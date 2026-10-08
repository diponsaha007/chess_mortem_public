import 'package:chess_mortem/logging/app_log.dart';
import 'package:chess_mortem/screens/log_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpLogs(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: LogScreen()));
    await tester.pumpAndSettle();
  }

  setUp(AppLog.instance.clear);
  tearDown(AppLog.instance.clear);

  testWidgets('an empty log says so rather than showing a blank page', (
    tester,
  ) async {
    await pumpLogs(tester);
    expect(find.text('Nothing logged yet.'), findsOne);
  });

  testWidgets('shows what the engine and the downloader reported', (
    tester,
  ) async {
    AppLog.instance.info('engine', 'started sf16 with 6 threads');
    AppLog.instance.error('nets', 'download failed: no route to host');
    await pumpLogs(tester);

    expect(find.textContaining('started sf16 with 6 threads'), findsOne);
    expect(find.textContaining('no route to host'), findsOne);
  });

  testWidgets('follows the log while the engine is still running', (
    tester,
  ) async {
    await pumpLogs(tester);
    expect(find.text('Nothing logged yet.'), findsOne);

    AppLog.instance.info('analysis', 'analysed 41 moves in 62.3 s');
    await tester.pumpAndSettle();

    expect(find.textContaining('analysed 41 moves in 62.3 s'), findsOne);
  });

  testWidgets('clearing empties the screen', (tester) async {
    AppLog.instance.info('engine', 'depth 15 in 900 ms');
    await pumpLogs(tester);

    await tester.tap(find.byTooltip('Clear log'));
    await tester.pumpAndSettle();

    expect(find.textContaining('depth 15'), findsNothing);
    expect(find.text('Nothing logged yet.'), findsOne);
  });

  testWidgets('an LLM prompt is collapsed until it is tapped', (tester) async {
    final prompt =
        'asking test-model about Bc4\n'
        '--- system ---\nYou are a chess coach.\n'
        '--- user ---\n${'Engine preferred: Bb5. ' * 20}';
    AppLog.instance.info('llm', prompt);
    await pumpLogs(tester);

    // The whole prompt is in the widget either way — what changes is how
    // much of it the row is allowed to draw.
    expect(find.text('tap to show all'), findsOne);
    final collapsed = tester.widget<Text>(find.byType(Text).first);
    expect(collapsed.maxLines, isNotNull);

    await tester.tap(find.text('tap to show all'));
    await tester.pumpAndSettle();

    expect(find.text('tap to collapse'), findsOne);
    final expanded = tester.widget<Text>(find.byType(Text).first);
    expect(expanded.maxLines, isNull);
  });

  testWidgets('an opened line stays with its entry as old ones drop off', (
    tester,
  ) async {
    final long = 'Engine preferred: Bb5. ' * 20;
    AppLog.instance.info('llm', 'first\n$long');
    AppLog.instance.info('llm', 'second\n$long');
    for (var i = 2; i < AppLog.maxEntries; i++) {
      AppLog.instance.info('engine', 'line $i');
    }
    await pumpLogs(tester);

    await tester.tap(find.text('tap to show all').first);
    await tester.pumpAndSettle();
    expect(find.text('tap to collapse'), findsOne);

    AppLog.instance.info('engine', 'one more'); // drops the opened one
    await tester.pumpAndSettle();
    expect(find.text('tap to collapse'), findsNothing);
  });

  testWidgets('a short line is shown whole, with nothing to tap', (
    tester,
  ) async {
    AppLog.instance.info('analysis', 'analysed 41 moves in 62.3 s');
    await pumpLogs(tester);

    expect(find.text('tap to show all'), findsNothing);
  });

  testWidgets('the last line clears the system navigation bar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    for (var i = 0; i < 60; i++) {
      AppLog.instance.info('engine', 'depth 15 in 900 ms — line $i');
    }
    await tester.pumpWidget(const MaterialApp(home: LogScreen()));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.padding?.resolve(TextDirection.ltr).bottom,
      greaterThanOrEqualTo(48),
    );
  });
}
