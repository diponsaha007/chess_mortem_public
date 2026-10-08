import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_phase.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/model/win_chart.dart';
import 'package:chess_mortem/widgets/move_list.dart' show ClassificationBadge;
import 'package:chess_mortem/widgets/win_chart.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 *
''';

GameTree _treeWithEvals(List<int?> cps) {
  final tree = GameTree.fromPgn(_pgn);
  final nodes = [tree.root, ...tree.mainline];
  for (var i = 0; i < cps.length; i++) {
    final cp = cps[i];
    nodes[i].eval = cp == null
        ? null
        : EngineEval(cp: cp, bestMoveUci: 'e2e4', depth: 15);
  }
  return tree;
}

void main() {
  group('buildWinChartPoints', () {
    test('plots White-perspective chances for White', () {
      final tree = _treeWithEvals([0, 300, 300, 300, 300]);
      final points = buildWinChartPoints(
        root: tree.root,
        mainline: tree.mainline,
        perspective: Side.white,
      );

      expect(points, hasLength(5));
      expect(points.first.ply, 0);
      expect(points.first.winPct, closeTo(50, 0.001));
      expect(points[1].winPct, greaterThan(50));
    });

    test('mirrors for Black, so the graph follows the board orientation', () {
      final tree = _treeWithEvals([0, 300, 300, 300, 300]);
      final white = buildWinChartPoints(
        root: tree.root,
        mainline: tree.mainline,
        perspective: Side.white,
      );
      final black = buildWinChartPoints(
        root: tree.root,
        mainline: tree.mainline,
        perspective: Side.black,
      );

      for (var i = 0; i < white.length; i++) {
        expect(black[i].winPct, closeTo(100 - white[i].winPct, 0.001));
      }
    });

    test('stops at the first unevaluated position', () {
      final tree = _treeWithEvals([0, 20, null, null, null]);
      final points = buildWinChartPoints(
        root: tree.root,
        mainline: tree.mainline,
        perspective: Side.white,
      );
      expect(points, hasLength(2));
    });

    test('carries the verdict and book status of each move', () {
      final tree = _treeWithEvals([0, 20, 20, 20, 20]);
      tree.mainline.first.classification = Classification.blunder;
      tree.mainline.first.openingName = 'B00 King\'s Pawn Game';

      final points = buildWinChartPoints(
        root: tree.root,
        mainline: tree.mainline,
        perspective: Side.white,
      );
      expect(points[1].classification, Classification.blunder);
      expect(points[1].isBook, isTrue);
      expect(points.first.classification, isNull);
    });
  });

  group('WinChart', () {
    const points = [
      WinChartPoint(ply: 0, winPct: 50, classification: null, isBook: false),
      WinChartPoint(ply: 1, winPct: 60, classification: null, isBook: false),
      WinChartPoint(ply: 2, winPct: 40, classification: null, isBook: false),
      WinChartPoint(ply: 3, winPct: 70, classification: null, isBook: false),
      WinChartPoint(ply: 4, winPct: 20, classification: null, isBook: false),
    ];

    Future<List<int>> pumpAndTapAt(WidgetTester tester, double fraction) async {
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: WinChart(
                points: points,
                currentPly: 0,
                onSelectPly: selected.add,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(WinChart));
      await tester.tapAt(
        Offset(rect.left + rect.width * fraction, rect.center.dy),
      );
      await tester.pump();
      return selected;
    }

    testWidgets('tapping maps the x position to the nearest ply', (
      tester,
    ) async {
      expect(await pumpAndTapAt(tester, 0.0), [0]);
      expect(await pumpAndTapAt(tester, 0.5), [2]);
      expect(await pumpAndTapAt(tester, 0.99), [4]);
    });

    testWidgets('an empty chart renders without exploding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WinChart(points: [], currentPly: 0, onSelectPly: _ignore),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('turning points', () {
    // The dots on the curve. Marking only the mistakes said half of what the
    // graph knows: a game is turned by the moves that won it too.
    test('are the two verdicts above Best and the two below Inaccuracy', () {
      for (final marked in [
        Classification.brilliant,
        Classification.great,
        Classification.mistake,
        Classification.blunder,
      ]) {
        expect(
          WinChartPainter.isTurningPoint(marked),
          isTrue,
          reason: '$marked should be marked',
        );
      }
      // Inaccuracy stays unmarked, as it always was: a sharp game has one
      // every few moves, and the graph would be a row of dots.
      for (final plain in [
        Classification.best,
        Classification.excellent,
        Classification.good,
        Classification.inaccuracy,
      ]) {
        expect(
          WinChartPainter.isTurningPoint(plain),
          isFalse,
          reason: '$plain is the ordinary run of a game',
        );
      }
    });
  });

  group('phase boundaries', () {
    const points = [
      WinChartPoint(ply: 0, winPct: 50, classification: null, isBook: false),
      WinChartPoint(ply: 1, winPct: 60, classification: null, isBook: false),
      WinChartPoint(ply: 2, winPct: 40, classification: null, isBook: false),
      WinChartPoint(ply: 3, winPct: 70, classification: null, isBook: false),
      WinChartPoint(ply: 4, winPct: 20, classification: null, isBook: false),
    ];

    WinChartPainter painterWith(GameDivision division) => WinChartPainter(
      points: points,
      currentPly: 0,
      division: division,
      playerColor: const Color(0xFF000000),
      opponentColor: const Color(0xFF111111),
      lineColor: const Color(0xFF222222),
      gridColor: const Color(0xFF333333),
      labelColor: const Color(0xFF444444),
      labelBackground: const Color(0xFF555555),
    );

    testWidgets('a divided game draws without exploding', (tester) async {
      // The boundaries are ply numbers, and one of them can sit past the end
      // of what has been analysed so far — the curve stops at the first
      // unevaluated position, so a rule for it must simply not be drawn.
      for (final division in const [
        GameDivision(plies: 5),
        GameDivision(middle: 2, plies: 5),
        GameDivision(middle: 2, end: 4, plies: 5),
        GameDivision(middle: 2, end: 40, plies: 5),
        // The odd case Divider.scala allows: an endgame at or before the
        // middlegame drops the middlegame and keeps the endgame.
        GameDivision(end: 1, plies: 5),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: WinChart(
                  points: points,
                  currentPly: 0,
                  division: division,
                  onSelectPly: _ignore,
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: '$division');
      }
    });

    test('repaints when the division moves', () {
      // The sweep streams in, so the boundaries shift while the chart is on
      // screen; a painter that ignores them draws a stale rule.
      final settled = painterWith(
        const GameDivision(middle: 2, end: 4, plies: 5),
      );
      expect(
        settled.shouldRepaint(
          painterWith(const GameDivision(middle: 1, end: 4, plies: 5)),
        ),
        isTrue,
      );
      expect(
        settled.shouldRepaint(
          painterWith(const GameDivision(middle: 2, plies: 5)),
        ),
        isTrue,
      );
      expect(
        settled.shouldRepaint(
          painterWith(const GameDivision(middle: 2, end: 4, plies: 5)),
        ),
        isFalse,
      );
    });
  });

  group('WinChart callout', () {
    const named = [
      WinChartPoint(ply: 0, winPct: 50, classification: null, isBook: false),
      WinChartPoint(
        ply: 1,
        winPct: 55,
        classification: Classification.best,
        isBook: true,
      ),
      WinChartPoint(
        ply: 2,
        winPct: 40,
        classification: Classification.blunder,
        isBook: false,
      ),
    ];

    Future<void> pumpAt(WidgetTester tester, int currentPly) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: WinChart(
                  points: named,
                  currentPly: currentPly,
                  onSelectPly: _ignore,
                ),
              ),
            ),
          ),
        );

    testWidgets('marks the cursor with the verdict badge and nothing else', (
      tester,
    ) async {
      await pumpAt(tester, 2);

      // The same badge as the board and the move strips.
      expect(
        find.descendant(
          of: find.byKey(winChartCalloutKey),
          matching: find.byType(ClassificationBadge),
        ),
        findsOneWidget,
      );
      // On a 130px chart the move number, the move and the word "Blunder"
      // were most of the graph, and the cursor line already says which move
      // this is.
      expect(find.textContaining('Bxf7'), findsNothing);
      expect(find.text('Blunder'), findsNothing);
    });

    testWidgets('a book move gets the book icon instead', (tester) async {
      await pumpAt(tester, 1);
      expect(find.byIcon(Icons.menu_book), findsOneWidget);
      expect(find.byType(ClassificationBadge), findsNothing);
      expect(find.text('Book'), findsNothing);
    });

    testWidgets('there is nothing to judge at the starting position', (
      tester,
    ) async {
      await pumpAt(tester, 0);
      expect(find.byKey(winChartCalloutKey), findsNothing);
    });

    testWidgets('stays inside the chart at either end', (tester) async {
      final chart = find.byType(WinChart);
      for (final ply in [1, 2]) {
        await pumpAt(tester, ply);
        final bubble = tester.getRect(find.byKey(winChartCalloutKey));
        final box = tester.getRect(chart);
        expect(bubble.left, greaterThanOrEqualTo(box.left - 0.01));
        expect(bubble.right, lessThanOrEqualTo(box.right + 0.01));
        expect(bubble.top, greaterThanOrEqualTo(box.top - 0.01));
        expect(bubble.bottom, lessThanOrEqualTo(box.bottom + 0.01));
      }
    });

    // The two ends are the easy cases; the badge is centred ON the point, so
    // every winning chance puts half of it over an edge unless the clamp
    // holds.
    testWidgets('stays inside the chart at every winning chance', (
      tester,
    ) async {
      for (var pct = 0; pct <= 100; pct++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: WinChart(
                  points: [
                    named.first,
                    WinChartPoint(
                      ply: 1,
                      winPct: pct.toDouble(),
                      classification: Classification.blunder,
                      isBook: false,
                    ),
                    named.last,
                  ],
                  currentPly: 1,
                  onSelectPly: _ignore,
                ),
              ),
            ),
          ),
        );
        final bubble = tester.getRect(find.byKey(winChartCalloutKey));
        final box = tester.getRect(find.byType(WinChart));
        expect(
          bubble.top,
          greaterThanOrEqualTo(box.top - 0.01),
          reason: 'clipped off the top at $pct%',
        );
        expect(
          bubble.bottom,
          lessThanOrEqualTo(box.bottom + 0.01),
          reason: 'clipped off the bottom at $pct%',
        );
      }
    });

    // `_callout` places the marker from this constant, because Positioned
    // needs a height before the child is laid out. If the marker's contents
    // ever grow, the constant has to grow with them.
    testWidgets('the marker is as tall as the layout assumes', (tester) async {
      await pumpAt(tester, 2);
      expect(
        tester.getSize(find.byKey(winChartCalloutKey)).height,
        WinChart.calloutHeight,
      );
    });
  });
}

void _ignore(int ply) {}
