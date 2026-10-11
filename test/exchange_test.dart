import 'package:chess_mortem/model/exchange.dart';
import 'package:chess_mortem/model/material_balance.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position _position(String fen) => Chess.fromSetup(Setup.parseFen(fen));

/// A whole game, in move order: an Italian where a one-reply material count
/// would score three ordinary moves as Brilliant.
const List<String> _gamePgnMainline = [
  'e4', 'e5', 'Nf3', 'Bc5', 'Bc4', 'Nf6', 'Nc3', 'O-O', 'd3', 'Bxf2+', //
  'Kxf2', 'c6', 'Re1', 'd5', 'exd5', 'cxd5', 'Bb3', 'Qb6+', 'Kf1', 'e4', //
  'dxe4', 'dxe4', 'Nxe4', 'Bg4', 'Nxf6+', 'Qxf6', 'Qd4', 'Qg6', 'Qf4', 'Bxf3',
  'Qxf3', 'Nc6', 'Bd2', 'Nd4', 'Qd3', 'Qf6+', 'Kg1', 'Rad8', 'Bc3', 'Qb6', //
  'Bxd4', 'Rxd4', 'Qe3', 'Qd6', 'Qf3', 'Kh8', 'Qxb7', 'Rh4', 'h3', 'Qd4+', //
  'Kh1', 'Rd8', 'Qxf7', 'Rf4', 'Re8+', 'Rxe8', 'Qxe8+', 'Rf8', 'Qxf8#',
];

Position _afterSans(List<String> sans) {
  Position position = Chess.initial;
  for (final san in sans) {
    position = position.play(position.parseSan(san)!);
  }
  return position;
}

