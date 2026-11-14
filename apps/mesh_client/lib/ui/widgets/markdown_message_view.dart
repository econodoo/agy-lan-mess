import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

class MessageBubbleCard extends StatefulWidget {
  final SessionMessage message;

  const MessageBubbleCard({super.key, required this.message});

  @override
  State<MessageBubbleCard> createState() => _MessageBubbleCardState();
}

class _MessageBubbleCardState extends State<MessageBubbleCard> {
  bool _showThinking = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
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
                  if (msg.status == 'streaming') ...[
                    const SizedBox(width: 10),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
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
