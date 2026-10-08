import 'dart:io';

import 'package:chess_mortem/appearance/appearance_controller.dart';
import 'package:chess_mortem/appearance/board_appearance.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bundled with the board library but NOT free to ship: non-commercial,
/// "freeware" or unlicensed.
const _notFree = {
  'alpha', 'chess7', 'companion', 'leipzig', 'reillycraig', 'riohacha', //
  'kosal', 'california', 'caliente', 'maestro', 'fresca', 'cardinal',
  'gioco', 'tatiana', 'staunty', 'governor', 'dubrovny', 'icpieces',
  'monarchy', 'cooke', 'horsey', 'anarcandy', 'xkcd', 'disguised',
  'symmetric',
};

void main() {
  group('BoardAppearance', () {
    test('the default is the brown board with the classic pieces', () {
      expect(BoardAppearance.standard.boardTheme, BoardTheme.brown);
      expect(BoardAppearance.standard.pieceStyle, PieceStyle.cburnett);
    });

    test('a stored name finds its value, an unknown one the default', () {
      expect(BoardTheme.byName('wood'), BoardTheme.wood);
      expect(BoardTheme.byName('no-such-board'), BoardTheme.brown);
      expect(BoardTheme.byName(null), BoardTheme.brown);
      expect(PieceStyle.byName('merida'), PieceStyle.merida);
      expect(PieceStyle.byName('staunty'), PieceStyle.cburnett);
    });

    test('only freely licensed piece sets are offered', () {
      for (final style in PieceStyle.values) {
        expect(_notFree, isNot(contains(style.name)), reason: style.name);
        expect(style.author, isNotEmpty);
        expect(style.licence, isNotEmpty);
      }
    });

    test('every piece set draws all twelve pieces', () {
      for (final style in PieceStyle.values) {
        for (final side in Side.values) {
          for (final role in Role.values) {
            expect(
              style.assets[Piece(color: side, role: role).kind],
              isNotNull,
              reason: '${style.name} $side $role',
            );
          }
        }
      }
    });

    // Flutter bundles every asset a package lists, offered or not, so the
    // vendored board library must list exactly the offered sets.
    test('the APK carries exactly the offered piece sets', () {
      const root = 'third_party/chessground';
      final offered = <String>{};
      for (final style in PieceStyle.values) {
        for (final image in style.assets.values) {
          final path = image.assetName;
          expect(File('$root/$path').existsSync(), isTrue, reason: path);
          offered.add(path.split('/')[2]);
        }
      }
      final listed = RegExp(r'- assets/piece_sets/([a-z0-9-]+)/')
          .allMatches(File('$root/pubspec.yaml').readAsStringSync())
          .map((m) => m.group(1)!)
          .toSet();
      final onDisk = Directory(
        '$root/assets/piece_sets',
      ).listSync().map((entry) => entry.path.split('/').last).toSet();
      expect(listed, offered);
      expect(onDisk, offered);
    });
  });

  group('boardSettingsFor', () {
    test('keys the coordinate backgrounds of solid AND image boards', () {
      for (final theme in BoardTheme.values) {
        final scheme = boardSettingsFor(
          BoardAppearance(boardTheme: theme),
        ).colorScheme;
        expect(scheme.whiteCoordBackground.key, coordinatesWhiteKey);
        expect(scheme.blackCoordBackground.key, coordinatesBlackKey);
        expect(scheme.whiteCoordBackground.coordinates, isTrue);
        expect(scheme.blackCoordBackground.orientation, Side.black);
        // An image board keeps its image under the coordinates.
        expect(
          scheme.whiteCoordBackground.runtimeType,
          theme.scheme.whiteCoordBackground.runtimeType,
          reason: theme.name,
        );
      }
    });

    test('carries the pieces and is the same object when asked twice', () {
      const appearance = BoardAppearance(
        boardTheme: BoardTheme.marble,
        pieceStyle: PieceStyle.merida,
      );
      final settings = boardSettingsFor(appearance);
      expect(settings.pieceAssets, PieceSet.meridaAssets);
      expect(settings.enablePremoves, isFalse);
      expect(identical(boardSettingsFor(appearance), settings), isTrue);
    });
  });

  group('AppearanceController', () {
    test('a choice is saved and read back at the next start', () async {
      SharedPreferences.setMockInitialValues({});
      final first = AppearanceController();
      await first.load();
      expect(first.appearance, BoardAppearance.standard);

      var notified = 0;
      first.addListener(() => notified++);
      first.setBoardTheme(BoardTheme.wood);
      first.setPieceStyle(PieceStyle.merida);
      first.setPieceStyle(PieceStyle.merida); // unchanged: no notification
      expect(notified, 2);
      await Future<void>.delayed(Duration.zero);

      final second = AppearanceController();
      await second.load();
      expect(second.appearance.boardTheme, BoardTheme.wood);
      expect(second.appearance.pieceStyle, PieceStyle.merida);
    });

    test(
      'a stored value this build does not know reads as the default',
      () async {
        SharedPreferences.setMockInitialValues({
          'board_theme': 'horsey',
          'piece_style': 'xkcd',
        });
        final controller = AppearanceController();
        await controller.load();
        expect(controller.appearance, BoardAppearance.standard);
      },
    );
  });
}
