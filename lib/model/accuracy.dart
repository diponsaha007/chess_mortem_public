/// Game accuracy, lichess's `AccuracyPercent.scala` formula for formula: an
/// exponential per-move curve, then the mean of a volatility-weighted mean
/// and a harmonic mean. Book moves are never scored.
library;

import 'dart:math';

import 'package:dartchess/dartchess.dart';

import 'classification.dart';
import 'eval.dart';
import 'game_phase.dart';
import 'game_tree.dart';

/// Accuracy of one move, 0-100, from the mover's winning chances before and
/// after it.
double moveAccuracy({
  required double winPctBefore,
  required double winPctAfter,
}) {
  if (winPctAfter >= winPctBefore) return 100;
  final winDiff = winPctBefore - winPctAfter;
  final raw =
      103.1668100711649 * exp(-0.04354415386753951 * winDiff) -
      3.166924740191411;
  return (raw + 1).clamp(0.0, 100.0); // +1: lichess's uncertainty bonus
}

/// lichess's `Cp.initial`: the level position every phase is scored from.
const EngineEval levelPosition = EngineEval(
  cp: 15,
  bestMoveUci: null,
  depth: 0,
);

/// One move's contribution to a game's accuracy.
class AccuracySample {
  const AccuracySample({
    required this.ply,
    required this.accuracy,
    required this.volatilityWeight,
  });

  /// The ply this move landed on.
  final int ply;

  final double accuracy;

  /// How much this move counts: the swing in the position around it.
  final double volatilityWeight;
}

/// Per-move accuracies for [mover]'s mainline moves. Stops at the first
/// unevaluated position, so it works mid-analysis.
List<AccuracySample> accuracySamples({
  required GameNode root,
  required List<GameNode> mainline,
  required Side mover,
}) {
  final rootEval = root.eval;
  if (rootEval == null) return const [];

  final winPcts = <double>[winPctFor(rootEval, mover)];
  final moves = <GameNode>[];
  for (final node in mainline) {
    final eval = node.eval;
    if (eval == null) break;
    winPcts.add(winPctFor(eval, mover));
    moves.add(node);
  }
  return _samples(winPcts: winPcts, moves: moves, mover: mover);
}

/// Scores [moves] against [winPcts], which starts with the position BEFORE
/// the first move: `moves[i]` produced `winPcts[i + 1]`. Every move feeds the
/// volatility window; only [mover]'s non-book moves become samples.
List<AccuracySample> _samples({
  required List<double> winPcts,
  required List<GameNode> moves,
  required Side mover,
}) {
  if (winPcts.length < 2) return const [];

  final windowSize = (moves.length ~/ 10).clamp(2, 8); // counted in MOVES
  final samples = <AccuracySample>[];

  for (var i = 1; i < winPcts.length; i++) {
    final node = moves[i - 1];
    if (node.sideThatMoved != mover || node.isBook) continue;

    // The window TRAILS the move, left-padded at the start.
    final end = min(winPcts.length, max(windowSize, i + 1));
    final start = max(0, end - windowSize);
    samples.add(
      AccuracySample(
        ply: node.ply,
        accuracy: moveAccuracy(
          winPctBefore: winPcts[i - 1],
          winPctAfter: winPcts[i],
        ),
        volatilityWeight: _stdDev(winPcts.sublist(start, end)).clamp(0.5, 12.0),
      ),
    );
  }
  return samples;
}

/// Overall accuracy, 0-100, or null with nothing to score.
double? gameAccuracy(List<AccuracySample> samples) {
  if (samples.isEmpty) return null;

  var weightedSum = 0.0;
  var weightTotal = 0.0; // never 0: weights are clamped to >= 0.5
  var reciprocalSum = 0.0;
  for (final sample in samples) {
    weightedSum += sample.accuracy * sample.volatilityWeight;
    weightTotal += sample.volatilityWeight;
    reciprocalSum += 1 / max(sample.accuracy, 1.0);
  }

  final weighted = weightedSum / weightTotal;
  final harmonic = samples.length / reciprocalSum;
  return ((weighted + harmonic) / 2).clamp(0.0, 100.0);
}

/// Accuracy over one phase, or null when [mover] made no scored move in it.
///
/// The phase is re-run as a game of its own starting from [levelPosition],
/// so phases do not add up to the overall number.
double? phaseAccuracy({
  required List<GameNode> mainline,
  required GameDivision division,
  required GamePhase phase,
  required Side mover,
}) {
  final winPcts = <double>[winPctFor(levelPosition, mover)];
  final moves = <GameNode>[];
  for (final node in mainline) {
    final eval = node.eval;
    if (eval == null) break;
    if (division.phaseAt(node.ply) != phase) continue;
    winPcts.add(winPctFor(eval, mover));
    moves.add(node);
  }
  return gameAccuracy(_samples(winPcts: winPcts, moves: moves, mover: mover));
}

/// Average centipawn loss for [mover] (lichess's `AccuracyCP`), over the
/// same moves [accuracySamples] scores.
int? averageCentipawnLoss({
  required GameNode root,
  required List<GameNode> mainline,
  required Side mover,
}) {
  var total = 0;
  var counted = 0;
  GameNode? previous;

  for (final node in [root, ...mainline]) {
    final eval = node.eval;
    if (eval == null) break;
    final before = previous?.eval;
    previous = node;
    if (before == null) continue; // the root has no move before it
    if (node.sideThatMoved != mover || node.isBook) continue;

    total += max(0, cpCeiledFor(before, mover) - cpCeiledFor(eval, mover));
    counted++;
  }

  if (counted == 0) return null;
  return (total / counted).round();
}

double _stdDev(List<double> values) {
  if (values.length < 2) return 0;
  final mean = values.reduce((a, b) => a + b) / values.length;
  var sum = 0.0;
  for (final value in values) {
    final delta = value - mean;
    sum += delta * delta;
  }
  return sqrt(sum / values.length);
}
