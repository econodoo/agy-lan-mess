import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import '../../state/mesh_app_controller.dart';

class ProjectSessionDialog extends StatefulWidget {
  final MeshAppController controller;
  final String? existingSessionId;
  final String? initialTitle;
  final String? initialNodeId;
  final String? initialWorkspacePath;

  const ProjectSessionDialog({
    super.key,
    required this.controller,
    this.existingSessionId,
    this.initialTitle,
    this.initialNodeId,
    this.initialWorkspacePath,
  });

  @override
  State<ProjectSessionDialog> createState() => _ProjectSessionDialogState();
}

class _ProjectSessionDialogState extends State<ProjectSessionDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _pathCtrl;
  late String _selectedNodeId;

  bool _isBrowsing = false;
  String? _browseError;
  List<DirEntryInfo>? _remoteDirs;

  @override
  void initState() {
    super.initState();
    final nodes = widget.controller.nodes;
    _selectedNodeId = widget.initialNodeId ??
        (nodes.isNotEmpty ? nodes.first.nodeId : '*');
    final matchedNode =
        nodes.where((n) => n.nodeId == _selectedNodeId).firstOrNull;

    _titleCtrl = TextEditingController(text: widget.initialTitle ?? '');
    _pathCtrl = TextEditingController(
      text: widget.initialWorkspacePath ?? (matchedNode?.cwd ?? ''),
    );
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _browseRemote(String path) async {
    if (_selectedNodeId == '*') return;
    setState(() {
      _isBrowsing = true;
      _browseError = null;
    });
    final res = await widget.controller.browseRemoteDirectory(
      _selectedNodeId,
      path.trim().isEmpty ? '.' : path.trim(),
    );
    if (!mounted) return;
    setState(() {
      _isBrowsing = false;
      if (res.ok) {
        _remoteDirs =
            (res.entries ?? []).where((e) => e.isDirectory).toList();
      } else {
        _browseError = res.error ?? 'Could not list directory';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingSessionId != null;
    final nodes = widget.controller.nodes;

    return AlertDialog(
      title: Text(
        isEdit ? 'Edit Project Session' : 'New Multi-Machine Project Session',
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Session / Project Name',
                  hintText: 'e.g. Gaming-PC Backend API, NAS Docker Stack',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Target LAN Computer',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Fleet-Wide (*)'),
                    selected: _selectedNodeId == '*',
                    onSelected: (_) => setState(() {
                      _selectedNodeId = '*';
                      _remoteDirs = null;
                    }),
                  ),
                  ...nodes.map((n) {
                    return ChoiceChip(
                      avatar: Icon(
                        n.online ? Icons.computer : Icons.portable_wifi_off,
                        size: 16,
                      ),
                      label: Text('${n.hostname} (${n.os})'),
                      selected: _selectedNodeId == n.nodeId,
                      onSelected: (_) => setState(() {
                        _selectedNodeId = n.nodeId;
                        if (_pathCtrl.text.trim().isEmpty) {
                          _pathCtrl.text = n.cwd;
                        }
                        _remoteDirs = null;
                      }),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pathCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Remote Project Folder Path',
                        hintText: r'C:\Projects\my_app or /home/user/project',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: (_selectedNodeId == '*' || _isBrowsing)
                        ? null
                        : () => _browseRemote(_pathCtrl.text),
                    icon: _isBrowsing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open, size: 18),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              if (_browseError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _browseError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_remoteDirs != null) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Remote Subdirectories (click to navigate):',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        final cur = _pathCtrl.text.trim();
                        final sep = cur.contains('\\') ? '\\' : '/';
                        final idx = cur.lastIndexOf(sep);
                        if (idx > 0) {
                          final parent = cur.substring(0, idx);
                          _pathCtrl.text = parent;
                          _browseRemote(parent);
                        }
                      },
                      icon: const Icon(Icons.arrow_upward, size: 14),
                      label: const Text('Up'),
                    ),
                  ],
                ),
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _remoteDirs!.isEmpty
                      ? const Center(child: Text('No subdirectories found'))
                      : ListView.builder(
                          itemCount: _remoteDirs!.length,
                          itemBuilder: (ctx, i) {
                            final dir = _remoteDirs![i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder, size: 18),
                              title: Text(dir.name),
                              subtitle: Text(
                                dir.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                _pathCtrl.text = dir.path;
                                _browseRemote(dir.path);
                              },
                            );
                          },
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () {
            final title = _titleCtrl.text.trim().isEmpty
                ? 'Project Session'
                : _titleCtrl.text.trim();
            if (isEdit) {
              widget.controller.updateProjectSession(
                sessionId: widget.existingSessionId!,
                title: title,
                targetNodeId: _selectedNodeId,
                workspacePath: _pathCtrl.text.trim(),
              );
            } else {
              widget.controller.createProjectSession(
                title: title,
                targetNodeId: _selectedNodeId,
                workspacePath: _pathCtrl.text.trim(),
              );
            }
            Navigator.of(context).pop();
          },
          icon: Icon(isEdit ? Icons.save : Icons.add),
          label: Text(isEdit ? 'Save Session' : 'Create Session'),
        ),
      ],
    );
  }
}
