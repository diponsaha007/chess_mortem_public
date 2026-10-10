import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_result.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/share/game_gif.dart';
import 'package:chess_mortem/share/gif_frames.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6?? 4.Qxf7#, analysed by hand.
GameTree _analysedGame() {
  final tree = GameTree.fromPgn('1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0');
  final moves = tree.mainline;
  for (final node in [tree.root, ...moves]) {
    node.eval = const EngineEval(cp: 30, bestMoveUci: 'e2e4', depth: 15);
    node.classification = Classification.best;
  }
  moves[0].openingName = "King's Pawn";
  // Black's 3rd move: the parent's eval says g6 instead.
  moves[5].parent!.eval = const EngineEval(
    cp: 30,
    bestMoveUci: 'g7g6',
    depth: 15,
  );
  moves[5].classification = Classification.blunder;
  moves[6].eval = const EngineEval.checkmate(mated: Side.black, depth: 0);
  return tree;
}

void main() {
  test('one frame for the start, one per mainline move, then the summary', () {
    final tree = _analysedGame();
    final frames = gifFramesFor(tree);
    expect(frames, hasLength(tree.mainline.length + 2));
    expect(frames.where((f) => f.summary != null), [frames.last]);
    expect(frames.last.duration, gifSummaryDuration);
    expect(frames.first.lastMove, isNull);
    expect(frames.first.badgeSquare, isNull);
    expect(frames.first.board, tree.root.position.board);
    expect(frames[1].lastMove, (Square.e2, Square.e4));
    expect(frames[frames.length - 2].board, tree.mainline.last.position.board);
  });

  test('turning points hold longer; the last frame longest', () {
    final frames = gifFramesFor(_analysedGame());
    expect(frames.first.duration, gifStartDuration);
    expect(frames[2].duration, gifMoveDuration);
    expect(frames[6].duration, gifKeyMoveDuration); // the blunder
    expect(frames[frames.length - 2].duration, gifEndDuration);
  });

  test('a book move shows the book mark and never holds the frame', () {
    final tree = _analysedGame();
    tree.mainline[0].classification = Classification.mistake;
    final frame = gifFramesFor(tree)[1];
    expect(frame.isBook, isTrue);
    expect(frame.badgeSquare, Square.e4);
    expect(frame.duration, gifMoveDuration);
    expect(frame.arrow, isNull);
  });

  test('the better-move arrow comes from the parent, on a mistake or worse '
      'only', () {
    final frames = gifFramesFor(_analysedGame());
    expect(frames[6].arrow, (Square.g7, Square.g6));
    expect(frames[6].classification, Classification.blunder);
    // Best moves elsewhere: no arrows.
    expect(frames.where((f) => f.arrow != null), hasLength(1));
  });

  test('the eval bar reads the position after the move', () {
    final frames = gifFramesFor(_analysedGame());
    expect(frames[frames.length - 2].eval!.isCheckmate, isTrue);
  });

  test('moves are numbered as in a score sheet', () {
    final frames = gifFramesFor(_analysedGame());
    expect(frames.first.moveLabel, isNull);
    expect(frames[1].moveLabel, '1. e4');
    expect(frames[6].moveLabel, '3… Nf6');
  });

  test('a coach line goes on turning points and the last move only, held '
      'long enough to read', () {
    final tree = _analysedGame();
    final frames = gifFramesFor(
      tree,
      coachLineFor: (node) => 'line for ${node.san}',
    );
    expect(
      [
        for (final f in frames)
          if (f.coachLine != null) f.coachLine,
      ],
      ['line for Nf6', 'line for Qxf7#'],
    );
    expect(frames[6].duration, gifCaptionDuration);
    expect(frames[frames.length - 2].duration, gifCaptionDuration);
    expect(frames[2].duration, gifMoveDuration);
  });

  test('without coach lines the timing is unchanged', () {
    final frames = gifFramesFor(_analysedGame());
    expect(frames.every((f) => f.coachLine == null), isTrue);
    expect(frames[6].duration, gifKeyMoveDuration);
  });

  test('the summary counts each side\'s verdicts, book apart, and scores '
      'accuracy', () {
    final tree = GameTree.fromPgn(
      '[White "Ann Example"]\n[Black "Ben Sample"]\n[WhiteElo "1850"]\n'
      '[Result "1-0"]\n\n1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0',
    );
    final moves = tree.mainline;
    for (final node in [tree.root, ...moves]) {
      node.eval = const EngineEval(cp: 30, bestMoveUci: 'e2e4', depth: 15);
      node.classification = Classification.best;
    }
    moves[0].openingName = "King's Pawn";
    moves[1].openingName = "King's Pawn Game";
    moves[5].classification = Classification.blunder;
    final summary = gifFramesFor(tree).last.summary!;

    expect(summary.result, GameResult.whiteWon);
    expect(summary.opening, "King's Pawn Game");
    expect(summary.white.name, 'Ann Example');
    expect(summary.white.rating, '1850');
    expect(summary.black.rating, isNull);
    expect(summary.white.bookMoves, 1);
    expect(summary.white.counts, {Classification.best: 3});
    expect(summary.black.bookMoves, 1);
    expect(summary.black.counts, {
      Classification.best: 1,
      Classification.blunder: 1,
    });
    expect(summary.white.accuracy, isNotNull);
    expect(summary.black.accuracy, isNotNull);
  });

  test('a game with no moves has no summary card', () {
    final frames = gifFramesFor(GameTree.fromPgn('[Event "x"]\n\n*'));
    expect(frames.every((f) => f.summary == null), isTrue);
  });

  test('the file is named after the players, safely', () {
    expect(
      gifFileName('Ann Example', 'Ben O\'Sample'),
      'Ann_Example-vs-Ben_O_Sample.gif',
    );
    expect(gifFileName(null, 'Ben'), 'game.gif');
    expect(gifFileName('///', 'Ben'), 'game.gif');
  });
}
