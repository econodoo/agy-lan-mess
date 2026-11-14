import 'dart:async';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'pairing_store.dart';

class ConnectedPeer {
  final String connectionId;
  final WebSocketChannel channel;
  final String remoteIp;
  NodeInfo? nodeInfo; // Non-null if registered as an executable/device node
  bool isAuthenticated;
  DateTime lastSeen;

  ConnectedPeer({
    required this.connectionId,
    required this.channel,
    required this.remoteIp,
    this.nodeInfo,
    this.isAuthenticated = false,
  }) : lastSeen = DateTime.now().toUtc();

  void send(WsEnvelope env) {
    try {
      channel.sink.add(env.encode());
    } catch (_) {}
  }
}

class _PendingRpc<T> {
  final String requestId;
  final String nodeId;
  final Completer<T> completer;
  Timer? timer;
  final void Function(T timeoutValue) onTimeoutBuilder;

  _PendingRpc({
    required this.requestId,
    required this.nodeId,
    required this.completer,
    required this.onTimeoutBuilder,
  });

  void armTimeout(Duration duration) {
    timer?.cancel();
    timer = Timer(duration, () {
      if (!completer.isCompleted) {
        onTimeoutBuilder;
        completer.completeError(
          TimeoutException('RPC $requestId timed out on node $nodeId', duration),
        );
      }
    });
  }

  void cancelTimer() {
    timer?.cancel();
    timer = null;
  }
}

class NodeRegistry {
  final PairingAndSessionStore store;
  final bool exposeLocalServerNode;
  final _uuid = const Uuid();

  final Map<String, ConnectedPeer> _peersByConnId = {};
  final Map<String, ConnectedPeer> _activeNodePeers = {};
  final Map<String, _PendingRpc<ExecResult>> _pendingExecs = {};
  final Map<String, _PendingRpc<FileOpResult>> _pendingFileOps = {};

  void Function(String nodeId, String requestId)? onNodeAwaitingApproval;
  Timer? _heartbeatTimer;

