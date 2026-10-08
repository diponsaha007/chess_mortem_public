import 'dart:convert';

import 'package:chess_mortem/model/game_library.dart';
import 'package:chess_mortem/model/game_result.dart';
import 'package:chess_mortem/model/saved_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fakes/fake_library_store.dart';

const _pgn = '''
[Event "Test"]
[Site "Somewhere"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]
[WhiteElo "1500"]
[BlackElo "1400"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0
''';

const _otherPgn = '''
[White "Carol"]
[Black "Dave"]
[Result "0-1"]

1. d4 d5 0-1
''';

String _knightShuffles(int pairs) {
  final moves = <String>[];
  for (var i = 0; i < pairs; i++) {
    final move = i.isEven ? 'Nf3 Nf6' : 'Ng1 Ng8';
    moves.add('${i + 1}. $move');
  }
  return '${moves.join(' ')} *';
}

void main() {
  group('SavedGame.fromPgn', () {
    test('keeps the five tags a row may show, and the move count', () {
      final game = SavedGame.fromPgn(_pgn)!;

      expect(game.white, 'Alice');
      expect(game.black, 'Bob');
      expect(game.whiteElo, '1500');
      expect(game.blackElo, '1400');
      expect(game.result, GameResult.whiteWon);
      // Five plies is three moves: 1.e4 e5 2.Nf3 Nc6 3.Bb5.
      expect(game.moveCount, 3);
      expect(game.pgn, _pgn.trim());
    });

    test('a PGN that will not parse is not a game', () {
      // An illegal move throws out of GameTree.fromPgn...
      expect(SavedGame.fromPgn('1. e5 nonsense *'), isNull);
      // ...and text that is not a PGN at all parses to no moves.
      expect(SavedGame.fromPgn('just some text'), isNull);
      expect(SavedGame.fromPgn('   '), isNull);
      // Headers with no moves under them is not a game either.
      expect(SavedGame.fromPgn('[White "Alice"]\n\n*'), isNull);
    });

    test('a PGN with no headers still saves', () {
      final game = SavedGame.fromPgn('1. e4 e5 *')!;

      expect(game.white, isNull);
      expect(game.result, isNull);
      expect(game.moveCount, 1);
    });
  });

  group('SavedGame JSON', () {
    test('round trips', () {
      final game = SavedGame.fromPgn(_pgn)!;
      final back = SavedGame.fromJson(jsonDecode(jsonEncode(game.toJson())))!;

      expect(back.id, game.id);
      expect(back.pgn, game.pgn);
      expect(back.white, 'Alice');
      expect(back.result, GameResult.whiteWon);
      expect(back.moveCount, 3);
      expect(back.lastOpenedAt, game.lastOpenedAt);
    });

    test('anything unrecognised is dropped, not repaired', () {
      expect(SavedGame.fromJson(null), isNull);
      expect(SavedGame.fromJson('a string'), isNull);
      expect(SavedGame.fromJson({'id': 'x'}), isNull);
      expect(SavedGame.fromJson({'id': 'x', 'pgn': ''}), isNull);
      // No addedAt to order it by.
      expect(SavedGame.fromJson({'id': 'x', 'pgn': '1. e4 *'}), isNull);
    });

    test('a field of the wrong type is ignored, not thrown', () {
      final game = SavedGame.fromJson({
        'id': 'x',
        'pgn': '1. e4 *',
        'addedAt': '2026-01-01T00:00:00.000',
        'white': 7,
        'moveCount': 'two',
      })!;
      expect(game.white, isNull);
      expect(game.moveCount, 0);
    });
  });

  group('GameLibrary', () {
    test('adds a game and persists it', () async {
      final store = FakeLibraryStore(const []);
      final library = GameLibrary(store: store);
      await library.load();

      final added = await library.add(_pgn);

      expect(added, isNotNull);
      expect(library.games.single.white, 'Alice');
      expect(store.stored!.single.pgn, _pgn.trim());
    });

    test('a PGN that will not parse is not saved and says so', () async {
      final store = FakeLibraryStore(const []);
      final library = GameLibrary(store: store);
      await library.load();

      expect(await library.add('not a pgn'), isNull);
      expect(library.games, isEmpty);
      expect(store.saves, 0);
    });

    test('the same PGN twice is one entry, moved to the top', () async {
      final library = GameLibrary(store: FakeLibraryStore(const []));
      await library.load();

      await library.add(_pgn);
      await library.add(_otherPgn);
      expect(library.games.first.white, 'Carol');

      final again = await library.add('$_pgn\n');

      expect(library.games.length, 2);
      expect(library.games.first.white, 'Alice');
      // The existing row came back, not a second copy of it.
      expect(again!.id, library.games.first.id);
    });

    test('opening a game moves it to the top', () async {
      final library = GameLibrary(store: FakeLibraryStore(const []));
      await library.load();
      await library.add(_pgn);
      await library.add(_otherPgn);
      final older = library.games.last;

      await library.touch(older);

      expect(library.games.first.id, older.id);
    });

    test('keeps only the newest maxGames', () async {
      final store = FakeLibraryStore(const []);
      final library = GameLibrary(store: store);
      await library.load();

      for (var i = 1; i <= GameLibrary.maxGames + 3; i++) {
        expect(await library.add(_knightShuffles(i)), isNotNull);
      }

      expect(library.games.length, GameLibrary.maxGames);
      expect(store.stored!.length, GameLibrary.maxGames);
    });

    test('remove drops the row, and restore puts it back in place', () async {
      final library = GameLibrary(store: FakeLibraryStore(const []));
      await library.load();
      await library.add(_pgn);
      await library.add(_otherPgn);
      final middleOfNowhere = library.games.last;

      await library.remove(middleOfNowhere);
      expect(library.games.length, 1);

      await library.restore(middleOfNowhere);

      expect(library.games.length, 2);
      // Its own timestamp came back with it, so it is last again — an undo,
      // not a re-paste.
      expect(library.games.last.id, middleOfNowhere.id);
    });

    test('seeds the sample on a first run only', () async {
      final store = FakeLibraryStore(); // null = the key has never been written
      final library = GameLibrary(store: store);

      await library.load(sampleWhenEmpty: _pgn);

      expect(library.games.single.white, 'Alice');
      // Writing it is what makes the deletion below stick.
      expect(store.stored, isNotNull);

      await library.remove(library.games.single);
      final relaunched = GameLibrary(store: store);
      await relaunched.load(sampleWhenEmpty: _pgn);

      expect(relaunched.games, isEmpty);
    });

    test('an empty stored list is not a first run', () async {
      final library = GameLibrary(store: FakeLibraryStore(const []));

      await library.load(sampleWhenEmpty: _pgn);

      expect(library.games, isEmpty);
    });

    test('notifies on every change', () async {
      final library = GameLibrary(store: FakeLibraryStore(const []));
      var notifications = 0;
      library.addListener(() => notifications++);

      await library.load();
      await library.add(_pgn);
      await library.remove(library.games.single);

      expect(notifications, 3);
    });
  });

  group('GameLibraryStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a key that was never written reads as a first run', () async {
      expect(await const GameLibraryStore().load(), isNull);
    });

    test('saved games survive a round trip', () async {
      const store = GameLibraryStore();
      final game = SavedGame.fromPgn(_pgn)!;

      await store.save([game]);
      final back = await store.load();

      expect(back!.single.id, game.id);
      expect(back.single.white, 'Alice');
      expect(back.single.pgn, game.pgn);
    });

    test('unreadable storage is an empty library, not a first run', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.saved_games': 'not json',
      });

      expect(await const GameLibraryStore().load(), isEmpty);
    });

    test('one bad entry does not poison the list', () async {
      final good = SavedGame.fromPgn(_pgn)!;
      SharedPreferences.setMockInitialValues({
        'flutter.saved_games': jsonEncode([
          {'id': 'broken'},
          good.toJson(),
        ]),
      });

      final loaded = await const GameLibraryStore().load();

      expect(loaded!.single.white, 'Alice');
    });
  });
}
