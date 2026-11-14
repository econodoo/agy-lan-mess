import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mesh_server/mesh_server.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show CLI usage');

  final startParser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8765', help: 'HTTP/WS/MCP port')
    ..addOption(
      'discovery-port',
      defaultsTo: '8766',
      help: 'UDP LAN auto-discovery port',
    )
    ..addOption('pin', help: 'Override the 6-digit LAN pairing PIN')
    ..addOption(
      'project-root',
      help: 'Path to agy-lan-mesh root (auto-detected by default)',
    )
    ..addOption('agy-bin', defaultsTo: 'agy', help: 'Path to agy CLI binary')
    ..addFlag(
      'register-mcp',
      defaultsTo: true,
      help: 'Ensure lan-mesh Streamable HTTP MCP server is registered in agy',
    )
    ..addFlag(
      'expose-local-node',
      defaultsTo: false,
      help: 'Also expose the Brain Server host itself as a controllable node',
    )
    ..addFlag(
      'skip-all-agy-permissions',
      defaultsTo: false,
      help:
          'Pass --dangerously-skip-permissions to headless agy turns (by default only mcp(lan-mesh/*) tools are auto-approved)',
    );

  final sessionsParser = ArgParser()
    ..addOption('url', defaultsTo: 'http://127.0.0.1:8765')
    ..addOption('title', abbr: 't', help: 'Session title (for "sessions new")')
    ..addOption('node', abbr: 'n', help: 'Target node hostname or ID')
    ..addOption('path', abbr: 'w', help: 'Remote workspace directory path');

  final nodesParser = ArgParser()
    ..addOption('url', defaultsTo: 'http://127.0.0.1:8765');

  final doctorParser = ArgParser()
    ..addOption('url', defaultsTo: 'http://127.0.0.1:8765')
    ..addFlag(
      'ping',
      defaultsTo: true,
      help: 'Run a live 1-turn Antigravity quota & connectivity ping',
    );

  parser
    ..addCommand('start', startParser)
    ..addCommand('sessions', sessionsParser)
    ..addCommand('nodes', nodesParser)
    ..addCommand('doctor', doctorParser);

  ArgResults results;
  try {
    results = parser.parse(arguments.isEmpty ? ['start'] : arguments);
  } catch (e) {
    stderr.writeln('Argument error: $e\n');
    _printUsage(parser, startParser);
    exit(64);
  }

  if (results['help'] as bool) {
    _printUsage(parser, startParser);
    return;
  }

  final cmd = results.command;
  if (cmd == null || cmd.name == 'start') {
    final sArgs = cmd ?? startParser.parse([]);
    final done = Completer<void>();
    runZonedGuarded(
      () async {
        try {
          await _runStart(sArgs);
          done.complete();
        } catch (e, st) {
          stderr.writeln('[Hub] Startup error: $e\n$st');
          exit(1);
        }
      },
      (error, stack) {
        // Keep the Hub Server running across transient socket/network errors.
        stderr.writeln('[Hub] Ignored transient async error: $error');
      },
    );
    await done.future;
  } else if (cmd.name == 'sessions') {
    await _runSessionsCli(cmd);
  } else if (cmd.name == 'nodes') {
    await _runNodesCli(cmd);
  } else if (cmd.name == 'doctor') {
    await _runDoctorCli(cmd);
  }
}

Future<void> _runStart(ArgResults args) async {
  final port = int.parse(args['port'] as String);
  final discoveryPort = int.parse(args['discovery-port'] as String);
  final projectRoot =
      (args['project-root'] as String?) ?? _detectProjectRoot();
  final registerMcp = args['register-mcp'] as bool;
  final agyBin = args['agy-bin'] as String;

  if (registerMcp) {
    await _ensureMcpRegistered(agyBin, port);
  }

  final hub = MeshHubServer(
    port: port,
    discoveryPort: discoveryPort,
    projectRoot: projectRoot,
    exposeLocalServerNode: args['expose-local-node'] as bool,
    skipAllAgyPermissions: args['skip-all-agy-permissions'] as bool,
    agyExecutable: agyBin,
  );

  await hub.start(overridePin: args['pin'] as String?);
  final lanIps = await DiscoveryBroadcaster.detectLanIpv4Addresses();
  final primaryIp = lanIps.isNotEmpty ? lanIps.first : '127.0.0.1';

  stdout.writeln('''
╔══════════════════════════════════════════════════════════════════════════╗
║                     🚀 AGY LAN MESH HUB SERVER READY                    ║
╠══════════════════════════════════════════════════════════════════════════╣
║  6-Digit Pairing PIN :  ${hub.store.pairingPin.padRight(48)}║
║  Server Console UI   :  http://127.0.0.1:${hub.boundPort.toString().padRight(31)}║
║  LAN Console / Web   :  http://$primaryIp:${hub.boundPort.toString().padRight(31)}║
║  MCP Endpoint (agy)  :  http://127.0.0.1:${hub.boundPort}/mcp                    ║
║  UDP Auto-Discovery  :  Port ${discoveryPort.toString().padRight(43)}║
╠══════════════════════════════════════════════════════════════════════════╣
║  Instant Zero-Install Target Rollout:                                    ║
║  • Windows (Admin PowerShell):                                           ║
║    irm http://$primaryIp:${hub.boundPort}/agent.ps1 -OutFile \$env:TEMP\\agy.ps1; \\
║    powershell -ExecutionPolicy Bypass -File \$env:TEMP\\agy.ps1 -Pin ${hub.store.pairingPin}
║  • Linux (Root or Sudo user):                                            ║
║    curl -fsSL http://$primaryIp:${hub.boundPort}/agent.sh | bash -s -- --pin ${hub.store.pairingPin}
║  • Server Session CLI:                                                   ║
║    agy-mesh-server sessions list | new | stop <id> | delete <id>         ║
╚══════════════════════════════════════════════════════════════════════════╝
''');

  final completer = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[Hub] Shutting down gracefully...');
    await hub.stop();
    if (!completer.isCompleted) completer.complete();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await hub.stop();
      if (!completer.isCompleted) completer.complete();
      exit(0);
    });
  }
  await completer.future;
}

