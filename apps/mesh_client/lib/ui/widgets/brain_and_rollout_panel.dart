import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import '../../state/mesh_app_controller.dart';

class ClientRolloutCard extends StatefulWidget {
  final MeshAppController controller;

  const ClientRolloutCard({super.key, required this.controller});

  @override
  State<ClientRolloutCard> createState() => _ClientRolloutCardState();
}

class _ClientRolloutCardState extends State<ClientRolloutCard> {
  bool _elevate = true;
  bool _fullAuto = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final baseUrl = c.bestRolloutHttpBaseUrl;
    final pin = c.serverLoopbackPin ?? '';
    final mode = _fullAuto ? 'auto' : 'ask';

    final winParams = [
      if (pin.isNotEmpty) 'pin=$pin',
      'mode=$mode',
      if (_elevate) 'elevate=1',
    ].join('&');
    final winCmd = 'irm "$baseUrl/agent.ps1?$winParams" | iex';

    final linParams = [
      if (pin.isNotEmpty) 'pin=$pin',
      'mode=$mode',
      if (_elevate) 'sudo=1',
    ].join('&');
    final linCmd = 'curl -fsSL "$baseUrl/agent.sh?$linParams" | bash';

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '1-Click Client Rollout Commands (Pre-Stamped with Server & PIN)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Open this URL on any client PC, log in with the PIN, and copy the single-line command below to join the mesh immediately—no typing required.',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('Elevate Privileges (Windows Admin UAC / Linux Sudo)'),
                  selected: _elevate,
                  onSelected: (v) => setState(() => _elevate = v),
                ),
                FilterChip(
                  label: const Text('Full Auto Mode (No Local Approval Prompts)'),
                  selected: _fullAuto,
                  onSelected: (v) => setState(() => _fullAuto = v),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _CommandCopyRow(
              label: 'Windows PowerShell (1-Line Copy & Paste)',
              icon: Icons.desktop_windows,
              command: winCmd,
              buttonText: 'Copy Windows Command',
            ),
            const SizedBox(height: 12),
            _CommandCopyRow(
              label: 'Linux / macOS Terminal (1-Line Copy & Paste)',
              icon: Icons.terminal,
              command: linCmd,
              buttonText: 'Copy Linux/macOS Command',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    final apkUrl = '$baseUrl/downloads/agy-mesh-client.apk';
                    Clipboard.setData(ClipboardData(text: apkUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Copied Android APK URL: $apkUrl')),
                    );
                  },
                  icon: const Icon(Icons.android, size: 18),
                  label: const Text('Copy Local Android APK URL'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    const relUrl =
                        'https://github.com/econodoo/agy-lan-mess/releases';
                    Clipboard.setData(const ClipboardData(text: relUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied GitHub Multi-OS Releases URL'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('Copy GitHub Releases URL (Win/Mac/Linux/APK)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandCopyRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final String command;
  final String buttonText;

  const _CommandCopyRow({
    required this.label,
    required this.icon,
    required this.command,
    required this.buttonText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1220),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  command,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: command));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied: $label'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(buttonText),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class BrainDiagnosticsCard extends StatelessWidget {
  final MeshAppController controller;

  const BrainDiagnosticsCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final bh = c.brainHealth;
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Server Antigravity (agy) Connectivity, Model & Quota',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh Brain Status',
                  onPressed: c.isConnected ? c.refreshBrainStatus : null,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                FilledButton.tonalIcon(
                  onPressed: (c.isConnected && !c.isPingingBrain)
                      ? c.runLiveBrainQuotaPing
                      : null,
                  icon: c.isPingingBrain
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt, size: 18),
                  label: Text(
                    c.isPingingBrain
                        ? 'Testing Brain...'
                        : 'Verify Brain & Quota',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (bh == null)
              Text(
                c.isConnected
                    ? 'Loading Antigravity CLI status from server...'
                    : 'Connect to the Hub Server to view Brain login, model & quota status.',
                style: TextStyle(color: cs.onSurfaceVariant),
              )
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  _StatusTile(
                    title: 'Login & Cloud Auth',
                    value: bh.loggedIn
                        ? 'Logged In${bh.accountEmail.isNotEmpty ? " (${bh.accountEmail})" : ""}'
                        : (bh.cliInstalled ? 'Not Logged In' : 'agy CLI Not Found'),
                    ok: bh.loggedIn,
                  ),
                  _StatusTile(
                    title: 'Quota & Live Health',
                    value: bh.quotaMessage,
                    ok: bh.quotaStatus == 'healthy' ||
                        bh.quotaStatus == 'unchecked',
                    isWarning: bh.quotaStatus == 'unchecked',
                  ),
                  _StatusTile(
                    title: 'MCP Bridge (lan-mesh)',
                    value: bh.mcpRegistered
                        ? 'Registered & Enabled'
                        : 'Not Registered',
                    ok: bh.mcpRegistered,
                  ),
                  _StatusTile(
                    title: 'Cumulative Brain Usage',
                    value:
                        '${bh.cumulativeTurns} turns • ${bh.cumulativeTotalTokens} total tokens (in: ${bh.cumulativeInputTokens}, out: ${bh.cumulativeOutputTokens}, think: ${bh.cumulativeThinkingTokens})',
                    ok: true,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.tune, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Active Brain Model:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownMenu<String>(
                      initialSelection: bh.selectedModelOverride,
                      expandedInsets: EdgeInsets.zero,
                      onSelected: (val) {
                        if (val != null) {
                          c.setBrainModelOverride(val);
                        }
                      },
                      dropdownMenuEntries: [
                        DropdownMenuEntry<String>(
                          value: '',
                          label:
                              'Server Default (${bh.defaultModelLabel.isNotEmpty ? bh.defaultModelLabel : "Auto"})',
                        ),
                        ...bh.availableModels.map(
                          (BrainModelOption m) => DropdownMenuEntry<String>(
                            value: m.id,
                            label: '${m.label}  [${m.id}]',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final String title;
  final String value;
  final bool ok;
  final bool isWarning;

  const _StatusTile({
    required this.title,
    required this.value,
    required this.ok,
    this.isWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = isWarning
        ? Colors.amber
        : (ok ? Colors.greenAccent.shade400 : Colors.redAccent);

    return Container(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 460),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class ActiveRemoteTasksCard extends StatelessWidget {
  final MeshAppController controller;

  const ActiveRemoteTasksCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final tasks = c.remoteTasks;
    if (tasks.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final activeCount = tasks.where((t) => t.isActive).length;

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  activeCount > 0 ? Icons.monitor_heart : Icons.history,
                  color: activeCount > 0
                      ? Colors.greenAccent.shade400
                      : cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    activeCount > 0
                        ? 'Live Remote Processes & Heartbeats ($activeCount Running)'
                        : 'Recent Remote Processes (${tasks.length})',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...tasks.take(8).map((t) {
              final sec = (t.elapsedMs / 1000.0).toStringAsFixed(1);
              final hbTime = DateTime.tryParse(t.lastHeartbeatAt);
              final hbAge = hbTime != null
                  ? DateTime.now().toUtc().difference(hbTime).inSeconds
                  : 0;
              final tail =
                  (t.stdoutTail.isNotEmpty ? t.stdoutTail : t.stderrTail).trim();

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: t.isActive
                        ? Colors.greenAccent.withValues(alpha: 0.5)
                        : cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (t.isActive)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              t.exitCode == 0
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline,
                              size: 16,
                              color: t.exitCode == 0
                                  ? Colors.greenAccent.shade400
                                  : Colors.redAccent,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            '[${t.nodeHostname}] ${t.command}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        if (t.isActive)
                          TextButton.icon(
                            onPressed: () => c.killRemoteTask(t.taskId),
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            label: const Text(
                              'Kill',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.isActive
                          ? 'Status: ${t.status.toUpperCase()}  •  PID: ${t.pid ?? "..."}  •  Elapsed: ${sec}s  •  Heartbeat: ${t.heartbeatHealthy ? "HEALTHY (${hbAge}s ago)" : "STALE"}'
                          : 'Status: ${t.status.toUpperCase()}  •  Exit: ${t.exitCode ?? "-"}  •  Duration: ${sec}s',
                      style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                    ),
                    if (tail.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1220),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          tail.length > 350
                              ? '...${tail.substring(tail.length - 350)}'
                              : tail,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
