import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/widgets/eval_bar.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<double?> pumpBar(WidgetTester tester, Side orientation) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: EvalBar(
              // +3 pawns: clearly winning for White.
              eval: const EngineEval(cp: 300, bestMoveUci: 'e2e4', depth: 15),
              height: 200,
              orientation: orientation,
            ),
          ),
        ),
      ),
    );
    return tester
        .widget<AnimatedFractionallySizedBox>(
          find.byType(AnimatedFractionallySizedBox),
        )
        .heightFactor;
  }

  testWidgets('the side at the bottom grows from the bottom', (tester) async {
    // White is winning, so with White at the bottom the bar is mostly filled.
    expect(await pumpBar(tester, Side.white), greaterThan(0.5));
    // Flipped: the same eval leaves Black's (bottom) share small.
    expect(await pumpBar(tester, Side.black), lessThan(0.5));
  });

  testWidgets('an unevaluated position sits at the halfway mark', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: EvalBar(eval: null, height: 200, orientation: Side.white),
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<AnimatedFractionallySizedBox>(
            find.byType(AnimatedFractionallySizedBox),
          )
          .heightFactor,
      0.5,
    );
  });

  group('the numeric score', () {
    test('reads as pawns from White\'s point of view', () {
      String? label(int cp) => EvalBar.scoreLabel(
        EngineEval(cp: cp, bestMoveUci: 'e2e4', depth: 15),
      );

      expect(label(0), '+0.0');
      expect(label(120), '+1.2');
      expect(label(-80), '-0.8');
      // Big scores drop the decimal so they still fit the bar's width.
      expect(label(1540), '+15');
    });

    test('a forced mate reads as M<n>', () {
      String? label(int mateIn) => EvalBar.scoreLabel(
        EngineEval(mateIn: mateIn, bestMoveUci: 'e2e4', depth: 15),
      );

      expect(label(3), 'M3');
      expect(label(-2), '-M2');
    });

    test(
      'a mate already delivered reads as #, and fills the winner\'s end',
      () {
        const mated = EngineEval.checkmate(mated: Side.black, depth: 0);
        expect(EvalBar.scoreLabel(mated), '#');
        // Not "M0", and above all not a bar that has swung to the loser.
        expect(mated.winPctWhite, greaterThan(90));
      },
    );

    test('an unevaluated position has no label', () {
      expect(EvalBar.scoreLabel(null), isNull);
    });

    Future<void> pumpEvalBar(
      WidgetTester tester,
      int cp,
      Side orientation,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: EvalBar(
                eval: EngineEval(cp: cp, bestMoveUci: 'e2e4', depth: 15),
                height: 200,
                orientation: orientation,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the label is drawn on the winning side of the bar', (
      tester,
    ) async {
      Future<Alignment> alignmentFor(int cp, Side orientation) async {
        await pumpEvalBar(tester, cp, orientation);
        return tester
                .widget<Align>(
                  find
                      .descendant(
                        of: find.byType(EvalBar),
                        matching: find.byType(Align),
                      )
                      .last,
                )
                .alignment
            as Alignment;
      }

      // White ahead, White at the bottom: the number sits at the bottom.
      expect(await alignmentFor(300, Side.white), Alignment.bottomCenter);
      // Same eval, board flipped: White's block is now the top one.
      expect(await alignmentFor(300, Side.black), Alignment.topCenter);
      // Black ahead with White at the bottom: the number goes to the top.
      expect(await alignmentFor(-300, Side.white), Alignment.topCenter);
    });

    testWidgets('the ink always contrasts with the block it sits in', (
      tester,
    ) async {
      Future<Color?> inkFor(int cp, Side orientation) async {
        await pumpEvalBar(tester, cp, orientation);
        return tester
            .widget<Text>(
              find.descendant(
                of: find.byType(EvalBar),
                matching: find.byType(Text),
              ),
            )
            .style
            ?.color;
      }

      // Each case lands the label in a different block; all four must be
      // legible, which the first version of this bar got wrong.
      expect(await inkFor(300, Side.white), Colors.black); // on White, bottom
      expect(await inkFor(300, Side.black), Colors.black); // on White, top
      expect(await inkFor(-300, Side.white), Colors.white); // on Black, top
      expect(await inkFor(-300, Side.black), Colors.white); // on Black, bottom
    });

    testWidgets('the coloured blocks fill the whole bar', (tester) async {
      // Inside a Stack without StackFit.expand the coloured box collapses to
      // its child and the page shows through the rest.
      await pumpEvalBar(tester, 300, Side.white);

      final barSize = tester.getSize(find.byType(EvalBar));
      final painted = tester.getSize(
        find.descendant(
          of: find.byType(EvalBar),
          matching: find.byType(AnimatedFractionallySizedBox),
        ),
      );
      expect(painted.height, barSize.height);
      expect(painted.width, barSize.width);
    });
  });
}
