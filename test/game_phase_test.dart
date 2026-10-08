import 'package:chess_mortem/model/game_phase.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Boards straight from the piece placement, not via a Position: the divider
/// only ever looks at where the pieces are, so these do not have to be legal
/// positions and some of them deliberately are not.
Board _board(String boardFen) => Board.parseFen(boardFen);

/// The boards BEFORE each move of [sans], which is what [divide] takes.
List<Board> _boardsOf(List<String> sans) {
  Position position = Chess.initial;
  final boards = <Board>[];
  for (final san in sans) {
    boards.add(position.board);
    position = position.play(position.parseSan(san)!);
  }
  return boards;
}

void main() {
  group('divider primitives', () {
    test('the starting position has 14 majors and minors', () {
      expect(majorsAndMinors(Board.standard), 14);
    });

    test('majors and minors ignore kings and pawns', () {
      // Two kings, two rooks, three pawns.
      expect(majorsAndMinors(_board('4k3/pppr4/8/8/8/8/4R3/4K3')), 2);
      expect(majorsAndMinors(_board('4k3/8/8/8/8/8/8/4K3')), 0);
    });

    test('a full back rank is not sparse', () {
      expect(backrankSparse(Board.standard), isFalse);
    });

    test('either side emptying its back rank is enough', () {
      // White has castled and developed; Black is untouched.
      expect(
        backrankSparse(_board('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/5RK1')),
        isTrue,
      );
      expect(
        backrankSparse(_board('5rk1/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR')),
        isTrue,
      );
    });

    test('the starting position is not mixed', () {
      // The two armies are on their own halves, so no 2x2 block holds both.
      expect(mixedness(Board.standard), lessThan(150));
    });

    test('interlocked pieces score higher than separated ones', () {
      final separated = mixedness(Board.standard);
      final interlocked = mixedness(_board('8/8/3pkp2/3PKP2/3pnp2/3PNP2/8/8'));
      expect(interlocked, greaterThan(separated));
    });
  });

  group('divide', () {
    test('an empty game divides into nothing', () {
      final division = divide([]);
      expect(division.middle, isNull);
      expect(division.end, isNull);
      expect(division.plies, 0);
    });

    test('the opening alone has no middlegame', () {
      // Four quiet developing moves: every piece is still home enough.
      final division = divide(_boardsOf(['e4', 'e5', 'Nf3', 'Nc6']));
      expect(division.hasMiddlegame, isFalse);
      expect(division.hasEndgame, isFalse);
      expect(division.plies, 4);
    });

    test('a 48-ply attacking game reaches a middlegame', () {
      final division = divide(
        _boardsOf(const [
          'e4', 'e5', 'd4', 'exd4', 'c3', 'Nc6', 'Bc4', 'd6', 'Nf3', 'Nf6', //
          'e5', 'dxe5', 'Bg5', 'Be7', 'Bxf6', 'Bxf6', 'Bxf7+', 'Kxf7',
          'Nxe5+', 'Nxe5', 'Qh5+', 'Ng6', 'O-O', 'Re8', 'cxd4', 'Kg8',
          'Nc3', 'Qxd4', 'Rad1', 'Qg4', 'Qd5+', 'Be6', 'Qxb7', 'Bxc3',
          'bxc3', 'Bxa2', 'Qxc7', 'Rec8', 'Qb7', 'Bf7', 'Ra1', 'a5',
          'Rfc1', 'a4', 'h3', 'Qc4', 'Ra3', 'Rcb8',
        ]),
      );
      expect(division.hasMiddlegame, isTrue);
      expect(division.middle, greaterThan(0));
      expect(division.plies, 48);
    });

    test('an endgame that arrives first cancels the middlegame', () {
      // Bare kings and a pawn: majorsAndMinors is 0 from ply 0, so the
      // endgame starts at 0 and the middlegame cannot start at or after it.
      final boards = [
        _board('4k3/4p3/8/8/8/8/4P3/4K3'),
        _board('4k3/4p3/8/8/8/4P3/8/4K3'),
      ];
      final division = divide(boards);
      expect(division.end, 0);
      expect(division.middle, isNull);
      expect(division.hasMiddlegame, isFalse);
      expect(division.hasEndgame, isTrue);
    });
  });

  group('phaseAt', () {
    test('reads the boundaries as first plies of their phase', () {
      const division = GameDivision(middle: 10, end: 30, plies: 40);
      expect(division.phaseAt(0), GamePhase.opening);
      expect(division.phaseAt(9), GamePhase.opening);
      expect(division.phaseAt(10), GamePhase.middlegame);
      expect(division.phaseAt(29), GamePhase.middlegame);
      expect(division.phaseAt(30), GamePhase.endgame);
      expect(division.phaseAt(39), GamePhase.endgame);
    });

    test('everything is opening when there is no middlegame', () {
      const division = GameDivision(plies: 12);
      expect(division.phaseAt(0), GamePhase.opening);
      expect(division.phaseAt(11), GamePhase.opening);
    });
  });
}
