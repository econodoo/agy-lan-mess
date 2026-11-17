import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('mesh_protocol serialization', () {
    test('MeshSession round-trips with workspacePath and messages', () {
      final session = MeshSession(
        sessionId: 'sess-1',
        title: 'Gaming PC API',
        targetNodeId: 'node-win-1',
        targetNodeName: 'WIN-GAMING',
        workspacePath: r'C:\Projects\api',
        agyConversationId: 'conv-123',
        status: SessionStatuses.running,
        createdAt: '2026-11-14T10:00:00Z',
        updatedAt: '2026-11-14T10:05:00Z',
        messages: const [
          SessionMessage(
            id: 'm1',
            role: 'user',
            text: 'Run unit tests',
            timestamp: '2026-11-14T10:00:00Z',
          ),
        ],
      );

      final decoded = MeshSession.fromJson(session.toJson());
      expect(decoded.sessionId, 'sess-1');
      expect(decoded.title, 'Gaming PC API');
      expect(decoded.targetNodeId, 'node-win-1');
      expect(decoded.workspacePath, r'C:\Projects\api');
      expect(decoded.agyConversationId, 'conv-123');
      expect(decoded.messages.single.text, 'Run unit tests');
    });

    test('WsEnvelope encodes and decodes cleanly', () {
      const env = WsEnvelope(
        type: WsTypes.rpcExec,
        id: 'req-42',
        payload: {'command': 'whoami', 'elevated': true},
      );
      final raw = env.encode();
      final back = WsEnvelope.decode(raw);
      expect(back.type, WsTypes.rpcExec);
      expect(back.id, 'req-42');
      expect(back.payload['elevated'], isTrue);
    });

    test('SessionCompletionSummary & cumulative MeshSession metrics serialize cleanly', () {
      const summary = SessionCompletionSummary(
        issue: 'Nginx returning 502 on ubuntu-prod',
        findings: 'Upstream port mismatch (3000 vs 8080)',
        actionsTaken: 'Updated site config and reloaded nginx',
        activeDurationMs: 42500,
        sessionSpanMs: 65000,
        turnsCount: 2,
        toolCallsCount: 5,
        inputTokens: 14200,
        outputTokens: 1800,
        thinkingTokens: 2500,
        modelLabel: 'Gemini 4 Carbon (Medium)',
        targetNodeName: 'ubuntu-prod',
        workspacePath: '/etc/nginx',
        generatedAt: '2026-11-17T10:55:00Z',
      );

      final session = MeshSession(
        sessionId: 'sess-brag',
        title: 'Fix Prod Nginx',
        targetNodeId: 'node-linux-1',
        targetNodeName: 'ubuntu-prod',
        workspacePath: '/etc/nginx',
        createdAt: '2026-11-17T10:54:00Z',
        updatedAt: '2026-11-17T10:55:00Z',
        messages: [
          const SessionMessage(
            id: 'u1',
            role: 'user',
            text: 'Fix 502 error',
            timestamp: '2026-11-17T10:54:00Z',
          ),
          const SessionMessage(
            id: 'a1',
            role: 'assistant',
            text: 'Fixed upstream port and reloaded nginx.',
            timestamp: '2026-11-17T10:54:45Z',
            durationMs: 42500,
            inputTokens: 14200,
            outputTokens: 1800,
            thinkingTokens: 2500,
            modelLabel: 'Gemini 4 Carbon (Medium)',
            toolEvents: [
              ToolCallSummary(
                id: 't1',
                toolName: 'mesh_exec',
                summary: 'nginx -t && systemctl reload nginx',
                status: 'done',
              ),
            ],
          ),
          SessionMessage(
            id: 's1',
            role: 'summary',
            text: summary.toMarkdown(sessionTitle: 'Fix Prod Nginx'),
            timestamp: '2026-11-17T10:55:00Z',
            completionSummary: summary,
          ),
        ],
      );

      final decoded = MeshSession.fromJson(session.toJson());
      expect(decoded.totalTurns, 1);
      expect(decoded.totalToolCalls, 1);
      expect(decoded.totalActiveDurationMs, 42500);
      expect(decoded.totalTokens, 18500);
      expect(decoded.latestSummary, isNotNull);
      expect(decoded.latestSummary!.issue, contains('502'));
      expect(SessionCompletionSummary.formatDuration(42500), '42.5s');
      expect(SessionCompletionSummary.formatTokens(18500), '18.5k');
      expect(
        summary.toMarkdown(sessionTitle: 'Fix Prod Nginx'),
        contains('What We Did'),
      );
    });
  });
}
