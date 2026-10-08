import 'package:flutter/material.dart';

import '../model/game_tree.dart';
import 'move_list.dart';

/// The line under the board: verdict, ONE line of prose (`coachLine`), and
/// the better move and best reply. Tapping it opens the full sheet.
class CoachBar extends StatelessWidget {
  const CoachBar({
    super.key,
    required this.node,
    required this.line,
    required this.onTap,
  });

  final GameNode node;

  /// The coach line for [node], from `coachLine`.
  final String line;
  final VoidCallback onTap;

  /// How many lines of prose the bar shows before it cuts the line.
  static const int lines = 3;

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
    final theme = Theme.of(context);
    final classification = node.classification;

    return SizedBox(
      height: heightFor(context),
      child: InkWell(
        onTap: node.isRoot ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              _leadingIcon(context),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
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
                  maxLines: lines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              _moveHints(context),
              if (!node.isRoot)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
            ],
          ),
        ),
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
