import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/concepts/board_concepts.dart';
import 'package:chess_mortem/model/concepts/concept.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:chess_mortem/model/concepts/ranker.dart';
import 'package:chess_mortem/model/concepts/salience.dart';
import 'package:chess_mortem/model/concepts/salience_weights.dart';
import 'package:chess_mortem/model/move_tags.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position _fen(String fen) => Chess.fromSetup(Setup.parseFen(fen));

ConceptInput _input(
  String fen,
  String san, {
  Classification? verdict,
  PreviousMove? previous,
  List<String> betterUci = const [],
  List<String> replyUci = const [],
  MoveTags tags = MoveTags.none,
  double? winPctDrop,
  double? winPctAfter,
}) {
  final before = _fen(fen);
  return ConceptInput(
    before: before,
    played: before.parseSan(san)!,
    verdict: verdict,
    previous: previous,
    betterUci: betterUci,
    replyUci: replyUci,
    tags: tags,
    winPctDrop: winPctDrop,
    winPctAfter: winPctAfter,
  );
}

// A bishop dropped where a pawn takes it: a Blunder the reply cashes in.
final _blunder = _input(
  '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1',
  'Bg5',
  verdict: Classification.blunder,
  betterUci: ['c1d2'],
  replyUci: ['h6g5'],
  tags: const MoveTags(allowed: LineReading(won: [Role.bishop], pays: true)),
  winPctDrop: 30,
);

// g4 leaves the knight on h4 en prise, but taking it gets mated on h7; the
// engine's reply is the skewer Bb5.
final _poisoned = _input(
  'r4rk1/pp1bnpp1/1q2p1np/3pP3/3P1P1N/P1BQ2P1/1PB4P/R4RK1 w - - 4 18',
  'g4',
  verdict: Classification.blunder,
  betterUci: ['a2a4'],
  replyUci: ['d7b5', 'd3g3', 'b5f1', 'a1f1', 'g6h4', 'g3h4', 'f7f6'],
  tags: const MoveTags(
    allowed: LineReading(
      motifs: {Motif.skewer},
      won: [Role.rook],
      gave: [Role.bishop],
      pays: true,
    ),
  ),
  winPctDrop: 21.5,
);

// Taking back on d5 after exd5: a Best move.
final _recapture = _input(
  'rnbqkbnr/pp1p1ppp/8/2pp4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
  'exd5',
  verdict: Classification.best,
  previous: (to: Square.d5, captured: true),
  replyUci: ['g8f6'],
);

