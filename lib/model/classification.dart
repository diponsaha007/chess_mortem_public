import 'package:dartchess/dartchess.dart';

import 'eval.dart';
import 'exchange.dart';
import 'material_balance.dart';
import 'move_facts.dart' show capturedSquare, landingSquare;

/// Move quality tiers, best to worst. [isMistakeOrWorse] compares indexes.
enum Classification {
  brilliant('Brilliant'),
  great('Great'),
  best('Best'),
  excellent('Excellent'),
  good('Good'),
  inaccuracy('Inaccuracy'),
  mistake('Mistake'),
  blunder('Blunder'),
  miss('Miss');

  const Classification(this.label);

  final String label;

  bool get isMistakeOrWorse => index >= Classification.mistake.index;
}

/// How far the engine's best move is ahead of its second choice, in winning-
/// chance points for [mover]. Null when only one line was searched — unknown,
/// not "nothing else came close".
double? onlyMoveGap(EngineEval eval, Side mover) {
  final second = eval.secondBest;
  if (second == null) return null;
  return winPctFor(eval, mover) - winPctFor(second, mover);
}

/// The gap at which the best move is the ONLY move: the Mistake threshold,
/// so "anything else is a mistake".
const double onlyMoveThreshold = 10.0;

/// Whether [eval] is the engine's draw score: exactly level, no mate. A
/// repetition or a perpetual check reads this way.
bool isDrawScore(EngineEval eval) => eval.cp == 0;

/// Whether [pvUci], played from [start], is [checker] giving check on every
/// one of its moves, at least [minChecks] times: a perpetual, as the engine
/// plays it. A quiet move anywhere in it (a king hunt that goes on) is not.
bool isPerpetualLine(
  Position start,
  List<String> pvUci,
  Side checker, {
  int minChecks = 2,
}) {
  var position = start;
  var checks = 0;
  for (final uci in pvUci) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final mover = position.turn;
    position = position.play(move);
    if (mover != checker) continue;
    if (!position.isCheck) return false;
    checks++;
  }
  return checks >= minChecks;
}

bool isOnlyMove(EngineEval eval, Side mover) {
  final gap = onlyMoveGap(eval, mover);
  return gap != null && gap >= onlyMoveThreshold;
}

/// True when [classify] would promote this move if it knew the runner-up:
/// the move is Best, passes the cheap half of [_isCriticalCandidate], had a
/// choice, and [before] has no runner-up yet. Only then is the runner-up
/// searched; every other verdict never reads it.
bool needsRunnerUp({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
  required String playedUci,
  required Position positionBefore,
}) {
  if (before.secondBest != null) return false;
  if (playedUci != before.bestMoveUci) return false;
  if (positionBefore.isCheck || _isForced(positionBefore)) return false;
  final played = Move.parse(playedUci);
  if (played == null) return false;
  if (played is NormalMove && played.promotion != null) return false;
  return winPctFor(after, mover) >= greatFloorWinPct;
}

/// The depth of the runner-up search: shallower than the eval, as an
/// engine tests a singular move. A gap of [onlyMoveThreshold] shows early,
/// at a fraction of the eval's cost.
const int runnerUpSearchDepth = 10;

/// The runner-up's depth for an eval searched to [evalDepth]: never deeper
/// than the eval itself.
int runnerUpDepthFor(int evalDepth) =>
    evalDepth < runnerUpSearchDepth ? evalDepth : runnerUpSearchDepth;

/// Great may be the only move that HOLDS a worse position; Brilliant must
/// not leave the mover worse.
const double greatFloorWinPct = 40;
const double brilliantFloorWinPct = 50;

/// Every legal move in [position] except [bestUci], in dartchess's UCI
/// (castling as king-takes-rook): what the runner-up search considers.
List<String> runnerUpMoves(Position position, String bestUci) => [
  ...legalMoveUcis(position).where((uci) => uci != bestUci),
];

