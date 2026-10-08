import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logging/app_log.dart';
import '../widgets/safe_bottom.dart';

/// Renders [AppLog], with copy and clear.
class LogScreen extends StatelessWidget {
  const LogScreen({super.key, AppLog? log}) : _log = log;

  final AppLog? _log;

  @override
  Widget build(BuildContext context) {
    final log = _log ?? AppLog.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy log',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log.asText()));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Log copied')));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: log.clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final entries = log.entries;
          if (entries.isEmpty) {
            return const Center(child: Text('Nothing logged yet.'));
          }
          return ListView.builder(
            padding: withSafeBottom(context, const EdgeInsets.all(12)),
            itemCount: entries.length,
            itemBuilder: (context, i) =>
                _LogLine(entries[i], key: ObjectKey(entries[i])),
          );
        },
      ),
    );
  }
}

class _LogLine extends StatefulWidget {
  // Keyed by entry: the log drops its oldest lines, and an opened line's
  // state must not slide onto its neighbour.
  const _LogLine(this.entry, {super.key});

  final LogEntry entry;

  @override
  State<_LogLine> createState() => _LogLineState();
}

class _LogLineState extends State<_LogLine> {
  /// Long entries (an LLM prompt) collapse to this and open on a tap.
  static const collapsedLines = 3;

  bool _expanded = false;

  bool get _isLong =>
      widget.entry.message.length > 200 ||
      '\n'.allMatches(widget.entry.message).length >= collapsedLines;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);
    final colour = switch (entry.level) {
      LogLevel.error => theme.colorScheme.error,
      LogLevel.warn => theme.colorScheme.tertiary,
      LogLevel.info => theme.colorScheme.onSurfaceVariant,
    };

    final collapsed = _isLong && !_expanded;

    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${entry.clock}  ',
            style: TextStyle(color: theme.colorScheme.outline),
          ),
          TextSpan(
            text: '${entry.tag}  ',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: entry.message,
            style: TextStyle(color: colour),
          ),
        ],
      ),
      maxLines: collapsed ? collapsedLines : null,
      overflow: collapsed ? TextOverflow.ellipsis : TextOverflow.clip,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        height: 1.35,
      ),
    );

    if (!_isLong) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: text,
      );
    }

    // InkResponse, not a button, so the row keeps its own height.
    return InkResponse(
      onTap: () => setState(() => _expanded = !_expanded),
      highlightShape: BoxShape.rectangle,
      containedInkWell: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            Text(
              _expanded ? 'tap to collapse' : 'tap to show all',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
