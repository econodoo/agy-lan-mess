import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'agy_brain_bridge.dart';
import 'discovery_broadcaster.dart';
import 'mcp_http_handler.dart';
import 'node_registry.dart';
import 'pairing_store.dart';

class MeshHubServer {
  final int port;
  final int discoveryPort;
  final String host;
  final String projectRoot;
  final bool exposeLocalServerNode;
  final bool skipAllAgyPermissions;
  final String agyExecutable;
  final String mcpServerName;
  final String? stateDir;

  late final PairingAndSessionStore store;
  late final NodeRegistry registry;
  late final AgyBrainBridge brain;
  late final McpHttpHandler mcpHandler;
  late final DiscoveryBroadcaster discovery;

  HttpServer? _httpServer;
  final _uuid = const Uuid();

  MeshHubServer({
    this.port = 8765,
    this.discoveryPort = 8766,
    this.host = '0.0.0.0',
    required this.projectRoot,
    this.exposeLocalServerNode = false,
    this.skipAllAgyPermissions = false,
    this.agyExecutable = 'agy',
    this.mcpServerName = 'lan-mesh',
    this.stateDir,
  });

  int get boundPort => _httpServer?.port ?? port;

  Future<void> start({String? overridePin}) async {
    store = PairingAndSessionStore(stateDir: stateDir);
    await store.init(overridePin: overridePin);

    registry = NodeRegistry(
      store: store,
      exposeLocalServerNode: exposeLocalServerNode,
    );

    brain = AgyBrainBridge(
      store: store,
      registry: registry,
      agyExecutable: agyExecutable,
      mcpServerName: mcpServerName,
      skipAllAgyPermissions: skipAllAgyPermissions,
    );

    registry.onNodeAwaitingApproval = (nodeId, _) {
      brain.notifyNodeAwaitingApproval(nodeId);
    };

    mcpHandler = McpHttpHandler(
      registry: registry,
      store: store,
      onToolActivity: brain.recordToolActivity,
    );

    final router = Router();

    // 1. Streamable HTTP MCP Endpoint for Antigravity
    router.all('/mcp', mcpHandler.handle);

    // 2. Persistent WebSocket Hub for Clients, Consoles & Mobile
    router.get('/ws', (Request req) {
      final remoteIp = _extractRemoteIp(req);
      final isLoopback = _isLoopbackIp(remoteIp);
      final handler = webSocketHandler((WebSocketChannel channel, String? _) {
        _handleWebSocketConnection(
          channel: channel,
          remoteIp: remoteIp,
          isLoopback: isLoopback,
        );
      });
      return handler(req);
    });

    // 3. Zero-Install Bootstrap Scripts
    router.get('/agent.ps1', _serveStampedPowerShellAgent);
    router.get('/agent.py', _serveStampedPythonAgent);
    router.get('/agent.sh', _serveStampedBashWrapper);

    // 4. Server Management REST API (Loopback or PIN/Token authenticated)
    router.get('/api/status', _handleApiStatus);
    router.get('/api/nodes', _handleApiNodes);
    router.get('/api/sessions', _handleApiSessionsList);
    router.post('/api/sessions', _handleApiSessionCreate);
    router.post('/api/sessions/<id>/cancel', _handleApiSessionCancel);
    router.delete('/api/sessions/<id>', _handleApiSessionDelete);

    // 5. Downloads directory (APK / portable zips)
    final downloadsDir = Directory(p.join(projectRoot, 'downloads'));
    if (await downloadsDir.exists()) {
      final dlStatic = createStaticHandler(downloadsDir.path);
      router.mount('/downloads/', dlStatic);
    } else {
      router.get('/downloads/<file|.*>', (Request req) {
        return Response.notFound('No artifacts in downloads/ folder yet.');
      });
    }

    // 6. Hosted Flutter Web Console (if built) or Helpful Fallback Landing Page
    final webBuildDir =
        Directory(p.join(projectRoot, 'apps', 'mesh_client', 'build', 'web'));
    Handler cascadeHandler;
    if (await webBuildDir.exists()) {
      final webStatic = createStaticHandler(
        webBuildDir.path,
        defaultDocument: 'index.html',
      );
      cascadeHandler = Cascade().add(router.call).add(webStatic).handler;
    } else {
      router.get('/', _serveFallbackDashboardHtml);
      cascadeHandler = router.call;
    }

    _httpServer = await HttpServer.bind(host, port);
    shelf_io.serveRequests(_httpServer!, cascadeHandler);

    discovery = DiscoveryBroadcaster(
      discoveryPort: discoveryPort,
      httpPort: boundPort,
    );
    await discovery.start();
  }

