import 'package:chess_mortem/logging/app_log.dart';
import 'package:chess_mortem/logging/crash_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(AppLog.instance.clear);

  test('keeps entries in the order they happened', () {
    AppLog.instance.info('engine', 'started');
    AppLog.instance.error('nets', 'download failed');

    expect(AppLog.instance.entries.map((e) => e.message), [
      'started',
      'download failed',
    ]);
    expect(AppLog.instance.entries.last.level, LogLevel.error);
  });

  test('drops the oldest rather than growing forever', () {
    for (var i = 0; i < AppLog.maxEntries + 50; i++) {
      AppLog.instance.info('engine', 'line $i');
    }

    expect(AppLog.instance.entries, hasLength(AppLog.maxEntries));
    expect(AppLog.instance.entries.first.message, 'line 50');
    expect(
      AppLog.instance.entries.last.message,
      'line ${AppLog.maxEntries + 49}',
    );
  });

  test('notifies so the screen can follow along', () {
    var notifications = 0;
    void listener() => notifications++;
    AppLog.instance.addListener(listener);
    addTearDown(() => AppLog.instance.removeListener(listener));

    AppLog.instance.info('engine', 'one');
    AppLog.instance.clear();

    expect(notifications, 2);
  });

  test('copies out as text, one entry per line', () {
    AppLog.instance.info('engine', 'depth 15 in 900 ms');
    AppLog.instance.warn('nets', 'retrying');

    final text = AppLog.instance.asText();
    expect(text.split('\n'), hasLength(2));
    expect(text, contains('engine'));
    expect(text, contains('depth 15 in 900 ms'));
  });

  group('formatting', () {
    test('durations stay readable either side of a second', () {
      expect(formatDuration(const Duration(milliseconds: 850)), '850 ms');
      expect(formatDuration(const Duration(milliseconds: 62300)), '62.3 s');
    });
  });

  group('the crash guard', () {
    test('an uncaught error lands in the log, with where it was', () {
      AppLog.instance.clear();
      logFlutterError(
        FlutterErrorDetails(
          exception: StateError('boom'),
          stack: StackTrace.current,
          context: ErrorDescription('while painting the board'),
        ),
      );
      logUncaughtError(const FormatException('bad'), null);

      final entries = AppLog.instance.entries;
      expect(entries, hasLength(2));
      expect(entries.every((entry) => entry.tag == 'crash'), isTrue);
      expect(entries.first.level, LogLevel.error);
      expect(entries.first.message, contains('boom'));
      expect(entries.first.message, contains('while painting the board'));
      expect(entries.last.message, contains('bad'));
    });
  });
}
