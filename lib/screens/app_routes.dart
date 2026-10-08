import 'package:flutter/material.dart';

import '../analysis/analysis_session.dart';
import '../llm/llm_config_store.dart';
import 'settings_screen.dart';

/// Pushes Settings, wired to the live [session]: depth, the Brilliant & Great
/// switch and player name apply at once. [onPlayerNameChanged] runs when the
/// name changes, after the session has it.
Future<void> openSettings(
  BuildContext context, {
  required AnalysisSession session,
  required LlmConfigStore configStore,
  VoidCallback? onPlayerNameChanged,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => SettingsScreen(
      configStore: configStore,
      onEngineDepthChanged: (depth) => session.searchDepth = depth,
      onRanksAlternativesChanged: (on) => session.ranksAlternatives = on,
      onPlayerNameChanged: (name) {
        session.playerName = name;
        onPlayerNameChanged?.call();
      },
      runningEngineName: session.engine.name,
    ),
  ),
);
