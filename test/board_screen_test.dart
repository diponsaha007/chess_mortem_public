import 'dart:async';
import 'dart:io' as io;

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/appearance/appearance_controller.dart';
import 'package:chess_mortem/appearance/board_appearance.dart';
import 'package:chess_mortem/engine/engine.dart';
import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/move_explainer.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/platform/share_game.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:chess_mortem/widgets/coach_bar.dart';
import 'package:chess_mortem/widgets/explanation_sheet.dart';
import 'package:chess_mortem/widgets/material_bar.dart';
import 'package:chess_mortem/widgets/move_list.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';
import 'fakes/fake_config_store.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 *
''';

/// Sizes worth checking: a small phone, a tall phone, and landscape.
const _sizes = [Size(320, 568), Size(360, 740), Size(740, 360)];

/// A legal game of [pairs] knight shuffles — long enough to make the move
/// list scroll without needing a real game transcript.
String _longPgn(int pairs) {
  final moves = [
    for (var i = 1; i <= pairs; i++) i.isOdd ? '$i. Nf3 Nf6' : '$i. Ng1 Ng8',
  ];
  return '[Event "Test"]\n\n${moves.join(' ')} *\n';
}

/// The verdict badge drawn over the board (not the ones in the move strips).
final _boardBadge = find.byKey(boardVerdictBadgeKey);

/// Asserts the board's verdict badge sits on [square]: drawn in its top-right
/// corner, its centre lands inside that square. White is at the bottom.
void expectBadgedOn(WidgetTester tester, Square square) {
  final board = tester.getRect(find.byType(Chessboard));
  final squareSize = board.width / 8;
  final rect = Rect.fromLTWH(
    board.left + square.file.value * squareSize,
    board.top + (7 - square.rank.value) * squareSize,
    squareSize,
    squareSize,
  );

  expect(_boardBadge, findsOneWidget, reason: 'expected exactly one badge');
  final centre = tester.getCenter(_boardBadge);
  expect(
    rect.contains(centre),
    isTrue,
    reason:
        'badge centre $centre is not on $square (that square is $rect) — '
        'the square-to-pixel arithmetic is wrong',
  );
}

void main() {
  Future<AnalysisSession> loadedSession() async {
    final session = AnalysisSession(engine: FakeEngine());
    await session.loadPgn(_pgn);
    return session;
  }

  Future<void> pumpBoard(
    WidgetTester tester,
    AnalysisSession session, {
    MoveExplainer? explainer,
    bool hasApiKey = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BoardScreen(
          session: session,
          configStore: FakeConfigStore(hasKey: hasApiKey),
          explainerFactory: (_) => explainer ?? FakeExplainer(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in _sizes) {
    testWidgets(
      'lays out without overflowing at ${size.width}x${size.height}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpBoard(tester, await loadedSession());

        // A RenderFlex overflow is reported as a framework exception, so a
        // clean pump is the assertion.
        expect(tester.takeException(), isNull);
        expect(find.byType(MoveList), findsOne);
        // Both material strips are part of the board block's height budget, so
        // they are what an overflow would show up in first.
        expect(find.byType(MaterialBar), findsNWidgets(2));
      },
    );
  }

  group('material advantage', () {
    /// The strip belonging to whichever player is at the bottom.
    MaterialBar bottomStrip(WidgetTester tester) =>
        tester.widgetList<MaterialBar>(find.byType(MaterialBar)).last;

    testWidgets('a level position shows no number', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBoard(tester, await loadedSession());

      // Scoped to the strips: the eval bar draws its own "+0.0" alongside.
      expect(
        find.descendant(
          of: find.byType(MaterialBar),
          matching: find.textContaining('+'),
        ),
        findsNothing,
      );
    });

    testWidgets('the winning side is named and the number appears once', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(engine: FakeEngine());
      // 3.Bxf7+ Kxf7 leaves Black two ahead.
      await session.loadPgn(
        '[Event "Test"]\n\n1. e4 e5 2. Bc4 Nf6 3. Bxf7+ Kxf7 *\n',
      );
      await pumpBoard(tester, session);
      session.goToNode(session.tree.mainline.last);
      await tester.pumpAndSettle();

      expect(find.text('+2'), findsOne, reason: 'once, on the leader\'s strip');
      expect(bottomStrip(tester).side, Side.white);
    });

    testWidgets('the strips show a difference, not two capture lists', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(engine: FakeEngine());
      // A pawn for a pawn — nothing to report on either side.
      await session.loadPgn('[Event "Test"]\n\n1. e4 d5 2. exd5 Qxd5 *\n');
      await pumpBoard(tester, session);
      session.goToNode(session.tree.mainline.last);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(MaterialBar),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
    });

    testWidgets('each strip carries its own player from the PGN', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(
        '[Event "Test"]\n[White "Alice"]\n[Black "Bob"]\n[WhiteElo "1500"]'
        '\n\n1. e4 e5 *\n',
      );
      await pumpBoard(tester, session);

      expect(find.text('Alice  1500'), findsOne);
      expect(find.text('Bob'), findsOne);
    });

    testWidgets('an unnamed player leaves the strip blank', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBoard(tester, await loadedSession());

      expect(
        find.descendant(
          of: find.byType(MaterialBar),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('a game you played as Black opens from Black\'s side', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(engine: FakeEngine(), playerName: 'Bob');
      await session.loadPgn(
        '[Event "Test"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *\n',
      );
      await pumpBoard(tester, session);

      expect(bottomStrip(tester).side, Side.black);
    });

    testWidgets('a game naming nobody you opens from White\'s side', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(
        engine: FakeEngine(),
        playerName: 'Carol',
      );
      await session.loadPgn(
        '[Event "Test"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *\n',
      );
      await pumpBoard(tester, session);

      expect(bottomStrip(tester).side, Side.white);
    });

    testWidgets('a new game turns the board back to your side', (tester) async {
      // The flip is per-game view state: it survives navigating the game it
      // was made in, and a freshly loaded PGN starts from the user's chair.
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = AnalysisSession(engine: FakeEngine(), playerName: 'Bob');
      await session.loadPgn('[Event "Test"]\n[White "Bob"]\n\n1. e4 e5 *\n');
      await pumpBoard(tester, session);
      expect(bottomStrip(tester).side, Side.white);

      await tester.tap(find.byTooltip('Flip board'));
      await tester.pumpAndSettle();
      expect(bottomStrip(tester).side, Side.black);

      await session.loadPgn('[Event "Test"]\n[White "Bob"]\n\n1. d4 d5 *\n');
      await tester.pumpAndSettle();

      expect(bottomStrip(tester).side, Side.white);
    });

    testWidgets('flipping the board swaps the strips', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBoard(tester, await loadedSession());
      expect(bottomStrip(tester).side, Side.white);

      await tester.tap(find.byTooltip('Flip board'));
      await tester.pumpAndSettle();

      expect(bottomStrip(tester).side, Side.black);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('flipping the board swaps the coordinate background', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    await pumpBoard(tester, session);

    expect(find.byKey(const ValueKey('coordinates-white')), findsOne);

    await tester.tap(find.byTooltip('Flip board'));
    await tester.pumpAndSettle();

    // The keys are what force chessground to replace (and so repaint) the
    // coordinate background instead of leaving stale a-h/1-8 labels.
    expect(find.byKey(const ValueKey('coordinates-black')), findsOne);
    expect(find.byKey(const ValueKey('coordinates-white')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the board, strips and move list wear the chosen appearance', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final appearance = AppearanceController();
    final session = await loadedSession();

    await tester.pumpWidget(
      AppearanceScope(
        controller: appearance,
        child: MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(hasKey: true),
            explainerFactory: (_) => FakeExplainer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ChessboardSettings settings() =>
        tester.widget<Chessboard>(find.byType(Chessboard)).settings;
    expect(settings().pieceAssets, PieceSet.cburnettAssets);

    // An image board: the coordinate trap must survive it.
    appearance.setBoardTheme(BoardTheme.wood);
    appearance.setPieceStyle(PieceStyle.merida);
    await tester.pumpAndSettle();

    expect(settings().pieceAssets, PieceSet.meridaAssets);
    expect(
      settings().colorScheme.lightSquare,
      BoardTheme.wood.scheme.lightSquare,
    );
    expect(find.byKey(coordinatesWhiteKey), findsOne);
    // The knight glyphs in the move strip come from the same set.
    final knight = PieceSet.meridaAssets[PieceKind.whiteKnight]!;
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image == knight),
      findsWidgets,
    );

    await tester.tap(find.byTooltip('Flip board'));
    await tester.pumpAndSettle();
    expect(find.byKey(coordinatesBlackKey), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the move list scrolls the current move into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // A long game, so the move list is taller than its panel.
    final session = AnalysisSession(engine: FakeEngine());
    await session.loadPgn(_longPgn(30));
    await pumpBoard(tester, session);

    ScrollPosition scrollPosition() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(MoveList),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    expect(scrollPosition().pixels, 0);
    expect(
      scrollPosition().maxScrollExtent,
      greaterThan(0),
      reason: 'the list must be scrollable for this test to mean anything',
    );

    session.goToNode(session.tree.mainline.last);
    await tester.pumpAndSettle();

    expect(scrollPosition().pixels, greaterThan(0));
  });

  testWidgets('the explain button is disabled at the root', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    await pumpBoard(tester, session);

    // The cursor starts at the root, which has no move to explain.
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.psychology_alt),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);

    session.goForward();
    await tester.pumpAndSettle();

    final enabled = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.psychology_alt),
        matching: find.byType(IconButton),
      ),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('the explain icon stays put while the answer is on its way', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    final gate = Completer<void>();
    await pumpBoard(tester, session, explainer: FakeExplainer()..gate = gate);
    session.goForward();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain more'));
    await tester.pump();

    // A spinner in its place would make the button the user just pressed
    // seem to vanish, so it stays and only greys out.
    expect(find.byIcon(Icons.psychology_alt), findsWidgets);
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.psychology_alt),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Why? opens a sheet titled by the coach line; the LLM only on request',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = await loadedSession();
      final explainer = FakeExplainer(response: 'Develops and hits e5.');
      await pumpBoard(tester, session, explainer: explainer);
      session.goForward();
      await tester.pumpAndSettle();
      final listRectBefore = tester.getRect(find.byType(MoveList));
      final line = session.coachLineFor(session.current);

      await tester.tap(find.byTooltip('Why this move?'));
      await tester.pumpAndSettle();

      // The sheet repeats the bar's line and asks nothing by itself.
      expect(_inSheet(line), findsOne);
      expect(find.text('White played e4 · Best'), findsOne);
      expect(explainer.calls, 0);

      await tester.tap(find.text('Explain more'));
      await tester.pumpAndSettle();
      expect(explainer.calls, 1);
      expect(_inSheet('Develops and hits e5.'), findsOne);
      // The answer goes under the coach line, never in its place.
      expect(_inSheet(line), findsOne);
      // The sheet overlays the board; the move list must not have moved.
      expect(tester.getRect(find.byType(MoveList)), listRectBefore);
    },
  );

  testWidgets('an answer can be asked again from the sheet', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    final explainer = FakeExplainer(response: 'Develops and hits e5.');
    await pumpBoard(tester, session, explainer: explainer);
    session.goForward();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain more'));
    await tester.pumpAndSettle();

    // As if the key had been switched to another model.
    explainer.response = 'Takes the centre.';
    await tester.tap(find.text('Ask again'));
    await tester.pumpAndSettle();

    expect(explainer.calls, 2);
    expect(_inSheet('Takes the centre.'), findsOne);
    expect(find.text('Develops and hits e5.'), findsNothing);
  });

  testWidgets('nothing is sent to a model until someone asks', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    final explainer = FakeExplainer();
    await pumpBoard(tester, session, explainer: explainer);

    session.goForward();
    await tester.pumpAndSettle();
    session.goForward();
    await tester.pumpAndSettle();

    // The coach line is the app's own: no background fetch.
    expect(explainer.calls, 0);
    expect(_inCoachBar(session.coachLineFor(session.current)), findsOne);
  });

  testWidgets('a book move keeps its own name as the title', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    session.tree.mainline.first.openingName = 'C20 King\'s Pawn Game';
    await pumpBoard(
      tester,
      session,
      explainer: FakeExplainer(response: 'Both sides head for the centre.'),
    );

    session.goForward();
    await tester.pumpAndSettle();
    expect(_inCoachBar('C20 King\'s Pawn Game'), findsOne);

    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain more'));
    await tester.pumpAndSettle();

    // The sheet agrees with the bar, and the model's answer is under it.
    expect(_inSheet('C20 King\'s Pawn Game'), findsOne);
    expect(_inSheet('Both sides head for the centre.'), findsOne);
  });

  testWidgets('a blunder shows the line that should have been played', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    await pumpBoard(tester, session);

    session.goForward();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();

    // Naming one better move says what to play; the line says why it was
    // better. Numbered from the position the move was played in.
    expect(_inSheet('Better was'), findsOne);
    expect(_inSheet('1. d4 d5 2. c4 e6 3. Nc3'), findsOne);
  });

  testWidgets('landing on a blunder puts the better line on the board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    await pumpBoard(tester, session, hasApiKey: false);

    session.goForward(); // onto 1. e4, the blunder
    await tester.pump(const Duration(milliseconds: 400)); // past the debounce
    await tester.pumpAndSettle();

    // Not text in a sheet: a real variation branch, so the line can be
    // stepped through on the board like any what-if move.
    expect(session.tree.root.children, hasLength(2));
    final better = session.tree.root.children[1];
    expect(better.san, 'd4');

    // The move list mounts it as a strip because it is an alternative to the
    // move the cursor is on. A chip is a Text.rich (the move number is bold),
    // so a plain find.text never sees it.
    expect(
      find.descendant(
        of: find.byType(MoveList),
        matching: find.textContaining('d4'),
      ),
      findsOneWidget,
    );

    // And it is playable: stepping into it puts that move on the board,
    // badged with its own verdict like any other.
    session.goToNode(better);
    await tester.pumpAndSettle();
    expectBadgedOn(tester, Square.d4);
  });

  testWidgets('stepping straight past a mistake adds nothing', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    await pumpBoard(tester, session, hasApiKey: false);

    // Debounced for the same reason the explanation is: a branch and five
    // engine searches for a move nobody stopped on is pure cost.
    session.goForward();
    await tester.pump(const Duration(milliseconds: 100));
    session.goForward();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(session.tree.root.children, hasLength(1));
  });

  testWidgets('the board follows the analysis without building better lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final initial = Chess.initial;
    final afterE4 = initial.play(initial.parseSan('e4')!).fen;
    // Answers the root and 1. e4, a blunder, then holds 1...e5.
    final engine = _GatedEngine(
      stopAfter: 2,
      evalsByFen: {
        initial.fen: const EngineEval(
          cp: 300,
          bestMoveUci: 'd2d4',
          pvUci: ['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3'],
          depth: 15,
        ),
        afterE4: const EngineEval(cp: -400, bestMoveUci: 'e7e5', depth: 15),
      },
    );
    final session = AnalysisSession(engine: engine);
    unawaited(session.loadPgn(_pgn));
    // The progress spinner never settles mid-sweep, so frames are pumped.
    await tester.pumpWidget(
      MaterialApp(
        home: BoardScreen(
          session: session,
          configStore: FakeConfigStore(hasKey: false),
          explainerFactory: (_) => FakeExplainer(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // past the debounce
    await tester.pump(const Duration(milliseconds: 400)); // past the animation

    // The board shows the blunder the engine just finished, but its better
    // line would queue engine searches in the middle of the sweep.
    expect(session.current.san, 'e4');
    expectBadgedOn(tester, Square.e4);
    expect(session.tree.root.children, hasLength(1));

    engine.gate.complete();
    await tester.pumpAndSettle();
    expect(session.isAnalyzing, isFalse);
    expect(session.current, session.tree.root);
  });

  testWidgets('a good move gets no better line — there is nothing to show', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The fake engine wants e2e4 everywhere, so 1.e4 is Best.
    final session = await loadedSession();
    await pumpBoard(tester, session);

    session.goForward();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();

    expect(_inSheet('Better was'), findsNothing);
  });

  testWidgets('without an API key the coach line and the sheet still work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Engine says White was winning before 1.e4 and lost after it.
    final initial = Chess.initial;
    final afterE4 = initial.play(initial.parseSan('e4')!).fen;
    final explainer = FakeExplainer();
    final session = AnalysisSession(
      engine: FakeEngine(
        evalsByFen: {
          initial.fen: const EngineEval(
            cp: 300,
            bestMoveUci: 'd2d4',
            depth: 15,
          ),
          afterE4: const EngineEval(cp: -400, bestMoveUci: 'e7e5', depth: 15),
        },
      ),
    );
    await session.loadPgn(_pgn);
    await pumpBoard(tester, session, explainer: explainer, hasApiKey: false);

    session.goForward();
    await tester.pumpAndSettle();

    // Nothing may be sent anywhere without a key, and the bar still says
    // something: the verdict and the app's own line.
    final line = session.coachLineFor(session.current);
    expect(explainer.calls, 0);
    expect(find.textContaining('Blunder'), findsOne);
    expect(_inCoachBar(line), findsOne);

    // The sheet opens without a key; only "Explain more" asks for one.
    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    expect(_inSheet(line), findsOne);
    await tester.tap(find.text('Explain more'));
    await tester.pumpAndSettle();
    expect(find.text('Open settings'), findsOne);
    expect(explainer.calls, 0);
  });

  testWidgets('the played move is badged with its verdict on the board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession(); // engine wants e2e4 everywhere
    await pumpBoard(tester, session, hasApiKey: false);

    expect(
      _boardBadge,
      findsNothing,
      reason: 'the starting position has no move to judge',
    );

    session.goForward();
    await tester.pumpAndSettle();

    expectBadgedOn(tester, Square.e4);
    // Literally the same widget the move strips and the summary draw, so the
    // board can never end up labelling a move differently from them.
    expect(
      tester
          .widget<ClassificationBadge>(
            find.descendant(
              of: _boardBadge,
              matching: find.byType(ClassificationBadge),
            ),
          )
          .classification,
      Classification.best,
    );
  });

  testWidgets('castling is badged on the king, not the rook\'s corner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    await pumpBoard(tester, session, hasApiKey: false);

    final castling = session.tree.mainline.firstWhere((n) => n.san == 'O-O');
    session.goToNode(castling);
    await tester.pumpAndSettle();

    // dartchess encodes O-O as king-takes-own-rook: `to` is the corner.
    expect((castling.move! as NormalMove).to, Square.h1);
    expectBadgedOn(tester, Square.g1);
  });

  testWidgets('a what-if move shows the opponent\'s best reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final initial = Chess.initial;
    final afterD4 = initial.play(initial.parseSan('d4')!).fen;
    final session = AnalysisSession(
      engine: FakeEngine(
        evalsByFen: {
          afterD4: const EngineEval(cp: 20, bestMoveUci: 'd7d5', depth: 15),
        },
      ),
    );
    await session.loadPgn(_pgn);
    await pumpBoard(tester, session, hasApiKey: false);

    // 1.d4 is not the game's move, so this opens a variation.
    await session.playMove(NormalMove(from: Square.d2, to: Square.d4));
    await tester.pumpAndSettle();

    // "Best" is still what to play INSTEAD; "Reply" is what the opponent
    // does about it, which is the whole point of playing a what-if move.
    expect(find.text('Best: e4'), findsOne);
    expect(find.text('Reply: d5'), findsOne);
  });

  testWidgets('the mainline shows the reply too, and draws both arrows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final initial = Chess.initial;
    final afterE4 = initial.play(initial.parseSan('e4')!).fen;
    final session = AnalysisSession(
      engine: FakeEngine(
        evalsByFen: {
          // The engine wanted d4 in the starting position, and answers 1.e4
          // with 1...c5 — which is NOT the 1...e5 the game actually played.
          Chess.initial.fen: const EngineEval(
            cp: 30,
            bestMoveUci: 'd2d4',
            depth: 15,
          ),
          afterE4: const EngineEval(cp: 20, bestMoveUci: 'c7c5', depth: 15),
        },
      ),
    );
    await session.loadPgn(_pgn);
    await pumpBoard(tester, session, hasApiKey: false);

    session.goForward();
    await tester.pumpAndSettle();

    // Mainline and what-if lines behave identically: the reply is worth
    // knowing either way, and the move list only shows what WAS played.
    expect(find.text('Best: d4'), findsOne);
    expect(find.text('Reply: c5'), findsOne);

    final shapes = tester.widget<Chessboard>(find.byType(Chessboard)).shapes;
    expect(
      shapes.whereType<Arrow>().map((a) => '${a.orig.name}${a.dest.name}'),
      containsAll(['d2d4', 'c7c5']),
    );
  });

  testWidgets('the app bar reaches the summary and counts the analysis', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = _GatedEngine(stopAfter: 2);
    final session = AnalysisSession(engine: engine);
    unawaited(session.loadPgn(_pgn));
    await tester.pumpWidget(
      MaterialApp(
        home: BoardScreen(
          session: session,
          configStore: FakeConfigStore(hasKey: false),
          explainerFactory: (_) => FakeExplainer(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The summary is read after every game, so it is one tap away.
    expect(find.byTooltip('Game summary'), findsOne);
    // Moves, not plies: the game is 5 moves long, and the engine is one
    // move in. "2 of 11" for the same game is what a ply count reads like.
    expect(find.text('1/5'), findsOne);

    engine.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('1/5'), findsNothing);
  });

  testWidgets('the coach bar names the move that should have been played', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The engine wants d4 everywhere, so e4 was not the best move and the
    // bar must suggest the PARENT position's choice, not the opponent's.
    final session = AnalysisSession(
      engine: FakeEngine()
        ..fallback = const EngineEval(cp: 30, bestMoveUci: 'd2d4', depth: 15),
    );
    await session.loadPgn(_pgn);
    await pumpBoard(tester, session);

    session.goForward();
    await tester.pumpAndSettle();

    expect(find.text('Best: d4'), findsOne);
  });

  testWidgets('a failed explanation says so and retries on a tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    final explainer = FakeExplainer(response: 'Develops and hits e5.')
      ..throwOnce = Exception('offline');
    await pumpBoard(tester, session, explainer: explainer);
    session.goForward();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain more'));
    await tester.pumpAndSettle();
    expect(_inSheet("Couldn't get an explanation."), findsOne);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(_inSheet('Develops and hits e5.'), findsOne);
    expect(explainer.calls, 2);
  });

  testWidgets(
    'one explainer serves every move, and is disposed with the screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = await loadedSession();
      final explainer = FakeExplainer(response: 'Develops and hits e5.');
      var built = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(),
            explainerFactory: (_) {
              built++;
              return explainer;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Two moves explained on request. Each explainer owns an HTTP
      // client, so one per request would throw away the keep-alive
      // connection and re-handshake TLS for every explanation.
      for (var i = 0; i < 2; i++) {
        session.goForward();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Why this move?'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Explain more'));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(ExplanationSheet))).pop();
        await tester.pumpAndSettle();
      }
      expect(explainer.calls, 2);
      expect(built, 1);

      // Leaving the screen releases that client rather than leaking it.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(explainer.disposed, isTrue);
    },
  );

  group('Share', () {
    const players =
        '[White "Ann Example"]\n[Black "Ben Sample"]\n\n1. e4 e5 *\n';

    Future<_FakeSharer> pumpAndShare(
      WidgetTester tester, {
      required bool hasSheet,
      bool sharesFiles = false,
      AnalysisSession? session,
      io.Directory? cache,
    }) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      if (session == null) {
        session = AnalysisSession(engine: FakeEngine());
        await session.loadPgn(players);
      }
      final sharer = _FakeSharer(hasSheet: hasSheet, sharesFiles: sharesFiles);
      await tester.pumpWidget(
        MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(hasKey: false),
            sharer: sharer,
            cacheDirectory: () async => cache ?? io.Directory.systemTemp,
          ),
        ),
      );
      // Not pumpAndSettle: a sweep still running keeps its spinner turning.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      await settle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle();
      await tester.tap(find.text('Share'));
      await settle();
      return sharer;
    }

    testWidgets('sends the PGN as it was imported, titled by the players', (
      tester,
    ) async {
      final sharer = await pumpAndShare(tester, hasSheet: true);
      expect(sharer.shared, [players]);
      expect(sharer.subject, 'Ann Example vs Ben Sample');
      expect(find.text('PGN copied'), findsNothing);
    });

    testWidgets('copies it where there is no share sheet', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpAndShare(tester, hasSheet: false);
      expect(copied, players);
      expect(find.text('PGN copied'), findsOne);
    });

    testWidgets('asks PGN or GIF where files can be shared', (tester) async {
      final sharer = await pumpAndShare(
        tester,
        hasSheet: true,
        sharesFiles: true,
      );
      expect(sharer.shared, isEmpty);
      expect(find.text('PGN'), findsOne);
      expect(find.text('GIF'), findsOne);

      await tester.tap(find.text('PGN'));
      await tester.pumpAndSettle();
      expect(sharer.shared, [players]);
      expect(sharer.files, isEmpty);
    });

    testWidgets('the GIF waits for the analysis', (tester) async {
      final engine = _GatedEngine(stopAfter: 1);
      final session = AnalysisSession(engine: engine);
      unawaited(session.loadPgn(players));
      final sharer = await pumpAndShare(
        tester,
        hasSheet: true,
        sharesFiles: true,
        session: session,
      );
      expect(find.text('After the analysis finishes'), findsOne);
      final gif = tester.widget<ListTile>(
        find.ancestor(of: find.text('GIF'), matching: find.byType(ListTile)),
      );
      expect(gif.enabled, isFalse);
      expect(sharer.files, isEmpty);
      engine.gate.complete();
    });

    testWidgets('shares the analysed game as a GIF file', (tester) async {
      final cache = io.Directory.systemTemp.createTempSync('gif_share_test');
      addTearDown(() => cache.deleteSync(recursive: true));
      final sharer = await pumpAndShare(
        tester,
        hasSheet: true,
        sharesFiles: true,
        cache: cache,
      );
      await tester.tap(find.text('GIF'));
      await tester.pump();
      expect(find.text('Making GIF…'), findsOne);

      // Decoding the pieces and the encoder's isolate are real work.
      for (var i = 0; i < 200 && sharer.files.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.text('Making GIF…'), findsNothing);
      expect(sharer.files, hasLength(1));
      final path = sharer.files.single;
      expect(path, '${cache.path}/shared/Ann_Example-vs-Ben_Sample.gif');
      expect(sharer.mimeType, 'image/gif');
      expect(sharer.subject, 'Ann Example vs Ben Sample');
      final bytes = io.File(path).readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(6)), 'GIF89a');
    });
  });

  testWidgets('an explainer still being built when the screen closes is '
      'disposed too', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = await loadedSession();
    final explainer = FakeExplainer();
    final store = _SlowConfigStore();

    await tester.pumpWidget(
      MaterialApp(
        home: BoardScreen(
          session: session,
          configStore: store,
          explainerFactory: (_) => explainer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    session.goForward();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Why this move?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain more')); // waits on the key
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    store.gate.complete();
    await tester.pumpAndSettle();
    expect(explainer.disposed, isTrue);
  });
}

/// A [PgnSharer] that records what it was given; without a sheet it shares
/// nothing, like a platform with no share sheet.
class _FakeSharer extends GameSharer {
  _FakeSharer({required this.hasSheet, this.sharesFiles = false});

  final bool hasSheet;
  final shared = <String>[];
  final files = <String>[];
  String? subject;
  String? mimeType;

  @override
  final bool sharesFiles;

  @override
  Future<bool> shareFile(
    String path, {
    required String mimeType,
    String? subject,
  }) async {
    if (!hasSheet) return false;
    files.add(path);
    this.mimeType = mimeType;
    this.subject = subject;
    return true;
  }

  @override
  Future<bool> share(String pgn, {String? subject}) async {
    if (!hasSheet) return false;
    shared.add(pgn);
    this.subject = subject;
    return true;
  }
}

/// A [FakeConfigStore] whose load waits for [gate].
class _SlowConfigStore extends FakeConfigStore {
  final gate = Completer<void>();

  @override
  Future<LlmConfig> load() async {
    await gate.future;
    return super.load();
  }
}

/// An engine that stops answering after [stopAfter] positions, so a test can
/// look at the screen mid-analysis.
class _GatedEngine implements ChessEngine {
  _GatedEngine({required this.stopAfter, this.evalsByFen = const {}});

  final int stopAfter;
  final Map<String, EngineEval> evalsByFen;
  final gate = Completer<void>();
  int calls = 0;

  @override
  String get name => 'Gated engine';

  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) async {
    calls++;
    if (calls > stopAfter) await gate.future;
    return evalsByFen[fen] ??
        const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15);
  }

  @override
  Future<EngineLine?> evaluateRunnerUp(
    String fen, {
    required List<String> searchMoves,
    int depth = 15,
  }) async => null;

  @override
  Future<void> dispose() async {}
}

/// The coach bar's line. It is a Text.rich (the verdict is coloured), so a
/// plain find.text never sees it.
Finder _inCoachBar(String text) => find.descendant(
  of: find.byType(CoachBar),
  matching: find.textContaining(text),
);

/// The sheet's copy of a text, as opposed to the coach bar's.
Finder _inSheet(String text) => find.descendant(
  of: find.byType(ExplanationSheet),
  matching: find.text(text),
);
