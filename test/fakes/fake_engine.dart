import 'package:chess_mortem/engine/engine.dart';
import 'package:chess_mortem/model/eval.dart';

/// In-memory [ChessEngine] for tests. Counts calls per FEN so tests can
/// assert the never-recompute guarantee.
class FakeEngine implements ChessEngine {
  FakeEngine({
    Map<String, EngineEval>? evalsByFen,
    Map<String, EngineLine>? runnerUpsByFen,
  }) : evalsByFen = evalsByFen ?? {},
       runnerUpsByFen = runnerUpsByFen ?? {};

  /// Scripted evals. FENs not listed get [fallback].
  final Map<String, EngineEval> evalsByFen;

  EngineEval fallback = const EngineEval(cp: 0, bestMoveUci: 'e2e4', depth: 15);

  final Map<String, int> callsByFen = {};

  /// Scripted runner-up searches. FENs not listed get null (no line).
  final Map<String, EngineLine> runnerUpsByFen;

  /// Runner-up searches per FEN, with the moves each one was restricted to.
  final Map<String, int> runnerUpCallsByFen = {};
  final Map<String, List<String>> searchMovesByFen = {};
  final Map<String, int> runnerUpDepthByFen = {};

  @override
  String get name => 'Fake engine';

  int get totalCalls => callsByFen.values.fold(0, (sum, count) => sum + count);

  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) async {
    callsByFen[fen] = (callsByFen[fen] ?? 0) + 1;
    return evalsByFen[fen] ?? fallback;
  }

  @override
  Future<EngineLine?> evaluateRunnerUp(
    String fen, {
    required List<String> searchMoves,
    int depth = 15,
  }) async {
    runnerUpCallsByFen[fen] = (runnerUpCallsByFen[fen] ?? 0) + 1;
    searchMovesByFen[fen] = searchMoves;
    runnerUpDepthByFen[fen] = depth;
    return runnerUpsByFen[fen];
  }

  @override
  Future<void> dispose() async {}
}
