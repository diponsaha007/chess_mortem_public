import 'package:flutter/material.dart';

import '../model/game_tree.dart';
import 'move_list.dart';

/// Where Show is in the line it plays, for the coach bar.
class ShowProgress {
  const ShowProgress({
    required this.reached,
    required this.moves,
    required this.playing,
  });

  /// Moves of the line on the board so far.
  final int reached;

  /// Moves in the line.
  final int moves;

  /// False once it has ended or was stopped.
  final bool playing;
}

/// The line under the board: verdict, ONE line of prose (`coachLine`), and
/// the better move and best reply. Tapping it opens the full sheet.
///
/// With [onShow], a Show button takes the hints' place and plays the line
/// out on the board. While a line is shown ([show]), the bar keeps the shown
/// move's line, with the progress and Stop, then Back and Replay once it has
/// ended.
class CoachBar extends StatelessWidget {
  const CoachBar({
    super.key,
    required this.node,
    required this.line,
    required this.onTap,
    this.onShow,
    this.show,
    this.onStop,
    this.onBack,
    this.onReplay,
  });

  final GameNode node;

  /// The coach line for [node], from `coachLine`.
  final String line;
  final VoidCallback? onTap;

  /// Plays [line]'s point out on the board; null where there is none.
  final VoidCallback? onShow;

  /// The line being shown, or null outside a show.
  final ShowProgress? show;
  final VoidCallback? onStop;
  final VoidCallback? onBack;
  final VoidCallback? onReplay;

  /// How many lines of prose the bar shows before it cuts the line.
  static const int lines = 3;

  /// The Show button.
  static const showKey = ValueKey('coachBarShow');

  /// Room for [lines] lines at the phone's text size. It depends on the
  /// text size alone, never on the line, so the board never resizes while
  /// stepping through the game.
  static double heightFor(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall!;
    final line = MediaQuery.textScalerOf(
      context,
    ).scale(style.fontSize! * (style.height ?? 1.2));
    return lines * line + 10;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: heightFor(context),
      child: InkWell(
        onTap: node.isRoot || show != null ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 8, top: 4, bottom: 4),
          child: _row(context),
        ),
      ),
    );
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final show = this.show;
    return Row(
      children: [
        _leadingIcon(context),
        const SizedBox(width: 8),
        Expanded(
          child: show == null
              ? _lineText(context, lines)
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _lineText(context, lines - 1),
                    const SizedBox(height: 6),
                    _progress(context, show),
                  ],
                ),
        ),
        // The line shows the better move and the reply itself, as the
        // arrows do: Show takes the hints' room.
        if (show == null && onShow != null)
          _action(context, Icons.play_arrow, 'Show', onShow, key: showKey)
        else if (show == null) ...[
          _moveHints(context),
          if (!node.isRoot)
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.outline,
            ),
        ] else if (show.playing)
          _action(context, Icons.stop, 'Stop', onStop)
        else ...[
          IconButton(
            onPressed: onBack,
            tooltip: 'Back to the move',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.undo),
          ),
          _action(context, Icons.replay, 'Replay', onReplay),
        ],
      ],
    );
  }

  Widget _lineText(BuildContext context, int maxLines) {
    final classification = node.classification;
    return Text.rich(
      TextSpan(
        children: [
          if (classification != null && !node.isBook)
            TextSpan(
              text: '${classification.label} · ',
              style: TextStyle(
                color: classificationColor(classification),
                fontWeight: FontWeight.bold,
              ),
            ),
          TextSpan(text: line),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  /// One segment per move of the shown line, filled as it is played.
  Widget _progress(BuildContext context, ShowProgress show) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Move ${show.reached} of ${show.moves}',
      child: Row(
        children: [
          for (var i = 0; i < show.moves; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i < show.reached
                      ? scheme.primary
                      : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A labelled button at the bar's end, in the colours of the move list's
  /// current move, clear of the screen's edge.
  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    Key? key,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: FilledButton.tonalIcon(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          padding: const EdgeInsets.only(left: 12, right: 16),
          visualDensity: VisualDensity.compact,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }

  /// The improvement over the move played and the opponent's best reply.
  Widget _moveHints(BuildContext context) {
    final theme = Theme.of(context);
    final better = node.betterMoveSan;
    final reply = node.replyMoveSan;
    if (better == null && reply == null) return const SizedBox.shrink();

    Text label(String text, Color color) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.bold,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (better != null) label('Best: $better', theme.colorScheme.primary),
          if (reply != null) label('Reply: $reply', theme.colorScheme.tertiary),
        ],
      ),
    );
  }

  /// The verdict badge. Never a spinner.
  Widget _leadingIcon(BuildContext context) {
    final theme = Theme.of(context);
    if (node.isBook) {
      return const BookBadge(size: 20);
    }
    final classification = node.classification;
    if (classification == null) {
      return Icon(
        Icons.psychology_alt,
        size: 20,
        color: theme.colorScheme.outline,
      );
    }
    return ClassificationBadge(classification: classification, size: 20);
  }
}
