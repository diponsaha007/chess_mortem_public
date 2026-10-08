import 'package:dartchess/dartchess.dart';

/// How the game ended, from the PGN's `Result` tag.
enum GameResult {
  whiteWon('1–0'),
  blackWon('0–1'),
  draw('½–½');

  const GameResult(this.label);

  /// "1–0", "0–1", "½–½", always written White-first.
  final String label;

  Side? get winner => switch (this) {
    GameResult.whiteWon => Side.white,
    GameResult.blackWon => Side.black,
    GameResult.draw => null,
  };

  bool get isDraw => this == GameResult.draw;

  bool wonBy(Side side) => winner == side;

  /// The tag, or null for `*` (unfinished, or no header at all).
  static GameResult? parse(String? raw) => switch (raw?.trim()) {
    '1-0' => GameResult.whiteWon,
    '0-1' => GameResult.blackWon,
    '1/2-1/2' || '½-½' => GameResult.draw,
    _ => null,
  };
}
