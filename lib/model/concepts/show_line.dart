/// What the coach line's Show button plays: the engine line that makes the
/// line's point, cut where the point is made. A mate is played to the mate,
/// a hanging piece to the move that takes it, material won by a tactic to
/// the first settled position where it is won.
///
/// Only events a line can show: what the move threatens is never played (the
/// engine's reply answers the threat), nor what the move itself already did,
/// nor a positional idea, which no line makes visible.
library;

import 'package:dartchess/dartchess.dart';

import '../game_phase.dart';
import '../game_tree.dart';
import '../move_facts.dart' show capturedSquare, landingSquare;
import '../move_tags.dart';
import 'concept.dart';
import 'detect_concepts.dart';
import 'node_concepts.dart';
import 'salience.dart';

/// The moves Show plays, in UCI, from [fromParent]'s position.
class ShowLine {
  const ShowLine({required this.fromParent, required this.uci});

  /// True when the line starts from the position BEFORE the move (the
  /// engine's better line); false when it starts after it (the reply line).
  final bool fromParent;

  /// At least one move, all legal from the start.
  final List<String> uci;
}

/// The line Show plays for the concept the coach line names on [node], or
/// null where the line names nothing an engine line can show: the root, a
/// book move, a move whose evals are not in, a positional idea.
ShowLine? showLineForNode(
  GameNode node, {
  GamePhase phase = GamePhase.middlegame,
}) {
  if (node.isRoot || node.openingName != null) return null;
  final input = conceptInputFor(node, phase: phase);
  if (input == null) return null;
  final found = detectConcepts(input);
  final pick = chooseConcept(input, found);
  return showLineFor(input, pick, also: companionsFor(input, pick, found).also);
}

/// The line that shows [pick] happening, or, when [pick] has none, the one
/// that shows [also], the idea the coach line adds to it ("takes back on d4
/// and forks the knight on c3": the fork).
ShowLine? showLineFor(ConceptInput input, Concept pick, {Concept? also}) =>
    _lineFor(input, pick) ?? (also == null ? null : _lineFor(input, also));

ShowLine? _lineFor(ConceptInput input, Concept c) {
  final before = input.before;
  if (!before.isLegal(input.played)) return null;
  final after = before.play(input.played);
  final mover = before.turn;

  // A mate in one found by the rules names its mating move, which the
  // engine's reply may not be.
  if (c.frame == Frame.allows &&
      c.kind == ConceptKind.checkmate &&
      c.evidence.startsWith('mate in one: ')) {
    final mate = mateInOneUci(after, preferred: input.replyUci.firstOrNull);
    return mate == null ? null : ShowLine(fromParent: false, uci: [mate]);
  }

  final Position start;
  final List<String> line;
  final Side scorer; // the side the concept credits
  final LineReading reading;
  final int readingPlies; // counted from [start]
  switch (c.frame) {
    case Frame.does:
      start = after;
      line = input.replyUci;
      scorer = mover;
      reading = readLine(start: before, pvUci: [input.played.uci, ...line]);
      readingPlies = reading.plies - 1;
    case Frame.allows:
      start = after;
      line = input.replyUci;
      scorer = mover.opposite;
      reading = input.tags.allowed;
      readingPlies = reading.plies;
    case Frame.better:
      if (input.isEngineMove) return null;
      start = before;
      line = input.betterUci;
      scorer = mover;
      reading = input.tags.missed;
      readingPlies = reading.plies;
    case Frame.threatens:
      return null;
  }
  final legal = _legalPrefix(start, line);
  final mate = _mateAt(start, legal, scorer.opposite);

  final int? end = switch (c.kind) {
    ConceptKind.checkmate ||
    ConceptKind.backRankMate ||
    ConceptKind.matingNet => mate,
    ConceptKind.hangingPiece => _hangingEnd(start, legal, c.object, reading),
    ConceptKind.promotion when c.frame != Frame.does => _promotionEnd(
      start,
      legal,
      scorer,
    ),
    ConceptKind.perpetualCheck => _perpetualEnd(start, legal),
    ConceptKind.stalemate when c.frame != Frame.does => _stalemateAt(
      start,
      legal,
    ),
    // The mate it buys, or the piece taken and material won back; a line
    // that declines it, or where "the position pays", shows nothing.
    ConceptKind.sacrifice =>
      mate ??
          _sacrificeEnd(
            start,
            legal,
            c.object ?? _offered(input, c.frame),
            scorer,
            reading,
            readingPlies,
          ),
    // The move's own capture is on the board already.
    ConceptKind.captureFree when c.frame == Frame.does => null,
    _ when _materialKinds.contains(c.kind) =>
      mate ?? (reading.winsMaterial ? readingPlies : null),
    _ => null,
  };
  if (end == null || end < 1 || end > legal.length) return null;
  return ShowLine(
    fromParent: c.frame == Frame.better,
    uci: legal.take(end).toList(),
  );
}

