import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class PairedNodeRecord {
  final String nodeId;
  final String tokenHash;
  final NodeInfo lastKnownInfo;

  const PairedNodeRecord({
    required this.nodeId,
    required this.tokenHash,
    required this.lastKnownInfo,
  });

  PairedNodeRecord copyWith({NodeInfo? lastKnownInfo, String? tokenHash}) =>
      PairedNodeRecord(
        nodeId: nodeId,
        tokenHash: tokenHash ?? this.tokenHash,
        lastKnownInfo: lastKnownInfo ?? this.lastKnownInfo,
      );

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'tokenHash': tokenHash,
        'lastKnownInfo': lastKnownInfo.toJson(),
      };

  factory PairedNodeRecord.fromJson(Map<String, dynamic> json) =>
      PairedNodeRecord(
        nodeId: json['nodeId'] as String? ?? '',
        tokenHash: json['tokenHash'] as String? ?? '',
        lastKnownInfo: NodeInfo.fromJson(
          Map<String, dynamic>.from(json['lastKnownInfo'] as Map? ?? const {}),
        ),
      );
}

class PairingAndSessionStore {
  final String stateFilePath;
  final _uuid = const Uuid();
  final _rng = Random.secure();

  late String _pairingPin;
  late String _loopbackAdminToken;
  final Map<String, PairedNodeRecord> _pairedNodes = {};
  final Map<String, MeshSession> _sessions = {};
  Timer? _saveDebounce;

  PairingAndSessionStore({String? stateDir})
      : stateFilePath = p.join(
          stateDir ?? _defaultStateDir(),
          'server_state.json',
        );

