import 'package:dartchess/dartchess.dart';

import '../llm/move_explainer.dart';
import 'eval.dart';
import 'game_tree.dart';

/// Bumped when the saved shape changes; an older file is simply re-analysed.
const analysisFormatVersion = 1;

/// What an analysed [tree] costs to rebuild, as JSON: the evals, the
/// explanations and the moves added to the PGN (what-if moves, better
/// lines). Verdicts are NOT saved — they are recomputed from the evals, so a
/// retuned rule applies to old games too.
///
/// [depth] is the depth the mainline was searched at. [runnerUpSearched] are
/// the positions whose runner-up search ran, found or not, so it is never
/// repeated.
Map<String, Object?> encodeAnalysis(
  GameTree tree, {
  required String engineName,
  required int depth,
  Set<GameNode> runnerUpSearched = const {},
}) => {
  'version': analysisFormatVersion,
  'engine': engineName,
  'depth': depth,
  'root': _encodeNode(tree.root, runnerUpSearched),
};

Map<String, Object?> _encodeNode(GameNode node, Set<GameNode> searched) {
  final eval = node.eval;
  final explanation = node.explanation;
  final children = <String, Object?>{
    for (final child in node.children)
      if (_isWorthSaving(child)) child.move!.uci: _encodeNode(child, searched),
  };
  return {
    if (eval != null) 'e': _encodeEval(eval),
    if (searched.contains(node)) 'r': true,
    if (explanation != null)
      'x': {'d': explanation.detail, 'm': ?explanation.model},
    if (node.isUserMove) 'u': true,
    if (children.isNotEmpty) 'c': children,
  };
}

/// A branch with nothing computed under it is rebuilt from the PGN anyway.
bool _isWorthSaving(GameNode node) =>
    node.eval != null ||
    node.explanation != null ||
    node.isUserMove ||
    node.children.any(_isWorthSaving);

Map<String, Object?> _encodeEval(EngineEval eval) => {
  if (eval.isCheckmate)
    'mated': eval.matedSide!.name
  else if (eval.mateIn != null)
    'mate': eval.mateIn
  else
    'cp': eval.cp,
  if (eval.bestMoveUci != null) 'best': eval.bestMoveUci,
  if (eval.pvUci.isNotEmpty) 'pv': eval.pvUci,
  if (eval.alternatives.isNotEmpty)
    'alt': [
      for (final line in eval.alternatives)
        {
          if (line.mateIn != null) 'mate': line.mateIn else 'cp': line.cp,
          'pv': line.pvUci,
        },
    ],
  'd': eval.depth,
};

/// Writes a saved analysis back onto [tree] (freshly parsed from the same
/// PGN) and returns the positions whose runner-up was already searched.
///
/// Returns null, leaving the tree untouched, when [json] is not this build's
/// format, came from another engine (its numbers would be shown under the
/// wrong name), or was searched SHALLOWER than [minDepth]: the user asked
/// for more, so the game is analysed again. A deeper one is kept. Anything
/// unreadable INSIDE the file is skipped — that position is just searched
/// again.
Set<GameNode>? applyAnalysis(
  GameTree tree,
  Object? json, {
  required String engineName,
  required int minDepth,
}) {
  if (json is! Map) return null;
  if (json['version'] != analysisFormatVersion) return null;
  if (json['engine'] != engineName) return null;
  final depth = savedDepthOf(json);
  if (depth == null || depth < minDepth) return null;
  final searched = Set<GameNode>.identity();
  _applyNode(tree, tree.root, json['root'], searched);
  return searched;
}

/// The depth a saved analysis was searched at, or null when it says none.
int? savedDepthOf(Object? json) {
  final depth = json is Map ? json['depth'] : null;
  return depth is int ? depth : null;
}

void _applyNode(
  GameTree tree,
  GameNode node,
  Object? json,
  Set<GameNode> searched,
) {
  if (json is! Map) return;
  node.eval ??= _decodeEval(json['e']);
  if (json['r'] == true) searched.add(node);
  node.explanation ??= _decodeExplanation(json['x']);

  final children = json['c'];
  if (children is! Map) return;
  for (final entry in children.entries) {
    final uci = entry.key;
    final saved = entry.value;
    if (uci is! String || saved is! Map) continue;
    final move = Move.parse(uci);
    if (move == null) continue;
    // The PGN's own moves are already there; the rest are added back.
    var child = node.childByMove(move);
    if (child == null) {
      if (!node.position.isLegal(move)) continue;
      child = tree.addMove(node, move, isUserMove: saved['u'] == true);
    }
    _applyNode(tree, child, saved, searched);
  }
}

EngineEval? _decodeEval(Object? json) {
  if (json is! Map) return null;
  final depth = json['d'];
  if (depth is! int) return null;
  final best = json['best'];
  final bestMove = best is String ? best : null;

  final mated = Side.values.asNameMap()[json['mated']];
  if (mated != null) {
    return EngineEval.checkmate(
      mated: mated,
      bestMoveUci: bestMove,
      depth: depth,
    );
  }
  final cp = json['cp'];
  final mate = json['mate'];
  // Exactly one of the two, and a mate of 0 is never a score.
  if ((cp is int) == (mate is int)) return null;
  if (mate == 0) return null;
  return EngineEval(
    cp: cp is int ? cp : null,
    mateIn: mate is int ? mate : null,
    bestMoveUci: bestMove,
    pvUci: _strings(json['pv']),
    alternatives: List.unmodifiable(_decodeLines(json['alt'])),
    depth: depth,
  );
}

List<EngineLine> _decodeLines(Object? json) {
  if (json is! List) return const [];
  final lines = <EngineLine>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    final cp = entry['cp'];
    final mate = entry['mate'];
    if ((cp is int) == (mate is int)) continue;
    lines.add(
      EngineLine(
        cp: cp is int ? cp : null,
        mateIn: mate is int ? mate : null,
        pvUci: _strings(entry['pv']),
      ),
    );
  }
  return lines;
}

MoveExplanation? _decodeExplanation(Object? json) {
  if (json is! Map) return null;
  final detail = json['d'];
  if (detail is! String || detail.isEmpty) return null;
  final model = json['m'];
  return MoveExplanation(detail: detail, model: model is String ? model : null);
}

List<String> _strings(Object? json) =>
    json is List ? [...json.whereType<String>()] : const [];
