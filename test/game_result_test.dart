import 'package:chess_mortem/model/game_result.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GameResult.parse', () {
    test('reads the three decided results', () {
      expect(GameResult.parse('1-0'), GameResult.whiteWon);
      expect(GameResult.parse('0-1'), GameResult.blackWon);
      expect(GameResult.parse('1/2-1/2'), GameResult.draw);
      // Some writers use the glyph rather than the fraction.
      expect(GameResult.parse('½-½'), GameResult.draw);
    });

    test('an unfinished or missing result is null, not a fake draw', () {
      // dartchess seeds a parse with `Result: *`, so a game whose PGN never
      // said anything arrives here as `*`. Drawing "½–½" for that would put a
      // result on screen that the file never claimed.
      expect(GameResult.parse('*'), isNull);
      expect(GameResult.parse(null), isNull);
      expect(GameResult.parse(''), isNull);
      expect(GameResult.parse('  '), isNull);
      expect(GameResult.parse('nonsense'), isNull);
    });

    test('surrounding whitespace does not hide a result', () {
      expect(GameResult.parse('  1-0 '), GameResult.whiteWon);
    });
  });

  group('GameResult', () {
    test('names a winner, and a draw has none', () {
      expect(GameResult.whiteWon.winner, Side.white);
      expect(GameResult.blackWon.winner, Side.black);
      expect(GameResult.draw.winner, isNull);
      expect(GameResult.draw.isDraw, isTrue);
    });

    test('wonBy answers for one side without unpacking the winner', () {
      expect(GameResult.whiteWon.wonBy(Side.white), isTrue);
      expect(GameResult.whiteWon.wonBy(Side.black), isFalse);
      expect(GameResult.draw.wonBy(Side.white), isFalse);
      expect(GameResult.draw.wonBy(Side.black), isFalse);
    });

    test('labels are scores, with en dashes and a real half', () {
      expect(GameResult.whiteWon.label, '1–0');
      expect(GameResult.blackWon.label, '0–1');
      expect(GameResult.draw.label, '½–½');
    });
  });
}