void main() {
  group('frameOrder', () {
    test('a good move is read by what it does', () {
      expect(
        frameOrder(_recapture, detectConcepts(_recapture)).first,
        Frame.does,
      );
    });

    test('a punished slip by what it allows, else by what was better', () {
      expect(
        frameOrder(_blunder, detectConcepts(_blunder)).first,
        Frame.allows,
      );
      final quiet = _input(
        '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1',
        'Bb2',
        verdict: Classification.mistake,
        betterUci: ['c1d2'],
        replyUci: ['e8d7'],
      );
      expect(frameOrder(quiet, detectConcepts(quiet)).first, Frame.better);
    });
  });

  for (final (name, choose) in [
    ('table', (ConceptInput i) => chooseByTable(i, detectConcepts(i))),
    (
      'ranker',
      (ConceptInput i) => chooseRanked(i, detectConcepts(i), salienceWeights),
    ),
  ]) {
    group(name, () {
      test('names the dropped bishop as allowed', () {
        final pick = choose(_blunder);
        expect(pick.frame, Frame.allows);
        expect(pick.kind, ConceptKind.hangingPiece);
      });

      test('a piece the reply leaves alone is not called hanging', () {
        // g4 takes the pawn's guard off the knight on h4, but …Nxh4?? is
        // met by Qh7#: the engine skewers instead and takes the knight later.
        final pick = choose(_poisoned);
        expect(pick.kind, ConceptKind.skewer);
        expect(pick.frame, Frame.allows);
      });

      test('names a recapture as one', () {
        final pick = choose(_recapture);
        expect(pick.frame, Frame.does);
        expect(pick.kind, ConceptKind.recapture);
      });

      test('only ever picks a detected candidate, or a generic line', () {
        for (final input in [_blunder, _recapture]) {
          final found = detectConcepts(input);
          final pick = choose(input);
          expect(
            pick.kind == ConceptKind.genericQuality ||
                pick.kind == ConceptKind.missedWin ||
                found.any((c) => c.kind == pick.kind && c.frame == pick.frame),
            isTrue,
          );
        }
      });
    });
  }

  test('a Miss names the missed win, with the idea as its detail', () {
    final miss = _input(
      'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
      'Kd2',
      verdict: Classification.miss,
      betterUci: ['b5c7', 'e8d7', 'c7a8'],
      replyUci: ['e8d7'],
      tags: const MoveTags(
        missed: LineReading(motifs: {Motif.fork}, won: [Role.rook], pays: true),
      ),
    );
    final pick = chooseByTable(miss, detectConcepts(miss));
    expect(pick.kind, ConceptKind.missedWin);
    expect(pick.evidence, contains('fork'));
  });

  test('the fitted weights are in use', () {
    expect(salienceWeights, isNotEmpty);
    expect(chooseConcept(_recapture).kind, ConceptKind.recapture);
  });

  group('"for free" is free', () {
    test('not when the answer takes as much back elsewhere', () {
      // 5...Nxd5 takes the queen, but 6.Bxd8 takes Black's straight back.
      final input = _input(
        'r1bqkb1r/pppp1ppp/2n2n2/3Q2B1/4P3/8/PPP2PPP/RN2KBNR b KQkq - 4 5',
        'Be7',
        verdict: Classification.miss,
        betterUci: ['f6d5', 'g5d8', 'd5b4'],
        replyUci: ['g5f6'],
      );
      final found = detectConcepts(input);
      final taking = found.where(
        (c) =>
            (c.kind == ConceptKind.captureFree ||
                c.kind == ConceptKind.winMaterial) &&
            c.frame == Frame.better &&
            c.object == Square.d5,
      );
      expect(taking, isNotEmpty); // the square alone says it wins …
      for (final c in taking) {
        expect(passesLineTests(input, c, found), isFalse); // … not the line
      }
    });

    test('not when the square is taken back for part of it', () {
      // Bxd5 exd5 Qxd5: a knight and a pawn for the bishop, not a free knight.
      final found = detectConcepts(
        _input(
          '2r2rk1/pp1b1ppp/1q2p3/n2nP3/8/1P3B1P/PB3PP1/RN1QR1K1 w - - 1 17',
          'Bxd5',
          replyUci: ['e6d5'],
        ),
      );
      expect(found.where((c) => c.kind == ConceptKind.captureFree), isEmpty);
      expect(
        found.where(
          (c) => c.kind == ConceptKind.winMaterial && c.frame == Frame.does,
        ),
        isNotEmpty,
      );
    });
  });

  group('the engine line', () {
    const fen = '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1';

    test('touches a piece it moves, takes or attacks', () {
      final start = _fen(fen);
      expect(lineTouches(start, ['c1g5'], Square.h6), isTrue); // attacks
      expect(lineTouches(start, ['c1b2'], Square.h6), isFalse);
      expect(lineTouches(start, ['c1b2', 'h6h5'], Square.h6), isTrue); // moves
    });

    test('takes a piece only if the opponent captures it where it stands', () {
      final after = _fen('4k3/8/7p/6B1/8/8/8/4K3 b - - 1 1');
      expect(lineTakes(after, ['h6g5'], Square.g5), isTrue);
      expect(lineTakes(after, ['e8d7'], Square.g5), isFalse);
    });
  });

  group('companions', () {
    // 1.e4 e5 2.Nf3 d6: Bb5+ develops, checks and clears the way to castle.
    const bb5 =
        'rnbqkbnr/ppp2ppp/3p4/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3';
    // Ke8 walks into Nc7+, forking king and rook.
    const fork = 'r2k4/8/8/1N6/8/8/8/4K3 b - - 0 1';

    Companions companions(ConceptInput input, [Concept? primary]) {
      final found = detectConcepts(input);
      return companionsFor(
        input,
        primary ?? chooseConcept(input, found),
        found,
      );
    }

    test('a check by the moved piece, and the idea development pairs with', () {
      final input = _input(
        bb5,
        'Bb5+',
        verdict: Classification.good,
        betterUci: ['d2d4'],
        replyUci: ['c7c6'],
      );
      final extra = companions(input);
      expect(extra.withCheck, isTrue);
      expect(
        {chooseConcept(input).kind, extra.also?.kind},
        {ConceptKind.developPiece, ConceptKind.enableCastling},
      );
    });

    test('a discovered check is not "with check"', () {
      final input = _input('4k3/8/8/8/4N3/8/8/4RK2 w - - 0 1', 'Nc5');
      final extra = companions(
        input,
        Concept(
          ConceptKind.activeSquare,
          Frame.does,
          object: Square.c5,
          evidence: 'the knight reaches 8 squares',
        ),
      );
      expect(extra.withCheck, isFalse);
    });

    test('the reply\'s check, only for what the reply itself does', () {
      final input = _input(
        fork,
        'Ke8',
        verdict: Classification.blunder,
        betterUci: ['d8d7'],
        replyUci: ['b5c7', 'e8d7', 'c7a8'],
      );
      final found = detectConcepts(input);
      final forks = found.firstWhere(
        (c) => c.kind == ConceptKind.fork && c.frame == Frame.allows,
      );
      expect(companionsFor(input, forks, found).withCheck, isTrue);
      final read = Concept(
        ConceptKind.winMaterial,
        Frame.allows,
        evidence: 'the line: wins a rook',
      );
      expect(companionsFor(input, read, found), noCompanions);
    });

    test('the better move\'s check', () {
      final input = _input(
        bb5,
        'h3',
        verdict: Classification.mistake,
        betterUci: ['f1b5', 'c7c6'],
        replyUci: ['g8f6'],
      );
      final pick = chooseConcept(input);
      expect(pick.frame, Frame.better);
      expect(companions(input, pick).withCheck, isTrue);
    });

    test('a rook is developed; it does not fight for the centre', () {
      final input = _input('4k3/8/8/8/8/8/8/R3K3 w - - 0 1', 'Rd1');
      final found = detectConcepts(input);
      final develops = found.firstWhere(
        (c) => c.kind == ConceptKind.developPiece && c.frame == Frame.does,
      );
      expect(found.any((c) => c.kind == ConceptKind.centralControl), isTrue);
      expect(companionsFor(input, develops, found).also, isNull);
    });

    test('a line with a sentence of its own takes nothing', () {
      final input = _input(
        bb5,
        'Bb5+',
        verdict: Classification.good,
        replyUci: ['c7c6'],
      );
      final extra = companions(
        input,
        Concept(
          ConceptKind.genericQuality,
          Frame.does,
          evidence: 'the verdict alone',
        ),
      );
      expect(extra.withCheck, isFalse);
      expect(extra.also, isNull);
    });

    test('what the reply allows is never paired', () {
      final input = _input(fork, 'Ke8', replyUci: ['b5c7', 'e8d7', 'c7a8']);
      final develops = Concept(
        ConceptKind.developPiece,
        Frame.allows,
        object: Square.c7,
        evidence: 'the reply: the knight leaves b5',
      );
      final centre = Concept(
        ConceptKind.centralControl,
        Frame.allows,
        object: Square.c7,
        evidence: 'the reply: now controls d5',
      );
      expect(companionsFor(input, develops, [develops, centre]).also, isNull);
    });
  });

  group('nothing is free that the reply wins back', () {
    // Qxd3 takes a knight nothing recaptures on d3, but Nf2+ forks the
    // king and the queen: Rxf2 Bxd3.
    const fen = '8/6k1/6b1/8/4n3/3n4/3Q4/5R1K w - - 0 1';
    bool free(List<String> reply) {
      final input = _input(
        fen,
        'Qxd3',
        verdict: Classification.best,
        replyUci: reply,
      );
      final found = detectConcepts(input);
      return found.any(
        (c) =>
            c.kind == ConceptKind.captureFree &&
            c.frame == Frame.does &&
            passesLineTests(input, c, found),
      );
    }

    test('a fork that takes the queen back', () {
      expect(free(['e4f2', 'f1f2', 'g6d3']), isFalse);
    });

    test('a quiet reply leaves it free', () {
      expect(free(['g7f7']), isTrue);
    });

    test('nor what a sound sacrifice just left', () {
      final before = _fen(fen);
      final input = ConceptInput(
        before: before,
        played: before.parseSan('Qxd3')!,
        verdict: Classification.best,
        replyUci: const ['g7f7'],
        opponentBrilliant: true,
      );
      final found = detectConcepts(input);
      expect(
        found.where(
          (c) =>
              c.kind == ConceptKind.captureFree &&
              passesLineTests(input, c, found),
        ),
        isEmpty,
      );
    });
  });

  test('the better move is not praised for taking what the move took', () {
    // Bxe7 and Nxe7 both take the rook.
    final input = _input(
      '5bk1/4R3/8/3n4/8/8/8/6K1 b - - 0 1',
      'Bxe7',
      verdict: Classification.inaccuracy,
      betterUci: ['d5e7'],
      replyUci: ['g1f2'],
    );
    final found = detectConcepts(input);
    final same = found.where(
      (c) =>
          c.frame == Frame.better &&
          c.object == Square.e7 &&
          {
            ConceptKind.capture,
            ConceptKind.captureFree,
            ConceptKind.winMaterial,
          }.contains(c.kind),
    );
    expect(same, isNotEmpty);
    expect(same.where((c) => passesLineTests(input, c, found)), isEmpty);
  });

  group('an outpost', () {
    const fen = '6k1/8/1n6/8/4P3/2N5/8/6K1 w - - 0 1';
    bool outpost(List<String> reply) {
      final input = _input(
        fen,
        'Nd5',
        verdict: Classification.best,
        replyUci: reply,
      );
      final found = detectConcepts(input);
      return found.any(
        (c) =>
            c.kind == ConceptKind.outpost &&
            c.frame == Frame.does &&
            passesLineTests(input, c, found),
      );
    }

    test('holds where the knight stays', () {
      expect(outpost(['g8f7']), isTrue);
    });

    test('is not one where the reply takes the knight at once', () {
      expect(outpost(['b6d5']), isFalse);
    });
  });

  test('a mistake is read by what it allows or what was better', () {
    final input = _input(
      'rnbqkbnr/pp1p1ppp/8/2pp4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
      'exd5',
      verdict: Classification.mistake,
      previous: (to: Square.d5, captured: true),
      betterUci: ['g1f3'],
      replyUci: ['g8f6'],
      winPctDrop: 12,
    );
    expect(chooseConcept(input).frame, isNot(Frame.does));
  });

  test('an inaccuracy is not praised for taking back', () {
    final input = _input(
      'rnbqkbnr/pp1p1ppp/8/2pp4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
      'exd5',
      verdict: Classification.inaccuracy,
      previous: (to: Square.d5, captured: true),
      betterUci: ['g1f3'],
      replyUci: ['g8f6'],
      winPctDrop: 6,
    );
    expect(chooseConcept(input).frame, isNot(Frame.does));
  });

  group('an offer', () {
    // Rd4 leaves the rook where the pawn on c5 can take it.
    const fen = '4k3/8/8/2p5/8/8/8/3RK3 w - - 0 1';
    Concept pick(Classification verdict, {double chances = 55}) =>
        chooseConcept(
          _input(
            fen,
            'Rd4',
            verdict: verdict,
            replyUci: ['e8e7'],
            winPctAfter: chances,
          ),
        );

    test('is said on the engine\'s own move', () {
      final c = pick(Classification.best);
      expect(c.kind, ConceptKind.sacrifice);
      expect(c.object, Square.d4);
    });

    test('is not said in a lost position', () {
      expect(
        pick(Classification.best, chances: 20).kind,
        isNot(ConceptKind.sacrifice),
      );
    });

    test('is not said on a move the engine did not play', () {
      expect(pick(Classification.good).kind, isNot(ConceptKind.sacrifice));
    });
  });

  test('a mate is said over the piece that escaped to give it', () {
    // The rook on a1 is attacked by the bishop; Ra8 mates.
    final input = _input(
      '6k1/5ppp/8/8/8/2b5/8/R5K1 w - - 0 1',
      'Ra8#',
      verdict: Classification.best,
    );
    expect(chooseConcept(input).kind, ConceptKind.checkmate);
  });

  test('a discovered check is said over the knight escaping to give it', () {
    // Ne1 is attacked by the king; Nd3+ uncovers the queen on d1.
    final input = _input(
      '8/5kpp/1N3p2/Q1p5/P7/6P1/1P3P1P/3qnK2 b - - 4 43',
      'Nd3+',
      verdict: Classification.best,
      replyUci: ['f1g2', 'd1e2', 'h2h3', 'e2f2'],
    );
    expect(chooseConcept(input).kind, ConceptKind.discoveredCheck);
  });

  test('a rook taken and won straight back is a trade, not an offer', () {
    // Rg1+ Rxg1 Kxh7.
    final input = _input(
      '6k1/1pp4R/4r1n1/p5r1/3B1p2/PP2P3/5P2/2K4R b - - 0 30',
      'Rg1+',
      verdict: Classification.best,
      replyUci: ['h1g1', 'g8h7', 'c1d2', 'f4e3', 'f2e3'],
      winPctAfter: 50,
    );
    expect(chooseConcept(input).kind, isNot(ConceptKind.sacrifice));
  });

  test('a slip into a mate is read by the mate', () {
    // Ra7 leaves the back rank to Re1#.
    final before = _fen('4r1k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1');
    final input = ConceptInput(
      before: before,
      played: before.parseSan('Ra7')!,
      verdict: Classification.blunder,
      betterUci: const ['g2g3'],
      replyUci: const ['e8e1'],
      mateAfter: -1,
      winPctDrop: 50,
      tags: const MoveTags(
        allowed: LineReading(motifs: {Motif.mate}, pays: true),
      ),
    );
    final pick = chooseConcept(input);
    expect(pick.kind, ConceptKind.checkmate);
    expect(pick.frame, Frame.allows);
  });

  group('a better move is not praised for what the played move did too', () {
    List<Concept> savers(ConceptInput input) {
      final found = detectConcepts(input);
      return [
        for (final c in found)
          if (c.frame == Frame.better &&
              (c.kind == ConceptKind.escapeAttack ||
                  c.kind == ConceptKind.defendThreat) &&
              passesLineTests(input, c, found))
            c,
      ];
    }

    test('the same piece moved to safety', () {
      // Qe6 and Qh5 both take the queen away from Bd3.
      final input = _input(
        'rnb1k1nr/ppp2pp1/1b4qp/4P3/8/3B1N2/PP3PPP/RNBQ1RK1 b kq - 2 10',
        'Qe6',
        verdict: Classification.inaccuracy,
        betterUci: ['g6h5', 'b1c3', 'b8c6'],
        replyUci: ['b1c3', 'g8e7'],
      );
      expect(savers(input), isEmpty);
    });

    test('the attacker taken', () {
      // exd4 takes the pawn that hit the bishop on c5; Bb6 only moves it.
      final input = _input(
        'rnb1k1nr/ppp2pp1/3p1q1p/2b1p3/2BPP3/2P2N2/PP3PPP/RNBQ1RK1 b kq - 0 6',
        'exd4',
        verdict: Classification.inaccuracy,
        betterUci: ['c5b6', 'a2a4', 'a7a5'],
        replyUci: ['c3d4', 'c5b6'],
      );
      expect(savers(input), isEmpty);
    });
  });

  test('a queen that can be shielded is not called trapped', () {
    // Bg4 hits the queen on d1, which has no square, but Be2 blocks.
    final input = _input(
      'r2qk2r/ppp2ppp/2nbbn2/1B1p2N1/P6P/4P3/1PPP1PP1/RNBQK2R b KQkq - 4 8',
      'Bg4',
      verdict: Classification.good,
      betterUci: ['e8g8'],
      replyUci: ['b5e2', 'g4e2', 'd1e2'],
    );
    expect(
      chooseConcept(input).kind,
      isNot(anyOf(ConceptKind.trappedPiece, ConceptKind.attackTrappedPiece)),
    );
  });
}
