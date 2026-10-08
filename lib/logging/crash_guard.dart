import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_log.dart';

/// Sends every uncaught error to [AppLog] and, in a release build, replaces
/// the grey "broken widget" box with [BrokenWidgetNotice].
/// Nothing is sent anywhere: a build with the Logs screen shows them there.
///
/// Called from `main()` only — a test binding installs its own handlers.
void installCrashGuard() {
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    logFlutterError(details);
    presentError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logUncaughtError(error, stack);
    // Handled: an error in one callback should not take the app down.
    return true;
  };
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const BrokenWidgetNotice();
  }
}

/// A build, layout or paint error, with where it happened.
void logFlutterError(FlutterErrorDetails details) {
  final where = details.context?.toDescription();
  AppLog.instance.error(
    'crash',
    '${details.exceptionAsString()}'
        '${where == null ? '' : '\n$where'}'
        '${_head(details.stack)}',
  );
}

/// An error no widget or zone caught: a failed future, a platform callback.
void logUncaughtError(Object error, StackTrace? stack) =>
    AppLog.instance.error('crash', '$error${_head(stack)}');

/// The top of [stack]: enough to find the line, short enough to read on a
/// phone.
String _head(StackTrace? stack) {
  if (stack == null) return '';
  final lines = stack.toString().trim().split('\n');
  if (lines.first.isEmpty) return '';
  return '\n${lines.take(8).join('\n')}';
}

/// What a widget that failed to build is replaced with.
class BrokenWidgetNotice extends StatelessWidget {
  const BrokenWidgetNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF14152A),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            showLogsScreen
                ? 'This part of the screen could not be shown.\n'
                      'Menu → Logs has the details.'
                : 'This part of the screen could not be shown.',
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFE2E2EC), fontSize: 14),
          ),
        ),
      ),
    );
  }
}
