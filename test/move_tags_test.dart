import 'package:chess_mortem/model/move_tags.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position _fen(String fen) => Chess.fromSetup(Setup.parseFen(fen));

LineReading _read(String fen, List<String> pv) =>
    readLine(start: _fen(fen), pvUci: pv);

void main() {
  group('readLine', () {
    test('taking an undefended piece is a hanging piece', () {
      final reading = _read('4k3/8/1b6/8/3N4/8/8/4K3 b - - 0 1', ['b6d4']);
      expect(reading.motifs, {Motif.hangingPiece});
      expect(reading.hung, Role.knight);
      expect(reading.won, [Role.knight]);
    });

    test('a knight check that wins the rook is a fork', () {
      final reading = _read('r3k3/8/8/3N4/8/8/8/4K3 w - - 0 1', [
        'd5c7',
        'e8d8',
        'c7a8',
      ]);
      expect(reading.motifs, contains(Motif.fork));
      expect(reading.won, [Role.rook]);
    });

    test('a rook mate behind the pawns is a back-rank mate', () {
      final reading = _read('6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1', ['a1a8']);
      expect(reading.motifs, {Motif.mate, Motif.backRankMate});
      expect(reading.mates, isTrue);
    });

    test('a pinned rook attacked by the pinning bishop is a pin', () {
      final reading = _read('4k3/3r3p/8/8/8/8/8/4KB2 w - - 0 1', [
        'f1b5',
        'h7h6',
        'b5d7',
        'e8d7',
      ]);
      expect(reading.motifs, contains(Motif.pin));
      expect(reading.won, [Role.rook]);
      expect(reading.gave, [Role.bishop]);
    });

    test('a check that wins the queen behind the king is a skewer', () {
      final reading = _read('4q3/8/8/4k3/8/8/8/R5K1 w - - 0 1', [
        'a1e1',
        'e5d5',
        'e1e8',
      ]);
      expect(reading.motifs, contains(Motif.skewer));
      expect(reading.won, [Role.queen]);
    });

    test('a knight capture uncovering a rook check is a discovered attack', () {
      // Only the rook checks: a knight that checks too is not counted, as in
      // the tagger.
      final reading = _read('8/4k3/3q4/8/4N3/8/8/4R1K1 w - - 0 1', [
        'e4d6',
        'e7d6',
      ]);
      expect(reading.motifs, contains(Motif.discoveredAttack));
      expect(reading.won, [Role.queen]);
      expect(reading.gave, [Role.knight]);
    });

    test('a bishop with no safe square, then taken, is a trapped piece', () {
      final reading = _read('r3k3/Bpp5/8/8/8/8/8/6K1 b - - 0 1', [
        'b7b6',
        'g1h1',
        'a8a7',
      ]);
      expect(reading.motifs, contains(Motif.trappedPiece));
      expect(reading.won, [Role.bishop]);
    });

    test('a line that wins nothing names no tactic', () {
      final reading = _read(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        ['e2e4', 'e7e5', 'g1f3', 'b8c6'],
      );
      expect(reading.isEmpty, isTrue);
      expect(describeLine(reading), isNull);
    });

    test('material still being traded is not counted as won', () {
      // Nxd4 is answered by exd4 next: the line stops mid-exchange.
      final reading = _read('4k3/8/8/4p3/3N4/8/8/4K2n b - - 0 1', ['h1f2']);
      expect(reading.won, isEmpty);
    });

    test('a bad UCI move ends the line without throwing', () {
      final reading = _read('4k3/8/1b6/8/3N4/8/8/4K3 b - - 0 1', ['zz99']);
      expect(reading, same(LineReading.none));
    });
  });

  group('tagMove', () {
    // White's king steps away from the knight it was guarding.
    final before = _fen('4k3/8/1b6/8/3N4/4K3/8/8 w - - 0 1');
    final played = Move.parse('e3e2')!;

    test('allowed is read from the opponent, after the move', () {
      final tags = tagMove(
        before: before,
        played: played,
        refutationUci: ['b6d4'],
        betterUci: ['e3e4'],
      );
      expect(tags.allowed.hung, Role.knight);
    });

    test('missed is empty when the move was the engine\'s', () {
      final tags = tagMove(
        before: before,
        played: played,
        refutationUci: ['b6d4'],
        betterUci: ['e3e2', 'b6d4'],
      );
      expect(tags.missed, same(LineReading.none));
    });

    test('a capture that is recaptured lost nothing', () {
      // Bxd7+ Kxd7: a bishop for a bishop, not "lost the bishop".
      final tags = tagMove(
        before: _fen('4k3/3b4/8/1B6/8/8/8/4K3 w - - 0 1'),
        played: Move.parse('b5d7')!,
        refutationUci: const ['e8d7'],
      );
      expect(tags.allowed.won, isEmpty);
      expect(tags.allowed.isEmpty, isTrue);
    });

    test('missed is measured against the played line, not the start', () {
      // bxc6 and dxc6 both take the knight: nothing was missed.
      final tags = tagMove(
        before: _fen('4k3/8/2n5/1P1P4/8/8/8/4K3 w - - 0 1'),
        played: Move.parse('b5c6')!,
        refutationUci: const ['e8e7'],
        betterUci: const ['d5c6', 'e8e7'],
      );
      expect(tags.missed.won, isEmpty);
      expect(tags.missed.isEmpty, isTrue);
    });

    test('a loss the engine does not back is not claimed', () {
      // Bxd4 wins the knight — but if the engine says the move cost almost
      // nothing, the count comes from a line nobody is forced into.
      final before = _fen('4k3/8/1b6/8/3N4/4K3/8/8 w - - 0 1');
      MoveTags tagsWith(double drop) => tagMove(
        before: before,
        played: Move.parse('e3e2')!,
        refutationUci: const ['b6d4'],
        evalDrop: drop,
      );
      expect(tagsWith(0.1).allowed.isEmpty, isTrue);
      expect(tagsWith(3).allowed.won, [Role.knight]);
    });

    test('with the engine behind it, a single pawn is worth naming', () {
      // Qxb7 is not defended: the pawn falls, and the engine agrees.
      final tags = tagMove(
        before: _fen('4k2q/1p6/8/8/8/8/8/1Q2K3 b - - 0 1'),
        played: Move.parse('h8h2')!,
        refutationUci: const ['b1b7'],
        evalDrop: 1.2,
      );
      expect(tags.allowed.winsMaterial, isTrue);
      expect(tacticSummaryLine(tags), 'Lost a pawn.');
    });

    test('missed needs a real gain, not just the loss avoided', () {
      // Both lines start level; the better one only avoids losing a pawn.
      final tags = tagMove(
        before: _fen('4k2q/1p6/8/8/8/8/8/1Q2K3 b - - 0 1'),
        played: Move.parse('h8h2')!,
        refutationUci: const ['b1b7'],
        betterUci: const ['h8b8', 'e1d2'],
        evalDrop: 1.2,
      );
      expect(tags.missed.isEmpty, isTrue);
    });

    test('a piece the mover later gives away is not the move\'s loss', () {
      // After Ke2, the engine's line has White put the knight on c3 where
      // the bishop takes it: White's choice then, not Ke2's cost.
      final tags = tagMove(
        before: _fen('4k3/8/5b2/8/8/8/8/1N2K3 w - - 0 1'),
        played: Move.parse('e1e2')!,
        refutationUci: const ['e8e7', 'b1c3', 'f6c3'],
        evalDrop: 3,
      );
      expect(tags.allowed.isEmpty, isTrue);
    });

    test('a piece taken and simply retaken was not given away', () {
      // White's d4 is taken and retaken: a trade, so the line counts past
      // it.
      final tags = tagMove(
        before: _fen('4k3/8/8/4p3/8/2PP4/8/4K3 w - - 0 1'),
        played: Move.parse('e1e2')!,
        refutationUci: const ['e8e7', 'd3d4', 'e5d4', 'c3d4'],
        evalDrop: 1,
      );
      expect(tags.ledger.map((e) => '$e'), ['2...exd4 3.cxd4: level']);
    });

    test('the ledger walks the exchanges with numbered moves', () {
      // 15...Bxe5 16.dxe5: a bishop for a knight.
      final tags = tagMove(
        before: _fen('4k3/8/3b4/4N3/3P4/8/8/4K3 b - - 0 15'),
        played: Move.parse('d6e5')!,
        refutationUci: const ['d4e5'],
      );
      expect(tags.ledger.map((e) => '$e'), ['15...Bxe5 16.dxe5: level']);
      expect(tags.allowed.isEmpty, isTrue);
    });

    test('startsEvenTrade', () {
      final before = _fen('4k3/8/3b4/4N3/3P4/8/8/4K3 b - - 0 15');
      expect(startsEvenTrade(before, Move.parse('d6e5')!), isTrue);
      expect(startsEvenTrade(before, Move.parse('d6c5')!), isFalse);
    });

    test('an illegal move tags nothing', () {
      final tags = tagMove(
        before: before,
        played: Move.parse('a1a2')!,
        refutationUci: const [],
      );
      expect(tags, same(MoveTags.none));
    });
  });

  group('describeLine', () {
    test('a hanging piece is named, not just counted', () {
      expect(
        describeLine(_read('4k3/8/1b6/8/3N4/8/8/4K3 b - - 0 1', ['b6d4'])),
        'takes the knight that was left hanging',
      );
    });

    test('an exchange names both sides and the tactic', () {
      final line = describeLine(
        _read('4k3/3r3p/8/8/8/8/8/4KB2 w - - 0 1', [
          'f1b5',
          'h7h6',
          'b5d7',
          'e8d7',
        ]),
      );
      expect(line, 'wins the rook for a bishop, with a pin');
    });

    test('a back-rank mate is said as one', () {
      expect(
        describeLine(_read('6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1', ['a1a8'])),
        'mates on the back rank',
      );
    });
  });

  group('materialStory', () {
    test('says when the material changes, not just that it did', () {
      expect(
        materialStory(const [
          LedgerEntry('16.dxe5', 'level'),
          LedgerEntry('17.Bxd5 exd5', 'level'),
          LedgerEntry('19.Nxd5', 'White is up a pawn'),
        ]),
        'Material stays level through 17.Bxd5 exd5; '
        'after 19.Nxd5, White is up a pawn.',
      );
    });

    test('a line of even trades says so', () {
      expect(
        materialStory(const [LedgerEntry('16.dxe5', 'level')]),
        'Material stays level.',
      );
    });

    test('material won back is told as well', () {
      expect(
        materialStory(const [
          LedgerEntry('9.Qxg4', 'White is up a bishop'),
          LedgerEntry('10...Qxf6', 'level'),
        ]),
        'After 9.Qxg4, White is up a bishop. '
        'After 10...Qxf6, material is level again.',
      );
    });
  });

  test('describeRoles', () {
    expect(describeRoles([Role.queen]), 'the queen');
    expect(describeRoles([Role.rook, Role.pawn]), 'the rook and a pawn');
    expect(describeRoles([Role.pawn, Role.pawn]), 'two pawns');
    expect(
      describeRoles([Role.queen, Role.pawn, Role.pawn]),
      'the queen and two pawns',
    );
    expect(describeRoles([Role.rook], definite: false), 'a rook');
  });
}
