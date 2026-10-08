import 'package:chess_mortem/widgets/app_bar_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppMenu', () {
    Future<void> pumpMenu(
      WidgetTester tester, {
      required bool withLogs,
      VoidCallback? onShare,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              AppMenu(onSettings: () {}, onShare: onShare, withLogs: withLogs),
            ],
          ),
        ),
      ),
    );

    /// The icon drawn in the menu row named [label].
    Finder iconBeside(String label, IconData icon) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)),
      matching: find.byIcon(icon),
    );

    testWidgets('without logs it is a Settings gear, no menu', (tester) async {
      await pumpMenu(tester, withLogs: false);

      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.byType(PopupMenuButton<Object?>), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('with logs it is a menu holding Settings and Logs', (
      tester,
    ) async {
      await pumpMenu(tester, withLogs: true);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Logs'), findsOneWidget);
      expect(iconBeside('Settings', Icons.settings_outlined), findsOneWidget);
      expect(iconBeside('Logs', Icons.receipt_long_outlined), findsOneWidget);
      expect(find.text('Share'), findsNothing);
    });

    testWidgets('with Share it is a menu, even without logs', (tester) async {
      var shared = 0;
      await pumpMenu(tester, withLogs: false, onShare: () => shared++);

      expect(find.byTooltip('Settings'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(iconBeside('Share', Icons.share_outlined), findsOneWidget);
      expect(iconBeside('Settings', Icons.settings_outlined), findsOneWidget);
      expect(find.text('Logs'), findsNothing);

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(shared, 1);
    });
  });
}
