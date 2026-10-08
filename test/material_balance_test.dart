import 'package:chess_mortem/model/material_balance.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Board _after(List<String> sans) {
  Position position = Chess.initial;
  for (final san in sans) {
    position = position.play(position.parseSan(san)!);
  }
  return position.board;
}

void main() {
  group('materialBalance', () {
    test('the starting position is level', () {
      expect(materialBalance(Board.standard), 0);
    });

    test('a pawn up reads +1 for White', () {
      expect(materialBalance(_after(['e4', 'd5', 'exd5'])), 1);
    });

    test('a piece up for Black reads negative', () {
      // A bishop sacrifice on f7: White wins a pawn and loses a bishop, so
      // Black is two ahead.
      final board = _after(['e4', 'e5', 'Bc4', 'Nf6', 'Bxf7+', 'Kxf7']);
      expect(materialBalance(board), -2);
    });

    test('counts the pieces on the board, so a promotion is scored', () {
      final board = Board.parseFen('4k3/8/8/8/8/8/8/Q3K3');
      expect(materialBalance(board), 9);
    });
  });

  group('materialDiff', () {
    test('nothing is ahead at the start', () {
      expect(materialDiff(Board.standard, Side.white), isEmpty);
      expect(materialDiff(Board.standard, Side.black), isEmpty);
    });

    test('an even trade cancels out on both sides', () {
      // A pawn for a pawn: lichess shows nothing here, and so do we.
      final board = _after(['e4', 'd5', 'exd5', 'Qxd5']);
      expect(materialDiff(board, Side.white), isEmpty);
      expect(materialDiff(board, Side.black), isEmpty);
    });

    test('only the side that is ahead in a role shows it', () {
      final board = _after(['e4', 'e5', 'Bc4', 'Nf6', 'Bxf7+', 'Kxf7']);
      // A bishop for a pawn: Black is a bishop up, White a pawn up.
      expect(materialDiff(board, Side.black), [Role.bishop]);
      expect(materialDiff(board, Side.white), [Role.pawn]);
    });

    test('the most valuable surplus comes first', () {
      // Black is missing a queen, a rook, a knight and a pawn.
      final board = Board.parseFen(
        '1nb1kb1r/ppppppp1/8/8/8/8/PPPPPPPP/RNBQKBNR',
      );
      expect(materialDiff(board, Side.white), [
        Role.queen,
        Role.rook,
        Role.knight,
        Role.pawn,
      ]);
      expect(materialDiff(board, Side.black), isEmpty);
    });

    test('kings are never listed', () {
      expect(
        materialDiff(Board.parseFen('4k3/8/8/8/8/8/8/4K3'), Side.white),
        isEmpty,
      );
    });

    test('a promotion needs no special case', () {
      // Black queened a pawn. Counting the live board, Black is simply a
      // queen up and a pawn down — no phantom "captured queen" anywhere.
      final board = Board.parseFen(
        'rnbqkbnr/ppppppp1/7q/8/8/8/PPPPPPPP/RNBQKBNR',
      );
      expect(materialDiff(board, Side.black), [Role.queen]);
      expect(materialDiff(board, Side.white), [Role.pawn]);
    });
  });
}
