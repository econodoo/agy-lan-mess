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
  final Map<String, Process> _runningProcesses = {};
  Process? _spawnedHubProcess;

  bool get isWebConsole => false;
  bool get isDesktopTarget =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;
  bool get isAndroid => Platform.isAndroid;
  bool get isSudoUnlocked => _sudoPassword != null && _sudoPassword!.isNotEmpty;
  bool get hasBundledServerBinary => findBundledServerBinary() != null;
  bool get isManagingLocalHub => _spawnedHubProcess != null;

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
        const Duration(milliseconds: 1400),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  String? findBundledServerBinary() {
    if (!isDesktopTarget) return null;
    final binName = Platform.isWindows ? 'agy-mesh-server.exe' : 'agy-mesh-server';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      p.join(exeDir, binName),
      p.normalize(p.join(exeDir, '..', binName)),
      p.normalize(p.join(exeDir, '..', 'server', binName)),
      p.normalize(p.join(exeDir, '..', '..', 'server', binName)),
      p.normalize(p.join(exeDir, '..', '..', '..', binName)),
      p.normalize(p.join(exeDir, '..', '..', '..', 'server', binName)),
      p.normalize(
        p.join(exeDir, '..', '..', '..', '..', '..', '..', 'build', binName),
      ),
      p.normalize(p.join(Directory.current.path, 'build', binName)),
      p.normalize(p.join(Directory.current.path, binName)),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<Map<String, dynamic>?> probeLocalHubStatus({int port = 8765}) async {
    if (Platform.isAndroid) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 450);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/api/status'))
          .timeout(const Duration(milliseconds: 500));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 600));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['service'] == 'agy-lan-mesh') {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isLocalAgyCliPresent() async {
    try {
      final res = await Process.run(
        'agy',
        ['--version'],
        runInShell: Platform.isWindows,
      ).timeout(const Duration(seconds: 2));
      return res.exitCode == 0;
    } catch (_) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty &&
          File(p.join(home, '.gemini', 'antigravity-cli', 'bin', 'agy'))
              .existsSync()) {
        return true;
      }
      return false;
    }
  }

  /// Automatically boots the bundled `agy-mesh-server` in the background when
  /// running the single Desktop App executable on the Brain computer.
  Future<bool> ensureLocalHubRunning({
    int port = 8765,
    bool force = false,
  }) async {
    if (!isDesktopTarget) return false;
    if (await probeLocalHubStatus(port: port) != null) return true;

    final serverBin = findBundledServerBinary();
    if (serverBin == null) return false;

    if (!force && !await _isLocalAgyCliPresent()) {
      return false;
    }

    try {
      final home = Platform.environment['HOME'] ?? '';
      final fallbackAgy = home.isNotEmpty
          ? p.join(home, '.gemini', 'antigravity-cli', 'bin', 'agy')
          : '';
      final extraArgs = <String>[
        'start',
        '--port',
        '$port',
        '--expose-local-node',
        if (fallbackAgy.isNotEmpty && File(fallbackAgy).existsSync()) ...[
          '--agy-bin',
          fallbackAgy,
        ],
      ];
      final proc = await Process.start(
        serverBin,
        extraArgs,
        workingDirectory: File(serverBin).parent.path,
      );
      _spawnedHubProcess = proc;
      // Drain pipes so child process never blocks on stdout/stderr buffers
      proc.stdout.drain<void>().ignore();
      proc.stderr.drain<void>().ignore();
      unawaited(proc.exitCode.then((_) {
        if (identical(_spawnedHubProcess, proc)) {
          _spawnedHubProcess = null;
        }
      }));

      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (await probeLocalHubStatus(port: port) != null) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  void stopSpawnedLocalHub() {
    final proc = _spawnedHubProcess;
    _spawnedHubProcess = null;
    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  Future<bool> killRunningCommand(String requestId) async {
    final proc = _runningProcesses[requestId];
    if (proc == null) return false;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill(ProcessSignal.sigterm);
        Timer(const Duration(seconds: 2), () {
          if (_runningProcesses.containsKey(requestId)) {
            try {
              proc.kill(ProcessSignal.sigkill);
            } catch (_) {}
          }
        });
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ExecResult> executeCommand(
    ExecRequest req, {
    void Function(ExecHeartbeat hb)? onHeartbeat,
  }) async {
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

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    Timer? hbTimer;

    try {
      late Process proc;
      final workingDir = (req.cwd != null &&
              req.cwd!.isNotEmpty &&
              Directory(req.cwd!).existsSync())
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

      _runningProcesses[req.requestId] = proc;

      final outDone = Completer<void>();
      final errDone = Completer<void>();
      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) => outBuf.write(chunk),
        onDone: () {
          if (!outDone.isCompleted) outDone.complete();
        },
        onError: (_) {
          if (!outDone.isCompleted) outDone.complete();
        },
      );
      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) => errBuf.write(chunk),
        onDone: () {
          if (!errDone.isCompleted) errDone.complete();
        },
        onError: (_) {
          if (!errDone.isCompleted) errDone.complete();
        },
      );

      void emitHeartbeat() {
        if (onHeartbeat == null) return;
        final sOut = outBuf.toString();
        final sErr = errBuf.toString();
        onHeartbeat(ExecHeartbeat(
          requestId: req.requestId,
          pid: proc.pid,
          alive: true,
          elapsedMs: sw.elapsedMilliseconds,
          stdoutBytes: sOut.length,
          stderrBytes: sErr.length,
          stdoutTail:
              sOut.length > 2000 ? sOut.substring(sOut.length - 2000) : sOut,
          stderrTail:
              sErr.length > 1000 ? sErr.substring(sErr.length - 1000) : sErr,
        ));
      }

      // Immediately report PID & start heartbeat stream every 5 seconds
      emitHeartbeat();
      hbTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        emitHeartbeat();
      });

      int code;
      if (req.timeoutSec > 0) {
        code = await proc.exitCode.timeout(
          Duration(seconds: req.timeoutSec),
          onTimeout: () {
            unawaited(killRunningCommand(req.requestId));
            throw TimeoutException('Hard timeout reached');
          },
        );
      } else {
        // No arbitrary wall-clock kill—wait as long as process runs!
        code = await proc.exitCode;
      }

      await Future.wait([outDone.future, errDone.future]);
      sw.stop();
      hbTimer.cancel();
      _runningProcesses.remove(req.requestId);

      return ExecResult(
        requestId: req.requestId,
        exitCode: code,
        stdout: outBuf.toString(),
        stderr: errBuf.toString(),
        approved: true,
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      sw.stop();
      hbTimer?.cancel();
      _runningProcesses.remove(req.requestId);
      return ExecResult(
        requestId: req.requestId,
        exitCode: 124,
        stdout: outBuf.toString(),
        stderr:
            '${errBuf.toString()}\nCommand reached explicit hard timeout (${req.timeoutSec}s)'
                .trim(),
        approved: true,
        durationMs: sw.elapsedMilliseconds,
        errorMessage: 'Hard timeout',
      );
    } catch (e) {
      sw.stop();
      hbTimer?.cancel();
      _runningProcesses.remove(req.requestId);
      return ExecResult(
        requestId: req.requestId,
        exitCode: -1,
        stdout: outBuf.toString(),
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
