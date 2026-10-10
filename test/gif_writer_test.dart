import 'dart:typed_data';

import 'package:chess_mortem/appearance/board_appearance.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/share/game_gif.dart';
import 'package:chess_mortem/share/gif_painter.dart';
import 'package:chess_mortem/share/gif_writer.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the writer encodes every frame with its delay, looping', () async {
    final writer = await GifWriter.start();
    const width = 4, height = 3;
    for (final (shade, ms) in [(0, 500), (255, 2000)]) {
      final pixels = Uint8List(width * height * 4)
        ..fillRange(0, width * height * 4, shade);
      await writer.add(
        pixels,
        width: width,
        height: height,
        duration: Duration(milliseconds: ms),
      );
    }
    final gif = img.GifDecoder().decode(await writer.finish())!;
    expect(gif.numFrames, 2);
    expect(gif.width, width);
    expect(gif.height, height);
    expect(gif.frames.map((f) => f.frameDuration), [500, 2000]);
    expect(gif.loopCount, 0); // forever
  });

  test('a closed writer fails what it was still doing', () async {
    final writer = await GifWriter.start();
    writer.close();
    expect(
      writer.add(Uint8List(4), width: 1, height: 1, duration: Duration.zero),
      throwsStateError,
    );
  });

  for (final appearance in [
    BoardAppearance.standard,
    // An image board and another piece set.
    const BoardAppearance(
      boardTheme: BoardTheme.wood,
      pieceStyle: PieceStyle.merida,
    ),
  ]) {
    test(
      'a game renders to one frame per position '
      '(${appearance.boardTheme.name}, ${appearance.pieceStyle.name})',
      () async {
        final tree = GameTree.fromPgn(
          '[White "Ann Example"]\n[Black "Ben Sample"]\n\n1. e4 e5 2. Nf3 *',
        );
        for (final node in [tree.root, ...tree.mainline]) {
          node.eval = const EngineEval(cp: 40, bestMoveUci: 'g1f3', depth: 15);
        }
        final export = GameGifExport(
          tree,
          orientation: Side.black,
          appearance: appearance,
        );
        final bytes = await export.render();
        expect(export.progress.value, export.total);

        final gif = img.GifDecoder().decode(bytes!)!;
        expect(gif.numFrames, 5); // and the summary card
        expect(gif.width, GifPainter.width);
        expect(gif.height, GifPainter.height);
        expect(gif.frames.last.frameDuration, 5000);
      },
    );
  }

  test('a cancelled export returns nothing', () async {
    final tree = GameTree.fromPgn('1. e4 e5 *');
    final export = GameGifExport(
      tree,
      orientation: Side.white,
      appearance: BoardAppearance.standard,
    );
    final rendering = export.render();
    export.cancel();
    expect(await rendering, isNull);
  });
}
