/// Repetition, read off the game tree: how often a position has stood, and
/// whether that ends the game. Positions match on the FEN without its
/// counters: pieces, side to move, castling rights and a legal en-passant
/// capture.
library;

import 'game_tree.dart';
import 'opening_key.dart' show openingEpd;

/// How many times [node]'s position has stood on the way to it, itself
/// included.
int repetitionsOf(GameNode node) {
  final key = openingEpd(node.position);
  var count = 0;
  for (GameNode? n = node; n != null; n = n.parent) {
    if (openingEpd(n.position) == key) count++;
    // A pawn move or a capture: nothing earlier can stand again.
    if (n.position.halfmoves == 0) break;
  }
  return count;
}

/// Whether [node]'s position is a draw by repetition. The fifth time always
/// is. The third is when the line stops there (the game ended, so the draw
/// was taken) or when the user played the move: the other side can claim
/// it. A game that went on past it was not drawn.
bool drawnByRepetition(GameNode node) {
  final times = repetitionsOf(node);
  if (times >= 5) return true;
  return times >= 3 &&
      (node.isUserMove || node.children.every((c) => c.isUserMove));
}

/// Whether the side that played [node]'s move gave check with every one of
/// its moves since the position last stood: a repetition by perpetual
/// check. False when the position has not stood before.
bool repeatedByChecks(GameNode node) {
  final key = openingEpd(node.position);
  final checker = node.sideThatMoved;
  for (GameNode? n = node; n != null && n.parent != null; n = n.parent) {
    if (n.sideThatMoved == checker && !n.position.isCheck) return false;
    final earlier = n.parent!;
    if (openingEpd(earlier.position) == key) return true;
    if (earlier.position.halfmoves == 0) return false;
  }
  return false;
}
