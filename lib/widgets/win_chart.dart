import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../model/classification.dart';
import '../model/game_phase.dart';
import '../model/win_chart.dart';
import 'move_list.dart';

/// Winning chances across the game: the area under the curve belongs to the
/// player whose perspective this is, the area above to the opponent. Tap to
/// jump to a move, drag to scrub through the game.
class WinChart extends StatelessWidget {
  const WinChart({
    super.key,
    required this.points,
    required this.currentPly,
    required this.onSelectPly,
    this.division = GameDivision.empty,
    this.height = 130,
  });

  final List<WinChartPoint> points;

  /// Where the board cursor is, marked with a vertical line.
  final int currentPly;

  /// Phase boundaries, drawn as labelled rules.
  final GameDivision division;

  /// Emits the ply of the nearest point, looked up in [points].
  final ValueChanged<int> onSelectPly;

  final double height;

  /// The side of the cursor marker's square box, known up front so it can
  /// be kept inside the chart.
  static const double calloutHeight = 24;

  int _plyAt(double dx, double width) {
    if (points.isEmpty) return 0;
    if (points.length == 1 || width <= 0) return points.first.ply;
    final index = (dx / width * (points.length - 1)).round().clamp(
      0,
      points.length - 1,
    );
    return points[index].ply;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) =>
              onSelectPly(_plyAt(d.localPosition.dx, constraints.maxWidth)),
          onHorizontalDragUpdate: (d) =>
              onSelectPly(_plyAt(d.localPosition.dx, constraints.maxWidth)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: WinChartPainter(
                  points: points,
                  currentPly: currentPly,
                  division: division,
                  playerColor: theme.colorScheme.onSurface,
                  opponentColor: theme.colorScheme.surfaceContainerHighest,
                  lineColor: theme.colorScheme.primary,
                  gridColor: theme.colorScheme.outlineVariant,
                  // Both fills run under a label, so it needs a backdrop.
                  labelColor: theme.colorScheme.onSurfaceVariant,
                  labelBackground: theme.colorScheme.surfaceContainerHigh,
                ),
              ),
              ..._callout(constraints.biggest),
            ],
          ),
        ),
      ),
    );
  }

  /// The cursor move's verdict, centred on its point.
  List<Widget> _callout(Size size) {
    if (points.length < 2 || size.isEmpty) return const [];
    final index = points.indexWhere((p) => p.ply == currentPly);
    // Nothing to judge at the starting position.
    if (index <= 0) return const [];
    final point = points[index];
    if (!point.isBook && point.classification == null) return const [];

    final x = WinChartPainter.xOf(index, points.length, size.width);
    final y = WinChartPainter.yOf(point.winPct, size.height);

    double centre(double at, double box, double extent) =>
        (at - box / 2).clamp(0.0, math.max(0.0, extent - box)).toDouble();

    return [
      Positioned(
        left: centre(x, calloutHeight, size.width),
        top: centre(y, calloutHeight, size.height),
        width: calloutHeight,
        height: calloutHeight,
        child: _PointCallout(point: point),
      ),
    ];
  }
}

/// The cursor marker, for tests.
const winChartCalloutKey = ValueKey('winChartCallout');

/// The selected move's badge on a backdrop, since both fills run under it.
class _PointCallout extends StatelessWidget {
  const _PointCallout({required this.point});

  final WinChartPoint point;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final classification = point.classification;
    return Container(
      key: winChartCalloutKey,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: point.isBook
          ? const BookBadge()
          : ClassificationBadge(classification: classification!, size: 16),
    );
  }
}

class WinChartPainter extends CustomPainter {
  WinChartPainter({
    required this.points,
    required this.currentPly,
    required this.playerColor,
    required this.opponentColor,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
    required this.labelBackground,
    this.division = GameDivision.empty,
  });

  final List<WinChartPoint> points;
  final int currentPly;
  final GameDivision division;
  final Color playerColor;
  final Color opponentColor;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;
  final Color labelBackground;

  /// The verdicts worth a dot.
  static bool isTurningPoint(Classification c) => c.isTurningPoint;

  /// Where point [index] of [count] sits; shared with the callout.
  static double xOf(int index, int count, double width) =>
      count < 2 ? 0 : width * index / (count - 1);

  static double yOf(double winPct, double height) =>
      height * (1 - winPct / 100);

