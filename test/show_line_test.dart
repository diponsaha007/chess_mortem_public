import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/coach_line.dart';
import 'package:chess_mortem/model/concepts/concept.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:chess_mortem/model/concepts/show_line.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/model/move_tags.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:chess_mortem/widgets/coach_bar.dart';
import 'package:chessground/chessground.dart' show Chessboard;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_config_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

ConceptInput _input(
  String fen,
  String san, {
  List<String> betterUci = const [],
  List<String> replyUci = const [],
  double? evalDrop,
  Classification? verdict,
}) {
  final before = Chess.fromSetup(Setup.parseFen(fen));
  final played = before.parseSan(san)!;
  return ConceptInput(
    before: before,
    played: played,
    betterUci: betterUci,
    replyUci: replyUci,
    verdict: verdict,
    tags: tagMove(
      before: before,
      played: played,
      refutationUci: replyUci,
      betterUci: betterUci,
      evalDrop: evalDrop,
    ),
  );
}

Concept _concept(
  ConceptKind kind,
  Frame frame, {
  String? object,
  String evidence = '',
}) => Concept(
  kind,
  frame,
  object: object == null ? null : Square.fromName(object),
  evidence: evidence,
);

/// Légal's mate: 5... Bxd1?? lets White mate with 6. Bxf7+ Ke7 7. Nd5#.
/// The game went 6. Kxd1 instead.
const _legal = '''
[White "Rin Takeda"]
[Black "Alex Moreau"]

1. e4 e5 2. Nf3 d6 3. Bc4 Bg4 4. Nc3 g6 5. Nxe5 Bxd1 6. Kxd1 dxe5 *
''';
const _afterNxe5 =
    'rn1qkbnr/ppp2p1p/3p2p1/4N3/2B1P1b1/2N5/PPPP1PPP/R1BQK2R b KQkq - 0 5';
const _mateLine = ['c4f7', 'e8e7', 'c3d5'];

/// The engine's word on the two positions around 5... Bxd1.
FakeEngine _legalEngine() {
  final mainline = GameTree.fromPgn(_legal).mainline;
  return FakeEngine(
    evalsByFen: {
      mainline[8].position.fen: const EngineEval(
        cp: 193,
        bestMoveUci: 'd6e5',
        pvUci: ['d6e5', 'd1g4', 'g8f6'],
        depth: 15,
      ),
      mainline[9].position.fen: const EngineEval(
        mateIn: 2,
        bestMoveUci: 'c4f7',
        pvUci: _mateLine,
        depth: 15,
      ),
    },
  );
}

/// White to move: Nc7+ forks the king on e8 and the rook on a8.
const _forkFen = 'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1';

