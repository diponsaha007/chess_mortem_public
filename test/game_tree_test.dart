import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _samplePgn = '''
[Event "Test"]
[White "A"]
[Black "B"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''';

const _pgnWithVariation = '''
[Event "Test"]

1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *
''';

void main() {
  group('GameTree.fromPgn', () {
    test('imports the mainline with correct SANs and positions', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final mainline = tree.mainline;

      expect(mainline.map((n) => n.san), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bb5',
        'a6',
      ]);
      expect(mainline.first.sideThatMoved, Side.white);
      expect(mainline[1].sideThatMoved, Side.black);
      expect(mainline.last.ply, 6);
      // After 3...a6 it is White's turn.
      expect(mainline.last.position.turn, Side.white);
      expect(tree.headers['White'], 'A');
    });

    test('imports PGN variations as sibling branches', () {
      final tree = GameTree.fromPgn(_pgnWithVariation);
      final firstBlackMove = tree.root.children.first; // node after 1. e4

      expect(firstBlackMove.children, hasLength(2));
      expect(firstBlackMove.children[0].san, 'e5'); // mainline
      expect(firstBlackMove.children[1].san, 'c5'); // variation
      expect(firstBlackMove.children[1].children.single.san, 'Nf3');
    });

    test('throws on an illegal move', () {
      expect(() => GameTree.fromPgn('1. e5 *'), throwsFormatException);
    });
  });

  group('GameTree.addMove', () {
    test('adding the same move twice returns the same node', () {
      final tree = GameTree.empty();
      final move = Move.parse('e2e4')!;

      final first = tree.addMove(tree.root, move, isUserMove: true);
      final second = tree.addMove(tree.root, move, isUserMove: true);

      expect(identical(first, second), isTrue);
      expect(tree.root.children, hasLength(1));
      expect(first.san, 'e4');
    });

    test('a different move creates a sibling', () {
      final tree = GameTree.empty();
      tree.addMove(tree.root, Move.parse('e2e4')!);
      tree.addMove(tree.root, Move.parse('d2d4')!);

      expect(tree.root.children.map((n) => n.san), ['e4', 'd4']);
    });

    test('a user move on a mainline position dedupes against the '
        'imported game move', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final existing = tree.root.children.first; // 1. e4 from the PGN

      final node = tree.addMove(
        tree.root,
        Move.parse('e2e4')!,
        isUserMove: true,
      );

      expect(identical(node, existing), isTrue);
      expect(node.isUserMove, isFalse); // the original node is kept
    });

    test('rejects illegal moves', () {
      final tree = GameTree.empty();
      expect(
        () => tree.addMove(tree.root, Move.parse('e2e5')!),
        throwsArgumentError,
      );
    });
  });

  group('branches', () {
    test('only nodes off children[0] are variations', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final mainline = tree.mainline;
      final branch = tree.addMove(
        tree.root,
        Move.parse('d2d4')!,
        isUserMove: true,
      );
      // A move played on TOP of a variation is one too, however deep.
      final deeper = tree.addMove(branch, Move.parse('d7d5')!);

      expect(mainline.every((n) => n.isVariation), isFalse);
      expect(mainline.last.isVariation, isFalse);
      expect(tree.root.isVariation, isFalse);
      expect(branch.isVariation, isTrue);
      expect(deeper.isVariation, isTrue);
    });

    test('the reply is this node\'s own best move, in SAN', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final node = tree.mainline.first; // after 1.e4

      expect(node.replyMoveSan, isNull); // not evaluated yet
      node.eval = const EngineEval(cp: 20, bestMoveUci: 'c7c5', depth: 15);
      expect(node.replyMoveSan, 'c5');

      // Not the same question as "what should I have played", which reads
      // the PARENT's eval.
      tree.root.eval = const EngineEval(cp: 20, bestMoveUci: 'd2d4', depth: 15);
      expect(node.betterMoveSan, 'd4');
    });

    test('castling lands on the king square, not the rook corner', () {
      final tree = GameTree.empty();
      var node = tree.root;
      for (final san in ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']) {
        node = tree.addMove(node, node.position.parseSan(san)!);
      }
      final short = tree.addMove(node, node.position.parseSan('O-O')!);
      final quiet = tree.mainline.first; // 1.e4

      // dartchess encodes castling as king-takes-own-rook.
      expect((short.move! as NormalMove).to, Square.h1);
      expect(short.landingSquare, Square.g1);
      // An ordinary move is unaffected.
      expect(quiet.landingSquare, Square.e4);
    });

    test('an illegal or missing best move gives no reply', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final node = tree.mainline.first;
      node.eval = const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15);

      // e2e4 cannot be played again after 1.e4 — degrade, don't throw.
      expect(node.replyMoveSan, isNull);
    });

    test('the better line is the PARENT\'s whole PV, in SAN', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final node = tree.mainline.first; // after 1.e4

      expect(node.betterLineSan, isEmpty); // parent not evaluated yet

      tree.root.eval = const EngineEval(
        cp: 20,
        bestMoveUci: 'd2d4',
        pvUci: ['d2d4', 'd7d5', 'c2c4'],
        depth: 15,
      );
      expect(node.betterLineSan, ['d4', 'd5', 'c4']);
      // It starts with the move the coach bar is naming.
      expect(node.betterLineSan.first, node.betterMoveSan);
    });

    test('a PV that disagrees with bestmove is dropped rather than shown', () {
      final tree = GameTree.fromPgn(_samplePgn);
      final node = tree.mainline.first;

      // A search cut short by `stop` can leave the last info line and the
      // bestmove line on different moves; a line starting with a move
      // nothing else names would be a lie.
      tree.root.eval = const EngineEval(
        cp: 20,
        bestMoveUci: 'd2d4',
        pvUci: ['g1f3', 'd7d5'],
        depth: 15,
      );
      expect(node.betterLineSan, isEmpty);
      expect(node.betterMoveSan, 'd4');
    });
  });
}
