/// Choosing the ONE concept a coach line names, out of `detectConcepts`'
/// candidates.
///
/// 1. The verdict picks the frame order: a good move is read by what it
///    DOES, a slip by what it ALLOWS or what was BETTER.
/// 2. A priority table ranks the concepts within a frame: mate, then
///    tactics, then material, then safety, then structure, then activity.
/// 3. The engine line filters: an ALLOWS or BETTER concept about a piece
///    counts only if the line touches that piece in its first moves, and a
///    loss is ALLOWED only if the engine's own move would not lose it too.
/// 4. A learned ranker (`ranker.dart`) takes 2 and 3 as features and
///    corrects them.
/// 5. Fixed rules add the companions a reviewer says in the same breath:
///    "with check", and one paired idea of the same move ([companionsFor]).
///
/// A draw the move makes on the board (stalemate, the third repetition, too
/// little material to mate) ends the game, and a perpetual check or a
/// stalemate in a line is the whole story where it is found. The fitted
/// weights know nothing of them, so fixed rules say them ahead of 2–4.
library;

import 'package:dartchess/dartchess.dart';

import '../classification.dart';
import '../material_balance.dart';
import '../move_facts.dart' show capturedSquare, landingSquare;
import 'concept.dart';
import 'detect_concepts.dart';
import 'ranker.dart';
import 'salience_weights.dart';

/// The concept the line should name for [input]: the learned ranker's pick
/// (`ranker.dart`), or the priority table's while no weights are fitted.
Concept chooseConcept(ConceptInput input, [List<Concept>? candidates]) {
  final found = candidates ?? detectConcepts(input);
  final ended = _drawOnBoard(input, found);
  if (ended != null) return ended;
  final draw = _drawPick(input, found);
  if (draw != null) return draw;
  final dropped = _droppedPiece(input, found);
  if (dropped != null) return dropped;
  final pick = salienceWeights.isNotEmpty
      ? chooseRanked(input, found, salienceWeights)
      : chooseByTable(input, found);
  final chosen =
      _mateFirst(input, found, pick) ??
      _tacticBehind(input, found, pick) ??
      // A piece taken is said before a tactic; a pawn taken after one.
      _gainOverPraise(input, found, pick, minimum: 3) ??
      _tacticOverSideEffect(input, found, pick) ??
      _threatIgnored(input, found, pick) ??
      _gainOverPraise(input, found, pick) ??
      _offerOverPraise(input, found, pick) ??
      pick;
  final reasoned = _reasonForSlip(input, found, chosen) ?? chosen;
  return _mateAllowed(input, found, reasoned) ?? reasoned;
}

