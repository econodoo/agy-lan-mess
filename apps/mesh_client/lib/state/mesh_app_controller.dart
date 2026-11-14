import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../platform/local_node_driver.dart';

class PendingApprovalItem {
  final ExecRequest request;
  final DateTime receivedAt;
  final Completer<bool> decisionCompleter;

  PendingApprovalItem({
    required this.request,
    required this.decisionCompleter,
  }) : receivedAt = DateTime.now();
}

class AuditLogEntry {
  final DateTime timestamp;
  final String category; // exec | fs | security
  final String summary;
  final String detail;
  final bool isError;

  AuditLogEntry({
    required this.category,
    required this.summary,
    this.detail = '',
    this.isError = false,
  }) : timestamp = DateTime.now();
}

class MeshAppController extends ChangeNotifier {
  final LocalNodeDriver driver = LocalNodeDriver();
  final _uuid = const Uuid();

  SharedPreferences? _prefs;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;

  // Connection & Identity State
  String wsUrl = 'ws://127.0.0.1:8765/ws';
  String nodeId = '';
  String hostname = '';
  String token = '';
  String pairingPinInput = '';
  String? serverLoopbackPin; // Populated for all authenticated sessions
  List<String> serverLanUrls = [];
  BrainHealthStatus? brainHealth;
  bool isPingingBrain = false;
  String serverHostname = '';
  String privilegeLevel = PrivilegeLevels.standard;
  String approvalMode = ApprovalModes.askForElevated;
  String localCwd = '';
  bool registerAsTargetNode = true;

  bool isConnecting = false;
  bool isConnected = false;
  bool needsPin = false;
  String? connectionError;

  // Fleet & Multi-Session State
  List<NodeInfo> nodes = [];
  List<Map<String, dynamic>> sessionSummaries = [];
  final Map<String, MeshSession> sessionDetails = {};
  String? selectedSessionId;
  String machineFilterNodeId = 'ALL'; // 'ALL' or specific nodeId

  // Pending Remote Directory Browser Completers
  final Map<String, Completer<FileOpResult>> _pendingBrowseRequests = {};

  // Local Approval Queue & Audit Log
  final List<PendingApprovalItem> pendingApprovals = [];
  final List<AuditLogEntry> auditLog = [];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    nodeId = _prefs?.getString('mesh_node_id') ?? _uuid.v4();
    await _prefs?.setString('mesh_node_id', nodeId);

    hostname = _prefs?.getString('mesh_hostname') ?? driver.defaultHostname;
    token = _prefs?.getString('mesh_token') ?? '';
    approvalMode =
        _prefs?.getString('mesh_approval_mode') ?? ApprovalModes.askForElevated;
    localCwd =
        _prefs?.getString('mesh_local_cwd') ?? await driver.defaultWorkingDirectory();
    registerAsTargetNode = _prefs?.getBool('mesh_register_node') ??
        !driver.isWebConsole;

    privilegeLevel = await driver.detectPrivilegeLevel();

