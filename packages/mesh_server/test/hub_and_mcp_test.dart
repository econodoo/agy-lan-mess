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
          if (req.command == 'LONG_BUILD') {
            ws.sink.add(WsEnvelope(
              type: WsTypes.rpcExecHeartbeat,
              payload: ExecHeartbeat(
                requestId: req.requestId,
                pid: 7777,
                alive: true,
                elapsedMs: 300,
                stdoutTail: 'Compiling step 1/2...',
              ).toJson(),
            ).encode());
            Future<void>.delayed(const Duration(milliseconds: 1600), () {
              ws.sink.add(WsEnvelope(
                type: WsTypes.rpcExecResult,
                payload: ExecResult(
                  requestId: req.requestId,
                  exitCode: 0,
                  stdout: 'LONG_BUILD_COMPLETED_OK',
                  stderr: '',
                  durationMs: 1600,
                ).toJson(),
              ).encode());
            });
          } else {
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
          }
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

      // 5. Verify heartbeat-backed long task detaches cleanly & mesh_task_status retrieves completion
      final longStartOut = await callMcpTool('mesh_exec', {
        'node': 'SIM-WIN-PC',
        'command': 'LONG_BUILD',
        'wait_sec': 1,
      });
      expect(longStartOut, contains('STILL RUNNING'));
      expect(longStartOut, contains('7777'));
      expect(longStartOut, contains('Compiling step 1/2...'));

      final idMatch = RegExp(r'Task ID\s*:\s*([a-f0-9\-]+)').firstMatch(longStartOut);
      expect(idMatch, isNotNull);
      final taskId = idMatch!.group(1)!;

      final listTasksOut = await callMcpTool('mesh_list_tasks', {
        'node': 'SIM-WIN-PC',
      });
      expect(listTasksOut, contains(taskId));

      final finalTaskOut = await callMcpTool('mesh_task_status', {
        'task_id': taskId,
        'wait_sec': 5,
      });
      expect(finalTaskOut, contains('LONG_BUILD_COMPLETED_OK'));
      expect(finalTaskOut, contains('Exit Code: 0'));

      await ws.sink.close();
    });

    test('Streams Brain turn without leaking <session_summary> tag and appends Brag Summary Card', () async {
      // Holdback & extraction unit checks
      expect(
        AgyBrainBridge.computeSafeStreamingLength('Hello world <sess'),
        'Hello world '.length,
      );
      expect(
        AgyBrainBridge.computeSafeStreamingLength('a < b is true'),
        'a < b is true'.length,
      );

      final fakeAgy = File(p.join(tempDir.path, 'fake_agy.sh'));
      await fakeAgy.writeAsString(r'''#!/usr/bin/env bash
cat << 'EOF'
{"event":"init","conversation_id":"conv-test-99"}
{"event":"step_update","step_update":{"text_delta":"Fixed the port conflict and restarted the service.\n\n<session_"}}
{"event":"step_update","step_update":{"text_delta":"summary>{\"issue\":\"Port 8080 conflict on dev server\",\"findings\":\"Stale node process held 8080\",\"what_we_did\":\"Terminated stale PID and restarted systemd unit\"}</session_summary>"}}
{"event":"result","result":{"conversation_id":"conv-test-99","usage":{"input_tokens":4200,"output_tokens":350,"thinking_tokens":650}}}
EOF
''');
      await Process.run('chmod', ['+x', fakeAgy.path]);

      final mockHub = MeshHubServer(
        port: 0,
        discoveryPort: 0,
        host: '127.0.0.1',
        projectRoot: p.normalize(p.join(Directory.current.path, '..', '..')),
        stateDir: p.join(tempDir.path, 'mock_hub_state'),
        agyExecutable: fakeAgy.path,
      );
      await mockHub.start(overridePin: '123456');

      try {
        final sess = mockHub.store.createSession(
          title: 'Dev Server Port Fix',
          targetNodeId: '*',
          targetNodeName: 'ubuntu-dev',
          workspacePath: '/srv/app',
        );

        final streamedDeltas = <String>[];
        final summaryCompleter = Completer<Map<String, dynamic>>();
        final subWs = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${mockHub.boundPort}/ws'),
        );
        await subWs.ready;
        final authOk = Completer<void>();
        subWs.stream.listen((raw) {
          final env = WsEnvelope.decode(raw as String);
          if (env.type == WsTypes.authOk && !authOk.isCompleted) {
            authOk.complete();
          } else if (env.type == WsTypes.chatEvent) {
            if (env.payload['kind'] == 'text_delta') {
              streamedDeltas.add(env.payload['delta'] as String);
            } else if (env.payload['kind'] == 'session_summary' &&
                !summaryCompleter.isCompleted) {
              summaryCompleter.complete(
                Map<String, dynamic>.from(env.payload['summary'] as Map),
              );
            }
          }
        });
        subWs.sink.add(const WsEnvelope(
          type: WsTypes.authHello,
          payload: {'registerAsNode': false, 'nodeInfo': {}},
        ).encode());
        await authOk.future;

        await mockHub.brain.runPromptTurn(
          sessionId: sess.sessionId,
          userPrompt: 'Why is port 8080 failing?',
        );

        final summaryEvent = await summaryCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        final fullStreamed = streamedDeltas.join();
        expect(fullStreamed, contains('Fixed the port conflict'));
        expect(fullStreamed, isNot(contains('<session_summary>')));
        expect(summaryEvent['issue'], 'Port 8080 conflict on dev server');
        expect(summaryEvent['findings'], 'Stale node process held 8080');
        expect(
          summaryEvent['actionsTaken'],
          'Terminated stale PID and restarted systemd unit',
        );
        expect(summaryEvent['inputTokens'], 4200);
        expect(summaryEvent['outputTokens'], 350);
        expect(summaryEvent['thinkingTokens'], 650);

        final finalSess = mockHub.store.getSession(sess.sessionId)!;
        expect(finalSess.messages.last.role, 'summary');
        expect(finalSess.latestSummary!.totalTokens, 5200);

        await subWs.sink.close();
      } finally {
        await mockHub.stop();
      }
    });
  });
}