/// Every legal move in [position], in dartchess's UCI (castling as
/// king-takes-rook), each promotion listed per piece.
List<String> legalMoveUcis(Position position) {
  final moves = <String>{};
  for (final MapEntry(key: from, value: targets)
      in position.legalMoves.entries) {
    final piece = position.board.pieceAt(from);
    for (final to in targets.squares) {
      final promotes =
          piece?.role == Role.pawn &&
          (to.rank == Rank.first || to.rank == Rank.eighth);
      for (final promotion
          in promotes
              ? const [Role.queen, Role.rook, Role.bishop, Role.knight]
              : const <Role?>[null]) {
        final move = position.normalizeMove(
          NormalMove(from: from, to: to, promotion: promotion),
        );
        moves.add(move.uci);
      }
    }
  }
  return [...moves];
}

/// Winning-chance points the mover gave up. <= 0 means nothing was lost.
double winPctDrop({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
}) => winPctFor(before, mover) - winPctFor(after, mover);

/// Classifies a played move from the White-perspective evals before and
/// after it.
///
/// The negative tiers are lichess's `Advice.scala` (5 / 10 / 15 points of
/// win-% drop); a mate on either side is judged by the sequence instead.
/// Best / Excellent / Good are ours.
///
/// Brilliant and Great are PROMOTIONS of a Best verdict and need
/// [positionBefore], [positionAfter] and runner-up lines in [before]. Miss
/// REPLACES a slip and needs [beforeOpponentMove], the eval before the
/// opponent's last move. Without them the result is the six-tier verdict.
/// [opponentWasInCheck]: the opponent's last move answered a check (a
/// perpetual already in hand is not Great). Pure.
Classification classify({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
  required String playedUci,
  Position? positionBefore,
  Position? positionAfter,
  String? previousCaptureUci,
  EngineEval? beforeOpponentMove,
  bool opponentWasInCheck = false,
}) {
  final tier = _qualityTier(
    before: before,
    after: after,
    mover: mover,
    playedUci: playedUci,
  );
  if (tier.index >= Classification.inaccuracy.index) {
    final missed =
        beforeOpponentMove != null &&
        _isMiss(
          beforeOpponentMove: beforeOpponentMove,
          before: before,
          after: after,
          mover: mover,
        );
    return missed ? Classification.miss : tier;
  }
  if (tier != Classification.best) return tier;
  if (positionBefore == null || positionAfter == null) return tier;

  final played = Move.parse(playedUci);
  if (played == null) return tier;
  if (before.secondBest != null &&
      _isCriticalCandidate(
        before: before,
        after: after,
        mover: mover,
        positionBefore: positionBefore,
        played: played,
      )) {
    // Taking back what was just taken gives nothing up, even when the
    // piece that does it is left en prise.
    if (winPctFor(after, mover) >= brilliantFloorWinPct &&
        !_isRecapture(positionBefore, played, previousCaptureUci) &&
        _isBrilliant(
          mover: mover,
          after: after,
          positionBefore: positionBefore,
          positionAfter: positionAfter,
          played: played,
        )) {
      return Classification.brilliant;
    }
    if (_isGreat(
      before: before,
      mover: mover,
      positionBefore: positionBefore,
      positionAfter: positionAfter,
      played: played,
      previousCaptureUci: previousCaptureUci,
      perpetualInHand:
          opponentWasInCheck &&
          beforeOpponentMove != null &&
          isDrawScore(beforeOpponentMove) &&
          isDrawScore(before) &&
          // A check that repeats the position into a draw ends the game,
          // so it has no line to read.
          (after.pvUci.isEmpty ||
              isPerpetualLine(positionAfter, after.pvUci, mover)),
    )) {
      return Classification.great;
    }
  }
  return tier;
}

/// Winning chances at which a side counts as winning. One line for every
/// rating: the runner-up of a Brilliant or Great must be under it.
const double winningWinPct = 75;

/// How much of the opponent's gift a Miss gives back: more than half.
/// Under that the gift was mostly kept, and the move is just a slip.
const double missGiveBack = 0.6;