    final savedUrl = _prefs?.getString('mesh_ws_url');
    if (savedUrl != null && savedUrl.isNotEmpty) {
      wsUrl = savedUrl;
    } else {
      wsUrl = driver.defaultInitialWsUrl();
      if (!driver.isWebConsole) {
        final discovered = await driver.discoverLanHub();
        if (discovered != null) {
          wsUrl = discovered.wsUrl;
        }
      }
    }
    notifyListeners();
    unawaited(connect());
  }

  Future<String?> autoDiscoverHub() async {
    final found = await driver.discoverLanHub();
    if (found != null) {
      wsUrl = found.wsUrl;
      await _prefs?.setString('mesh_ws_url', wsUrl);
      notifyListeners();
      unawaited(connect());
      return '${found.serverName} (${found.wsUrl})';
    }
    return null;
  }

  Future<void> connect({String? newWsUrl, String? pin}) async {
    _reconnectTimer?.cancel();
    if (newWsUrl != null && newWsUrl.trim().isNotEmpty) {
      wsUrl = newWsUrl.trim();
      await _prefs?.setString('mesh_ws_url', wsUrl);
    }
    if (pin != null) {
      pairingPinInput = pin.trim();
    }

    await _wsSub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}

    isConnecting = true;
    isConnected = false;
    connectionError = null;
    notifyListeners();

    try {
      privilegeLevel = await driver.detectPrivilegeLevel();
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      await channel.ready;
      _channel = channel;

      _wsSub = channel.stream.listen(
        _onWsMessage,
        onDone: _onWsClosed,
        onError: (Object err) {
          connectionError = err.toString();
          _onWsClosed();
        },
      );

      final now = DateTime.now().toUtc().toIso8601String();
      final myNode = NodeInfo(
        nodeId: nodeId,
        hostname: hostname,
        os: driver.osName,
        osVersion: driver.osVersion,
        arch: driver.arch,
        privilegeLevel: privilegeLevel,
        approvalMode: approvalMode,
        cwd: localCwd,
        capabilities: driver.capabilities,
        online: true,
        connectedAt: now,
        lastSeenAt: now,
      );

      _send(WsEnvelope(
        type: WsTypes.authHello,
        payload: {
          'pin': pairingPinInput,
          'token': token,
          'registerAsNode': registerAsTargetNode && !driver.isWebConsole,
          'nodeInfo': myNode.toJson(),
        },
      ));
    } catch (e) {
      isConnecting = false;
      isConnected = false;
      connectionError = 'Could not reach Hub ($wsUrl): $e';
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onWsClosed() {
    isConnecting = false;
    isConnected = false;
    notifyListeners();
    if (!needsPin) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!isConnected && !isConnecting && !needsPin) {
        unawaited(connect());
      }
    });
  }

  void _send(WsEnvelope env) {
    try {
      _channel?.sink.add(env.encode());
    } catch (_) {}
  }

  Future<void> _onWsMessage(dynamic raw) async {
    if (raw is! String) return;
    WsEnvelope env;
    try {
      env = WsEnvelope.decode(raw);
    } catch (_) {
      return;
    }

    final p = env.payload;
    switch (env.type) {
      case WsTypes.authOk:
        isConnecting = false;
        isConnected = true;
        needsPin = false;
        connectionError = null;
        nodeId = p['nodeId'] as String? ?? nodeId;
        token = p['token'] as String? ?? token;
        serverHostname = p['serverHostname'] as String? ?? 'AGY Hub';
        serverLoopbackPin = p['pairingPin'] as String?;
        serverLanUrls = (p['lanUrls'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [];
        if (p['brainStatus'] is Map) {
          brainHealth = BrainHealthStatus.fromJson(
            Map<String, dynamic>.from(p['brainStatus'] as Map),
          );
        }
        pairingPinInput = '';
        await _prefs?.setString('mesh_node_id', nodeId);
        await _prefs?.setString('mesh_token', token);

        _ingestNodes(p['nodes'] as List<dynamic>?);
        _ingestSessions(p['sessions'] as List<dynamic>?);
        if (selectedSessionId != null) {
          requestSessionDetail(selectedSessionId!);
        } else if (sessionSummaries.isNotEmpty) {
          selectSession(sessionSummaries.first['sessionId'] as String);
        }
        notifyListeners();
        break;

      case WsTypes.authError:
        isConnecting = false;
        isConnected = false;
        needsPin = true;
        token = '';
        await _prefs?.remove('mesh_token');
        connectionError = p['message'] as String? ?? 'Pairing PIN required.';
        notifyListeners();
        break;

      case WsTypes.nodePing:
        _send(const WsEnvelope(type: WsTypes.nodePong));
        break;

      case WsTypes.fleetSnapshot:
        _ingestNodes(p['nodes'] as List<dynamic>?);
        notifyListeners();
        break;

      case WsTypes.sessionsSnapshot:
        _ingestSessions(p['sessions'] as List<dynamic>?);
        notifyListeners();
        break;

      case WsTypes.sessionDetail:
        final sMap = p['session'] as Map?;
        if (sMap != null) {
          final detail =
              MeshSession.fromJson(Map<String, dynamic>.from(sMap));
          sessionDetails[detail.sessionId] = detail;
          selectedSessionId ??= detail.sessionId;
          notifyListeners();
        }
        break;

      case WsTypes.chatEvent:
        _handleLiveChatEvent(p);
        break;

      case WsTypes.brainStatus:
        isPingingBrain = false;
        brainHealth = BrainHealthStatus.fromJson(p);
        notifyListeners();
        break;

      case WsTypes.browseRemoteDirResult:
        final id = env.id;
        if (id != null && _pendingBrowseRequests.containsKey(id)) {
          final c = _pendingBrowseRequests.remove(id)!;
          if (!c.isCompleted) {
            c.complete(FileOpResult.fromJson(p));
          }
        }
        break;

      case WsTypes.rpcExec:
        unawaited(_handleIncomingExecRpc(ExecRequest.fromJson(p)));
        break;

      case WsTypes.rpcFileOp:
        unawaited(_handleIncomingFileOpRpc(FileOpRequest.fromJson(p)));
        break;
    }
  }

  void _ingestNodes(List<dynamic>? rawNodes) {
    if (rawNodes == null) return;
    nodes = rawNodes
        .map((e) => NodeInfo.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  void _ingestSessions(List<dynamic>? rawSessions) {
    if (rawSessions == null) return;
    sessionSummaries = rawSessions
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (selectedSessionId != null &&
        !sessionSummaries.any((s) => s['sessionId'] == selectedSessionId)) {
      selectedSessionId = sessionSummaries.isNotEmpty
          ? sessionSummaries.first['sessionId'] as String
          : null;
      if (selectedSessionId != null) {
        requestSessionDetail(selectedSessionId!);
      }
    }
  }

  void _handleLiveChatEvent(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String? ?? '';
    final detail = sessionDetails[sessionId];
    if (detail == null) {
      if (sessionId == selectedSessionId) {
        requestSessionDetail(sessionId);
      }
      return;
    }

    final kind = p['kind'] as String? ?? '';
    if (kind == 'text_delta' || kind == 'thinking_delta') {
      final msgId = p['messageId'] as String? ?? '';
      final delta = p['delta'] as String? ?? '';
      final updatedMsgs = detail.messages.map((m) {
        if (m.id != msgId) return m;
        return kind == 'text_delta'
            ? m.copyWith(text: m.text + delta)
            : m.copyWith(thinking: m.thinking + delta);
      }).toList();
      sessionDetails[sessionId] = detail.copyWith(messages: updatedMsgs);
      notifyListeners();
    } else if (kind == 'tool_event') {
      final teMap = p['toolEvent'] as Map?;
      if (teMap != null && detail.messages.isNotEmpty) {
        final te = ToolCallSummary.fromJson(Map<String, dynamic>.from(teMap));
        final msgs = [...detail.messages];
        final last = msgs.last;
        final idx = last.toolEvents.indexWhere((x) => x.id == te.id);
        final nextTools = [...last.toolEvents];
        if (idx >= 0) {
          nextTools[idx] = te;
        } else {
          nextTools.add(te);
        }
        msgs[msgs.length - 1] = last.copyWith(toolEvents: nextTools);
        sessionDetails[sessionId] = detail.copyWith(messages: msgs);
        notifyListeners();
      }
    }
  }

  // ---------------- Local Target Node RPC Execution ----------------

  Future<void> _handleIncomingExecRpc(ExecRequest req) async {
    var approved = true;
    if (req.elevated && approvalMode == ApprovalModes.askForElevated) {
      _send(WsEnvelope(
        type: WsTypes.rpcAwaitingApproval,
        payload: {'requestId': req.requestId},
      ));
      final completer = Completer<bool>();
      final item = PendingApprovalItem(
        request: req,
        decisionCompleter: completer,
      );
      pendingApprovals.add(item);
      notifyListeners();
      approved = await completer.future;
    }

    if (!approved) {
      auditLog.insert(
        0,
        AuditLogEntry(
          category: 'security',
          summary: 'DENIED elevated command: ${req.command}',
          isError: true,
        ),
      );
      _send(WsEnvelope(
        type: WsTypes.rpcExecResult,
        payload: ExecResult(
          requestId: req.requestId,
          exitCode: 126,
          stdout: '',
          stderr: 'Command denied by local user on "$hostname".',
          approved: false,
        ).toJson(),
      ));
      notifyListeners();
      return;
    }

    final res = await driver.executeCommand(req);
    auditLog.insert(
      0,
      AuditLogEntry(
        category: 'exec',
        summary:
            '[exit ${res.exitCode}] ${req.elevated ? "(ELEVATED) " : ""}${req.command}',
        detail: (res.stdout.isNotEmpty ? res.stdout : res.stderr).trim(),
        isError: res.exitCode != 0,
      ),
    );
    _send(WsEnvelope(
      type: WsTypes.rpcExecResult,
      payload: res.toJson(),
    ));
    notifyListeners();
  }

  void resolvePendingApproval(
    PendingApprovalItem item, {
    required bool approve,
    bool switchToFullAuto = false,
  }) {
    pendingApprovals.remove(item);
    if (switchToFullAuto) {
      unawaited(setApprovalMode(ApprovalModes.fullAuto));
    }
    if (!item.decisionCompleter.isCompleted) {
      item.decisionCompleter.complete(approve);
    }
    notifyListeners();
  }

  Future<void> _handleIncomingFileOpRpc(FileOpRequest req) async {
    final res = await driver.performFileOp(req, defaultCwd: localCwd);
    auditLog.insert(
      0,
      AuditLogEntry(
        category: 'fs',
        summary: '${req.op.toUpperCase()} ${req.path}',
        detail: res.message ?? res.error ?? '',
        isError: !res.ok,
      ),
    );
    _send(WsEnvelope(
      type: WsTypes.rpcFileOpResult,
      payload: res.toJson(),
    ));
    notifyListeners();
  }

  // ---------------- Privilege & Node Settings ----------------

  Future<void> setApprovalMode(String mode) async {
    approvalMode = mode;
    await _prefs?.setString('mesh_approval_mode', mode);
    _send(WsEnvelope(
      type: WsTypes.nodeUpdate,
      payload: {'approvalMode': mode},
    ));
    notifyListeners();
  }

  Future<void> setLocalCwd(String path) async {
    localCwd = path.trim();
    await _prefs?.setString('mesh_local_cwd', localCwd);
    _send(WsEnvelope(
      type: WsTypes.nodeUpdate,
      payload: {'cwd': localCwd},
    ));
    notifyListeners();
  }

  Future<bool> unlockLocalSudo(String password) async {
    final ok = await driver.unlockSudo(password);
    if (ok) {
      privilegeLevel = await driver.detectPrivilegeLevel();
      _send(WsEnvelope(
        type: WsTypes.nodeUpdate,
        payload: {'privilegeLevel': privilegeLevel},
      ));
      auditLog.insert(
        0,
        AuditLogEntry(
          category: 'security',
          summary: 'Unlocked local in-memory sudo vault',
        ),
      );
      notifyListeners();
    }
    return ok;
  }

  Future<void> lockLocalSudo() async {
    driver.lockSudo();
    privilegeLevel = await driver.detectPrivilegeLevel();
    _send(WsEnvelope(
      type: WsTypes.nodeUpdate,
      payload: {'privilegeLevel': privilegeLevel},
    ));
    notifyListeners();
  }

  Future<bool> relaunchWindowsAdmin() => driver.relaunchAsWindowsAdmin();

  // ---------------- Multi-Session & Remote Folder Actions ----------------

  List<Map<String, dynamic>> get filteredSessions {
    if (machineFilterNodeId == 'ALL') return sessionSummaries;
    return sessionSummaries
        .where((s) => s['targetNodeId'] == machineFilterNodeId)
        .toList();
  }

  MeshSession? get activeSession =>
      selectedSessionId != null ? sessionDetails[selectedSessionId] : null;

  void setMachineFilter(String nodeIdOrAll) {
    machineFilterNodeId = nodeIdOrAll;
    notifyListeners();
  }

  void selectSession(String sessionId) {
    selectedSessionId = sessionId;
    requestSessionDetail(sessionId);
    notifyListeners();
  }

  void requestSessionDetail(String sessionId) {
    _send(WsEnvelope(
      type: WsTypes.sessionGet,
      payload: {'sessionId': sessionId},
    ));
  }

  void createProjectSession({
    required String title,
    required String targetNodeId,
    required String workspacePath,
  }) {
    final reqId = _uuid.v4();
    _send(WsEnvelope(
      type: WsTypes.sessionCreate,
      id: reqId,
      payload: {
        'title': title,
        'targetNodeId': targetNodeId,
        'workspacePath': workspacePath,
      },
    ));
  }

  void updateProjectSession({
    required String sessionId,
    String? title,
    String? targetNodeId,
    String? workspacePath,
  }) {
    _send(WsEnvelope(
      type: WsTypes.sessionUpdate,
      payload: {
        'sessionId': sessionId,
        if (title != null) 'title': title,
        if (targetNodeId != null) 'targetNodeId': targetNodeId,
        if (workspacePath != null) 'workspacePath': workspacePath,
      },
    ));
  }

  void deleteProjectSession(String sessionId) {
    sessionDetails.remove(sessionId);
    if (selectedSessionId == sessionId) {
      selectedSessionId = null;
    }
    _send(WsEnvelope(
      type: WsTypes.sessionDelete,
      payload: {'sessionId': sessionId},
    ));
    notifyListeners();
  }

  void sendChatPrompt(
    String prompt, {
    String? quickTargetNodeId,
    String? quickWorkspacePath,
  }) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;

    if (selectedSessionId != null) {
      _send(WsEnvelope(
        type: WsTypes.chatSend,
        payload: {
          'sessionId': selectedSessionId,
          'prompt': trimmed,
        },
      ));
    } else {
      final newId = _uuid.v4();
      selectedSessionId = newId;
      final defaultTarget = quickTargetNodeId ??
          ((registerAsTargetNode && !driver.isWebConsole && !driver.isAndroid)
              ? nodeId
              : (nodes.isNotEmpty ? nodes.first.nodeId : '*'));
      _send(WsEnvelope(
        type: WsTypes.chatSend,
        payload: {
          'sessionId': newId,
          'targetNodeId': defaultTarget,
          'workspacePath': quickWorkspacePath ?? localCwd,
          'prompt': trimmed,
        },
      ));
    }
  }

  void cancelActiveTurn(String sessionId) {
    _send(WsEnvelope(
      type: WsTypes.chatCancel,
      payload: {'sessionId': sessionId},
    ));
  }

  // ---------------- Brain Diagnostics, Model & Rollout Helpers ----------------

  void refreshBrainStatus() {
    _send(const WsEnvelope(type: WsTypes.brainStatusGet));
  }

  void runLiveBrainQuotaPing() {
    isPingingBrain = true;
    notifyListeners();
    _send(const WsEnvelope(type: WsTypes.brainPingTest));
  }

  void setBrainModelOverride(String modelId) {
    _send(WsEnvelope(
      type: WsTypes.brainSetModel,
      payload: {'modelId': modelId},
    ));
  }

  /// Best HTTP base URL for client rollout commands (uses LAN IP even if opened via 127.0.0.1 on Server!).
  String get bestRolloutHttpBaseUrl {
    try {
      final parsed = Uri.parse(wsUrl);
      final isLoopback = parsed.host == '127.0.0.1' ||
          parsed.host == 'localhost' ||
          parsed.host == '::1';
      if (isLoopback && serverLanUrls.isNotEmpty) {
        return serverLanUrls.first;
      }
      final httpScheme = parsed.scheme == 'wss' ? 'https' : 'http';
      final portPart = parsed.hasPort ? ':${parsed.port}' : '';
      return '$httpScheme://${parsed.host}$portPart';
    } catch (_) {
      return serverLanUrls.isNotEmpty
          ? serverLanUrls.first
          : 'http://127.0.0.1:8765';
    }
  }

  Future<FileOpResult> browseRemoteDirectory(String targetNodeId, String path) {
    final reqId = _uuid.v4();
    final completer = Completer<FileOpResult>();
    _pendingBrowseRequests[reqId] = completer;
    _send(WsEnvelope(
      type: WsTypes.browseRemoteDir,
      id: reqId,
      payload: {'nodeId': targetNodeId, 'path': path},
    ));
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingBrowseRequests.remove(reqId);
        return FileOpResult(
          requestId: reqId,
          ok: false,
          error: 'Timed out browsing remote directory',
        );
      },
    );
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _wsSub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
