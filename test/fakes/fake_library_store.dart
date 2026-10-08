import 'package:chess_mortem/model/game_library.dart';
import 'package:chess_mortem/model/saved_game.dart';

/// In-memory games. [stored] null is a first run: the key was never written.
class FakeLibraryStore extends GameLibraryStore {
  FakeLibraryStore([this.stored]);

  List<SavedGame>? stored;
  int saves = 0;

  @override
  Future<List<SavedGame>?> load() async => stored;

  @override
  Future<void> save(List<SavedGame> games) async {
    stored = List.of(games);
    saves++;
  }
}
