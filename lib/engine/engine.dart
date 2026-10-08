import '../model/eval.dart';

/// Anything that can evaluate a chess position. Swappable; tests use a fake.
abstract class ChessEngine {
  /// "Stockfish 16" — shown, since the engine changes the numbers.
  String get name;

  /// Eval, best move and PV for [fen], White-perspective.
  Future<EngineEval> evaluate(String fen, {int depth = 15});

  /// The best of [searchMoves] (dartchess UCI) in [fen], White-perspective:
  /// the runner-up when they are every move but the best. Null when the
  /// search returned no line.
  Future<EngineLine?> evaluateRunnerUp(
    String fen, {
    required List<String> searchMoves,
    int depth = 15,
  });

  Future<void> dispose();
}

/// Thrown when the engine could not be started. Every later search fails
/// the same way at once: a second start would put another engine on the
/// same native pipes as the one that did not answer.
class EngineStartException implements Exception {
  EngineStartException(this.cause);

  final Object cause;

  @override
  String toString() => 'The engine could not start ($cause)';
}

/// Thrown when the engine produced no usable output in time.
class EngineTimeoutException implements Exception {
  EngineTimeoutException(this.fen);

  final String fen;

  @override
  String toString() => 'Engine timed out evaluating $fen';
}
