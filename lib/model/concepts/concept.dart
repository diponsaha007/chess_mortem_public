/// The vocabulary of a coach line: frame × concept × object. The ids and
/// frames mirror `concepts.json` beside this file; `concepts_test.dart`
/// keeps the two in step.
library;

import 'package:dartchess/dartchess.dart';

/// Whose move a line is about, and when.
enum Frame {
  /// What the played move itself does, visible right after it.
  does,

  /// What the played move sets up for the mover's next move.
  threatens,

  /// What the played move lets the opponent do (the engine's reply line).
  allows,

  /// What the engine's better move would have done.
  better,
}

const _all = {Frame.does, Frame.allows, Frame.better};
const _doesBetter = {Frame.does, Frame.better};

/// One idea a coach line can name. [id] is its id in `concepts.json`.
enum ConceptKind {
  checkmate('checkmate', _all),
  backRankMate('back_rank_mate', {...Frame.values}),
  mateThreat('mate_threat', {Frame.threatens, Frame.allows}),
  check('check', {Frame.does}),
  hangingPiece('hanging_piece', {Frame.allows}),
  captureFree('capture_free', _doesBetter),
  winMaterial('win_material', _all),
  capture('capture', {Frame.does}),
  recapture('recapture', _doesBetter),
  evenTrade('even_trade', _doesBetter),
  tradeWhenAhead('trade_when_ahead', _doesBetter),
  sacrifice('sacrifice', _doesBetter),
  gambit('gambit', {Frame.does}),
  fork('fork', {...Frame.values}),
  pin('pin', _all),
  exploitPin('exploit_pin', _all),
  skewer('skewer', _all),
  discoveredAttack('discovered_attack', _all),
  discoveredCheck('discovered_check', _all),
  trappedPiece('trapped_piece', {...Frame.values}),
  attackTrappedPiece('attack_trapped_piece', {...Frame.values}),
  removeDefender('remove_defender', _all),
  pileOn('pile_on', {Frame.does}),
  attackPiece('attack_piece', {Frame.does, Frame.threatens}),
  pawnKick('pawn_kick', _all),
  gainTempo('gain_tempo', _doesBetter),
  escapeAttack('escape_attack', _doesBetter),
  defendHanging('defend_hanging', _doesBetter),
  removeAttacker('remove_attacker', {Frame.does}),
  defendThreat('defend_threat', _doesBetter),
  ignoredThreat('ignored_threat', _all),
  castle('castle', _doesBetter),
  enableCastling('enable_castling', {Frame.does}),
  luft('luft', {Frame.does}),
  kingExposed('king_exposed', {Frame.allows}),
  kingActivity('king_activity', {Frame.does, Frame.better, Frame.allows}),
  developPiece('develop_piece', {Frame.does, Frame.better, Frame.allows}),
  centralControl('central_control', _doesBetter),
  activeSquare('active_square', {Frame.does, Frame.better, Frame.allows}),
  rookOpenFile('rook_open_file', _doesBetter),
  rookSeventh('rook_seventh', _doesBetter),
  outpost('outpost', _all),
  passivePiece('passive_piece', {Frame.allows}),
  doubledPawns('doubled_pawns', _all),
  isolatedPawn('isolated_pawn', _all),
  passedPawn('passed_pawn', {Frame.does, Frame.better, Frame.allows}),
  pawnChainAttack('pawn_chain_attack', _doesBetter),
  promotion('promotion', {...Frame.values}),
  openingName('opening_name', {Frame.does}),
  onlyMove('only_move', {Frame.does}),
  missedWin('missed_win', {Frame.better}),
  genericQuality('generic_quality', _all),
  escapeCheck('escape_check', _doesBetter),
  opposition('opposition', _doesBetter),
  stopPassedPawn('stop_passed_pawn', _doesBetter),
  backwardPawn('backward_pawn', _all),
  pawnChainCreate('pawn_chain_create', _doesBetter),
  forcedMove('forced_move', {Frame.does}),
  matingNet('mating_net', {Frame.does}),
  perpetualCheck('perpetual_check', _all),
  doubleRooks('double_rooks', {Frame.does}),
  stalemate('stalemate', _all),
  repetition('repetition', {Frame.does}),
  insufficientMaterial('insufficient_material', {Frame.does});

  const ConceptKind(this.id, this.frames);

  /// The id in `concepts.json`, e.g. `hanging_piece`.
  final String id;

  /// The frames a line about this concept can take.
  final Set<Frame> frames;
}

/// One detected candidate: a concept in a frame, about [object] (the
/// TARGET of a tactic, the piece that moved otherwise), with the board fact
/// that makes it true. Detection never ranks; choosing is `salience.dart`'s job.
class Concept {
  const Concept(this.kind, this.frame, {this.object, required this.evidence});

  final ConceptKind kind;
  final Frame frame;

  /// The square the concept is about, or null when it names none.
  final Square? object;

  /// Why it holds, in plain words ("the knight on c3 was attacked by the
  /// pawn on b4 and is safe on e2").
  final String evidence;

  @override
  bool operator ==(Object other) =>
      other is Concept &&
      other.kind == kind &&
      other.frame == frame &&
      other.object == object;

  @override
  int get hashCode => Object.hash(kind, frame, object);

  @override
  String toString() =>
      '${frame.name}/${kind.id}${object == null ? '' : ' ${object!.name}'}';
}
