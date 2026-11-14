import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import '../state/mesh_app_controller.dart';
import 'widgets/brain_and_rollout_panel.dart';
import 'widgets/markdown_message_view.dart';
import 'widgets/new_session_dialog.dart';

class MeshHomePage extends StatefulWidget {
  final MeshAppController controller;

  const MeshHomePage({super.key, required this.controller});

  @override
  State<MeshHomePage> createState() => _MeshHomePageState();
}

class _MeshHomePageState extends State<MeshHomePage> {
  int _activeTab = 0; // 0 = Sessions, 1 = Computers, 2 = Brain & Setup, 3 = Local Audit
  final _promptCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  MeshAppController get c => widget.controller;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _sendPrompt() {
    final text = _promptCtrl.text.trim();
    if (text.isEmpty || !c.isConnected) return;
    _promptCtrl.clear();
    c.sendChatPrompt(text);
  }

  void _openNewSessionDialog({
    String? preselectedNodeId,
    String? preselectedPath,
    String? preselectedTitle,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => ProjectSessionDialog(
        controller: c,
        initialNodeId: preselectedNodeId,
        initialWorkspacePath: preselectedPath,
        initialTitle: preselectedTitle,
      ),
    );
  }

  void _openClientRolloutDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join This Computer to AGY LAN Mesh'),
        content: SizedBox(
          width: 660,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: c,
              builder: (_, _) => ClientRolloutCard(controller: c),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _openConnectionSheet() {
    final urlCtrl = TextEditingController(text: c.wsUrl);
    final pinCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect / Pair with AGY LAN Hub'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Hub WebSocket URL',
                  hintText: 'ws://192.168.1.50:8765/ws',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '6-Digit Pairing PIN (required first time)',
                  hintText: 'e.g. 482910',
                  border: OutlineInputBorder(),
                ),
              ),
              if (!c.driver.isWebConsole) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final found = await c.autoDiscoverHub();
                      if (!ctx.mounted) return;
                      if (found != null) {
                        urlCtrl.text = c.wsUrl;
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Discovered $found')),
                        );
                      } else {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('No LAN Hub responded on UDP 8766.'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.radar),
                    label: const Text('Auto-Discover Hub on LAN'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              c.connect(newWsUrl: urlCtrl.text, pin: pinCtrl.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  void _openUnlockSudoDialog() {
    final pwCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock Local Sudo Vault'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your sudo password stays strictly in this client\'s local RAM and is NEVER transmitted to the Hub Server or the LLM.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pwCtrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Local Linux sudo password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) async {
                  final ok = await c.unlockLocalSudo(pwCtrl.text);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? 'Local sudo vault unlocked.'
                            : 'Sudo verification failed.',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await c.unlockLocalSudo(pwCtrl.text);
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? 'Local sudo vault unlocked.'
                        : 'Sudo verification failed.',
                  ),
                ),
              );
            },
            child: const Text('Verify & Unlock'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final isWide = MediaQuery.of(context).size.width >= 880;
        final runningCount = c.sessionSummaries
            .where((s) => s['status'] == SessionStatuses.running)
            .length;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(
              children: [
                const Icon(Icons.hub_outlined, size: 22),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text(
                    'AGY LAN Mesh',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                _ConnectionBadge(controller: c, onTap: _openConnectionSheet),
                if (c.serverLoopbackPin != null) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.key, size: 15),
                    label: Text('PIN: ${c.serverLoopbackPin}'),
                    tooltip: 'Click to copy Pairing PIN for new computers',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: c.serverLoopbackPin!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied 6-digit Pairing PIN'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
                if (c.brainHealth != null && isWide) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: Icon(
                      c.brainHealth!.loggedIn
                          ? Icons.psychology
                          : Icons.warning_amber_rounded,
                      size: 16,
                      color: c.brainHealth!.loggedIn
                          ? Colors.greenAccent.shade400
                          : Colors.redAccent,
                    ),
                    label: Text(
                      c.brainHealth!.loggedIn
                          ? 'Model: ${c.brainHealth!.effectiveModelDisplay}'
                          : 'AGY Not Logged In',
                    ),
                    tooltip: 'Check AGY login, quota & active model',
                    onPressed: () => setState(() => _activeTab = 2),
                  ),
                ],
                if (runningCount > 0) ...[
                  const SizedBox(width: 8),
                  Chip(
                    avatar: const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    label: Text('$runningCount Active'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            actions: [
              if (c.isConnected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: isWide
                      ? FilledButton.tonalIcon(
                          onPressed: _openClientRolloutDialog,
                          icon: const Icon(Icons.terminal, size: 17),
                          label: const Text('Copy Client Command'),
                        )
                      : IconButton(
                          tooltip: 'Copy Client Install Command',
                          onPressed: _openClientRolloutDialog,
                          icon: const Icon(Icons.terminal),
                        ),
                ),
              IconButton(
                tooltip: 'New Project Session',
                onPressed: c.isConnected ? () => _openNewSessionDialog() : null,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: 'Hub Connection Settings',
                onPressed: _openConnectionSheet,
                icon: const Icon(Icons.settings_ethernet),
              ),
              const SizedBox(width: 6),
            ],
          ),
          drawer: (!isWide && _activeTab == 0)
              ? Drawer(
                  width: 320,
                  child: SafeArea(child: _buildSessionsSidebar(closeOnTap: true)),
                )
              : null,
          body: Column(
            children: [
              if (c.needsPin || c.connectionError != null)
                _buildConnectionAlertBanner(),
              if (c.pendingApprovals.isNotEmpty)
                _buildPendingApprovalBanner(c.pendingApprovals.first),
              Expanded(
                child: Row(
                  children: [
                    if (isWide)
                      NavigationRail(
                        selectedIndex: _activeTab,
                        onDestinationSelected: (idx) =>
                            setState(() => _activeTab = idx),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          const NavigationRailDestination(
                            icon: Icon(Icons.workspaces_outlined),
                            selectedIcon: Icon(Icons.workspaces),
                            label: Text('Sessions'),
                          ),
                          NavigationRailDestination(
                            icon: Badge(
                              isLabelVisible: c.nodes.isNotEmpty,
                              label: Text('${c.nodes.where((n) => n.online).length}'),
                              child: const Icon(Icons.devices_outlined),
                            ),
                            selectedIcon: const Icon(Icons.devices),
                            label: const Text('Computers'),
                          ),
                          NavigationRailDestination(
                            icon: Badge(
                              isLabelVisible:
                                  c.brainHealth != null && !c.brainHealth!.loggedIn,
                              label: const Text('!'),
                              child: const Icon(Icons.psychology_outlined),
                            ),
                            selectedIcon: const Icon(Icons.psychology),
                            label: const Text('Brain & Setup'),
                          ),
                          NavigationRailDestination(
                            icon: Badge(
                              isLabelVisible: c.pendingApprovals.isNotEmpty,
                              label: Text('${c.pendingApprovals.length}'),
                              child: const Icon(Icons.shield_outlined),
                            ),
                            selectedIcon: const Icon(Icons.shield),
                            label: const Text('Audit'),
                          ),
                        ],
                      ),
                    if (isWide) const VerticalDivider(width: 1),
                    if (isWide && _activeTab == 0) ...[
                      SizedBox(
                        width: 310,
                        child: _buildSessionsSidebar(closeOnTap: false),
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      child: IndexedStack(
                        index: _activeTab,
                        children: [
                          _buildChatWorkspacePane(isWide: isWide),
                          _buildComputersAndPrivilegePane(),
                          _buildBrainAndSetupPane(),
                          _buildAuditPane(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: isWide
              ? null
              : NavigationBar(
                  selectedIndex: _activeTab,
                  onDestinationSelected: (idx) =>
                      setState(() => _activeTab = idx),
                  destinations: [
                    const NavigationDestination(
                      icon: Icon(Icons.workspaces_outlined),
                      label: 'Sessions',
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: c.nodes.isNotEmpty,
                        label: Text('${c.nodes.where((n) => n.online).length}'),
                        child: const Icon(Icons.devices_outlined),
                      ),
                      label: 'Computers',
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible:
                            c.brainHealth != null && !c.brainHealth!.loggedIn,
                        label: const Text('!'),
                        child: const Icon(Icons.psychology_outlined),
                      ),
                      label: 'Brain & Setup',
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: c.pendingApprovals.isNotEmpty,
                        label: Text('${c.pendingApprovals.length}'),
                        child: const Icon(Icons.shield_outlined),
                      ),
                      label: 'Audit',
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildConnectionAlertBanner() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.link_off, color: cs.onErrorContainer, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                c.connectionError ?? 'Enter the 6-digit Pairing PIN to connect.',
                style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
              ),
            ),
            FilledButton.tonal(
              onPressed: _openConnectionSheet,
              child: Text(c.needsPin ? 'Enter PIN' : 'Configure Hub'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingApprovalBanner(PendingApprovalItem item) {
    final req = item.request;
    return Material(
      color: Colors.amber.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '⚡ Elevated Command Approval Requested (${req.requestingSessionTitle ?? "AGY Brain"})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                '${req.cwd != null ? "[${req.cwd}] " : ""}${req.command}',
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () =>
                      c.resolvePendingApproval(item, approve: true),
                  icon: const Icon(Icons.check),
                  label: const Text('Approve Once'),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () => c.resolvePendingApproval(
                    item,
                    approve: true,
                    switchToFullAuto: true,
                  ),
                  child: const Text('Approve & Switch to Full Auto'),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () =>
                      c.resolvePendingApproval(item, approve: false),
                  icon: const Icon(Icons.close),
                  label: const Text('Deny'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Multi-Project Sessions Sidebar ----------------

  Widget _buildSessionsSidebar({required bool closeOnTap}) {
    final sessions = c.filteredSessions;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: FilledButton.icon(
            onPressed: c.isConnected ? () => _openNewSessionDialog() : null,
            icon: const Icon(Icons.add),
            label: const Text('New Project Session'),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              FilterChip(
                label: Text('All (${c.sessionSummaries.length})'),
                selected: c.machineFilterNodeId == 'ALL',
                onSelected: (_) => c.setMachineFilter('ALL'),
              ),
              const SizedBox(width: 6),
              ...c.nodes.map((n) {
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(n.hostname),
                    selected: c.machineFilterNodeId == n.nodeId,
                    onSelected: (_) => c.setMachineFilter(n.nodeId),
                  ),
                );
              }),
            ],
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'No project sessions yet.\nOpen multiple projects across any LAN machines simultaneously!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (ctx, i) {
                    final s = sessions[i];
                    final id = s['sessionId'] as String;
                    final status = s['status'] as String? ?? 'idle';
                    final selected = id == c.selectedSessionId;
                    final nodeName =
                        (s['targetNodeName'] as String?)?.isNotEmpty == true
                            ? s['targetNodeName'] as String
                            : (s['targetNodeId'] as String? ?? '*');
                    final wsPath = s['workspacePath'] as String? ?? '';

                    return ListTile(
                      selected: selected,
                      selectedTileColor:
                          cs.primaryContainer.withValues(alpha: 0.35),
                      leading: _SessionStatusIcon(status: status),
                      title: Text(
                        s['title'] as String? ?? 'Session',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Text(
                        wsPath.isNotEmpty ? '$nodeName • $wsPath' : nodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      trailing: PopupMenuButton<String>(
                        iconSize: 18,
                        onSelected: (action) {
                          if (action == 'edit') {
                            showDialog<void>(
                              context: context,
                              builder: (_) => ProjectSessionDialog(
                                controller: c,
                                existingSessionId: id,
                                initialTitle: s['title'] as String?,
                                initialNodeId: s['targetNodeId'] as String?,
                                initialWorkspacePath: wsPath,
                              ),
                            );
                          } else if (action == 'stop') {
                            c.cancelActiveTurn(id);
                          } else if (action == 'delete') {
                            c.deleteProjectSession(id);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit Machine / Folder'),
                          ),
                          if (status == SessionStatuses.running ||
                              status == SessionStatuses.awaitingApproval)
                            const PopupMenuItem(
                              value: 'stop',
                              child: Text('Stop Running Turn'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete Session'),
                          ),
                        ],
                      ),
                      onTap: () {
                        c.selectSession(id);
                        if (closeOnTap) Navigator.of(context).pop();
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------- Active Session Chat Workspace ----------------

  Widget _buildChatWorkspacePane({required bool isWide}) {
    final session = c.activeSession;
    final cs = Theme.of(context).colorScheme;
    final isRunning = session?.status == SessionStatuses.running ||
        session?.status == SessionStatuses.awaitingApproval;

    return Column(
      children: [
        // Active Session Header Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(
            children: [
              if (!isWide)
                Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu),
                    tooltip: 'Switch Project Session',
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                ),
              Expanded(
                child: session == null
                    ? const Text(
                        'Quick Prompt (will create a new session automatically)',
                        style: TextStyle(fontSize: 13),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                            ),
                          ),
                          Text(
                            'Target: ${session.targetNodeName.isNotEmpty ? session.targetNodeName : session.targetNodeId}'
                            '${session.workspacePath.isNotEmpty ? "  •  Folder: ${session.workspacePath}" : ""}',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              ),
              if (session != null) ...[
                IconButton(
                  tooltip: 'Change Target Machine / Project Folder',
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => ProjectSessionDialog(
                        controller: c,
                        existingSessionId: session.sessionId,
                        initialTitle: session.title,
                        initialNodeId: session.targetNodeId,
                        initialWorkspacePath: session.workspacePath,
                      ),
                    );
                  },
                ),
                if (isRunning)
                  FilledButton.tonalIcon(
                    onPressed: () => c.cancelActiveTurn(session.sessionId),
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text('Stop'),
                  ),
              ],
            ],
          ),
        ),

        // Message Stream
        Expanded(
          child: (session == null || session.messages.isEmpty)
              ? Center(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 44,
                              color: cs.primary.withValues(alpha: 0.8),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              session == null
                                  ? 'Work Across Any Computer Using Your Central Brain'
                                  : 'Ready in "${session.title}"',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Open multiple project sessions side-by-side targeting different Windows & Linux machines. The Server\'s Antigravity Brain processes every prompt and runs tools on the target machine.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              alignment: WrapAlignment.center,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: c.isConnected
                                      ? () => _openNewSessionDialog()
                                      : _openConnectionSheet,
                                  icon: const Icon(
                                      Icons.create_new_folder_outlined),
                                  label: Text(
                                    c.isConnected
                                        ? 'Pin a Project Folder on a LAN Computer'
                                        : 'Connect to LAN Hub First',
                                  ),
                                ),
                                if (c.isConnected)
                                  FilledButton.tonalIcon(
                                    onPressed: _openClientRolloutDialog,
                                    icon: const Icon(Icons.terminal, size: 18),
                                    label: const Text(
                                      'Copy 1-Line Command for This Client',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(16),
                  itemCount: session.messages.length,
                  itemBuilder: (ctx, i) =>
                      MessageBubbleCard(message: session.messages[i]),
                ),
        ),

        // Composer
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(
              top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _sendPrompt,
                  },
                  child: TextField(
                    controller: _promptCtrl,
                    minLines: 1,
                    maxLines: 5,
                    enabled: c.isConnected,
                    decoration: InputDecoration(
                      hintText: c.isConnected
                          ? 'Ask Antigravity Brain to inspect, code, or administer target machine... (Enter to send, Shift+Enter newline)'
                          : 'Connect to AGY Hub to send prompts...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: (c.isConnected && !isRunning) ? _sendPrompt : null,
                icon: const Icon(Icons.send),
                label: const Text('Send'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- Computers & Local Privilege Pane ----------------

  Widget _buildComputersAndPrivilegePane() {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (!c.driver.isWebConsole) ...[
          Card(
            elevation: 0,
            color: cs.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.laptop_chromebook),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This Device: ${c.hostname} (${c.driver.osName})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _PrivilegeBadge(level: c.privilegeLevel),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: ApprovalModes.askForElevated,
                            icon: Icon(Icons.verified_user_outlined, size: 16),
                            label: Text('Ask Approval for Admin/Sudo'),
                          ),
                          ButtonSegment(
                            value: ApprovalModes.fullAuto,
                            icon: Icon(Icons.bolt, size: 16),
                            label: Text('Full Auto'),
                          ),
                        ],
                        selected: {c.approvalMode},
                        onSelectionChanged: (s) => c.setApprovalMode(s.first),
                      ),
                      if (c.driver.isLinux &&
                          c.privilegeLevel != PrivilegeLevels.root)
                        c.driver.isSudoUnlocked
                            ? OutlinedButton.icon(
                                onPressed: c.lockLocalSudo,
                                icon: const Icon(Icons.lock_outline),
                                label: const Text('Lock Sudo Vault'),
                              )
                            : FilledButton.tonalIcon(
                                onPressed: _openUnlockSudoDialog,
                                icon: const Icon(Icons.lock_open),
                                label: const Text('Unlock Sudo (Local RAM)'),
                              ),
                      if (c.driver.isWindows &&
                          c.privilegeLevel != PrivilegeLevels.admin)
                        FilledButton.tonalIcon(
                          onPressed: c.relaunchWindowsAdmin,
                          icon: const Icon(Icons.admin_panel_settings),
                          label: const Text('Relaunch as Administrator'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (c.isConnected) ...[
          ClientRolloutCard(controller: c),
          const SizedBox(height: 18),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Paired LAN Computers (${c.nodes.length})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            TextButton.icon(
              onPressed: () => _openNewSessionDialog(),
              icon: const Icon(Icons.add),
              label: const Text('New Session'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (c.nodes.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No target computers connected yet. Run the Flutter Client or the 1-line agent.ps1 / agent.sh bootstrap script on any LAN PC!',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          )
        else
          ...c.nodes.map((n) {
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: n.online
                      ? Colors.green.withValues(alpha: 0.2)
                      : cs.surfaceContainerHighest,
                  child: Icon(
                    n.os == 'windows'
                        ? Icons.desktop_windows
                        : (n.os == 'android'
                            ? Icons.phone_android
                            : Icons.terminal),
                    color: n.online ? Colors.green.shade400 : cs.outline,
                  ),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        n.hostname,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _PrivilegeBadge(level: n.privilegeLevel),
                  ],
                ),
                subtitle: Text(
                  '${n.online ? "● Online" : "○ Offline"}  •  ${n.os} (${n.ipAddress})  •  Mode: ${n.approvalMode}\nDefault CWD: ${n.cwd}',
                ),
                isThreeLine: true,
                trailing: FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() => _activeTab = 0);
                    _openNewSessionDialog(
                      preselectedNodeId: n.nodeId,
                      preselectedPath: n.cwd,
                      preselectedTitle: '${n.hostname} Project',
                    );
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open Session'),
                ),
              ),
            );
          }),
      ],
    );
  }

  // ---------------- Brain Health & Client Rollout Pane ----------------

  Widget _buildBrainAndSetupPane() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        BrainDiagnosticsCard(controller: c),
        const SizedBox(height: 18),
        ClientRolloutCard(controller: c),
      ],
    );
  }

  // ---------------- Local Audit Log Pane ----------------

  Widget _buildAuditPane() {
    if (c.auditLog.isEmpty) {
      return const Center(
        child: Text('No commands or file edits executed on this device yet.'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: c.auditLog.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final entry = c.auditLog[i];
        return ListTile(
          leading: Icon(
            entry.isError
                ? Icons.warning_amber_rounded
                : (entry.category == 'exec'
                    ? Icons.terminal
                    : Icons.description_outlined),
            color: entry.isError ? Colors.redAccent : Colors.tealAccent,
          ),
          title: Text(
            entry.summary,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          subtitle: entry.detail.isNotEmpty
              ? Text(
                  entry.detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                )
              : null,
          trailing: Text(
            '${entry.timestamp.hour.toString().padLeft(2, "0")}:${entry.timestamp.minute.toString().padLeft(2, "0")}:${entry.timestamp.second.toString().padLeft(2, "0")}',
            style: const TextStyle(fontSize: 11),
          ),
        );
      },
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  final MeshAppController controller;
  final VoidCallback onTap;

  const _ConnectionBadge({required this.controller, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = controller.isConnected
        ? Colors.greenAccent.shade400
        : (controller.isConnecting ? Colors.amber : Colors.redAccent);
    final label = controller.isConnected
        ? 'Brain: ${controller.serverHostname}'
        : (controller.isConnecting ? 'Connecting...' : 'Disconnected');

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivilegeBadge extends StatelessWidget {
  final String level;

  const _PrivilegeBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    final isElevated = PrivilegeLevels.isElevatedCapable(level);
    final bg = isElevated
        ? Colors.amber.withValues(alpha: 0.2)
        : Colors.blueGrey.withValues(alpha: 0.2);
    final fg = isElevated ? Colors.amber.shade300 : Colors.blueGrey.shade200;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        level.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}

class _SessionStatusIcon extends StatelessWidget {
  final String status;

  const _SessionStatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == SessionStatuses.running) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      );
    }
    if (status == SessionStatuses.awaitingApproval) {
      return const Icon(Icons.gpp_maybe, color: Colors.amber, size: 20);
    }
    if (status == SessionStatuses.error) {
      return const Icon(Icons.error_outline, color: Colors.redAccent, size: 20);
    }
    return const Icon(Icons.folder_special_outlined, size: 20);
  }
}
