import 'dart:convert';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'node_registry.dart';
import 'pairing_store.dart';

class McpHttpHandler {
  final NodeRegistry registry;
  final PairingAndSessionStore store;
  final void Function(String? sessionId, ToolCallSummary toolEvent)?
      onToolActivity;
  final _uuid = const Uuid();

  McpHttpHandler({
    required this.registry,
    required this.store,
    this.onToolActivity,
  });

  static const List<String> allToolNames = [
    'mesh_list_nodes',
    'mesh_list_sessions',
    'mesh_upsert_session',
    'mesh_exec',
    'mesh_read_file',
    'mesh_write_file',
    'mesh_edit_file',
    'mesh_list_dir',
  ];

  Future<Response> handle(Request request) async {
    if (request.method == 'GET') {
      // Per MCP Streamable HTTP 2025-03-26 spec: return 405 if server does not open standalone SSE push stream
      return Response(405, headers: {'Allow': 'POST, DELETE, OPTIONS'});
    }
    if (request.method == 'DELETE') {
      return Response.ok('');
    }
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: _corsHeaders);
    }
    if (request.method != 'POST') {
      return Response(405);
    }

    final rawBody = await request.readAsString();
    if (rawBody.trim().isEmpty) {
      return _jsonResponse(
        _rpcError(null, -32700, 'Empty JSON-RPC body'),
        statusCode: 400,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (e) {
      return _jsonResponse(
        _rpcError(null, -32700, 'Parse error: $e'),
        statusCode: 400,
      );
    }

    final sessionHeader =
        request.headers['mcp-session-id'] ?? _uuid.v4();

    if (decoded is List) {
      final responses = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final res = await _dispatchSingle(item);
          if (res != null) responses.add(res);
        }
      }
      if (responses.isEmpty) {
        return Response(202, headers: {
          ..._corsHeaders,
          'Mcp-Session-Id': sessionHeader,
        });
      }
      return _jsonResponse(responses, sessionId: sessionHeader);
    } else if (decoded is Map<String, dynamic>) {
      final res = await _dispatchSingle(decoded);
      if (res == null) {
        // Notification (no 'id') -> 202 Accepted
        return Response(202, headers: {
          ..._corsHeaders,
          'Mcp-Session-Id': sessionHeader,
        });
      }
      return _jsonResponse(res, sessionId: sessionHeader);
    }

    return _jsonResponse(
      _rpcError(null, -32600, 'Invalid JSON-RPC request'),
      statusCode: 400,
    );
  }

  Future<Map<String, dynamic>?> _dispatchSingle(
    Map<String, dynamic> msg,
  ) async {
    final hasId = msg.containsKey('id');
    final id = msg['id'];
    final method = msg['method'] as String? ?? '';
    final params = msg['params'] is Map
        ? Map<String, dynamic>.from(msg['params'] as Map)
        : <String, dynamic>{};

    if (!hasId) {
      // JSON-RPC Notification (e.g., notifications/initialized, notifications/cancelled)
      return null;
    }

    try {
      switch (method) {
        case 'initialize':
          final requestedVersion =
              params['protocolVersion'] as String? ?? '2025-03-26';
          final negotiated = const {
            '2024-11-05',
            '2025-03-26',
            '2025-06-18',
          }.contains(requestedVersion)
              ? requestedVersion
              : '2025-03-26';
          return _rpcResult(id, {
            'protocolVersion': negotiated,
            'capabilities': {
              'tools': {'listChanged': false},
            },
            'serverInfo': {
              'name': 'lan-mesh',
              'version': '1.0.0',
            },
          });

        case 'ping':
          return _rpcResult(id, <String, dynamic>{});

        case 'tools/list':
          return _rpcResult(id, {'tools': _toolDefinitions()});

        case 'tools/call':
          final name = params['name'] as String? ?? '';
          final args = params['arguments'] is Map
              ? Map<String, dynamic>.from(params['arguments'] as Map)
              : <String, dynamic>{};
          final toolResult = await _executeTool(name, args);
          return _rpcResult(id, toolResult);

        default:
          return _rpcError(id, -32601, 'Method not found: $method');
      }
    } catch (e) {
      return _rpcError(id, -32603, 'Internal MCP error: $e');
    }
  }

  Future<Map<String, dynamic>> _executeTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final sessionId = args['session_id'] as String?;
    final linkedSession =
        (sessionId != null && sessionId.isNotEmpty) ? store.getSession(sessionId) : null;

    // Resolve target node from explicit 'node' arg OR linked session's targetNodeId
    String resolveNodeRef() {
      final explicit = (args['node'] as String?)?.trim() ?? '';
      if (explicit.isNotEmpty) return explicit;
      if (linkedSession != null &&
          linkedSession.targetNodeId.isNotEmpty &&
          linkedSession.targetNodeId != '*') {
        return linkedSession.targetNodeId;
      }
      return '';
    }

    final callId = _uuid.v4();

    switch (name) {
      case 'mesh_list_nodes':
        final nodes = registry.listAllNodes();
        final formatted = const JsonEncoder.withIndent('  ')
            .convert(nodes.map((n) => n.toJson()).toList());
        return _mcpTextContent(
          nodes.isEmpty
              ? 'No LAN nodes paired yet. Start a Flutter client or run agent.ps1 / agent.py on a target machine.'
              : formatted,
        );

      case 'mesh_list_sessions':
        final sessions = store.listSessions();
        final formatted = const JsonEncoder.withIndent('  ')
            .convert(sessions.map((s) => s.toSummaryJson()).toList());
        return _mcpTextContent(
          sessions.isEmpty ? 'No project sessions created yet.' : formatted,
        );

      case 'mesh_upsert_session':
        final title = (args['title'] as String?)?.trim() ?? 'Project Session';
        final nodeArg = (args['node'] as String?)?.trim() ?? '*';
        final workspacePath = (args['workspace_path'] as String?)?.trim() ?? '';
        final existingId = (args['session_id'] as String?)?.trim();
        final resolvedNode = nodeArg == '*' ? null : registry.resolveNode(nodeArg);
        final targetId = resolvedNode?.nodeId ?? nodeArg;
        final targetName = resolvedNode?.hostname ?? nodeArg;

        MeshSession session;
        if (existingId != null &&
            existingId.isNotEmpty &&
            store.getSession(existingId) != null) {
          session = store.updateSessionMeta(
            existingId,
            title: title,
            targetNodeId: targetId,
            targetNodeName: targetName,
            workspacePath: workspacePath,
          )!;
        } else {
          session = store.createSession(
            title: title,
            targetNodeId: targetId,
            targetNodeName: targetName,
            workspacePath: workspacePath,
          );
        }
        registry.broadcastSessionsSnapshot();
        return _mcpTextContent(
          const JsonEncoder.withIndent('  ').convert(session.toSummaryJson()),
        );

      case 'mesh_exec':
        final nodeRef = resolveNodeRef();
        final command = args['command'] as String? ?? '';
        if (nodeRef.isEmpty || command.trim().isEmpty) {
          return _mcpTextContent(
            'Error: Both "node" (or a bound "session_id") and "command" are required.',
            isError: true,
          );
        }
        final cwd = (args['cwd'] as String?)?.trim().isNotEmpty == true
            ? (args['cwd'] as String).trim()
            : (linkedSession?.workspacePath.isNotEmpty == true
                ? linkedSession!.workspacePath
                : null);
        final elevated = args['elevated'] as bool? ?? false;
        final timeoutSec = (args['timeout_sec'] as num?)?.toInt() ?? 120;

        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_exec',
            summary:
                '[${elevated ? "ELEVATED " : ""}$nodeRef] $command',
            status: 'running',
          ),
        );

        final res = await registry.executeCommand(
          nodeRef: nodeRef,
          command: command,
          cwd: cwd,
          elevated: elevated,
          timeoutSec: timeoutSec,
          requestingSessionTitle: linkedSession?.title,
        );

        final isErr = !res.approved || res.errorMessage != null;
        final preview = (res.stdout.isNotEmpty ? res.stdout : res.stderr).trim();
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_exec',
            summary:
                '[${elevated ? "ELEVATED " : ""}$nodeRef] $command (exit ${res.exitCode})',
            status: (isErr || res.exitCode != 0) ? 'error' : 'done',
            outputPreview:
                preview.length > 300 ? '${preview.substring(0, 300)}...' : preview,
          ),
        );

        final summaryBuf = StringBuffer()
          ..writeln('Exit Code: ${res.exitCode} (${res.durationMs}ms)')
          ..writeln('Approved: ${res.approved}');
        if (res.errorMessage != null) {
          summaryBuf.writeln('Error: ${res.errorMessage}');
        }
        if (res.stdout.isNotEmpty) {
          summaryBuf.writeln('--- STDOUT ---\n${res.stdout}');
        }
        if (res.stderr.isNotEmpty) {
          summaryBuf.writeln('--- STDERR ---\n${res.stderr}');
        }
        return _mcpTextContent(summaryBuf.toString(), isError: isErr);

      case 'mesh_read_file':
        final nodeRef = resolveNodeRef();
        final path = args['path'] as String? ?? '';
        if (nodeRef.isEmpty || path.isEmpty) {
          return _mcpTextContent(
            'Error: "node" and "path" are required.',
            isError: true,
          );
        }
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_read_file',
            summary: '[$nodeRef] Read $path',
            status: 'running',
          ),
        );
        final res = await registry.performFileOp(
          nodeRef: nodeRef,
          op: 'read',
          path: path,
          baseWorkspacePath: linkedSession?.workspacePath,
          startLine: (args['start_line'] as num?)?.toInt(),
          endLine: (args['end_line'] as num?)?.toInt(),
        );
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_read_file',
            summary: '[$nodeRef] Read $path',
            status: res.ok ? 'done' : 'error',
          ),
        );
        return res.ok
            ? _mcpTextContent(res.content ?? '')
            : _mcpTextContent('Error: ${res.error}', isError: true);

      case 'mesh_write_file':
        final nodeRef = resolveNodeRef();
        final path = args['path'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        final append = args['append'] as bool? ?? false;
        if (nodeRef.isEmpty || path.isEmpty) {
          return _mcpTextContent(
            'Error: "node" and "path" are required.',
            isError: true,
          );
        }
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_write_file',
            summary: '[$nodeRef] Write $path',
            status: 'running',
          ),
        );
        final res = await registry.performFileOp(
          nodeRef: nodeRef,
          op: 'write',
          path: path,
          baseWorkspacePath: linkedSession?.workspacePath,
          content: content,
          append: append,
        );
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_write_file',
            summary: '[$nodeRef] Write $path',
            status: res.ok ? 'done' : 'error',
          ),
        );
        return res.ok
            ? _mcpTextContent(res.message ?? 'OK')
            : _mcpTextContent('Error: ${res.error}', isError: true);

      case 'mesh_edit_file':
        final nodeRef = resolveNodeRef();
        final path = args['path'] as String? ?? '';
        final target = args['target'] as String? ?? '';
        final replacement = args['replacement'] as String? ?? '';
        if (nodeRef.isEmpty || path.isEmpty || target.isEmpty) {
          return _mcpTextContent(
            'Error: "node", "path", and non-empty "target" are required.',
            isError: true,
          );
        }
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_edit_file',
            summary: '[$nodeRef] Edit $path',
            status: 'running',
          ),
        );
        final res = await registry.performFileOp(
          nodeRef: nodeRef,
          op: 'edit',
          path: path,
          baseWorkspacePath: linkedSession?.workspacePath,
          target: target,
          replacement: replacement,
        );
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_edit_file',
            summary: '[$nodeRef] Edit $path',
            status: res.ok ? 'done' : 'error',
          ),
        );
        return res.ok
            ? _mcpTextContent(res.message ?? 'Edited successfully')
            : _mcpTextContent('Error: ${res.error}', isError: true);

      case 'mesh_list_dir':
        final nodeRef = resolveNodeRef();
        final path = args['path'] as String? ?? '.';
        if (nodeRef.isEmpty) {
          return _mcpTextContent('Error: "node" is required.', isError: true);
        }
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_list_dir',
            summary: '[$nodeRef] List $path',
            status: 'running',
          ),
        );
        final res = await registry.performFileOp(
          nodeRef: nodeRef,
          op: 'list',
          path: path,
          baseWorkspacePath: linkedSession?.workspacePath,
        );
        onToolActivity?.call(
          sessionId,
          ToolCallSummary(
            id: callId,
            toolName: 'mesh_list_dir',
            summary: '[$nodeRef] List $path',
            status: res.ok ? 'done' : 'error',
          ),
        );
        if (!res.ok) {
          return _mcpTextContent('Error: ${res.error}', isError: true);
        }
        final formatted = const JsonEncoder.withIndent('  ')
            .convert((res.entries ?? const []).map((e) => e.toJson()).toList());
        return _mcpTextContent(formatted);

      default:
        return _mcpTextContent('Unknown MCP tool: $name', isError: true);
    }
  }

  List<Map<String, dynamic>> _toolDefinitions() => [
        {
          'name': 'mesh_list_nodes',
          'description':
              'List all paired LAN computers/devices connected to AGY LAN Mesh, including hostname, nodeId, OS, IP, privilege level (admin/root/sudoUnlocked/standard), approval mode, and online status.',
          'inputSchema': {
            'type': 'object',
            'properties': <String, dynamic>{},
          },
        },
        {
          'name': 'mesh_list_sessions',
          'description':
              'List all multi-project workspace sessions managed by the AGY LAN Mesh server across target machines.',
          'inputSchema': {
            'type': 'object',
            'properties': <String, dynamic>{},
          },
        },
        {
          'name': 'mesh_upsert_session',
          'description':
              'Create or update a named project session pinned to a specific LAN computer and remote project workspace directory.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'session_id': {
                'type': 'string',
                'description':
                    'Optional existing sessionId to update; omit to create a new session.',
              },
              'title': {
                'type': 'string',
                'description':
                    'Human-readable project/session name (e.g. "Win-PC WebApp").',
              },
              'node': {
                'type': 'string',
                'description':
                    'Target nodeId or hostname (or "*" for fleet-wide).',
              },
              'workspace_path': {
                'type': 'string',
                'description':
                    'Absolute path to the project folder on the target computer.',
              },
            },
            'required': ['title', 'node'],
          },
        },
        {
          'name': 'mesh_exec',
          'description':
              'Execute a shell command (PowerShell on Windows, bash/sh on Linux) on a target LAN computer. Set elevated=true when root/sudo/Administrator privileges are required.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'node': {
                'type': 'string',
                'description': 'Target computer nodeId or hostname.',
              },
              'command': {
                'type': 'string',
                'description': 'Shell command string to execute.',
              },
              'cwd': {
                'type': 'string',
                'description':
                    'Optional working directory on the remote computer (defaults to the session workspace_path or node cwd).',
              },
              'elevated': {
                'type': 'boolean',
                'description':
                    'Set true to run via local sudo on Linux or verify Administrator on Windows.',
              },
              'timeout_sec': {
                'type': 'integer',
                'description': 'Timeout in seconds (default 120).',
              },
              'session_id': {
                'type': 'string',
                'description':
                    'Optional Mesh sessionId to inherit target node & workspace_path and attach live UI progress.',
              },
            },
            'required': ['node', 'command'],
          },
        },
        {
          'name': 'mesh_read_file',
          'description':
              'Read the text contents of a file on a remote LAN computer, optionally restricted to a 1-based inclusive line range.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'node': {
                'type': 'string',
                'description': 'Target computer nodeId or hostname.',
              },
              'path': {
                'type': 'string',
                'description':
                    'Absolute path (or relative to session workspace_path) on the remote computer.',
              },
              'start_line': {
                'type': 'integer',
                'description': 'Optional 1-based start line.',
              },
              'end_line': {
                'type': 'integer',
                'description': 'Optional 1-based inclusive end line.',
              },
              'session_id': {'type': 'string'},
            },
            'required': ['node', 'path'],
          },
        },
        {
          'name': 'mesh_write_file',
          'description':
              'Create, overwrite, or append to a file on a remote LAN computer (parent directories are created automatically).',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'node': {
                'type': 'string',
                'description': 'Target computer nodeId or hostname.',
              },
              'path': {
                'type': 'string',
                'description':
                    'Destination path on the remote computer.',
              },
              'content': {
                'type': 'string',
                'description': 'Text content to write.',
              },
              'append': {
                'type': 'boolean',
                'description': 'True to append rather than overwrite.',
              },
              'session_id': {'type': 'string'},
            },
            'required': ['node', 'path', 'content'],
          },
        },
        {
          'name': 'mesh_edit_file',
          'description':
              'Replace an exact target text block with replacement text inside an existing file on a remote LAN computer.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'node': {
                'type': 'string',
                'description': 'Target computer nodeId or hostname.',
              },
              'path': {
                'type': 'string',
                'description': 'File path on the remote computer.',
              },
              'target': {
                'type': 'string',
                'description': 'Exact character sequence to replace.',
              },
              'replacement': {
                'type': 'string',
                'description': 'Replacement text.',
              },
              'session_id': {'type': 'string'},
            },
            'required': ['node', 'path', 'target', 'replacement'],
          },
        },
        {
          'name': 'mesh_list_dir',
          'description':
              'List files and subdirectories at a path on a remote LAN computer.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'node': {
                'type': 'string',
                'description': 'Target computer nodeId or hostname.',
              },
              'path': {
                'type': 'string',
                'description':
                    'Directory path on the remote computer (or "." for project workspace root).',
              },
              'session_id': {'type': 'string'},
            },
            'required': ['node'],
          },
        },
      ];

  static Map<String, dynamic> _mcpTextContent(
    String text, {
    bool isError = false,
  }) =>
      {
        'content': [
          {'type': 'text', 'text': text},
        ],
        if (isError) 'isError': true,
      };

  static Map<String, dynamic> _rpcResult(dynamic id, dynamic result) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };

  static Map<String, dynamic> _rpcError(
    dynamic id,
    int code,
    String message,
  ) =>
      {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  static const Map<String, String> _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
        'Content-Type, Accept, Authorization, Mcp-Session-Id',
    'Access-Control-Expose-Headers': 'Mcp-Session-Id',
  };

  static Response _jsonResponse(
    Object body, {
    int statusCode = 200,
    String? sessionId,
  }) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        ..._corsHeaders,
        if (sessionId != null) 'Mcp-Session-Id': sessionId,
      },
    );
  }
}
