import 'package:dartchess/dartchess.dart';

import '../llm/move_explainer.dart';
import 'classification.dart';
import 'eval.dart';
import 'move_facts.dart' as facts show capturedSquare, landingSquare;
import 'move_tags.dart';
import 'pv_line.dart';

/// One position in the game. [move] is the edge INTO this node (null at the
/// root). `children[0]` is the mainline; other children are variations.
class GameNode {
  GameNode({
    required this.position,
    this.parent,
    this.move,
    this.san,
    this.isUserMove = false,
  });

  /// The position AFTER [move].
  final Position position;
  final GameNode? parent;
  final Move? move;
  final String? san;

  /// Created by the user playing a what-if move, not imported from the PGN.
  final bool isUserMove;

  final List<GameNode> children = [];

  /// Written once, via `eval ??=` in AnalysisSession, and at most once more
  /// to add the runner-up (`withRunnerUp`).
  EngineEval? eval;

  Classification? classification;

  /// Set while the game is still in the opening book. Not a [Classification]:
  /// book moves keep their real verdict.
  String? openingName;

  bool get isBook => openingName != null;

  /// Only successful explanations land here.
  MoveExplanation? explanation;

  bool get isRoot => parent == null;

  /// Who played [move]. Meaningless at the root.
  Side get sideThatMoved => position.turn.opposite;

  /// The piece that played [move]: the king when castling, the pawn when
  /// promoting.
  Piece? get movedPiece {
    final played = move;
    if (played is! NormalMove || parent == null) return null;
    return parent!.position.board.pieceAt(played.from);
  }

  /// Where a badge for this move belongs — the king's square when castling.
  Square? get landingSquare {
    final played = move;
    if (played == null || parent == null) return null;
    return facts.landingSquare(parent!.position, played);
  }

  /// Half-moves from the start. Cached: [parent] never changes.
  late final int ply = parent == null ? 0 : parent!.ply + 1;

  /// True when this move took something, en passant included.
  bool get isCapture {
    final from = parent;
    final played = move;
    return from != null &&
        played != null &&
        facts.capturedSquare(from.position, played) != null;
  }

  /// The engine's choice where this move was played FROM. The PARENT's eval:
  /// this node's eval is the opponent's reply.
  String? get engineMoveUci => parent?.eval?.bestMoveUci;

  bool get isEngineMove => move != null && engineMoveUci == move!.uci;

  /// What should have been played instead, in SAN. Null when this move was
  /// the engine's choice or the parent is not evaluated yet.
  String? get betterMoveSan {
    if (parent == null || isEngineMove) return null;
    return sanOf(parent!.position, engineMoveUci);
  }

  /// The engine's line from the parent, in SAN. Empty unless the PV starts
  /// with the parent's own `bestMoveUci`.
  List<String> get betterLineSan {
    final eval = parent?.eval;
    if (eval == null || !eval.pvStartsWithBest) return const [];
    return pvToSan(parent!.position, eval.pvUci);
  }

  /// [betterLineSan] cut at the move that makes the point. The variation
  /// branch and the sheet both use this, so they never disagree.
  List<String> get betterKeyLine => keyLine(betterLineSan);

  /// The tactics around this move, read off the cached PVs (`tagMove`): what
  /// it allowed, from this node's eval, and what the better move had, from
  /// the parent's. Not cached — both evals can still arrive.
  MoveTags get tags {
    final from = parent;
    final played = move;
    final after = eval;
    if (from == null || played == null || after == null) return MoveTags.none;
    final before = from.eval;
    final better = before != null && before.pvStartsWithBest
        ? before.pvUci
        : const <String>[];
    // What the engine says the move cost the mover, in pawns.
    final mover = sideThatMoved;
    final drop = before == null
        ? null
        : (cpCeiledFor(before, mover) - cpCeiledFor(after, mover)) / 100;
    return tagMove(
      before: from.position,
      played: played,
      refutationUci: after.pvUci,
      betterUci: better,
      previous: from.move,
      beforePrevious: from.parent?.position,
      evalDrop: drop,
    );
  }

  /// The opponent's best reply — from THIS node's eval.
  String? get replyMoveUci => eval?.bestMoveUci;

  String? get replyMoveSan => sanOf(position, replyMoveUci);

  /// True off the imported mainline: a PGN variation or a what-if move.
  bool get isVariation {
    var node = this;
    while (node.parent != null) {
      if (!identical(node.parent!.children.first, node)) return true;
      node = node.parent!;
    }
    return false;
  }

  /// The child reached by [move], compared by UCI.
  GameNode? childByMove(Move move) {
    for (final child in children) {
      if (child.move?.uci == move.uci) return child;
    }
    return null;
  }
}

/// The whole game as a tree of positions connected by moves.
class GameTree {
  GameTree._(this.root, this.headers);

  GameTree.empty() : root = GameNode(position: Chess.initial), headers = {};

  final GameNode root;
  final Map<String, String> headers;

  /// A PGN header, or null when missing or dartchess's `?` placeholder.
  String? header(String key) {
    final value = headers[key]?.trim();
    if (value == null || value.isEmpty || value == '?') return null;
    return value;
  }

  /// Parses a PGN, mainline and variations. Throws [FormatException] on an
  /// illegal move.
  factory GameTree.fromPgn(String pgn) {
    final game = PgnGame.parsePgn(pgn);
    final root = GameNode(position: PgnGame.startingPosition(game.headers));
    _importChildren(from: game.moves, into: root);
    return GameTree._(root, Map.of(game.headers));
  }

  static void _importChildren({
    required PgnNode<PgnNodeData> from,
    required GameNode into,
  }) {
    for (final pgnChild in from.children) {
      final san = pgnChild.data.san;
      final move = into.position.parseSan(san);
      if (move == null) {
        throw FormatException('Illegal move "$san" at ply ${into.ply + 1}');
      }
      final child = GameNode(
        position: into.position.play(move),
        parent: into,
        move: move,
        san: san,
      );
      into.children.add(child);
      _importChildren(from: pgnChild, into: child);
    }
  }

  /// Adds [move] under [from], or returns the existing child for that edge.
  /// The dedupe keeps a revisited position's cached eval.
  GameNode addMove(GameNode from, Move move, {bool isUserMove = false}) {
    final existing = from.childByMove(move);
    if (existing != null) return existing;

    if (!from.position.isLegal(move)) {
      throw ArgumentError('Illegal move ${move.uci} in ${from.position.fen}');
    }
    final (newPosition, san) = from.position.makeSan(move);
    final child = GameNode(
      position: newPosition,
      parent: from,
      move: move,
      san: san,
      isUserMove: isUserMove,
    );
    from.children.add(child);
    return child;
  }

  /// The mainline moves in order, root excluded.
  List<GameNode> get mainline {
    final nodes = <GameNode>[];
    var node = root;
    while (node.children.isNotEmpty) {
      node = node.children.first;
      nodes.add(node);
    }
    return nodes;
  }
}
