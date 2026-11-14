import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:mesh_server/mesh_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('MeshHubServer + Streamable HTTP MCP + Multi-Session Integration', () {
    late Directory tempDir;
    late Directory remoteWorkspaceDir;
    late MeshHubServer hub;
    late int port;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('agy_mesh_test_');
      remoteWorkspaceDir = Directory(p.join(tempDir.path, 'remote_proj'));
      await remoteWorkspaceDir.create(recursive: true);

      hub = MeshHubServer(
        port: 0, // ephemeral port
        discoveryPort: 0,
        host: '127.0.0.1',
        projectRoot: p.normalize(p.join(Directory.current.path, '..', '..')),
        stateDir: tempDir.path,
      );
      await hub.start(overridePin: '654321');
      port = hub.boundPort;
    });

    tearDown(() async {
      await hub.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Pairs node via PIN, manages concurrent sessions, and executes MCP tools', () async {
      // 1. Verify MCP initialize & tools/list
      final initResp = await http.post(
        Uri.parse('http://127.0.0.1:$port/mcp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {'protocolVersion': '2025-03-26'},
        }),
      );
      expect(initResp.statusCode, 200);
      expect(initResp.headers['mcp-session-id'], isNotEmpty);
      final initBody = jsonDecode(initResp.body) as Map<String, dynamic>;
      expect(initBody['result']['serverInfo']['name'], 'lan-mesh');

      // Notification returns 202 Accepted
      final notifResp = await http.post(
        Uri.parse('http://127.0.0.1:$port/mcp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
      );
      expect(notifResp.statusCode, 202);

      // 2. Connect a simulated target machine over WebSocket using PIN 654321
      final ws = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port/ws'),
      );
      await ws.ready;

      final authCompleter = Completer<Map<String, dynamic>>();
      ws.stream.listen((raw) async {
        final env = WsEnvelope.decode(raw as String);
        if (env.type == WsTypes.authOk && !authCompleter.isCompleted) {
          authCompleter.complete(env.payload);
        } else if (env.type == WsTypes.rpcExec) {
          final req = ExecRequest.fromJson(env.payload);
          ws.sink.add(WsEnvelope(
            type: WsTypes.rpcExecResult,
            payload: ExecResult(
              requestId: req.requestId,
              exitCode: 0,
              stdout: 'EXEC_OK:${req.command}@${req.cwd}',
              stderr: '',
              durationMs: 5,
            ).toJson(),
          ).encode());
        } else if (env.type == WsTypes.rpcFileOp) {
          final req = FileOpRequest.fromJson(env.payload);
          final file = File(req.path);
          if (req.op == 'write') {
            await file.parent.create(recursive: true);
            await file.writeAsString(req.content ?? '');
            ws.sink.add(WsEnvelope(
              type: WsTypes.rpcFileOpResult,
              payload: FileOpResult(
                requestId: req.requestId,
                ok: true,
                message: 'written',
              ).toJson(),
            ).encode());
          } else if (req.op == 'edit') {
            final cur = await file.readAsString();
            await file.writeAsString(
              cur.replaceAll(req.target!, req.replacement!),
            );
            ws.sink.add(WsEnvelope(
              type: WsTypes.rpcFileOpResult,
              payload: FileOpResult(
                requestId: req.requestId,
                ok: true,
                message: 'edited',
              ).toJson(),
            ).encode());
          } else if (req.op == 'read') {
            ws.sink.add(WsEnvelope(
              type: WsTypes.rpcFileOpResult,
              payload: FileOpResult(
                requestId: req.requestId,
                ok: true,
                content: await file.readAsString(),
              ).toJson(),
            ).encode());
          }
        }
      });

      final now = DateTime.now().toUtc().toIso8601String();
      ws.sink.add(WsEnvelope(
        type: WsTypes.authHello,
        payload: {
          'pin': '654321',
          'registerAsNode': true,
          'nodeInfo': NodeInfo(
            nodeId: 'sim-win-node',
            hostname: 'SIM-WIN-PC',
            os: 'linux', // use posix paths in test
            privilegeLevel: PrivilegeLevels.admin,
            approvalMode: ApprovalModes.fullAuto,
            cwd: remoteWorkspaceDir.path,
            connectedAt: now,
            lastSeenAt: now,
          ).toJson(),
        },
      ).encode());

      final authOk = await authCompleter.future;
      expect(authOk['token'], isNotEmpty);

      // 3. Create two concurrent project sessions from Server REST API
      final sess1Resp = await http.post(
        Uri.parse('http://127.0.0.1:$port/api/sessions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': 'Project Alpha',
          'node': 'SIM-WIN-PC',
          'workspacePath': remoteWorkspaceDir.path,
        }),
      );
      expect(sess1Resp.statusCode, 200);
      final sess1Id =
          (jsonDecode(sess1Resp.body)['session']['sessionId']) as String;

      final sess2Resp = await http.post(
        Uri.parse('http://127.0.0.1:$port/api/sessions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': 'Project Beta',
          'node': 'SIM-WIN-PC',
          'workspacePath': '/srv/beta',
        }),
      );
      expect(sess2Resp.statusCode, 200);

      final listSessResp =
          await http.get(Uri.parse('http://127.0.0.1:$port/api/sessions'));
      final sessionsList =
          jsonDecode(listSessResp.body)['sessions'] as List<dynamic>;
      expect(sessionsList.length, 2);

      // 4. Call MCP tools (mesh_exec, mesh_write_file, mesh_edit_file, mesh_read_file) scoped to sess1Id
      Future<String> callMcpTool(String name, Map<String, dynamic> args) async {
        final r = await http.post(
          Uri.parse('http://127.0.0.1:$port/mcp'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 99,
            'method': 'tools/call',
            'params': {'name': name, 'arguments': args},
          }),
        );
        final decoded = jsonDecode(r.body) as Map<String, dynamic>;
        return decoded['result']['content'][0]['text'] as String;
      }

      final execOut = await callMcpTool('mesh_exec', {
        'node': 'SIM-WIN-PC',
        'command': 'npm test',
        'session_id': sess1Id,
      });
      expect(execOut, contains('EXEC_OK:npm test@${remoteWorkspaceDir.path}'));

      await callMcpTool('mesh_write_file', {
        'node': 'SIM-WIN-PC',
        'path': 'hello.txt',
        'content': 'Hello World',
        'session_id': sess1Id,
      });
      await callMcpTool('mesh_edit_file', {
        'node': 'SIM-WIN-PC',
        'path': 'hello.txt',
        'target': 'World',
        'replacement': 'Antigravity Mesh',
        'session_id': sess1Id,
      });
      final readBack = await callMcpTool('mesh_read_file', {
        'node': 'SIM-WIN-PC',
        'path': 'hello.txt',
        'session_id': sess1Id,
      });
      expect(readBack, 'Hello Antigravity Mesh');

      await ws.sink.close();
    });
  });
}
