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
  });
}