void main() {
  group('a mate', () {
    test('is played to the mate', () {
      final input = _input(_afterNxe5, 'Bxd1', replyUci: _mateLine);
      final show = showLineFor(
        input,
        _concept(ConceptKind.checkmate, Frame.allows),
      );
      expect(show?.fromParent, isFalse);
      expect(show?.uci, _mateLine);
    });

    test('past the stored line shows nothing', () {
      final input = _input(
        _afterNxe5,
        'Bxd1',
        replyUci: _mateLine.take(2).toList(),
      );
      expect(
        showLineFor(input, _concept(ConceptKind.checkmate, Frame.allows)),
        isNull,
      );
    });

    test('in one, found by the rules, is its mating move', () {
      // After 6. Bxf7+ the king must go to e7, and Nd5 mates.
      const fen =
          'rn1qkbnr/ppp2B1p/3p2p1/4N3/4P3/2N5/PPPP1PPP/R1BbK2R b KQkq - 0 6';
      final input = _input(fen, 'Ke7');
      final show = showLineFor(
        input,
        _concept(
          ConceptKind.checkmate,
          Frame.allows,
          evidence: 'mate in one: Nd5#',
        ),
      );
      expect(show?.uci, ['c3d5']);
    });

    test('the move delivering it has nothing left to show', () {
      const fen =
          'rn1q1bnr/ppp1kB1p/3p2p1/4N3/4P3/2N5/PPPP1PPP/R1BbK2R w KQ - 1 7';
      final input = _input(fen, 'Nd5#');
      expect(
        showLineFor(input, _concept(ConceptKind.checkmate, Frame.does)),
        isNull,
      );
    });
  });

  group('a hanging piece', () {
    // 3. Ng5?? leaves the knight to the queen on d8.
    const fen =
        'rnbqkbnr/ppp2ppp/3p4/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3';
    const reply = ['d8g5', 'd2d4', 'g5g6'];

    test('is played to the move that takes it', () {
      final input = _input(fen, 'Ng5', replyUci: reply);
      final show = showLineFor(
        input,
        _concept(ConceptKind.hangingPiece, Frame.allows, object: 'g5'),
      );
      expect(show?.uci, ['d8g5']);
    });

    test('that the line never takes shows nothing', () {
      final input = _input(fen, 'Ng5', replyUci: reply);
      expect(
        showLineFor(
          input,
          _concept(ConceptKind.hangingPiece, Frame.allows, object: 'e4'),
        ),
        isNull,
      );
    });
  });

  test('a promotion is played with the recapture that follows it', () {
    // 1... Rh8?? lets the pawn queen, and the rook takes it back.
    final input = _input(
      'r7/P7/8/8/8/8/k7/4K3 b - - 0 1',
      'Rh8',
      replyUci: ['a7a8q', 'h8a8', 'e1d2'],
    );
    final show = showLineFor(
      input,
      _concept(ConceptKind.promotion, Frame.allows, object: 'a8'),
    );
    expect(show?.uci, ['a7a8q', 'h8a8']);
  });

  group('a sacrifice', () {
    // 10. Nxb5 offers the knight for the b-pawns.
    const pgn =
        '1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 '
        '7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 *';
    ConceptInput offer(List<String> reply) {
      final played = GameTree.fromPgn(pgn).mainline.last;
      return ConceptInput(
        before: played.parent!.position,
        played: played.move!,
        replyUci: reply,
        verdict: Classification.brilliant,
      );
    }

    final sacrifice = _concept(ConceptKind.sacrifice, Frame.does);

    test('taken, is played until the material is back', () {
      final show = showLineFor(
        offer(['c6b5', 'c4b5', 'b8d7', 'e1c1']),
        sacrifice,
      );
      expect(show?.uci, ['c6b5', 'c4b5']);
    });

    test('declined by the line, shows nothing', () {
      expect(
        showLineFor(offer(['e7b4', 'b3b4', 'f8b4', 'c2c3']), sacrifice),
        isNull,
      );
    });
  });

  group('a tactic of the better move', () {
    ConceptInput missedFork() => _input(
      _forkFen,
      'Ke2',
      betterUci: ['b5c7', 'e8d7', 'c7a8', 'd7c6', 'e2e3'],
      replyUci: ['a8a5', 'e2e3'],
      evalDrop: 5,
      verdict: Classification.blunder,
    );

    test('starts before the move and stops once the rook is won', () {
      final show = showLineFor(
        missedFork(),
        _concept(ConceptKind.fork, Frame.better, object: 'a8'),
      );
      expect(show?.fromParent, isTrue);
      expect(show?.uci, ['b5c7', 'e8d7', 'c7a8']);
    });

    test('stands in for an idea the line itself cannot show', () {
      final show = showLineFor(
        missedFork(),
        _concept(ConceptKind.developPiece, Frame.does, object: 'e2'),
        also: _concept(ConceptKind.fork, Frame.better, object: 'a8'),
      );
      expect(show?.uci, ['b5c7', 'e8d7', 'c7a8']);
    });

    test('that wins nothing shows nothing', () {
      final quiet = _input(
        _forkFen,
        'Ke2',
        betterUci: ['b5c3', 'a8a5'],
        replyUci: ['a8a5'],
        evalDrop: 0.5,
      );
      expect(
        showLineFor(quiet, _concept(ConceptKind.fork, Frame.better)),
        isNull,
      );
    });
  });

  group('nothing to show', () {
    final input = _input(_afterNxe5, 'Bxd1', replyUci: _mateLine);

    test('for what the move threatens', () {
      expect(
        showLineFor(input, _concept(ConceptKind.fork, Frame.threatens)),
        isNull,
      );
    });

    test('for a positional idea', () {
      expect(
        showLineFor(
          input,
          _concept(ConceptKind.developPiece, Frame.does, object: 'd1'),
        ),
        isNull,
      );
    });

    test('for a capture the move already made', () {
      expect(
        showLineFor(
          input,
          _concept(ConceptKind.captureFree, Frame.does, object: 'd1'),
        ),
        isNull,
      );
    });
  });

  group('on a game', () {
    test('the coach line names the mate, and Show plays it', () async {
      final session = AnalysisSession(engine: _legalEngine());
      await session.loadPgn(_legal);
      final blunder = session.tree.mainline[9];
      expect(blunder.classification, Classification.blunder);
      expect(coachLine(blunder, playful: false), contains('mate'));

      final show = session.showLineFor(blunder);
      expect(show?.fromParent, isFalse);
      expect(show?.uci, _mateLine);
    });

    test('the line hangs under the move and is searched', () async {
      final engine = _legalEngine();
      final session = AnalysisSession(engine: engine);
      await session.loadPgn(_legal);
      final blunder = session.tree.mainline[9];

      final line = session.addShowLine(blunder);
      expect(line.map((n) => n.san), ['Bxf7+', 'Ke7', 'Nd5#']);
      expect(identical(line.first.parent, blunder), isTrue);
      // The game stays the mainline.
      expect(blunder.children.first.san, 'Kxd1');

      await pumpEventQueue();
      expect(line.every((n) => n.eval != null), isTrue);
      for (final node in line) {
        expect(engine.callsByFen[node.position.fen], 1);
      }

      // Asked again, the same positions: nothing added, nothing searched.
      final again = session.addShowLine(blunder);
      expect(again.length, 3);
      expect(again.indexed.every((e) => identical(e.$2, line[e.$1])), isTrue);
      await pumpEventQueue();
      for (final node in line) {
        expect(engine.callsByFen[node.position.fen], 1);
      }
    });

    test('a line the game played walks the mainline', () async {
      const played =
          '1. e4 e5 2. Nf3 d6 3. Bc4 Bg4 4. Nc3 g6 5. Nxe5 Bxd1 '
          '6. Bxf7+ Ke7 7. Nd5# *';
      final mainline = GameTree.fromPgn(played).mainline;
      final session = AnalysisSession(
        engine: FakeEngine(
          evalsByFen: {
            mainline[8].position.fen: const EngineEval(
              cp: 193,
              bestMoveUci: 'd6e5',
              pvUci: ['d6e5', 'd1g4'],
              depth: 15,
            ),
            mainline[9].position.fen: const EngineEval(
              mateIn: 2,
              bestMoveUci: 'c4f7',
              pvUci: _mateLine,
              depth: 15,
            ),
          },
        ),
      );
      await session.loadPgn(played);
      final tree = session.tree.mainline;

      final line = session.addShowLine(tree[9]);
      expect(line.length, 3);
      for (final (i, node) in line.indexed) {
        expect(identical(node, tree[10 + i]), isTrue);
      }
      expect(tree[9].children.length, 1);
    });

    test('a book move or the start shows nothing', () async {
      final session = AnalysisSession(engine: _legalEngine());
      await session.loadPgn(_legal);
      expect(session.showLineFor(session.tree.root), isNull);
      expect(session.addShowLine(session.tree.root), isEmpty);
    });
  });

  group('on the board', () {
    Future<AnalysisSession> analysed() async {
      final session = AnalysisSession(engine: _legalEngine());
      await session.loadPgn(_legal);
      return session;
    }

    Future<void> pumpBoard(WidgetTester tester, AnalysisSession session) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(hasKey: true),
            explainerFactory: (_) => FakeExplainer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Lets the debounced buzz and better-line timers run out.
    Future<void> settleTimers(WidgetTester tester) =>
        tester.pump(const Duration(seconds: 2));

    testWidgets('Show plays the line a move at a time, then offers Back', (
      tester,
    ) async {
      final session = await analysed();
      final blunder = session.tree.mainline[9];
      session.goToNode(blunder);
      await pumpBoard(tester, session);
      final boardSize = tester.getSize(find.byType(Chessboard));
      expect(find.textContaining('Best:'), findsNothing);

      await tester.tap(find.byKey(CoachBar.showKey));
      await tester.pump();
      expect(session.current, same(blunder));
      expect(find.text('Stop'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      expect(session.current.san, 'Bxf7+');
      await tester.pump(const Duration(milliseconds: 800));
      expect(session.current.san, 'Ke7');
      await tester.pump(const Duration(milliseconds: 800));
      expect(session.current.san, 'Nd5#');
      await tester.pump();
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Replay'), findsOneWidget);
      expect(tester.getSize(find.byType(Chessboard)), boardSize);

      await tester.tap(find.byTooltip('Back to the move'));
      await tester.pumpAndSettle();
      expect(session.current, same(blunder));
      expect(find.text('Show'), findsOneWidget);
      await settleTimers(tester);
    });

    testWidgets('Stop holds the position; a step of the user ends the show', (
      tester,
    ) async {
      final session = await analysed();
      final blunder = session.tree.mainline[9];
      session.goToNode(blunder);
      await pumpBoard(tester, session);

      await tester.tap(find.byKey(CoachBar.showKey));
      await tester.pump(const Duration(milliseconds: 400));
      expect(session.current.san, 'Bxf7+');
      await tester.tap(find.text('Stop'));
      await tester.pump(const Duration(seconds: 2));
      expect(session.current.san, 'Bxf7+');
      expect(find.text('Replay'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous move'));
      await tester.pump();
      expect(session.current, same(blunder));
      expect(find.text('Replay'), findsNothing);
      expect(find.text('Show'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(session.current, same(blunder));
      await settleTimers(tester);
    });

    testWidgets('the sheet plays the same line', (tester) async {
      final session = await analysed();
      final blunder = session.tree.mainline[9];
      session.goToNode(blunder);
      await pumpBoard(tester, session);

      await tester.tap(find.byTooltip('Why this move?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show on board'));
      await tester.pumpAndSettle();
      expect(find.text('Show on board'), findsNothing);
      expect(session.current.san, 'Bxf7+');
      await tester.pump(const Duration(seconds: 2));
      expect(session.current.san, 'Nd5#');
      await settleTimers(tester);
    });

    for (final size in const [Size(320, 568), Size(740, 360)]) {
      testWidgets('every state fits at ${size.width}x${size.height}', (
        tester,
      ) async {
        final session = await analysed();
        session.goToNode(session.tree.mainline[9]);
        await pumpBoard(tester, session);
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();

        // An overflow is reported as an exception after a pump.
        await tester.tap(find.byKey(CoachBar.showKey));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 2));
        expect(session.current.san, 'Nd5#');
        expect(tester.takeException(), isNull);
        await settleTimers(tester);
      });
    }

    testWidgets('a line naming nothing to show has no button', (tester) async {
      final session = await analysed();
      session.goToNode(session.tree.mainline[0]);
      await pumpBoard(tester, session);

      expect(find.text('Show'), findsNothing);
      await settleTimers(tester);
    });
  });
}
