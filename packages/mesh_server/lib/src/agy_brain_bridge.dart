import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:uuid/uuid.dart';

import 'brain_diagnostics.dart';
import 'mcp_http_handler.dart';
import 'node_registry.dart';
import 'pairing_store.dart';

class AgyBrainBridge {
  final PairingAndSessionStore store;
  final NodeRegistry registry;
  final BrainDiagnosticsService diagnostics;
  final String agyExecutable;
  final String mcpServerName;
  final bool skipAllAgyPermissions;
  final _uuid = const Uuid();

  /// Concurrent running `agy` processes keyed by `sessionId`.
  final Map<String, Process> _activeProcesses = {};
  final Map<String, String> _activeAssistantMsgIds = {};
  final Map<String, List<String>> _queuedWakeupPrompts = {};

  AgyBrainBridge({
    required this.store,
    required this.registry,
    required this.diagnostics,
    this.agyExecutable = 'agy',
    this.mcpServerName = 'lan-mesh',
    this.skipAllAgyPermissions = false,
  });

  bool isSessionRunning(String sessionId) =>
      _activeProcesses.containsKey(sessionId);

  List<String> get runningSessionIds => _activeProcesses.keys.toList();

  /// Attaches live MCP tool call events onto the streaming assistant message of `sessionId`.
  void recordToolActivity(String? sessionId, ToolCallSummary event) {
    if (sessionId == null || sessionId.isEmpty) return;
    final msgId = _activeAssistantMsgIds[sessionId];
    if (msgId != null) {
      store.updateMessage(sessionId, msgId, (msg) {
        final idx = msg.toolEvents.indexWhere((t) => t.id == event.id);
        final nextEvents = [...msg.toolEvents];
        if (idx >= 0) {
          nextEvents[idx] = event;
        } else {
          nextEvents.add(event);
        }
        return msg.copyWith(toolEvents: nextEvents);
      });
    }
    registry.broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.chatEvent,
        payload: {
          'sessionId': sessionId,
          'kind': 'tool_event',
          'toolEvent': event.toJson(),
        },
      ),
    );
  }

  /// Marks any session waiting on an approval gate so Server & Client UIs highlight it.
  void notifyNodeAwaitingApproval(String nodeId) {
    for (final s in store.listSessions()) {
      if (s.status == SessionStatuses.running &&
          (s.targetNodeId == nodeId || s.targetNodeId == '*')) {
        store.updateSessionMeta(
          s.sessionId,
          status: SessionStatuses.awaitingApproval,
        );
        registry.broadcastSessionsSnapshot();
      }
    }
  }

  Future<bool> cancelSessionTurn(String sessionId) async {
    final proc = _activeProcesses.remove(sessionId);
    _activeAssistantMsgIds.remove(sessionId);
    if (proc == null) return false;
    proc.kill(ProcessSignal.sigterm);
    store.updateSessionMeta(sessionId, status: SessionStatuses.idle);
    registry.broadcastSessionsSnapshot();
    registry.broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.chatEvent,
        payload: {
          'sessionId': sessionId,
          'kind': 'cancelled',
        },
      ),
    );
    return true;
  }

  Future<void> runPromptTurn({
    required String sessionId,
    required String userPrompt,
    String? senderNodeId,
  }) async {
    final session = store.getSession(sessionId);
    if (session == null) return;

    if (_activeProcesses.containsKey(sessionId)) {
      registry.broadcastToAuthenticated(
        WsEnvelope(
          type: WsTypes.chatEvent,
          payload: {
            'sessionId': sessionId,
            'kind': 'error',
            'error':
                'Session "${session.title}" already has a turn running. Cancel it first or open another session.',
          },
        ),
      );
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final userMsg = SessionMessage(
      id: _uuid.v4(),
      role: 'user',
      text: userPrompt,
      timestamp: now,
      status: 'done',
    );
    final assistantMsgId = _uuid.v4();
    final assistantMsg = SessionMessage(
      id: assistantMsgId,
      role: 'assistant',
      text: '',
      thinking: '',
      timestamp: DateTime.now().toUtc().toIso8601String(),
      status: 'streaming',
    );

    store.appendMessage(sessionId, userMsg);
    final updatedSession = store.appendMessage(sessionId, assistantMsg)!;
    store.updateSessionMeta(sessionId, status: SessionStatuses.running);
    _activeAssistantMsgIds[sessionId] = assistantMsgId;

    registry.broadcastSessionsSnapshot();
    registry.broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.sessionDetail,
        payload: {
          'session': store.getSession(sessionId)!.toJson(),
        },
      ),
    );

    final contextualized = _buildContextualizedPrompt(
      session: updatedSession,
      userPrompt: userPrompt,
      senderNodeId: senderNodeId,
    );

    final allowedGrants = McpHttpHandler.allToolNames
        .map((t) => 'mcp($mcpServerName/$t)')
        .toList();

    final cliArgs = <String>[
      '-p',
      contextualized,
      '--output-format',
      'stream-json',
      if (diagnostics.selectedModelOverride.isNotEmpty) ...[
        '--model',
        diagnostics.selectedModelOverride,
      ],
      if (updatedSession.agyConversationId != null &&
          updatedSession.agyConversationId!.isNotEmpty) ...[
        '--conversation',
        updatedSession.agyConversationId!,
      ],
      if (skipAllAgyPermissions)
        '--dangerously-skip-permissions'
      else ...[
        '--settings',
        jsonEncode({
          'permissions': {'allow': allowedGrants},
        }),
      ],
    ];

    try {
      final proc = await Process.start(
        agyExecutable,
        cliArgs,
        runInShell: Platform.isWindows,
      );
      _activeProcesses[sessionId] = proc;

      final stderrBuf = StringBuffer();
      proc.stderr.transform(utf8.decoder).listen((chunk) {
        stderrBuf.write(chunk);
      });

      var accumulatedText = '';
      var accumulatedThinking = '';
      String? discoveredConvId = updatedSession.agyConversationId;

      await for (final line in proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        Map<String, dynamic> eventObj;
        try {
          eventObj = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final eventType = eventObj['event'] as String? ?? '';
        if (eventType == 'init') {
          final cid = eventObj['conversation_id'] as String?;
          if (cid != null && cid.isNotEmpty && cid != discoveredConvId) {
            discoveredConvId = cid;
            store.updateSessionMeta(sessionId, agyConversationId: cid);
          }
        } else if (eventType == 'step_update') {
          final su = eventObj['step_update'] as Map<String, dynamic>? ?? {};
          final cid = su['conversation_id'] as String?;
          if (cid != null && cid.isNotEmpty && cid != discoveredConvId) {
            discoveredConvId = cid;
            store.updateSessionMeta(sessionId, agyConversationId: cid);
          }

          final thoughtDelta = (su['thought_delta'] as String?) ??
              (su['thinking_delta'] as String?) ??
              '';
          final textDelta = su['text_delta'] as String? ?? '';

          if (thoughtDelta.isNotEmpty) {
            accumulatedThinking += thoughtDelta;
            store.updateMessage(
              sessionId,
              assistantMsgId,
              (m) => m.copyWith(thinking: accumulatedThinking),
            );
            registry.broadcastToAuthenticated(
              WsEnvelope(
                type: WsTypes.chatEvent,
                payload: {
                  'sessionId': sessionId,
                  'messageId': assistantMsgId,
                  'kind': 'thinking_delta',
                  'delta': thoughtDelta,
                },
              ),
            );
          }

          if (textDelta.isNotEmpty) {
            accumulatedText += textDelta;
            store.updateMessage(
              sessionId,
              assistantMsgId,
              (m) => m.copyWith(text: accumulatedText),
            );
            registry.broadcastToAuthenticated(
              WsEnvelope(
                type: WsTypes.chatEvent,
                payload: {
                  'sessionId': sessionId,
                  'messageId': assistantMsgId,
                  'kind': 'text_delta',
                  'delta': textDelta,
                },
              ),
            );
          }
        } else if (eventType == 'result') {
          final res = eventObj['result'] as Map<String, dynamic>? ?? {};
          final cid = res['conversation_id'] as String?;
          if (cid != null && cid.isNotEmpty) {
            discoveredConvId = cid;
            store.updateSessionMeta(sessionId, agyConversationId: cid);
          }
          final usage = res['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            diagnostics.recordTurnUsage(
              inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
              outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
              thinkingTokens: (usage['thinking_tokens'] as num?)?.toInt() ?? 0,
            );
          }
          final fullResp = res['response'] as String? ?? '';
          if (accumulatedText.trim().isEmpty && fullResp.isNotEmpty) {
            accumulatedText = fullResp;
          }
        }
      }

      final exitCode = await proc.exitCode;
      _activeProcesses.remove(sessionId);
      _activeAssistantMsgIds.remove(sessionId);

      if (exitCode != 0 && accumulatedText.trim().isEmpty) {
        final errText = stderrBuf.toString().trim().isNotEmpty
            ? stderrBuf.toString().trim()
            : 'agy exited with code $exitCode';
        store.updateMessage(
          sessionId,
          assistantMsgId,
          (m) => m.copyWith(
            text: '⚠️ Brain execution error:\n```\n$errText\n```',
            status: 'error',
          ),
        );
        store.updateSessionMeta(sessionId, status: SessionStatuses.error);
      } else {
        store.updateMessage(
          sessionId,
          assistantMsgId,
          (m) => m.copyWith(
            text: accumulatedText.isEmpty ? '(Completed)' : accumulatedText,
            status: 'done',
          ),
        );
        store.updateSessionMeta(sessionId, status: SessionStatuses.idle);
      }
    } catch (e) {
      _activeProcesses.remove(sessionId);
      _activeAssistantMsgIds.remove(sessionId);
      store.updateMessage(
        sessionId,
        assistantMsgId,
        (m) => m.copyWith(
          text: '⚠️ Failed to launch `$agyExecutable`: $e',
          status: 'error',
        ),
      );
      store.updateSessionMeta(sessionId, status: SessionStatuses.error);
    }

    registry.broadcastSessionsSnapshot();
    final finalSession = store.getSession(sessionId);
    if (finalSession != null) {
      registry.broadcastToAuthenticated(
        WsEnvelope(
          type: WsTypes.sessionDetail,
          payload: {'session': finalSession.toJson()},
        ),
      );
    }

    // Drain any queued async remote-command completion events for this session
    final queued = _queuedWakeupPrompts.remove(sessionId);
    if (queued != null && queued.isNotEmpty) {
      final combined = queued.join('\n\n');
      unawaited(runPromptTurn(
        sessionId: sessionId,
        userPrompt: combined,
      ));
    }
  }

  /// Automatically triggered by `NodeRegistry` when a detached/async remote task
  /// finishes on a client computer. Resumes the session's Brain turn reactively!
  void handleAsyncTaskCompletion(
    String sessionId,
    RemoteTaskInfo taskInfo,
    ExecResult res,
  ) {
    final session = store.getSession(sessionId);
    if (session == null) return;

    final outTrim = res.stdout.length > 8000
        ? '...[truncated]...\n${res.stdout.substring(res.stdout.length - 8000)}'
        : res.stdout;
    final errTrim = res.stderr.length > 4000
        ? '...[truncated]...\n${res.stderr.substring(res.stderr.length - 4000)}'
        : res.stderr;

    final buf = StringBuffer()
      ..writeln('🔔 [ASYNC REMOTE COMMAND COMPLETED]')
      ..writeln('- Task ID  : ${taskInfo.taskId}')
      ..writeln('- Computer : ${taskInfo.nodeHostname} (${taskInfo.nodeId})')
      ..writeln('- Command  : ${taskInfo.command}')
      ..writeln('- Exit Code: ${res.exitCode} (${(res.durationMs / 1000.0).toStringAsFixed(1)}s)');
    if (outTrim.trim().isNotEmpty) {
      buf.writeln('--- STDOUT ---\n$outTrim');
    }
    if (errTrim.trim().isNotEmpty) {
      buf.writeln('--- STDERR ---\n$errTrim');
    }
    buf.writeln(
      '\nReview the completed async command output above and continue the task or summarize the outcome for the user.',
    );

    final wakeupText = buf.toString();
    if (isSessionRunning(sessionId)) {
      _queuedWakeupPrompts.putIfAbsent(sessionId, () => []).add(wakeupText);
    } else {
      unawaited(runPromptTurn(
        sessionId: sessionId,
        userPrompt: wakeupText,
      ));
    }
  }

  String _buildContextualizedPrompt({
    required MeshSession session,
    required String userPrompt,
    String? senderNodeId,
  }) {
    final targetNode = session.targetNodeId == '*'
        ? null
        : registry.resolveNode(session.targetNodeId);
    final buf = StringBuffer()
      ..writeln('[AGY LAN Mesh Session Context]')
      ..writeln('- session_id: "${session.sessionId}"')
      ..writeln('- project_title: "${session.title}"');

    if (targetNode != null) {
      buf
        ..writeln(
            '- target_computer: "${targetNode.hostname}" (nodeId: "${targetNode.nodeId}", OS: ${targetNode.os}, privilege: ${targetNode.privilegeLevel}, online: ${targetNode.online})')
        ..writeln(
            '- remote_workspace_path: "${session.workspacePath.isNotEmpty ? session.workspacePath : targetNode.cwd}"');
    } else {
      buf.writeln(
          '- target_computer: Fleet-Wide ("*") — call mesh_list_nodes to inspect available machines.');
      if (session.workspacePath.isNotEmpty) {
        buf.writeln('- remote_workspace_path: "${session.workspacePath}"');
      }
    }
    if (senderNodeId != null && senderNodeId.isNotEmpty) {
      buf.writeln('- prompt_issued_from_node: "$senderNodeId"');
    }
    buf
      ..writeln(
          '- Instructions: Always pass session_id="${session.sessionId}" when calling $mcpServerName MCP tools (mesh_exec, mesh_task_status, mesh_list_tasks, mesh_kill_task, mesh_read_file, mesh_write_file, mesh_edit_file, mesh_list_dir) so paths resolve relative to remote_workspace_path and live tool progress streams to this session. Do NOT run local commands on the Brain host unless explicitly asked; operate on target_computer via MCP tools.')
      ..writeln(
          '- Long-Running & Async Commands: Remote commands in mesh_exec are backed by continuous 5s client heartbeats and are NEVER killed at 180s. For long tasks (builds, installs, tests), you can EITHER pass background=true to mesh_exec and end your turn (the server will automatically wake this session up when the client finishes the command!), OR call mesh_task_status(task_id=..., wait_sec=90) to wait while heartbeats stay healthy.')
      ..writeln('[/AGY LAN Mesh Session Context]')
      ..writeln()
      ..write(userPrompt);
    return buf.toString();
  }

  void dispose() {
    for (final proc in _activeProcesses.values) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    _activeProcesses.clear();
  }
}
