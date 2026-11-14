import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;

class DiscoveredHub {
  final String wsUrl;
  final String serverName;
  const DiscoveredHub({required this.wsUrl, required this.serverName});
}

class LocalNodeDriver {
  /// Kept strictly in local process memory—never persisted or sent over the network.
  String? _sudoPassword;

  bool get isWebConsole => false;
  bool get isDesktopTarget =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;
  bool get isAndroid => Platform.isAndroid;
  bool get isSudoUnlocked => _sudoPassword != null && _sudoPassword!.isNotEmpty;

  String get defaultHostname => Platform.localHostname;
  String get osName => Platform.operatingSystem;
  String get osVersion => Platform.operatingSystemVersion;
  String get arch => Platform.version.split(' ').last;

  String defaultInitialWsUrl() => 'ws://127.0.0.1:8765/ws';

  Future<String> defaultWorkingDirectory() async {
    if (Platform.isAndroid) {
      return Directory.systemTemp.path;
    }
    try {
      return Directory.current.path;
    } catch (_) {
      return Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
    }
  }

  List<String> get capabilities =>
      Platform.isAndroid ? const ['chat', 'fs'] : const ['exec', 'fs', 'chat'];

  Future<String> detectPrivilegeLevel() async {
    if (Platform.isAndroid) return PrivilegeLevels.standard;
    if (Platform.isWindows) {
      try {
        final res = await Process.run('net', ['session']);
        if (res.exitCode == 0) return PrivilegeLevels.admin;
      } catch (_) {}
      return PrivilegeLevels.standard;
    }
    // Linux / macOS
    try {
      final res = await Process.run('id', ['-u']);
      if (res.stdout.toString().trim() == '0') {
        return PrivilegeLevels.root;
      }
    } catch (_) {}
    if (isSudoUnlocked) return PrivilegeLevels.sudoUnlocked;
    return PrivilegeLevels.standard;
  }

  Future<bool> unlockSudo(String password) async {
    if (!Platform.isLinux && !Platform.isMacOS) return false;
    try {
      final proc = await Process.start(
        'sudo',
        ['-S', '-k', '-p', '', 'true'],
      );
      proc.stdin.writeln(password);
      await proc.stdin.flush();
      await proc.stdin.close();
      final code = await proc.exitCode.timeout(const Duration(seconds: 8));
      if (code == 0) {
        _sudoPassword = password;
        return true;
      }
    } catch (_) {}
    return false;
  }

  void lockSudo() {
    _sudoPassword = null;
  }

