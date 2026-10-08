import 'dart:convert';

import 'package:chess_mortem/analysis/analysis_store.dart';

/// In-memory analyses, kept as JSON TEXT so a test reads back exactly what a
/// file would hold.
class FakeAnalysisStore extends AnalysisStore {
  final Map<String, String> files = {};
  int saves = 0;

  @override
  Future<Object?> load(String gameId) async {
    final text = files[gameId];
    return text == null ? null : jsonDecode(text);
  }

  @override
  Future<void> save(String gameId, Map<String, Object?> analysis) async {
    files[gameId] = jsonEncode(analysis);
    saves++;
  }

  @override
  Future<void> prune(Set<String> keepIds) async =>
      files.removeWhere((id, _) => !keepIds.contains(id));
}
