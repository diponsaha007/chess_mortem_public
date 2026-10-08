import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Keeps each game's analysis in its own file, named by the library entry's
/// id. Files rather than preferences: an analysed game is tens of kilobytes,
/// and the library list is one bounded string. A class so tests can
/// substitute one.
class AnalysisStore {
  AnalysisStore({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/analysis');
  }

  Future<File> _file(String gameId) async {
    final safe = gameId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    return File('${(await _directory()).path}/$safe.json');
  }

  /// The saved analysis of [gameId] as decoded JSON, or null when there is
  /// none or it cannot be read.
  Future<Object?> load(String gameId) async {
    try {
      final file = await _file(gameId);
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Written beside the real file and renamed over it, so a kill mid-write
  /// leaves the previous analysis, not half of the new one.
  Future<void> save(String gameId, Map<String, Object?> analysis) async {
    final file = await _file(gameId);
    await file.parent.create(recursive: true);
    final scratch = File('${file.path}.tmp');
    await scratch.writeAsString(jsonEncode(analysis), flush: true);
    await scratch.rename(file.path);
  }

  /// Deletes the analysis of every game not in [keepIds]. Run at start
  /// rather than on delete, so the library's Undo brings the analysis back
  /// with the game.
  Future<void> prune(Set<String> keepIds) async {
    try {
      final directory = await _directory();
      if (!await directory.exists()) return;
      final keep = {for (final id in keepIds) (await _file(id)).path};
      await for (final entry in directory.list()) {
        if (entry is File && !keep.contains(entry.path)) await entry.delete();
      }
    } catch (_) {} // housekeeping: a leftover file costs only its bytes
  }
}
