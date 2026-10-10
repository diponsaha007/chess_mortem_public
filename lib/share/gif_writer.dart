import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Encodes an animated GIF on a worker isolate, one frame at a time, so the
/// UI stays smooth and only one frame's pixels are held at once. It loops
/// forever.
class GifWriter {
  GifWriter._(this._isolate, this._replies);

  final Isolate _isolate;
  final ReceivePort _replies;
  late final SendPort _commands;

  /// One per message sent; the worker answers each, in order.
  final _waiting = Queue<Completer<Object?>>();
  bool _closed = false;

  static Future<GifWriter> start() async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_work, replies.sendPort);
    final writer = GifWriter._(isolate, replies);
    final ready = Completer<Object?>();
    writer._waiting.add(ready);
    replies.listen(writer._reply);
    writer._commands = await ready.future as SendPort;
    return writer;
  }

  void _reply(Object? message) {
    if (_waiting.isEmpty) return;
    final waiter = _waiting.removeFirst();
    if (message is String) {
      waiter.completeError(StateError('GIF encoder failed: $message'));
    } else {
      waiter.complete(message);
    }
  }

  Future<Object?> _ask(Object? message) {
    if (_closed) return Future.error(StateError('GIF writer closed'));
    final waiter = Completer<Object?>();
    _waiting.add(waiter);
    _commands.send(message);
    return waiter.future;
  }

  /// Adds a frame of straight RGBA [pixels], shown for [duration]. Completes
  /// once the worker has taken it in.
  Future<void> add(
    Uint8List pixels, {
    required int width,
    required int height,
    required Duration duration,
  }) => _ask((
    TransferableTypedData.fromList([pixels]),
    width,
    height,
    // GIF delays are in hundredths of a second.
    (duration.inMilliseconds / 10).round(),
  ));

  /// The finished GIF. The writer is closed afterwards.
  Future<Uint8List> finish() async {
    final result = await _ask(null) as TransferableTypedData;
    close();
    return result.materialize().asUint8List();
  }

  /// Stops the worker. Anything still waiting fails.
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(StateError('GIF writer closed'));
    }
  }
}

/// The worker: a frame record adds a frame, null finishes. Answers `true`
/// per frame, the bytes at the end, or the error as a string.
void _work(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  // No dithering: it speckles the flat squares and shimmers between frames.
  final encoder = img.GifEncoder(dither: img.DitherKernel.none);
  commands.listen((message) {
    try {
      if (message case (
        TransferableTypedData pixels,
        int width,
        int height,
        int delay,
      )) {
        final frame = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: pixels.materialize(),
          numChannels: 4,
        );
        encoder.addFrame(frame, duration: delay);
        replies.send(true);
      } else {
        final bytes = encoder.finish() ?? Uint8List(0);
        replies.send(TransferableTypedData.fromList([bytes]));
        commands.close();
      }
    } catch (e) {
      replies.send('$e');
      commands.close();
    }
  });
}
