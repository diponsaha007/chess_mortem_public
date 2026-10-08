import 'package:flutter/services.dart';

/// Hands a PGN to other apps through the system share sheet, as plain text.
/// The Android side is `MainActivity.kt`; the sheet's own Copy action covers
/// copying.
class PgnSharer {
  PgnSharer([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('chess_mortem/share');

  final MethodChannel _channel;

  /// Opens the share sheet with [pgn]. [subject] titles it where the target
  /// has a subject line (email). False when this platform has no share sheet.
  Future<bool> share(String pgn, {String? subject}) async {
    try {
      final shown = await _channel.invokeMethod<bool>('share', {
        'text': pgn,
        'subject': subject,
      });
      return shown ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // not Android
    }
  }
}
