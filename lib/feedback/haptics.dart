import 'dart:async';

import 'package:flutter/services.dart';

import '../model/coach_flavor.dart';

/// Every buzz the app makes. There is no switch in the app: Flutter's
/// haptics honour the phone's own touch-feedback setting, which is the off
/// switch.
abstract final class Haptics {
  /// A light tick: a move played, a step through the game.
  static void tap() => unawaited(HapticFeedback.selectionClick());

  /// A firmer one: a jump to a key move, a delete.
  static void step() => unawaited(HapticFeedback.lightImpact());

  /// A big moment on the board: medium for good news for the reader, heavy
  /// for bad.
  static void react(CoachReaction reaction) => unawaited(
    reaction.cheers
        ? HapticFeedback.mediumImpact()
        : HapticFeedback.heavyImpact(),
  );
}
