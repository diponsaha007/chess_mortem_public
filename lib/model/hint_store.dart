import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which one-time hints the user has waved away. A class so tests
/// can substitute one.
class HintStore {
  const HintStore();

  static const _nameHintKey = 'name_hint_dismissed';

  /// True when the "set your name" card should stay hidden. Unreadable
  /// storage reads as dismissed: a hint that cannot be dismissed for good
  /// is a nag.
  Future<bool> isNameHintDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_nameHintKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  Future<void> dismissNameHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_nameHintKey, true);
    } catch (_) {} // it comes back next start, nothing worse
  }
}
