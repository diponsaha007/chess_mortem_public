import 'package:flutter/foundation.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  LogEntry(this.level, this.tag, this.message) : at = DateTime.now();

  final DateTime at;
  final LogLevel level;

  /// Where it came from — 'engine', 'nets', 'analysis'.
  final String tag;
  final String message;

  String get clock =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}.'
      '${at.millisecond.toString().padLeft(3, '0')}';

  @override
  String toString() => '$clock  ${level.name.padRight(5)}  $tag  $message';
}

/// Whether the app has a Logs screen: always in debug and profile builds, in
/// a release build only with `--dart-define=SHOW_LOGS=true`. A constant, so a
/// build without it leaves the screen out.
const showLogsScreen = bool.fromEnvironment(
  'SHOW_LOGS',
  defaultValue: !kReleaseMode,
);

/// A bounded in-memory log, read from the Logs screen. Never written to disk
/// or sent anywhere. A singleton because the engine adapter and the
/// downloader have no other route to the UI.
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const maxEntries = 500;

  final List<LogEntry> _entries = [];

  /// Newest last, the order a log is read in.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  void info(String tag, String message) => _add(LogLevel.info, tag, message);
  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);
  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  void _add(LogLevel level, String tag, String message) {
    _entries.add(LogEntry(level, tag, message));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    // Also to the console, so `flutter run` shows the same thing.
    debugPrint(_entries.last.toString());
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// The whole log as text, for the copy button.
  String asText() => _entries.join('\n');
}

/// Milliseconds, or seconds once that stops being readable.
String formatDuration(Duration d) => d.inMilliseconds < 1000
    ? '${d.inMilliseconds} ms'
    : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
