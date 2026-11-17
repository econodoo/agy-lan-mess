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
  static const String summaryOpenTag = '<session_summary>';
  static const String summaryCloseTag = '</session_summary>';

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

    final turnSw = Stopwatch()..start();
    var turnInputTokens = 0;
    var turnOutputTokens = 0;
    var turnThinkingTokens = 0;

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
      var emittedVisibleLength = 0;
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
            final safeLen = computeSafeStreamingLength(accumulatedText);
            if (safeLen > emittedVisibleLength) {
              final visibleDelta =
                  accumulatedText.substring(emittedVisibleLength, safeLen);
              emittedVisibleLength = safeLen;
              final visibleSoFar = accumulatedText.substring(0, safeLen);
              store.updateMessage(
                sessionId,
                assistantMsgId,
                (m) => m.copyWith(text: visibleSoFar),
              );
              registry.broadcastToAuthenticated(
                WsEnvelope(
                  type: WsTypes.chatEvent,
                  payload: {
                    'sessionId': sessionId,
                    'messageId': assistantMsgId,
                    'kind': 'text_delta',
                    'delta': visibleDelta,
                  },
                ),
              );
            }
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
            turnInputTokens = (usage['input_tokens'] as num?)?.toInt() ?? 0;
            turnOutputTokens = (usage['output_tokens'] as num?)?.toInt() ?? 0;
            turnThinkingTokens =
                (usage['thinking_tokens'] as num?)?.toInt() ?? 0;
            diagnostics.recordTurnUsage(
              inputTokens: turnInputTokens,
              outputTokens: turnOutputTokens,
              thinkingTokens: turnThinkingTokens,
            );
          }
          final fullResp = res['response'] as String? ?? '';
          if (accumulatedText.trim().isEmpty && fullResp.isNotEmpty) {
            accumulatedText = fullResp;
          }
        }
      }

      final exitCode = await proc.exitCode;
      turnSw.stop();
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
            durationMs: turnSw.elapsedMilliseconds,
          ),
        );
        store.updateSessionMeta(sessionId, status: SessionStatuses.error);
      } else {
        final extracted = extractSummaryBlock(accumulatedText);
        final cleanVisible = extracted.cleanText;
        final modelLabel = _effectiveModelLabel();

        store.updateMessage(
          sessionId,
          assistantMsgId,
          (m) => m.copyWith(
            text: cleanVisible.isEmpty ? '(Completed)' : cleanVisible,
            status: 'done',
            durationMs: turnSw.elapsedMilliseconds,
            inputTokens: turnInputTokens,
            outputTokens: turnOutputTokens,
            thinkingTokens: turnThinkingTokens,
            modelLabel: modelLabel,
          ),
        );
        store.updateSessionMeta(sessionId, status: SessionStatuses.idle);

        final hasPendingAsyncWork =
            registry.hasActiveTasksForSession(sessionId) ||
                (_queuedWakeupPrompts[sessionId]?.isNotEmpty ?? false);

        if (!hasPendingAsyncWork) {
          final currentSession = store.getSession(sessionId);
          final latestAssistantMsg = currentSession?.messages
              .where((m) => m.id == assistantMsgId)
              .firstOrNull;
          final hadTools = latestAssistantMsg != null &&
              latestAssistantMsg.toolEvents.isNotEmpty;

          if (currentSession != null &&
              (extracted.parsedSummary != null || hadTools)) {
            final summaryFields = extracted.parsedSummary ??
                synthesizeFallbackSummary(currentSession);
            _attachAndBroadcastSessionSummary(
              sessionId: sessionId,
              summaryFields: summaryFields,
            );
          }
        }
      }
    } catch (e) {
      turnSw.stop();
      _activeProcesses.remove(sessionId);
      _activeAssistantMsgIds.remove(sessionId);
      store.updateMessage(
        sessionId,
        assistantMsgId,
        (m) => m.copyWith(
          text: '⚠️ Failed to launch `$agyExecutable`: $e',
          status: 'error',
          durationMs: turnSw.elapsedMilliseconds,
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
    if (diagnostics.cachedStatus != null) {
      unawaited(diagnostics.inspect().then((st) {
        registry.broadcastToAuthenticated(
          WsEnvelope(type: WsTypes.brainStatus, payload: st.toJson()),
        );
      }));
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

  /// Generates or refreshes the screenshot-ready Session Completion Summary card on demand
  /// without adding a noisy user prompt bubble to the conversation.
  Future<SessionCompletionSummary?> summarizeSession(String sessionId) async {
    final session = store.getSession(sessionId);
    if (session == null || session.messages.isEmpty) return null;
    if (_activeProcesses.containsKey(sessionId)) return null;

    store.updateSessionMeta(sessionId, status: SessionStatuses.running);
    registry.broadcastSessionsSnapshot();

    Map<String, String>? parsed;
    var extraDurationMs = 0;
    var extraIn = 0;
    var extraOut = 0;
    var extraThink = 0;

    final wrapSw = Stopwatch()..start();
    try {
      final wrapPrompt = _buildOnDemandSummaryPrompt(session);
      final cliArgs = <String>[
        '-p',
        wrapPrompt,
        '--output-format',
        'stream-json',
        if (diagnostics.selectedModelOverride.isNotEmpty) ...[
          '--model',
          diagnostics.selectedModelOverride,
        ],
        if (session.agyConversationId != null &&
            session.agyConversationId!.isNotEmpty) ...[
          '--conversation',
          session.agyConversationId!,
        ],
      ];

      final proc = await Process.start(
        agyExecutable,
        cliArgs,
        runInShell: Platform.isWindows,
      );
      _activeProcesses[sessionId] = proc;

      var rawOut = '';
      await for (final line in proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final ev = obj['event'] as String? ?? '';
          if (ev == 'step_update') {
            final su = obj['step_update'] as Map<String, dynamic>? ?? {};
            rawOut += su['text_delta'] as String? ?? '';
          } else if (ev == 'result') {
            final res = obj['result'] as Map<String, dynamic>? ?? {};
            final usage = res['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              extraIn = (usage['input_tokens'] as num?)?.toInt() ?? 0;
              extraOut = (usage['output_tokens'] as num?)?.toInt() ?? 0;
              extraThink = (usage['thinking_tokens'] as num?)?.toInt() ?? 0;
              diagnostics.recordTurnUsage(
                inputTokens: extraIn,
                outputTokens: extraOut,
                thinkingTokens: extraThink,
              );
            }
            final fullResp = res['response'] as String? ?? '';
            if (rawOut.trim().isEmpty && fullResp.isNotEmpty) {
              rawOut = fullResp;
            }
          }
        } catch (_) {}
      }
      await proc.exitCode;
      wrapSw.stop();
      extraDurationMs = wrapSw.elapsedMilliseconds;
      _activeProcesses.remove(sessionId);

      parsed = extractSummaryBlock(rawOut).parsedSummary ??
          tryParseLooseSummaryText(rawOut);
    } catch (_) {
      wrapSw.stop();
      _activeProcesses.remove(sessionId);
    }

    store.updateSessionMeta(sessionId, status: SessionStatuses.idle);
    final latest = store.getSession(sessionId);
    if (latest == null) return null;

    final fields = parsed ?? synthesizeFallbackSummary(latest);
    final summary = _attachAndBroadcastSessionSummary(
      sessionId: sessionId,
      summaryFields: fields,
      extraDurationMs: extraDurationMs,
      extraInputTokens: extraIn,
      extraOutputTokens: extraOut,
      extraThinkingTokens: extraThink,
    );

    registry.broadcastSessionsSnapshot();
    final updatedSession = store.getSession(sessionId);
    if (updatedSession != null) {
      registry.broadcastToAuthenticated(
        WsEnvelope(
          type: WsTypes.sessionDetail,
          payload: {'session': updatedSession.toJson()},
        ),
      );
    }
    return summary;
  }

  SessionCompletionSummary _attachAndBroadcastSessionSummary({
    required String sessionId,
    required Map<String, String> summaryFields,
    int extraDurationMs = 0,
    int extraInputTokens = 0,
    int extraOutputTokens = 0,
    int extraThinkingTokens = 0,
  }) {
    final current = store.getSession(sessionId)!;
    final nowUtc = DateTime.now().toUtc();
    final activeMs = current.totalActiveDurationMs + extraDurationMs;
    final createdDt = DateTime.tryParse(current.createdAt);
    final rawSpanMs =
        createdDt != null ? nowUtc.difference(createdDt).inMilliseconds : activeMs;
    final spanMs = rawSpanMs > activeMs ? rawSpanMs : activeMs;

    final summary = SessionCompletionSummary(
      issue: summaryFields['issue'] ?? 'Task execution in "${current.title}"',
      findings: summaryFields['findings'] ??
          'Inspected workspace and target environment.',
      actionsTaken: summaryFields['what_we_did'] ??
          'Completed requested operations and verified results.',
      activeDurationMs: activeMs,
      sessionSpanMs: spanMs,
      turnsCount: current.totalTurns > 0 ? current.totalTurns : 1,
      toolCallsCount: current.totalToolCalls,
      inputTokens: current.totalInputTokens + extraInputTokens,
      outputTokens: current.totalOutputTokens + extraOutputTokens,
      thinkingTokens: current.totalThinkingTokens + extraThinkingTokens,
      modelLabel: _effectiveModelLabel(),
      targetNodeName: current.targetNodeName.isNotEmpty
          ? current.targetNodeName
          : current.targetNodeId,
      workspacePath: current.workspacePath,
      generatedAt: nowUtc.toIso8601String(),
    );

    final summaryMsg = SessionMessage(
      id: _uuid.v4(),
      role: 'summary',
      text: summary.toMarkdown(sessionTitle: current.title),
      timestamp: nowUtc.toIso8601String(),
      status: 'done',
      completionSummary: summary,
    );

    store.upsertSessionSummaryMessage(sessionId, summaryMsg);
    registry.broadcastToAuthenticated(
      WsEnvelope(
        type: WsTypes.chatEvent,
        payload: {
          'sessionId': sessionId,
          'kind': 'session_summary',
          'summary': summary.toJson(),
        },
      ),
    );
    return summary;
  }

  String _effectiveModelLabel() {
    final st = diagnostics.cachedStatus;
    if (st != null && st.effectiveModelDisplay.isNotEmpty) {
      return st.effectiveModelDisplay;
    }
    if (diagnostics.selectedModelOverride.isNotEmpty) {
      return diagnostics.selectedModelOverride;
    }
    return 'Antigravity Brain';
  }

  static int computeSafeStreamingLength(String full) {
    final openIdx = full.indexOf(summaryOpenTag);
    if (openIdx >= 0) return openIdx;
    final maxPrefix = full.length < summaryOpenTag.length - 1
        ? full.length
        : summaryOpenTag.length - 1;
    for (var len = maxPrefix; len >= 1; len--) {
      if (full.endsWith(summaryOpenTag.substring(0, len))) {
        return full.length - len;
      }
    }
    return full.length;
  }

  static ({String cleanText, Map<String, String>? parsedSummary})
      extractSummaryBlock(String raw) {
    final closedRe =
        RegExp(r'<session_summary>([\s\S]*?)</session_summary>', multiLine: true);
    final match = closedRe.firstMatch(raw);
    if (match != null) {
      final inner = (match.group(1) ?? '').trim();
      final cleaned = raw.replaceRange(match.start, match.end, '').trimRight();
      return (
        cleanText: cleaned,
        parsedSummary: tryParseLooseSummaryText(inner),
      );
    }

    final openIdx = raw.indexOf(summaryOpenTag);
    if (openIdx >= 0) {
      final inner = raw.substring(openIdx + summaryOpenTag.length).trim();
      final cleaned = raw.substring(0, openIdx).trimRight();
      return (
        cleanText: cleaned,
        parsedSummary: tryParseLooseSummaryText(inner),
      );
    }

    return (cleanText: raw.trimRight(), parsedSummary: null);
  }

  static Map<String, String>? tryParseLooseSummaryText(String inner) {
    if (inner.isEmpty) return null;
    var candidate = inner.trim();
    final fenceRe = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final fm = fenceRe.firstMatch(candidate);
    if (fm != null) {
      candidate = (fm.group(1) ?? '').trim();
    }

    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) {
        final issue = (decoded['issue'] ?? decoded['problem'] ?? '').toString().trim();
        final findings =
            (decoded['findings'] ?? decoded['root_cause'] ?? '').toString().trim();
        final whatWeDid = (decoded['what_we_did'] ??
                decoded['actions_taken'] ??
                decoded['actionsTaken'] ??
                decoded['solution'] ??
                '')
            .toString()
            .trim();
        if (issue.isNotEmpty || findings.isNotEmpty || whatWeDid.isNotEmpty) {
          return {
            'issue': issue.isNotEmpty ? issue : 'User task completed.',
            'findings':
                findings.isNotEmpty ? findings : 'Analyzed target system state.',
            'what_we_did': whatWeDid.isNotEmpty
                ? whatWeDid
                : 'Executed requested actions and verified outcome.',
          };
        }
      }
    } catch (_) {}

    // Fallback line-based parser if model formatted key: value bullets
    String? issue;
    String? findings;
    String? actions;
    for (final rawLine in const LineSplitter().convert(candidate)) {
      final line = rawLine.replaceFirst(RegExp(r'^[-*•\s]+'), '').trim();
      final lower = line.toLowerCase();
      if (lower.startsWith('issue:') || lower.startsWith('**issue**:')) {
        issue = line.split(':').sublist(1).join(':').replaceAll('**', '').trim();
      } else if (lower.startsWith('findings:') ||
          lower.startsWith('**findings**:')) {
        findings =
            line.split(':').sublist(1).join(':').replaceAll('**', '').trim();
      } else if (lower.startsWith('what we did:') ||
          lower.startsWith('what_we_did:') ||
          lower.startsWith('actions:') ||
          lower.startsWith('**what we did**:')) {
        actions =
            line.split(':').sublist(1).join(':').replaceAll('**', '').trim();
      }
    }
    if (issue != null || findings != null || actions != null) {
      return {
        'issue': issue ?? 'Task completed.',
        'findings': findings ?? 'Reviewed workspace and target environment.',
        'what_we_did': actions ?? 'Completed requested changes.',
      };
    }
    return null;
  }

  static Map<String, String> synthesizeFallbackSummary(MeshSession session) {
    final userPrompts = session.messages
        .where((m) => m.role == 'user' && !m.text.startsWith('🔔 [ASYNC'))
        .map((m) => m.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final assistantMsgs = session.messages
        .where((m) => m.role == 'assistant' && m.status == 'done')
        .toList();
    final allTools = session.messages.expand((m) => m.toolEvents).toList();

    final firstPrompt =
        userPrompts.isNotEmpty ? userPrompts.first : session.title;
    final issue = firstPrompt.length > 200
        ? '${firstPrompt.substring(0, 197)}...'
        : firstPrompt;

    final lastReply = assistantMsgs.isNotEmpty ? assistantMsgs.last.text.trim() : '';
    final cleanFirstPara = lastReply
        .split('\n\n')
        .map((s) => s.replaceAll(RegExp(r'[#*`]+'), '').trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    final findings = cleanFirstPara.isNotEmpty
        ? (cleanFirstPara.length > 240
            ? '${cleanFirstPara.substring(0, 237)}...'
            : cleanFirstPara)
        : 'Inspected ${session.targetNodeName.isNotEmpty ? session.targetNodeName : "target machine"} and verified environment state.';

    final actionsTaken = allTools.isNotEmpty
        ? 'Executed ${allTools.length} remote ${allTools.length == 1 ? "operation" : "operations"} '
            '(${allTools.take(4).map((t) => t.summary).join("; ")}${allTools.length > 4 ? "; +${allTools.length - 4} more" : ""}).'
        : 'Answered query and completed session analysis across ${assistantMsgs.length} ${assistantMsgs.length == 1 ? "turn" : "turns"}.';

    return {
      'issue': issue,
      'findings': findings,
      'what_we_did': actionsTaken,
    };
  }

  String _buildOnDemandSummaryPrompt(MeshSession session) {
    final buf = StringBuffer()
      ..writeln(
        'Generate a concise, brag-worthy completion summary of everything accomplished in this session ("${session.title}").',
      )
      ..writeln(
        'Reply ONLY with a single <session_summary> JSON block in this exact format (no extra prose outside the tag):',
      )
      ..writeln('<session_summary>')
      ..writeln(
        '{"issue": "1-2 sentences describing the problem or goal", "findings": "Key discoveries, root causes, or system state found", "what_we_did": "Concrete commands, code/config changes, and verifications completed"}',
      )
      ..writeln('</session_summary>');

    if (session.agyConversationId == null ||
        session.agyConversationId!.isEmpty) {
      buf.writeln('\nSession Transcript Reference:');
      for (final m in session.messages.where((m) => m.role != 'summary').take(12)) {
        final snippet =
            m.text.length > 500 ? '${m.text.substring(0, 500)}...' : m.text;
        buf.writeln('[${m.role.toUpperCase()}]: $snippet');
      }
    }
    return buf.toString();
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
      ..writeln(
          '- Session Completion Summary Card: Whenever you finish completing the user\'s requested task(s) (and are NOT merely asking a clarifying question or waiting on a detached background command), append a `<session_summary>` JSON block at the very end of your response summarizing the entire session so far:\n'
          '<session_summary>\n'
          '{"issue": "Concise 1-sentence statement of the issue or goal", "findings": "Key root causes, diagnostics, or discoveries", "what_we_did": "Concrete fixes, commands, file edits, and verification performed"}\n'
          '</session_summary>\n'
          'The Hub Server automatically strips this tag from prose and combines it with exact wall-clock duration, remote action count, and token usage into a screenshot-ready Summary Card.')
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
