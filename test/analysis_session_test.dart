import 'dart:async';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/engine/engine.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 *
''';

const _pgnLong = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''';

/// Every move the "next key move" button stops on, from the start.
List<GameNode> _walkKeyMoves(AnalysisSession session) {
  session.goToNode(session.tree.root);
  final visited = <GameNode>[];
  for (
    var next = session.nextKeyMove;
    next != null;
    next = session.nextKeyMove
  ) {
    session.goToNode(next);
    visited.add(next);
  }
  return visited;
}

void main() {
  group('AnalysisSession', () {
    test(
      'loadPgn evaluates root + each mainline position exactly once',
      () async {
        final engine = FakeEngine();
        final session = AnalysisSession(engine: engine);

        await session.loadPgn(_pgn);

        // Root + 3 moves = 4 positions, one call each.
        expect(engine.totalCalls, 4);
        expect(engine.callsByFen.values, everyElement(1));
        expect(session.isAnalyzing, isFalse);
        expect(
          session.tree.mainline.map((n) => n.classification),
          everyElement(isNotNull),
        );
      },
    );

    test(
      'the engine label quotes the depth the moves were searched at',
      () async {
        final engine = FakeEngine();
        final session = AnalysisSession(engine: engine, searchDepth: 12);
        engine.fallback = const EngineEval(
          cp: 0,
          bestMoveUci: 'e2e4',
          depth: 12,
        );
        await session.loadPgn(_pgn);

        expect(session.engineLabel, 'Fake engine · depth 12');

        // The slider only changes what LATER searches use, so the label must
        // not follow it — those moves are still depth-12 evals.
        session.searchDepth = 20;
        expect(session.engineLabel, 'Fake engine · depth 12');
      },
    );

    test(
      'the engine label drops the depth when there is no single one',
      () async {
        final session = AnalysisSession(engine: FakeEngine());

        // Nothing analysed yet: naming a depth would be inventing one.
        expect(session.engineLabel, 'Fake engine');
        expect(session.analyzedDepth, isNull);
      },
    );

    test('progress is reported in moves, not plies', () async {
      final session = AnalysisSession(engine: FakeEngine());

      // Nothing loaded yet.
      expect(session.totalMoves, 0);

      await session.loadPgn(_pgn); // 1. e4 e5 2. Nf3 — three plies
      expect(session.totalToAnalyze, 4); // root + 3 plies
      expect(session.totalMoves, 2); // ...but two numbered moves
      expect(session.analyzedMoves, session.totalMoves);
    });

    test(
      'playMove on an existing edge reuses the node, zero engine calls',
      () async {
        final engine = FakeEngine();
        final session = AnalysisSession(engine: engine);
        await session.loadPgn(_pgn);
        final callsAfterAnalysis = engine.totalCalls;
        final mainlineFirst = session.tree.root.children.first;

        session.goToNode(session.tree.root);
        final node = await session.playMove(Move.parse('e2e4')!);

        expect(identical(node, mainlineFirst), isTrue);
        expect(engine.totalCalls, callsAfterAnalysis);
        expect(session.current, node);
      },
    );

    test('playMove on a new edge evaluates and classifies it once', () async {
      final engine = FakeEngine();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn(_pgn);
      final callsAfterAnalysis = engine.totalCalls;

      session.goToNode(session.tree.root);
      final node = await session.playMove(Move.parse('d2d4')!);

      expect(node.san, 'd4');
      expect(node.isUserMove, isTrue);
      expect(node.eval, isNotNull);
      expect(node.classification, isNotNull);
      expect(engine.totalCalls, callsAfterAnalysis + 1);

      // Playing it again re-uses everything.
      session.goToNode(session.tree.root);
      await session.playMove(Move.parse('d2d4')!);
      expect(engine.totalCalls, callsAfterAnalysis + 1);
    });

    test('navigation walks the tree and clamps at the ends', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      expect(session.current, session.tree.root);
      expect(session.canGoBack, isFalse);

      session.goForward();
      expect(session.current.san, 'e4');

      session.goBack();
      session.goBack(); // extra goBack at root is a no-op
      expect(session.current, session.tree.root);

      session.goToNode(session.tree.mainline.last);
      expect(session.canGoForward, isFalse);
    });

    test('nextKeyMove finds the next mainline mistake/blunder', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);
      final mainline = session.tree.mainline;
      for (final node in mainline) {
        node.classification = Classification.best;
      }
      mainline[2].classification = Classification.blunder;

      session.goToNode(session.tree.root);
      expect(session.nextKeyMove, mainline[2]);

      session.goToNode(mainline[2]);
      expect(session.nextKeyMove, isNull);
      expect(session.previousKeyMove, isNull);
    });

    test('key moves include Brilliant, Great and Miss, not inaccuracies '
        'when there is a mistake', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgnLong);
      final verdicts = [
        Classification.great,
        Classification.inaccuracy,
        Classification.mistake,
        Classification.brilliant,
        Classification.good,
        Classification.miss,
      ];
      final mainline = session.tree.mainline;
      for (var i = 0; i < mainline.length; i++) {
        mainline[i].classification = verdicts[i];
      }

      expect(_walkKeyMoves(session), [
        mainline[0],
        mainline[2],
        mainline[3],
        mainline[5],
      ]);
    });

    test('with no mistake, the key moves fall back to inaccuracies', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgnLong);
      final verdicts = [
        Classification.best,
        Classification.inaccuracy,
        Classification.great,
        Classification.good,
        Classification.inaccuracy,
        Classification.excellent,
      ];
      final mainline = session.tree.mainline;
      for (var i = 0; i < mainline.length; i++) {
        mainline[i].classification = verdicts[i];
      }

      expect(_walkKeyMoves(session), [mainline[1], mainline[2], mainline[4]]);
    });

    test('invalid PGN sets loadError instead of throwing', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn('1. e5 nonsense *');
      expect(session.loadError, isNotNull);
    });

    test('keeps the PGN as given, and drops it when one fails', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);
      expect(session.pgn, _pgn);

      await session.loadPgn('1. e5 nonsense *');
      expect(session.pgn, isNull);
    });

    test('the cursor follows the sweep, then returns to the start', () async {
      final engine = _SteppedEngine();
      final session = AnalysisSession(engine: engine);

      final analysis = session.loadPgn(_pgn);
      await pumpEventQueue();
      engine.releaseNext(); // the root
      await pumpEventQueue();
      expect(session.current, session.tree.root);
      expect(session.followsSweep, isTrue);

      for (final node in session.tree.mainline) {
        engine.releaseNext();
        await pumpEventQueue();
        if (session.isAnalyzing) expect(session.current, node);
      }
      await analysis;

      expect(session.current, session.tree.root);
      expect(session.followsSweep, isFalse);
    });

    test('navigating mid-sweep stops the following for good', () async {
      final engine = _SteppedEngine();
      final session = AnalysisSession(engine: engine);

      final analysis = session.loadPgn(_pgn);
      await pumpEventQueue();
      engine.releaseNext(); // the root
      await pumpEventQueue();
      engine.releaseNext(); // 1. e4
      await pumpEventQueue();
      expect(session.current.san, 'e4');

      session.goBack();
      expect(session.followsSweep, isFalse);
      while (session.isAnalyzing) {
        engine.releaseNext();
        await pumpEventQueue();
      }
      await analysis;

      expect(session.current, session.tree.root);
      session.goToNode(session.tree.mainline.last);
      expect(session.current, session.tree.mainline.last);
    });

    test('a what-if move mid-sweep stops the following', () async {
      final engine = _SteppedEngine();
      final session = AnalysisSession(engine: engine);

      final analysis = session.loadPgn(_pgn);
      await pumpEventQueue();
      engine.releaseNext(); // the root
      await pumpEventQueue();
      engine.releaseNext(); // 1. e4
      await pumpEventQueue();

      final whatIf = session.playMove(Move.parse('d7d6')!);
      final node = session.current;
      expect(node.san, 'd6');
      while (session.isAnalyzing) {
        engine.releaseNext();
        await pumpEventQueue();
      }
      engine.releaseNext(); // the what-if move itself
      await whatIf;
      await analysis;

      expect(session.current, node);
    });

    test(
      'a failed search of the previous game leaves this one alone',
      () async {
        final engine = _SteppedEngine();
        final session = AnalysisSession(engine: engine);

        unawaited(session.loadPgn(_pgn));
        await pumpEventQueue();
        final analysis = session.loadPgn(_pgnLong);
        await pumpEventQueue();

        engine.failNext(EngineTimeoutException('old game')); // the first root
        await pumpEventQueue();
        expect(session.loadError, isNull);
        expect(session.isAnalyzing, isTrue);

        while (session.isAnalyzing) {
          engine.releaseNext();
          await pumpEventQueue();
        }
        await analysis;
        expect(session.loadError, isNull);
      },
    );

    test(
      'a what-if move onto an unsearched mainline move shares the search',
      () async {
        final engine = _SteppedEngine();
        final session = AnalysisSession(engine: engine);

        final analysis = session.loadPgn(_pgn);
        await pumpEventQueue();
        // The sweep is still on the root; play the game's own first move.
        final whatIf = session.playMove(Move.parse('e2e4')!);
        await pumpEventQueue();
        while (engine._pending.isNotEmpty) {
          engine.releaseNext();
          await pumpEventQueue();
        }
        await whatIf;
        await analysis;

        final e4 = session.tree.mainline.first.position.fen;
        expect(engine.searched.where((fen) => fen == e4), hasLength(1));
      },
    );

    test('an explanation runs while the engine is still analysing', () async {
      // Both are awaited I/O, so neither holds the event loop: the LLM
      // request for a move the engine has already scored must complete
      // without waiting for the rest of the game. Anything that made these
      // share a lock — one queue, one mutex, an await in the wrong place —
      // would turn the coach line into "wait for the whole analysis".
      final engine = _SteppedEngine();
      final explainer = FakeExplainer(response: 'It grabs the centre.');
      final session = AnalysisSession(engine: engine);

      final analysis = session.loadPgn(_pgn); // deliberately not awaited
      await pumpEventQueue();
      engine.releaseNext(); // the root
      await pumpEventQueue();
      engine.releaseNext(); // 1. e4
      await pumpEventQueue();

      final node = session.tree.mainline.first;
      expect(session.canExplain(node), isTrue);
      expect(session.isAnalyzing, isTrue); // 1...e5 is still in the engine

      await session.fetchExplanation(explainer, node: node);

      expect(node.explanation?.detail, 'It grabs the centre.');
      expect(session.isAnalyzing, isTrue); // and it still is

      while (session.isAnalyzing) {
        engine.releaseNext();
        await pumpEventQueue();
      }
      await analysis;
    });

    test(
      'the explanation is asked for with the board facts, not just evals',
      () async {
        // The session is the only place that has the node, its parent and the
        // opponent's best reply at once, so it is the only place that can hand
        // the facts over. Without this the prompt is back to a FEN and a score.
        final engine = FakeEngine();
        engine.fallback = const EngineEval(
          cp: 20,
          bestMoveUci: 'b8c6',
          depth: 15,
        );
        final explainer = FakeExplainer();
        final session = AnalysisSession(engine: engine);
        await session.loadPgn(_pgn);

        await session.fetchExplanation(
          explainer,
          node: session.tree.mainline.first,
        );

        final context = explainer.contexts.single;
        // The bare route is left out: a model reads it back as the answer.
        expect(context.facts, isNot(contains(contains('from e2 to e4'))));
        // The reply comes from the played node's own cached eval, so naming it
        // costs no extra search.
        expect(context.facts, contains(contains('Nc6')));
        // The model expands on the app's own line, so it is handed over.
        expect(
          context.coachLine,
          session.coachLineFor(session.tree.mainline.first, playful: false),
        );
      },
    );

    test(
      'a move is judged with the boards, so a sacrifice can be Brilliant',
      () async {
        // The Fried Liver, as far as the knight sacrifice.
        const moves = [
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
          'Kxf7',
        ];
        const pgn =
            '1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. Ng5 d5 '
            '5. exd5 Nxd5 6. Nxf7 Kxf7 *';

        Position positionAt(int ply) {
          Position position = Chess.initial;
          for (final san in moves.take(ply)) {
            position = position.play(position.parseSan(san)!);
          }
          return position;
        }

        // Two positions have to be scripted, because both halves of the
        // verdict come from the engine: the parent names Nxf7 as the move to
        // play, and the child carries the line the material is measured over.
        final engine = FakeEngine(
          evalsByFen: {
            positionAt(10).fen: const EngineEval(
              cp: 0,
              bestMoveUci: 'g5f7',
              depth: 15,
              // A ranked search, because Brilliant and Great are both read off
              // the runner-up: "would you have been winning without this?"
              alternatives: [
                EngineLine(cp: 10, pvUci: ['d1f3']),
              ],
            ),
            positionAt(11).fen: const EngineEval(
              cp: 0,
              bestMoveUci: 'e8f7',
              // Kxf7, Qf3+, Ke6: White stays a knight for a pawn down.
              pvUci: ['e8f7', 'd1f3', 'f7e6'],
              depth: 15,
            ),
          },
        );
        final session = AnalysisSession(engine: engine);
        await session.loadPgn(pgn);

        final sacrifice = session.tree.mainline[10];
        expect(sacrifice.san, 'Nxf7');
        // The fake scores every position the same, so the move is Best on the
        // numbers alone; only the material read off the boards can lift it.
        expect(sacrifice.classification, Classification.brilliant);
      },
    );
  });

  group('a repetition that ends the game', () {
    const shuffle = '1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1';

    test('is a draw, never searched', () async {
      final engine = FakeEngine();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn('$shuffle Ng8 1/2-1/2');
      final last = session.tree.mainline.last;
      expect(last.eval?.cp, 0);
      expect(last.eval?.bestMoveUci, isNull);
      expect(engine.callsByFen[last.position.fen], isNull);
    });

    test('a game that went on past it was not drawn', () async {
      final engine = FakeEngine();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn('$shuffle Ng8 5. e4 *');
      final third = session.tree.mainline[7];
      expect(third.eval?.bestMoveUci, 'e2e4');
      expect(engine.callsByFen[third.position.fen], 1);
    });

    test('a what-if move that repeats a third time is a draw', () async {
      final engine = FakeEngine();
      final session = AnalysisSession(engine: engine);
      // The game went 4...Nc6; ...Ng8 instead brings the start back.
      await session.loadPgn('$shuffle Nc6 *');
      session.goToNode(session.tree.mainline[6]);
      final node = await session.playMove(Move.parse('f6g8')!);
      expect(node.isUserMove, isTrue);
      expect(node.eval?.cp, 0);
      expect(node.eval?.bestMoveUci, isNull);
      expect(engine.callsByFen[node.position.fen], isNull);
    });
  });

  group('runner-up search', () {
    // 1.e4 e5 2.Nf3, every move the engine's choice. Only White's moves end
    // at or over Great's 40 % floor for the mover (1...e5 leaves Black at
    // 36.5 %), so only the root and the position after 1...e5 are candidates.
    final afterE4 = Chess.initial.play(Move.parse('e2e4')!);
    final afterE5 = afterE4.play(Move.parse('e7e5')!);
    final afterNf3 = afterE5.play(Move.parse('g1f3')!);

    FakeEngine scripted() => FakeEngine(
      evalsByFen: {
        Chess.initial.fen: const EngineEval(
          cp: 20,
          bestMoveUci: 'e2e4',
          depth: 15,
        ),
        afterE4.fen: const EngineEval(cp: 20, bestMoveUci: 'e7e5', depth: 15),
        // Black is under Great's floor (36.5 %) after 1...e5: never asked.
        afterE5.fen: const EngineEval(cp: 150, bestMoveUci: 'g1f3', depth: 15),
        afterNf3.fen: const EngineEval(cp: 20, bestMoveUci: 'b8c6', depth: 15),
      },
      runnerUpsByFen: {
        // Everything but 1.e4 loses: 1.e4 is the only move.
        Chess.initial.fen: const EngineLine(cp: -300, pvUci: ['a2a3']),
      },
    );

    test('is asked only where a Best move could be promoted', () async {
      final engine = scripted();
      await AnalysisSession(engine: engine).loadPgn(_pgn);

      expect(engine.runnerUpCallsByFen.keys, {Chess.initial.fen, afterE5.fen});
      expect(engine.runnerUpCallsByFen.values, everyElement(1));
      // Every move but the engine's own.
      expect(engine.searchMovesByFen[Chess.initial.fen], hasLength(19));
      expect(
        engine.searchMovesByFen[Chess.initial.fen],
        isNot(contains('e2e4')),
      );
    });

    test('is shallower than the eval, never deeper', () async {
      // The evals are depth 15; a gap that size shows by depth 10.
      final engine = scripted();
      await AnalysisSession(engine: engine).loadPgn(_pgn);
      expect(engine.runnerUpDepthByFen[Chess.initial.fen], runnerUpSearchDepth);

      expect(runnerUpDepthFor(22), runnerUpSearchDepth);
      expect(runnerUpDepthFor(8), 8);
    });

    test('its answer promotes the move and stays on the parent', () async {
      final engine = scripted();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn(_pgn);

      final e4 = session.tree.mainline.first;
      expect(e4.classification, Classification.great);
      expect(session.tree.root.eval?.secondBest?.moveUci, 'a2a3');
      // No line came back after 1...e5: still Best, and unknown, not "none".
      expect(session.tree.mainline.last.classification, Classification.best);
      expect(session.tree.mainline[1].eval?.secondBest, isNull);
    });

    test('is never asked twice for one position', () async {
      final engine = scripted();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn(_pgn);

      // A what-if 2.Nf3 again from the same parent, and another Best move
      // from a position whose search came back empty.
      session.goToNode(session.tree.mainline[1]);
      await session.playMove(Move.parse('g1f3')!);
      expect(engine.runnerUpCallsByFen[afterE5.fen], 1);
    });

    test('the switch off asks for nothing and awards neither', () async {
      final engine = scripted();
      final session = AnalysisSession(engine: engine, ranksAlternatives: false);
      await session.loadPgn(_pgn);

      expect(engine.runnerUpCallsByFen, isEmpty);
      expect(session.tree.mainline.first.classification, Classification.best);
    });
  });

  group('ensureBetterLine', () {
    /// A session where 1. e4 is a blunder and the engine wanted the line
    /// 1. d4 d5 2. c4 e6 3. Nc3 instead.
    Future<AnalysisSession> blunderSession() async {
      final initial = Chess.initial;
      final afterE4 = initial.play(initial.parseSan('e4')!).fen;
      final session = AnalysisSession(
        engine: FakeEngine(
          evalsByFen: {
            initial.fen: const EngineEval(
              cp: 300,
              bestMoveUci: 'd2d4',
              pvUci: ['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3'],
              depth: 15,
            ),
            afterE4: const EngineEval(cp: -400, bestMoveUci: 'e7e5', depth: 15),
          },
        ),
      );
      await session.loadPgn(_pgn);
      return session;
    }

    test(
      'plays the engine\'s line out as a variation under the parent',
      () async {
        final session = await blunderSession();
        final blunder = session.tree.mainline.first; // 1. e4
        expect(blunder.classification, Classification.blunder);

        await session.ensureBetterLine(blunder);

        // The played move keeps its place as children[0]; the engine's line is
        // a sibling branch, which is what the move strips render as a
        // variation and what the board can be stepped through.
        final root = session.tree.root;
        expect(root.children.first, blunder);
        expect(root.children, hasLength(2));

        final line = <String>[];
        for (var node = root.children[1]; ; node = node.children.first) {
          line.add(node.san!);
          if (node.children.isEmpty) break;
        }
        expect(line, ['d4', 'd5', 'c4', 'e6', 'Nc3']);
      },
    );

    test(
      'every move of it is evaluated and judged, like a what-if move',
      () async {
        final session = await blunderSession();
        await session.ensureBetterLine(session.tree.mainline.first);

        for (var node = session.tree.root.children[1]; ;) {
          expect(node.eval, isNotNull, reason: node.san);
          expect(node.classification, isNotNull, reason: node.san);
          if (node.children.isEmpty) break;
          node = node.children.first;
        }
      },
    );

    test('builds it once, however many times the cursor lands there', () async {
      final session = await blunderSession();
      final engine = session.engine as FakeEngine;
      final blunder = session.tree.mainline.first;

      await session.ensureBetterLine(blunder);
      final callsAfterFirst = engine.totalCalls;
      await session.ensureBetterLine(blunder);
      await session.ensureBetterLine(blunder);

      expect(engine.totalCalls, callsAfterFirst);
      expect(session.tree.root.children, hasLength(2));
    });

    test(
      'a good move gets no branch — there is nothing better to play',
      () async {
        // The fake engine wants e2e4 everywhere, so 1. e4 is the best move.
        final session = AnalysisSession(engine: FakeEngine());
        await session.loadPgn(_pgn);

        await session.ensureBetterLine(session.tree.mainline.first);
        expect(session.tree.root.children, hasLength(1));
      },
    );

    test('a PV that disagrees with bestmove builds nothing', () async {
      final initial = Chess.initial;
      final afterE4 = initial.play(initial.parseSan('e4')!).fen;
      final session = AnalysisSession(
        engine: FakeEngine(
          evalsByFen: {
            initial.fen: const EngineEval(
              cp: 300,
              bestMoveUci: 'd2d4',
              pvUci: ['g1f3', 'd7d5'], // a search cut short by `stop`
              depth: 15,
            ),
            afterE4: const EngineEval(cp: -400, bestMoveUci: 'e7e5', depth: 15),
          },
        ),
      );
      await session.loadPgn(_pgn);

      await session.ensureBetterLine(session.tree.mainline.first);
      expect(session.tree.root.children, hasLength(1));
    });
  });
}

/// An engine that hands out one evaluation at a time, on the test's command,
/// so the test can hold the analysis mid-game.
class _SteppedEngine implements ChessEngine {
  final List<Completer<void>> _pending = [];

  /// Every position searched, in order.
  final List<String> searched = [];

  @override
  String get name => 'Stepped engine';

  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) async {
    searched.add(fen);
    final gate = Completer<void>();
    _pending.add(gate);
    await gate.future;
    return const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15);
  }

  @override
  Future<EngineLine?> evaluateRunnerUp(
    String fen, {
    required List<String> searchMoves,
    int depth = 15,
  }) async => null;

  void releaseNext() {
    if (_pending.isNotEmpty) _pending.removeAt(0).complete();
  }

  void failNext(Object error) {
    if (_pending.isNotEmpty) _pending.removeAt(0).completeError(error);
  }

  @override
  Future<void> dispose() async {}
}
