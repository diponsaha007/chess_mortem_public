import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/coach_line.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/model/move_tags.dart';
import 'package:chess_mortem/widgets/coach_bar.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// One analysed move: e4 played from the start, scored either side of it.
GameNode _move({
  required Classification classification,
  int cpBefore = 20,
  int cpAfter = 20,
  String bestBefore = 'e2e4',
  String played = 'e2e4',
  String reply = 'e7e5',
}) {
  final tree = GameTree.empty();
  tree.root.eval = EngineEval(cp: cpBefore, bestMoveUci: bestBefore, depth: 15);
  final node = tree.addMove(tree.root, Move.parse(played)!);
  node.eval = EngineEval(cp: cpAfter, bestMoveUci: reply, depth: 15);
  node.classification = classification;
  return node;
}

void main() {
  group('the coach bar', () {
    const long =
        'Black sacrifices the knight on a4 and comes out a pawn up. Pure art.';

    for (final (size, scale) in [
      (const Size(360, 740), 1.0),
      (const Size(360, 740), 1.3),
      (const Size(320, 568), 1.0),
    ]) {
      testWidgets('shows three whole lines at $size, text x$scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final node = _move(
          classification: Classification.brilliant,
          bestBefore: 'd2d4',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: CoachBar(node: node, line: long, onTap: () {}),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(CoachBar),
            matching: find.textContaining('sacrifices'),
          ),
        );
        // Three lines, none clipped by the bar's fixed height.
        final lineHeight = paragraph.getFullHeightForCaret(
          const TextPosition(offset: 0),
        );
        expect((paragraph.size.height / lineHeight).round(), CoachBar.lines);
        expect(
          paragraph.size.height,
          lessThanOrEqualTo(tester.getSize(find.byType(CoachBar)).height - 8),
        );
      });
    }
  });

  group('moveSummaryLine', () {
    // With no API key configured this line IS the explanation, and board
    // code is its only author — so it cannot say something the
    // badge next to it contradicts.
    test('Brilliant says what the badge means, not what the numbers say', () {
      // Not the engine's move and no drop: must not read "Held the position,
      // though … was sharper" under a "!!".
      final node = _move(
        classification: Classification.brilliant,
        bestBefore: 'd2d4',
      );
      expect(moveSummaryLine(node), 'Gave up material — and it works.');
    });

    test('Great says it was the only move', () {
      // Always the engine's move, but must not read "The engine's first
      // choice."
      final node = _move(classification: Classification.great);
      expect(moveSummaryLine(node), 'The only good move here.');
    });

    test(
      'Miss says the gift was let go, and names the move that punished it',
      () {
        // Not "Gave up N%": the percentage reads as a blunder, and the point is
        // the opponent's gift.
        final node = _move(
          classification: Classification.miss,
          cpBefore: 500,
          cpAfter: 20,
          bestBefore: 'd2d4',
        );
        expect(
          moveSummaryLine(node),
          "Let the opponent's mistake go — d4 would have punished it.",
        );
      },
    );

    test('Best, Blunder and Excellent each get their own summary', () {
      expect(
        moveSummaryLine(_move(classification: Classification.best)),
        "The engine's first choice.",
      );
      expect(
        moveSummaryLine(
          _move(
            classification: Classification.blunder,
            cpBefore: 300,
            cpAfter: -300,
          ),
        ),
        startsWith('Gave up '),
      );
      expect(
        moveSummaryLine(
          _move(classification: Classification.excellent, bestBefore: 'd2d4'),
        ),
        'Held the position, though d4 was sharper.',
      );
    });

    test('a tagged slip names the tactic, not the percentage', () {
      // White's king steps off e3, leaving the knight on d4 to the bishop.
      final root = GameNode(
        position: Chess.fromSetup(
          Setup.parseFen('4k3/8/1b6/8/3N4/4K3/8/8 w - - 0 1'),
        ),
      )..eval = EngineEval(cp: 0, bestMoveUci: 'e3e4', depth: 15);
      final played = Move.parse('e3e2')!;
      final node =
          GameNode(
              position: root.position.play(played),
              parent: root,
              move: played,
              san: 'Ke2',
            )
            ..eval = EngineEval(
              cp: -300,
              bestMoveUci: 'b6d4',
              pvUci: const ['b6d4'],
              depth: 15,
            )
            ..classification = Classification.blunder;
      expect(moveSummaryLine(node), 'Left the knight hanging.');
    });

    test('an unanalysed move says so rather than guessing', () {
      final tree = GameTree.empty();
      final node = tree.addMove(tree.root, Move.parse('e2e4')!);
      expect(moveSummaryLine(node), 'Not analyzed yet.');
      expect(moveSummaryLine(tree.root), 'Starting position.');
    });
  });

  group('tacticSummaryLine', () {
    MoveTags allowing(String fen, List<String> pv) => MoveTags(
      allowed: readLine(start: Chess.fromSetup(Setup.parseFen(fen)), pvUci: pv),
    );

    test('a mate allowed comes first', () {
      expect(
        tacticSummaryLine(
          allowing('6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1', ['a1a8']),
        ),
        'Allowed a back-rank mate.',
      );
    });

    test('material lost to a tactic names both', () {
      expect(
        tacticSummaryLine(
          allowing('r3k3/8/8/3N4/8/8/8/4K3 w - - 0 1', [
            'd5c7',
            'e8d8',
            'c7a8',
          ]),
        ),
        'Allowed a fork that wins the rook.',
      );
    });

    test('a missed win is said when nothing was allowed', () {
      final missed = readLine(
        start: Chess.fromSetup(
          Setup.parseFen('4q3/8/8/4k3/8/8/8/R5K1 w - - 0 1'),
        ),
        pvUci: const ['a1e1', 'e5d5', 'e1e8'],
      );
      expect(
        tacticSummaryLine(MoveTags(missed: missed)),
        'Missed a skewer that wins the queen.',
      );
    });

    test('no tactic, no line', () {
      expect(tacticSummaryLine(MoveTags.none), isNull);
    });
  });

  group('coachLine', () {
    test('the book name still outranks every computed line', () {
      // A fact about the position beats a verdict about the move.
      final node = _move(classification: Classification.brilliant)
        ..openingName = 'C20 King\'s Pawn Game';
      expect(coachLine(node), 'C20 King\'s Pawn Game');
    });

    test('an analysed move gets the concept line, in the user\'s voice', () {
      // A knight leaving home: a concept line, not a close call with praise.
      final node = _move(
        classification: Classification.best,
        bestBefore: 'g1f3',
        played: 'g1f3',
        reply: 'd7d5',
      );
      // Which concept is the ranker's call; the voice is this test's.
      final mine = coachLine(node, userSide: Side.white);
      final theirs = coachLine(node, userSide: Side.black);
      final neutral = coachLine(node);
      expect(mine, startsWith('You '));
      expect(theirs, startsWith('Your opponent '));
      expect(neutral, startsWith('White '));
      // One concept, conjugated for its subject: "You open", "White opens".
      expect(
        theirs.substring('Your opponent '.length),
        neutral.substring('White '.length),
      );
      expect(mine, isNot(neutral.replaceFirst('White', 'You')));
    });

    test('before the engine is done it falls back to the summary', () {
      final tree = GameTree.empty();
      final node = tree.addMove(tree.root, Move.parse('e2e4')!);
      expect(coachLine(node), 'Not analyzed yet.');
      expect(coachLine(tree.root), 'Starting position.');
    });
  });
}
