import 'package:flutter/services.dart';

/// PGNs handed to the app from outside: shared as text from another app, or
/// a `.pgn` file opened with it. The Android side is `MainActivity.kt`; on a
/// platform without one, nothing ever arrives.
class IncomingPgn {
  IncomingPgn([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('chess_mortem/incoming');

  final MethodChannel _channel;

  /// Starts listening and delivers the text the app was LAUNCHED with, if
  /// any. [onPgn] gets raw text: it may not be a PGN at all.
  Future<void> listen(void Function(String text) onPgn) async {
    _channel.setMethodCallHandler((call) async {
      final text = call.arguments;
      if (call.method == 'incoming' && text is String) onPgn(text);
    });
    try {
      final pending = await _channel.invokeMethod<String>('takePending');
      if (pending != null) onPgn(pending);
    } on PlatformException {
      // Nothing to deliver.
    } on MissingPluginException {
      // Not Android: no share target here.
    }
  }

  void stop() => _channel.setMethodCallHandler(null);
}