void main() {
  group('staticExchange', () {
    test('an undefended piece is worth its full value', () {
      // A lone black knight on e5; White's pawn on d4 simply takes it.
      final board = _position('4k3/8/8/4n3/3P4/8/8/4K3 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 3);
    });

    test('nothing to take, or your own piece, is zero', () {
      final board = _position('4k3/8/8/4n3/3P4/8/8/4K3 w - - 0 1').board;
      expect(staticExchange(board, Square.e4, Side.white), 0);
      expect(staticExchange(board, Square.d4, Side.white), 0);
    });

    test('an even trade is zero, not the value of the first capture', () {
      // Knight for knight: white Nd3 takes on e5, the f6 pawn takes back.
      final board = _position('4k3/8/5p2/4n3/8/3N4/8/4K3 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 0);
    });

    test('a defended minor taken by a pawn still wins two', () {
      // Knight on e5 defended by the rook on e8: PxN wins 3, RxP gives back 1.
      final board = _position('4r2k/8/8/4n3/3P4/8/8/4K3 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 2);
    });

    test('a capture that would lose material is simply not made', () {
      // A pawn on e5 defended twice, attacked by a knight: NxP is a piece for
      // a pawn, so White does not start. Nobody is forced into an exchange.
      final board = _position('4k3/8/3p1p2/4p3/8/5N2/8/4K3 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 0);
    });

    test('a piece behind a piece joins the sequence', () {
      // Doubled white rooks on e1/e2 against a black rook on e5 defended by
      // its own rook on e8. RxR, RxR, RxR: White ends a rook up.
      // Without the x-ray the front rook looks like it is trading into a
      // defender and losing.
      final board = _position('4r2k/8/8/4r3/8/8/4R3/4R2K w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 5);
    });

    test('the king may not capture into a defended square', () {
      // Black knight on e5, defended by the f6 pawn, with only the white king
      // attacking it. Kxe5 is illegal, so nothing is won.
      final board = _position('7k/8/5p2/4n3/4K3/8/8/8 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 0);
    });

    test('the king takes freely when nothing recaptures', () {
      final board = _position('7k/8/8/4n3/4K3/8/8/8 w - - 0 1').board;
      expect(staticExchange(board, Square.e5, Side.white), 3);
    });

    test('exchangeLoss is the same question from the owner\'s side', () {
      final board = _position('4k3/8/8/4n3/3P4/8/8/4K3 w - - 0 1').board;
      expect(exchangeLoss(board, Square.e5, Side.black), 3);
    });
  });

  group('offeredPieces', () {
    test('a knight left en prise is on offer', () {
      // The Fried Liver: Nxf7 puts the knight on a square the king takes on.
      final after = _afterSans([
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bc4',
        'Nf6',
        'Ng5',
        'd5',
        'exd5',
        'Nxd5',
        'Nxf7',
      ]);
      expect(
        offeredPieces(
          after,
          Side.white,
          capturedValue: pieceValues[Role.pawn]!,
        ),
        contains(Square.f7),
      );
    });

    test('a piece that took something of equal value is not on offer', () {
      // Bxc6 in the Ruy Lopez: the bishop can be taken, but it took a knight
      // first, so the exchange is a trade and nothing was given.
      final after = _afterSans(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Bxc6']);
      expect(
        offeredPieces(
          after,
          Side.white,
          capturedValue: pieceValues[Role.knight]!,
        ),
        isEmpty,
      );
    });

    test('pawns are never counted as sacrificed material', () {
      // The Queen's Gambit hands over a pawn and nothing else.
      final after = _afterSans(['d4', 'd5', 'c4']);
      expect(offeredPieces(after, Side.white), isEmpty);
    });

    test('a defended piece is not on offer', () {
      final after = _afterSans(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']);
      expect(offeredPieces(after, Side.white), isEmpty);
    });

    test('15.Qf4 offers nothing — the g2 pawn takes back', () {
      // Read one reply deep this hands over a knight (15...Bxf3). The
      // exchange on f3 is a trade: the queen and
      // the g2 pawn both defend it.
      final after = _afterSans(_gamePgnMainline.take(29).toList());
      expect(exchangeLoss(after.board, Square.f3, Side.white), 0);
      expect(offeredPieces(after, Side.white), isEmpty);
    });

    test('28.Re8+ offers nothing — the queen defends e8', () {
      final after = _afterSans(_gamePgnMainline.take(55).toList());
      // The rook that "was sacrificed" is defended by the queen on f7, so the
      // exchange on e8 is a trade and nothing is given.
      expect(exchangeLoss(after.board, Square.e8, Side.white), 0);

      // The queen herself IS attacked, by the rook on f4 — but Black is in
      // check and that capture is not legal, which is the whole reason a
      // second, legality-aware test stands behind the exchange count.
      expect(offeredPieces(after, Side.white), [Square.f7]);
      expect(canBeCaptured(after, Square.f7), isFalse);
    });
  });

  group('canBeCaptured', () {
    test('true when a legal move lands on the square', () {
      final after = _afterSans([
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bc4',
        'Nf6',
        'Ng5',
        'd5',
        'exd5',
        'Nxd5',
        'Nxf7',
      ]);
      expect(canBeCaptured(after, Square.f7), isTrue);
    });

    test('false for a square nothing attacks', () {
      final after = _afterSans(['e4', 'e5']);
      expect(canBeCaptured(after, Square.e4), isFalse);
    });

    test('an absolutely pinned attacker cannot take', () {
      // The black bishop on d6 attacks the white knight on e5, but it is the
      // only thing between the rook on d1 and its own king on d8. Attacker
      // counting says e5 is attacked; the legal move list knows better.
      final position = _position('3k4/8/3b4/4N3/8/8/8/3RK3 b - - 0 1');
      expect(
        position.board.attacksTo(Square.e5, Side.black).isNotEmpty,
        isTrue,
      );
      expect(canBeCaptured(position, Square.e5), isFalse);
    });
  });

  group('sacrificeHolds', () {
    // Fried Liver again: after Nxf7 White has given a knight for a pawn and,
    // whatever else happens, does not get it back in this window.
    Position friedLiver() => _afterSans([
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bc4',
      'Nf6',
      'Ng5',
      'd5',
      'exd5',
      'Nxd5',
      'Nxf7',
    ]);

    int materialBeforeNxf7() {
      final before = _afterSans([
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bc4',
        'Nf6',
        'Ng5',
        'd5',
        'exd5',
        'Nxd5',
      ]);
      return materialFor(before.board, Side.white);
    }

    test('a deficit that survives the line is a sacrifice', () {
      expect(
        sacrificeHolds(
          positionAfter: friedLiver(),
          mover: Side.white,
          materialBefore: materialBeforeNxf7(),
          // Kxf7, Qf3+, Ke6.
          pvUci: const ['e8f7', 'd1f3', 'f7e6'],
        ),
        isTrue,
      );
    });

    test('material won straight back is a tactic, not a sacrifice', () {
      // 28.Re8+ looks like a whole rook thrown in, and read one reply deep
      // it is — but Qxe8+ takes it back on the next move.
      final sans = _gamePgnMainline.take(54).toList(); // through 27...Rf4
      final before = _afterSans(sans);
      final after = before.play(before.parseSan('Re8+')!);
      // A PV the walk cannot play would make this pass for the wrong reason.
      expect(after.isLegal(Move.parse('d8e8')!), isTrue);
      expect(
        sacrificeHolds(
          positionAfter: after,
          mover: Side.white,
          materialBefore: materialFor(before.board, Side.white),
          // Rxe8, Qxe8+, Rf8, Qxf8#.
          pvUci: const ['d8e8', 'f7e8', 'f4f8', 'e8f8'],
        ),
        isFalse,
      );
    });

    test('a piece still down a move later is a sacrifice, whatever the '
        'line wins after', () {
      // 20...Nxf3+ 21.gxf3 Qxf3: a knight for two pawns, still a pawn down
      // when White moves on, and then ...Qxc3 wins the queen.
      final before = Chess.fromSetup(
        Setup.parseFen(
          'r3r1k1/pb3p1p/1p4p1/2pq4/2Nn4/1PQB1P2/P5PP/R3R1K1 b - - 0 20',
        ),
      );
      expect(
        sacrificeHolds(
          positionAfter: before.play(Move.parse('d4f3')!),
          mover: Side.black,
          materialBefore: materialFor(before.board, Side.black),
          // gxf3, Qxf3, Be4, Qxc3, Bxb7, Rxe1+.
          pvUci: const ['g2f3', 'd5f3', 'd3e4', 'f3c3', 'e4b7', 'e8e1'],
        ),
        isTrue,
      );
    });

    test('a deficit gone by the next move is a trade, not a sacrifice', () {
      // 32.Qxf8+ Qxf8 33.Rxf8+ Kxf8: the queen is down for one move only.
      final before = Chess.fromSetup(
        Setup.parseFen(
          '5rk1/1r4pp/bR6/3Pp3/p3P3/q2p1Q1P/3N2P1/5R1K w - - 1 32',
        ),
      );
      expect(
        sacrificeHolds(
          positionAfter: before.play(Move.parse('f3f8')!),
          mover: Side.white,
          materialBefore: materialFor(before.board, Side.white),
          // Qxf8, Rxf8+, Kxf8, Rxa6.
          pvUci: const ['a3f8', 'f1f8', 'g8f8', 'b6a6'],
        ),
        isFalse,
      );
    });

    test('a line nothing is known about is not a sacrifice', () {
      expect(
        sacrificeHolds(
          positionAfter: friedLiver(),
          mover: Side.white,
          materialBefore: materialBeforeNxf7(),
          pvUci: const [],
        ),
        isFalse,
      );
      // An illegal PV stops the walk, and stopping before any checkpoint is
      // the same as knowing nothing.
      expect(
        sacrificeHolds(
          positionAfter: friedLiver(),
          mover: Side.white,
          materialBefore: materialBeforeNxf7(),
          pvUci: const ['a1a8'],
        ),
        isFalse,
      );
    });

    test('a line that ends in mate holds however the count reads', () {
      // Legal's Mate: 1.e4 e5 2.Nf3 d6 3.Bc4 Bg4 4.Nc3 g6 5.Nxe5 Bxd1
      // 6.Bxf7+ Ke7 7.Nd5#. White is a queen down and mating.
      final after = _afterSans([
        'e4',
        'e5',
        'Nf3',
        'd6',
        'Bc4',
        'Bg4',
        'Nc3',
        'g6',
        'Nxe5',
        'Bxd1',
      ]);
      final before = _afterSans([
        'e4',
        'e5',
        'Nf3',
        'd6',
        'Bc4',
        'Bg4',
        'Nc3',
        'g6',
        'Nxe5',
      ]);
      expect(
        sacrificeHolds(
          positionAfter: after,
          mover: Side.white,
          materialBefore: materialFor(before.board, Side.white),
          pvUci: const ['c4f7', 'e8e7', 'c3d5'],
        ),
        isTrue,
      );
    });
  });
}
