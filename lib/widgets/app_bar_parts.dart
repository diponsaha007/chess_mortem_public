import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../logging/app_log.dart';
import '../screens/log_screen.dart';

/// The logo and app name, for an [AppBar] title. [trailing] follows the name.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key, this.trailing = const []});

  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Sized on both axes: an SVG has no intrinsic size while it loads.
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(
            width: 32,
            height: 32,
            child: SvgPicture.asset('assets/logo.svg'),
          ),
        ),
        const SizedBox(width: 8),
        const Flexible(
          child: Text('Chess Mortem', overflow: TextOverflow.ellipsis),
        ),
        ...trailing,
      ],
    );
  }
}

enum _MenuAction { share, settings, logs }

/// The app bar's last action: a Settings gear, or, where there is more to
/// offer ([onShare], or a build with the Logs screen), an overflow menu whose
/// items each carry an icon and a name.
class AppMenu extends StatelessWidget {
  const AppMenu({
    super.key,
    required this.onSettings,
    this.onShare,
    this.withLogs = showLogsScreen,
  });

  final VoidCallback onSettings;

  /// Shares the open game; null leaves Share out.
  final VoidCallback? onShare;

  /// Injectable for tests.
  final bool withLogs;

  @override
  Widget build(BuildContext context) {
    // The constant first, so a build without logs leaves the screen out.
    final logs = showLogsScreen && withLogs;
    final share = onShare;
    if (share == null && !logs) {
      return IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: 'Settings',
        onPressed: onSettings,
      );
    }
    return PopupMenuButton<_MenuAction>(
      onSelected: (action) => switch (action) {
        _MenuAction.share => share?.call(),
        _MenuAction.settings => onSettings(),
        _MenuAction.logs => unawaited(
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const LogScreen())),
        ),
      },
      itemBuilder: (context) => [
        if (share != null) ...[
          const PopupMenuItem(
            value: _MenuAction.share,
            child: _MenuRow(icon: Icons.share_outlined, label: 'Share'),
          ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(
          value: _MenuAction.settings,
          child: _MenuRow(icon: Icons.settings_outlined, label: 'Settings'),
        ),
        if (logs)
          const PopupMenuItem(
            value: _MenuAction.logs,
            child: _MenuRow(icon: Icons.receipt_long_outlined, label: 'Logs'),
          ),
      ],
    );
  }
}

/// A menu item's icon and name.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}