  Future<bool> relaunchAsWindowsAdmin() async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable.replaceAll("'", "''");
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath '$exe' -Verb RunAs",
      ]);
      if (res.exitCode == 0) {
        exit(0);
      }
    } catch (_) {}
    return false;
  }

  Future<DiscoveredHub?> discoverLanHub({int discoveryPort = 8766}) async {
    RawDatagramSocket? socket;
    try {
      final completer = Completer<DiscoveredHub?>();
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg == null) return;
          try {
            final map = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
            if (map['service'] == 'agy-lan-mesh') {
              final beacon = DiscoveryBeacon.fromJson(map);
              final host = dg.address.address;
              if (!completer.isCompleted) {
                completer.complete(
                  DiscoveredHub(
                    wsUrl: 'ws://$host:${beacon.port}/ws',
                    serverName: beacon.serverName,
                  ),
                );
              }
            }
          } catch (_) {}
        }
      }, onError: (Object _, StackTrace _) {});

      final probeBytes = utf8.encode(DiscoveryBeacon.magicProbe);
      socket.send(probeBytes, InternetAddress('255.255.255.255'), discoveryPort);

      return await completer.future.timeout(
        const Duration(milliseconds: 2200),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  Future<ExecResult> executeCommand(ExecRequest req) async {
    final sw = Stopwatch()..start();
    if (Platform.isAndroid) {
      sw.stop();
      return ExecResult(
        requestId: req.requestId,
        exitCode: 126,
        stdout: '',
        stderr: 'Android node runs in sandboxed mobile controller mode.',
        errorMessage: 'Android shell disabled',
        durationMs: sw.elapsedMilliseconds,
      );
    }

    try {
      late Process proc;
      final workingDir =
          (req.cwd != null && req.cwd!.isNotEmpty && Directory(req.cwd!).existsSync())
              ? req.cwd
              : null;

      if (Platform.isWindows) {
        proc = await Process.start(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', req.command],
          workingDirectory: workingDir,
          environment: req.env,
        );
      } else {
        final priv = await detectPrivilegeLevel();
        if (req.elevated && priv != PrivilegeLevels.root) {
          if (isSudoUnlocked) {
            proc = await Process.start(
              'sudo',
              ['-S', '-p', '', '--', 'bash', '-c', req.command],
              workingDirectory: workingDir,
              environment: req.env,
            );
            proc.stdin.writeln(_sudoPassword!);
            await proc.stdin.flush();
            await proc.stdin.close();
          } else {
            proc = await Process.start(
              'sudo',
              ['-n', '--', 'bash', '-c', req.command],
              workingDirectory: workingDir,
              environment: req.env,
            );
          }
        } else {
          proc = await Process.start(
            'bash',
            ['-c', req.command],
            workingDirectory: workingDir,
            environment: req.env,
          );
        }
      }

      final outFuture = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final errFuture = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();

      final code = await proc.exitCode.timeout(
        Duration(seconds: req.timeoutSec),
        onTimeout: () {
          proc.kill(ProcessSignal.sigterm);
          throw TimeoutException('Command timed out');
        },
      );
      sw.stop();
      return ExecResult(
        requestId: req.requestId,
        exitCode: code,
        stdout: await outFuture,
        stderr: await errFuture,
        approved: true,
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      sw.stop();
      return ExecResult(
        requestId: req.requestId,
        exitCode: 124,
        stdout: '',
        stderr: 'Command timed out after ${req.timeoutSec}s',
        approved: true,
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return ExecResult(
        requestId: req.requestId,
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        approved: true,
        durationMs: sw.elapsedMilliseconds,
        errorMessage: e.toString(),
      );
    }
  }

  Future<FileOpResult> performFileOp(
    FileOpRequest req, {
    required String defaultCwd,
  }) async {
    final resolvedPath = _expandPath(req.path, defaultCwd);
    try {
      switch (req.op) {
        case 'read':
          final f = File(resolvedPath);
          if (!await f.exists()) {
            return FileOpResult(
              requestId: req.requestId,
              ok: false,
              error: 'File not found: $resolvedPath',
            );
          }
          final content = await f.readAsString();
          final lines = content.split('\n');
          final s =
              (req.startLine ?? 1).clamp(1, lines.isEmpty ? 1 : lines.length);
          final e = (req.endLine ?? lines.length)
              .clamp(s, lines.isEmpty ? 1 : lines.length);
          final sliced = lines.isEmpty ? '' : lines.sublist(s - 1, e).join('\n');
          return FileOpResult(
            requestId: req.requestId,
            ok: true,
            content: sliced,
          );

        case 'write':
          final f = File(resolvedPath);
          await f.parent.create(recursive: true);
          await f.writeAsString(
            req.content ?? '',
            mode: req.append ? FileMode.append : FileMode.write,
          );
          return FileOpResult(
            requestId: req.requestId,
            ok: true,
            message: 'Wrote ${req.content?.length ?? 0} chars to $resolvedPath',
          );

        case 'edit':
          final f = File(resolvedPath);
          if (!await f.exists()) {
            return FileOpResult(
              requestId: req.requestId,
              ok: false,
              error: 'File not found: $resolvedPath',
            );
          }
          final text = await f.readAsString();
          final target = req.target ?? '';
          if (target.isEmpty || !text.contains(target)) {
            return FileOpResult(
              requestId: req.requestId,
              ok: false,
              error: 'Target text not found in $resolvedPath',
            );
          }
          await f.writeAsString(text.replaceAll(target, req.replacement ?? ''));
          return FileOpResult(
            requestId: req.requestId,
            ok: true,
            message: 'Edited $resolvedPath',
          );

        case 'list':
          final d = Directory(resolvedPath);
          if (!await d.exists()) {
            return FileOpResult(
              requestId: req.requestId,
              ok: false,
              error: 'Directory not found: $resolvedPath',
            );
          }
          final items = <DirEntryInfo>[];
          await for (final entity in d.list(followLinks: false)) {
            final st = await entity.stat();
            items.add(DirEntryInfo(
              name: p.basename(entity.path),
              path: entity.path,
              isDirectory: st.type == FileSystemEntityType.directory,
              size: st.size,
              modifiedAt: st.modified.toUtc().toIso8601String(),
            ));
          }
          items.sort((a, b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          return FileOpResult(
            requestId: req.requestId,
            ok: true,
            entries: items,
          );

        default:
          return FileOpResult(
            requestId: req.requestId,
            ok: false,
            error: 'Unsupported op: ${req.op}',
          );
      }
    } catch (e) {
      return FileOpResult(
        requestId: req.requestId,
        ok: false,
        error: e.toString(),
      );
    }
  }

  static String _expandPath(String rawPath, String defaultCwd) {
    var path = rawPath.trim();
    if (path.startsWith('~')) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isNotEmpty) {
        path = home + path.substring(1);
      }
    }
    if (p.isAbsolute(path)) return path;
    if (defaultCwd.isNotEmpty) return p.join(defaultCwd, path);
    return path;
  }
}
