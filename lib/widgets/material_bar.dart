import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../appearance/appearance_controller.dart';
import '../appearance/board_appearance.dart';
import '../model/material_balance.dart';

/// One player's strip beside the board: name and rating on the left, the
/// material lead on the right, "+N" on the leading side only.
class MaterialBar extends StatelessWidget {
  const MaterialBar({
    super.key,
    required this.board,
    required this.side,
    this.name,
    this.rating,
    this.width,
  });

  final Board board;

  /// Whose strip this is: it shows what THIS side is ahead by.
  final Side side;

  /// From the PGN; nothing is drawn without one.
  final String? name;
  final String? rating;

  /// The board's width, so the strip lines up with it.
  final double? width;

  /// Fixed: the board is sized from what is left over.
  static const double height = 20;

  static const double _glyphSize = 14;

  /// Picked from the colour of the pieces drawn: a cburnett black piece
  /// vanishes on a dark theme. Not a theme colour, on purpose.
  static const Color _lightBackdrop = Color(0xFFE4E4E4);
  static const Color _darkBackdrop = Color(0xFF5A5A5A);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surplus = materialDiff(board, side);
    final balance = materialBalance(board);
    final lead = side == Side.white ? balance : -balance;
    final label = name == null
        ? null
        : (rating == null ? name! : '$name  $rating');

    return SizedBox(
      height: height,
      width: width,
      child: Row(
        children: [
          // The ONLY flex child, so the material ends flush right. A Spacer
          // beside it would split the slack and leave a gap after the pieces.
          Expanded(
            child: label == null
                ? const SizedBox.shrink()
                : Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
          ),
          if (surplus.isNotEmpty) ...[
            const SizedBox(width: 6),
            _pieces(surplus, AppearanceScope.of(context).pieceStyle),
          ],
          if (lead > 0) ...[
            const SizedBox(width: 5),
            Text(
              '+$lead',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pieces(List<Role> surplus, PieceStyle pieces) {
    final victim = side.opposite;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: victim == Side.black ? _lightBackdrop : _darkBackdrop,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final role in surplus)
            Image(
              // Unicode ♘ is unreliable in Android's font fallback.
              image: pieces.image(Piece(color: victim, role: role)),
              width: _glyphSize,
              height: _glyphSize,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            ),
        ],
      ),
    );
  }
}
