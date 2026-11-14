import 'dart:convert';

class PrivilegeLevels {
  static const String admin = 'admin';
  static const String root = 'root';
  static const String sudoUnlocked = 'sudoUnlocked';
  static const String standard = 'standard';

  static bool isElevatedCapable(String level) =>
      level == admin || level == root || level == sudoUnlocked;
}

class ApprovalModes {
  static const String fullAuto = 'fullAuto';
  static const String askForElevated = 'askForElevated';
}

class SessionStatuses {
  static const String idle = 'idle';
  static const String running = 'running';
  static const String awaitingApproval = 'awaitingApproval';
  static const String error = 'error';
}

class DiscoveryBeacon {
  static const String magicProbe = 'AGY_MESH_DISCOVER_V1';

  final String service;
  final int version;
  final String serverName;
  final int port;
  final String? suggestedHost;

  const DiscoveryBeacon({
    this.service = 'agy-lan-mesh',
    this.version = 1,
    required this.serverName,
    required this.port,
    this.suggestedHost,
  });

  Map<String, dynamic> toJson() => {
        'service': service,
        'version': version,
        'serverName': serverName,
        'port': port,
        if (suggestedHost != null) 'suggestedHost': suggestedHost,
      };

  factory DiscoveryBeacon.fromJson(Map<String, dynamic> json) =>
      DiscoveryBeacon(
        service: json['service'] as String? ?? 'agy-lan-mesh',
        version: (json['version'] as num?)?.toInt() ?? 1,
        serverName: json['serverName'] as String? ?? 'AGY Hub',
        port: (json['port'] as num?)?.toInt() ?? 8765,
        suggestedHost: json['suggestedHost'] as String?,
      );
}

class NodeInfo {
  final String nodeId;
  final String hostname;
  final String os;
  final String osVersion;
  final String arch;
  final String ipAddress;
  final String privilegeLevel;
  final String approvalMode;
  final String cwd;
  final List<String> capabilities;
  final bool online;
  final String connectedAt;
  final String lastSeenAt;

  const NodeInfo({
    required this.nodeId,
    required this.hostname,
    required this.os,
    this.osVersion = '',
    this.arch = '',
    this.ipAddress = '',
    this.privilegeLevel = PrivilegeLevels.standard,
    this.approvalMode = ApprovalModes.askForElevated,
    this.cwd = '',
    this.capabilities = const ['exec', 'fs', 'chat'],
    this.online = true,
    required this.connectedAt,
    required this.lastSeenAt,
  });

  bool get canExecute => capabilities.contains('exec');
  bool get canAccessFs => capabilities.contains('fs');

