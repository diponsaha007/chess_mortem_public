import 'package:dartchess/dartchess.dart';

import 'classification.dart';
import 'game_tree.dart';

/// One plotted point of the winning-chance graph.
class WinChartPoint {
  const WinChartPoint({
    required this.ply,
    required this.winPct,
    required this.classification,
    required this.isBook,
  });

  final int ply;

  /// Winning chances (0-100) from the chart's perspective.
  final double winPct;

  /// Verdict on the move that led here. Null at ply 0.
  final Classification? classification;

  final bool isBook;

  @override
  bool operator ==(Object other) =>
      other is WinChartPoint &&
      other.ply == ply &&
      other.winPct == winPct &&
      other.classification == classification &&
      other.isBook == isBook;

  @override
  int get hashCode => Object.hash(ply, winPct, classification, isBook);
}

/// The root plus every evaluated mainline position, seen from [perspective].
/// Stops at the first unevaluated node, so the chart grows with the sweep.
List<WinChartPoint> buildWinChartPoints({
  required GameNode root,
  required List<GameNode> mainline,
  required Side perspective,
}) {
  final points = <WinChartPoint>[];
  for (final node in [root, ...mainline]) {
    final eval = node.eval;
    if (eval == null) break;
    points.add(
      WinChartPoint(
        ply: node.ply,
        winPct: winPctFor(eval, perspective),
        classification: node.classification,
        isBook: node.isBook,
      ),
    );
  }
  return points;
}