  Future<void> stop() async {
    brain.dispose();
    await discovery.stop();
    registry.dispose();
    await _httpServer?.close(force: true);
    await store.dispose();
  }

  // ---------------- WebSocket Peer Handling ----------------

  void _handleWebSocketConnection({
    required WebSocketChannel channel,
    required String remoteIp,
    required bool isLoopback,
  }) {
    final peer = ConnectedPeer(
      connectionId: _uuid.v4(),
      channel: channel,
      remoteIp: remoteIp,
    );
    registry.registerPeer(peer);

    channel.stream.listen(
      (dynamic raw) {
        if (raw is! String) return;
        peer.lastSeen = DateTime.now().toUtc();
        WsEnvelope env;
        try {
          env = WsEnvelope.decode(raw);
        } catch (_) {
          return;
        }
        unawaited(_dispatchWsFrame(peer, env, isLoopback: isLoopback));
      },
      onDone: () => registry.unregisterPeer(peer),
      onError: (_) => registry.unregisterPeer(peer),
    );
  }

  Future<void> _dispatchWsFrame(
    ConnectedPeer peer,
    WsEnvelope env, {
    required bool isLoopback,
  }) async {
    final pMap = env.payload;

    if (env.type == WsTypes.nodePong) return;
    if (env.type == WsTypes.nodePing) {
      peer.send(const WsEnvelope(type: WsTypes.nodePong));
      return;
    }

    if (env.type == WsTypes.authHello) {
      final pin = (pMap['pin'] as String?)?.trim() ?? '';
      final existingToken = (pMap['token'] as String?)?.trim() ?? '';
      final registerAsNode = pMap['registerAsNode'] as bool? ?? true;
      final nodeMap = pMap['nodeInfo'] is Map
          ? Map<String, dynamic>.from(pMap['nodeInfo'] as Map)
          : <String, dynamic>{};

      final requestedNodeId =
          (nodeMap['nodeId'] as String?)?.trim().isNotEmpty == true
              ? (nodeMap['nodeId'] as String).trim()
              : _uuid.v4();

      String? issuedToken;
      if (existingToken.isNotEmpty &&
          (store.verifyNodeToken(requestedNodeId, existingToken) ||
              store.verifyAnyToken(existingToken))) {
        issuedToken = existingToken;
      } else if (pin.isNotEmpty && store.verifyPin(pin)) {
        issuedToken = null; // Will generate below
      } else if (isLoopback && !registerAsNode) {
        // Frictionless Server Console auto-auth strictly on 127.0.0.1 / ::1
        issuedToken = store.loopbackAdminToken;
      } else {
        peer.send(WsEnvelope(
          type: WsTypes.authError,
          id: env.id,
          payload: {
            'message':
                'Invalid or missing 6-digit Pairing PIN. Check the AGY Hub Server banner.',
          },
        ));
        return;
      }

      if (registerAsNode) {
        final now = DateTime.now().toUtc().toIso8601String();
        final info = NodeInfo.fromJson({
          ...nodeMap,
          'nodeId': requestedNodeId,
          'ipAddress': remoteIpDisplay(peer.remoteIp, nodeMap['ipAddress'] as String?),
          'online': true,
          'connectedAt': now,
          'lastSeenAt': now,
        });
        issuedToken = store.registerOrUpdatePairedNode(
          info,
          existingToken: issuedToken,
        );
        registry.bindAuthenticatedNode(peer, info);
      } else {
        peer.isAuthenticated = true;
        issuedToken ??= store.registerOrUpdatePairedNode(
          NodeInfo(
            nodeId: 'console-$requestedNodeId',
            hostname: nodeMap['hostname'] as String? ?? 'Console',
            os: nodeMap['os'] as String? ?? 'web',
            capabilities: const ['chat'],
            online: false,
            connectedAt: DateTime.now().toUtc().toIso8601String(),
            lastSeenAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
      }

      peer.send(WsEnvelope(
        type: WsTypes.authOk,
        id: env.id,
        payload: {
          'nodeId': requestedNodeId,
          'token': issuedToken,
          'serverHostname': Platform.localHostname,
          if (isLoopback) 'pairingPin': store.pairingPin,
          'nodes': registry.listAllNodes().map((n) => n.toJson()).toList(),
          'sessions':
              store.listSessions().map((s) => s.toSummaryJson()).toList(),
        },
      ));
      return;
    }

    // Require authentication for all operational messages
    if (!peer.isAuthenticated) {
      peer.send(WsEnvelope(
        type: WsTypes.authError,
        id: env.id,
        payload: {'message': 'Not authenticated. Send auth.hello first.'},
      ));
      return;
    }

    switch (env.type) {
      case WsTypes.nodeUpdate:
        registry.updatePeerNodeInfo(peer, pMap);
        break;

      case WsTypes.rpcAwaitingApproval:
        final reqId = pMap['requestId'] as String? ?? '';
        if (peer.nodeInfo != null && reqId.isNotEmpty) {
          registry.handleExecAwaitingApproval(peer.nodeInfo!.nodeId, reqId);
        }
        break;

      case WsTypes.rpcExecResult:
        registry.handleExecResult(pMap);
        break;

      case WsTypes.rpcFileOpResult:
        registry.handleFileOpResult(pMap);
        break;

      // ---------- Multi-Session Management ----------
      case WsTypes.sessionCreate:
        final title = pMap['title'] as String? ?? 'New Project Session';
        final targetNodeId = pMap['targetNodeId'] as String? ?? '*';
        final workspacePath = pMap['workspacePath'] as String? ?? '';
        final resolved =
            targetNodeId == '*' ? null : registry.resolveNode(targetNodeId);
        final session = store.createSession(
          title: title,
          targetNodeId: resolved?.nodeId ?? targetNodeId,
          targetNodeName: resolved?.hostname ??
              (targetNodeId == '*' ? 'Fleet-Wide' : targetNodeId),
          workspacePath: workspacePath.isNotEmpty
              ? workspacePath
              : (resolved?.cwd ?? ''),
        );
        registry.broadcastSessionsSnapshot();
        peer.send(WsEnvelope(
          type: WsTypes.sessionDetail,
          id: env.id,
          payload: {'session': session.toJson()},
        ));
        break;

      case WsTypes.sessionUpdate:
        final sessionId = pMap['sessionId'] as String? ?? '';
        final targetNodeId = pMap['targetNodeId'] as String?;
        final resolved = (targetNodeId != null && targetNodeId != '*')
            ? registry.resolveNode(targetNodeId)
            : null;
        final updated = store.updateSessionMeta(
          sessionId,
          title: pMap['title'] as String?,
          targetNodeId: resolved?.nodeId ?? targetNodeId,
          targetNodeName: resolved?.hostname ??
              (targetNodeId == '*' ? 'Fleet-Wide' : null),
          workspacePath: pMap['workspacePath'] as String?,
        );
        if (updated != null) {
          registry.broadcastSessionsSnapshot();
          registry.broadcastToAuthenticated(WsEnvelope(
            type: WsTypes.sessionDetail,
            id: env.id,
            payload: {'session': updated.toJson()},
          ));
        }
        break;

      case WsTypes.sessionDelete:
        final sessionId = pMap['sessionId'] as String? ?? '';
        if (sessionId.isNotEmpty) {
          await brain.cancelSessionTurn(sessionId);
          store.deleteSession(sessionId);
          registry.broadcastSessionsSnapshot();
        }
        break;

      case WsTypes.sessionGet:
        final sessionId = pMap['sessionId'] as String? ?? '';
        final session = store.getSession(sessionId);
        if (session != null) {
          peer.send(WsEnvelope(
            type: WsTypes.sessionDetail,
            id: env.id,
            payload: {'session': session.toJson()},
          ));
        }
        break;

      case WsTypes.browseRemoteDir:
        final nodeId = pMap['nodeId'] as String? ?? '';
        final path = pMap['path'] as String? ?? '.';
        final res = await registry.performFileOp(
          nodeRef: nodeId,
          op: 'list',
          path: path,
        );
        peer.send(WsEnvelope(
          type: WsTypes.browseRemoteDirResult,
          id: env.id,
          payload: res.toJson(),
        ));
        break;

      // ---------- Brain Prompt & Cancel ----------
      case WsTypes.chatSend:
        final prompt = (pMap['prompt'] as String?)?.trim() ?? '';
        if (prompt.isEmpty) return;
        var sessionId = (pMap['sessionId'] as String?)?.trim() ?? '';
        var session = sessionId.isNotEmpty ? store.getSession(sessionId) : null;
        if (session == null) {
          final targetNodeId = (pMap['targetNodeId'] as String?)?.trim() ??
              (peer.nodeInfo?.nodeId ?? '*');
          final resolved =
              targetNodeId == '*' ? null : registry.resolveNode(targetNodeId);
          final autoTitle = pMap['title'] as String? ??
              _deriveSessionTitle(prompt, resolved?.hostname);
          session = store.createSession(
            sessionId: sessionId.isNotEmpty ? sessionId : null,
            title: autoTitle,
            targetNodeId: resolved?.nodeId ?? targetNodeId,
            targetNodeName: resolved?.hostname ??
                (targetNodeId == '*' ? 'Fleet-Wide' : targetNodeId),
            workspacePath: (pMap['workspacePath'] as String?) ??
                (resolved?.cwd ?? ''),
          );
          sessionId = session.sessionId;
        }
        unawaited(brain.runPromptTurn(
          sessionId: sessionId,
          userPrompt: prompt,
          senderNodeId: peer.nodeInfo?.hostname ?? peer.nodeInfo?.nodeId,
        ));
        break;

      case WsTypes.chatCancel:
        final sessionId = pMap['sessionId'] as String? ?? '';
        if (sessionId.isNotEmpty) {
          await brain.cancelSessionTurn(sessionId);
        }
        break;
    }
  }

  static String remoteIpDisplay(String socketIp, String? reportedIp) {
    if (reportedIp != null &&
        reportedIp.isNotEmpty &&
        reportedIp != '127.0.0.1') {
      return reportedIp;
    }
    return socketIp;
  }

  static String _deriveSessionTitle(String prompt, String? hostname) {
    final clean = prompt.replaceAll('\n', ' ').trim();
    final shortPrompt =
        clean.length > 36 ? '${clean.substring(0, 36)}...' : clean;
    if (hostname != null && hostname.isNotEmpty) {
      return '[$hostname] $shortPrompt';
    }
    return shortPrompt;
  }

  // ---------------- REST Management API ----------------

  bool _isAuthorizedHttp(Request req) {
    final ip = _extractRemoteIp(req);
    if (_isLoopbackIp(ip)) return true;
    final auth = req.headers['authorization'] ?? '';
    if (auth.toLowerCase().startsWith('bearer ')) {
      final credential = auth.substring(7).trim();
      return store.verifyPin(credential) || store.verifyAnyToken(credential);
    }
    return false;
  }

  Future<Response> _handleApiStatus(Request req) async {
    final isLoopback = _isLoopbackIp(_extractRemoteIp(req));
    return _apiJson({
      'service': 'agy-lan-mesh',
      'hostname': Platform.localHostname,
      'port': boundPort,
      'discoveryPort': discoveryPort,
      if (isLoopback) 'pairingPin': store.pairingPin,
      if (isLoopback) 'loopbackToken': store.loopbackAdminToken,
      'onlineNodes': registry.listAllNodes().where((n) => n.online).length,
      'totalNodes': registry.listAllNodes().length,
      'totalSessions': store.listSessions().length,
      'runningSessions': brain.runningSessionIds,
    });
  }

  Future<Response> _handleApiNodes(Request req) async {
    if (!_isAuthorizedHttp(req)) return Response.forbidden('Unauthorized');
    return _apiJson({
      'nodes': registry.listAllNodes().map((n) => n.toJson()).toList(),
    });
  }

  Future<Response> _handleApiSessionsList(Request req) async {
    if (!_isAuthorizedHttp(req)) return Response.forbidden('Unauthorized');
    return _apiJson({
      'sessions': store.listSessions().map((s) => s.toSummaryJson()).toList(),
    });
  }

  Future<Response> _handleApiSessionCreate(Request req) async {
    if (!_isAuthorizedHttp(req)) return Response.forbidden('Unauthorized');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final title = body['title'] as String? ?? 'Untitled Project';
    final nodeRef = body['node'] as String? ??
        body['targetNodeId'] as String? ??
        '*';
    final workspacePath = body['workspacePath'] as String? ?? '';
    final resolved = nodeRef == '*' ? null : registry.resolveNode(nodeRef);
    final session = store.createSession(
      title: title,
      targetNodeId: resolved?.nodeId ?? nodeRef,
      targetNodeName: resolved?.hostname ?? nodeRef,
      workspacePath:
          workspacePath.isNotEmpty ? workspacePath : (resolved?.cwd ?? ''),
    );
    registry.broadcastSessionsSnapshot();
    return _apiJson({'session': session.toJson()});
  }

  Future<Response> _handleApiSessionCancel(Request req, String id) async {
    if (!_isAuthorizedHttp(req)) return Response.forbidden('Unauthorized');
    final cancelled = await brain.cancelSessionTurn(id);
    return _apiJson({'ok': true, 'cancelled': cancelled});
  }

  Future<Response> _handleApiSessionDelete(Request req, String id) async {
    if (!_isAuthorizedHttp(req)) return Response.forbidden('Unauthorized');
    await brain.cancelSessionTurn(id);
    final deleted = store.deleteSession(id);
    registry.broadcastSessionsSnapshot();
    return _apiJson({'ok': deleted});
  }

  // ---------------- Zero-Install Bootstrap Handlers ----------------

  String _inferServerHttpBase(Request req) {
    final hostHeader = req.headers['host'] ?? '127.0.0.1:$boundPort';
    return 'http://$hostHeader';
  }

  String _inferServerWsUrl(Request req) {
    final hostHeader = req.headers['host'] ?? '127.0.0.1:$boundPort';
    return 'ws://$hostHeader/ws';
  }

  Future<Response> _serveStampedPowerShellAgent(Request req) async {
    final file = File(p.join(projectRoot, 'scripts', 'agent.ps1'));
    if (!await file.exists()) {
      return Response.notFound('scripts/agent.ps1 not found');
    }
    final content = (await file.readAsString())
        .replaceAll('__DEFAULT_WS_URL__', _inferServerWsUrl(req));
    return Response.ok(
      content,
      headers: {'Content-Type': 'text/plain; charset=utf-8'},
    );
  }

  Future<Response> _serveStampedPythonAgent(Request req) async {
    final file = File(p.join(projectRoot, 'scripts', 'agent.py'));
    if (!await file.exists()) {
      return Response.notFound('scripts/agent.py not found');
    }
    final content = (await file.readAsString())
        .replaceAll('__DEFAULT_WS_URL__', _inferServerWsUrl(req));
    return Response.ok(
      content,
      headers: {'Content-Type': 'text/plain; charset=utf-8'},
    );
  }

  Future<Response> _serveStampedBashWrapper(Request req) async {
    final base = _inferServerHttpBase(req);
    final script = '''#!/usr/bin/env bash
set -euo pipefail
TMP_AGENT="\$(mktemp /tmp/agy_mesh_agent_XXXXXX.py)"
trap 'rm -f "\$TMP_AGENT"' EXIT
curl -fsSL "$base/agent.py" -o "\$TMP_AGENT"
exec python3 "\$TMP_AGENT" "\$@" </dev/tty
''';
    return Response.ok(
      script,
      headers: {'Content-Type': 'text/plain; charset=utf-8'},
    );
  }

  Future<Response> _serveFallbackDashboardHtml(Request req) async {
    final base = _inferServerHttpBase(req);
    final html = '''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>AGY LAN Mesh Hub</title>
<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:2rem;max-width:820px;margin:auto}
code,pre{background:#1e293b;padding:0.4rem 0.6rem;border-radius:6px;color:#38bdf8}pre{padding:1rem;overflow-x:auto}</style></head>
<body>
<h1>🚀 AGY LAN Mesh Hub is Running</h1>
<p>Flutter Web UI has not been built yet (run <code>flutter build web</code> inside <code>apps/mesh_client</code>).</p>
<h3>Instant Zero-Install Windows Agent (Run in Admin PowerShell):</h3>
<pre>irm $base/agent.ps1 -OutFile \$env:TEMP\\agy-agent.ps1; powershell -ExecutionPolicy Bypass -File \$env:TEMP\\agy-agent.ps1</pre>
<h3>Instant Zero-Install Linux Agent:</h3>
<pre>curl -fsSL $base/agent.sh | bash</pre>
</body></html>''';
    return Response.ok(html, headers: {'Content-Type': 'text/html'});
  }

  static String _extractRemoteIp(Request req) {
    final connInfo =
        req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    return connInfo?.remoteAddress.address ?? 'unknown';
  }

  static bool _isLoopbackIp(String ip) =>
      ip == '127.0.0.1' || ip == '::1' || ip == 'localhost';

  static Response _apiJson(Map<String, dynamic> data, {int status = 200}) =>
      Response(
        status,
        body: const JsonEncoder.withIndent('  ').convert(data),
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      );
}
