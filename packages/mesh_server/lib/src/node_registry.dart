import 'dart:async';
import 'dart:convert';
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

class CommandWaitOutcome {
  final bool completed;
  final ExecResult? result;
  final RemoteTaskInfo taskInfo;

  const CommandWaitOutcome({
    required this.completed,
    this.result,
    required this.taskInfo,
  });
}

class _PendingRpc<T> {
  final String requestId;
  final String nodeId;
  final Completer<T> completer;
  Timer? timer;

  _PendingRpc({
    required this.requestId,
    required this.nodeId,
    required this.completer,
  });

  void armTimeout(Duration duration) {
    timer?.cancel();
    timer = Timer(duration, () {
      if (!completer.isCompleted) {
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

class _ManagedRemoteTask {
  RemoteTaskInfo info;
  final DateTime startedClock;
  DateTime lastHeartbeatClock;
  final String? requestingSessionId;
  bool wasDetachedToBackground = false;
  bool wasConsumedByWaitForTask = false;
  final Completer<ExecResult> completer = Completer<ExecResult>();
  ExecResult? finalResult;
  Timer? livenessWatchdog;
  Process? localProcess;

  _ManagedRemoteTask({
    required this.info,
    required this.startedClock,
    this.requestingSessionId,
  }) : lastHeartbeatClock = startedClock;

  void cancelWatchdog() {
    livenessWatchdog?.cancel();
    livenessWatchdog = null;
  }

  RemoteTaskInfo refreshedSnapshot() {
    if (!info.isActive) return info;
    final now = DateTime.now().toUtc();
    final elapsed = now.difference(startedClock).inMilliseconds;
    return info.copyWith(
      elapsedMs: elapsed > info.elapsedMs ? elapsed : info.elapsedMs,
    );
  }
}

class NodeRegistry {
  final PairingAndSessionStore store;
  final bool exposeLocalServerNode;
  final Duration heartbeatPingInterval;
  final Duration heartbeatLivenessTimeout;
  final _uuid = const Uuid();

  final Map<String, ConnectedPeer> _peersByConnId = {};
  final Map<String, ConnectedPeer> _activeNodePeers = {};
  final Map<String, _ManagedRemoteTask> _tasks = {};
  final Map<String, _PendingRpc<FileOpResult>> _pendingFileOps = {};

  void Function(String nodeId, String requestId)? onNodeAwaitingApproval;
  void Function(
    String sessionId,
    RemoteTaskInfo taskInfo,
    ExecResult result,
  )? onDetachedTaskCompleted;
  Timer? _heartbeatTimer;
  DateTime _lastTasksBroadcast = DateTime.fromMillisecondsSinceEpoch(0);

  NodeRegistry({
    required this.store,
    this.exposeLocalServerNode = false,
    this.heartbeatPingInterval = const Duration(seconds: 10),
    this.heartbeatLivenessTimeout = const Duration(seconds: 45),
  }) {
    _heartbeatTimer = Timer.periodic(heartbeatPingInterval, (_) {
      _pingAll();
    });
  }

  static const String localServerNodeId = 'server-local';

  bool hasActiveTasksForSession(String sessionId) => _tasks.values.any(
        (t) => t.requestingSessionId == sessionId && t.info.isActive,
      );

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

  /// Called on ANY incoming WebSocket frame (including `node.pong` and `rpc.exec_heartbeat`)
  /// from `peer` so active tasks on that computer know the link is alive.
  void touchPeerHeartbeat(ConnectedPeer peer) {
    final now = DateTime.now().toUtc();
    peer.lastSeen = now;
    final info = peer.nodeInfo;
    if (info == null) return;
    peer.nodeInfo = info.copyWith(lastSeenAt: now.toIso8601String(), online: true);

    for (final task in _tasks.values) {
      if (task.info.nodeId == info.nodeId && task.info.isActive) {
        task.lastHeartbeatClock = now;
        task.info = task.info.copyWith(
          lastHeartbeatAt: now.toIso8601String(),
          heartbeatHealthy: true,
        );
        if (task.info.status == 'running') {
          _armTaskWatchdog(task, heartbeatLivenessTimeout);
        }
      }
    }
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
        final nowIso = DateTime.now().toUtc().toIso8601String();
        final offlineInfo = info.copyWith(
          online: false,
          lastSeenAt: nowIso,
        );
        store.updateNodeMetadata(offlineInfo);

        // Fail any active tasks on this disconnected node immediately
        for (final task in _tasks.values) {
          if (task.info.nodeId == info.nodeId && task.info.isActive) {
            _finalizeTask(
              task,
              ExecResult(
                requestId: task.info.taskId,
                exitCode: -1,
                stdout: task.info.stdoutTail,
                stderr:
                    '${task.info.stderrTail}\nNode "${info.hostname}" disconnected during execution.'
                        .trim(),
                errorMessage: 'Node disconnected',
                durationMs: task.refreshedSnapshot().elapsedMs,
              ),
              overrideStatus: 'lost_heartbeat',
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
        broadcastTasksSnapshot(force: true);
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
          'sessions':
              store.listSessions().map((s) => s.toSummaryJson()).toList(),
        },
      ),
    );
  }

  void broadcastTasksSnapshot({bool force = false}) {
    final now = DateTime.now().toUtc();
    if (!force &&
        now.difference(_lastTasksBroadcast) < const Duration(seconds: 2)) {
      return;
    }
    _lastTasksBroadcast = now;
    broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.tasksSnapshot,
        payload: {
          'tasks': listTasks(includeCompleted: true)
              .take(25)
              .map((t) => t.toJson())
              .toList(),
        },
      ),
    );
  }

  // ---------------- Heartbeat-Backed Remote Execution & Task Inspection ----------------

  List<RemoteTaskInfo> listTasks({
    String? nodeRef,
    bool includeCompleted = true,
  }) {
    String? filterNodeId;
    if (nodeRef != null && nodeRef.trim().isNotEmpty) {
      filterNodeId = resolveNode(nodeRef)?.nodeId ?? nodeRef.trim();
    }
    final items = _tasks.values
        .map((t) => t.refreshedSnapshot())
        .where((info) =>
            (includeCompleted || info.isActive) &&
            (filterNodeId == null || info.nodeId == filterNodeId))
        .toList();
    items.sort((a, b) {
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return b.startedAt.compareTo(a.startedAt);
    });
    return items;
  }

  RemoteTaskInfo? getTaskInfo(String taskId) =>
      _tasks[taskId.trim()]?.refreshedSnapshot();

  ExecResult? getCompletedTaskResult(String taskId) =>
      _tasks[taskId.trim()]?.finalResult;

  /// Starts a remote command backed by continuous client heartbeats and waits up to
  /// `waitSec` for completion. If the command is still running after `waitSec` and
  /// heartbeats are healthy, the process is NOT killed—`completed: false` is returned
  /// with the live `RemoteTaskInfo` (`taskId`, `pid`, `stdoutTail`, `lastHeartbeatAt`)
  /// so the caller can keep waiting via `waitForTask`.
  Future<CommandWaitOutcome> startOrWaitCommand({
    required String nodeRef,
    required String command,
    String? cwd,
    bool elevated = false,
    int waitSec = 90,
    int hardTimeoutSec = 0,
    String? requestingSessionId,
    String? requestingSessionTitle,
  }) async {
    final resolved = resolveNode(nodeRef);
    if (resolved == null) {
      final err = ExecResult(
        requestId: 'none',
        exitCode: -1,
        stdout: '',
        stderr:
            'Unknown target node "$nodeRef". Call mesh_list_nodes to see valid node IDs/hostnames.',
        errorMessage: 'Unknown node',
      );
      final nowIso = DateTime.now().toUtc().toIso8601String();
      return CommandWaitOutcome(
        completed: true,
        result: err,
        taskInfo: RemoteTaskInfo(
          taskId: 'none',
          nodeId: nodeRef,
          nodeHostname: nodeRef,
          command: command,
          status: 'failed',
          startedAt: nowIso,
          lastHeartbeatAt: nowIso,
          heartbeatHealthy: false,
        ),
      );
    }

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final requestId = _uuid.v4();

    if (resolved.nodeId == localServerNodeId && exposeLocalServerNode) {
      final task = _ManagedRemoteTask(
        startedClock: now,
        requestingSessionId: requestingSessionId,
        info: RemoteTaskInfo(
          taskId: requestId,
          nodeId: resolved.nodeId,
          nodeHostname: resolved.hostname,
          command: command,
          cwd: cwd ?? resolved.cwd,
          elevated: elevated,
          sessionTitle: requestingSessionTitle ?? '',
          status: 'running',
          startedAt: nowIso,
          lastHeartbeatAt: nowIso,
          heartbeatHealthy: true,
        ),
      );
      _tasks[requestId] = task;
      _pruneOldCompletedTasks();
      broadcastTasksSnapshot(force: true);
      unawaited(_runLocalManagedCommand(
        task: task,
        command: command,
        cwd: cwd,
        hardTimeoutSec: hardTimeoutSec,
      ));
      final outcome = (await waitForTask(
        requestId,
        waitSec: waitSec,
        isInitialLaunch: true,
      ))!;
      if (!outcome.completed) {
        task.wasDetachedToBackground = true;
      }
      return outcome;
    }

    final peer = _activeNodePeers[resolved.nodeId];
    if (peer == null || !resolved.online) {
      final err = ExecResult(
        requestId: 'none',
        exitCode: -1,
        stdout: '',
        stderr:
            'Target node "${resolved.hostname}" (${resolved.nodeId}) is currently offline.',
        errorMessage: 'Node offline',
      );
      return CommandWaitOutcome(
        completed: true,
        result: err,
        taskInfo: RemoteTaskInfo(
          taskId: 'none',
          nodeId: resolved.nodeId,
          nodeHostname: resolved.hostname,
          command: command,
          status: 'failed',
          startedAt: nowIso,
          lastHeartbeatAt: nowIso,
          heartbeatHealthy: false,
        ),
      );
    }

    final req = ExecRequest(
      requestId: requestId,
      command: command,
      cwd: cwd,
      elevated: elevated,
      timeoutSec: hardTimeoutSec, // 0 = no arbitrary wall-clock kill!
      requestingSessionTitle: requestingSessionTitle,
    );

    final managed = _ManagedRemoteTask(
      startedClock: now,
      requestingSessionId: requestingSessionId,
      info: RemoteTaskInfo(
        taskId: requestId,
        nodeId: resolved.nodeId,
        nodeHostname: resolved.hostname,
        command: command,
        cwd: cwd ?? resolved.cwd,
        elevated: elevated,
        sessionTitle: requestingSessionTitle ?? '',
        status: 'running',
        startedAt: nowIso,
        lastHeartbeatAt: nowIso,
        heartbeatHealthy: true,
      ),
    );
    _tasks[requestId] = managed;
    _pruneOldCompletedTasks();
    _armTaskWatchdog(managed, heartbeatLivenessTimeout);
    broadcastTasksSnapshot(force: true);

    peer.send(WsEnvelope(
      type: WsTypes.rpcExec,
      id: requestId,
      payload: req.toJson(),
    ));

    final outcome = (await waitForTask(
      requestId,
      waitSec: waitSec,
      isInitialLaunch: true,
    ))!;
    if (!outcome.completed) {
      managed.wasDetachedToBackground = true;
    }
    return outcome;
  }

  /// Waits up to `waitSec` for an existing task to finish, or returns its live
  /// heartbeat & output status immediately if `waitSec <= 0` or if still running
  /// after `waitSec`. Returns `null` if `taskId` is unknown.
  Future<CommandWaitOutcome?> waitForTask(
    String taskId, {
    int waitSec = 90,
    bool isInitialLaunch = false,
  }) async {
    final managed = _tasks[taskId.trim()];
    if (managed == null) return null;

    if (managed.finalResult != null || managed.completer.isCompleted) {
      if (!isInitialLaunch) {
        managed.wasConsumedByWaitForTask = true;
      }
      final res = managed.finalResult ?? await managed.completer.future;
      return CommandWaitOutcome(
        completed: true,
        result: res,
        taskInfo: managed.refreshedSnapshot(),
      );
    }

    if (waitSec <= 0) {
      return CommandWaitOutcome(
        completed: false,
        taskInfo: managed.refreshedSnapshot(),
      );
    }

    // Also proactively ping the target peer so even legacy/busy clients confirm liveness
    final peer = _activeNodePeers[managed.info.nodeId];
    peer?.send(const WsEnvelope(type: WsTypes.nodePing));

    await Future.any<Object?>([
      managed.completer.future,
      Future<void>.delayed(Duration(seconds: waitSec)),
    ]);

    if (managed.finalResult != null || managed.completer.isCompleted) {
      if (!isInitialLaunch) {
        managed.wasConsumedByWaitForTask = true;
      }
      final res = managed.finalResult ?? await managed.completer.future;
      return CommandWaitOutcome(
        completed: true,
        result: res,
        taskInfo: managed.refreshedSnapshot(),
      );
    }

    return CommandWaitOutcome(
      completed: false,
      taskInfo: managed.refreshedSnapshot(),
    );
  }

  /// Convenience wrapper awaiting completion (with optional hard timeout).
  Future<ExecResult> executeCommand({
    required String nodeRef,
    required String command,
    String? cwd,
    bool elevated = false,
    int timeoutSec = 0,
    String? requestingSessionTitle,
  }) async {
    final outcome = await startOrWaitCommand(
      nodeRef: nodeRef,
      command: command,
      cwd: cwd,
      elevated: elevated,
      waitSec: timeoutSec > 0 ? timeoutSec + 15 : 86400,
      hardTimeoutSec: timeoutSec,
      requestingSessionTitle: requestingSessionTitle,
    );
    if (outcome.completed && outcome.result != null) {
      return outcome.result!;
    }
    return ExecResult(
      requestId: outcome.taskInfo.taskId,
      exitCode: 124,
      stdout: outcome.taskInfo.stdoutTail,
      stderr:
          'Command exceeded wait window on "${outcome.taskInfo.nodeHostname}".',
      errorMessage: 'Timeout',
      durationMs: outcome.taskInfo.elapsedMs,
    );
  }

  bool killTask(String taskId) {
    final managed = _tasks[taskId.trim()];
    if (managed == null || !managed.info.isActive) return false;

    if (managed.localProcess != null) {
      try {
        managed.localProcess!.kill(ProcessSignal.sigterm);
      } catch (_) {}
    } else {
      final peer = _activeNodePeers[managed.info.nodeId];
      peer?.send(WsEnvelope(
        type: WsTypes.rpcTaskKill,
        id: managed.info.taskId,
        payload: {'requestId': managed.info.taskId},
      ));
    }

    // If the client doesn't send rpc.exec_result within 5s of kill, finalize locally
    Timer(const Duration(seconds: 5), () {
      if (managed.info.isActive) {
        _finalizeTask(
          managed,
          ExecResult(
            requestId: managed.info.taskId,
            exitCode: 137,
            stdout: managed.info.stdoutTail,
            stderr:
                '${managed.info.stderrTail}\nProcess terminated via mesh_kill_task.'
                    .trim(),
            errorMessage: 'Killed',
            durationMs: managed.refreshedSnapshot().elapsedMs,
          ),
          overrideStatus: 'killed',
        );
      }
    });
    return true;
  }

  void _armTaskWatchdog(_ManagedRemoteTask task, Duration window) {
    task.cancelWatchdog();
    task.livenessWatchdog = Timer(window, () {
      if (!task.info.isActive) return;
      _finalizeTask(
        task,
        ExecResult(
          requestId: task.info.taskId,
          exitCode: 125,
          stdout: task.info.stdoutTail,
          stderr:
              '${task.info.stderrTail}\nLost heartbeat from "${task.info.nodeHostname}" for ${window.inSeconds}s while waiting for command.'
                  .trim(),
          errorMessage: 'Heartbeat lost',
          durationMs: task.refreshedSnapshot().elapsedMs,
        ),
        overrideStatus: 'lost_heartbeat',
      );
    });
  }

  void handleExecHeartbeat(Map<String, dynamic> payload) {
    final hb = ExecHeartbeat.fromJson(payload);
    final task = _tasks[hb.requestId];
    if (task == null || !task.info.isActive) return;

    final now = DateTime.now().toUtc();
    task.lastHeartbeatClock = now;
    task.info = task.info.copyWith(
      status: 'running',
      pid: hb.pid ?? task.info.pid,
      lastHeartbeatAt: now.toIso8601String(),
      elapsedMs: hb.elapsedMs > 0
          ? hb.elapsedMs
          : now.difference(task.startedClock).inMilliseconds,
      stdoutTail: hb.stdoutTail.isNotEmpty ? hb.stdoutTail : task.info.stdoutTail,
      stderrTail: hb.stderrTail.isNotEmpty ? hb.stderrTail : task.info.stderrTail,
      heartbeatHealthy: hb.alive,
    );
    _armTaskWatchdog(task, heartbeatLivenessTimeout);
    broadcastTasksSnapshot(force: false);
  }

  void handleExecAwaitingApproval(String nodeId, String requestId) {
    final task = _tasks[requestId];
    if (task != null && task.info.isActive) {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      task.info = task.info.copyWith(
        status: 'awaiting_approval',
        lastHeartbeatAt: nowIso,
        heartbeatHealthy: true,
      );
      // Allow up to 10 minutes for human approval on the target device
      _armTaskWatchdog(task, const Duration(minutes: 10));
      onNodeAwaitingApproval?.call(nodeId, requestId);
      broadcastTasksSnapshot(force: true);
    }
  }

  void handleExecResult(Map<String, dynamic> payload) {
    final res = ExecResult.fromJson(payload);
    final task = _tasks[res.requestId];
    if (task != null) {
      _finalizeTask(task, res);
    }
  }

  void _finalizeTask(
    _ManagedRemoteTask task,
    ExecResult res, {
    String? overrideStatus,
  }) {
    task.cancelWatchdog();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final tailOut = res.stdout.length > 2000
        ? res.stdout.substring(res.stdout.length - 2000)
        : res.stdout;
    final tailErr = res.stderr.length > 1000
        ? res.stderr.substring(res.stderr.length - 1000)
        : res.stderr;

    final nextStatus = overrideStatus ??
        ((res.exitCode == 0 && res.approved && res.errorMessage == null)
            ? 'completed'
            : (res.exitCode == 137 ? 'killed' : 'failed'));

    task.finalResult = res;
    task.info = task.info.copyWith(
      status: nextStatus,
      lastHeartbeatAt: nowIso,
      completedAt: nowIso,
      elapsedMs: res.durationMs > 0
          ? res.durationMs
          : task.refreshedSnapshot().elapsedMs,
      exitCode: res.exitCode,
      stdoutTail: tailOut,
      stderrTail: tailErr,
      heartbeatHealthy: nextStatus == 'completed',
    );
    if (!task.completer.isCompleted) {
      task.completer.complete(res);
    }
    broadcastTasksSnapshot(force: true);

    // Event-driven async server wakeup: if this task detached into background for a
    // session and was not already consumed synchronously via waitForTask, trigger
    // the Brain callback once the event loop settles.
    final sessId = task.requestingSessionId;
    if (sessId != null &&
        sessId.isNotEmpty &&
        onDetachedTaskCompleted != null) {
      Timer(const Duration(milliseconds: 350), () {
        if (task.wasDetachedToBackground && !task.wasConsumedByWaitForTask) {
          onDetachedTaskCompleted?.call(sessId, task.info, res);
        }
      });
    }
  }

  void _pruneOldCompletedTasks() {
    final completedEntries = _tasks.entries
        .where((e) => !e.value.info.isActive)
        .toList()
      ..sort((a, b) => a.value.info.startedAt.compareTo(b.value.info.startedAt));
    while (completedEntries.length > 40) {
      final oldest = completedEntries.removeAt(0);
      _tasks.remove(oldest.key);
    }
  }

  Future<void> _runLocalManagedCommand({
    required _ManagedRemoteTask task,
    required String command,
    String? cwd,
    required int hardTimeoutSec,
  }) async {
    final sw = Stopwatch()..start();
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    Timer? hbTimer;

    try {
      final proc = await Process.start(
        Platform.isWindows ? 'powershell.exe' : 'bash',
        Platform.isWindows
            ? ['-NoProfile', '-NonInteractive', '-Command', command]
            : ['-c', command],
        workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
      );
      task.localProcess = proc;
      task.info = task.info.copyWith(pid: proc.pid);

      final outDone = Completer<void>();
      final errDone = Completer<void>();
      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) => outBuf.write(chunk),
        onDone: () => outDone.complete(),
        onError: (_) {
          if (!outDone.isCompleted) outDone.complete();
        },
      );
      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) => errBuf.write(chunk),
        onDone: () => errDone.complete(),
        onError: (_) {
          if (!errDone.isCompleted) errDone.complete();
        },
      );

      hbTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final sOut = outBuf.toString();
        final sErr = errBuf.toString();
        task.info = task.info.copyWith(
          lastHeartbeatAt: DateTime.now().toUtc().toIso8601String(),
          elapsedMs: sw.elapsedMilliseconds,
          stdoutTail:
              sOut.length > 2000 ? sOut.substring(sOut.length - 2000) : sOut,
          stderrTail:
              sErr.length > 1000 ? sErr.substring(sErr.length - 1000) : sErr,
          heartbeatHealthy: true,
        );
        broadcastTasksSnapshot(force: false);
      });

      int exitCode;
      if (hardTimeoutSec > 0) {
        exitCode = await proc.exitCode.timeout(
          Duration(seconds: hardTimeoutSec),
          onTimeout: () {
            proc.kill(ProcessSignal.sigterm);
            throw TimeoutException('Hard timeout reached');
          },
        );
      } else {
        exitCode = await proc.exitCode;
      }
      await Future.wait([outDone.future, errDone.future]);
      sw.stop();
      hbTimer.cancel();

      _finalizeTask(
        task,
        ExecResult(
          requestId: task.info.taskId,
          exitCode: exitCode,
          stdout: outBuf.toString(),
          stderr: errBuf.toString(),
          durationMs: sw.elapsedMilliseconds,
        ),
      );
    } on TimeoutException {
      sw.stop();
      hbTimer?.cancel();
      _finalizeTask(
        task,
        ExecResult(
          requestId: task.info.taskId,
          exitCode: 124,
          stdout: outBuf.toString(),
          stderr:
              '${errBuf.toString()}\nCommand reached explicit hard_timeout_sec (${hardTimeoutSec}s).'
                  .trim(),
          errorMessage: 'Hard timeout',
          durationMs: sw.elapsedMilliseconds,
        ),
      );
    } catch (e) {
      sw.stop();
      hbTimer?.cancel();
      _finalizeTask(
        task,
        ExecResult(
          requestId: task.info.taskId,
          exitCode: -1,
          stdout: outBuf.toString(),
          stderr: e.toString(),
          errorMessage: e.toString(),
          durationMs: sw.elapsedMilliseconds,
        ),
      );
    }
  }

  // ---------------- Remote File Operations ----------------

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
        error:
            'Target node "${resolved.hostname}" (${resolved.nodeId}) is currently offline.',
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
    );
    _pendingFileOps[requestId] = pending;
    pending.armTimeout(const Duration(seconds: 60));

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
          final e = (endLine ?? lines.length)
              .clamp(s, lines.isEmpty ? 1 : lines.length);
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
    for (final task in _tasks.values) {
      task.cancelWatchdog();
    }
    _tasks.clear();
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
