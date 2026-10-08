import 'package:dartchess/dartchess.dart';

import 'game_result.dart';
import 'game_tree.dart';
import 'sides.dart';

/// One library entry: the PGN text plus the facts a row may show.
///
/// Only the text is saved — no evals or explanations — so nothing here may
/// be an accuracy or a mistake count. Only the five tags the app reads
/// (players, ratings, result) are copied out of the PGN.
class SavedGame {
  const SavedGame({
    required this.id,
    required this.pgn,
    required this.moveCount,
    required this.addedAt,
    required this.lastOpenedAt,
    this.white,
    this.black,
    this.whiteElo,
    this.blackElo,
    this.result,
  });

  /// Stable across reorders, so a list can key on it.
  final String id;
  final String pgn;
  final String? white;
  final String? black;
  final String? whiteElo;
  final String? blackElo;
  final GameResult? result;

  /// Full moves, not plies.
  final int moveCount;
  final DateTime addedAt;

  /// What the list is ordered by.
  final DateTime lastOpenedAt;

  /// Which side [playerName] played, or null.
  Side? userSide(String? playerName) =>
      sideOfPlayer(playerName, white: white, black: black);

  SavedGame copyWith({DateTime? lastOpenedAt}) => SavedGame(
    id: id,
    pgn: pgn,
    moveCount: moveCount,
    addedAt: addedAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    white: white,
    black: black,
    whiteElo: whiteElo,
    blackElo: blackElo,
    result: result,
  );

  /// Reads [pgn] into an entry, or null when it will not open: an illegal
  /// move throws, and non-PGN text parses to a game with no moves.
  static SavedGame? fromPgn(String pgn, {DateTime? now}) {
    final text = pgn.trim();
    if (text.isEmpty) return null;
    final GameTree tree;
    try {
      tree = GameTree.fromPgn(text);
    } catch (_) {
      return null;
    }
    final plies = tree.mainline.length;
    if (plies == 0) return null;
    final at = now ?? DateTime.now();
    return SavedGame(
      id: '${at.microsecondsSinceEpoch}',
      pgn: text,
      moveCount: (plies + 1) ~/ 2,
      addedAt: at,
      lastOpenedAt: at,
      white: tree.header('White'),
      black: tree.header('Black'),
      whiteElo: tree.header('WhiteElo'),
      blackElo: tree.header('BlackElo'),
      result: GameResult.parse(tree.header('Result')),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'pgn': pgn,
    'white': white,
    'black': black,
    'whiteElo': whiteElo,
    'blackElo': blackElo,
    'result': result?.name,
    'moveCount': moveCount,
    'addedAt': addedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
  };

  /// One stored entry, or null if unreadable — a bad entry is dropped rather
  /// than losing the whole list.
  static SavedGame? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final pgn = json['pgn'];
    if (id is! String || pgn is! String || pgn.isEmpty) return null;
    final added = DateTime.tryParse(_string(json['addedAt']) ?? '');
    if (added == null) return null;
    return SavedGame(
      id: id,
      pgn: pgn,
      white: _string(json['white']),
      black: _string(json['black']),
      whiteElo: _string(json['whiteElo']),
      blackElo: _string(json['blackElo']),
      result: GameResult.values.asNameMap()[json['result']],
      moveCount: switch (json['moveCount']) {
        final int count => count,
        _ => 0,
      },
      addedAt: added,
      lastOpenedAt:
          DateTime.tryParse(_string(json['lastOpenedAt']) ?? '') ?? added,
    );
  }
}

String? _string(Object? value) => value is String ? value : null;
