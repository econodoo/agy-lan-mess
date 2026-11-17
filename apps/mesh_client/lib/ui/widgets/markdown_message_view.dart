import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

class MessageBubbleCard extends StatefulWidget {
  final SessionMessage message;
  final String? sessionTitle;

  const MessageBubbleCard({
    super.key,
    required this.message,
    this.sessionTitle,
  });

  @override
  State<MessageBubbleCard> createState() => _MessageBubbleCardState();
}

class _MessageBubbleCardState extends State<MessageBubbleCard> {
  bool _showThinking = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    if (msg.role == 'summary' && msg.completionSummary != null) {
      return _SessionSummaryBragCard(
        message: msg,
        summary: msg.completionSummary!,
        sessionTitle: widget.sessionTitle,
      );
    }

    final isUser = msg.role == 'user';
    final cs = Theme.of(context).colorScheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isUser
                ? cs.primaryContainer.withValues(alpha: 0.75)
                : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isUser
                  ? cs.primary.withValues(alpha: 0.35)
                  : cs.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 16,
                        color: isUser ? cs.onPrimaryContainer : cs.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isUser ? 'You' : 'Antigravity Brain',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isUser ? cs.onPrimaryContainer : cs.primary,
                        ),
                      ),
                    ],
                  ),
                  if (msg.status == 'streaming')
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (!isUser &&
                      msg.status == 'done' &&
                      (msg.durationMs != null || msg.totalTokens > 0))
                    Text(
                      [
                        if (msg.durationMs != null)
                          '⏱ ${SessionCompletionSummary.formatDuration(msg.durationMs!)}',
                        if (msg.totalTokens > 0)
                          '🪙 ${SessionCompletionSummary.formatTokens(msg.totalTokens)} tok',
                      ].join('  •  '),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (msg.thinking.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _showThinking = !_showThinking),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showThinking
                                  ? Icons.expand_less
                                  : Icons.psychology_outlined,
                              size: 15,
                              color: cs.secondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _showThinking
                                  ? 'Hide Brain Reasoning'
                                  : 'Show Brain Reasoning',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.secondary,
                              ),
                            ),
                          ],
                        ),
                        if (_showThinking) ...[
                          const SizedBox(height: 6),
                          SelectableText(
                            msg.thinking.trim(),
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (msg.toolEvents.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: msg.toolEvents
                      .map((te) => _ToolEventPill(toolEvent: te))
                      .toList(),
                ),
              ],
              if (msg.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                _FormattedCodeAndText(text: msg.text),
              ] else if (msg.status == 'streaming' && msg.toolEvents.isEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Thinking...',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolEventPill extends StatelessWidget {
  final ToolCallSummary toolEvent;

  const _ToolEventPill({required this.toolEvent});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRunning = toolEvent.status == 'running';
    final isErr = toolEvent.status == 'error';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isErr
            ? cs.errorContainer.withValues(alpha: 0.65)
            : cs.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isRunning)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  isErr ? Icons.error_outline : Icons.terminal,
                  size: 14,
                  color: isErr ? cs.onErrorContainer : cs.onSecondaryContainer,
                ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  toolEvent.summary,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color:
                        isErr ? cs.onErrorContainer : cs.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          if (toolEvent.outputPreview != null &&
              toolEvent.outputPreview!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              toolEvent.outputPreview!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FormattedCodeAndText extends StatelessWidget {
  final String text;

  const _FormattedCodeAndText({required this.text});

  @override
  Widget build(BuildContext context) {
    final blocks = _splitFencedBlocks(text);
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks.map((b) {
        if (!b.isCode) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: SelectableText(
              b.content,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: cs.onSurface,
              ),
            ),
          );
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1220),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(10)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      b.language.isEmpty ? 'code' : b.language,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Colors.white70,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 14, color: Colors.white70),
                      tooltip: 'Copy code',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: b.content));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Copied code to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  b.content,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: Color(0xFFE2E8F0),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  static List<_Segment> _splitFencedBlocks(String raw) {
    final regex = RegExp(r'```([^\n]*)\n([\s\S]*?)```');
    final matches = regex.allMatches(raw);
    if (matches.isEmpty) return [_Segment(isCode: false, content: raw)];

    final out = <_Segment>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        final prose = raw.substring(cursor, m.start).trim();
        if (prose.isNotEmpty) {
          out.add(_Segment(isCode: false, content: prose));
        }
      }
      out.add(_Segment(
        isCode: true,
        language: (m.group(1) ?? '').trim(),
        content: (m.group(2) ?? '').trimRight(),
      ));
      cursor = m.end;
    }
    if (cursor < raw.length) {
      final tail = raw.substring(cursor).trim();
      if (tail.isNotEmpty) {
        out.add(_Segment(isCode: false, content: tail));
      }
    }
    return out;
  }
}

