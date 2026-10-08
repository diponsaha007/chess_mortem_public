import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/llm_config_store.dart';
import 'package:chess_mortem/screens/settings_screen.dart';
import 'package:chess_mortem/screens/summary_screen.dart';
import 'package:chess_mortem/widgets/material_bar.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';
import 'fakes/fake_secure_storage.dart';

const _pgn = '''
[White "Queen_Walker_Test"]
[Black "Night_Owl_Test"]
[WhiteElo "1290"]
[BlackElo "1325"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''';

const _drawPgn = '''
[White "Queen_Walker_Test"]
[Black "Night_Owl_Test"]
[Result "1/2-1/2"]

1. e4 e5 *
''';

Future<AnalysisSession> _session(String pgn, {String? playerName}) async {
  final session = AnalysisSession(engine: FakeEngine(), playerName: playerName);
  await session.loadPgn(pgn);
  return session;
}

Widget _strip(AnalysisSession session, Side side) => MaterialApp(
  home: Scaffold(
    body: MaterialBar(
      board: session.tree.root.position.board,
      side: side,
      name: side == Side.white ? session.whitePlayer : session.blackPlayer,
      rating: side == Side.white ? session.whiteElo : session.blackElo,
    ),
  ),
);

void main() {
  group('the strip beside the board', () {
    testWidgets('carries the player and nothing else', (tester) async {
      // Who you are and how the game ended belong to the summary. Beside the
      // board they only pushed the material difference out of line.
      final session = await _session(_pgn, playerName: 'Queen_Walker_Test');

      for (final side in Side.values) {
        await tester.pumpWidget(_strip(session, side));
        expect(find.text('YOU'), findsNothing);
        expect(find.text('1–0'), findsNothing);
      }
      expect(find.text('Night_Owl_Test  1325'), findsOneWidget);
    });

    testWidgets('says nothing of a drawn game either', (tester) async {
      final session = await _session(_drawPgn);

      for (final side in Side.values) {
        await tester.pumpWidget(_strip(session, side));
        expect(find.text('½–½'), findsNothing);
      }
    });

    testWidgets('still fits its fixed height', (tester) async {
      // The board is sized from what these strips leave, so a strip that grew
      // to fit its contents would resize the board as the game went on.
      final session = await _session(_pgn, playerName: 'Queen_Walker_Test');
      await tester.pumpWidget(_strip(session, Side.white));

      expect(
        tester.getSize(find.byType(MaterialBar)).height,
        MaterialBar.height,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the material sits on the board\'s right edge', (tester) async {
      // The lead finishes where the board does: the name is the strip's only
      // flex child.
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn('[White "Al"]\n\n1. e4 d5 2. exd5 *');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaterialBar(
              board: session.tree.mainline.last.position.board,
              side: Side.white,
              name: session.whitePlayer,
              width: 300,
            ),
          ),
        ),
      );

      expect(
        tester.getBottomRight(find.text('+1')).dx,
        moreOrLessEquals(tester.getBottomRight(find.byType(MaterialBar)).dx),
      );
    });

    testWidgets('a long name gives way rather than overflowing', (
      tester,
    ) async {
      // Narrowest phone the board screen is tested at, and a name with no
      // room to spare: it has to ellipsise instead of pushing the strip past
      // its width.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = await _session(
        _pgn.replaceFirst('Queen_Walker_Test', 'a-very-long-username-indeed'),
        playerName: 'a-very-long-username-indeed',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaterialBar(
              board: session.tree.root.position.board,
              side: Side.white,
              name: session.whitePlayer,
              rating: session.whiteElo,
              width: 294, // 320 less the eval bar and its gap
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('the summary', () {
    testWidgets('tells each player how the game went for them', (tester) async {
      final session = await _session(_pgn, playerName: 'Queen_Walker_Test');

      await tester.pumpWidget(
        MaterialApp(
          home: SummaryScreen(session: session, perspective: Side.white),
        ),
      );
      await tester.pumpAndSettle();

      // The word is each player's own; the score keeps its written form on
      // both cards, because a result is always notated White-first.
      expect(find.textContaining('won 1–0'), findsOne);
      expect(find.textContaining('lost 1–0'), findsOne);
      expect(find.text('YOU'), findsOne);
    });

    testWidgets('a draw is a draw on both cards', (tester) async {
      final session = await _session(_drawPgn);

      await tester.pumpWidget(
        MaterialApp(
          home: SummaryScreen(session: session, perspective: Side.white),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('drew ½–½'), findsNWidgets(2));
    });

    testWidgets('marks nobody when the name matches neither', (tester) async {
      final session = await _session(_pgn, playerName: 'someone else');

      await tester.pumpWidget(
        MaterialApp(
          home: SummaryScreen(session: session, perspective: Side.white),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('YOU'), findsNothing);
    });
  });

  group('setting your name', () {
    testWidgets('saves it and reports it to the session', (tester) async {
      final store = LlmConfigStore(FakeSecureStorage());
      String? reported;

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            configStore: store,
            onPlayerNameChanged: (name) => reported = name,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(playerNameTileKey);
      await tester.scrollUntilVisible(tile, 100);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(playerNameFieldKey),
        'Queen_Walker_Test',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(reported, 'Queen_Walker_Test');
      expect((await store.load()).playerName, 'Queen_Walker_Test');
    });

    testWidgets('other settings do not report a name change', (tester) async {
      // The board turns to the user's side on a name change, so a report on
      // every save would undo a hand flip whenever any setting moved.
      final store = LlmConfigStore(FakeSecureStorage());
      await store.save(LlmConfig(playerName: 'Queen_Walker_Test'));
      var reports = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            configStore: store,
            onPlayerNameChanged: (_) => reports++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(criticalMovesSwitchKey);
      await tester.scrollUntilVisible(toggle, 100);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect((await store.load()).ranksAlternatives, isFalse);
      expect(reports, 0);
    });

    testWidgets('cancelling leaves the saved name alone', (tester) async {
      final store = LlmConfigStore(FakeSecureStorage());
      await store.save(LlmConfig(playerName: 'Queen_Walker_Test'));

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(configStore: store)),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(playerNameTileKey);
      await tester.scrollUntilVisible(tile, 100);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(playerNameFieldKey), 'typo');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect((await store.load()).playerName, 'Queen_Walker_Test');
    });

    testWidgets('can be cleared back to nobody', (tester) async {
      // Clearing writes '', not null — null through copyWith would mean
      // "leave it alone" and the name could never be deleted.
      final store = LlmConfigStore(FakeSecureStorage());
      await store.save(LlmConfig(playerName: 'Queen_Walker_Test'));

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(configStore: store)),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(playerNameTileKey);
      await tester.scrollUntilVisible(tile, 100);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(playerNameFieldKey), '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect((await store.load()).playerName, isEmpty);

      final session = AnalysisSession(engine: FakeEngine(), playerName: '');
      await session.loadPgn(_pgn);
      expect(session.userSide, isNull);
    });
  });
}
