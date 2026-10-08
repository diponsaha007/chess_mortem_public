import 'dart:convert';
import 'dart:io';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/analysis/analysis_store.dart';
import 'package:chess_mortem/model/analysis_codec.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_analysis_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 *
''';

/// Everything a save has to bring back, as comparable text.
String _snapshot(GameTree tree) {
  final lines = <String>[];
  void visit(GameNode node, String path) {
    final eval = node.eval;
    lines.add(
      '$path cp=${eval?.cp} mate=${eval?.mateIn} mated=${eval?.matedSide} '
      'best=${eval?.bestMoveUci} pv=${eval?.pvUci} d=${eval?.depth} '
      'alt=${eval?.alternatives} verdict=${node.classification} '
      'user=${node.isUserMove} x=${node.explanation}',
    );
    for (final child in node.children) {
      visit(child, '$path/${child.move!.uci}');
    }
  }

  visit(tree.root, '');
  return lines.join('\n');
}

/// Scores each position differently, so a misplaced eval shows.
class _VaryingEngine extends FakeEngine {
  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) async {
    callsByFen[fen] = (callsByFen[fen] ?? 0) + 1;
    final scripted = evalsByFen[fen];
    final result =
        scripted ??
        EngineEval(
          cp: (fen.hashCode % 300) - 150,
          bestMoveUci: Chess.fromSetup(Setup.parseFen(fen)).legalMoves.entries
              .where((entry) => entry.value.isNotEmpty)
              .map(
                (entry) =>
                    NormalMove(from: entry.key, to: entry.value.first!).uci,
              )
              .first,
          depth: depth,
        );
    return result;
  }
}

void main() {
  group('encodeAnalysis / applyAnalysis', () {
    test('evals, what-if moves and explanations survive a save', () async {
      final session = AnalysisSession(engine: _VaryingEngine());
      await session.loadPgn(_pgn);
      session.goToNode(session.tree.mainline[3]);
      final whatIf = await session.playMove(Move.parse('d2d4')!);
      await session.fetchExplanation(
        FakeExplainer(model: 'gpt-oss 120B'),
        node: whatIf,
      );
      // A mate, a checkmate and a runner-up, to cover every eval shape.
      final mainline = session.tree.mainline;
      mainline[5].eval = const EngineEval(
        mateIn: -3,
        bestMoveUci: 'e1g1',
        pvUci: ['e1g1', 'f8e7'],
        alternatives: [
          EngineLine(cp: -40, pvUci: ['d2d3']),
          EngineLine(mateIn: 2, pvUci: ['c2c3']),
        ],
        depth: 15,
      );
      mainline[9].eval = const EngineEval.checkmate(
        mated: Side.white,
        depth: 15,
      );

      final text = jsonEncode(
        encodeAnalysis(session.tree, engineName: 'Fake engine', depth: 15),
      );
      final restored = GameTree.fromPgn(_pgn);
      final searched = applyAnalysis(
        restored,
        jsonDecode(text),
        engineName: 'Fake engine',
        minDepth: 15,
      );

      expect(searched, isNotNull);
      String evalsOf(GameTree tree) => _snapshot(
        tree,
      ).replaceAll(RegExp(r'verdict=\S+'), ''); // recomputed, not saved
      expect(evalsOf(restored), evalsOf(session.tree));
      final restoredWhatIf = restored.mainline[3].children.last;
      expect(restoredWhatIf.move!.uci, 'd2d4');
      expect(restoredWhatIf.isUserMove, isTrue);
      // Which model wrote it is kept with it.
      expect(restoredWhatIf.explanation, whatIf.explanation);
      expect(restoredWhatIf.explanation?.model, 'gpt-oss 120B');
      expect(restored.mainline[9].eval!.isCheckmate, isTrue);
    });

    test('another engine, another format or junk restores nothing', () {
      final tree = GameTree.fromPgn(_pgn);
      tree.root.eval = const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15);
      final saved = encodeAnalysis(tree, engineName: 'Stockfish 16', depth: 15);

      for (final bad in <Object?>[
        null,
        'not a map',
        const <Object?>[],
        {...saved, 'version': 99},
        {...saved, 'depth': null},
      ]) {
        final fresh = GameTree.fromPgn(_pgn);
        expect(
          applyAnalysis(fresh, bad, engineName: 'Stockfish 16', minDepth: 15),
          isNull,
        );
        expect(fresh.root.eval, isNull);
      }
      final fresh = GameTree.fromPgn(_pgn);
      expect(
        applyAnalysis(fresh, saved, engineName: 'Stockfish 18', minDepth: 15),
        isNull,
      );
      expect(fresh.root.eval, isNull);
    });

    test('a damaged entry is skipped, the rest is kept', () {
      final fresh = GameTree.fromPgn(_pgn);
      final searched = applyAnalysis(
        fresh,
        {
          'version': analysisFormatVersion,
          'engine': 'E',
          'depth': 15,
          'root': {
            'e': {'cp': 12, 'mate': 3, 'd': 15}, // both: unreadable
            'c': {
              'e2e4': {
                'e': {'cp': 31, 'best': 'e7e5', 'd': 15},
                'c': {
                  'zz': {'e': 1}, // not a move
                  'a1a8': {'u': true}, // not legal here
                  'e7e5': {
                    'e': {'mate': 0, 'd': 15}, // a mate of 0 has no sign
                  },
                },
              },
            },
          },
        },
        engineName: 'E',
        minDepth: 15,
      );

      expect(searched, isEmpty);
      expect(fresh.root.eval, isNull);
      expect(fresh.mainline[0].eval!.cp, 31);
      expect(fresh.mainline[0].children, hasLength(1));
      expect(fresh.mainline[1].eval, isNull);
    });
  });

  group('AnalysisSession with a store', () {
    test('a reopened game is not searched again and reads the same', () async {
      final store = FakeAnalysisStore();
      final first = AnalysisSession(engine: _VaryingEngine(), store: store);
      await first.loadPgn(_pgn, gameId: 'g1');
      first.goToNode(first.tree.mainline[3]);
      final whatIf = await first.playMove(Move.parse('d2d4')!);
      await first.fetchExplanation(FakeExplainer(), node: whatIf);
      await pumpEventQueue();
      expect(store.files.keys, ['g1']);

      final engine = _VaryingEngine();
      final second = AnalysisSession(engine: engine, store: store);
      await second.loadPgn(_pgn, gameId: 'g1');

      expect(engine.totalCalls, 0);
      expect(engine.runnerUpCallsByFen, isEmpty);
      expect(second.isAnalyzing, isFalse);
      expect(_snapshot(second.tree), _snapshot(first.tree));
    });

    test('a reopened game keeps the board at the start', () async {
      // Nothing is searched, so there is nothing for the board to follow.
      final store = FakeAnalysisStore();
      await AnalysisSession(
        engine: _VaryingEngine(),
        store: store,
      ).loadPgn(_pgn, gameId: 'g1');
      await pumpEventQueue();

      final second = AnalysisSession(engine: _VaryingEngine(), store: store);
      final shown = <GameNode>{};
      second.addListener(() => shown.add(second.current));
      await second.loadPgn(_pgn, gameId: 'g1');

      expect(shown, {second.tree.root});
    });

    test('a higher depth setting analyses the game again', () async {
      final store = FakeAnalysisStore();
      final first = AnalysisSession(
        engine: _VaryingEngine(),
        store: store,
        searchDepth: 15,
      );
      await first.loadPgn(_pgn, gameId: 'g1');
      await pumpEventQueue();
      final positions = first.tree.mainline.length + 1;

      // Lower or equal: the deeper analysis is kept, and stays "depth 15".
      final shallow = _VaryingEngine();
      final lower = AnalysisSession(
        engine: shallow,
        store: store,
        searchDepth: 12,
      );
      await lower.loadPgn(_pgn, gameId: 'g1');
      await pumpEventQueue();
      expect(shallow.totalCalls, 0);
      expect(lower.analyzedDepth, 15);

      // Higher: searched again, at the new depth, and saved as such.
      final deep = _VaryingEngine();
      final higher = AnalysisSession(
        engine: deep,
        store: store,
        searchDepth: 20,
      );
      await higher.loadPgn(_pgn, gameId: 'g1');
      await pumpEventQueue();
      expect(deep.totalCalls, positions);
      expect(higher.analyzedDepth, 20);
      expect(savedDepthOf(jsonDecode(store.files['g1']!)), 20);
    });

    test('a game with no id is never saved', () async {
      final store = FakeAnalysisStore();
      final session = AnalysisSession(engine: FakeEngine(), store: store);
      await session.loadPgn(_pgn);
      await pumpEventQueue();
      expect(store.saves, 0);
    });

    test('a store that cannot write costs nothing but the save', () async {
      final session = AnalysisSession(
        engine: FakeEngine(),
        store: _BrokenStore(),
      );
      await session.loadPgn(_pgn, gameId: 'g1');
      await pumpEventQueue();
      expect(session.loadError, isNull);
      expect(session.tree.mainline.last.classification, isNotNull);
    });
  });

  group('AnalysisStore', () {
    test('saves, loads and prunes real files', () async {
      final directory = await Directory.systemTemp.createTemp('analysis');
      addTearDown(() => directory.delete(recursive: true));
      final store = AnalysisStore(directory: () async => directory);

      expect(await store.load('a'), isNull);
      await store.save('a', {'version': 1});
      await store.save('b', {'version': 2});
      await store.save('a', {'version': 3}); // replaced, not appended
      expect(await store.load('a'), {'version': 3});

      File('${directory.path}/c.json').writeAsStringSync('{ not json');
      expect(await store.load('c'), isNull);

      await store.prune({'a'});
      expect(await store.load('a'), {'version': 3});
      expect(await store.load('b'), isNull);
      expect(directory.listSync(), hasLength(1));
    });
  });
}

class _BrokenStore extends AnalysisStore {
  @override
  Future<Object?> load(String gameId) async => null;

  @override
  Future<void> save(String gameId, Map<String, Object?> analysis) =>
      Future.error(const FileSystemException('disk full'));
}
