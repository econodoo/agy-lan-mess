import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;

class BrainDiagnosticsService {
  final String agyExecutable;
  final String mcpServerName;

  String selectedModelOverride = '';
  String _lastQuotaStatus = 'unchecked';
  String _lastQuotaMessage =
      'Click "Verify Brain & Quota" to run a live turn check.';
  int? _lastPingLatencyMs;

  int cumulativeTurns = 0;
  int cumulativeInputTokens = 0;
  int cumulativeOutputTokens = 0;
  int cumulativeThinkingTokens = 0;

  BrainHealthStatus? _cachedStatus;

  BrainDiagnosticsService({
    this.agyExecutable = 'agy',
    this.mcpServerName = 'lan-mesh',
  });

  BrainHealthStatus? get cachedStatus => _cachedStatus;

  void recordTurnUsage({
    required int inputTokens,
    required int outputTokens,
    required int thinkingTokens,
    bool quotaError = false,
    String? errorMessage,
  }) {
    cumulativeTurns += 1;
    cumulativeInputTokens += inputTokens;
    cumulativeOutputTokens += outputTokens;
    cumulativeThinkingTokens += thinkingTokens;
    if (quotaError) {
      _lastQuotaStatus = 'exhausted';
      _lastQuotaMessage = errorMessage ?? 'Quota or rate limit reached.';
    } else if (errorMessage == null) {
      _lastQuotaStatus = 'healthy';
      _lastQuotaMessage = 'Active (verified on latest Brain turn)';
    }
  }