class _Segment {
  final bool isCode;
  final String language;
  final String content;

  _Segment({required this.isCode, this.language = '', required this.content});
}

class _SessionSummaryBragCard extends StatelessWidget {
  final SessionMessage message;
  final SessionCompletionSummary summary;
  final String? sessionTitle;

  const _SessionSummaryBragCard({
    required this.message,
    required this.summary,
    this.sessionTitle,
  });

  @override
  Widget build(BuildContext context) {
    final tokenSubParts = <String>[
      '${SessionCompletionSummary.formatTokens(summary.inputTokens)} in',
      '${SessionCompletionSummary.formatTokens(summary.outputTokens)} out',
      if (summary.thinkingTokens > 0)
        '${SessionCompletionSummary.formatTokens(summary.thinkingTokens)} think',
    ];

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0A1628), Color(0xFF112240), Color(0xFF0D1B2A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.55),
              width: 1.3,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.14),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Brag Header
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF34D399)
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF34D399)
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.workspace_premium,
                                  size: 15,
                                  color: Color(0xFF34D399),
                                ),
                                SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'SESSION COMPLETED  •  AGY LAN MESH',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.8,
                                      color: Color(0xFF6EE7B7),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (sessionTitle != null &&
                              sessionTitle!.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              sessionTitle!,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFF8FAFC),
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (summary.targetNodeName.isNotEmpty)
                                _SummaryMetaPill(
                                  icon: Icons.devices,
                                  label: summary.workspacePath.isNotEmpty
                                      ? '${summary.targetNodeName} (${summary.workspacePath})'
                                      : summary.targetNodeName,
                                ),
                              if (summary.modelLabel.isNotEmpty)
                                _SummaryMetaPill(
                                  icon: Icons.psychology_outlined,
                                  label: summary.modelLabel,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy Markdown Summary',
                      icon: const Icon(
                        Icons.copy_all_outlined,
                        size: 18,
                        color: Color(0xFF94A3B8),
                      ),
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: summary.toMarkdown(
                              sessionTitle: sessionTitle,
                            ),
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Copied Session Summary to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Issue / Findings / What We Did
                _SummarySectionRow(
                  icon: Icons.flag_circle_outlined,
                  accentColor: const Color(0xFFFBBF24),
                  title: 'ISSUE',
                  body: summary.issue,
                ),
                const SizedBox(height: 10),
                _SummarySectionRow(
                  icon: Icons.manage_search_rounded,
                  accentColor: const Color(0xFF38BDF8),
                  title: 'FINDINGS',
                  body: summary.findings,
                ),
                const SizedBox(height: 10),
                _SummarySectionRow(
                  icon: Icons.auto_fix_high_outlined,
                  accentColor: const Color(0xFF34D399),
                  title: 'WHAT WE DID',
                  body: summary.actionsTaken,
                ),

                const SizedBox(height: 16),

                // Bottom Stats Strip
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070E1A).withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF334155).withValues(alpha: 0.75),
                    ),
                  ),
                  child: Wrap(
                    spacing: 22,
                    runSpacing: 12,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      _SummaryMetricTile(
                        icon: Icons.timer_outlined,
                        iconColor: const Color(0xFF38BDF8),
                        label: 'TIME SPENT',
                        value: SessionCompletionSummary.formatDuration(
                          summary.activeDurationMs,
                        ),
                        subtitle:
                            '${summary.turnsCount} ${summary.turnsCount == 1 ? "turn" : "turns"}',
                      ),
                      _SummaryMetricTile(
                        icon: Icons.terminal_rounded,
                        iconColor: const Color(0xFFA78BFA),
                        label: 'REMOTE ACTIONS',
                        value: '${summary.toolCallsCount}',
                        subtitle: 'commands & file ops',
                      ),
                      _SummaryMetricTile(
                        icon: Icons.token_outlined,
                        iconColor: const Color(0xFFFBBF24),
                        label: 'TOKENS USED',
                        value: SessionCompletionSummary.formatTokens(
                          summary.totalTokens,
                        ),
                        subtitle: tokenSubParts.join(' • '),
                      ),
                      const _SummaryMetricTile(
                        icon: Icons.verified_rounded,
                        iconColor: Color(0xFF34D399),
                        label: 'OUTCOME',
                        value: 'Done',
                        subtitle: 'tasks completed',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryMetaPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SummaryMetaPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF94A3B8)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: Color(0xFFCBD5E1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummarySectionRow extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String body;

  const _SummarySectionRow({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: accentColor, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                  color: accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            body,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.42,
              color: Color(0xFFE2E8F0),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetricTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String subtitle;

  const _SummaryMetricTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: iconColor),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF94A3B8),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: Color(0xFFF8FAFC),
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
