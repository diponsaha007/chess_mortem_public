import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/screens/summary_screen.dart';
import 'package:chess_mortem/widgets/win_chart.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''';

/// Long enough to leave the opening, so the phase rows have something to
/// split. (Six moves of theory would all land in one phase.)
const _longPgn = '''
[Event "Test"]
[White "Alice"]
[Black "Bob"]
[WhiteElo "1500"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6
8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8
14. Ng3 g6 15. b3 Bg7 16. d5 Nb6 17. Be3 Nfd7 18. c4 f5 19. exf5 gxf5 *
''';

void main() {
  Future<AnalysisSession> loadedSession({String pgn = _pgn}) async {
    final session = AnalysisSession(engine: FakeEngine());
    await session.loadPgn(pgn);
    return session;
  }

  Future<void> pumpSummary(
    WidgetTester tester,
    AnalysisSession session, {
    Side perspective = Side.white,
    // Tall enough for the whole page: a ListView does not build what is off
    // screen, and the quality table always lists every tier.
    Size size = const Size(400, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SummaryScreen(session: session, perspective: perspective),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('leads with both accuracies, then the chart, then the tables', (
    tester,
  ) async {
    await pumpSummary(tester, await loadedSession());

    for (final side in Side.values) {
      expect(
        tester.widget<Text>(find.byKey(accuracyKeyFor(side))).data,
        endsWith('%'),
      );
    }
    expect(find.byType(WinChart), findsOne);
    expect(find.text("WHITE'S WINNING CHANCES"), findsOne);
    expect(find.text('MOVE QUALITY'), findsOne);
    expect(find.text('ACCURACY DETAIL'), findsOne);
    expect(find.text('Centipawn loss'), findsOne);
    expect(find.text('—'), findsNothing, reason: 'the game is analyzed');
    expect(tester.takeException(), isNull);

    // Ranked, not listed: the two numbers the screen exists for come first.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(
      top(find.byKey(accuracyKeyFor(Side.white))),
      lessThan(top(find.byType(WinChart))),
    );
    expect(
      top(find.byType(WinChart)),
      lessThan(top(find.text('MOVE QUALITY'))),
    );
  });

  testWidgets('the chart carries a scale, so the curve is a percentage', (
    tester,
  ) async {
    await pumpSummary(tester, await loadedSession());

    // 100 and 50 are unique to the axis; a bare "0" also shows up as a count
    // elsewhere on the page, so it is checked as part of the axis column.
    expect(find.text('100'), findsOne);
    expect(find.text('50'), findsOne);
    final axis = find
        .ancestor(of: find.text('100'), matching: find.byType(Column))
        .first;
    expect(find.descendant(of: axis, matching: find.text('0')), findsOne);
  });

  testWidgets('every verdict gets a row, zeros included', (tester) async {
    // Driven by the enum, so a new verdict appears unasked; a tier the game
    // did not contain still prints its row, with 0 for both players.
    final session = await loadedSession();
    final played = [
      Classification.blunder,
      Classification.brilliant,
      Classification.good,
    ];
    for (var i = 0; i < session.tree.mainline.length; i++) {
      session.tree.mainline[i].classification = played[i % played.length];
    }
    await pumpSummary(tester, session, size: const Size(400, 1400));

    // Tall enough that the whole page is laid out.
    for (final tier in Classification.values) {
      expect(find.text(tier.label), findsOne, reason: tier.label);
    }
    final greatRow = find
        .ancestor(of: find.text('Great'), matching: find.byType(Row))
        .last;
    expect(
      find.descendant(of: greatRow, matching: find.text('0')),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('book moves are a row of the quality table, under Great', (
    tester,
  ) async {
    // Book is counted with the verdicts, directly under Great.
    final session = await loadedSession();
    final mainline = session.tree.mainline;
    for (final node in mainline) {
      node.openingName = 'Spanish Game';
      node.classification = Classification.great;
    }
    mainline.last.openingName = null; // one scored move, so Great has a row
    await pumpSummary(tester, session, size: const Size(400, 1400));

    expect(find.text('Book'), findsOne);
    expect(
      tester.getTopLeft(find.text('Great')).dy,
      lessThan(tester.getTopLeft(find.text('Book')).dy),
    );
    // Only the moves still in theory, split by who played them.
    final bookRow = find
        .ancestor(of: find.text('Book'), matching: find.byType(Row))
        .last;
    expect(find.descendant(of: bookRow, matching: find.text('3')), findsOne);
    expect(find.descendant(of: bookRow, matching: find.text('2')), findsOne);
  });

  testWidgets('a game with no theory in it still has a book row', (
    tester,
  ) async {
    await pumpSummary(
      tester,
      await loadedSession(),
      size: const Size(400, 1400),
    );

    expect(find.text('Book'), findsOne);
  });

  testWidgets('the outlined card is the one being read, not the winner', (
    tester,
  ) async {
    // Border and fill both mark the selection, never the winner.
    final session = await loadedSession(pgn: _longPgn);
    await pumpSummary(tester, session, perspective: Side.white);

    BorderSide sideOf(Side player) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(playerCardKeyFor(player)),
              matching: find.byType(Material),
            )
            .first,
      );
      return (material.shape as RoundedRectangleBorder).side;
    }

    expect(sideOf(Side.white).color, isNot(Colors.transparent));
    expect(sideOf(Side.black).color, Colors.transparent);
    expect(
      sideOf(Side.white).width,
      sideOf(Side.black).width,
      reason: 'both cards carry the same border, so neither moves when picked',
    );

    await tester.tap(find.byKey(playerCardKeyFor(Side.black)));
    await tester.pumpAndSettle();

    expect(sideOf(Side.black).color, isNot(Colors.transparent));
    expect(sideOf(Side.white).color, Colors.transparent);
  });

  testWidgets(
    'a game with nothing scored yet shows zeros, and does not crash',
    (tester) async {
      await pumpSummary(
        tester,
        AnalysisSession(engine: FakeEngine()),
        size: const Size(400, 1400),
      );

      expect(find.text('Blunder'), findsOne);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('says which engine produced the numbers, and at what depth', (
    tester,
  ) async {
    // Every eval, classification and accuracy above depends on this, and a
    // different engine gives a different set for the same game.
    // Tall enough that the whole page is built: the engine line is the last
    // thing on it and a ListView does not build what is off screen.
    await pumpSummary(
      tester,
      await loadedSession(),
      size: const Size(400, 1400),
    );

    expect(find.textContaining('Analysed by Fake engine'), findsOne);
    expect(find.textContaining('depth 15'), findsOne);
  });

  testWidgets('the players from the PGN sit under their colour', (
    tester,
  ) async {
    await pumpSummary(tester, await loadedSession(pgn: _longPgn));

    // The Elo comes along when the PGN carried one, on the quiet line under
    // the name, and is simply left off when it did not.
    expect(find.text('Alice'), findsOne);
    expect(find.text('Bob'), findsOne);
    expect(find.textContaining('1500'), findsOne);
  });

  testWidgets('an unnamed player is its colour, not a question mark', (
    tester,
  ) async {
    // dartchess fills White/Black with "?" when the PGN says nothing, and a
    // literal question mark where the name goes would be worse than nothing.
    await pumpSummary(tester, await loadedSession());

    // The Mistake badge's "?" is a symbol, not a name; only the cards count.
    for (final side in Side.values) {
      expect(
        find.descendant(
          of: find.byKey(playerCardKeyFor(side)),
          matching: find.text('?'),
        ),
        findsNothing,
        reason: 'no placeholder name on either card',
      );
    }
    // The card falls back to naming the colour it belongs to. (The column
    // headings say the same words, hence "at least".)
    expect(find.text('White'), findsAtLeastNWidgets(1));
    expect(find.text('Black'), findsAtLeastNWidgets(1));
  });

  testWidgets('the phases the game reached each get a row', (tester) async {
    await pumpSummary(tester, await loadedSession(pgn: _longPgn));

    expect(find.text('Opening'), findsOne);
    expect(find.text('Middlegame'), findsOne);
    // This game never trades down far enough for an endgame.
    expect(find.text('Endgame'), findsNothing);
  });

  testWidgets('a game that never left the opening has no phase rows', (
    tester,
  ) async {
    await pumpSummary(tester, await loadedSession());

    expect(find.text('Centipawn loss'), findsOne, reason: 'the table is there');
    expect(find.text('Opening'), findsNothing);
    expect(find.text('Middlegame'), findsNothing);
    expect(find.text('Endgame'), findsNothing);
  });

  testWidgets('the chart says "yours" only when it really is yours', (
    tester,
  ) async {
    // The board can be flipped to either colour and the graph follows it, so
    // "Your winning chances" over the opponent's curve would be a lie.
    final session = await loadedSession(pgn: _longPgn);
    session.playerName = 'Alice';

    await pumpSummary(tester, session);
    expect(find.text('YOUR WINNING CHANCES'), findsOne);

    await pumpSummary(tester, session, perspective: Side.black);
    expect(find.text("BLACK'S WINNING CHANCES"), findsOne);
  });

  testWidgets('picking a player card reads the game from their side', (
    tester,
  ) async {
    // A player card is a radio button: choosing a player does what flipping
    // the board does.
    Side? reported;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: SummaryScreen(
          session: await loadedSession(pgn: _longPgn),
          perspective: Side.white,
          onPerspectiveChanged: (side) => reported = side,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("WHITE'S WINNING CHANCES"), findsOne);

    await tester.tap(find.byKey(playerCardKeyFor(Side.black)));
    await tester.pumpAndSettle();

    expect(find.text("BLACK'S WINNING CHANCES"), findsOne);
    expect(reported, Side.black, reason: 'the board has to flip with it');
  });

  testWidgets('picking the side already shown reports nothing', (tester) async {
    var reports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SummaryScreen(
          session: await loadedSession(),
          perspective: Side.white,
          onPerspectiveChanged: (_) => reports++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(playerCardKeyFor(Side.white)));
    await tester.pumpAndSettle();

    expect(reports, 0);
  });

  testWidgets('an unanalyzed game shows dashes instead of crashing', (
    tester,
  ) async {
    final session = AnalysisSession(engine: FakeEngine());
    await pumpSummary(tester, session);

    // Overall accuracy and centipawn loss, for both players.
    expect(find.text('—'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it repaints as analysis streams in', (tester) async {
    final session = await loadedSession();
    // Move an eval so one accuracy changes, then notify.
    await pumpSummary(tester, session);
    String whiteAccuracy() =>
        tester.widget<Text>(find.byKey(accuracyKeyFor(Side.white))).data!;
    final shown = whiteAccuracy();

    session.tree.mainline.first.eval = const EngineEval(
      cp: -900,
      bestMoveUci: 'e2e4',
      depth: 15,
    );
    session.goToNode(session.tree.mainline.first); // notifies
    await tester.pumpAndSettle();

    expect(whiteAccuracy(), isNot(shown));
  });

  testWidgets('tapping the chart moves the cursor', (tester) async {
    final session = await loadedSession();
    await pumpSummary(tester, session);
    expect(session.current, session.tree.root);

    final rect = tester.getRect(find.byType(WinChart));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pumpAndSettle();

    expect(session.current, session.tree.mainline.last);
  });

  testWidgets('the last line can be scrolled clear of the navigation bar', (
    tester,
  ) async {
    // Android draws the nav bar over the app, so the screen has to make room
    // for it itself or the closing paragraph is unreadable.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SummaryScreen(
          session: await loadedSession(),
          perspective: Side.white,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lastLine = find.textContaining('Analysed by');
    await tester.scrollUntilVisible(lastLine, 200);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(lastLine).dy, lessThan(800 - 48));
  });

  testWidgets('a row explains itself in a dialog instead of a closing essay', (
    tester,
  ) async {
    // Each row carries its own ⓘ, so the reader never matches a paragraph's
    // sentences to rows.
    await pumpSummary(tester, await loadedSession());

    expect(
      find.textContaining('winning chances each player kept'),
      findsNothing,
      reason: 'the explanation is behind the icon, not printed on the page',
    );

    Finder infoFor(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byIcon(Icons.info_outline),
    );

    await tester.tap(infoFor('Centipawn loss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hundredths of a pawn'), findsOne);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hundredths of a pawn'), findsNothing);

    // A different figure explains a different thing: the headline accuracy,
    // which is not in the table, carries its own note.
    await tester.tap(infoFor('ACCURACY').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('winning chances each player kept'), findsOne);
  });
}
