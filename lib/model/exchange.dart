/// Static Exchange Evaluation, and what it says about whether a move gave
/// material away. Pure and board-only.
///
/// https://www.chessprogramming.org/Static_Exchange_Evaluation
library;

import 'package:dartchess/dartchess.dart';

import 'material_balance.dart';

/// What [attacker] wins by starting a sequence of captures on [square], in
/// pawns. Never negative: nobody is forced to start an exchange.
///
/// Each side takes with its cheapest attacker and may stop at any point.
/// Captured pieces leave the occupancy mask, so x-rays join the sequence. A
/// king only captures as the last attacker; promotions are scored as pawns.
int staticExchange(Board board, Square square, Side attacker) {
  final victim = board.pieceAt(square);
  if (victim == null || victim.color == attacker) return 0;
  return _see(board, square, attacker, board.occupied, valueOf(victim.role));
}

int _see(
  Board board,
  Square square,
  Side side,
  SquareSet occupied,
  int onSquare,
) {
  final from = cheapestAttacker(
    board,
    _attackersOn(board, square, side, occupied),
  );
  if (from == null) return 0;

  final remaining = occupied.withoutSquare(from);
  final capturing = board.pieceAt(from)!;
  // The king may not capture into a square that is still covered.
  if (capturing.role == Role.king &&
      _attackersOn(board, square, side.opposite, remaining).isNotEmpty) {
    return 0;
  }

  final gain =
      onSquare -
      _see(board, square, side.opposite, remaining, valueOf(capturing.role));
  return gain > 0 ? gain : 0;
}

/// What the piece on [square] costs [owner] if the opponent starts taking
/// there. Positive = it is being given away.
int exchangeLoss(Board board, Square square, Side owner) =>
    staticExchange(board, square, owner.opposite);

/// The smallest sacrifice worth the word, in pawns: a minor piece for a pawn.
const int sacrificeThreshold = 2;

/// The mover's pieces ON OFFER in [after]: non-pawn, non-king pieces worth
/// more than [capturedValue] (what this move took, so a recapture is not
/// generosity) that the opponent profits by taking.
///
/// Every piece is checked, not just the one that moved — a deflection that
/// leaves the queen hanging elsewhere is a sacrifice too. How much it cost is
/// [sacrificeHolds]'s question, not this one's.
List<Square> offeredPieces(
  Position after,
  Side mover, {
  int capturedValue = 0,
}) {
  final offered = <Square>[];
  for (final square in after.board.bySide(mover).squares) {
    final piece = after.board.pieceAt(square)!;
    if (piece.role == Role.pawn || piece.role == Role.king) continue;
    if (valueOf(piece.role) <= capturedValue) continue;
    if (exchangeLoss(after.board, square, mover) <= 0) continue;
    offered.add(square);
  }
  return offered;
}

/// True when the opponent has a LEGAL capture on [square]; a pinned
/// attacker does not count. En passant never matters here: only pawns are
/// taken that way and [offeredPieces] never returns one.
bool canBeCaptured(Position after, Square square) =>
    after.legalMoves.values.any((destinations) => destinations.has(square));

/// True when the engine's line [pvUci] from [positionAfter] puts [mover] at
/// least [sacrificeThreshold] pawns down at a mover-to-move checkpoint of its
/// first six plies, and [mover] is STILL at least a pawn down at the next
/// checkpoint (or the line ends there) — an investment, not a trade that
/// evens out on the next move. What the line wins later does not undo it: a
/// knight given for two pawns that then wins the queen was still given.
///
/// A line ending in mate for [mover] holds; a line never down that far does
/// not. Same idea as lichess's puzzle tagger (`tagger/cook.py`,
/// `sacrifice`), which asks for the deficit at any checkpoint.
bool sacrificeHolds({
  required Position positionAfter,
  required Side mover,
  required int materialBefore,
  required List<String> pvUci,
}) {
  var position = positionAfter;
  var down = false;

  for (final uci in pvUci.take(_sacrificePlies)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    position = position.play(move);

    if (position.isCheckmate && position.turn == mover.opposite) return true;
    if (position.isGameOver) break;
    if (position.turn != mover) continue;

    final deficit = materialBefore - materialFor(position.board, mover);
    if (down) return deficit >= _stillDown;
    down = deficit >= sacrificeThreshold;
  }
  return down;
}

/// What a sacrifice must still be down a move after it is taken, in pawns.
const int _stillDown = 1;

const int _sacrificePlies = 6;

/// The least valuable piece among [attackers], or null when there is none.
/// The king ranks last: it is worth 0 but can only take when nothing else
/// can.
Square? cheapestAttacker(Board board, SquareSet attackers) {
  Square? cheapest;
  var bestRank = 1 << 30;
  for (final from in attackers.squares) {
    final role = board.pieceAt(from)!.role;
    final rank = role == Role.king ? 1 << 20 : valueOf(role);
    if (rank < bestRank) {
      bestRank = rank;
      cheapest = from;
    }
  }
  return cheapest;
}

/// [side]'s pieces attacking [square] through [occupied], with pieces
/// already used up in the sequence left out.
SquareSet _attackersOn(
  Board board,
  Square square,
  Side side,
  SquareSet occupied,
) => board.attacksTo(square, side, occupied: occupied).intersect(occupied);
