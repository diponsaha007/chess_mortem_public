import 'dart:async';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/game_library.dart';
import 'package:chess_mortem/model/saved_game.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:chess_mortem/screens/library_screen.dart';
import 'package:chess_mortem/widgets/side_marks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';
import 'fakes/fake_config_store.dart';
import 'fakes/fake_library_store.dart';

const _wonPgn = '''
[White "Queen_Walker_Test"]
[Black "Night_Owl_Test"]
[Result "1-0"]
[WhiteElo "1290"]
[BlackElo "1325"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0
''';

const _lostPgn = '''
[White "Rook_Example"]
[Black "Queen_Walker_Test"]
[Result "1-0"]

1. d4 d5 2. c4 1-0
''';

/// Sizes worth checking: a small phone and a tall one.
const _sizes = [Size(320, 568), Size(360, 740)];

Future<GameLibrary> loadedLibrary([List<String> pgns = const []]) async {
  final library = GameLibrary(store: FakeLibraryStore(const []));
  await library.load();
  for (final pgn in pgns) {
    await library.add(pgn);
  }
  return library;
}

Future<void> pumpLibrary(
  WidgetTester tester,
  GameLibrary library, {
  String? playerName,
}) async {
  final session = AnalysisSession(engine: FakeEngine(), playerName: playerName);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryScreen(
        session: session,
        configStore: FakeConfigStore(hasKey: false),
        library: library,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in _sizes) {
    testWidgets('a saved game reads as a card at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final library = await loadedLibrary([_wonPgn]);

      await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');

      expect(find.text('Queen_Walker_Test'), findsOne);
      expect(find.text('Night_Owl_Test'), findsOne);
      expect(find.text('1290'), findsOne);
      expect(find.text('1325'), findsOne);
      expect(find.text('1–0'), findsOne);
      expect(find.textContaining('3 moves'), findsOne);
      // No overflow at either size.
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the result is said from the user\'s side', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_lostPgn, _wonPgn]);

    await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');

    expect(find.text('YOU WON'), findsOne);
    expect(find.text('YOU LOST'), findsOne);
    // One chip per card: the user is one of the two players in each.
    expect(find.byType(YouChip), findsExactly(2));
  });

  testWidgets('with no player name the result is said by colour', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_wonPgn]);

    await pumpLibrary(tester, library);

    expect(find.text('WHITE WON'), findsOne);
    expect(find.byType(YouChip), findsNothing);
  });

  testWidgets('tapping a game loads it and opens the board', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_wonPgn]);

    await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');
    await tester.tap(find.text('Night_Owl_Test'));
    await tester.pumpAndSettle();

    expect(find.byType(BoardScreen), findsOne);
  });

  testWidgets('a game can be deleted, and the deletion undone', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_wonPgn]);

    await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');
    await tester.tap(find.byTooltip('Delete game'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Night_Owl_Test'), findsNothing);
    expect(find.text('No games yet'), findsOne);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('Night_Owl_Test'), findsOne);
  });

  testWidgets('the Undo offer goes away by itself', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_wonPgn]);

    await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');
    await tester.tap(find.byTooltip('Delete game'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOne);

    // The default snackbar time is 4 s.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('Undo'), findsNothing);
    expect(library.games, isEmpty);
  });

  testWidgets('cancelling the delete keeps the game', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary([_wonPgn]);

    await pumpLibrary(tester, library, playerName: 'Queen_Walker_Test');
    await tester.tap(find.byTooltip('Delete game'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Night_Owl_Test'), findsOne);
    expect(library.games, hasLength(1));
  });

  testWidgets('an empty library asks for a PGN', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpLibrary(tester, await loadedLibrary());

    expect(find.text('No games yet'), findsOne);
    // One button, not the empty state's plus a floating one.
    expect(find.text('Paste PGN'), findsOne);
  });

  testWidgets('a PGN that will not parse is refused, not saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary();

    await pumpLibrary(tester, library);
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not a pgn at all');
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();

    // The dialog stays open, with the reason under the field.
    expect(find.textContaining('could not be read'), findsOne);
    expect(library.games, isEmpty);
  });

  testWidgets('a pasted game is saved and opened', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final library = await loadedLibrary();

    await pumpLibrary(tester, library);
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _wonPgn);
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();

    expect(library.games.single.white, 'Queen_Walker_Test');
    expect(find.byType(BoardScreen), findsOne);
  });

  testWidgets('a double tap on Analyze submits once', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = _SlowStore();
    final library = GameLibrary(store: store);
    await library.load();

    await pumpLibrary(tester, library);
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _wonPgn);
    // Both taps land while the first save is still in storage.
    await tester.tap(find.text('Analyze'));
    await tester.pump();
    await tester.tap(find.text('Analyze'));
    await tester.pump();
    store.gate.complete();
    await tester.pumpAndSettle();

    // Saved when added, and again when the board opens it; a second submit
    // would add a third.
    expect(store.saves, 2);
    expect(find.byType(BoardScreen), findsOne);
  });

  group('libraryTimeLabel', () {
    final now = DateTime(2026, 8, 18, 12);
    String label(Duration ago) => libraryTimeLabel(now.subtract(ago), now: now);

    test('reads in words, roughly', () {
      expect(label(const Duration(seconds: 20)), 'Just now');
      expect(label(const Duration(minutes: 5)), '5 min ago');
      expect(label(const Duration(hours: 1)), '1 hour ago');
      expect(label(const Duration(hours: 5)), '5 hours ago');
      expect(label(const Duration(days: 1)), 'Yesterday');
      expect(label(const Duration(days: 3)), '3 days ago');
      expect(label(const Duration(days: 9)), 'Last week');
      expect(label(const Duration(days: 20)), '2 weeks ago');
      expect(label(const Duration(days: 200)), '6 months ago');
      expect(label(const Duration(days: 800)), 'Over a year ago');
    });

    test('a clock that went backwards still reads', () {
      expect(label(const Duration(days: -2)), 'Just now');
    });
  });
}

/// Holds every save until [gate] completes.
class _SlowStore extends FakeLibraryStore {
  _SlowStore() : super(const []);

  final gate = Completer<void>();

  @override
  Future<void> save(List<SavedGame> games) async {
    await gate.future;
    await super.save(games);
  }
}
