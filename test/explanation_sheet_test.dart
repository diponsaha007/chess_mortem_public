import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/widgets/explanation_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required ExplanationStatus status,
    String? explanation,
    String? errorDetail,
    String? betterLine,
    String? explainedBy,
    VoidCallback? onRetry,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExplanationSheet(
            moveLabel: 'White played Nxe5 · Blunder',
            summaryLine: 'This leaves the queen on d5 hanging.',
            status: status,
            explanation: explanation,
            errorDetail: errorDetail,
            betterLine: betterLine,
            explainedBy: explainedBy,
            onRetry: onRetry ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('shows a spinner while loading', (tester) async {
    await pumpSheet(tester, status: ExplanationStatus.loading);

    expect(find.text('White played Nxe5 · Blunder'), findsOne);
    expect(find.byType(CircularProgressIndicator), findsOne);
  });

  testWidgets('the title is there in every state, before any LLM call', (
    tester,
  ) async {
    for (final status in ExplanationStatus.values) {
      await pumpSheet(tester, status: status);
      expect(
        find.text('This leaves the queen on d5 hanging.'),
        findsOne,
        reason: '$status',
      );
    }
  });

  testWidgets('the coach line stays the title under the model\'s answer', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      status: ExplanationStatus.ready,
      explanation: 'Nxd5 forks the king and queen.',
    );

    // One title, one author: the model only adds the body.
    expect(find.text('This leaves the queen on d5 hanging.'), findsOne);
    expect(find.text('Nxd5 forks the king and queen.'), findsOne);
  });

  testWidgets('asks the model only from a button', (tester) async {
    var asked = 0;
    await pumpSheet(
      tester,
      status: ExplanationStatus.idle,
      onRetry: () => asked++,
    );
    expect(asked, 0);
    await tester.tap(find.text('Explain more'));
    expect(asked, 1);
  });

  testWidgets('shows the explanation when ready', (tester) async {
    await pumpSheet(
      tester,
      status: ExplanationStatus.ready,
      explanation: 'Drops the knight to d4.',
    );

    expect(find.text('Drops the knight to d4.'), findsOne);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('an answer can be asked again, and says who wrote it', (
    tester,
  ) async {
    var asked = 0;
    await pumpSheet(
      tester,
      status: ExplanationStatus.ready,
      explanation: 'Drops the knight to d4.',
      explainedBy: 'gpt-oss 120B',
      onRetry: () => asked++,
    );

    expect(find.text('Answered by gpt-oss 120B'), findsOne);
    await tester.tap(find.text('Ask again'));
    expect(asked, 1);
  });

  testWidgets('the old answer stays while it is asked again', (tester) async {
    await pumpSheet(
      tester,
      status: ExplanationStatus.loading,
      explanation: 'Drops the knight to d4.',
    );

    expect(find.text('Drops the knight to d4.'), findsOne);
    expect(find.text('Asking again…'), findsOne);
    expect(find.text('Ask again'), findsNothing);
  });

  testWidgets('a failed ask-again keeps the old answer above the error', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      status: ExplanationStatus.failed,
      explanation: 'Drops the knight to d4.',
      errorDetail: 'The request timed out.',
    );

    expect(find.text('Drops the knight to d4.'), findsOne);
    expect(find.text('The request timed out.'), findsOne);
    expect(find.text('Retry'), findsOne);
  });

  testWidgets('offers a retry after a failure', (tester) async {
    var retries = 0;
    await pumpSheet(
      tester,
      status: ExplanationStatus.failed,
      errorDetail: 'The request timed out.',
      onRetry: () => retries++,
    );

    expect(find.text("Couldn't get an explanation."), findsOne);
    expect(find.text('The request timed out.'), findsOne);

    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('the better line is there in every state', (tester) async {
    // The engine knew this line long before the model was asked anything, so
    // it does not wait on the request — or on there being one.
    for (final status in ExplanationStatus.values) {
      await pumpSheet(
        tester,
        status: status,
        betterLine: '9. Nf3 Nc6 10. d4 exd4',
      );
      expect(find.text('Better was'), findsOne, reason: '$status');
      expect(find.text('9. Nf3 Nc6 10. d4 exd4'), findsOne, reason: '$status');
    }
  });

  testWidgets('no better line, no block', (tester) async {
    await pumpSheet(tester, status: ExplanationStatus.ready);
    expect(find.text('Better was'), findsNothing);
  });

  testWidgets('the last line clears the navigation bar', (tester) async {
    // Pumped through a real modal route, unlike the tests above: the bug
    // this guards is showModalBottomSheet's useSafeArea being
    // SafeArea(bottom: false), which only exists on that route.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const ExplanationSheet(
                  moveLabel: 'White played Nxe5 · Blunder',
                  summaryLine: 'This leaves the queen on d5 hanging.',
                  status: ExplanationStatus.ready,
                  explanation: 'The knight hangs to the queen on d1.',
                  errorDetail: null,
                  onRetry: _noop,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final body = find.text('The knight hangs to the queen on d1.');
    expect(tester.getBottomLeft(body).dy, lessThan(800 - 48));
  });
}

void _noop() {}