  NodeInfo copyWith({
    String? hostname,
    String? os,
    String? osVersion,
    String? arch,
    String? ipAddress,
    String? privilegeLevel,
    String? approvalMode,
    String? cwd,
    List<String>? capabilities,
    bool? online,
    String? connectedAt,
    String? lastSeenAt,
  }) {
    return NodeInfo(
      nodeId: nodeId,
      hostname: hostname ?? this.hostname,
      os: os ?? this.os,
      osVersion: osVersion ?? this.osVersion,
      arch: arch ?? this.arch,
      ipAddress: ipAddress ?? this.ipAddress,
      privilegeLevel: privilegeLevel ?? this.privilegeLevel,
      approvalMode: approvalMode ?? this.approvalMode,
      cwd: cwd ?? this.cwd,
      capabilities: capabilities ?? this.capabilities,
      online: online ?? this.online,
      connectedAt: connectedAt ?? this.connectedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'hostname': hostname,
        'os': os,
        'osVersion': osVersion,
        'arch': arch,
        'ipAddress': ipAddress,
        'privilegeLevel': privilegeLevel,
        'approvalMode': approvalMode,
        'cwd': cwd,
        'capabilities': capabilities,
        'online': online,
        'connectedAt': connectedAt,
        'lastSeenAt': lastSeenAt,
      };

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
        nodeId: json['nodeId'] as String? ?? '',
        hostname: json['hostname'] as String? ?? 'unknown',
        os: json['os'] as String? ?? 'unknown',
        osVersion: json['osVersion'] as String? ?? '',
        arch: json['arch'] as String? ?? '',
        ipAddress: json['ipAddress'] as String? ?? '',
        privilegeLevel:
            json['privilegeLevel'] as String? ?? PrivilegeLevels.standard,
        approvalMode:
            json['approvalMode'] as String? ?? ApprovalModes.askForElevated,
        cwd: json['cwd'] as String? ?? '',
        capabilities: (json['capabilities'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const ['exec', 'fs', 'chat'],
        online: json['online'] as bool? ?? false,
        connectedAt:
            json['connectedAt'] as String? ?? DateTime.now().toUtc().toIso8601String(),
        lastSeenAt:
            json['lastSeenAt'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      );
}

class ToolCallSummary {
  final String id;
  final String toolName;
  final String summary;
  final String status; // running | done | error
  final String? outputPreview;

  const ToolCallSummary({
    required this.id,
    required this.toolName,
    required this.summary,
    this.status = 'running',
    this.outputPreview,
  });

  ToolCallSummary copyWith({
    String? summary,
    String? status,
    String? outputPreview,
  }) =>
      ToolCallSummary(
        id: id,
        toolName: toolName,
        summary: summary ?? this.summary,
        status: status ?? this.status,
        outputPreview: outputPreview ?? this.outputPreview,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'summary': summary,
        'status': status,
        if (outputPreview != null) 'outputPreview': outputPreview,
      };

  factory ToolCallSummary.fromJson(Map<String, dynamic> json) =>
      ToolCallSummary(
        id: json['id'] as String? ?? '',
        toolName: json['toolName'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        status: json['status'] as String? ?? 'done',
        outputPreview: json['outputPreview'] as String?,
      );
}

class SessionMessage {
  final String id;
  final String role; // user | assistant | system
  final String text;
  final String thinking;
  final List<ToolCallSummary> toolEvents;
  final String timestamp;
  final String status; // streaming | done | error

  const SessionMessage({
    required this.id,
    required this.role,
    required this.text,
    this.thinking = '',
    this.toolEvents = const [],
    required this.timestamp,
    this.status = 'done',
  });

  SessionMessage copyWith({
    String? text,
    String? thinking,
    List<ToolCallSummary>? toolEvents,
    String? status,
  }) =>
      SessionMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        thinking: thinking ?? this.thinking,
        toolEvents: toolEvents ?? this.toolEvents,
        timestamp: timestamp,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        'thinking': thinking,
        'toolEvents': toolEvents.map((e) => e.toJson()).toList(),
        'timestamp': timestamp,
        'status': status,
      };

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
        id: json['id'] as String? ?? '',
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
        thinking: json['thinking'] as String? ?? '',
        toolEvents: (json['toolEvents'] as List<dynamic>?)
                ?.map((e) =>
                    ToolCallSummary.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        timestamp:
            json['timestamp'] as String? ?? DateTime.now().toUtc().toIso8601String(),
        status: json['status'] as String? ?? 'done',
      );
}

class MeshSession {
  final String sessionId;
  final String title;
  final String targetNodeId; // nodeId or '*' for fleet-wide
  final String targetNodeName;
  final String workspacePath; // project root path on targetNodeId
  final String? agyConversationId;
  final String status;
  final String createdAt;
  final String updatedAt;
  final List<SessionMessage> messages;

  const MeshSession({
    required this.sessionId,
    required this.title,
    required this.targetNodeId,
    this.targetNodeName = '',
    this.workspacePath = '',
    this.agyConversationId,
    this.status = SessionStatuses.idle,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
  });

  MeshSession copyWith({
    String? title,
    String? targetNodeId,
    String? targetNodeName,
    String? workspacePath,
    String? agyConversationId,
    String? status,
    String? updatedAt,
    List<SessionMessage>? messages,
  }) =>
      MeshSession(
        sessionId: sessionId,
        title: title ?? this.title,
        targetNodeId: targetNodeId ?? this.targetNodeId,
        targetNodeName: targetNodeName ?? this.targetNodeName,
        workspacePath: workspacePath ?? this.workspacePath,
        agyConversationId: agyConversationId ?? this.agyConversationId,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messages: messages ?? this.messages,
      );

  /// Lightweight summary without full message bodies for fast fleet session lists.
  Map<String, dynamic> toSummaryJson() => {
        'sessionId': sessionId,
        'title': title,
        'targetNodeId': targetNodeId,
        'targetNodeName': targetNodeName,
        'workspacePath': workspacePath,
        'agyConversationId': agyConversationId,
        'status': status,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'messageCount': messages.length,
        'lastMessagePreview': messages.isNotEmpty
            ? (messages.last.text.length > 100
                ? '${messages.last.text.substring(0, 100)}...'
                : messages.last.text)
            : '',
      };

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'title': title,
        'targetNodeId': targetNodeId,
        'targetNodeName': targetNodeName,
        'workspacePath': workspacePath,
        'agyConversationId': agyConversationId,
        'status': status,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory MeshSession.fromJson(Map<String, dynamic> json) => MeshSession(
        sessionId: json['sessionId'] as String? ?? '',
        title: json['title'] as String? ?? 'Untitled Project Session',
        targetNodeId: json['targetNodeId'] as String? ?? '*',
        targetNodeName: json['targetNodeName'] as String? ?? '',
        workspacePath: json['workspacePath'] as String? ?? '',
        agyConversationId: json['agyConversationId'] as String?,
        status: json['status'] as String? ?? SessionStatuses.idle,
        createdAt:
            json['createdAt'] as String? ?? DateTime.now().toUtc().toIso8601String(),
        updatedAt:
            json['updatedAt'] as String? ?? DateTime.now().toUtc().toIso8601String(),
        messages: (json['messages'] as List<dynamic>?)
                ?.map((m) =>
                    SessionMessage.fromJson(Map<String, dynamic>.from(m as Map)))
                .toList() ??
            const [],
      );
}

class ExecRequest {
  final String requestId;
  final String command;
  final String? cwd;
  final Map<String, String>? env;
  final bool elevated;
  final int timeoutSec;
  final String? requestingSessionTitle;

  const ExecRequest({
    required this.requestId,
    required this.command,
    this.cwd,
    this.env,
    this.elevated = false,
    this.timeoutSec = 120,
    this.requestingSessionTitle,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'command': command,
        if (cwd != null && cwd!.isNotEmpty) 'cwd': cwd,
        if (env != null && env!.isNotEmpty) 'env': env,
        'elevated': elevated,
        'timeoutSec': timeoutSec,
        if (requestingSessionTitle != null)
          'requestingSessionTitle': requestingSessionTitle,
      };

  factory ExecRequest.fromJson(Map<String, dynamic> json) => ExecRequest(
        requestId: json['requestId'] as String? ?? '',
        command: json['command'] as String? ?? '',
        cwd: json['cwd'] as String?,
        env: (json['env'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v.toString())),
        elevated: json['elevated'] as bool? ?? false,
        timeoutSec: (json['timeoutSec'] as num?)?.toInt() ?? 120,
        requestingSessionTitle: json['requestingSessionTitle'] as String?,
      );
}

class ExecResult {
  final String requestId;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool approved;
  final int durationMs;
  final String? errorMessage;

  const ExecResult({
    required this.requestId,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.approved = true,
    this.durationMs = 0,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'exitCode': exitCode,
        'stdout': stdout,
        'stderr': stderr,
        'approved': approved,
        'durationMs': durationMs,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  factory ExecResult.fromJson(Map<String, dynamic> json) => ExecResult(
        requestId: json['requestId'] as String? ?? '',
        exitCode: (json['exitCode'] as num?)?.toInt() ?? -1,
        stdout: json['stdout'] as String? ?? '',
        stderr: json['stderr'] as String? ?? '',
        approved: json['approved'] as bool? ?? true,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        errorMessage: json['errorMessage'] as String?,
      );
}

class FileOpRequest {
  final String requestId;
  final String op; // read | write | edit | list
  final String path;
  final String? content;
  final String? target;
  final String? replacement;
  final bool append;
  final int? startLine;
  final int? endLine;

  const FileOpRequest({
    required this.requestId,
    required this.op,
    required this.path,
    this.content,
    this.target,
    this.replacement,
    this.append = false,
    this.startLine,
    this.endLine,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'op': op,
        'path': path,
        if (content != null) 'content': content,
        if (target != null) 'target': target,
        if (replacement != null) 'replacement': replacement,
        'append': append,
        if (startLine != null) 'startLine': startLine,
        if (endLine != null) 'endLine': endLine,
      };

  factory FileOpRequest.fromJson(Map<String, dynamic> json) => FileOpRequest(
        requestId: json['requestId'] as String? ?? '',
        op: json['op'] as String? ?? 'read',
        path: json['path'] as String? ?? '',
        content: json['content'] as String?,
        target: json['target'] as String?,
        replacement: json['replacement'] as String?,
        append: json['append'] as bool? ?? false,
        startLine: (json['startLine'] as num?)?.toInt(),
        endLine: (json['endLine'] as num?)?.toInt(),
      );
}

class DirEntryInfo {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final String modifiedAt;

  const DirEntryInfo({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modifiedAt = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isDirectory': isDirectory,
        'size': size,
        'modifiedAt': modifiedAt,
      };

  factory DirEntryInfo.fromJson(Map<String, dynamic> json) => DirEntryInfo(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDirectory: json['isDirectory'] as bool? ?? false,
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedAt: json['modifiedAt'] as String? ?? '',
      );
}

class FileOpResult {
  final String requestId;
  final bool ok;
  final String? content;
  final List<DirEntryInfo>? entries;
  final String? message;
  final String? error;

  const FileOpResult({
    required this.requestId,
    required this.ok,
    this.content,
    this.entries,
    this.message,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'ok': ok,
        if (content != null) 'content': content,
        if (entries != null)
          'entries': entries!.map((e) => e.toJson()).toList(),
        if (message != null) 'message': message,
        if (error != null) 'error': error,
      };

  factory FileOpResult.fromJson(Map<String, dynamic> json) => FileOpResult(
        requestId: json['requestId'] as String? ?? '',
        ok: json['ok'] as bool? ?? false,
        content: json['content'] as String?,
        entries: (json['entries'] as List<dynamic>?)
            ?.map((e) =>
                DirEntryInfo.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        message: json['message'] as String?,
        error: json['error'] as String?,
      );

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