  @override
  void paint(Canvas canvas, Size size) {
    // The box is the opponent's; the area under the curve is the player's.
    canvas.drawRect(Offset.zero & size, Paint()..color = opponentColor);

    if (points.length < 2) {
      _drawMidline(canvas, size);
      return;
    }

    double xOf(int index) =>
        WinChartPainter.xOf(index, points.length, size.width);
    double yOf(double winPct) => WinChartPainter.yOf(winPct, size.height);

    final curve = Path()..moveTo(0, yOf(points.first.winPct));
    for (var i = 1; i < points.length; i++) {
      // Straight segments: a spline would overshoot past 0 % or 100 %.
      curve.lineTo(xOf(i), yOf(points[i].winPct));
    }

    final area = Path.from(curve)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = playerColor);

    _drawMidline(canvas, size);

    canvas.drawPath(
      curve,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Turning points, ringed to read against either fill. Never book moves.
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final classification = point.classification;
      if (point.isBook || classification == null) continue;
      if (!isTurningPoint(classification)) continue;
      final centre = Offset(xOf(i), yOf(point.winPct));
      canvas.drawCircle(
        centre,
        4,
        Paint()..color = classificationColor(classification),
      );
      canvas.drawCircle(
        centre,
        4,
        Paint()
          ..color = opponentColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    _drawPhases(canvas, size);

    final cursorIndex = points.indexWhere((p) => p.ply == currentPly);
    if (cursorIndex >= 0) {
      final x = xOf(cursorIndex);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = lineColor.withValues(alpha: 0.6)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(x, yOf(points[cursorIndex].winPct)),
        3.5,
        Paint()..color = lineColor,
      );
    }
  }

  /// A dashed rule per phase boundary, labelled with the phase that STARTS
  /// there.
  void _drawPhases(Canvas canvas, Size size) {
    final boundaries = <(int, String)>[];
    final middle = division.middle;
    final end = division.end;
    if (middle != null) boundaries.add((middle, GamePhase.middlegame.label));
    if (end != null) boundaries.add((end, GamePhase.endgame.label));

    double? lastLabelRight;
    for (final (ply, label) in boundaries) {
      final index = points.indexWhere((p) => p.ply == ply);
      // Not reached by the sweep yet.
      if (index < 0) continue;
      final x = xOf(index, points.length, size.width);
      _drawDashedRule(canvas, x, size.height);
      lastLabelRight = _drawPhaseLabel(canvas, x, size, label, lastLabelRight);
    }
  }

  /// Dashed and faint, so it cannot be mistaken for the solid cursor line.
  void _drawDashedRule(Canvas canvas, double x, double height) {
    final paint = Paint()
      ..color = lineColor.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var y = 0.0; y < height; y += 6) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3, height)), paint);
    }
  }

  /// Draws [label] beside the rule at [x] and returns its right edge. Skips
  /// it (returning [lastRight]) when it would overlap the previous chip.
  double? _drawPhaseLabel(
    Canvas canvas,
    double x,
    Size size,
    String label,
    double? lastRight,
  ) {
    const gap = 3.0;
    const padX = 4.0;
    const padY = 2.0;

    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: labelColor,
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final width = text.width + padX * 2;
    final height = text.height + padY * 2;
    // Right of the rule, or left of it near the chart's end.
    var left = x + gap;
    if (left + width > size.width) left = x - gap - width;
    left = left.clamp(0.0, math.max(0.0, size.width - width));
    if (lastRight != null && left < lastRight + 2) return lastRight;

    final rect = Rect.fromLTWH(left, padY, width, height);
    final chip = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(chip, Paint()..color = labelBackground);
    canvas.drawRRect(
      chip,
      Paint()
        ..color = gridColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    text.paint(canvas, Offset(left + padX, padY * 2));
    return rect.right;
  }

  void _drawMidline(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 10) {
      canvas.drawLine(Offset(x, y), Offset(x + 6, y), paint);
    }
  }

  @override
  bool shouldRepaint(WinChartPainter oldDelegate) =>
      oldDelegate.currentPly != currentPly ||
      oldDelegate.playerColor != playerColor ||
      // GameDivision has no value equality.
      oldDelegate.division.middle != division.middle ||
      oldDelegate.division.end != division.end ||
      !listEquals(oldDelegate.points, points);
}