/// Losing is the mirror of winning: at or under this, a move into it stays
/// a Blunder instead of a Miss.
const double lostWinPct = 100 - winningWinPct;

/// The opponent's last move was a mistake (it handed the mover at least
/// [_opponentSlip] points) and this move gave [missGiveBack] of it back
/// without ending up lost: a missed chance to punish it. Winning or not:
/// most missed chances come in level positions.
bool _isMiss({
  required EngineEval beforeOpponentMove,
  required EngineEval before,
  required EngineEval after,
  required Side mover,
}) {
  final gift = winPctFor(before, mover) - winPctFor(beforeOpponentMove, mover);
  if (gift < _opponentSlip) return false;
  final kept = winPctFor(after, mover);
  if (kept <= lostWinPct) return false;
  return winPctFor(before, mover) - kept >= gift * missGiveBack;
}

/// The opponent's drop that counts as a gift: the Mistake threshold.
const double _opponentSlip = 10;

/// The four tests both promotions share, each ruling out a class of false
/// positive: not escaping check, not a promotion, not lost after (the
/// lower floor, Great's), and not winning anyway.
bool _isCriticalCandidate({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
  required Position positionBefore,
  required Move played,
}) {
  if (positionBefore.isCheck) return false;
  if (played is NormalMove && played.promotion != null) return false;
  if (winPctFor(after, mover) < greatFloorWinPct) return false;
  return !_wasWinningAnyway(before: before, mover: mover);
}

/// True when the SECOND-best move already won outright. Asked of the
/// runner-up, not the position: a queen sacrificed for mate is at the
/// ceiling before it is played, and must still qualify.
bool _wasWinningAnyway({required EngineEval before, required Side mover}) =>
    winPctFor(before.secondBest!, mover) >= winningWinPct;

/// A move that gives material away and is still right: something is on
/// offer, the opponent can legally take it, and it is really given up —
/// accepted and the deficit survives the engine's line, or declined at a
/// real price.
bool _isBrilliant({
  required Side mover,
  required EngineEval after,
  required Position positionBefore,
  required Position positionAfter,
  required Move played,
}) {
  final taken = capturedSquare(positionBefore, played);
  final capturedValue = taken == null
      ? 0
      : valueOf(positionBefore.board.pieceAt(taken)!.role);

  final offered =
      offeredPieces(positionAfter, mover, capturedValue: capturedValue)
          .where(
            (square) =>
                canBeCaptured(positionAfter, square) &&
                offeredByThisMove(
                  positionBefore,
                  positionAfter,
                  square,
                  mover,
                  played,
                ),
          )
          .toList();
  if (offered.isEmpty) return false;

  if (_replyAccepts(positionAfter, after, offered)) {
    return sacrificeHolds(
      positionAfter: positionAfter,
      mover: mover,
      materialBefore: materialFor(positionBefore.board, mover),
      pvUci: after.pvUci,
    );
  }

  return offered.any(
    (square) =>
        exchangeLoss(positionAfter.board, square, mover) >= sacrificeThreshold,
  );
}

/// True when [played] is what put the piece on [square] at risk: it is the
/// piece that moved, or the move made taking it pay more (a defender left,
/// a line opened). A piece already en prise before the move — two rooks
/// forked by the opponent's last move — is not offered by this one. Nor is
/// a moved piece that was lost whatever it did — en prise with no safe
/// square to go to: a queen pinned to its king taking the pinning rook is
/// forced, not given (a desperado). A piece that could have retreated (the
/// Fried Liver's Ng5) still sacrifices itself.
bool offeredByThisMove(
  Position positionBefore,
  Position positionAfter,
  Square square,
  Side mover,
  Move played,
) {
  if (square == landingSquare(positionBefore, played)) {
    return !_lostAnyway(positionBefore, played, mover);
  }
  if (positionBefore.board.pieceAt(square) !=
      positionAfter.board.pieceAt(square)) {
    return true; // the castling rook
  }
  return exchangeLoss(positionAfter.board, square, mover) >
      exchangeLoss(positionBefore.board, square, mover);
}

