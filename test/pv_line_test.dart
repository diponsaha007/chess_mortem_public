import 'package:chess_mortem/model/pv_line.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pvToSan', () {
    test('converts a known line to SAN', () {
      // Position after 1. e4 e5.
      Position position = Chess.initial;
      position = position.makeSan(position.parseSan('e4')!).$1;
      position = position.makeSan(position.parseSan('e5')!).$1;

      final sans = pvToSan(position, ['g1f3', 'b8c6', 'f1b5']);
      expect(sans, ['Nf3', 'Nc6', 'Bb5']);
    });

    test('renders promotions in SAN', () {
      // White pawn on e7, kings tucked away in the corners.
      final position = Chess.fromSetup(
        Setup.parseFen('8/4P3/8/8/8/8/8/K6k w - - 0 1'),
      );
      final sans = pvToSan(position, ['e7e8q']);
      expect(sans, ['e8=Q']);
    });

    test('truncates at the first illegal move and caps plies', () {
      final sans = pvToSan(Chess.initial, [
        'e2e4',
        'e7e5',
        'a1a8' /* illegal */,
        'g1f3',
      ]);
      expect(sans, ['e4', 'e5']);
    });
  });

  group('keyLine', () {
    test('ends on the capture that makes the point', () {
      expect(keyLine(['Nf3', 'Nc6', 'd4', 'exd4', 'Nxd4', 'Bc5']), [
        'Nf3',
        'Nc6',
        'd4',
        'exd4',
      ]);
    });

    test('ends on a check', () {
      expect(keyLine(['Nf3', 'd6', 'Bb5', 'c6', 'Bb5+']), [
        'Nf3',
        'd6',
        'Bb5',
        'c6',
        'Bb5+',
      ]);
    });

    test('ends on mate', () {
      expect(keyLine(['Qh5', 'g6', 'Qe5', 'f6', 'Qxe8#']), [
        'Qh5',
        'g6',
        'Qe5',
        'f6',
        'Qxe8#',
      ]);
    });

    test(
      'does not cut before minPlies — one pair says no more than the hint',
      () {
        // The capture on ply 2 is ignored; the one on ply 4 ends the line.
        expect(keyLine(['Nf3', 'Nxe4', 'd4', 'dxe4', 'Bc4']), [
          'Nf3',
          'Nxe4',
          'd4',
          'dxe4',
        ]);
      },
    );

    test('runs to maxPlies when nothing decisive happens', () {
      final quiet = [
        'Nf3', 'Nc6', 'd3', 'd6', 'Be2', //
        'Be7', 'O-O', 'O-O', 'Re1', 'Re8', 'h3',
      ];
      expect(keyLine(quiet), hasLength(10));
      expect(keyLine(quiet).last, 'Re8');
    });

    test('an empty line stays empty', () {
      expect(keyLine(const []), isEmpty);
    });
  });

  group('formatLine', () {
    test('numbers a line that starts on White', () {
      // Ply 16 is the position after Black's 8th, so White is to move.
      expect(
        formatLine(['Nf3', 'Nc6', 'd4'], startingPly: 16),
        '9. Nf3 Nc6 10. d4',
      );
    });

    test('opens with the ellipsis form when Black is to move', () {
      expect(
        formatLine(['Kxf7', 'Nxe5+', 'Ke8'], startingPly: 17),
        '9… Kxf7 10. Nxe5+ Ke8',
      );
    });

    test('numbers from the start of the game', () {
      expect(formatLine(['e4', 'e5'], startingPly: 0), '1. e4 e5');
    });
  });
}
