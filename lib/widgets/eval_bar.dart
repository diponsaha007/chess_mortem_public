import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../model/eval.dart';

/// The advantage bar beside the board, driven by winning chances. It mirrors
/// with the board, and the score sits at the leading side's end.
class EvalBar extends StatelessWidget {
  const EvalBar({
    super.key,
    required this.eval,
    required this.height,
    required this.orientation,
  });

  static const double width = 20;

  final EngineEval? eval;
  final double height;

  /// The side at the bottom of the board.
  final Side orientation;

  /// White-perspective score: "+1.2", "-0.8", "M3", "-M2", "#" once the mate
  /// has been delivered.
  static String? scoreLabel(EngineEval? eval) {
    if (eval == null) return null;
    // Checkmate is not "M0": there is no mate to come, and 0 carries no sign.
    if (eval.isCheckmate) return '#';
    final mateIn = eval.mateIn;
    if (mateIn != null) return mateIn > 0 ? 'M$mateIn' : '-M${-mateIn}';
    final pawns = eval.pawns;
    final text = pawns.abs().toStringAsFixed(pawns.abs() >= 10 ? 0 : 1);
    return pawns >= 0 ? '+$text' : '-$text';
  }

  @override
  Widget build(BuildContext context) {
    final bottomIsWhite = orientation == Side.white;
    final whiteFraction = (eval?.winPctWhite ?? 50) / 100;
    final bottomFraction = (bottomIsWhite ? whiteFraction : 1 - whiteFraction)
        .clamp(0.0, 1.0);

    // Ink is derived from the fill at each end, never from who leads.
    final bottomFill = bottomIsWhite ? Colors.white : Colors.black;
    final topFill = bottomIsWhite ? Colors.black : Colors.white;

    final label = scoreLabel(eval);
    final whiteAhead = whiteFraction >= 0.5;
    final labelAtBottom = whiteAhead == bottomIsWhite;
    final labelFill = labelAtBottom ? bottomFill : topFill;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        // Required, or the box collapses and the page shows through.
        fit: StackFit.expand,
        children: [
          Container(
            color: topFill,
            child: AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 300),
              alignment: Alignment.bottomCenter,
              heightFactor: bottomFraction,
              child: Container(color: bottomFill),
            ),
          ),
          if (label != null)
            Align(
              alignment: labelAtBottom
                  ? Alignment.bottomCenter
                  : Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 3),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 9.5,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      color: labelFill == Colors.white
                          ? Colors.black
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
