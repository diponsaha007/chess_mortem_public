import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Hands a game to other apps through the system share sheet: the PGN as
/// plain text, or a file such as the analysis GIF. The Android side is
/// `MainActivity.kt`; the sheet's own Copy action covers copying.
class GameSharer {
  GameSharer([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('chess_mortem/share');

  final MethodChannel _channel;

  /// Whether [shareFile] can work here: only Android has the other side.
  bool get sharesFiles =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Opens the share sheet with [pgn]. [subject] titles it where the target
  /// has a subject line (email). False when this platform has no share sheet.
  Future<bool> share(String pgn, {String? subject}) =>
      _invoke('share', {'text': pgn, 'subject': subject});

  /// Opens the share sheet with the file at [path], which must be in the
  /// cache's shared folder (the only one the file provider exposes).
  Future<bool> shareFile(
    String path, {
    required String mimeType,
    String? subject,
  }) => _invoke('shareFile', {
    'path': path,
    'mimeType': mimeType,
    'subject': subject,
  });

  Future<bool> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      final shown = await _channel.invokeMethod<bool>(method, arguments);
      return shown ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // not Android
    }
  }
}