/// True when the piece [played] moves was en prise and every other square
/// it could go to loses it too: it was going anyway.
bool _lostAnyway(Position positionBefore, Move played, Side mover) {
  final from = (played as NormalMove).from;
  if (exchangeLoss(positionBefore.board, from, mover) <= 0) return false;
  for (final to in positionBefore.legalMovesOf(from).squares) {
    if (to == played.to) continue;
    final escape = NormalMove(from: from, to: to);
    if (!positionBefore.isLegal(escape)) continue;
    final landed = positionBefore.play(escape);
    if (exchangeLoss(landed.board, to, mover) <= 0) return false;
  }
  return true;
}

/// True when the opponent's best answer takes one of the [offered] pieces.
bool _replyAccepts(
  Position positionAfter,
  EngineEval after,
  List<Square> offered,
) {
  final replyUci = after.pvUci.isNotEmpty
      ? after.pvUci.first
      : after.bestMoveUci;
  final reply = replyUci == null ? null : Move.parse(replyUci);
  if (reply == null || !positionAfter.isLegal(reply)) return false;
  return offered.contains(capturedSquare(positionAfter, reply));
}

/// The engine's move when nothing else held, minus the only-moves that take
/// no finding: a single legal move, a recapture, taking material that was
/// hanging anyway, delivering a mate already in hand, keeping up a perpetual
/// check already in hand ([perpetualInHand]), a runner-up that still stands
/// clearly better, and a forced retreat.
bool _isGreat({
  required EngineEval before,
  required Side mover,
  required Position positionBefore,
  required Position positionAfter,
  required Move played,
  String? previousCaptureUci,
  bool perpetualInHand = false,
}) {
  if (!isOnlyMove(before, mover)) return false;
  if (_isForced(positionBefore)) return false;
  if (_isRecapture(positionBefore, played, previousCaptureUci)) return false;

  // The runner-up must really let the advantage go: one that still stands
  // clearly better was not "the only move".
  if (winPctFor(before.secondBest!, mover) >= greatRunnerUpCeiling) {
    return false;
  }

  // Delivering a mate already in hand is technique. Finding the one move
  // that keeps it, when the next best lets the win go, is not.
  final mateBefore = _mateInFor(before, mover);
  if (mateBefore != null && mateBefore > 0 && positionAfter.isCheckmate) {
    return false;
  }

  // The same for a draw: the check that FINDS a perpetual can be Great; the
  // checks that keep it going, once the draw stood on the board before the
  // opponent's last move, are not.
  if (perpetualInHand && positionAfter.isCheck) return false;

  // Taking what was hanging anyway takes no finding. An even trade can:
  // many tactics start with one.
  final taken = capturedSquare(positionBefore, played);
  if (taken != null && staticExchange(positionBefore.board, taken, mover) > 0) {
    return false;
  }
  return !_isRetreat(positionBefore, positionAfter, mover, played);
}

/// True when the moved piece was en prise, the move takes it to safety, and
/// that was its ONE safe square: the runner-up then "loses" by leaving it
/// there — the only move, but the one every player looks at first. With two
/// or more safe squares, choosing the right one is a find. Only the moved
/// piece: asking it of every piece also catches genuine Greats that happen
/// to cover something.
bool _isRetreat(
  Position positionBefore,
  Position positionAfter,
  Side mover,
  Move played,
) {
  if (played is! NormalMove) return false;
  final landed = landingSquare(positionBefore, played);
  if (landed == null) return false;
  if (exchangeLoss(positionBefore.board, played.from, mover) <= 0 ||
      exchangeLoss(positionAfter.board, landed, mover) > 0) {
    return false;
  }
  return _safeSquares(positionBefore, played.from, mover) < 2;
}

