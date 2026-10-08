import 'package:chess_mortem/model/accuracy.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_phase.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// A legal game of [pairs] knight shuffles, so evals can be scripted per ply
/// without needing a real transcript.
String _shufflePgn(int pairs) {
  final moves = [
    for (var i = 1; i <= pairs; i++) i.isOdd ? '$i. Nf3 Nf6' : '$i. Ng1 Ng8',
  ];
  return '[Event "Test"]\n\n${moves.join(' ')} *\n';
}

/// Builds a tree whose root and mainline carry [cps] (White-perspective
/// centipawns), one entry per position including the root.
GameTree _treeWithEvals(List<int> cps) {
  final tree = GameTree.fromPgn(_shufflePgn((cps.length - 1) ~/ 2 + 1));
  final nodes = [tree.root, ...tree.mainline];
  for (var i = 0; i < cps.length && i < nodes.length; i++) {
    nodes[i].eval = EngineEval(cp: cps[i], bestMoveUci: 'g1f3', depth: 15);
  }
  // Anything past the scripted evals stays unevaluated, which the accuracy
  // code must simply stop at.
  for (var i = cps.length; i < nodes.length; i++) {
    nodes[i].eval = null;
  }
  return tree;
}

double? _accuracy(GameTree tree, Side side) => gameAccuracy(
  accuracySamples(root: tree.root, mainline: tree.mainline, mover: side),
);

