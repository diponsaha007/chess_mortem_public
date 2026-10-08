import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/widgets/move_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 *
''';

void main() {
  Future<GameNode> pumpList(
    WidgetTester tester,
    GameTree tree,
    GameNode current,
  ) async {
    var tapped = tree.root;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveList(
            tree: tree,
            current: current,
            onTap: (node) => tapped = node,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tapped;
  }

  testWidgets('the mainline is one horizontally-scrolling strip', (
    tester,
  ) async {
    final tree = GameTree.fromPgn(_pgn);
    await pumpList(tester, tree, tree.root);

    final scrollables = find.descendant(
      of: find.byType(MoveList),
      matching: find.byType(Scrollable),
    );
    expect(scrollables, findsOne);
    expect(
      tester.widget<Scrollable>(scrollables).axisDirection,
      AxisDirection.right,
    );
  });

  testWidgets('back at the start, the strip scrolls back to the first move', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Twenty knight shuffles: far wider than a phone.
    final moves = [
      for (var i = 0; i < 20; i++)
        i.isEven ? '${i + 1}. Nf3 Nf6' : '${i + 1}. Ng1 Ng8',
    ].join(' ');
    final tree = GameTree.fromPgn('[Event "Test"]\n\n$moves *\n');
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(MoveList),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    // Following the sweep to the last move, then the sweep returns home.
    await pumpList(tester, tree, tree.mainline.last);
    expect(offset(), greaterThan(0));
    await pumpList(tester, tree, tree.root);
    expect(offset(), 0);
  });

  testWidgets('the strip is short enough to leave the board room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tree = GameTree.fromPgn(_pgn);
    await pumpList(tester, tree, tree.mainline.last);

    expect(tester.getSize(find.byType(MoveList)).height, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a variation gets its own strip only while the cursor is in it', (
    tester,
  ) async {
    final tree = GameTree.fromPgn(_pgn);
    final afterE4 = tree.mainline.first;
    // A what-if reply to 1.e4: a sibling of the mainline 1...e5.
    final whatIf = tree.addMove(
      afterE4,
      afterE4.position.parseSan('c5')!,
      isUserMove: true,
    );

    // Cursor on the mainline, well past the fork: only the mainline strip.
    await pumpList(tester, tree, tree.mainline.last);
    expect(find.text('1...c5'), findsNothing);

    // Cursor inside the variation: its strip appears.
    await pumpList(tester, tree, whatIf);
    expect(find.text('1...c5'), findsOne);
    expect(
      find.descendant(
        of: find.byType(MoveList),
        matching: find.byType(Scrollable),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('an alternative shows up when the cursor sits on the fork', (
    tester,
  ) async {
    final tree = GameTree.fromPgn(_pgn);
    final afterE4 = tree.mainline.first;
    tree.addMove(afterE4, afterE4.position.parseSan('c5')!, isUserMove: true);

    // Standing on 1...e5, the what-if sibling is worth showing.
    await pumpList(tester, tree, tree.mainline[1]);
    expect(find.text('1...c5'), findsOne);
  });

  testWidgets('move numbers are bold and the piece is drawn as a glyph', (
    tester,
  ) async {
    final tree = GameTree.fromPgn(_pgn);
    await pumpList(tester, tree, tree.root);

    // "2." is bold, "f3" is not — the SAN's leading N became the glyph.
    final rich = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere(
          (t) => t.textSpan?.toPlainText() == '2.f3',
          orElse: () => throw StateError('no chip for 2.Nf3'),
        );
    final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.text, '2.');
    expect(spans.first.style?.fontWeight, FontWeight.bold);
    expect(spans.last.text, 'f3');

    // One image per move: the piece that played it.
    expect(
      find.descendant(of: find.byType(MoveList), matching: find.byType(Image)),
      findsNWidgets(tree.mainline.length),
    );
  });

  testWidgets('tapping a move reports it', (tester) async {
    final tree = GameTree.fromPgn(_pgn);
    var tapped = tree.root;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveList(
            tree: tree,
            current: tree.root,
            onTap: (node) => tapped = node,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('1.e4'));
    expect(tapped, tree.mainline.first);
  });

  testWidgets('every verdict has a badge that fits the board', (tester) async {
    // The badge is drawn on the board through chessground's annotations,
    // which take two characters of text and nothing else — so a symbol that
    // ran long would be cut off there and read as a different verdict.
    for (final tier in Classification.values) {
      expect(
        classificationSymbol(tier).length,
        lessThanOrEqualTo(2),
        reason: tier.label,
      );
    }
    // Excellent and good are the same tick in two greens on purpose; nothing
    // else may double up.
    final symbols = Classification.values.map(classificationSymbol).toSet();
    expect(symbols, hasLength(Classification.values.length - 1));
    expect(
      classificationSymbol(Classification.excellent),
      classificationSymbol(Classification.good),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final tier in Classification.values)
                ClassificationBadge(classification: tier),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