/// The concepts shown by the material their line wins (or its mate).
const _materialKinds = {
  ConceptKind.winMaterial,
  ConceptKind.captureFree,
  ConceptKind.fork,
  ConceptKind.skewer,
  ConceptKind.pin,
  ConceptKind.exploitPin,
  ConceptKind.discoveredAttack,
  ConceptKind.discoveredCheck,
  ConceptKind.removeDefender,
  ConceptKind.trappedPiece,
  ConceptKind.attackTrappedPiece,
  ConceptKind.missedWin,
};

/// The longest legal start of [uci] from [start].
List<String> _legalPrefix(Position start, List<String> uci) {
  final legal = <String>[];
  var position = start;
  for (final move in uci) {
    final parsed = Move.parse(move);
    if (parsed == null || !position.isLegal(parsed)) break;
    legal.add(move);
    position = position.play(parsed);
    if (position.isGameOver) break;
  }
  return legal;
}

/// Plies of [uci] until [loser] is mated, or null when the line does not
/// mate them.
int? _mateAt(Position start, List<String> uci, Side loser) {
  var position = start;
  for (final (i, move) in uci.indexed) {
    position = position.play(Move.parse(move)!);
    if (position.isCheckmate) return position.turn == loser ? i + 1 : null;
  }
  return null;
}

/// Plies until the piece on [square] is taken (and taken back, when the
/// next move does), or, with no square, until the tagger's hanging piece is
/// won. The piece must not move first.
int? _hangingEnd(
  Position start,
  List<String> uci,
  Square? square,
  LineReading reading,
) {
  if (square == null) return reading.pays ? reading.plies : null;
  final owner = start.board.sideAt(square);
  if (owner == null) return null;
  var position = start;
  for (final (i, move) in uci.take(6).indexed) {
    final parsed = Move.parse(move)! as NormalMove;
    if (parsed.from == square) return null;
    if (position.turn != owner && parsed.to == square) {
      return _withRecapture(start, uci, i + 1);
    }
    position = position.play(parsed);
  }
  return null;
}

/// Where the sacrificing move of [frame] lands: the piece offered.
Square? _offered(ConceptInput input, Frame frame) {
  final move = frame == Frame.better
      ? Move.parse(input.betterUci.firstOrNull ?? '')
      : input.played;
  if (move == null || !input.before.isLegal(move)) return null;
  return landingSquare(input.before, move);
}

/// Plies until [giver]'s piece on [square] is taken and [reading]'s
/// material is back: null when the line never takes it or wins nothing.
int? _sacrificeEnd(
  Position start,
  List<String> uci,
  Square? square,
  Side giver,
  LineReading reading,
  int readingPlies,
) {
  if (square == null || reading.won.isEmpty) return null;
  var position = start;
  for (final (i, move) in uci.indexed) {
    final parsed = Move.parse(move)!;
    if (capturedSquare(position, parsed) == square &&
        position.board.sideAt(square) == giver) {
      return readingPlies > i ? readingPlies : null;
    }
    position = position.play(parsed);
  }
  return null;
}

/// Plies until [side] promotes, within six; with the recapture when the
/// next move takes the new piece.
int? _promotionEnd(Position start, List<String> uci, Side side) {
  var position = start;
  for (final (i, move) in uci.take(6).indexed) {
    final parsed = Move.parse(move)!;
    final promotes = parsed is NormalMove && parsed.promotion != null;
    if (promotes && position.turn == side) {
      return _withRecapture(start, uci, i + 1);
    }
    position = position.play(parsed);
  }
  return null;
}

/// [plies], or one more when the move after them captures on the square
/// the last of them landed on.
int _withRecapture(Position start, List<String> uci, int plies) {
  if (plies >= uci.length) return plies;
  var position = start;
  for (final move in uci.take(plies - 1)) {
    position = position.play(Move.parse(move)!);
  }
  final last = Move.parse(uci[plies - 1])!;
  final landed = landingSquare(position, last);
  final next = position.play(last);
  final reply = Move.parse(uci[plies])!;
  return capturedSquare(next, reply) == landed ? plies + 1 : plies;
}

/// Plies of a checking line until a position comes round again: the checks
/// go on for ever from there. The whole line when none repeats; null under
/// two plies.
int? _perpetualEnd(Position start, List<String> uci) {
  if (uci.length < 2) return null;
  String key(Position p) => p.fen.split(' ').take(4).join(' ');
  final seen = {key(start)};
  var position = start;
  for (final (i, move) in uci.indexed) {
    position = position.play(Move.parse(move)!);
    if (!seen.add(key(position))) return i + 1;
  }
  return uci.length;
}

/// Plies of [uci] until a stalemate, or null.
int? _stalemateAt(Position start, List<String> uci) {
  var position = start;
  for (final (i, move) in uci.indexed) {
    position = position.play(Move.parse(move)!);
    if (position.isStalemate) return i + 1;
  }
  return null;
}