Future<void> _ensureMcpRegistered(String agyBin, int port) async {
  final mcpUrl = 'http://127.0.0.1:$port/mcp';
  try {
    final res = await Process.run(agyBin, ['mcp', 'add', 'lan-mesh', mcpUrl]);
    if (res.exitCode == 0) {
      stdout.writeln('[MCP] Registered "lan-mesh" -> $mcpUrl in Antigravity.');
    } else {
      stderr.writeln(
        '[MCP] Note: `agy mcp add` returned ${res.exitCode}: ${res.stderr}',
      );
    }
  } catch (e) {
    stderr.writeln('[MCP] Could not invoke `$agyBin mcp add`: $e');
  }
}

Future<void> _runSessionsCli(ArgResults cmd) async {
  final baseUrl = cmd['url'] as String;
  final rest = cmd.rest;
  final action = rest.isEmpty ? 'list' : rest.first;
  final client = HttpClient();

  try {
    switch (action) {
      case 'list':
        final data = await _httpJson(client, 'GET', '$baseUrl/api/sessions');
        final sessions = data['sessions'] as List<dynamic>? ?? [];
        if (sessions.isEmpty) {
          stdout.writeln('No sessions exist yet. Create one with: sessions new -t "My App" -n <node> -w <path>');
          return;
        }
        stdout.writeln(
          '${"SESSION ID".padRight(38)} ${"STATUS".padRight(17)} ${"TARGET MACHINE".padRight(20)} ${"TITLE & WORKSPACE"}',
        );
        stdout.writeln('-' * 105);
        for (final item in sessions) {
          final s = item as Map<String, dynamic>;
          stdout.writeln(
            '${(s["sessionId"] as String).padRight(38)} '
            '${(s["status"] as String).padRight(17)} '
            '${(s["targetNodeName"] as String? ?? s["targetNodeId"] as String).padRight(20)} '
            '${s["title"]} (${s["workspacePath"] ?? ""})',
          );
        }
        break;

      case 'new':
      case 'create':
        final title = cmd['title'] as String? ?? 'Project Session';
        final node = cmd['node'] as String? ?? '*';
        final path = cmd['path'] as String? ?? '';
        final data = await _httpJson(
          client,
          'POST',
          '$baseUrl/api/sessions',
          body: {'title': title, 'node': node, 'workspacePath': path},
        );
        final created = data['session'] as Map<String, dynamic>;
        stdout.writeln(
          'Created session "${created["title"]}" -> ID: ${created["sessionId"]} (Node: ${created["targetNodeName"]}, Path: ${created["workspacePath"]})',
        );
        break;

      case 'stop':
      case 'cancel':
        if (rest.length < 2) {
          stderr.writeln('Usage: agy-mesh-server sessions stop <sessionId>');
          exit(64);
        }
        final res = await _httpJson(
          client,
          'POST',
          '$baseUrl/api/sessions/${rest[1]}/cancel',
        );
        stdout.writeln('Session ${rest[1]} cancel result: ${res["cancelled"]}');
        break;

      case 'delete':
      case 'rm':
        if (rest.length < 2) {
          stderr.writeln('Usage: agy-mesh-server sessions delete <sessionId>');
          exit(64);
        }
        final res = await _httpJson(
          client,
          'DELETE',
          '$baseUrl/api/sessions/${rest[1]}',
        );
        stdout.writeln('Deleted session ${rest[1]}: ${res["ok"]}');
        break;

      default:
        stderr.writeln(
          'Unknown sessions action "$action". Use: list | new | stop <id> | delete <id>',
        );
        exit(64);
    }
  } finally {
    client.close();
  }
}

