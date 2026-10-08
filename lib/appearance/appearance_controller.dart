import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_appearance.dart';

/// Loads and saves the [BoardAppearance]. Plain preferences: nothing here is
/// a secret. A class so tests can substitute one.
class AppearanceStore {
  const AppearanceStore();

  static const _boardKey = 'board_theme';
  static const _piecesKey = 'piece_style';

  /// The saved appearance; the default when nothing (or nonsense) is stored
  /// or the storage cannot be read.
  Future<BoardAppearance> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return BoardAppearance(
        boardTheme: BoardTheme.byName(prefs.getString(_boardKey)),
        pieceStyle: PieceStyle.byName(prefs.getString(_piecesKey)),
      );
    } catch (_) {
      return BoardAppearance.standard;
    }
  }

  Future<void> save(BoardAppearance appearance) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_boardKey, appearance.boardTheme.name);
    await prefs.setString(_piecesKey, appearance.pieceStyle.name);
  }
}

/// The board's look, live: a change repaints every board and piece glyph at
/// once and saves itself.
class AppearanceController extends ChangeNotifier {
  AppearanceController({AppearanceStore store = const AppearanceStore()})
    : _store = store;

  final AppearanceStore _store;

  BoardAppearance get appearance => _appearance;
  BoardAppearance _appearance = BoardAppearance.standard;

  Future<void> load() async {
    _appearance = await _store.load();
    notifyListeners();
  }

  void setBoardTheme(BoardTheme theme) =>
      _set(_appearance.copyWith(boardTheme: theme));

  void setPieceStyle(PieceStyle style) =>
      _set(_appearance.copyWith(pieceStyle: style));

  void _set(BoardAppearance appearance) {
    if (appearance == _appearance) return;
    _appearance = appearance;
    notifyListeners();
    // A failed save costs the choice at the next start, nothing more.
    unawaited(_store.save(appearance).catchError((Object _) {}));
  }
}

/// Hands the [AppearanceController] to everything under it. Sits above the
/// `MaterialApp`, so pushed routes see it too.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller, or null with no scope mounted.
  static AppearanceController? controllerOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;

  /// The appearance to draw with; the default one with no scope mounted, so
  /// a widget needs no scope to be used on its own.
  static BoardAppearance of(BuildContext context) =>
      controllerOf(context)?.appearance ?? BoardAppearance.standard;
}
