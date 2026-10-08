import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

/// A player's colour as a disc, outlined so black shows on a dark page.
class SideDot extends StatelessWidget {
  const SideDot({super.key, required this.side, this.size = 10});

  final Side side;
  final double size;

  static const _white = Color(0xFFEFEEEA);
  static const _black = Color(0xFF191D1C);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: side == Side.white ? _white : _black,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

/// Marks the player the user is.
class YouChip extends StatelessWidget {
  const YouChip({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'YOU',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
          fontSize: 9,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
