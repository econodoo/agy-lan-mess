import 'dart:convert';

class WsTypes {
  // Auth & Node Registration
  static const String authHello = 'auth.hello';
  static const String authOk = 'auth.ok';
  static const String authError = 'auth.error';
  static const String nodeUpdate = 'node.update';
  static const String nodePing = 'node.ping';
  static const String nodePong = 'node.pong';

  // Fleet & Multi-Session Sync (Server <-> Consoles)
  static const String fleetSnapshot = 'fleet.snapshot';
  static const String sessionsSnapshot = 'sessions.snapshot';
  static const String sessionDetail = 'session.detail';
  static const String sessionCreate = 'session.create';
  static const String sessionUpdate = 'session.update';
  static const String sessionDelete = 'session.delete';
  static const String sessionGet = 'session.get';
  static const String browseRemoteDir = 'fleet.browse_dir';
  static const String browseRemoteDirResult = 'fleet.browse_dir_result';

  // Chat Streaming (Client/Server UI -> Server Brain -> Subscribers)
  static const String chatSend = 'chat.send';
  static const String chatCancel = 'chat.cancel';
  static const String chatEvent = 'chat.event';

  // Server Brain Health, Auth, Quota & Model Control
  static const String brainStatusGet = 'brain.status_get';
  static const String brainPingTest = 'brain.ping_test';
  static const String brainSetModel = 'brain.set_model';
  static const String brainStatus = 'brain.status';

  // Server -> Target Node RPC & Heartbeat Task Tracking
  static const String rpcExec = 'rpc.exec';
  static const String rpcExecHeartbeat = 'rpc.exec_heartbeat';
  static const String rpcExecResult = 'rpc.exec_result';
  static const String rpcTaskKill = 'rpc.task_kill';
  static const String rpcAwaitingApproval = 'rpc.awaiting_approval';
  static const String rpcFileOp = 'rpc.file_op';
  static const String rpcFileOpResult = 'rpc.file_op_result';
  static const String tasksSnapshot = 'tasks.snapshot';
  static const String taskKillRequest = 'task.kill';
}

class WsEnvelope {
  final String type;
  final String? id;
  final Map<String, dynamic> payload;

  const WsEnvelope({
    required this.type,
    this.id,
    this.payload = const {},
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        if (id != null) 'id': id,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  factory WsEnvelope.decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return WsEnvelope(
      type: map['type'] as String? ?? '',
      id: map['id'] as String?,
      payload: map['payload'] is Map
          ? Map<String, dynamic>.from(map['payload'] as Map)
          : const {},
    );
  }
}
