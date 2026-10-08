import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

EngineEval _cp(int cp, {String? best}) =>
    EngineEval(cp: cp, bestMoveUci: best ?? 'e2e4', depth: 15);

/// The same eval from a search that ranked more than one move — what Brilliant
/// and Great both need, since each is a question about the move NOT played.
///
/// [runnerUp] defaults to a score that is not winning, so the "you were winning
/// anyway" guard stays out of the way of the test that asked for this.
EngineEval _ranked(int cp, {required String best, int runnerUp = 100}) =>
    EngineEval(
      cp: cp,
      bestMoveUci: best,
      depth: 20,
      alternatives: [
        EngineLine(cp: runnerUp, pvUci: const ['d1f3']),
      ],
    );

Position _positionAfter(List<String> sans) {
  Position position = Chess.initial;
  for (final san in sans) {
    position = position.play(position.parseSan(san)!);
  }
  return position;
}

void main() {
  group('EngineEval.winPctWhite', () {
    test('equal position is 50%', () {
      expect(_cp(0).winPctWhite, closeTo(50, 0.001));
    });

    test('is symmetric around zero', () {
      final up = _cp(150).winPctWhite;
      final down = _cp(-150).winPctWhite;
      expect(up + down, closeTo(100, 0.001));
      expect(up, greaterThan(50));
    });

    test('a score past the ceiling stops moving the needle', () {
      // lichess clamps to +/-1000 cp before the sigmoid, so 10 pawns and 40
      // pawns are the same winning chance. Without that clamp a hopeless
      // position reads 0 % and swamps every threshold built on this number.
      expect(_cp(4000).winPctWhite, closeTo(_cp(1000).winPctWhite, 0.001));
      expect(_cp(1000).winPctWhite, closeTo(97.55, 0.01));
    });

    test('mate for black is the ceiling, not zero', () {
      const eval = EngineEval(mateIn: -3, bestMoveUci: 'a1a2', depth: 15);
      expect(eval.cpCeiled, -EngineEval.cpCeiling);
      expect(eval.winPctWhite, closeTo(2.45, 0.01));
      // The display number is unchanged: the bar still reads a mate as -99.
      expect(eval.pawns, -99.0);
    });
  });

  group('classify', () {
    test('playing the engine move is Best regardless of eval', () {
      final result = classify(
        before: _cp(100, best: 'g1f3'),
        after: _cp(20),
        mover: Side.white,
        playedUci: 'g1f3',
      );
      expect(result, Classification.best);
    });

    test('tiny win% drop is Excellent', () {
      expect(
        classify(
          before: _cp(30, best: 'g1f3'),
          after: _cp(20),
          mover: Side.white,
          playedUci: 'b1c3',
        ),
        Classification.excellent,
      );
    });

    test('large drop for white is a Blunder', () {
      expect(
        classify(
          before: _cp(50, best: 'g1f3'),
          after: _cp(-400),
          mover: Side.white,
          playedUci: 'f2f3',
        ),
        Classification.blunder,
      );
    });

    test('black-mover perspective: white eval RISING after black\'s move '
        'is a drop for black', () {
      expect(
        classify(
          before: _cp(0, best: 'e7e5'),
          after: _cp(450), // white got much better -> black blundered
          mover: Side.black,
          playedUci: 'g8h6',
        ),
        Classification.blunder,
      );
    });

    test('black-mover perspective: white eval falling is fine for black', () {
      expect(
        classify(
          before: _cp(0, best: 'e7e5'),
          after: _cp(-40),
          mover: Side.black,
          playedUci: 'c7c5',
        ),
        Classification.excellent,
      );
    });

    test('missing a mate counts as a huge drop', () {
      const mateForWhite = EngineEval(
        mateIn: 2,
        bestMoveUci: 'd1h5',
        depth: 15,
      );
      expect(
        classify(
          before: mateForWhite,
          after: _cp(0),
          mover: Side.white,
          playedUci: 'a2a3',
        ),
        Classification.blunder,
      );
    });

    test('a 16.5-point drop (-2.6 to -5.6) is a Blunder, not a Mistake', () {
      // -2.6 to -5.6 is a 16.5-point drop: over lichess's 15-point line.
      expect(
        winPctDrop(
          before: _cp(-260, best: 'e1g1'),
          after: _cp(-560),
          mover: Side.white,
        ),
        closeTo(16.46, 0.01),
      );
      expect(
        classify(
          before: _cp(-260, best: 'e1g1'),
          after: _cp(-560),
          mover: Side.white,
          playedUci: 'c4f7',
        ),
        Classification.blunder,
      );
    });

    test('the tiers sit exactly on lichess\'s boundaries', () {
      // 5 / 10 / 15 percentage points, from Advice.scala's .1 / .2 / .3 on
      // winning chances. Each pair straddles one line.
      Classification at(int before, int after) => classify(
        before: _cp(before, best: 'g1f3'),
        after: _cp(after),
        mover: Side.white,
        playedUci: 'a2a3',
      );
      expect(at(0, -50), Classification.good); //  4.6 points
      expect(at(0, -60), Classification.inaccuracy); //  5.5
      expect(at(0, -105), Classification.inaccuracy); //  9.5
      expect(at(0, -115), Classification.mistake); // 10.4
      expect(at(0, -160), Classification.mistake); // 14.3
      expect(at(0, -175), Classification.blunder); // 15.6
    });
  });

  group('classify with a mate on the board', () {
    const mateForWhite = EngineEval(mateIn: 2, bestMoveUci: 'd1h5', depth: 15);
    const mateForBlack = EngineEval(mateIn: -2, bestMoveUci: 'd8h4', depth: 15);

    test('a mate other than the engine\'s is still Best', () {
      // Two mates in one: the engine names one, the player plays the other.
      expect(
        classify(
          before: const EngineEval(mateIn: 1, bestMoveUci: 'b4a3', depth: 15),
          after: const EngineEval.checkmate(mated: Side.white, depth: 0),
          mover: Side.black,
          playedUci: 'a2c2',
        ),
        Classification.best,
      );
    });

    test('walking into a forced mate from a level position is a Blunder', () {
      expect(
        classify(
          before: _cp(0, best: 'g1f3'),
          after: mateForBlack,
          mover: Side.white,
          playedUci: 'g2g4',
        ),
        Classification.blunder,
      );
    });

    test('being mated when already lost is only an Inaccuracy', () {
      // With the ceiling the win% barely moves; a hopeless position's best
      // try is not a blunder.
      expect(
        classify(
          before: _cp(-1500, best: 'g1f3'),
          after: mateForBlack,
          mover: Side.white,
          playedUci: 'g2g4',
        ),
        Classification.inaccuracy,
      );
      expect(
        classify(
          before: _cp(-800, best: 'g1f3'),
          after: mateForBlack,
          mover: Side.white,
          playedUci: 'g2g4',
        ),
        Classification.mistake,
      );
    });

    test('throwing away a mate for a won position is an Inaccuracy', () {
      expect(
        classify(
          before: mateForWhite,
          after: _cp(1200),
          mover: Side.white,
          playedUci: 'a2a3',
        ),
        Classification.inaccuracy,
      );
    });

    test('a slower mate is still a fine move', () {
      // Mate in 2 instead of mate in 1 produces no judgement at all in
      // lichess, so it falls through to the winning-chance table.
      expect(
        classify(
          before: const EngineEval(mateIn: 1, bestMoveUci: 'd1h5', depth: 15),
          after: mateForWhite,
          mover: Side.white,
          playedUci: 'a2a3',
        ),
        Classification.excellent,
      );
    });

    test('creating a mate is never punished', () {
      expect(
        classify(
          before: _cp(300, best: 'g1f3'),
          after: mateForWhite,
          mover: Side.white,
          playedUci: 'd1h5',
        ),
        Classification.excellent,
      );
    });

    test('the mover perspective flips for Black', () {
      // Black plays and now White mates: a blunder BY BLACK.
      expect(
        classify(
          before: _cp(0, best: 'e7e5'),
          after: mateForWhite,
          mover: Side.black,
          playedUci: 'f7f6',
        ),
        Classification.blunder,
      );
      // Black plays and now Black mates: excellent.
      expect(
        classify(
          before: _cp(0, best: 'e7e5'),
          after: mateForBlack,
          mover: Side.black,
          playedUci: 'd8h4',
        ),
        Classification.excellent,
      );
    });
  });

  group('onlyMoveGap', () {
    test('is null when the search ranked a single move', () {
      // Unknown, NOT "nothing else was close" — the difference is the whole
      // reason this is nullable.
      expect(onlyMoveGap(_cp(50, best: 'e2e4'), Side.white), isNull);
      expect(isOnlyMove(_cp(50, best: 'e2e4'), Side.white), isFalse);
    });

    test(
      'measures the drop to the second choice, in the mover perspective',
      () {
        const eval = EngineEval(
          cp: 300,
          bestMoveUci: 'e2e4',
          depth: 20,
          alternatives: [
            EngineLine(cp: -300, pvUci: ['d2d4']),
          ],
        );

        final forWhite = onlyMoveGap(eval, Side.white)!;
        expect(forWhite, greaterThan(onlyMoveThreshold));
        expect(isOnlyMove(eval, Side.white), isTrue);

        // The same two lines seen from the other side: the "alternative" is
        // better for Black, so nothing is being lost by playing it.
        expect(onlyMoveGap(eval, Side.black), closeTo(-forWhite, 0.001));
        expect(isOnlyMove(eval, Side.black), isFalse);
      },
    );

    test('two moves that are both fine is not an only move', () {
      const eval = EngineEval(
        cp: 40,
        bestMoveUci: 'e2e4',
        depth: 20,
        alternatives: [
          EngineLine(cp: 30, pvUci: ['d2d4']),
        ],
      );
      expect(onlyMoveGap(eval, Side.white), lessThan(1));
      expect(isOnlyMove(eval, Side.white), isFalse);
    });
  });

  group('Brilliant', () {
    // The Fried Liver: White gives a knight for a pawn and the black king.
    final beforeSac = _positionAfter([
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
    final afterSac = beforeSac.play(beforeSac.parseSan('Nxf7')!);

    /// Kxf7, Qf3+, Ke6 — the main line, in which White stays a knight for a
    /// pawn down. The PV matters now: an accepted sacrifice is judged by what
    /// the engine's own continuation does with the material.
    const acceptedPv = ['e8f7', 'd1f3', 'f7e6'];

    Classification classifySac({
      required EngineEval before,
      required EngineEval after,
    }) => classify(
      before: before,
      after: after,
      mover: Side.white,
      playedUci: 'g5f7',
      positionBefore: beforeSac,
      positionAfter: afterSac,
    );

    test('a sacrifice that works is Brilliant, not merely Best', () {
      expect(
        classifySac(
          before: _ranked(100, best: 'g5f7'),
          // Recapturing is Black's best answer, and it is what makes this a
          // knight for a pawn rather than a free pawn.
          after: const EngineEval(
            cp: 150,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        Classification.brilliant,
      );
    });

    test('a recapture is never a sacrifice', () {
      // The Fried Liver knight takes on f7 — but as if Black had just
      // captured there, the move only takes back.
      expect(
        classify(
          before: _ranked(100, best: 'g5f7'),
          after: const EngineEval(
            cp: 150,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
          mover: Side.white,
          playedUci: 'g5f7',
          positionBefore: beforeSac,
          positionAfter: afterSac,
          previousCaptureUci: 'f8f7',
        ),
        isNot(Classification.brilliant),
      );
    });

    test('a pinned queen taking its pinner is not a sacrifice', () {
      // The rook on e8 pins the queen on e4 to the king: the queen is lost
      // either way, so Qxe8+ Kxe8 (a queen for a rook) is forced, not given.
      final before = Chess.fromSetup(
        Setup.parseFen('4rk2/p7/8/8/4Q3/8/P7/4K3 w - - 0 1'),
      );
      final after = before.play(before.parseSan('Qxe8+')!);
      expect(
        classify(
          before: _ranked(0, best: 'e4e8', runnerUp: -900),
          after: const EngineEval(
            cp: 0,
            bestMoveUci: 'f8e8',
            pvUci: ['f8e8', 'e1d2', 'e8d7'],
            depth: 20,
          ),
          mover: Side.white,
          playedUci: 'e4e8',
          positionBefore: before,
          positionAfter: after,
        ),
        isNot(Classification.brilliant),
      );
    });

    test('a piece already hanging before the move is not offered by it', () {
      // 10...Nxf2 forks White's rooks on d1 and h1; 11.Be3 hits the queen
      // and leaves them hanging exactly as before. Black's best reply takes
      // neither, and a rook the opponent declines is not one this move offered.
      final before = _positionAfter(
        'e4 e5 Nf3 d5 d3 Nf6 Nxe5 dxe4 Nc3 Bb4 Bd2 Qd4 Nc4 Ng4 Qe2 O-O '
                'O-O-O Bf5 h3 Nxf2'
            .split(' '),
      );
      final after = before.play(before.parseSan('Be3')!);
      expect(
        classify(
          before: _ranked(310, best: 'd2e3'),
          after: const EngineEval(
            cp: 310,
            bestMoveUci: 'f2d3',
            pvUci: ['f2d3', 'c2d3', 'e4d3'],
            depth: 20,
          ),
          mover: Side.white,
          playedUci: 'd2e3',
          positionBefore: before,
          positionAfter: after,
        ),
        isNot(Classification.brilliant),
      );
    });

    test('material won straight back is a tactic, not a sacrifice', () {
      // The same offer, but the engine's line collects the knight again two
      // moves later. A count that stopped at the first reply would call it a
      // sacrifice.
      expect(
        classifySac(
          before: _ranked(100, best: 'g5f7'),
          after: const EngineEval(
            cp: 150,
            bestMoveUci: 'e8f7',
            // Kxf7, Qf3+, Ke6, Qxd5+, Ke7 — and the knight is paid for.
            pvUci: ['e8f7', 'd1f3', 'f7e6', 'f3d5', 'e6e7'],
            depth: 20,
          ),
        ),
        Classification.best,
      );
    });

    test('a sacrifice the opponent declines is still a sacrifice', () {
      // Nobody has to take, and the good ones often cannot be taken. There is
      // no material swing in the line at all here, so the price is what
      // accepting WOULD have cost — which is the exchange on f7.
      expect(
        classifySac(
          before: _ranked(100, best: 'g5f7'),
          after: const EngineEval(
            cp: 150,
            bestMoveUci: 'd8e7',
            pvUci: ['d8e7', 'f7h8', 'e7e6'],
            depth: 20,
          ),
        ),
        Classification.brilliant,
      );
    });

    test('a near-best move is not promoted, however pretty', () {
      // Brilliant is a promotion of Best and nothing else: a sacrifice the
      // engine ranked second is a move it found something better than.
      expect(
        classifySac(
          before: _ranked(100, best: 'd1f3'),
          after: const EngineEval(
            cp: 99,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        Classification.excellent,
      );
    });

    test('escaping check is not brilliant', () {
      // 1.e4 e5 2.Nf3 Nc6 3.Bc4 Nf6 4.Ng5 d5 5.exd5 Nd4 6.d6 Bxd6 and now
      // ...Bb4+ has White in check. Whatever comes next was forced on him.
      final before = _positionAfter([
        'e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'd3', 'Nf6', //
        'Bg5', 'h6', 'Bh4', 'g5', 'Bg3', 'Bxf2+',
      ]);
      expect(before.isCheck, isTrue);
      final after = before.play(before.parseSan('Kxf2')!);
      expect(
        classify(
          before: _ranked(120, best: 'e1f2'),
          after: const EngineEval(
            cp: 130,
            bestMoveUci: 'f6e4',
            pvUci: ['f6e4', 'f2g1', 'e4g3'],
            depth: 20,
          ),
          mover: Side.white,
          playedUci: 'e1f2',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });

    test('a promotion is not brilliant', () {
      // The new queen is there to be taken by the rook on b1, so every
      // material test in the file says a queen was offered. Queening is its
      // own reward and needs no adjective on top.
      final before = Chess.fromSetup(
        Setup.parseFen('6k1/1P6/8/8/8/8/6K1/1r6 w - - 0 1'),
      );
      final after = before.play(before.parseSan('b8=Q')!);
      expect(
        classify(
          before: _ranked(0, best: 'b7b8q'),
          after: const EngineEval(
            cp: 50,
            bestMoveUci: 'b1b8',
            pvUci: ['b1b8', 'g2g3'],
            depth: 20,
          ),
          mover: Side.white,
          playedUci: 'b7b8q',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });

    test('a one-line search awards neither Brilliant nor Great', () {
      // No promotion path on a single-line search.
      expect(
        classifySac(
          before: _cp(100, best: 'g5f7'),
          after: const EngineEval(
            cp: 150,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        Classification.best,
        reason: 'the same sacrifice is Brilliant when a runner-up is known',
      );
    });

    test('without the boards it is the same verdict as it always was', () {
      // The optional arguments are what a caller with no position degrades
      // to: a real verdict, never a crash.
      expect(
        classify(
          before: _ranked(100, best: 'g5f7'),
          after: _cp(150),
          mover: Side.white,
          playedUci: 'g5f7',
        ),
        Classification.best,
      );
    });

    test('a sacrifice that leaves the mover worse is Great at most', () {
      // -0.6 (44.5 %) after: over Great's floor, under Brilliant's.
      // Every other move lost (-4.0), so it is still the only move.
      expect(
        classifySac(
          before: _ranked(-50, best: 'g5f7', runnerUp: -400),
          after: const EngineEval(
            cp: -60,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        Classification.great,
      );
    });

    test('a sacrifice that loses is not brilliant', () {
      expect(
        classifySac(
          before: _ranked(100, best: 'g5f7'),
          after: const EngineEval(
            cp: -400,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        isNot(Classification.brilliant),
      );
    });

    test('"winning anyway" is asked of the second-best move', () {
      // Every won game ends in simplification, and without this guard the last
      // five moves of one would all read Brilliant. The position's own score
      // cannot be the one asked, because a move this good is what PUT the
      // score there; the runner-up can.
      EngineEval runnerUp(int cp) => EngineEval(
        cp: 900,
        bestMoveUci: 'g5f7',
        depth: 20,
        alternatives: [
          EngineLine(cp: cp, pvUci: const ['d1f3']),
        ],
      );
      const after = EngineEval(
        cp: 950,
        bestMoveUci: 'e8f7',
        pvUci: acceptedPv,
        depth: 20,
      );

      // Another move was winning too: the position deserves the credit.
      expect(
        classifySac(before: runnerUp(900), after: after),
        Classification.best,
      );
      // Nothing else was: the move deserves it.
      expect(
        classifySac(before: runnerUp(100), after: after),
        Classification.brilliant,
      );
    });

    test(
      'a sacrifice that forces mate is Brilliant however good it looked',
      () {
        // The archetypal !!, and the case a guard on the POSITION silently
        // excluded: a forced mate IS the ceiling score, so the position before
        // a mating sacrifice always reads as already won. Asking the runner-up
        // instead is what rescues it — nothing ELSE was winning here.
        expect(
          classifySac(
            before: _ranked(900, best: 'g5f7'),
            after: const EngineEval(
              mateIn: 3,
              bestMoveUci: 'e8f7',
              pvUci: acceptedPv,
              depth: 20,
            ),
          ),
          Classification.brilliant,
        );
      },
    );

    test('the move that ends the game gives nothing up', () {
      // Legal's Mate: White is a whole queen down and mates with Nd5. The
      // knight looks thrown in, but a mated player takes nothing — there are
      // no legal moves left at all, which is what the legality test reads.
      // The sacrifice in a mating combination is an EARLIER move.
      final before = _positionAfter([
        'e4', 'e5', 'Nf3', 'd6', 'Bc4', 'Bg4', //
        'Nc3', 'g6', 'Nxe5', 'Bxd1', 'Bxf7+', 'Ke7',
      ]);
      final after = before.play(before.parseSan('Nd5#')!);
      expect(after.isCheckmate, isTrue);
      expect(
        classify(
          before: _ranked(200, best: 'c3d5'),
          after: const EngineEval.checkmate(mated: Side.black, depth: 20),
          mover: Side.white,
          playedUci: 'c3d5',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });

    test('executing a mate that was already forced is still technique', () {
      // Handing material back to play out a mate the position already had is
      // exactly what the "already winning" guard is for: another move mated
      // too, so this one found nothing.
      expect(
        classifySac(
          before: const EngineEval(
            mateIn: 4,
            bestMoveUci: 'g5f7',
            depth: 20,
            alternatives: [
              EngineLine(mateIn: 4, pvUci: ['d1f3']),
            ],
          ),
          after: const EngineEval(
            mateIn: 3,
            bestMoveUci: 'e8f7',
            pvUci: acceptedPv,
            depth: 20,
          ),
        ),
        Classification.best,
      );
    });

    test('a plain trade is not a sacrifice', () {
      final before = _positionAfter(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);
      final after = before.play(before.parseSan('Nd4')!);
      expect(
        classify(
          before: _cp(20, best: 'c6d4'),
          after: const EngineEval(cp: 15, bestMoveUci: 'f3d4', depth: 20),
          mover: Side.black,
          playedUci: 'c6d4',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });
  });

  group('Great', () {
    final beforeMove = _positionAfter(['e4', 'e5']);
    final afterMove = beforeMove.play(beforeMove.parseSan('Nf3')!);

    EngineEval onlyMove(String best) => EngineEval(
      cp: 30,
      bestMoveUci: best,
      depth: 20,
      alternatives: const [
        EngineLine(cp: -300, pvUci: ['d2d4']),
      ],
    );

    test('the one move that held is Great', () {
      expect(
        classify(
          before: onlyMove('g1f3'),
          after: _cp(25),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
          previousCaptureUci: 'e7e5',
        ),
        Classification.great,
      );
    });

    test('without alternatives to compare against it stays Best', () {
      // A single-line search cannot tell an only move from an obvious one, and
      // guessing is how every forced recapture would end up decorated.
      expect(
        classify(
          before: _cp(30, best: 'g1f3'),
          after: _cp(25),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
        ),
        Classification.best,
      );
    });

    test('taking back on the square just captured is not Great', () {
      final before = _positionAfter(['e4', 'd5', 'exd5']);
      final after = before.play(before.parseSan('Qxd5')!);
      expect(
        classify(
          before: EngineEval(
            cp: 30,
            bestMoveUci: 'd8d5',
            depth: 20,
            alternatives: const [
              EngineLine(cp: 400, pvUci: ['g8f6']),
            ],
          ),
          after: _cp(25),
          mover: Side.black,
          playedUci: 'd8d5',
          positionBefore: before,
          positionAfter: after,
          previousCaptureUci: 'e4d5',
        ),
        Classification.best,
      );
    });

    test('taking back en passant is a recapture too', () {
      // An en passant capture lands BEHIND the pawn it takes, so comparing
      // landing squares let this one through as Great.
      final before = _positionAfter(['e4', 'a6', 'e5', 'd5']);
      final after = before.play(before.parseSan('exd6')!);
      expect(
        classify(
          before: EngineEval(
            cp: 30,
            bestMoveUci: 'e5d6',
            depth: 20,
            alternatives: const [
              EngineLine(cp: -400, pvUci: ['g1f3']),
            ],
          ),
          after: _cp(25),
          mover: Side.white,
          playedUci: 'e5d6',
          positionBefore: before,
          positionAfter: after,
          previousCaptureUci: 'd7d5',
        ),
        Classification.best,
      );
    });

    test('a gap the runner-up survives is not an only move', () {
      // 6 points: the other move would have been an inaccuracy, not a
      // mistake.
      const before = EngineEval(
        cp: 30,
        bestMoveUci: 'g1f3',
        depth: 20,
        alternatives: [
          EngineLine(cp: -30, pvUci: ['d2d4']),
        ],
      );
      expect(onlyMoveGap(before, Side.white), inInclusiveRange(5, 10));
      expect(
        classify(
          before: before,
          after: _cp(25),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
          previousCaptureUci: 'e7e5',
        ),
        Classification.best,
      );
    });

    test('grabbing a piece that was hanging anyway is not Great', () {
      // Free material is not a find, and the engine ranking everything else
      // far behind is just the engine agreeing that it should be taken.
      final before = Chess.fromSetup(
        Setup.parseFen('4k3/8/8/4n3/3P4/8/8/4K3 w - - 0 1'),
      );
      final after = before.play(before.parseSan('dxe5')!);
      expect(
        classify(
          before: EngineEval(
            cp: 300,
            bestMoveUci: 'd4e5',
            depth: 20,
            alternatives: const [
              EngineLine(cp: -300, pvUci: ['e1e2']),
            ],
          ),
          after: _cp(320),
          mover: Side.white,
          playedUci: 'd4e5',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });

    test('the only move that holds a worse position is Great', () {
      // -0.6 (44.5 %) after, over Great's 40 % floor; anything else -4.0.
      expect(
        classify(
          before: EngineEval(
            cp: -50,
            bestMoveUci: 'g1f3',
            depth: 20,
            alternatives: const [
              EngineLine(cp: -400, pvUci: ['d2d4']),
            ],
          ),
          after: _cp(-60),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
        ),
        Classification.great,
      );
    });

    test('the only move in a lost position is not Great', () {
      // Holding on is not the same as finding something. A player who is
      // already lost cannot be praised for the least bad move.
      expect(
        classify(
          before: EngineEval(
            cp: -300,
            bestMoveUci: 'g1f3',
            depth: 20,
            alternatives: const [
              EngineLine(cp: -900, pvUci: ['d2d4']),
            ],
          ),
          after: _cp(-320),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
          previousCaptureUci: 'e7e5',
        ),
        Classification.best,
      );
    });

    test('the one move that keeps a mate in hand can be Great', () {
      // The runner-up is only +1.0: the win was there to lose.
      expect(
        classify(
          before: const EngineEval(
            mateIn: 3,
            bestMoveUci: 'g1f3',
            depth: 20,
            alternatives: [
              EngineLine(cp: 100, pvUci: ['d2d4']),
            ],
          ),
          after: _cp(500),
          mover: Side.white,
          playedUci: 'g1f3',
          positionBefore: beforeMove,
          positionAfter: afterMove,
          previousCaptureUci: 'e7e5',
        ),
        Classification.great,
      );
    });

    test('the only legal move in the position is not Great either', () {
      // Black queen beside the white king: taking it is the one legal move,
      // and finding it takes nothing.
      final before = Chess.fromSetup(
        Setup.parseFen('k7/8/8/8/8/8/6q1/7K w - - 0 1'),
      );
      final after = before.play(before.parseSan('Kxg2')!);
      expect(
        classify(
          before: EngineEval(
            cp: 0,
            bestMoveUci: 'h1g2',
            depth: 20,
            alternatives: const [
              EngineLine(mateIn: -1, pvUci: ['h1h2']),
            ],
          ),
          after: _cp(0),
          mover: Side.white,
          playedUci: 'h1g2',
          positionBefore: before,
          positionAfter: after,
        ),
        Classification.best,
      );
    });
  });

  group('Miss', () {
    // White to move after Black's reply. Scores are White's; +3.0 (75 %)
    // counts as winning.
    Classification judge({
      int? beforeOpponent = 0,
      int before = 500,
      int after = 50,
      Side mover = Side.white,
    }) {
      final flip = mover == Side.white ? 1 : -1;
      return classify(
        beforeOpponentMove: beforeOpponent == null
            ? null
            : _cp(flip * beforeOpponent),
        before: _cp(flip * before),
        after: _cp(flip * after),
        mover: mover,
        playedUci: 'a2a3',
      );
    }

    test('giving back the win the opponent just handed over is a Miss', () {
      // Level, then Black blunders (+5), then White lets it go (+0.5).
      expect(judge(), Classification.miss);
    });

    test('it is judged from Black\'s side too', () {
      expect(judge(mover: Side.black), Classification.miss);
    });

    test('landing in a lost position is still a Blunder', () {
      expect(judge(after: -500), Classification.blunder);
    });

    test('giving back most of the gift is a Miss; less is just a slip', () {
      // Level (50 %) to +2.4 (70.6 %): a 20.6-point gift. +0.6 (55.5 %)
      // gives back 15.1, over 60 % of it: a Miss. +1.6 (64.2 %) gives back
      // 6.4: most of the gift is kept, so it is only an Inaccuracy.
      expect(judge(before: 240, after: 60), Classification.miss);
      expect(judge(before: 240, after: 160), Classification.inaccuracy);
    });

    test('a slip that keeps most of the gift is not a Miss', () {
      // +5.0 (86.2 %) to +3.5 (78.4 %): 7.8 of a 36-point gift.
      expect(judge(after: 350), Classification.inaccuracy);
    });

    test('a Miss need not be winning: level positions count too', () {
      // -1.5 (36.5 %) to +0.5 (54.6 %): the opponent's mistake made it
      // level; back to -1.5 lets the whole chance go.
      expect(
        judge(beforeOpponent: -150, before: 50, after: -150),
        Classification.miss,
      );
    });

    test('a gift on top of a win, thrown away, is a Miss', () {
      // +2.6 (72.2 %) to +6.0 (90.1 %), then back to level.
      expect(
        judge(beforeOpponent: 260, before: 600, after: 0),
        Classification.miss,
      );
    });

    test('already winning, a small extra is no gift', () {
      // +4.0 (81.3 %) to +5.0 (86.2 %) is under the Mistake threshold.
      expect(judge(beforeOpponent: 400), Classification.blunder);
    });

    test('an opponent move that gave little away is no gift', () {
      // +2.5 to +3.2 is a 5-point drop, under the Mistake threshold.
      expect(
        judge(beforeOpponent: 250, before: 320, after: 0),
        Classification.blunder,
      );
    });

    test('without the earlier eval it is the six-tier verdict', () {
      expect(judge(beforeOpponent: null), Classification.blunder);
    });

    test('a best move is never a Miss', () {
      expect(
        classify(
          beforeOpponentMove: _cp(0),
          before: _cp(500, best: 'a2a3'),
          after: _cp(50),
          mover: Side.white,
          playedUci: 'a2a3',
        ),
        Classification.best,
      );
    });

    test('sits below Blunder, and counts as a mistake', () {
      expect(Classification.values.last, Classification.miss);
      expect(Classification.miss.isMistakeOrWorse, isTrue);
    });
  });

  group('needsRunnerUp', () {
    // 1.e4 e5 2.Nf3: Black to move, many legal moves, not in check.
    final open = _positionAfter(['e4', 'e5', 'Nf3']);

    bool needs({
      EngineEval? before,
      EngineEval? after,
      String played = 'b8c6',
      Position? position,
      Side mover = Side.black,
    }) => needsRunnerUp(
      before: before ?? _cp(-20, best: 'b8c6'),
      after: after ?? _cp(-20),
      mover: mover,
      playedUci: played,
      positionBefore: position ?? open,
    );

    test('a Best move with a choice asks for the runner-up', () {
      expect(needs(), isTrue);
    });

    test('any move but the best never does — no promotion reads it', () {
      expect(needs(played: 'g8f6'), isFalse);
    });

    test('a position that already has its runner-up is not searched twice', () {
      expect(needs(before: _ranked(-20, best: 'b8c6')), isFalse);
    });

    test('under Great\'s floor (40 %) nothing can be promoted', () {
      // White-perspective +200 is 32.4 % for Black.
      expect(needs(after: _cp(200)), isFalse);
    });

    test('a worse position over Great\'s floor is still asked', () {
      // +0.5 is 45.4 % for Black: a Great may hold it.
      expect(needs(after: _cp(50)), isTrue);
    });

    test('escaping check is not asked about', () {
      // 1.e4 f5 2.Qh5+: Black is in check.
      final check = _positionAfter(['e4', 'f5', 'Qh5+']);
      expect(
        needs(
          position: check,
          played: 'g7g6',
          before: _cp(300, best: 'g7g6'),
        ),
        isFalse,
      );
    });

    test('a single legal move is not asked about', () {
      // The king is boxed in by the rook and the h6 pawn, h7 is blocked:
      // ...b5 is Black's only move.
      final forced = Chess.fromSetup(
        Setup.parseFen('7k/7p/1p5P/8/8/8/8/K5R1 b - - 0 1'),
      );
      expect(forced.legalMoves.values.fold<int>(0, (n, s) => n + s.size), 1);
      expect(
        needs(
          position: forced,
          played: 'b6b5',
          before: _cp(-900, best: 'b6b5'),
          after: _cp(-900),
        ),
        isFalse,
      );
    });

    test('a promotion is not asked about', () {
      final promotion = Chess.fromSetup(
        Setup.parseFen('8/P6k/8/8/8/8/8/K7 w - - 0 1'),
      );
      expect(
        needs(
          position: promotion,
          played: 'a7a8q',
          mover: Side.white,
          before: _cp(900, best: 'a7a8q'),
          after: _cp(900),
        ),
        isFalse,
      );
    });
  });

  group('runnerUpMoves', () {
    test('is every legal move but the best one', () {
      final moves = runnerUpMoves(Chess.initial, 'e2e4');
      expect(moves, hasLength(19));
      expect(moves, isNot(contains('e2e4')));
      expect(moves, contains('g1f3'));
    });

    test('castling is written the way the app compares moves', () {
      // White can castle short: dartchess writes it king-takes-rook.
      final castle = _positionAfter(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']);
      final moves = runnerUpMoves(castle, 'c2c3');
      expect(moves, contains('e1h1'));
      expect(moves, isNot(contains('e1g1')));
    });

    test('a promotion is offered as all four pieces', () {
      final promotion = Chess.fromSetup(
        Setup.parseFen('8/P6k/8/8/8/8/8/K7 w - - 0 1'),
      );
      final moves = runnerUpMoves(promotion, 'a7a8q');
      expect(moves, containsAll(['a7a8r', 'a7a8b', 'a7a8n']));
      expect(moves, isNot(contains('a7a8q')));
    });
  });

  group('EngineEval.withRunnerUp', () {
    test('keeps the score and the line, and adds the runner-up', () {
      const eval = EngineEval(
        cp: 40,
        bestMoveUci: 'e2e4',
        pvUci: ['e2e4', 'e7e5'],
        depth: 15,
      );
      final ranked = eval.withRunnerUp(
        const EngineLine(cp: -300, pvUci: ['a2a3']),
      );
      expect(ranked.cp, 40);
      expect(ranked.bestMoveUci, 'e2e4');
      expect(ranked.pvUci, ['e2e4', 'e7e5']);
      expect(ranked.depth, 15);
      expect(ranked.secondBest?.moveUci, 'a2a3');
      expect(onlyMoveGap(ranked, Side.white), greaterThan(15));
    });
  });

  group('Great, on whole positions', () {
    EngineEval onlyMove(String best, {int cp = 30, int runnerUp = -300}) =>
        EngineEval(
          cp: cp,
          bestMoveUci: best,
          depth: 20,
          alternatives: [
            EngineLine(cp: runnerUp, pvUci: const ['a2a3']),
          ],
        );

    Classification judge(
      List<String> sans,
      String playedSan, {
      EngineEval Function(String best)? before,
      String? previousCaptureUci,
    }) {
      final positionBefore = _positionAfter(sans);
      final move = positionBefore.parseSan(playedSan)!;
      return classify(
        before: (before ?? onlyMove)(move.uci),
        after: _cp(25),
        mover: positionBefore.turn,
        playedUci: move.uci,
        positionBefore: positionBefore,
        positionAfter: positionBefore.play(move),
        previousCaptureUci: previousCaptureUci,
      );
    }

    test('a retreat to the one safe square is not Great', () {
      // 4...b5 hits the bishop, and b3 is the only square that keeps it.
      expect(
        judge(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'b5'], 'Bb3'),
        Classification.best,
      );
    });

    test('a retreat with a choice of safe squares can be Great', () {
      // 3...a6 hits the bishop, which has several safe squares: if only one
      // of them holds the position, finding it counts.
      expect(
        judge(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'], 'Ba4'),
        Classification.great,
      );
    });

    test('an even trade can still be Great — many tactics start with one', () {
      // exd5 Qxd5: a pawn for a pawn, but the only move here.
      expect(judge(['e4', 'd5'], 'exd5'), Classification.great);
    });

    test('taking a piece that only moved there is no recapture', () {
      // 3...d5 moved a pawn, it captured nothing; Bxd5 gives the bishop for
      // it. The only move, and the bishop is really on offer, so it is
      // promoted to Brilliant.
      expect(
        judge(['e3', 'e5', 'Bc4', 'Nf6', 'd3', 'd5'], 'Bxd5'),
        Classification.brilliant,
      );
    });

    test('a runner-up that still stands clearly better is not needed', () {
      // The runner-up keeps +1.2 (61 %), over Great's 60 % ceiling.
      expect(
        judge(
          ['e4', 'e5'],
          'Nf3',
          before: (best) => onlyMove(best, cp: 1000, runnerUp: 120),
        ),
        Classification.best,
      );
      // At +1.0 (59 %) the advantage is really let go.
      expect(
        judge(
          ['e4', 'e5'],
          'Nf3',
          before: (best) => onlyMove(best, cp: 1000, runnerUp: 100),
        ),
        Classification.great,
      );
    });

    test('only the check that finds a perpetual is Great', () {
      // Qe8+ Kh7 Qe4+ Kh8 Qe8+: the queen checks for ever (cp 0), and
      // everything else loses to the rook.
      final positionBefore = Chess.fromSetup(
        Setup.parseFen('7k/6p1/8/8/8/8/r4PPP/4Q1K1 w - - 0 1'),
      );
      final move = Move.parse('e1e8')!;
      Classification check({
        required int beforeOpponentMove,
        bool opponentWasInCheck = true,
        List<String> line = const ['h8h7', 'e8e4', 'h7h8', 'e4e8'],
      }) => classify(
        before: onlyMove(move.uci, cp: 0),
        after: EngineEval(
          cp: 0,
          bestMoveUci: line.first,
          pvUci: line,
          depth: 20,
        ),
        mover: Side.white,
        playedUci: move.uci,
        positionBefore: positionBefore,
        positionAfter: positionBefore.play(move),
        beforeOpponentMove: _cp(beforeOpponentMove),
        opponentWasInCheck: opponentWasInCheck,
      );
      // The opponent's slip handed over the draw: finding it is Great.
      expect(check(beforeOpponentMove: -500), Classification.great);
      // Already drawn by the checks before: keeping them up is not.
      expect(check(beforeOpponentMove: 0), Classification.best);
      // Nor is the check that repeats it into a draw, which has no line.
      expect(
        classify(
          before: onlyMove(move.uci, cp: 0),
          after: const EngineEval(cp: 0, bestMoveUci: null, depth: 20),
          mover: Side.white,
          playedUci: move.uci,
          positionBefore: positionBefore,
          positionAfter: positionBefore.play(move),
          beforeOpponentMove: _cp(0),
          opponentWasInCheck: true,
        ),
        Classification.best,
      );
      // Level, but no check before it: no perpetual was running yet.
      expect(
        check(beforeOpponentMove: 0, opponentWasInCheck: false),
        Classification.great,
      );
      // A hunt that goes on with a quiet move is not a perpetual.
      expect(
        check(beforeOpponentMove: 0, line: const ['h8h7', 'g1f1']),
        Classification.great,
      );
    });

    test('isPerpetualLine wants a check on every move of the checker', () {
      final start = Chess.fromSetup(
        Setup.parseFen('4Q2k/6p1/8/8/8/8/r4PPP/6K1 b - - 0 1'),
      );
      expect(
        isPerpetualLine(start, const [
          'h8h7',
          'e8e4',
          'h7h8',
          'e4e8',
        ], Side.white),
        isTrue,
      );
      expect(
        isPerpetualLine(start, const ['h8h7', 'e8e4'], Side.white),
        isFalse,
        reason: 'one check is not yet a perpetual',
      );
      expect(
        isPerpetualLine(start, const ['h8h7', 'g1f1', 'h7h8'], Side.white),
        isFalse,
      );
    });

    test('delivering a mate already in hand is not Great', () {
      // 1.f3 e5 2.g4 Qh4#: the mating move itself.
      final before = _positionAfter(['f3', 'e5', 'g4']);
      final mate = before.parseSan('Qh4#')!;
      expect(
        classify(
          before: EngineEval(
            mateIn: -1,
            bestMoveUci: mate.uci,
            depth: 20,
            alternatives: const [
              EngineLine(cp: 0, pvUci: ['a7a6']),
            ],
          ),
          after: const EngineEval.checkmate(mated: Side.white, depth: 20),
          mover: Side.black,
          playedUci: mate.uci,
          positionBefore: before,
          positionAfter: before.play(mate),
        ),
        Classification.best,
      );
    });
  });

  group('cpCeiledFor', () {
    test('is White-perspective for White and flipped for Black', () {
      expect(cpCeiledFor(_cp(250), Side.white), 250);
      expect(cpCeiledFor(_cp(250), Side.black), -250);
    });

    test('clamps before it flips', () {
      expect(cpCeiledFor(_cp(9000), Side.white), 1000);
      expect(cpCeiledFor(_cp(9000), Side.black), -1000);
    });
  });
}
