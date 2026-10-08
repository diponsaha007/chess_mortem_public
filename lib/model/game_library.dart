import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'saved_game.dart';

/// Loads and saves the game list. A class so tests can substitute one.
class GameLibraryStore {
  const GameLibraryStore();

  static const _gamesKey = 'saved_games';

  /// The stored games, or null when the key was never written (a first run).
  /// Storage that throws reads as `[]`, NOT as a first run, so the sample is
  /// never re-seeded on every launch.
  Future<List<SavedGame>?> load() async {
    final String? stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = prefs.getString(_gamesKey);
    } catch (_) {
      return const [];
    }
    if (stored == null) return null;
    return _decode(stored);
  }

  Future<void> save(List<SavedGame> games) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _gamesKey,
      jsonEncode([for (final game in games) game.toJson()]),
    );
  }

  List<SavedGame> _decode(String stored) {
    final Object? json;
    try {
      json = jsonDecode(stored);
    } on FormatException {
      return const [];
    }
    if (json is! List) return const [];
    return [for (final entry in json) ?SavedGame.fromJson(entry)];
  }
}

/// The games the user has loaded, most recently opened first.
class GameLibrary extends ChangeNotifier {
  GameLibrary({GameLibraryStore store = const GameLibraryStore()})
    : _store = store;

  final GameLibraryStore _store;
  final List<SavedGame> _games = [];

  /// The whole list is one preferences string, so it is bounded.
  static const maxGames = 50;

  List<SavedGame> get games => List.unmodifiable(_games);

  bool get isEmpty => _games.isEmpty;

  /// Reads the stored list; on a first run only, adds [sampleWhenEmpty] as an
  /// ordinary entry.
  Future<void> load({String? sampleWhenEmpty}) async {
    final stored = await _store.load();
    _games
      ..clear()
      ..addAll(stored ?? const []);
    _sort();
    if (stored == null && sampleWhenEmpty != null) {
      await add(sampleWhenEmpty); // notifies and persists
      return;
    }
    notifyListeners();
  }

  /// Saves [pgn] and returns its entry, or null when it does not parse. The
  /// same PGN twice is one entry moved to the top.
  Future<SavedGame?> add(String pgn) async {
    final text = pgn.trim();
    for (final game in _games) {
      if (game.pgn == text) {
        await touch(game);
        return game;
      }
    }
    final game = SavedGame.fromPgn(text);
    if (game == null) return null;
    await _insert(game);
    return game;
  }

  /// Marks [game] as just opened, moving it to the top.
  Future<void> touch(SavedGame game) async {
    final index = _games.indexWhere((entry) => entry.id == game.id);
    if (index < 0) return;
    _games[index] = _games[index].copyWith(lastOpenedAt: DateTime.now());
    _sort();
    await _persist();
  }

  /// Puts a removed entry back with its own id and timestamp — the snackbar's
  /// Undo.
  Future<void> restore(SavedGame game) async {
    if (_games.any((entry) => entry.id == game.id)) return;
    await _insert(game);
  }

  Future<void> remove(SavedGame game) async {
    final before = _games.length;
    _games.removeWhere((entry) => entry.id == game.id);
    if (_games.length == before) return;
    await _persist();
  }

  Future<void> _insert(SavedGame game) async {
    _games.add(game);
    _sort();
    if (_games.length > maxGames) _games.removeRange(maxGames, _games.length);
    await _persist();
  }

  /// Listeners hear at once; a failed write only loses the change on the
  /// next launch.
  Future<void> _persist() async {
    notifyListeners();
    try {
      await _store.save(_games);
    } catch (_) {}
  }

  void _sort() =>
      _games.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
}