  NodeRegistry({
    required this.store,
    this.exposeLocalServerNode = false,
  }) {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _pingAll();
    });
  }

  static const String localServerNodeId = 'server-local';

  NodeInfo _buildLocalServerNodeInfo() {
    final now = DateTime.now().toUtc().toIso8601String();
    final isRoot = !Platform.isWindows &&
        (Platform.environment['USER'] == 'root' || _checkUidZero());
    return NodeInfo(
      nodeId: localServerNodeId,
      hostname: '${Platform.localHostname} (Brain Host)',
      os: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      arch: Platform.version.split(' ').last,
      ipAddress: '127.0.0.1',
      privilegeLevel:
          isRoot ? PrivilegeLevels.root : PrivilegeLevels.standard,
      approvalMode: ApprovalModes.fullAuto,
      cwd: Directory.current.path,
      capabilities: const ['exec', 'fs', 'chat'],
      online: true,
      connectedAt: now,
      lastSeenAt: now,
    );
  }

  static bool _checkUidZero() {
    try {
      final res = Process.runSync('id', ['-u']);
      return res.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  void registerPeer(ConnectedPeer peer) {
    _peersByConnId[peer.connectionId] = peer;
  }

  void bindAuthenticatedNode(ConnectedPeer peer, NodeInfo info) {
    final existingPeer = _activeNodePeers[info.nodeId];
    if (existingPeer != null &&
        existingPeer.connectionId != peer.connectionId) {
      try {
        existingPeer.channel.sink.close();
      } catch (_) {}
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final liveInfo = info.copyWith(
      ipAddress: info.ipAddress.isNotEmpty ? info.ipAddress : peer.remoteIp,
      online: true,
      lastSeenAt: now,
    );
    peer.nodeInfo = liveInfo;
    peer.isAuthenticated = true;
    _activeNodePeers[liveInfo.nodeId] = peer;
    store.updateNodeMetadata(liveInfo);
    broadcastFleetSnapshot();
  }

  void updatePeerNodeInfo(ConnectedPeer peer, Map<String, dynamic> patch) {
    final current = peer.nodeInfo;
    if (current == null) return;
    final updated = current.copyWith(
      hostname: patch['hostname'] as String?,
      privilegeLevel: patch['privilegeLevel'] as String?,
      approvalMode: patch['approvalMode'] as String?,
      cwd: patch['cwd'] as String?,
      online: true,
      lastSeenAt: DateTime.now().toUtc().toIso8601String(),
    );
    peer.nodeInfo = updated;
    store.updateNodeMetadata(updated);
    broadcastFleetSnapshot();
  }

  void unregisterPeer(ConnectedPeer peer) {
    _peersByConnId.remove(peer.connectionId);
    final info = peer.nodeInfo;
    if (info != null) {
      final currentActive = _activeNodePeers[info.nodeId];
      if (currentActive?.connectionId == peer.connectionId) {
        _activeNodePeers.remove(info.nodeId);
        final offlineInfo = info.copyWith(
          online: false,
          lastSeenAt: DateTime.now().toUtc().toIso8601String(),
        );
        store.updateNodeMetadata(offlineInfo);

        // Fail any pending RPCs for this disconnected node immediately
        final failedExecIds = _pendingExecs.entries
            .where((e) => e.value.nodeId == info.nodeId)
            .map((e) => e.key)
            .toList();
        for (final id in failedExecIds) {
          final rpc = _pendingExecs.remove(id);
          rpc?.cancelTimer();
          if (rpc != null && !rpc.completer.isCompleted) {
            rpc.completer.complete(
              ExecResult(
                requestId: id,
                exitCode: -1,
                stdout: '',
                stderr: 'Node "${info.hostname}" disconnected during execution.',
                errorMessage: 'Node disconnected',
              ),
            );
          }
        }

        final failedFsIds = _pendingFileOps.entries
            .where((e) => e.value.nodeId == info.nodeId)
            .map((e) => e.key)
            .toList();
        for (final id in failedFsIds) {
          final rpc = _pendingFileOps.remove(id);
          rpc?.cancelTimer();
          if (rpc != null && !rpc.completer.isCompleted) {
            rpc.completer.complete(
              FileOpResult(
                requestId: id,
                ok: false,
                error: 'Node "${info.hostname}" disconnected during file op.',
              ),
            );
          }
        }
        broadcastFleetSnapshot();
      }
    }
  }

  List<NodeInfo> listAllNodes() {
    final map = <String, NodeInfo>{};
    if (exposeLocalServerNode) {
      map[localServerNodeId] = _buildLocalServerNodeInfo();
    }
    for (final known in store.getAllKnownNodes()) {
      map[known.nodeId] = known.copyWith(online: false);
    }
    for (final entry in _activeNodePeers.entries) {
      if (entry.value.nodeInfo != null) {
        map[entry.key] = entry.value.nodeInfo!.copyWith(online: true);
      }
    }
    final list = map.values.toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
    });
    return list;
  }

  /// Resolves a node by exact `nodeId`, exact `hostname`, or unique prefix/substring.
  NodeInfo? resolveNode(String nodeRef) {
    final query = nodeRef.trim();
    if (query.isEmpty) return null;
    final all = listAllNodes();
    for (final n in all) {
      if (n.nodeId == query) return n;
    }
    final lower = query.toLowerCase();
    for (final n in all) {
      if (n.hostname.toLowerCase() == lower) return n;
    }
    final partial =
        all.where((n) => n.hostname.toLowerCase().contains(lower)).toList();
    if (partial.length == 1) return partial.first;
    final onlinePartial = partial.where((n) => n.online).toList();
    if (onlinePartial.length == 1) return onlinePartial.first;
    return null;
  }

  void broadcastToAuthenticated(WsEnvelope envelope) {
    for (final peer in _peersByConnId.values.toList()) {
      if (peer.isAuthenticated) {
        peer.send(envelope);
      }
    }
  }

  void broadcastFleetSnapshot() {
    broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.fleetSnapshot,
        payload: {
          'nodes': listAllNodes().map((n) => n.toJson()).toList(),
        },
      ),
    );
  }

  void broadcastSessionsSnapshot() {
    broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.sessionsSnapshot,
        payload: {
          'sessions': store.listSessions().map((s) => s.toSummaryJson()).toList(),
        },
      ),
    );
  }

  // ---------------- Remote Execution & File Ops ----------------

  Future<ExecResult> executeCommand({
    required String nodeRef,
    required String command,
    String? cwd,
    bool elevated = false,
    int timeoutSec = 120,
    String? requestingSessionTitle,
  }) async {
    final resolved = resolveNode(nodeRef);
    if (resolved == null) {
      return ExecResult(
        requestId: 'none',
        exitCode: -1,
        stdout: '',
        stderr:
            'Unknown target node "$nodeRef". Call mesh_list_nodes to see valid node IDs/hostnames.',
        errorMessage: 'Unknown node',
      );
    }

    if (resolved.nodeId == localServerNodeId && exposeLocalServerNode) {
      return _executeLocalCommand(
        command: command,
        cwd: cwd,
        timeoutSec: timeoutSec,
      );
    }

    final peer = _activeNodePeers[resolved.nodeId];
    if (peer == null || !resolved.online) {
      return ExecResult(
        requestId: 'none',
        exitCode: -1,
        stdout: '',
        stderr: 'Target node "${resolved.hostname}" (${resolved.nodeId}) is currently offline.',
        errorMessage: 'Node offline',
      );
    }

    final requestId = _uuid.v4();
    final req = ExecRequest(
      requestId: requestId,
      command: command,
      cwd: cwd,
      elevated: elevated,
      timeoutSec: timeoutSec,
      requestingSessionTitle: requestingSessionTitle,
    );

    final completer = Completer<ExecResult>();
    final pending = _PendingRpc<ExecResult>(
      requestId: requestId,
      nodeId: resolved.nodeId,
      completer: completer,
      onTimeoutBuilder: (_) {},
    );
    _pendingExecs[requestId] = pending;
    pending.armTimeout(Duration(seconds: timeoutSec + 15));

    peer.send(WsEnvelope(
      type: WsTypes.rpcExec,
      id: requestId,
      payload: req.toJson(),
    ));

    try {
      return await completer.future;
    } on TimeoutException {
      _pendingExecs.remove(requestId);
      return ExecResult(
        requestId: requestId,
        exitCode: 124,
        stdout: '',
        stderr: 'Command timed out after ${timeoutSec}s on "${resolved.hostname}".',
        errorMessage: 'Timeout',
      );
    }
  }

  void handleExecAwaitingApproval(String nodeId, String requestId) {
    final pending = _pendingExecs[requestId];
    if (pending != null) {
      // Give the human up to 10 minutes to click Approve/Deny on the target device
      pending.armTimeout(const Duration(minutes: 10));
      onNodeAwaitingApproval?.call(nodeId, requestId);
    }
  }

  void handleExecResult(Map<String, dynamic> payload) {
    final res = ExecResult.fromJson(payload);
    final pending = _pendingExecs.remove(res.requestId);
    if (pending != null) {
      pending.cancelTimer();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(res);
      }
    }
  }

  Future<FileOpResult> performFileOp({
    required String nodeRef,
    required String op,
    required String path,
    String? baseWorkspacePath,
    String? content,
    String? target,
    String? replacement,
    bool append = false,
    int? startLine,
    int? endLine,
  }) async {
    final resolved = resolveNode(nodeRef);
    if (resolved == null) {
      return FileOpResult(
        requestId: 'none',
        ok: false,
        error:
            'Unknown target node "$nodeRef". Call mesh_list_nodes to see valid node IDs/hostnames.',
      );
    }

    final effectivePath = _resolveRemotePath(
      rawPath: path,
      os: resolved.os,
      workspacePath: baseWorkspacePath,
      nodeCwd: resolved.cwd,
    );

    if (resolved.nodeId == localServerNodeId && exposeLocalServerNode) {
      return _performLocalFileOp(
        op: op,
        path: effectivePath,
        content: content,
        target: target,
        replacement: replacement,
        append: append,
        startLine: startLine,
        endLine: endLine,
      );
    }

    final peer = _activeNodePeers[resolved.nodeId];
    if (peer == null || !resolved.online) {
      return FileOpResult(
        requestId: 'none',
        ok: false,
        error: 'Target node "${resolved.hostname}" (${resolved.nodeId}) is currently offline.',
      );
    }

    final requestId = _uuid.v4();
    final req = FileOpRequest(
      requestId: requestId,
      op: op,
      path: effectivePath,
      content: content,
      target: target,
      replacement: replacement,
      append: append,
      startLine: startLine,
      endLine: endLine,
    );

    final completer = Completer<FileOpResult>();
    final pending = _PendingRpc<FileOpResult>(
      requestId: requestId,
      nodeId: resolved.nodeId,
      completer: completer,
      onTimeoutBuilder: (_) {},
    );
    _pendingFileOps[requestId] = pending;
    pending.armTimeout(const Duration(seconds: 45));

    peer.send(WsEnvelope(
      type: WsTypes.rpcFileOp,
      id: requestId,
      payload: req.toJson(),
    ));

    try {
      return await completer.future;
    } on TimeoutException {
      _pendingFileOps.remove(requestId);
      return FileOpResult(
        requestId: requestId,
        ok: false,
        error: 'File operation "$op" timed out on "${resolved.hostname}".',
      );
    }
  }

  void handleFileOpResult(Map<String, dynamic> payload) {
    final res = FileOpResult.fromJson(payload);
    final pending = _pendingFileOps.remove(res.requestId);
    if (pending != null) {
      pending.cancelTimer();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(res);
      }
    }
  }

  static String _resolveRemotePath({
    required String rawPath,
    required String os,
    String? workspacePath,
    String? nodeCwd,
  }) {
    final trimmed = rawPath.trim();
    final isWin = os.toLowerCase() == 'windows';
    final ctx = isWin ? p.windows : p.posix;
    if (trimmed.isEmpty || trimmed == '.') {
      if (workspacePath != null && workspacePath.trim().isNotEmpty) {
        return workspacePath.trim();
      }
      return (nodeCwd != null && nodeCwd.isNotEmpty) ? nodeCwd : '.';
    }
    if (ctx.isAbsolute(trimmed) ||
        (isWin && RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed)) ||
        trimmed.startsWith('~')) {
      return trimmed;
    }
    final base = (workspacePath != null && workspacePath.trim().isNotEmpty)
        ? workspacePath.trim()
        : ((nodeCwd != null && nodeCwd.trim().isNotEmpty) ? nodeCwd.trim() : '');
    if (base.isEmpty) return trimmed;
    return ctx.join(base, trimmed);
  }

  Future<ExecResult> _executeLocalCommand({
    required String command,
    String? cwd,
    required int timeoutSec,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final proc = await Process.start(
        Platform.isWindows ? 'powershell.exe' : 'bash',
        Platform.isWindows
            ? ['-NoProfile', '-NonInteractive', '-Command', command]
            : ['-c', command],
        workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
      );
      final stdoutFuture = proc.stdout.transform(SystemEncoding().decoder).join();
      final stderrFuture = proc.stderr.transform(SystemEncoding().decoder).join();
      final exitCode = await proc.exitCode.timeout(Duration(seconds: timeoutSec));
      sw.stop();
      return ExecResult(
        requestId: 'local',
        exitCode: exitCode,
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      sw.stop();
      return ExecResult(
        requestId: 'local',
        exitCode: 124,
        stdout: '',
        stderr: 'Local server command timed out after ${timeoutSec}s',
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return ExecResult(
        requestId: 'local',
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  Future<FileOpResult> _performLocalFileOp({
    required String op,
    required String path,
    String? content,
    String? target,
    String? replacement,
    bool append = false,
    int? startLine,
    int? endLine,
  }) async {
    try {
      switch (op) {
        case 'read':
          final file = File(path);
          if (!await file.exists()) {
            return FileOpResult(
              requestId: 'local',
              ok: false,
              error: 'File not found: $path',
            );
          }
          final text = await file.readAsString();
          final lines = text.split('\n');
          final s = (startLine ?? 1).clamp(1, lines.isEmpty ? 1 : lines.length);
          final e =
              (endLine ?? lines.length).clamp(s, lines.isEmpty ? 1 : lines.length);
          final slice = lines.isEmpty ? '' : lines.sublist(s - 1, e).join('\n');
          return FileOpResult(requestId: 'local', ok: true, content: slice);
        case 'write':
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsString(
            content ?? '',
            mode: append ? FileMode.append : FileMode.write,
          );
          return FileOpResult(
            requestId: 'local',
            ok: true,
            message: 'Wrote ${content?.length ?? 0} chars to $path',
          );
        case 'edit':
          final file = File(path);
          if (!await file.exists()) {
            return FileOpResult(
              requestId: 'local',
              ok: false,
              error: 'File not found: $path',
            );
          }
          final existing = await file.readAsString();
          if (target == null || target.isEmpty || !existing.contains(target)) {
            return FileOpResult(
              requestId: 'local',
              ok: false,
              error: 'Target text not found in $path',
            );
          }
          final updated = existing.replaceAll(target, replacement ?? '');
          await file.writeAsString(updated);
          return FileOpResult(
            requestId: 'local',
            ok: true,
            message: 'Edited $path successfully.',
          );
        case 'list':
          final dir = Directory(path);
          if (!await dir.exists()) {
            return FileOpResult(
              requestId: 'local',
              ok: false,
              error: 'Directory not found: $path',
            );
          }
          final entries = <DirEntryInfo>[];
          await for (final entity in dir.list(followLinks: false)) {
            final stat = await entity.stat();
            entries.add(DirEntryInfo(
              name: p.basename(entity.path),
              path: entity.path,
              isDirectory: stat.type == FileSystemEntityType.directory,
              size: stat.size,
              modifiedAt: stat.modified.toUtc().toIso8601String(),
            ));
          }
          entries.sort((a, b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          return FileOpResult(requestId: 'local', ok: true, entries: entries);
        default:
          return FileOpResult(
            requestId: 'local',
            ok: false,
            error: 'Unsupported file op: $op',
          );
      }
    } catch (e) {
      return FileOpResult(requestId: 'local', ok: false, error: e.toString());
    }
  }

  void _pingAll() {
    final ping = const WsEnvelope(type: WsTypes.nodePing);
    for (final peer in _peersByConnId.values.toList()) {
      peer.send(ping);
    }
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    final peers = _peersByConnId.values.toList();
    _peersByConnId.clear();
    _activeNodePeers.clear();
    for (final peer in peers) {
      try {
        peer.channel.sink.close();
      } catch (_) {}
    }
  }
}
