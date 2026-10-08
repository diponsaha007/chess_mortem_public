/// Opening / middlegame / endgame boundaries: a verbatim port of lichess's
/// `Divider.scala`. Decided by the pieces, not move numbers, so a short game
/// can have no middlegame.
library;

import 'package:dartchess/dartchess.dart';

enum GamePhase {
  opening('Opening'),
  middlegame('Middlegame'),
  endgame('Endgame');

  const GamePhase(this.label);

  final String label;
}

/// The two boundaries of a game, as ply numbers.
class GameDivision {
  const GameDivision({this.middle, this.end, required this.plies});

  static const GameDivision empty = GameDivision(plies: 0);

  /// First ply of the middlegame, or null when the game never left the opening.
  final int? middle;

  /// First ply of the endgame, or null when the game never reached one.
  final int? end;

  /// How many plies were divided.
  final int plies;

  bool get hasMiddlegame => middle != null;

  bool get hasEndgame => end != null;

  /// The phase a move belongs to, by the ply it LANDS on — exactly as
  /// lichess's `phaseAccuracies` buckets it. Do not switch to the ply it was
  /// played from; the numbers would stop matching.
  GamePhase phaseAt(int ply) {
    if (end != null && ply >= end!) return GamePhase.endgame;
    if (middle != null && ply >= middle!) return GamePhase.middlegame;
    return GamePhase.opening;
  }

  @override
  String toString() => 'GameDivision(middle: $middle, end: $end, $plies plies)';
}

/// Divides a game into phases. [boards] holds the board BEFORE each move, so
/// `boards[i]` is ply `i` and the boundaries returned are ply numbers.
GameDivision divide(List<Board> boards) {
  int? midGame;
  for (var i = 0; i < boards.length; i++) {
    final board = boards[i];
    if (majorsAndMinors(board) <= 10 ||
        backrankSparse(board) ||
        mixedness(board) > 150) {
      midGame = i;
      break;
    }
  }

  int? endGame;
  if (midGame != null) {
    // Faithful to lichess: rescanned from ply 0, not from the middlegame.
    for (var i = 0; i < boards.length; i++) {
      if (majorsAndMinors(boards[i]) <= 6) {
        endGame = i;
        break;
      }
    }
  }

  // `midGame.filter(m => endGame.fold(true)(m < _))`
  final middle = (midGame != null && (endGame == null || midGame < endGame))
      ? midGame
      : null;

  return GameDivision(middle: middle, end: endGame, plies: boards.length);
}

/// Pieces that are neither king nor pawn, both colours. 14 at the start.
int majorsAndMinors(Board board) =>
    (board.occupied ^ (board.kings | board.pawns)).size;

/// A thin back rank means the pieces have been developed. Either side counts.
bool backrankSparse(Board board) =>
    (SquareSet.firstRank & board.white).size < 4 ||
    (SquareSet.eighthRank & board.black).size < 4;

/// How intertwined the two armies are, summed over every 2x2 block of squares.
int mixedness(Board board) {
  var acc = 0;
  for (var i = 0; i < _mixednessRegions.length; i++) {
    final region = _mixednessRegions[i];
    final y = i ~/ 7 + 1;
    acc += _score(y, (board.white & region).size, (board.black & region).size);
  }
  return acc;
}

/// The 49 overlapping 2x2 blocks of squares, in lichess's order: y outer, x
/// inner, so index `i` is row `i ~/ 7`.
final List<SquareSet> _mixednessRegions = [
  for (var y = 0; y <= 6; y++)
    for (var x = 0; x <= 6; x++) const SquareSet(0x0303).shl(x + 8 * y),
];

/// lichess's hand-tuned table. [y] is the block's rank, 1-7; [white] and
/// [black] are how many pieces of each colour stand in it, 0-4.
int _score(int y, int white, int black) {
  switch (white) {
    case 0:
      switch (black) {
        case 1:
          return 1 + y;
        case 2:
          return y < 6 ? 2 + (6 - y) : 0;
        case 3:
          return y < 7 ? 3 + (7 - y) : 0;
        case 4:
          return y < 7 ? 3 + (7 - y) : 0;
        default:
          return 0;
      }
    case 1:
      switch (black) {
        case 0:
          return 1 + (8 - y);
        case 1:
          return 5 + (4 - y).abs();
        case 2:
          return 4 + (7 - y);
        case 3:
          return 5 + (7 - y);
        default:
          return 0;
      }
    case 2:
      switch (black) {
        case 0:
          return y > 2 ? 2 + (y - 2) : 0;
        case 1:
          return 4 + (y - 1);
        case 2:
          return 7;
        default:
          return 0;
      }
    case 3:
      switch (black) {
        case 0:
          return y > 1 ? 3 + (y - 1) : 0;
        case 1:
          return 5 + (y - 1);
        default:
          return 0;
      }
    case 4:
      // A group of four on the home row is not "mixed" at all.
      return black == 0 ? (y > 1 ? 3 + (y - 1) : 0) : 0;
    default:
      return 0;
  }
}