Future<void> _runNodesCli(ArgResults cmd) async {
  final baseUrl = cmd['url'] as String;
  final client = HttpClient();
  try {
    final data = await _httpJson(client, 'GET', '$baseUrl/api/nodes');
    final nodes = data['nodes'] as List<dynamic>? ?? [];
    if (nodes.isEmpty) {
      stdout.writeln('No LAN nodes paired yet.');
      return;
    }
    stdout.writeln(
      '${"ONLINE".padRight(8)} ${"HOSTNAME".padRight(22)} ${"OS".padRight(10)} ${"PRIVILEGE".padRight(14)} ${"MODE".padRight(16)} ${"IP / NODE ID"}',
    );
    stdout.writeln('-' * 100);
    for (final item in nodes) {
      final n = item as Map<String, dynamic>;
      final online = (n['online'] as bool? ?? false) ? '● YES' : '○ NO';
      stdout.writeln(
        '${online.padRight(8)} '
        '${(n["hostname"] as String).padRight(22)} '
        '${(n["os"] as String).padRight(10)} '
        '${(n["privilegeLevel"] as String).padRight(14)} '
        '${(n["approvalMode"] as String).padRight(16)} '
        '${n["ipAddress"]} (${n["nodeId"]})',
      );
    }
  } finally {
    client.close();
  }
}

Future<void> _runDoctorCli(ArgResults cmd) async {
  final baseUrl = cmd['url'] as String;
  final doPing = cmd['ping'] as bool;
  final client = HttpClient();
  try {
    stdout.writeln(
      doPing
          ? '🔍 Checking Antigravity Brain auth, models, MCP & running live quota ping...'
          : '🔍 Checking Antigravity Brain auth, models & MCP...',
    );
    final data = doPing
        ? await _httpJson(client, 'POST', '$baseUrl/api/brain/ping', body: {})
        : await _httpJson(client, 'GET', '$baseUrl/api/brain');
    stdout.writeln('  CLI Installed      : ${data["cliInstalled"]}');
    stdout.writeln(
      '  Login Status       : ${data["loggedIn"] == true ? "✅ Logged In" : "❌ Not Logged In"} '
      '(${data["accountEmail"] ?? ""} ${data["authMethod"] ?? ""})',
    );
    stdout.writeln('  Server Default Mdl : ${data["defaultModelLabel"]}');
    stdout.writeln(
      '  Model Override     : ${(data["selectedModelOverride"] as String? ?? "").isEmpty ? "(Using Server Default)" : data["selectedModelOverride"]}',
    );
    stdout.writeln(
      '  MCP Bridge (lan)   : ${data["mcpRegistered"] == true ? "✅ Registered" : "⚠️ Not Registered"}',
    );
    stdout.writeln(
      '  Quota / Live Check : [${data["quotaStatus"]}] ${data["quotaMessage"]}',
    );
    final models = data['availableModels'] as List<dynamic>? ?? [];
    stdout.writeln('  Available Models   : ${models.length} models ready');
    stdout.writeln(
      '  Cumulative Usage   : ${data["cumulativeTurns"]} turns '
      '(in=${data["cumulativeInputTokens"]}, out=${data["cumulativeOutputTokens"]}, thinking=${data["cumulativeThinkingTokens"]})',
    );
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _httpJson(
  HttpClient client,
  String method,
  String url, {
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.parse(url);
  final req = await client.openUrl(method, uri);
  req.headers.contentType = ContentType.json;
  if (body != null) {
    req.write(jsonEncode(body));
  }
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  if (resp.statusCode >= 400) {
    throw HttpException('HTTP ${resp.statusCode}: $text', uri: uri);
  }
  return jsonDecode(text) as Map<String, dynamic>;
}

String _detectProjectRoot() {
  final candidates = [
    Directory.current.path,
    p.normalize(p.join(Directory.current.path, '..', '..')),
    p.normalize(p.join(File(Platform.resolvedExecutable).parent.path, '..')),
  ];
  for (final dir in candidates) {
    if (Directory(p.join(dir, 'scripts')).existsSync() ||
        Directory(p.join(dir, 'packages', 'mesh_server')).existsSync()) {
      return dir;
    }
  }
  return Directory.current.path;
}

void _printUsage(ArgParser parser, ArgParser startParser) {
  stdout.writeln('AGY LAN Mesh Hub & MCP Server');
  stdout.writeln('\nUsage:');
  stdout.writeln('  agy-mesh-server start [flags]');
  stdout.writeln('  agy-mesh-server nodes [--url http://127.0.0.1:8765]');
  stdout.writeln(
    '  agy-mesh-server sessions <list|new|stop|delete> [options]',
  );
  stdout.writeln('\nStart Flags:');
  stdout.writeln(startParser.usage);
}