/// A slip into a forced mate: the mate is the reason, ahead of any piece
/// the line also forks or wins on the way.
Concept? _mateAllowed(ConceptInput input, List<Concept> found, Concept pick) {
  if (pick.frame == Frame.does ||
      _mateKinds.contains(pick.kind) ||
      ((input.mateAfter ?? 0) >= 0 && !_allowsMateInOne(found))) {
    return null;
  }
  for (final c in rankedConcepts(input, found)) {
    if (c.frame == Frame.allows &&
        c.kind == ConceptKind.checkmate &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

/// A named tactic of the move where the ranker would say only what it
/// escapes or defends, an offer, or the verdict alone: "gives a discovered
/// check", not "moves the knight to safety on d3".
Concept? _tacticOverSideEffect(
  ConceptInput input,
  List<Concept> found,
  Concept pick,
) {
  if (pick.frame != Frame.does) return null;
  final weak =
      _sideEffects.contains(pick.kind) ||
      pick.kind == ConceptKind.escapeCheck ||
      pick.kind == ConceptKind.genericQuality ||
      (pick.kind == ConceptKind.sacrifice &&
          input.verdict != Classification.brilliant);
  if (!weak) return null;
  for (final c in rankedConcepts(input, found)) {
    if (c.frame == Frame.does &&
        _sharpTactics.contains(c.kind) &&
        // What the move itself does, not what its line does later.
        !c.evidence.startsWith('the line') &&
        // Chasing a defender only threatens to remove it.
        (c.kind != ConceptKind.removeDefender ||
            c.evidence.startsWith('takes the defender')) &&
        // A piece with no square is trapped only if it cannot be shielded
        // either: the engine's line must win it.
        (!_trapKinds.contains(c.kind) ||
            (c.object != null &&
                lineCapturesOn(
                  input.before.play(input.played),
                  input.replyUci,
                  c.object!,
                  plies: 4,
                ))) &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

const _trapKinds = {ConceptKind.trappedPiece, ConceptKind.attackTrappedPiece};

/// Tactics a line names over what the move merely escapes or defends.
const _sharpTactics = {
  ConceptKind.discoveredCheck,
  ConceptKind.discoveredAttack,
  ConceptKind.fork,
  ConceptKind.skewer,
  ConceptKind.trappedPiece,
  ConceptKind.attackTrappedPiece,
  ConceptKind.exploitPin,
  ConceptKind.removeDefender,
};

/// A move that mates says so, and one that keeps a forced mate says it is
/// forcing it, over anything quiet the move also does: "moves the queen to
/// safety on d7 with check" under Qd7# hides the whole story. A sacrifice
/// or a named tactic on the way stays.
Concept? _mateFirst(ConceptInput input, List<Concept> found, Concept pick) {
  if (pick.frame != Frame.does || _mateKinds.contains(pick.kind)) return null;
  final mates = input.before.play(input.played).isCheckmate;
  final forcing = (input.mateAfter ?? 0) > 0;
  if (!mates && !forcing) return null;
  if (!mates &&
      !_quiet.contains(pick.kind) &&
      !_sideEffects.contains(pick.kind) &&
      pick.kind != ConceptKind.escapeCheck &&
      pick.kind != ConceptKind.check) {
    return null;
  }
  for (final c in found) {
    if (c.frame == Frame.does && c.kind == ConceptKind.checkmate) return c;
  }
  return null;
}

const _mateKinds = {
  ConceptKind.checkmate,
  ConceptKind.backRankMate,
  ConceptKind.matingNet,
  ConceptKind.perpetualCheck,
};

/// A piece (a minor piece or more) the engine's move leaves to the threat
/// on purpose, where the ranker names a quiet side effect, the castling,
/// or a capture of something cheaper: leaving it is the point.
Concept? _threatIgnored(ConceptInput input, List<Concept> found, Concept pick) {
  if (pick.frame != Frame.does || !_good.contains(input.verdict)) return null;
  final taken = capturedSquare(input.before, input.played);
  final takenValue = taken == null
      ? 0
      : valueOf(input.before.board.roleAt(taken) ?? Role.pawn);
  final quiet =
      _quiet.contains(pick.kind) ||
      pick.kind == ConceptKind.castle ||
      pick.kind == ConceptKind.enableCastling ||
      _takingKinds.contains(pick.kind);
  if (!quiet) return null;
  final after = input.before.play(input.played);
  for (final c in rankedConcepts(input, found)) {
    final object = c.object;
    if (c.frame != Frame.does ||
        c.kind != ConceptKind.ignoredThreat ||
        object == null) {
      continue;
    }
    final value = valueOf(after.board.roleAt(object) ?? Role.pawn);
    if (value >= 3 && value > takenValue && passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

/// A sound offer of a piece (Great, or the engine's own move) where the
/// ranker would only praise the move: the piece left to be taken is the
/// idea.
Concept? _offerOverPraise(
  ConceptInput input,
  List<Concept> found,
  Concept pick,
) {
  if (pick.frame != Frame.does ||
      !_quiet.contains(pick.kind) ||
      (input.verdict != Classification.great &&
          input.verdict != Classification.best)) {
    return null;
  }
  for (final c in rankedConcepts(input, found)) {
    if (c.frame == Frame.does &&
        c.kind == ConceptKind.sacrifice &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

/// A slip read by what it DOES gives no reason: "Black takes back on d4"
/// under a Mistake badge. A Mistake or worse is read by what it allows or
/// what was better; an Inaccuracy only when its DOES line would praise it.
/// Nothing concrete there: the better move alone ("Stronger was Rhe8.").
Concept? _reasonForSlip(ConceptInput input, List<Concept> found, Concept pick) {
  final verdict = input.verdict;
  if (pick.frame != Frame.does || verdict == null) return null;
  final serious = verdict.isMistakeOrWorse;
  if (!serious &&
      !(verdict == Classification.inaccuracy &&
          _praiseLike.contains(pick.kind))) {
    return null;
  }
  if (input.openingName != null) return null;
  for (final c in rankedConcepts(input, found)) {
    if ((c.frame == Frame.allows || c.frame == Frame.better) &&
        c.kind != ConceptKind.genericQuality &&
        !(c.frame == Frame.allows && _vagueGains.contains(c.kind)) &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  if (input.isEngineMove) return null;
  return const Concept(
    ConceptKind.genericQuality,
    Frame.better,
    evidence: 'a slip with no concrete reason: the better move',
  );
}

/// A piece (a minor piece or more) the move leaves for the reply to take,
/// on a move the verdict calls fine: in a lost position a rook can hang
/// without moving the winning chances, and the line must still say it. Not
/// for Brilliant, Great or the engine's own move, where it is a sacrifice.
Concept? _droppedPiece(ConceptInput input, List<Concept> found) {
  final verdict = input.verdict;
  if (verdict == null ||
      verdict.index >= Classification.inaccuracy.index ||
      verdict == Classification.brilliant ||
      verdict == Classification.great ||
      input.isEngineMove ||
      input.openingName != null ||
      !input.tags.allowed.winsMaterial) {
    return null;
  }
  final after = input.before.play(input.played);
  for (final c in rankedConcepts(input, found)) {
    final object = c.object;
    if (c.frame == Frame.allows &&
        c.kind == ConceptKind.hangingPiece &&
        object != null &&
        valueOf(after.board.roleAt(object) ?? Role.pawn) >= 3 &&
        lineTakes(after, input.replyUci, object, plies: 1) &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

/// A capture where the ranker would only praise the move, name a quiet side
/// effect of it (the pawns it doubles, the file it opens) or say what it
/// defends or does to the pawns: what it took is the point. A piece won
/// first; then a passed pawn taken; else the plain fact of the capture or
/// the trade.
Concept? _gainOverPraise(
  ConceptInput input,
  List<Concept> found,
  Concept pick, {
  int minimum = 0,
}) {
  if (pick.frame != Frame.does ||
      !(_quiet.contains(pick.kind) ||
          _sideEffects.contains(pick.kind) ||
          _structure.contains(pick.kind))) {
    return null;
  }
  final taken = capturedSquare(input.before, input.played);
  if (taken == null) return null;
  final role = input.before.board.roleAt(taken);
  if (role == null || valueOf(role) < minimum) return null;
  final ranked = rankedConcepts(input, found);
  for (final kinds in _captureOrder) {
    for (final c in ranked) {
      if (c.frame == Frame.does &&
          c.object == taken &&
          kinds.contains(c.kind) &&
          passesLineTests(input, c, found)) {
        return c;
      }
    }
  }
  return null;
}

/// What a capture is said as, best first.
const _captureOrder = [
  {ConceptKind.captureFree, ConceptKind.winMaterial, ConceptKind.exploitPin},
  {ConceptKind.stopPassedPawn},
  {ConceptKind.recapture},
  {ConceptKind.evenTrade},
  {ConceptKind.capture},
];

/// What a capture does to the pawns: a consequence of what it took.
const _structure = {
  ConceptKind.passedPawn,
  ConceptKind.doubledPawns,
  ConceptKind.isolatedPawn,
  ConceptKind.backwardPawn,
  ConceptKind.pawnChainAttack,
  ConceptKind.pawnChainCreate,
};

/// What a capturing move also does, never its point.
const _sideEffects = {
  ConceptKind.escapeAttack,
  ConceptKind.defendHanging,
  ConceptKind.defendThreat,
};

/// The named tactic that wins the material [pick] is about, when [pick] is
/// "wins material" in ALLOWS or BETTER: one event, and the tactic says how
/// ("lets Black pin the queen on e2", not "lets Black win material").
Concept? _tacticBehind(ConceptInput input, List<Concept> found, Concept pick) {
  if (pick.kind != ConceptKind.winMaterial || pick.frame == Frame.does) {
    return null;
  }
  final allows = pick.frame == Frame.allows;
  final mover = input.before.turn;
  // The very piece the line wins, followed back to where it stood.
  final lost = allows
      ? lostPiece(
          input.before.play(input.played),
          input.replyUci,
          mover,
          input.tags.allowed,
        )
      : lostPiece(
          input.before,
          input.betterUci,
          mover.opposite,
          input.tags.missed,
        );
  if (lost == null) return null;
  for (final c in rankedConcepts(input, found)) {
    if (c.frame == pick.frame &&
        _behindMaterial.contains(c.kind) &&
        !c.evidence.contains('later in the line') &&
        c.object == lost &&
        passesLineTests(input, c, found)) {
      return c;
    }
  }
  return null;
}

/// What a line may add to its concept: "with check" when the frame's move
/// gives check with the piece it moves, and [also], one more idea of that
/// move that reads well beside it ("develops the bishop and clears the way
/// to castle"). Praise for a good move takes the move's idea as [also]
/// ("Spot on, attacking the rook on e8").
typedef Companions = ({bool withCheck, Concept? also});

const Companions noCompanions = (withCheck: false, also: null);

/// The companions of [primary], the concept chosen for [input]. Fixed rules,
/// not a second pick: every pair is one a reviewer writes as one sentence.
Companions companionsFor(
  ConceptInput input,
  Concept primary,
  List<Concept> found,
) {
  final frame = primary.frame;
  final (start, move) = switch (frame) {
    Frame.does => (input.before, input.played),
    Frame.better => (input.before, _first(input.betterUci)),
    Frame.allows => (input.before.play(input.played), _first(input.replyUci)),
    Frame.threatens => (input.before, null),
  };
  if (move == null || !start.isLegal(move) || !_aboutTheMove(primary)) {
    return noCompanions;
  }
  if (frame == Frame.better && input.isEngineMove) return noCompanions;
  if (primary.kind == ConceptKind.genericQuality) {
    return (withCheck: false, also: _praisedIdea(input, found));
  }
  final landing = landingSquare(start, move);
  final withCheck =
      landing != null &&
      start.play(move).checkers.has(landing) &&
      !_standsAlone.contains(primary.kind);

  Concept? also;
  final partners = _pairs[primary.kind];
  // A rook or queen "fighting for the centre" is not what a reviewer says.
  final role = start.board.pieceAt((move as NormalMove).from)?.role;
  final minor = role == Role.knight || role == Role.bishop || role == Role.pawn;
  // A pawn's attack is a kick, said on its own; not "moves to safety and
  // attacks".
  final pawnAttack = role == Role.pawn;
  if (frame != Frame.allows && partners != null) {
    for (final c in rankedConcepts(input, found)) {
      if (c.frame == frame &&
          partners.contains(c.kind) &&
          !(pawnAttack && c.kind == ConceptKind.attackPiece) &&
          // A fork beside a recapture forks pieces, not a pawn.
          !(c.kind == ConceptKind.fork && c.evidence.contains('pawn on')) &&
          (minor ||
              !{primary.kind, c.kind}.contains(ConceptKind.centralControl)) &&
          _aboutTheMove(c) &&
          passesLineTests(input, c, found) &&
          _answered(input, c)) {
        also = c;
        break;
      }
    }
  }
  return (withCheck: withCheck, also: also);
}

/// The ideas a reviewer joins with "and", both ways round.
const Map<ConceptKind, Set<ConceptKind>> _pairs = {
  ConceptKind.developPiece: {
    ConceptKind.enableCastling,
    ConceptKind.centralControl,
  },
  ConceptKind.enableCastling: {ConceptKind.developPiece},
  ConceptKind.centralControl: {ConceptKind.developPiece},
  // "takes back on d4 and forks the knight on c3"
  ConceptKind.recapture: {ConceptKind.fork},
  // "defends the pawn on b7 and attacks the knight on d6"; a pawn kicks.
  ConceptKind.defendHanging: {ConceptKind.attackPiece, ConceptKind.pawnKick},
  ConceptKind.defendThreat: {ConceptKind.attackPiece, ConceptKind.pawnKick},
  ConceptKind.escapeAttack: {ConceptKind.attackPiece},
  ConceptKind.attackPiece: {
    ConceptKind.defendHanging,
    ConceptKind.defendThreat,
    ConceptKind.escapeAttack,
  },
};

/// What a capture's own gain outranks.
const _quiet = {
  ConceptKind.genericQuality,
  ConceptKind.doubledPawns,
  ConceptKind.isolatedPawn,
  ConceptKind.backwardPawn,
  ConceptKind.passedPawn,
  ConceptKind.pawnChainAttack,
  ConceptKind.pawnChainCreate,
  ConceptKind.centralControl,
  ConceptKind.activeSquare,
  ConceptKind.developPiece,
  ConceptKind.pileOn,
  ConceptKind.rookOpenFile,
  ConceptKind.rookSeventh,
  ConceptKind.outpost,
};

/// The verdicts a move is praised with.
const _good = {
  Classification.brilliant,
  Classification.great,
  Classification.best,
  Classification.excellent,
};

/// What a DOES line says that reads as praise: under an Inaccuracy badge it
/// contradicts the verdict. Material won is a fact, not praise, and stays.
const _praiseLike = {
  ConceptKind.developPiece,
  ConceptKind.castle,
  ConceptKind.enableCastling,
  ConceptKind.centralControl,
  ConceptKind.activeSquare,
  ConceptKind.capture,
  ConceptKind.recapture,
  ConceptKind.evenTrade,
  ConceptKind.escapeAttack,
  ConceptKind.defendHanging,
  ConceptKind.defendThreat,
  ConceptKind.pawnKick,
  ConceptKind.attackPiece,
  ConceptKind.gainTempo,
  ConceptKind.discoveredAttack,
  ConceptKind.mateThreat,
  ConceptKind.outpost,
  ConceptKind.rookOpenFile,
  ConceptKind.rookSeventh,
  ConceptKind.pileOn,
  ConceptKind.passedPawn,
  ConceptKind.pawnChainCreate,
  ConceptKind.pin,
  ConceptKind.fork,
};

/// What the opponent's reply gains that is no reason for a slip: "lets
/// White put the queen on a more active square".
const _vagueGains = {
  ConceptKind.activeSquare,
  ConceptKind.centralControl,
  ConceptKind.developPiece,
};

/// The ideas praise may name: concrete, and checked by the board and the
/// engine line. Not the centre, development or "a more active square": true
/// of most moves, they add nothing to "Spot on".
const _praisable = {
  ConceptKind.doubleRooks,
  ConceptKind.rookOpenFile,
  ConceptKind.rookSeventh,
  ConceptKind.attackPiece,
  ConceptKind.pin,
  ConceptKind.pawnKick,
  ConceptKind.passedPawn,
  ConceptKind.outpost,
};

/// Ideas about where a piece stands, not what it does.
const _placement = {
  ConceptKind.doubleRooks,
  ConceptKind.rookOpenFile,
  ConceptKind.rookSeventh,
  ConceptKind.outpost,
};

/// The verdicts whose praise may carry an idea.
const _praised = {
  Classification.great,
  Classification.best,
  Classification.excellent,
  Classification.good,
};

/// The idea a praised move's line names after the praise, or null: the
/// likeliest [_praisable] concept of the played move that the line tests
/// pass and, for an attack, that the reply has to answer.
Concept? _praisedIdea(ConceptInput input, List<Concept> found) {
  if (!_praised.contains(input.verdict) || input.openingName != null) {
    return null;
  }
  // Nothing the moved piece does counts if the reply takes it at once.
  final landing = _landing(input);
  final reply = _first(input.replyUci);
  if (reply is NormalMove && reply.to == landing) return null;
  // A check is the point of a checking move; the file it lands on is not.
  final checks = input.before.play(input.played).isCheck;
  for (final c in rankedConcepts(input, found)) {
    if (checks && _placement.contains(c.kind)) continue;
    if (c.frame == Frame.does &&
        _praisable.contains(c.kind) &&
        _aboutTheMove(c) &&
        passesLineTests(input, c, found) &&
        _answered(input, c)) {
      return c;
    }
  }
  return null;
}

/// An attack is worth naming only when the reply line answers it: in its
/// first three moves the attacked piece moves or is taken, or the attacker
/// is. Other concepts pass.
bool _answered(ConceptInput input, Concept c) {
  final target = c.object;
  if (c.kind != ConceptKind.attackPiece || target == null) return true;
  final attacker = _landing(input);
  var position = input.before.play(input.played);
  for (final uci in input.replyUci.take(3)) {
    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) return false;
    if (move.from == target || move.to == target || move.to == attacker) {
      return true;
    }
    position = position.play(move);
  }
  return false;
}

/// Concepts that speak of the king already, or have a sentence of their
/// own: never "with check".
const _standsAlone = {
  ConceptKind.check,
  ConceptKind.perpetualCheck,
  ConceptKind.stalemate,
  ConceptKind.repetition,
  ConceptKind.insufficientMaterial,
  ConceptKind.checkmate,
  ConceptKind.backRankMate,
  ConceptKind.matingNet,
  ConceptKind.mateThreat,
  ConceptKind.discoveredCheck,
  ConceptKind.escapeCheck,
  ConceptKind.forcedMove,
  ConceptKind.onlyMove,
  ConceptKind.missedWin,
  ConceptKind.openingName,
  ConceptKind.genericQuality,
  ConceptKind.sacrifice,
  ConceptKind.hangingPiece,
  ConceptKind.ignoredThreat,
  ConceptKind.kingExposed,
  ConceptKind.passivePiece,
};

/// Whether [c] is about the first move of its frame (the played move, the
/// better move, the reply), not something read further down a line.
bool _aboutTheMove(Concept c) {
  final evidence = c.evidence;
  if (evidence.contains('later in the line')) return false;
  return switch (c.frame) {
    Frame.does => !evidence.startsWith('the line'),
    Frame.better => evidence.startsWith('the better move: '),
    Frame.allows => evidence.startsWith('the reply: '),
    Frame.threatens => false,
  };
}

Move? _first(List<String> pvUci) =>
    pvUci.isEmpty ? null : Move.parse(pvUci.first);

/// Every candidate, the likeliest first: the ranker's order, or the
/// priority table's while no weights are fitted.
List<Concept> rankedConcepts(ConceptInput input, List<Concept> found) {
  if (salienceWeights.isNotEmpty) {
    return rankConcepts(input, found, salienceWeights);
  }
  final frames = frameOrder(input, found);
  int rank(Concept c) {
    final frame = frames.indexOf(c.frame);
    final kind = priority[c.frame]?.indexOf(c.kind) ?? -1;
    return (frame < 0 ? frames.length : frame) * 100 + (kind < 0 ? 99 : kind);
  }

  final order = [for (var i = 0; i < found.length; i++) i]
    ..sort((a, b) {
      final by = rank(found[a]).compareTo(rank(found[b]));
      return by != 0 ? by : a.compareTo(b);
    });
  return [for (final i in order) found[i]];
}

/// The priority table's pick; `generic_quality` when no concrete candidate
/// survives.
Concept chooseByTable(ConceptInput input, List<Concept> found) {
  if (input.verdict == Classification.miss) {
    // A reviewer's Miss line is about the missed win itself; the concrete
    // idea is the realizer's detail.
    final how = _best(input, found, Frame.better);
    return Concept(
      ConceptKind.missedWin,
      Frame.better,
      object: how?.object,
      evidence: how == null ? 'Miss' : 'Miss: ${how.kind.id}, ${how.evidence}',
    );
  }
  for (final frame in frameOrder(input, found)) {
    final pick = _best(input, found, frame);
    if (pick != null) return pick;
  }
  final frame = frameOrder(input, found).first;
  return Concept(
    ConceptKind.genericQuality,
    frame,
    evidence: 'nothing concrete to name',
  );
}

/// The frames to try for [input], most likely first.
List<Frame> frameOrder(ConceptInput input, List<Concept> found) {
  if (input.openingName != null) return const [Frame.does];
  final verdict = input.verdict;
  switch (verdict) {
    case Classification.miss:
      return const [Frame.better, Frame.allows];
    case Classification.blunder || Classification.mistake:
      // ALLOWS when the reply wins something concrete, else what was better.
      return _punished(input, found)
          ? const [Frame.allows, Frame.better]
          : const [Frame.better, Frame.allows];
    case Classification.inaccuracy:
      return _punished(input, found)
          ? const [Frame.allows, Frame.better, Frame.does]
          : const [Frame.better, Frame.does, Frame.allows];
    default:
      return const [Frame.does, Frame.threatens];
  }
}

/// The draw the move makes on the board, whatever the verdict: the game
/// ends there. A repetition the game played on past is no draw.
Concept? _drawOnBoard(ConceptInput input, List<Concept> found) {
  for (final c in found) {
    if (c.frame == Frame.does &&
        _drawsOnBoard.contains(c.kind) &&
        (c.kind != ConceptKind.repetition || input.repetitionDraws)) {
      return c;
    }
  }
  return null;
}

const _drawsOnBoard = {
  ConceptKind.stalemate,
  ConceptKind.repetition,
  ConceptKind.insufficientMaterial,
};

/// The perpetual check or stalemate in the first frame [frameOrder] tries
/// that has one.
Concept? _drawPick(ConceptInput input, List<Concept> found) {
  for (final frame in frameOrder(input, found)) {
    for (final c in found) {
      if (c.frame == frame && _drawLines.contains(c.kind)) return c;
    }
  }
  return null;
}

const _drawLines = {ConceptKind.perpetualCheck, ConceptKind.stalemate};

/// Whether the rules found a mate in one the move lets in.
bool _allowsMateInOne(List<Concept> found) => found.any(
  (c) =>
      c.kind == ConceptKind.checkmate &&
      c.frame == Frame.allows &&
      c.evidence.startsWith('mate in one'),
);

/// Whether the reply line wins something concrete: mate, material the
/// engine backs, or a draw by perpetual check or stalemate.
bool _punished(ConceptInput input, List<Concept> found) {
  final allowed = input.tags.allowed;
  if (allowed.mates || allowed.winsMaterial) return true;
  if (_allowsMateInOne(found) ||
      found.any(
        (c) => _drawLines.contains(c.kind) && c.frame == Frame.allows,
      )) {
    return true;
  }
  final mate = input.mateAfter;
  return mate != null && mate < 0;
}

/// The frame's candidates, most important first; each kind's rank is its
/// index. Kinds missing from a frame's table are never chosen in it: true,
/// but not what a reviewer says.
/// The draws are left out: fixed rules say them ahead of any table, and a
/// row here would shift the ranker's table feature for every other kind.
const Map<Frame, List<ConceptKind>> priority = {
  Frame.does: [
    ConceptKind.checkmate,
    ConceptKind.backRankMate,
    ConceptKind.perpetualCheck,
    ConceptKind.forcedMove,
    ConceptKind.promotion,
    ConceptKind.fork,
    ConceptKind.skewer,
    ConceptKind.discoveredCheck,
    ConceptKind.discoveredAttack,
    ConceptKind.attackTrappedPiece,
    ConceptKind.pin,
    ConceptKind.recapture,
    ConceptKind.captureFree,
    ConceptKind.ignoredThreat,
    ConceptKind.escapeCheck,
    ConceptKind.escapeAttack,
    ConceptKind.removeAttacker,
    ConceptKind.defendHanging,
    ConceptKind.evenTrade,
    ConceptKind.castle,
    ConceptKind.sacrifice,
    ConceptKind.exploitPin,
    ConceptKind.matingNet,
    ConceptKind.passedPawn,
    ConceptKind.pawnKick,
    ConceptKind.doubleRooks,
    ConceptKind.enableCastling,
    ConceptKind.centralControl,
    ConceptKind.developPiece,
    ConceptKind.gainTempo,
    ConceptKind.pileOn,
    ConceptKind.removeDefender,
    ConceptKind.defendThreat,
    ConceptKind.opposition,
    ConceptKind.outpost,
    ConceptKind.luft,
    ConceptKind.doubledPawns,
    ConceptKind.isolatedPawn,
    ConceptKind.gambit,
    ConceptKind.onlyMove,
    ConceptKind.openingName,
  ],
  Frame.threatens: [
    ConceptKind.mateThreat,
    ConceptKind.backRankMate,
    ConceptKind.fork,
    ConceptKind.attackTrappedPiece,
    ConceptKind.promotion,
  ],
  Frame.allows: [
    ConceptKind.checkmate,
    ConceptKind.backRankMate,
    ConceptKind.perpetualCheck,
    ConceptKind.mateThreat,
    ConceptKind.fork,
    ConceptKind.skewer,
    ConceptKind.discoveredCheck,
    ConceptKind.discoveredAttack,
    ConceptKind.attackTrappedPiece,
    ConceptKind.trappedPiece,
    ConceptKind.pin,
    ConceptKind.exploitPin,
    ConceptKind.hangingPiece,
    ConceptKind.winMaterial,
    ConceptKind.removeDefender,
    ConceptKind.ignoredThreat,
    ConceptKind.promotion,
    ConceptKind.passedPawn,
    ConceptKind.pawnKick,
    ConceptKind.kingExposed,
    ConceptKind.doubledPawns,
    ConceptKind.isolatedPawn,
    ConceptKind.backwardPawn,
    ConceptKind.outpost,
  ],
  Frame.better: [
    ConceptKind.checkmate,
    ConceptKind.backRankMate,
    ConceptKind.perpetualCheck,
    ConceptKind.fork,
    ConceptKind.skewer,
    ConceptKind.discoveredCheck,
    ConceptKind.discoveredAttack,
    ConceptKind.attackTrappedPiece,
    ConceptKind.trappedPiece,
    ConceptKind.pin,
    ConceptKind.captureFree,
    ConceptKind.winMaterial,
    ConceptKind.recapture,
    ConceptKind.promotion,
    ConceptKind.exploitPin,
    ConceptKind.removeDefender,
    ConceptKind.sacrifice,
    ConceptKind.ignoredThreat,
    ConceptKind.passedPawn,
    ConceptKind.escapeCheck,
    ConceptKind.defendHanging,
    ConceptKind.defendThreat,
    ConceptKind.pawnKick,
    ConceptKind.castle,
    ConceptKind.centralControl,
    ConceptKind.stopPassedPawn,
    ConceptKind.missedWin,
  ],
};

/// The highest-ranked candidate in [frame] that passes the line tests.
Concept? _best(ConceptInput input, List<Concept> found, Frame frame) {
  final table = priority[frame]!;
  final landing = _landing(input);
  // A minor piece leaving home is development first; the centre it eyes
  // is a side effect. A pawn's is the other way round (the table's order).
  double rank(Concept c) {
    if (c.kind == ConceptKind.developPiece &&
        c.frame == Frame.does &&
        c.object == landing &&
        table.contains(ConceptKind.centralControl)) {
      return table.indexOf(ConceptKind.centralControl) - 0.5;
    }
    return table.indexOf(c.kind).toDouble();
  }

  final ranked = [
    for (final c in found)
      if (c.frame == frame && table.contains(c.kind)) c,
  ]..sort((a, b) => rank(a).compareTo(rank(b)));
  for (final c in ranked) {
    if (passesLineTests(input, c, found)) return c;
  }
  return null;
}

/// The tactics [_tacticBehind] may name in place of "wins material": each
/// says how the piece is won. Not removing a defender or hitting a pinned
/// piece: "wins a pawn" says it plainer.
const _behindMaterial = {
  ConceptKind.fork,
  ConceptKind.pin,
  ConceptKind.skewer,
  ConceptKind.discoveredAttack,
  ConceptKind.trappedPiece,
};

/// Tactics that are only worth naming when the line cashes them in.
const _tactics = {
  ConceptKind.fork,
  ConceptKind.skewer,
  ConceptKind.discoveredAttack,
  ConceptKind.attackTrappedPiece,
  ConceptKind.exploitPin,
  ConceptKind.removeDefender,
};

/// Tactics a line may name only together with their target's square.
const _named = {..._tactics, ConceptKind.pin, ConceptKind.trappedPiece};

/// The engine-line tests: whether the engine's lines back [c]. A concept
/// about a piece counts only if the line touches that piece, and a loss is
/// ALLOWED only if the reply line comes out ahead and the engine's own move
/// would not lose it too.
bool passesLineTests(ConceptInput input, Concept c, List<Concept> found) {
  // A piece left en prise is a sacrifice only when the verdict says so:
  // Brilliant, or an offer of a minor piece or more that the engine stands
  // behind (Great, or its own move).
  if (c.kind == ConceptKind.sacrifice &&
      c.frame == Frame.does &&
      input.verdict != Classification.brilliant &&
      !_soundOffer(input, c)) {
    return false;
  }
  if (_tactics.contains(c.kind) && !_pays(input, found, c.frame)) {
    return false;
  }
  // A tactic is said only about a piece on a square: "fork two pieces" from
  // a line reading cannot be checked.
  if (_named.contains(c.kind) && c.object == null) return false;
  final before = input.before;
  final after = before.play(input.played);
  // A loss is allowed only if the reply line really comes out ahead: a
  // queen taken and won straight back was never hanging.
  if (c.frame == Frame.allows &&
      _lossKinds.contains(c.kind) &&
      !(input.tags.allowed.winsMaterial || input.tags.allowed.mates)) {
    return false;
  }
  // Free material is free only if the line does not take as much back
  // elsewhere at once (Nxd5, answered by Bxd8 taking the queen back).
  if ((c.kind == ConceptKind.captureFree ||
          c.kind == ConceptKind.winMaterial) &&
      c.object != null &&
      (c.frame == Frame.does || c.frame == Frame.better)) {
    final (start, move, answer) = c.frame == Frame.does
        ? (before, input.played.uci, input.replyUci.firstOrNull)
        : (
            before,
            input.betterUci.firstOrNull,
            input.betterUci.elementAtOrNull(1),
          );
    if (move != null &&
        answer != null &&
        _takesBack(start, move, answer, c.object!)) {
      return false;
    }
  }
  // Nothing is won for free when the reply line wins more back or mates,
  // or when the piece was a sound sacrifice the opponent just left.
  if ((c.kind == ConceptKind.captureFree ||
          c.kind == ConceptKind.winMaterial) &&
      c.frame == Frame.does &&
      (input.opponentBrilliant ||
          input.tags.allowed.winsMaterial ||
          input.tags.allowed.mates ||
          _winsBack(input))) {
    return false;
  }
  // "Better was Nxe7, winning the rook" when the played move took that rook
  // too says nothing about the difference.
  if (c.frame == Frame.better &&
      _takingKinds.contains(c.kind) &&
      c.object != null &&
      c.object == capturedSquare(before, input.played)) {
    return false;
  }
  // Nor does "creating a passed pawn on f5" when the played move made the
  // same passed pawn, or "moving the queen to safety" when the played move
  // saved that queen too.
  if (c.frame == Frame.better &&
      (_playedDoesToo(c, found) || _savedToo(input, c, found))) {
    return false;
  }
  // No outpost for a piece the reply takes at once.
  if (c.kind == ConceptKind.outpost &&
      c.frame == Frame.does &&
      c.object != null &&
      lineTakes(after, input.replyUci, c.object!, plies: 1)) {
    return false;
  }
  final object = c.object;
  // A tactic further down the line counts only if its target falls.
  if (c.evidence.contains('later in the line')) {
    if (object == null) return false;
    final (start, line) = c.frame == Frame.better
        ? (before, input.betterUci)
        : (after, input.replyUci);
    if (!lineCapturesOn(start, line, object)) return false;
  }
  if (object == null) return true;
  switch (c.frame) {
    case Frame.allows:
      if (!lineTouches(after, input.replyUci, object)) return false;
      // Lost to the engine's own move too: not what THIS move allowed.
      if (_lossKinds.contains(c.kind) && !input.isEngineMove) {
        final origin = object == _landing(input) ? _from(input.played) : object;
        if (lineTakes(before, input.betterUci, origin)) return false;
      }
      return true;
    case Frame.better:
      // Ignoring a threat is the line NOT dealing with that piece.
      return c.kind == ConceptKind.ignoredThreat ||
          lineTouches(before, input.betterUci, object);
    case Frame.does || Frame.threatens:
      return true;
  }
}

/// Whether the played move's own reading has [c] too: the same concept on
/// the same square.
bool _playedDoesToo(Concept c, List<Concept> found) =>
    c.object != null &&
    found.any(
      (d) => d.frame == Frame.does && d.kind == c.kind && d.object == c.object,
    );

/// Whether [c] saves a piece (moves it to safety, or parries the threat to
/// it) that the played move took out of danger too: it moved that piece to
/// safety itself, or took a piece that was attacking it.
bool _savedToo(ConceptInput input, Concept c, List<Concept> found) {
  final better = Move.parse(input.betterUci.firstOrNull ?? '');
  final played = input.played;
  if (better is! NormalMove || played is! NormalMove) return false;
  final Square saved;
  switch (c.kind) {
    case ConceptKind.escapeAttack:
      saved = better.from;
    case ConceptKind.defendThreat when c.object != null:
      saved = c.object!;
    default:
      return false;
  }
  if (played.from == saved) {
    return found.any(
      (d) => d.frame == Frame.does && d.kind == ConceptKind.escapeAttack,
    );
  }
  final taken = capturedSquare(input.before, played);
  return taken != null &&
      input.before.board
          .attacksTo(saved, input.before.turn.opposite)
          .has(taken);
}

/// Whether the reply line's first moves take back at least what the played
/// move took, net of what the mover takes in between (Qxd3, answered by
/// Nf2+ Rxf2 Bxd3). Read from the captures themselves: in a lost position
/// the engine's line no longer counts material.
bool _winsBack(ConceptInput input) {
  final taken = capturedSquare(input.before, input.played);
  if (taken == null) return false;
  final value = valueOf(input.before.board.roleAt(taken) ?? Role.pawn);
  final (theirs, mine) = _replyCaptures(input);
  return theirs - mine >= value;
}

/// What the opponent and the mover capture, in pawns, in the reply line's
/// first four plies: an even number, so the mover's answer is counted too.
(int, int) _replyCaptures(ConceptInput input) {
  final after = input.before.play(input.played);
  final mover = input.before.turn;
  int sum(List<Role> roles) => roles.fold(0, (t, r) => t + valueOf(r));
  return (
    sum(lineCaptures(after, input.replyUci, mover.opposite, plies: 4)),
    sum(lineCaptures(after, input.replyUci, mover, plies: 4)),
  );
}

/// The concepts that say the move takes something.
const _takingKinds = {
  ConceptKind.capture,
  ConceptKind.captureFree,
  ConceptKind.winMaterial,
  ConceptKind.recapture,
};

/// The piece that moved, a minor piece or more, left where it can be taken
/// by a move the engine stands behind (Great, or the engine's own move),
/// whose line neither simply wins it nor trades it straight back. A piece that was en prise already is
/// an ignored threat, not an offer.
bool _soundOffer(ConceptInput input, Concept c) {
  final object = c.object;
  if (object == null) return false;
  if (input.verdict != Classification.great &&
      !(input.verdict == Classification.best && input.isEngineMove)) {
    return false;
  }
  // A move out of check is forced: what it leaves is not offered. Nor is
  // anything in a lost position, where the engine's line no longer counts
  // a piece.
  if (input.before.isCheck) return false;
  final chances = input.winPctAfter;
  if (chances != null && chances < greatFloorWinPct) return false;
  // The piece that moved, and only where the engine's line does not cash
  // it in: a piece the line simply wins is lost, not offered.
  if (object != _landing(input) ||
      input.tags.allowed.winsMaterial ||
      input.tags.allowed.mates) {
    return false;
  }
  final after = input.before.play(input.played);
  final role = after.board.roleAt(object);
  if (role == null || valueOf(role) < 3) return false;
  // Taken and the same worth taken straight back (Rg1+ Rxg1 Kxh7): a
  // trade. Won back with interest (Bf5 exf5 Rxe7) it is an offer that pays.
  if (_tradedBack(after, input.replyUci, object, valueOf(role))) return false;
  return offeredByThisMove(
    input.before,
    after,
    object,
    input.before.turn,
    input.played,
  );
}

/// Whether the first move of [pvUci] from [start] takes the piece on
/// [square] and the next takes back a piece worth exactly [value].
bool _tradedBack(Position start, List<String> pvUci, Square square, int value) {
  if (pvUci.length < 2) return false;
  final take = Move.parse(pvUci[0]);
  if (take is! NormalMove || take.to != square || !start.isLegal(take)) {
    return false;
  }
  final taken = start.play(take);
  final back = Move.parse(pvUci[1]);
  if (back is! NormalMove || !taken.isLegal(back)) return false;
  final victim = taken.board.roleAt(back.to);
  return victim != null && valueOf(victim) == value;
}

/// Whether the line read in [frame] wins material or mates.
bool _pays(ConceptInput input, List<Concept> found, Frame frame) {
  final reading = switch (frame) {
    Frame.allows => input.tags.allowed,
    Frame.better => input.tags.missed,
    _ => null,
  };
  if (reading != null && (reading.winsMaterial || reading.mates)) return true;
  return found.any(
    (c) =>
        c.frame == frame &&
        (c.kind == ConceptKind.winMaterial || c.kind == ConceptKind.checkmate),
  );
}

const _lossKinds = {
  ConceptKind.hangingPiece,
  ConceptKind.winMaterial,
  ConceptKind.ignoredThreat,
};

Square? _landing(ConceptInput input) => switch (input.played) {
  NormalMove(:final to) => to,
  _ => null,
};

Square _from(Move move) => (move as NormalMove).from;

/// Whether the first [plies] moves of [pvUci] from [start] move, take or
/// attack whatever stands on [square] (following it if it moves).
bool lineTouches(
  Position start,
  List<String> pvUci,
  Square square, {
  int plies = 4,
}) {
  var position = start;
  for (final uci in pvUci.take(plies)) {
    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) return false;
    if (move.from == square || move.to == square) return true;
    position = position.play(move);
    final piece = position.board.pieceAt(move.to);
    if (piece != null &&
        attacks(piece, move.to, position.board.occupied).has(square) &&
        position.board.occupied.has(square)) {
      return true;
    }
  }
  return false;
}

/// Whether the opponent captures on [square] in the first [plies] moves of
/// [pvUci] from [start], before the piece there has moved.
bool lineTakes(
  Position start,
  List<String> pvUci,
  Square square, {
  int plies = 4,
}) {
  var position = start;
  final owner = start.board.sideAt(square);
  if (owner == null) return false;
  for (final uci in pvUci.take(plies)) {
    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) return false;
    if (move.from == square) return false;
    if (move.to == square && position.turn != owner) return true;
    position = position.play(move);
  }
  return false;
}

/// Whether any move in the first [plies] of [pvUci] from [start] captures
/// on [square].
bool lineCapturesOn(
  Position start,
  List<String> pvUci,
  Square square, {
  int plies = 8,
}) {
  var position = start;
  for (final uci in pvUci.take(plies)) {
    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) return false;
    if (move.to == square && position.board.occupied.has(square)) return true;
    position = position.play(move);
  }
  return false;
}

/// The roles [side] captures in the first [plies] moves of [pvUci] from
/// [start]: the material a reader can see being won.
List<Role> lineCaptures(
  Position start,
  List<String> pvUci,
  Side side, {
  int plies = 6,
}) {
  final taken = <Role>[];
  var position = start;
  for (final uci in pvUci.take(plies)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    if (position.turn == side && move is NormalMove) {
      final victim = position.board.pieceAt(move.to);
      if (victim != null && victim.color != side) taken.add(victim.role);
    }
    position = position.play(move);
  }
  return taken;
}

/// Whether [answerUci], the reply to [moveUci] played in [start], captures
/// at least as much as the piece [moveUci] took on [taken].
bool _takesBack(
  Position start,
  String moveUci,
  String answerUci,
  Square taken,
) {
  final move = Move.parse(moveUci);
  if (move == null || !start.isLegal(move)) return false;
  final victim = start.board.pieceAt(taken);
  if (victim == null) return false;
  final after = start.play(move);
  final answer = Move.parse(answerUci);
  if (answer is! NormalMove || !after.isLegal(answer)) return false;
  final back = after.board.pieceAt(answer.to);
  return back != null && valueOf(back.role) >= valueOf(victim.role);
}
