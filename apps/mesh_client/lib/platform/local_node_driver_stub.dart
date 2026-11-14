import 'package:mesh_protocol/mesh_protocol.dart';

class DiscoveredHub {
  final String wsUrl;
  final String serverName;
  const DiscoveredHub({required this.wsUrl, required this.serverName});
}

class LocalNodeDriver {
  bool get isWebConsole => true;
  bool get isDesktopTarget => false;
  bool get isWindows => false;
  bool get isLinux => false;
  bool get isAndroid => false;
  bool get isSudoUnlocked => false;

  String get defaultHostname => 'Web Console';
  String get osName => 'web';
  String get osVersion => 'Browser';
  String get arch => 'wasm/js';

  String defaultInitialWsUrl() {
    final base = Uri.base;
    if (base.scheme == 'http' || base.scheme == 'https') {
      final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
      final portPart = base.hasPort ? ':${base.port}' : '';
      return '$wsScheme://${base.host}$portPart/ws';
    }
    return 'ws://127.0.0.1:8765/ws';
  }

  Future<String> defaultWorkingDirectory() async => '';

  Future<String> detectPrivilegeLevel() async => PrivilegeLevels.standard;

  List<String> get capabilities => const ['chat'];

  Future<DiscoveredHub?> discoverLanHub({int discoveryPort = 8766}) async =>
      null;

  Future<bool> unlockSudo(String password) async => false;

  void lockSudo() {}

  Future<bool> relaunchAsWindowsAdmin() async => false;

  Future<ExecResult> executeCommand(ExecRequest req) async {
    return ExecResult(
      requestId: req.requestId,
      exitCode: -1,
      stdout: '',
      stderr: 'Browser console does not execute host OS shell commands.',
      errorMessage: 'Unsupported on Web',
    );
  }

  Future<FileOpResult> performFileOp(
    FileOpRequest req, {
    required String defaultCwd,
  }) async {
    return FileOpResult(
      requestId: req.requestId,
      ok: false,
      error: 'Browser console does not expose host filesystem.',
    );
  }
}
