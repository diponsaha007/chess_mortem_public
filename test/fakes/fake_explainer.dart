import 'dart:async';

import 'package:chess_mortem/llm/move_explainer.dart';

/// Scriptable [MoveExplainer] for tests: counts calls, can fail once, and
/// can be held open to inspect the loading state.
class FakeExplainer implements MoveExplainer {
  FakeExplainer({this.response = 'Loses a pawn to Nxe5.', this.model});

  /// The answer returned once nothing else intervenes.
  String response;

  /// Who the answer says wrote it.
  String? model;

  /// Thrown by the next call, then cleared — so a retry succeeds.
  Object? throwOnce;

  /// When set, the next call waits on this instead of returning, so a test
  /// can observe the loading state.
  Completer<void>? gate;

  int calls = 0;
  final List<ExplanationContext> contexts = [];

  /// Set once [dispose] has been called, so a test can assert the screen
  /// released the explainer it built.
  bool disposed = false;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Future<MoveExplanation> explainMove(ExplanationContext context) async {
    calls++;
    contexts.add(context);
    final failure = throwOnce;
    if (failure != null) {
      throwOnce = null;
      throw failure;
    }
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    return MoveExplanation(detail: response, model: model);
  }
}