  Future<BrainHealthStatus> inspect({bool runLivePing = false}) async {
    var cliInstalled = false;
    var loggedIn = false;
    final models = <BrainModelOption>[];
    var mcpRegistered = false;

    // 1. Query `agy models` to verify binary + Cloud OAuth + fetch model catalog
    try {
      final res = await Process.run(
        agyExecutable,
        ['models'],
        runInShell: Platform.isWindows,
      ).timeout(const Duration(seconds: 15));

      cliInstalled = true;
      final out = res.stdout.toString();
      for (final line in const LineSplitter().convert(out)) {
        if (line.contains('\t')) {
          final parts = line.split('\t');
          final id = parts.first.trim();
          final label = parts.sublist(1).join(' ').trim();
          if (id.isNotEmpty && label.isNotEmpty) {
            models.add(BrainModelOption(id: id, label: label));
          }
        }
      }
      loggedIn = res.exitCode == 0 && models.isNotEmpty;
    } catch (_) {
      cliInstalled = false;
    }

    // 2. Check `agy mcp list` for `lan-mesh`
    if (cliInstalled) {
      try {
        final mcpRes = await Process.run(
          agyExecutable,
          ['mcp', 'list'],
          runInShell: Platform.isWindows,
        ).timeout(const Duration(seconds: 8));
        mcpRegistered = mcpRes.stdout.toString().contains(mcpServerName);
      } catch (_) {}
    }

    // 3. Parse recent non-sensitive account & default model lines from cli.log
    final logMeta = await _readCliLogMetadata();
    final email = logMeta['email'] ?? '';
    final authMethod = logMeta['authMethod'] ?? '';
    final defaultModel = logMeta['defaultModel'] ??
        (models.isNotEmpty ? models.first.label : 'Default');
    if (email.isNotEmpty) {
      loggedIn = true;
    }

    // 4. Optional live 1-turn ping to verify quota & end-to-end inference
    if (runLivePing && cliInstalled) {
      final sw = Stopwatch()..start();
      try {
        final args = <String>[
          '-p',
          'Reply with only the single word OK.',
          '--output-format',
          'stream-json',
          if (selectedModelOverride.isNotEmpty) ...[
            '--model',
            selectedModelOverride,
          ],
        ];
        final pingRes = await Process.run(
          agyExecutable,
          args,
          runInShell: Platform.isWindows,
        ).timeout(const Duration(seconds: 35));
        sw.stop();
        _lastPingLatencyMs = sw.elapsedMilliseconds;

        final stdoutStr = pingRes.stdout.toString();
        final stderrStr = pingRes.stderr.toString();
        final combinedLower = '$stdoutStr\n$stderrStr'.toLowerCase();

        if (combinedLower.contains('quota') ||
            combinedLower.contains('rate limit') ||
            combinedLower.contains('resource_exhausted') ||
            combinedLower.contains('429')) {
          _lastQuotaStatus = 'exhausted';
          _lastQuotaMessage =
              'Quota / rate-limit reported by Antigravity (${stderrStr.trim().isNotEmpty ? stderrStr.trim() : "HTTP 429"}).';
        } else if (pingRes.exitCode == 0) {
          loggedIn = true;
          _lastQuotaStatus = 'healthy';
          var pingTokens = 0;
          for (final line in const LineSplitter().convert(stdoutStr)) {
            if (!line.trim().startsWith('{')) continue;
            try {
              final obj = jsonDecode(line) as Map<String, dynamic>;
              if (obj['event'] == 'result') {
                final usage =
                    (obj['result'] as Map?)?['usage'] as Map<String, dynamic>?;
                if (usage != null) {
                  final inTok = (usage['input_tokens'] as num?)?.toInt() ?? 0;
                  final outTok = (usage['output_tokens'] as num?)?.toInt() ?? 0;
                  final thTok =
                      (usage['thinking_tokens'] as num?)?.toInt() ?? 0;
                  pingTokens =
                      (usage['total_tokens'] as num?)?.toInt() ?? (inTok + outTok + thTok);
                  recordTurnUsage(
                    inputTokens: inTok,
                    outputTokens: outTok,
                    thinkingTokens: thTok,
                  );
                }
              }
            } catch (_) {}
          }
          final activeLabel = selectedModelOverride.isNotEmpty
              ? selectedModelOverride
              : defaultModel;
          _lastQuotaMessage =
              'Quota Healthy • Live response in ${(_lastPingLatencyMs! / 1000).toStringAsFixed(1)}s using $activeLabel ($pingTokens tokens)';
        } else {
          _lastQuotaStatus = 'error';
          _lastQuotaMessage = stderrStr.trim().isNotEmpty
              ? stderrStr.trim()
              : 'agy exited with code ${pingRes.exitCode}';
        }
      } on TimeoutException {
        sw.stop();
        _lastQuotaStatus = 'error';
        _lastQuotaMessage = 'Live ping timed out after 35s.';
      } catch (e) {
        sw.stop();
        _lastQuotaStatus = 'error';
        _lastQuotaMessage = 'Failed to run agy ping: $e';
      }
    }

    final status = BrainHealthStatus(
      checkedAt: DateTime.now().toUtc().toIso8601String(),
      cliInstalled: cliInstalled,
      loggedIn: loggedIn,
      accountEmail: email,
      authMethod: authMethod,
      defaultModelLabel: defaultModel,
      selectedModelOverride: selectedModelOverride,
      availableModels: models,
      quotaStatus: _lastQuotaStatus,
      quotaMessage: _lastQuotaMessage,
      lastPingLatencyMs: _lastPingLatencyMs,
      mcpRegistered: mcpRegistered,
      cumulativeTurns: cumulativeTurns,
      cumulativeInputTokens: cumulativeInputTokens,
      cumulativeOutputTokens: cumulativeOutputTokens,
      cumulativeThinkingTokens: cumulativeThinkingTokens,
    );
    _cachedStatus = status;
    return status;
  }

  Future<Map<String, String>> _readCliLogMetadata() async {
    final out = <String, String>{};
    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isEmpty) return out;
      final logFile =
          File(p.join(home, '.gemini', 'antigravity-cli', 'cli.log'));
      if (!await logFile.exists()) return out;

      // Read only the last 64 KB of cli.log for instant parsing
      final len = await logFile.length();
      final start = len > 65536 ? len - 65536 : 0;
      final bytes = await logFile
          .openRead(start, len)
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final text = utf8.decode(bytes, allowMalformed: true);

      final authRegex = RegExp(
        r'applyAuthResult:\s*email=([^,\s]+),\s*authMethod=([^,\s]+)',
      );
      for (final m in authRegex.allMatches(text)) {
        out['email'] = m.group(1) ?? '';
        out['authMethod'] = m.group(2) ?? '';
      }

      final modelRegex = RegExp(
        r'Propagating selected model override to backend:\s*label="([^"]+)"',
      );
      for (final m in modelRegex.allMatches(text)) {
        out['defaultModel'] = m.group(1) ?? '';
      }
    } catch (_) {}
    return out;
  }
}
