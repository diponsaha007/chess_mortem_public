/// A [GameNode] as the detectors' input, read from the tree's cached evals.
library;

import 'package:dartchess/dartchess.dart';

import '../classification.dart';
import '../eval.dart';
import '../game_phase.dart';
import '../game_tree.dart';
import '../material_balance.dart' show valueOf;
import '../move_facts.dart' show capturedSquare, landingSquare;
import '../repetition.dart';
import 'board_concepts.dart' show EarlierCapture;
import 'detect_concepts.dart';

/// The input for the move that led to [node], or null until both evals are
/// in (or for the root).
ConceptInput? conceptInputFor(
  GameNode node, {
  GamePhase phase = GamePhase.middlegame,
}) {
  final parent = node.parent;
  final played = node.move;
  final before = parent?.eval;
  final after = node.eval;
  if (parent == null || played == null || before == null || after == null) {
    return null;
  }
  final mover = node.sideThatMoved;
  final previousMove = parent.move;
  final grand = parent.parent?.position;
  return ConceptInput(
    before: parent.position,
    played: played,
    previous: previousMove == null || grand == null
        ? null
        : (
            to: landingSquare(grand, previousMove)!,
            captured: capturedSquare(grand, previousMove) != null,
          ),
    earlierCapture: _earlierCapture(parent),
    opponentSlipped: parent.classification?.isMistakeOrWorse ?? false,
    opponentBrilliant: parent.classification == Classification.brilliant,
    acceptance: _acceptance(node),
    betterUci: before.pvStartsWithBest ? before.pvUci : const [],
    replyUci: after.pvUci,
    tags: node.tags,
    verdict: node.classification,
    openingName: node.openingName,
    phase: phase,
    mateBefore: _mateFor(before, mover),
    mateAfter: _mateFor(after, mover),
    winPctDrop: winPctDrop(before: before, after: after, mover: mover),
    winPctAfter: winPctFor(after, mover),
    drawBefore: isDrawScore(before),
    drawAfter: isDrawScore(after),
    perpetualInHand: _perpetualInHand(parent),
    repetitions: repetitionsOf(node),
    repetitionDraws: drawnByRepetition(node),
    repeatedByChecks: repeatedByChecks(node),
  );
}

/// The opponent's capture one move before the move that led to [parent],
/// when the piece that captured still stands there. Not when the captures
/// on that square had come out even for the opponent (Bxe4 Rxe4): taking
/// there again starts a new trade.
EarlierCapture? _earlierCapture(GameNode parent) {
  final last = parent.move;
  final mine = parent.parent;
  final theirs = mine?.parent;
  final earlier = theirs?.move;
  final start = theirs?.parent?.position;
  if (last == null || earlier == null || start == null) return null;
  final took = capturedSquare(start, earlier);
  final to = landingSquare(start, earlier);
  if (took == null || to == null || to != took) return null;
  if (_exchangeOn(theirs!, to) <= 0) return null;
  final piece = theirs.position.board.pieceAt(to);
  final still = parent.position.board.pieceAt(to);
  if (piece == null || piece != still) return null;
  if (last is NormalMove && last.from == to) return null;
  return (to: to, took: start.board.roleAt(took)!);
}

/// What the side that played [node]'s move has won on [square] in the run
/// of captures there ending with that move, in pawns: Bxc6 bxc6 Nxc6 is
/// +1, Bxe4 Rxe4 is 0.
int _exchangeOn(GameNode node, Square square) {
  var total = 0;
  var sign = 1;
  for (GameNode? n = node; n != null; n = n.parent) {
    final move = n.move;
    final start = n.parent?.position;
    if (move == null || start == null) break;
    final taken = capturedSquare(start, move);
    if (taken == null || landingSquare(start, move) != square) break;
    total += sign * valueOf(start.board.roleAt(taken)!);
    sign = -sign;
  }
  return total;
}

/// The game's next move after [node], once it has been searched.
Acceptance? _acceptance(GameNode node) {
  final next = node.children.firstOrNull;
  final move = next?.move;
  final eval = next?.eval;
  if (next == null || move == null || eval == null) return null;
  final taker = next.sideThatMoved;
  final mate = eval.mateIn;
  final mates =
      eval.matedSide == taker ||
      (mate != null && mate != 0 && (mate > 0) == (taker == Side.black));
  return (uci: move.uci, replyUci: eval.pvUci, mates: mates);
}

/// Whether the draw stood before the opponent's last move (the move that
/// led to [parent]) and that move answered a check.
bool _perpetualInHand(GameNode parent) {
  final grand = parent.parent;
  final eval = grand?.eval;
  return grand != null &&
      eval != null &&
      grand.position.isCheck &&
      isDrawScore(eval);
}

/// Moves to mate from [mover]'s side (positive: [mover] mates); null for a
/// plain score or a finished game (the board says that itself).
int? _mateFor(EngineEval eval, Side mover) {
  final mate = eval.mateIn;
  if (eval.isCheckmate || mate == null || mate == 0) return null;
  return mover == Side.white ? mate : -mate;
}
