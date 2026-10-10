import 'dart:io';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../appearance/board_appearance.dart';
import '../logging/app_log.dart';
import '../model/game_tree.dart';
import 'gif_frames.dart';
import 'gif_painter.dart';
import 'gif_writer.dart';

/// Renders a game's mainline, with its analysis, as an animated GIF.
/// [progress] counts the frames done out of [total]; [cancel] stops it.
class GameGifExport {
  GameGifExport(
    this.tree, {
    required this.orientation,
    required this.appearance,
    String Function(GameNode node)? coachLineFor,
  }) : frames = gifFramesFor(tree, coachLineFor: coachLineFor);

  final GameTree tree;

  /// The side at the bottom of the board, as on the screen.
  final Side orientation;
  final BoardAppearance appearance;
  final List<GifFrame> frames;

  final progress = ValueNotifier<int>(0);
  int get total => frames.length;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  GifWriter? _writer;

  void cancel() {
    _cancelled = true;
    _writer?.close();
  }

  /// The GIF's bytes, or null once cancelled.
  Future<Uint8List?> render() async {
    final watch = Stopwatch()..start();
    final painter = await GifPainter.load(
      appearance: appearance,
      orientation: orientation,
      whiteName: _player('White'),
      blackName: _player('Black'),
    );
    GifWriter? writer;
    try {
      writer = await GifWriter.start();
      _writer = writer;
      for (final frame in frames) {
        if (_cancelled) return null;
        final pixels = await painter.render(frame);
        if (_cancelled) return null;
        await writer.add(
          pixels,
          width: GifPainter.width,
          height: GifPainter.height,
          duration: frame.duration,
        );
        progress.value++;
      }
      final bytes = await writer.finish();
      AppLog.instance.info(
        'share',
        'GIF: ${frames.length} frames, ${bytes.length ~/ 1024} KB '
            'in ${formatDuration(watch.elapsed)}',
      );
      return bytes;
    } on StateError {
      // Closing the writer fails what it was doing.
      if (_cancelled) return null;
      rethrow;
    } finally {
      painter.dispose();
      writer?.close();
    }
  }

  /// "Ann Example (1850)", or the colour when the PGN names nobody.
  String _player(String colour) {
    final name = tree.header(colour) ?? colour;
    final elo = tree.header('${colour}Elo');
    return elo == null ? name : '$name ($elo)';
  }
}

/// The folder shared files are written to, under the app's cache. The
/// Android file provider exposes exactly this folder.
const sharedFolder = 'shared';

/// Writes [bytes] as [name] in [cache]'s shared folder, emptied first so
/// old exports do not pile up. Written to a scratch file and renamed.
Future<File> writeSharedFile(
  Directory cache,
  String name,
  Uint8List bytes,
) async {
  final folder = Directory('${cache.path}/$sharedFolder');
  if (await folder.exists()) await folder.delete(recursive: true);
  await folder.create(recursive: true);
  final scratch = File('${folder.path}/$name.part');
  await scratch.writeAsBytes(bytes, flush: true);
  return scratch.rename('${folder.path}/$name');
}

/// "Ann_Example-vs-Ben_Sample.gif": the players, safe for any file system.
String gifFileName(String? white, String? black) {
  String safe(String s) => s
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final w = white == null ? '' : safe(white);
  final b = black == null ? '' : safe(black);
  if (w.isEmpty || b.isEmpty) return 'game.gif';
  return '$w-vs-$b.gif';
}
