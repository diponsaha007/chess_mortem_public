import 'package:chess_mortem/model/move_facts.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position _positionAfter(List<String> sans) {
  Position position = Chess.initial;
  for (final san in sans) {
    position = position.play(position.parseSan(san)!);
  }
  return position;
}

/// The facts for the SAN move [san] played in the position reached by [sans].
List<String> _factsFor(List<String> sans, String san, {String? replyUci}) {
  final before = _positionAfter(sans);
  final move = before.parseSan(san)!;
  return moveFacts(before: before, move: move, san: san, replyUci: replyUci);
}

/// One fact containing every one of [parts], or a readable failure.
Matcher _says(List<String> parts) => contains(
  predicate<String>(
    (fact) => parts.every(fact.contains),
    'a fact mentioning ${parts.join(' + ')}',
  ),
);

void main() {
  group('what was played', () {
    test('a plain move states no bare route', () {
      // "Nf3 is the knight from g1 to f3" is read back as the explanation.
      expect(_factsFor([], 'Nf3'), isNot(_says(['from g1'])));
    });

    test('a capture names what was taken and where', () {
      expect(
        _factsFor(['e4', 'd5'], 'exd5'),
        _says(['captures', 'black pawn', 'd5']),
      );
    });

    test('en passant names the pawn beside the landing square', () {
      // The captured pawn is NOT on the square the pawn lands on, which is
      // exactly the detail a model gets wrong unaided. It gets its colour
      // like every other capture: dropping it here was an inconsistency the
      // model had to resolve for itself.
      final facts = _factsFor(['e4', 'a6', 'e5', 'd5'], 'exd6');
      expect(facts, _says(['captures the black pawn on d5 en passant']));
    });

    test('castling reports the king, not the rook corner', () {
      final facts = _factsFor(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5'], 'O-O');
      expect(facts, _says(['castles kingside', 'g1']));
    });

    test('promotion says what the pawn became', () {
      final position = Chess.fromSetup(
        Setup.parseFen('7k/P7/8/8/8/8/8/7K w - - 0 1'),
      );
      final facts = moveFacts(
        before: position,
        move: position.parseSan('a8=Q')!,
        san: 'a8=Q',
      );
      expect(facts, _says(['promotes', 'queen', 'a8']));
    });

    test('check and mate are stated outright', () {
      expect(
        _factsFor(['e4', 'e5', 'Qh5', 'Nc6', 'Bc4', 'Nf6'], 'Qxf7'),
        contains('It is checkmate.'),
      );
      expect(
        _factsFor(['e4', 'e5', 'Bc4', 'Nc6'], 'Qh5'),
        isNot(contains('It is checkmate.')),
      );
    });

    test('an illegal move has no facts rather than invented ones', () {
      expect(
        moveFacts(
          before: Chess.initial,
          move: NormalMove(from: Square.e2, to: Square.e5),
          san: 'e5',
        ),
        isEmpty,
      );
    });
  });

  group('what the move does', () {
    test('a fork is named as one', () {
      // Knight on c7 hitting the king on e8 and the rook on a8 — the king is
      // reported as check, so the fork line names the pieces it attacks.
      final position = Chess.fromSetup(
        Setup.parseFen('r3k3/8/8/3N4/8/8/8/4K3 w - - 0 1'),
      );
      final facts = moveFacts(
        before: position,
        move: position.parseSan('Nb6')!,
        san: 'Nb6',
      );
      expect(facts, _says(['knight on b6', 'attacks', 'black rook on a8']));
    });

    test('a piece left en prise is reported with what takes it', () {
      final facts = _factsFor(['e4', 'e5', 'Nf3'], 'Nf6');
      // Nf6 attacks the e4 pawn; the knight itself is fine. What matters is
      // the app noticing the pawn is undefended.
      expect(facts, _says(['e4']));
    });

    test('the moved piece being left en prise is spelled out', () {
      final facts = _factsFor(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'h6'], 'Ng5');
      expect(facts, _says(['knight on g5', 'black pawn on h6']));
    });

    test('a pin against the king is named', () {
      final position = Chess.fromSetup(
        Setup.parseFen('4k3/8/4n3/8/8/8/8/3R2K1 w - - 0 1'),
      );
      final facts = moveFacts(
        before: position,
        move: position.parseSan('Re1')!,
        san: 'Re1',
      );
      // The rook on e1 sees e6 through nothing but the knight, with the king
      // behind it.
      expect(facts, _says(['pins', 'black knight on e6', 'king on e8']));
    });

    test('a pin against the queen is named too', () {
      // Bg5 in the Queen's Gambit. Nothing else here would notice it: the
      // knight it pins is defended and no more valuable than the bishop.
      final facts = _factsFor(['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4'], 'Bg5');
      expect(facts, _says(['pins', 'black knight on f6', 'queen on d8']));
    });

    test('a finished game gets no talk of what could be taken next', () {
      // On a mating move the mated king "attacks" the piece delivering it,
      // which read as "the queen can be taken by the king" under a checkmate.
      final facts = _factsFor(['e4', 'e5', 'Qh5', 'Nc6', 'Bc4', 'Nf6'], 'Qxf7');
      expect(facts, contains('It is checkmate.'));
      expect(facts, isNot(_says(['can be taken'])));
      expect(facts, isNot(_says(['nothing defending'])));
    });

    test('a discovered attack says which piece was uncovered', () {
      // Bishop a1, own knight d4 in the way, black rook h8 on the diagonal.
      final position = Chess.fromSetup(
        Setup.parseFen('7r/8/8/8/3N4/8/8/B3K2k w - - 0 1'),
      );
      final facts = moveFacts(
        before: position,
        move: position.parseSan('Nf5')!,
        san: 'Nf5',
      );
      expect(facts, _says(['uncovers', 'bishop on a1', 'black rook on h8']));
    });

    test('castling is never reported as uncovering its own rook', () {
      // After O-O the rook stands on f1, a square it was never on before, so
      // its new lines came out as "Moving off e1 uncovers the rook on f1".
      // The attack was real; the cause was not.
      final facts = _factsFor(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5'], 'O-O');
      expect(facts, isNot(_says(['uncovers'])));
    });

    test('a reply that castles takes nothing', () {
      // Castling is the king moving onto its own rook, which read as
      // "Black answers O-O, taking the black rook on h8".
      final facts = _factsFor(
        ['e4', 'e5', 'Nf3', 'Nf6', 'Bc4', 'Bc5'],
        'd3',
        replyUci: 'e8h8',
      );
      expect(facts, contains('Black answers O-O.'));
      expect(facts, isNot(_says(['taking'])));
    });

    test('a piece that moved is not a piece that was uncovered', () {
      final facts = _factsFor(['d4', 'd5', 'Nc3', 'Nc6'], 'Bf4');
      for (final fact in facts) {
        expect(fact, isNot(contains('uncovers the bishop on f4')));
      }
    });
  });

  group('what comes back', () {
    test('the reply is named, and so is what it takes', () {
      // The Fried Liver: Nxf7 wins a pawn, Kxf7 wins the knight.
      final facts = _factsFor(
        ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'Ng5', 'd5', 'exd5', 'Nxd5'],
        'Nxf7',
        replyUci: 'e8f7',
      );
      expect(facts, _says(['Kxf7', 'taking', 'white knight', 'f7']));
      // And the deal in pieces, never in centipawns: a knight for a pawn.
      expect(facts, _says(['gives up', 'knight', 'pawn']));
    });

    test('a reply taking en passant names the pawn it took', () {
      final facts = _factsFor(['e4', 'a6', 'e5'], 'd5', replyUci: 'e5d6');
      expect(facts, _says(['exd6', 'taking the black pawn on d5']));
    });

    test('an even trade is described as one, not as a loss', () {
      final facts = _factsFor(
        ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'],
        'Bxc6',
        replyUci: 'd7c6',
      );
      expect(facts, _says(['trades', 'bishop', 'knight']));
      expect(facts, isNot(_says(['gives up'])));
    });

    test('a capture that is taken back is a trade, not a piece hung', () {
      // Bxc6: the pawn on d7 takes back on c6.
      final facts = _factsFor(
        ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'],
        'Bxc6',
        replyUci: 'd7c6',
      );
      expect(facts, _says(['taken back', 'even trade']));
      expect(facts, isNot(_says(['nothing defending'])));
    });

    test('mid-exchange the count waits for the recapture', () {
      // 2.Nc3 dxe4: the pawn is taken, but Nxe4 takes it back.
      final facts = _factsFor(['e4', 'd5'], 'Nc3', replyUci: 'd5e4');
      expect(facts, _says(['White can take back on e4']));
      expect(facts, isNot(_says(['for nothing in return'])));
    });

    test('winning a pawn outright reads as winning it', () {
      final facts = _factsFor(
        ['e4', 'e5', 'Nf3', 'Ne7'],
        'Nxe5',
        replyUci: 'e7g6',
      );
      expect(facts, _says(['wins', 'pawn']));
    });

    test('no reply given, no claim about the exchange', () {
      final facts = _factsFor(['e4', 'd5'], 'exd5');
      expect(facts, isNot(_says(['answers'])));
      expect(facts, isNot(_says(['Over those two moves'])));
    });

    test('an illegal reply is ignored rather than believed', () {
      // A PV is the engine's word, not a promise (the same rule the better
      // line follows).
      final facts = _factsFor(['e4', 'd5'], 'exd5', replyUci: 'a1a8');
      expect(facts, isNot(_says(['answers'])));
      expect(facts, isNotEmpty);
    });
  });

  test('no fact carries an evaluation number', () {
    // Material is named in pieces. "-3.00 pawns" in the prompt is what made
    // models call the best defence in a lost position a brutal blunder.
    final facts = _factsFor(
      ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nf6', 'Ng5', 'd5', 'exd5', 'Nxd5'],
      'Nxf7',
      replyUci: 'e8f7',
    );
    for (final fact in facts) {
      expect(fact, isNot(matches(RegExp(r'[+-]?\d+\.\d'))));
    }
  });
}