/// How many squares the piece on [from] can move to without being lost
/// there (static exchange), counted up to two.
int _safeSquares(Position position, Square from, Side mover) {
  var safe = 0;
  for (final to in position.legalMovesOf(from).squares) {
    final promotes =
        position.board.pieceAt(from)?.role == Role.pawn &&
        (to.rank == Rank.first || to.rank == Rank.eighth);
    final move = position.normalizeMove(
      NormalMove(from: from, to: to, promotion: promotes ? Role.queen : null),
    );
    if (!position.isLegal(move)) continue;
    final landing = landingSquare(position, move) ?? to;
    if (exchangeLoss(position.play(move).board, landing, mover) > 0) continue;
    if (++safe == 2) break;
  }
  return safe;
}

/// Great's own "winning anyway": at or above this for the RUNNER-UP, the
/// played move was not needed. Lower than [winningWinPct], which Brilliant
/// keeps.
const double greatRunnerUpCeiling = 60;

/// True when the side to move has at most one legal move.
bool _isForced(Position position) {
  var count = 0;
  for (final destinations in position.legalMoves.values) {
    count += destinations.size;
    if (count > 1) return false;
  }
  return true;
}

/// True when [played] captures on the square the opponent just captured on.
/// [previousCaptureUci] is the opponent's last move only when it captured:
/// taking a piece that merely moved there is no recapture.
bool _isRecapture(Position before, Move played, String? previousCaptureUci) {
  final previous = previousCaptureUci == null
      ? null
      : Move.parse(previousCaptureUci);
  if (previous is! NormalMove) return false;
  return capturedSquare(before, played) == previous.to;
}

/// The six-tier verdict.
Classification _qualityTier({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
  required String playedUci,
}) {
  if (playedUci == before.bestMoveUci) return Classification.best;
  // Any mate is as good as the engine's: there is nothing left to improve.
  if (after.matedSide == mover.opposite) return Classification.best;

  final mateVerdict = _mateJudgement(
    before: before,
    after: after,
    mover: mover,
  );
  if (mateVerdict != null) return mateVerdict;

  final drop = winPctDrop(before: before, after: after, mover: mover);
  if (drop < 2) return Classification.excellent;
  if (drop < 5) return Classification.good;
  if (drop < 10) return Classification.inaccuracy;
  if (drop < 15) return Classification.mistake;
  return Classification.blunder;
}

/// lichess's `MateAdvice`, from the mover's perspective. Null when no mate
/// sequence is worth judging, so the winning-chance table decides.
Classification? _mateJudgement({
  required EngineEval before,
  required EngineEval after,
  required Side mover,
}) {
  final mateBefore = _mateInFor(before, mover);
  final mateAfter = _mateInFor(after, mover);

  // MateCreated: the mover was not being mated and now is.
  if (mateBefore == null && mateAfter != null && mateAfter < 0) {
    final cpBefore = cpCeiledFor(before, mover);
    if (cpBefore < -999) return Classification.inaccuracy;
    if (cpBefore < -700) return Classification.mistake;
    return Classification.blunder;
  }

  // MateLost: the mover had a forced mate and no longer does. A position that
  // is itself mate against the mover reads as 0, so that is a blunder.
  if (mateBefore != null &&
      mateBefore > 0 &&
      (mateAfter == null || mateAfter < 0)) {
    final cpAfter = mateAfter == null ? cpCeiledFor(after, mover) : 0;
    if (cpAfter > 999) return Classification.inaccuracy;
    if (cpAfter > 700) return Classification.mistake;
    return Classification.blunder;
  }

  return null;
}

/// Moves until mate from [side]'s point of view: positive = [side] mates.
int? _mateInFor(EngineEval eval, Side side) {
  final mateIn = eval.mateIn;
  if (mateIn == null) return null;
  return side == Side.white ? mateIn : -mateIn;
}

/// Winning chances in percent for [side]. With [cpCeiledFor], the only place
/// a stored score is flipped.
double winPctFor(Scored score, Side side) =>
    side == Side.white ? score.winPctWhite : 100 - score.winPctWhite;

/// Ceiling-clamped centipawns for [side].
int cpCeiledFor(Scored score, Side side) =>
    side == Side.white ? score.cpCeiled : -score.cpCeiled;