void main() {
  group('moveAccuracy', () {
    test('a move that loses nothing is 100', () {
      expect(moveAccuracy(winPctBefore: 50, winPctAfter: 50), 100);
      expect(moveAccuracy(winPctBefore: 50, winPctAfter: 62), 100);
    });

    test('a small slip stays high', () {
      final accuracy = moveAccuracy(winPctBefore: 55, winPctAfter: 53);
      expect(accuracy, greaterThan(90));
      expect(accuracy, lessThan(100));
    });

    test('a blunder scores far below the naive "100 minus the drop"', () {
      // Losing 40 points of winning chances is a disaster, which a plain
      // "100 minus the drop" would score 60%.
      final accuracy = moveAccuracy(winPctBefore: 70, winPctAfter: 30);
      expect(accuracy, lessThan(20));
    });

    test('the curve is monotonic in the drop', () {
      var previous = 101.0;
      for (var drop = 0; drop <= 60; drop += 5) {
        final accuracy = moveAccuracy(
          winPctBefore: 80,
          winPctAfter: 80.0 - drop,
        );
        expect(accuracy, lessThanOrEqualTo(previous));
        previous = accuracy;
      }
    });
  });

  group('gameAccuracy', () {
    test('a game where nothing changes scores ~100', () {
      final tree = _treeWithEvals(List.filled(21, 20));
      expect(_accuracy(tree, Side.white), closeTo(100, 0.5));
      expect(_accuracy(tree, Side.black), closeTo(100, 0.5));
    });

    test('one blunder in an otherwise clean game pulls the score down', () {
      final cps = List.filled(21, 20);
      cps[7] = -600; // White's 4th move throws the game away
      for (var i = 8; i < cps.length; i++) {
        cps[i] = -600;
      }
      final tree = _treeWithEvals(cps);

      final white = _accuracy(tree, Side.white)!;
      final black = _accuracy(tree, Side.black)!;
      expect(
        white,
        lessThan(75),
        reason: 'the harmonic mean must let one blunder actually hurt',
      );
      expect(black, greaterThan(white));
    });

    test('a game thrown away in three blunders is nowhere near 90%', () {
      // The complaint this formula exists to fix: three real blunders used
      // to average out to a 90-something score.
      final cps = List.filled(21, 0);
      for (var ply = 0; ply < cps.length; ply++) {
        cps[ply] = switch (ply) {
          < 5 => 0,
          < 11 => -300,
          < 17 => -600,
          _ => -900,
        };
      }
      final tree = _treeWithEvals(cps);

      final white = _accuracy(tree, Side.white)!;
      expect(white, lessThan(80));
      // Black, who only ever gained, played "perfectly".
      expect(_accuracy(tree, Side.black), closeTo(100, 0.5));
    });

    test('a slow drift still scores high, because no single move was bad', () {
      // Documents what the formula measures: giving up 40 centipawns a move
      // is not blundering, and the published curve scores it high too.
      final cps = [for (var i = 0; i <= 20; i++) -40 * i];
      final white = _accuracy(_treeWithEvals(cps), Side.white)!;
      expect(white, greaterThan(85));
      expect(white, lessThan(95));
    });

    test('book moves are not scored', () {
      final cps = List.filled(21, 20);
      cps[1] = -900; // a catastrophic first move...
      final tree = _treeWithEvals(cps);
      final scoredWithoutBook = _accuracy(tree, Side.white)!;

      // ...which is theory, so it must not count against the player.
      tree.mainline.first.openingName = 'A04 Zukertort Opening';
      final scoredWithBook = _accuracy(tree, Side.white)!;

      expect(scoredWithBook, greaterThan(scoredWithoutBook));
      expect(scoredWithBook, greaterThan(90));
    });

    test('an unanalyzed game has no accuracy', () {
      final tree = GameTree.fromPgn(_shufflePgn(4));
      expect(_accuracy(tree, Side.white), isNull);
    });

    test('a partially analyzed game scores only what is evaluated', () {
      final tree = _treeWithEvals(List.filled(5, 15));
      expect(_accuracy(tree, Side.white), isNotNull);
    });

    test('the volatility window trails the move it weights', () {
      // lichess weights a move by the swing in the positions LEADING UP to
      // it, never by what happened afterwards. The game is quiet through ply
      // 3 and then collapses on ply 4.
      final cps = [for (var i = 0; i <= 10; i++) i < 4 ? 0 : -800];
      final tree = _treeWithEvals(cps);
      List<AccuracySample> samplesFor(Side side) => accuracySamples(
        root: tree.root,
        mainline: tree.mainline,
        mover: side,
      );

      // White's ply-3 move is scored while nothing has happened yet. A
      // CENTRED window would already see the ply-4 collapse and weight this
      // move as if the player had been in the storm.
      final whiteAt3 = samplesFor(Side.white).firstWhere((s) => s.ply == 3);
      expect(whiteAt3.volatilityWeight, 0.5);

      // The collapse itself is the move whose trailing window straddles it.
      final blackAt4 = samplesFor(Side.black).firstWhere((s) => s.ply == 4);
      expect(blackAt4.volatilityWeight, 12.0);
    });

    test('samples carry the ply they were played on', () {
      final tree = _treeWithEvals(List.filled(11, 20));
      final samples = accuracySamples(
        root: tree.root,
        mainline: tree.mainline,
        mover: Side.white,
      );
      expect(samples.map((s) => s.ply), [1, 3, 5, 7, 9]);
    });
  });

  group('phaseAccuracy', () {
    double? phase(
      GameTree tree,
      GameDivision division,
      GamePhase phase,
      Side side,
    ) => phaseAccuracy(
      mainline: tree.mainline,
      division: division,
      phase: phase,
      mover: side,
    );

    test('splits the game at the ply a move lands on', () {
      // Clean until ply 10, then White throws it away.
      final cps = [for (var i = 0; i <= 20; i++) i < 11 ? 0 : -700];
      final tree = _treeWithEvals(cps);
      const division = GameDivision(middle: 10, plies: 20);

      final opening = phase(tree, division, GamePhase.opening, Side.white)!;
      final middlegame = phase(
        tree,
        division,
        GamePhase.middlegame,
        Side.white,
      )!;
      expect(opening, greaterThan(90));
      expect(middlegame, lessThan(opening));
    });

    test('a phase entered while already lost does not score 100', () {
      // The point of scoring a phase from a level position. White is lost
      // from ply 10 on and nothing after that changes: every drop inside the
      // endgame is exactly 0, because both scores sit on the +/-1000 ceiling.
      // Measured from where the phase really began, White's endgame would
      // read a perfect 100.
      final cps = [for (var i = 0; i <= 20; i++) i < 10 ? 0 : -2000];
      final tree = _treeWithEvals(cps);
      // Odd, so the endgame opens with a White move: the level baseline is
      // spent on whoever moves first in the phase.
      const division = GameDivision(middle: 4, end: 11, plies: 20);

      final endgame = phase(tree, division, GamePhase.endgame, Side.white)!;
      expect(endgame, lessThan(40));
      // The player who did the winning kept everything they had.
      expect(phase(tree, division, GamePhase.endgame, Side.black), 100);
    });

    test('a phase is not a slice of the overall number', () {
      // Each phase is re-run as its own game against a level position, so the
      // parts can legitimately read lower than the whole. Pinned so nobody
      // "fixes" the rows into adding up.
      final cps = [for (var i = 0; i <= 20; i++) -30 * i];
      final tree = _treeWithEvals(cps);
      const division = GameDivision(middle: 5, end: 15, plies: 20);

      final overall = _accuracy(tree, Side.white)!;
      final endgame = phase(tree, division, GamePhase.endgame, Side.white)!;
      expect(overall, greaterThan(85));
      expect(endgame, lessThan(60));
    });

    test('a phase with no moves has no accuracy', () {
      final tree = _treeWithEvals(List.filled(11, 20));
      expect(
        phase(
          tree,
          const GameDivision(middle: 10, end: 40, plies: 60),
          GamePhase.endgame,
          Side.white,
        ),
        isNull,
      );
    });
  });

  group('averageCentipawnLoss', () {
    int? acpl(GameTree tree, Side side) => averageCentipawnLoss(
      root: tree.root,
      mainline: tree.mainline,
      mover: side,
    );

    test('perfect play loses nothing', () {
      final tree = _treeWithEvals(List.filled(11, 30));
      expect(acpl(tree, Side.white), 0);
      expect(acpl(tree, Side.black), 0);
    });

    test('counts only the mover\'s own moves', () {
      // White drops 100 on each of their moves; Black simply holds on.
      final cps = [0, -100, -100, -200, -200, -300, -300];
      final tree = _treeWithEvals(cps);
      expect(acpl(tree, Side.white), 100);
      expect(acpl(tree, Side.black), 0);
    });

    test('a gain counts as zero, it does not cancel a loss', () {
      // One move loses 200, the next gains 200. The mean is 100, not 0.
      final cps = [0, -200, -200, 0, 0];
      final tree = _treeWithEvals(cps);
      expect(acpl(tree, Side.white), 100);
    });

    test('a mate is scored at the ceiling, not at 99 pawns', () {
      final tree = _treeWithEvals([0, 0, 0]);
      tree.mainline.first.eval = const EngineEval(
        mateIn: -1,
        bestMoveUci: 'd8h4',
        depth: 15,
      );
      // 0 to -1000, capped by the ceiling rather than by the -9900 that
      // EngineEval.pawns would report.
      expect(acpl(tree, Side.white), 1000);
    });

    test('book moves are not counted', () {
      final cps = [0, -400, -400, -400, -400];
      final tree = _treeWithEvals(cps);
      expect(acpl(tree, Side.white), 200);

      tree.mainline.first.openingName = 'A04 Zukertort Opening';
      expect(acpl(tree, Side.white), 0);
    });

    test('an unanalyzed game has no centipawn loss', () {
      final tree = GameTree.fromPgn(_shufflePgn(4));
      expect(acpl(tree, Side.white), isNull);
    });
  });

  // The last position of a won game is the one the engine reports as
  // `score mate 0`, and mishandling it made the winner's mating move look
  // like the worst move of their game — which dragged the whole score down.
  group('a game that ends in checkmate', () {
    /// 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6?? 4. Qxf7#, evaluated: quiet until
    /// Black's 3rd move hangs mate, then White plays it.
    GameTree matedTree() {
      final tree = GameTree.fromPgn(
        '[Event "Test"]\n\n1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0\n',
      );
      final nodes = [tree.root, ...tree.mainline];
      for (final node in nodes) {
        node.eval = const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15);
      }
      // After 3...Nf6 White has mate in one, and then plays it.
      nodes[6].eval = const EngineEval(
        mateIn: 1,
        bestMoveUci: 'h5f7',
        depth: 15,
      );
      nodes[7].eval = const EngineEval.checkmate(mated: Side.black, depth: 15);
      return tree;
    }

    test('the mating move costs the winner nothing', () {
      final tree = matedTree();
      final mate = accuracySamples(
        root: tree.root,
        mainline: tree.mainline,
        mover: Side.white,
      ).firstWhere((s) => s.ply == 7);
      expect(mate.accuracy, 100);

      expect(_accuracy(tree, Side.white), greaterThan(95));
      // The player who walked into it is the one who lost something.
      expect(_accuracy(tree, Side.black), lessThan(50));
    });

    test('delivering mate is not centipawn loss', () {
      final tree = matedTree();
      int? loss(Side side) => averageCentipawnLoss(
        root: tree.root,
        mainline: tree.mainline,
        mover: side,
      );
      expect(loss(Side.white), 0);
      expect(loss(Side.black), greaterThan(300));
    });
  });
}