  static String _defaultStateDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return p.join(home, '.config', 'agy-lan-mesh');
  }

  String get pairingPin => _pairingPin;
  String get loopbackAdminToken => _loopbackAdminToken;

  Future<void> init({String? overridePin}) async {
    _loopbackAdminToken = _generateRandomHex(32);
    final file = File(stateFilePath);
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _pairingPin = overridePin ??
            (data['pairingPin'] as String?) ??
            _generateSixDigitPin();
        final nodesMap = data['pairedNodes'] as Map<String, dynamic>? ?? {};
        for (final entry in nodesMap.entries) {
          final rec = PairedNodeRecord.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          _pairedNodes[entry.key] = rec.copyWith(
            lastKnownInfo: rec.lastKnownInfo.copyWith(online: false),
          );
        }
        final sessionsList = data['sessions'] as List<dynamic>? ?? [];
        for (final item in sessionsList) {
          final s = MeshSession.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          // Reset any stale 'running' status from a prior crash/shutdown
          final normalized = (s.status == SessionStatuses.running ||
                  s.status == SessionStatuses.awaitingApproval)
              ? s.copyWith(status: SessionStatuses.idle)
              : s;
          _sessions[normalized.sessionId] = normalized;
        }
      } catch (e) {
        stderr.writeln('[Store] Warning: failed to parse $stateFilePath: $e');
        _pairingPin = overridePin ?? _generateSixDigitPin();
      }
    } else {
      _pairingPin = overridePin ?? _generateSixDigitPin();
    }
    await saveNow();
  }

  String rotatePin() {
    _pairingPin = _generateSixDigitPin();
    scheduleSave();
    return _pairingPin;
  }

  bool verifyPin(String candidate) =>
      candidate.trim().isNotEmpty && candidate.trim() == _pairingPin;

  bool isLoopbackToken(String? token) =>
      token != null && token.isNotEmpty && token == _loopbackAdminToken;

  /// Issues a persistent bearer token for a newly paired node.
  String registerOrUpdatePairedNode(NodeInfo info, {String? existingToken}) {
    final token = existingToken ?? _generateRandomHex(32);
    final hash = _hashToken(token);
    _pairedNodes[info.nodeId] = PairedNodeRecord(
      nodeId: info.nodeId,
      tokenHash: hash,
      lastKnownInfo: info,
    );
    scheduleSave();
    return token;
  }

  bool verifyNodeToken(String nodeId, String token) {
    if (isLoopbackToken(token)) return true;
    final rec = _pairedNodes[nodeId];
    if (rec == null) return false;
    return rec.tokenHash == _hashToken(token);
  }

  /// Also allows console clients to authenticate with any valid paired token.
  bool verifyAnyToken(String token) {
    if (isLoopbackToken(token)) return true;
    final h = _hashToken(token);
    return _pairedNodes.values.any((r) => r.tokenHash == h);
  }

  void updateNodeMetadata(NodeInfo info) {
    final existing = _pairedNodes[info.nodeId];
    if (existing != null) {
      _pairedNodes[info.nodeId] = existing.copyWith(lastKnownInfo: info);
      scheduleSave();
    }
  }

  List<NodeInfo> getAllKnownNodes() =>
      _pairedNodes.values.map((r) => r.lastKnownInfo).toList();

  // ---------------- Multi-Session Management ----------------

  List<MeshSession> listSessions() {
    final list = _sessions.values.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  MeshSession? getSession(String sessionId) => _sessions[sessionId];

  MeshSession createSession({
    required String title,
    required String targetNodeId,
    String targetNodeName = '',
    String workspacePath = '',
    String? sessionId,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = sessionId ?? _uuid.v4();
    final session = MeshSession(
      sessionId: id,
      title: title.trim().isEmpty ? 'Untitled Session' : title.trim(),
      targetNodeId: targetNodeId.trim().isEmpty ? '*' : targetNodeId.trim(),
      targetNodeName: targetNodeName,
      workspacePath: workspacePath.trim(),
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    _sessions[id] = session;
    scheduleSave();
    return session;
  }

  MeshSession? updateSessionMeta(
    String sessionId, {
    String? title,
    String? targetNodeId,
    String? targetNodeName,
    String? workspacePath,
    String? agyConversationId,
    String? status,
  }) {
    final current = _sessions[sessionId];
    if (current == null) return null;
    final updated = current.copyWith(
      title: title,
      targetNodeId: targetNodeId,
      targetNodeName: targetNodeName,
      workspacePath: workspacePath,
      agyConversationId: agyConversationId,
      status: status,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _sessions[sessionId] = updated;
    scheduleSave();
    return updated;
  }

  MeshSession? appendMessage(String sessionId, SessionMessage message) {
    final current = _sessions[sessionId];
    if (current == null) return null;
    final updated = current.copyWith(
      messages: [...current.messages, message],
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _sessions[sessionId] = updated;
    scheduleSave();
    return updated;
  }

  MeshSession? updateMessage(
    String sessionId,
    String messageId,
    SessionMessage Function(SessionMessage current) updater,
  ) {
    final current = _sessions[sessionId];
    if (current == null) return null;
    final updatedMessages = current.messages
        .map((m) => m.id == messageId ? updater(m) : m)
        .toList();
    final updated = current.copyWith(
      messages: updatedMessages,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _sessions[sessionId] = updated;
    scheduleSave();
    return updated;
  }

  bool deleteSession(String sessionId) {
    final removed = _sessions.remove(sessionId) != null;
    if (removed) scheduleSave();
    return removed;
  }

  void scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final file = File(stateFilePath);
    await file.parent.create(recursive: true);
    final tmp = File('$stateFilePath.tmp');
    final payload = const JsonEncoder.withIndent('  ').convert({
      'pairingPin': _pairingPin,
      'pairedNodes': _pairedNodes.map((k, v) => MapEntry(k, v.toJson())),
      'sessions': listSessions().map((s) => s.toJson()).toList(),
    });
    await tmp.writeAsString(payload);
    await tmp.rename(stateFilePath);
  }

  Future<void> dispose() async {
    await saveNow();
  }

  String _generateSixDigitPin() {
    final n = 100000 + _rng.nextInt(900000);
    return n.toString();
  }

  String _generateRandomHex(int bytes) {
    final list = List<int>.generate(bytes, (_) => _rng.nextInt(256));
    return list.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
