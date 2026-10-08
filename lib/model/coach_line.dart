/// The realizer: ONE chosen [Concept] as ONE sentence, from templates keyed
/// by frame × concept. The plain voice is short and declarative; a seed
/// varies its wording, and the playful layer (`coach_flavor.dart`) adds a
/// reaction at the big moments.
///
/// Every word comes from the concept, the board or the engine's SAN, so a
/// line can only say what the detectors found. Pieces are named by square
/// ("the knight on c3"), never by owner, so a line cannot get it wrong
/// whose piece it is.
library;

import 'package:dartchess/dartchess.dart';

import 'classification.dart';
import 'coach_flavor.dart';
import 'concepts/concept.dart';
import 'concepts/detect_concepts.dart';
import 'concepts/node_concepts.dart';
import 'concepts/salience.dart';
import 'game_phase.dart';
import 'game_tree.dart';
import 'material_balance.dart' show materialFor;
import 'move_facts.dart' show capturedSquare, castlingSide, landingSquare;
import 'move_tags.dart' show describeRoles, tacticSummaryLine;
import 'opening_key.dart' show fnv1a63;
import 'pv_line.dart';
import 'sides.dart';

/// The concept line for [input]: the concept `chooseConcept` picks, with
/// the companions `companionsFor` allows it, as [coachSentence] says it.
String conceptLine(
  ConceptInput input, {
  Side? userSide,
  int? seed,
  bool playful = false,
}) {
  final found = detectConcepts(input);
  final pick = chooseConcept(input, found);
  return coachSentence(
    pick,
    input,
    userSide: userSide,
    seed: seed,
    playful: playful,
    companions: companionsFor(input, pick, found),
  );
}

/// The line for [concept], chosen for [input]. [userSide] turns "White" /
/// "Black" into "You" / "Your opponent". [seed] picks among wordings (null:
/// always the first), [playful] adds a reaction when the line names a big
/// moment, and [companions] may join the sentence.
String coachSentence(
  Concept concept,
  ConceptInput input, {
  Side? userSide,
  int? seed,
  bool playful = false,
  Companions companions = noCompanions,
}) {
  final line = _Line(concept, input, userSide, seed);
  final (:plain, :concrete) = _plainSentence(line, companions);
  if (!playful) return plain;
  final reaction = _reaction(line, concrete: concrete);
  if (reaction == null) return plain;
  final slots = FlavorSlots(
    voice: reaction.voice,
    side: sideName(line.mover),
    piece: line.piece,
    betterSan: line.betterSan,
  );
  return flavor(plain, reaction.moment, slots, seed ?? 0);
}

/// The reaction to [input]'s concept line, or null where the line stays
/// plain: the same test [conceptLine]'s playful layer applies, so the
/// phone buzzes exactly where the line reacts.
CoachReaction? conceptReaction(
  ConceptInput input, {
  Side? userSide,
  int? seed,
}) {
  final found = detectConcepts(input);
  final pick = chooseConcept(input, found);
  final line = _Line(pick, input, userSide, seed);
  final sentence = _plainSentence(line, companionsFor(input, pick, found));
  return _reaction(line, concrete: sentence.concrete);
}

/// The sentence without a reaction, and whether it names a concrete event
/// (false: the generic line). Companions join while it stays short enough
/// for the coach bar: the paired idea is dropped first, then the check.
({String plain, bool concrete}) _plainSentence(
  _Line line,
  Companions companions,
) {
  final idea = companions.also;
  if (line.kind == ConceptKind.genericQuality && idea != null) {
    final praised = _praiseWithIdea(line, line.about(idea));
    if (praised != null) return praised;
  }
  String? concrete;
  for (final extra in [
    companions,
    (withCheck: companions.withCheck, also: null),
    noCompanions,
  ]) {
    concrete = _special(line) ?? _framed(line, extra);
    if (concrete == null || concrete.length <= maxFlavoredLength) break;
  }
  final text = concrete ?? _generic(line);
  // A sentence may open with the better move, whose case is SAN's ("c3").
  final san = line.betterSan;
  final plain = san != null && text.startsWith(san) ? text : _capitalised(text);
  return (plain: plain, concrete: concrete != null);
}

/// The big moment [line] is about, in whose voice, or null. A generic line
/// names no event; only Brilliant and Great are one alone.
CoachReaction? _reaction(_Line line, {required bool concrete}) {
  final concept = line.concept;
  final input = line.input;
  final moment = momentFor(
    kind: concept.kind,
    frame: concept.frame,
    verdict: input.verdict,
    role: line.stake,
    betterSan: line.betterSan,
    mated: line.after.isCheckmate,
    threwWin: _threwAWin(line),
    gift:
        input.opponentSlipped &&
        concept.object != null &&
        input.previous?.to == concept.object &&
        !concept.evidence.contains('comes out'),
  );
  if (moment == null ||
      (!concrete && moment != Moment.brilliant && moment != Moment.great)) {
    return null;
  }
  final voice = line.userSide == null
      ? CoachVoice.neutral
      : line.isYou(line.mover)
      ? CoachVoice.you
      : CoachVoice.opponent;
  return CoachReaction(moment, voice, role: line.stake, seed: line.seed);
}

class _Line {
  _Line(this.concept, this.input, this.userSide, this.seed)
    : mover = input.before.turn,
      after = input.before.play(input.played);

  final Concept concept;
  final ConceptInput input;
  final Side? userSide;
  final int? seed;
  final Side mover;
  final Position after;

  /// One of [wordings], the same one every time for this move; the first
  /// without a seed.
  String pick(String salt, List<String> wordings) =>
      wordings[seed == null ? 0 : pickIndex(seed!, salt, wordings.length)];

  ConceptKind get kind => concept.kind;
  Frame get frame => concept.frame;

  /// The subject for [side]: "you", "your opponent", or "White"; the
  /// sentence is capitalised later.
  String who(Side side) => switch (userSide) {
    null => sideName(side),
    final user when user == side => 'you',
    _ => 'your opponent',
  };

  bool isYou(Side side) => userSide == side;

  /// The owner of [side]'s pieces: "your", "your opponent's", or "White's".
  String whose(Side side) => switch (userSide) {
    null => "${sideName(side)}'s",
    final user when user == side => 'your',
    _ => "your opponent's",
  };

  /// Whose pawns a structure concept is about, as its evidence names them
  /// ("doubles the white pawns …"). The detector judges structure after
  /// the recapture, so the square alone can hold the other side's pawn.
  Side? get pawnOwner {
    final evidence = concept.evidence;
    if (evidence.contains('white pawn')) return Side.white;
    if (evidence.contains('black pawn')) return Side.black;
    return null;
  }

  String? get betterSan => input.isEngineMove || input.betterUci.isEmpty
      ? null
      : sanOf(input.before, input.betterUci.first);

  /// The boards the concept's object is looked up on, most relevant first.
  /// A capture's object is the piece taken, so it is read BEFORE the move
  /// that takes it.
  List<Board> get boards {
    // A tactic later in the line is read where it is played: the line's
    // third move, after the first two.
    if (concept.evidence.contains('later in the line')) {
      final line = frame == Frame.allows
          ? (start: after, uci: input.replyUci)
          : (start: input.before, uci: input.betterUci);
      final board = _boardAfter(line.start, line.uci.take(2));
      if (board != null) return [board, input.before.board, after.board];
    }
    if (_isCapture) {
      return [
        if (frame == Frame.allows) after.board,
        input.before.board,
        after.board,
      ];
    }
    final reply = input.replyUci.isEmpty
        ? null
        : Move.parse(input.replyUci.first);
    final better = input.betterUci.isEmpty
        ? null
        : Move.parse(input.betterUci.first);
    return [
      if (frame == Frame.better &&
          better != null &&
          input.before.isLegal(better))
        input.before.play(better).board,
      if (frame == Frame.better) input.before.board,
      after.board,
      if (reply != null && after.isLegal(reply)) after.play(reply).board,
      input.before.board,
    ];
  }

  Role? get role {
    final square = concept.object;
    if (square == null) return null;
    for (final board in boards) {
      final piece = board.pieceAt(square);
      if (piece != null) return piece.role;
    }
    return null;
  }

  /// The piece at stake: the one the concept names or, for material the
  /// reply line wins, the most valuable piece it takes.
  Role? get stake {
    final named = role;
    if (named != null ||
        kind != ConceptKind.winMaterial ||
        frame != Frame.allows) {
      return named;
    }
    final won = input.tags.allowed.won;
    for (final r in const [Role.queen, Role.rook, Role.bishop, Role.knight]) {
      if (won.contains(r)) return r;
    }
    return null;
  }

  /// "the knight on c3", or null when the concept names no piece. A piece
  /// taken while it gives check is "the checking rook".
  String? get piece {
    final r = role;
    if (r == null) return null;
    final square = concept.object!;
    final checking =
        _isCapture &&
        frame != Frame.allows &&
        input.before.checkers.has(square);
    return 'the ${checking ? 'checking ' : ''}${r.name} on ${square.name}';
  }

  /// The concept is about the piece the move takes: read it before.
  bool get _isCapture =>
      _captures.contains(kind) ||
      (kind == ConceptKind.exploitPin &&
          concept.evidence.startsWith('the defender'));

  /// The same move and voice, about [other].
  _Line about(Concept other) => _Line(other, input, userSide, seed);

  String? get square => concept.object?.name;

  /// Where the frame's move lands when it takes the concept's object en
  /// passant: the pawn taken stood on [square], the capture happens here.
  /// Null for every other capture.
  String? get enPassantLanding {
    final object = concept.object;
    if (object == null) return null;
    final (start, uci) = switch (frame) {
      Frame.does || Frame.threatens => (input.before, input.played.uci),
      Frame.better => (input.before, input.betterUci.firstOrNull),
      Frame.allows => (after, input.replyUci.firstOrNull),
    };
    final move = uci == null ? null : Move.parse(uci);
    if (move == null || !start.isLegal(move)) return null;
    final landing = landingSquare(start, move);
    return capturedSquare(start, move) == object && landing != object
        ? landing?.name
        : null;
  }

  /// The square a trade or a recapture happens on.
  String? get exchangeSquare => enPassantLanding ?? square;
}

/// The board once [uci] is played from [start], or null when a move is not
/// legal there.
Board? _boardAfter(Position start, Iterable<String> uci) {
  var position = start;
  for (final text in uci) {
    final move = Move.parse(text);
    if (move == null || !position.isLegal(move)) return null;
    position = position.play(move);
  }
  return position.board;
}

const _captures = {
  ConceptKind.capture,
  ConceptKind.captureFree,
  ConceptKind.recapture,
  ConceptKind.winMaterial,
  ConceptKind.removeAttacker,
  ConceptKind.evenTrade,
};

/// An action in three verb forms, so each frame can build its sentence:
/// "take" (you), "takes" (White), "taking" (better was …), then the rest.
typedef _Act = (String base, String third, String ing, String rest);

_Act? _action(_Line l) {
  final piece = l.piece;
  final role = l.role?.name;
  final square = l.square;
  switch (l.kind) {
    case ConceptKind.checkmate:
      return ('force', 'forces', 'forcing', 'mate');
    case ConceptKind.backRankMate:
      return ('mate', 'mates', 'mating', 'on the back rank');
    case ConceptKind.matingNet:
      return ('tighten', 'tightens', 'tightening', 'the mating net');
    case ConceptKind.check:
      return ('give', 'gives', 'giving', 'check');
    case ConceptKind.discoveredCheck:
      return ('give', 'gives', 'giving', 'a discovered check');
    case ConceptKind.captureFree:
      return piece == null
          ? ('win', 'wins', 'winning', 'material')
          : ('win', 'wins', 'winning', '$piece for free');
    case ConceptKind.winMaterial:
      // A piece taken outright is named; a net gain from an exchange only
      // with what it costs: "the rook on b3 for the bishop".
      final evidence = l.concept.evidence;
      if (piece != null && !evidence.contains('comes out')) {
        return ('win', 'wins', 'winning', piece);
      }
      final costs = RegExp(r', for the (\w+)$').firstMatch(evidence);
      if (piece != null && costs != null) {
        final role = costs.group(1)!;
        final cost = role == 'pawn' ? 'a pawn' : 'the $role';
        return ('win', 'wins', 'winning', '$piece for $cost');
      }
      // From a line reading: only what a reader can see captured in the
      // line's first moves, and a piece named only when it is the whole
      // story (one piece won, nothing given back).
      final (reading, start, line, side) = switch (l.frame) {
        Frame.allows => (
          l.input.tags.allowed,
          l.after,
          l.input.replyUci,
          l.mover.opposite,
        ),
        Frame.better => (
          l.input.tags.missed,
          l.input.before,
          l.input.betterUci,
          l.mover,
        ),
        _ => (
          null,
          l.input.before,
          [l.input.played.uci, ...l.input.replyUci],
          l.mover,
        ),
      };
      final seen = lineCaptures(start, line, side);
      if (seen.isEmpty) return null;
      if (reading != null &&
          reading.won.length == 1 &&
          reading.gave.isEmpty &&
          seen.contains(reading.won.single)) {
        return (
          'win',
          'wins',
          'winning',
          describeRoles(reading.won, definite: false),
        );
      }
      return ('win', 'wins', 'winning', 'material');
    case ConceptKind.capture:
      if (piece == null) return null;
      final ep = l.enPassantLanding == null ? '' : ' en passant';
      return ('take', 'takes', 'taking', '$piece$ep');
    case ConceptKind.recapture:
      final where = l.exchangeSquare;
      return where == null
          ? ('take', 'takes', 'taking', 'back')
          : ('take', 'takes', 'taking', 'back on $where');
    case ConceptKind.evenTrade:
      // BETTER prefixes its evidence ("the better move: offers a trade …").
      if (l.concept.evidence.contains('offers a trade') && piece != null) {
        return ('offer', 'offers', 'offering', 'a trade with $piece');
      }
      final where = l.exchangeSquare;
      return where == null
          ? ('offer', 'offers', 'offering', 'an even trade')
          : ('trade', 'trades', 'trading', 'evenly on $where');
    case ConceptKind.tradeWhenAhead:
      return ('trade', 'trades', 'trading', 'pieces while ahead');
    case ConceptKind.sacrifice:
      return piece == null
          ? ('give', 'gives', 'giving', 'up material for the attack')
          : ('sacrifice', 'sacrifices', 'sacrificing', piece);
    case ConceptKind.gambit:
      return ('offer', 'offers', 'offering', 'a pawn for quick development');
    case ConceptKind.fork:
      return piece == null
          ? ('fork', 'forks', 'forking', 'two pieces')
          : ('fork', 'forks', 'forking', piece);
    case ConceptKind.pin:
      return piece == null
          ? ('pin', 'pins', 'pinning', 'a piece')
          : ('pin', 'pins', 'pinning', piece);
    case ConceptKind.exploitPin:
      if (piece != null && l.concept.evidence.startsWith('the defender')) {
        return ('take', 'takes', 'taking', '$piece, whose defender is pinned');
      }
      return role == null
          ? ('exploit', 'exploits', 'exploiting', 'a pin')
          : ('attack', 'attacks', 'attacking', 'the pinned $role on $square');
    case ConceptKind.skewer:
      return piece == null
          ? ('skewer', 'skewers', 'skewering', 'two pieces')
          : ('skewer', 'skewers', 'skewering', piece);
    case ConceptKind.discoveredAttack:
      return piece == null
          ? ('unleash', 'unleashes', 'unleashing', 'a discovered attack')
          : (
              'unleash',
              'unleashes',
              'unleashing',
              'a discovered attack on $piece',
            );
    case ConceptKind.trappedPiece:
      return piece == null ? null : ('trap', 'traps', 'trapping', piece);
    case ConceptKind.attackTrappedPiece:
      return role == null
          ? ('attack', 'attacks', 'attacking', 'a trapped piece')
          : ('attack', 'attacks', 'attacking', 'the trapped $role on $square');
    case ConceptKind.removeDefender:
      if (piece == null) {
        return ('remove', 'removes', 'removing', 'a key defender');
      }
      // Only a capture removes the defender; chasing it only attacks it.
      return l.concept.evidence.contains('takes the defender')
          ? ('remove', 'removes', 'removing', 'the defender of $piece')
          : ('attack', 'attacks', 'attacking', 'the defender of $piece');
    case ConceptKind.pileOn:
      return piece == null ? null : ('pile', 'piles', 'piling', 'up on $piece');
    case ConceptKind.attackPiece:
      return piece == null ? null : ('attack', 'attacks', 'attacking', piece);
    case ConceptKind.pawnKick:
      return piece == null
          ? null
          : ('kick', 'kicks', 'kicking', '$piece with a pawn');
    case ConceptKind.gainTempo:
      return piece == null
          ? ('gain', 'gains', 'gaining', 'time')
          : ('gain', 'gains', 'gaining', 'time by attacking $piece');
    case ConceptKind.escapeAttack:
      return role == null
          ? null
          : ('move', 'moves', 'moving', 'the $role to safety on $square');
    case ConceptKind.escapeCheck:
      return ('get', 'gets', 'getting', 'out of check');
    case ConceptKind.defendHanging:
      if (piece == null) return null;
      return l.concept.evidence.startsWith('blocks')
          ? ('block', 'blocks', 'blocking', 'the attack on $piece')
          : ('defend', 'defends', 'defending', piece);
    case ConceptKind.removeAttacker:
      return piece == null
          ? null
          : ('remove', 'removes', 'removing', 'the attacker, $piece');
    case ConceptKind.defendThreat:
      return piece == null
          ? ('parry', 'parries', 'parrying', 'the mating threat')
          : ('parry', 'parries', 'parrying', 'the threat to $piece');
    case ConceptKind.castle:
      final side = l.frame == Frame.does
          ? castlingSide(l.input.before, l.input.played)
          : null;
      return side == null
          ? ('castle', 'castles', 'castling', '')
          : ('castle', 'castles', 'castling', '${side.name}side');
    case ConceptKind.enableCastling:
      return ('clear', 'clears', 'clearing', 'the way to castle');
    case ConceptKind.luft:
      return ('make', 'makes', 'making', 'room for the king');
    case ConceptKind.kingActivity:
      return ('bring', 'brings', 'bringing', 'the king into play');
    case ConceptKind.opposition:
      return ('take', 'takes', 'taking', 'the opposition');
    case ConceptKind.developPiece:
      if (role == null) return ('develop', 'develops', 'developing', 'a piece');
      // The piece of the frame's own move, or one a pawn move let out.
      final move = l.frame == Frame.better
          ? (l.input.betterUci.isEmpty
                ? null
                : Move.parse(l.input.betterUci.first))
          : l.input.played;
      final moved = switch (move) {
        NormalMove(:final to) => to == l.concept.object,
        _ => false,
      };
      return !moved && role == 'bishop'
          ? ('open', 'opens', 'opening', 'the way for $piece')
          : ('develop', 'develops', 'developing', 'the $role');
    case ConceptKind.centralControl:
      return ('fight', 'fights', 'fighting', 'for the centre');
    case ConceptKind.activeSquare:
      return l.concept.evidence.contains('connected')
          ? ('connect', 'connects', 'connecting', 'the rooks')
          : role == null
          ? ('find', 'finds', 'finding', 'a more active square')
          : ('put', 'puts', 'putting', 'the $role on a more active square');
    case ConceptKind.rookOpenFile:
      if (square == null) {
        return ('put', 'puts', 'putting', 'a rook on an open file');
      }
      // Open of its own pawns; an enemy pawn on it makes it half-open.
      final board = l.boards.first;
      final rook = board.pieceAt(l.concept.object!);
      final enemyPawn =
          rook != null &&
          board.pawns
              .intersect(board.bySide(rook.color.opposite))
              .intersect(SquareSet.fromFile(l.concept.object!.file))
              .isNotEmpty;
      final open = enemyPawn ? 'half-open' : 'open';
      return (
        'put',
        'puts',
        'putting',
        'a rook on the $open ${square[0]}-file',
      );
    case ConceptKind.rookSeventh:
      return ('put', 'puts', 'putting', 'a rook on the seventh rank');
    case ConceptKind.outpost:
      return role == null
          ? null
          : ('plant', 'plants', 'planting', 'the $role on the $square outpost');
    // Whose pawns, said outright: "You double the pawns" reads as your own.
    case ConceptKind.doubledPawns:
      final owner = l.pawnOwner;
      final pawns = owner == null ? 'the pawns' : '${l.whose(owner)} pawns';
      return square == null
          ? ('double', 'doubles', 'doubling', 'pawns')
          : (
              'double',
              'doubles',
              'doubling',
              '$pawns on the ${square[0]}-file',
            );
    case ConceptKind.isolatedPawn:
      return square == null
          ? ('isolate', 'isolates', 'isolating', 'a pawn')
          : ('isolate', 'isolates', 'isolating', 'the pawn on $square');
    case ConceptKind.backwardPawn:
      return square == null
          ? null
          : ('leave', 'leaves', 'leaving', 'a backward pawn on $square');
    case ConceptKind.passedPawn:
      if (square != null && l.concept.evidence.contains('pushes the passed')) {
        return ('push', 'pushes', 'pushing', 'the passed pawn to $square');
      }
      return square == null
          ? ('create', 'creates', 'creating', 'a passed pawn')
          : ('create', 'creates', 'creating', 'a passed pawn on $square');
    case ConceptKind.stopPassedPawn:
      if (square == null) {
        return ('stop', 'stops', 'stopping', 'the passed pawn');
      }
      // Taking it is how this move stops it.
      final takes =
          l.frame == Frame.does &&
          capturedSquare(l.input.before, l.input.played) == l.concept.object;
      return takes
          ? ('take', 'takes', 'taking', 'the passed pawn on $square')
          : ('stop', 'stops', 'stopping', 'the passed pawn on $square');
    case ConceptKind.pawnChainAttack:
      return ('strike', 'strikes', 'striking', 'at the pawn chain');
    case ConceptKind.pawnChainCreate:
      return ('build', 'builds', 'building', 'a pawn chain');
    case ConceptKind.promotion:
      return ('promote', 'promotes', 'promoting', 'a pawn');
    case ConceptKind.mateThreat:
      return ('threaten', 'threatens', 'threatening', 'mate');
    case ConceptKind.perpetualCheck:
      return l.concept.evidence.startsWith('keeps up')
          ? ('keep', 'keeps', 'keeping', 'up the perpetual check')
          : ('force', 'forces', 'forcing', 'a draw by perpetual check');
    // On the board itself (DOES) the line is _special's.
    case ConceptKind.stalemate:
      return ('force', 'forces', 'forcing', 'stalemate');
    case ConceptKind.doubleRooks:
      final file = square == null ? 'file' : '${square[0]}-file';
      return l.concept.evidence.startsWith('makes room')
          ? ('make', 'makes', 'making', 'room to double the rooks on the $file')
          : ('double', 'doubles', 'doubling', 'the rooks on the $file');
    // On purpose (DOES / BETTER); the ALLOWS line is _special's.
    case ConceptKind.ignoredThreat:
      return piece == null
          ? null
          : ('ignore', 'ignores', 'ignoring', 'the threat to $piece');
    // Lines of their own (_special), or never an action.
    case ConceptKind.hangingPiece ||
        ConceptKind.kingExposed ||
        ConceptKind.passivePiece ||
        ConceptKind.openingName ||
        ConceptKind.onlyMove ||
        ConceptKind.missedWin ||
        ConceptKind.forcedMove ||
        ConceptKind.repetition ||
        ConceptKind.insufficientMaterial ||
        ConceptKind.genericQuality:
      return null;
  }
}

/// Concepts whose line is not "[who] [does something]".
String? _special(_Line l) {
  final piece = l.piece;
  switch (l.kind) {
    case ConceptKind.checkmate
        when l.frame == Frame.does && l.after.isCheckmate:
      return 'Checkmate.';
    // Found by the rules: the mating move can be named.
    case ConceptKind.checkmate
        when l.frame == Frame.allows &&
            l.concept.evidence.startsWith('mate in one: '):
      final san = l.concept.evidence.substring('mate in one: '.length);
      final who = l.who(l.mover.opposite);
      return 'This lets $who mate at once with $san.';
    case ConceptKind.stalemate when l.frame == Frame.does:
      return _threwAWin(l)
          ? 'Stalemate: a won game ends in a draw.'
          : 'Stalemate: the game is drawn.';
    case ConceptKind.repetition:
      final input = l.input;
      final repeats =
          'That repeats the position a '
          '${repetitionOrdinal(input.repetitions)} time';
      if (!input.repetitionDraws) return '$repeats: a draw could be claimed.';
      if (_threwAWin(l)) return '$repeats, and a won game is drawn.';
      return input.repeatedByChecks
          ? '$repeats: a draw by perpetual check.'
          : '$repeats: a draw by repetition.';
    case ConceptKind.insufficientMaterial:
      const left = 'That leaves too little material to mate';
      return _threwAWin(l)
          ? '$left, and a won game is drawn.'
          : '$left: the game is drawn.';
    case ConceptKind.openingName:
      return l.input.openingName;
    case ConceptKind.onlyMove:
      return 'The only good move here.';
    case ConceptKind.forcedMove:
      return 'The only legal move.';
    case ConceptKind.missedWin:
      // What a Miss means, and nothing more: the better move would have
      // punished the opponent's mistake. Not "kept the win": a Miss may be
      // in a level position.
      final better = l.betterSan;
      return better == null
          ? "This lets the opponent's mistake go."
          : "This lets the opponent's mistake go; $better would have punished it.";
    case ConceptKind.hangingPiece:
      if (piece == null) return 'This leaves a piece hanging.';
      // The piece that captured, taken back for more than it took.
      final taken = capturedSquare(l.input.before, l.input.played);
      final role = l.role;
      if (taken != null &&
          role != null &&
          l.concept.object == landingSquare(l.input.before, l.input.played)) {
        final got = l.input.before.board.roleAt(taken)!;
        final what = got == Role.pawn ? 'a pawn' : 'the ${got.name}';
        return 'This gives the ${role.name} for $what.';
      }
      return 'This leaves $piece hanging.';
    case ConceptKind.ignoredThreat
        when l.frame == Frame.does && piece != null && _ifTaken(l).isNotEmpty:
      final you = l.isYou(l.mover);
      final line =
          '${l.who(l.mover)} ${you ? 'ignore' : 'ignores'} the threat to '
          '$piece${_ifTaken(l)}.';
      return line.length <= maxFlavoredLength ? line : null;
    // The mover's own pawn, left behind by the move: nothing the opponent
    // does ("lets White leave a backward pawn").
    case ConceptKind.backwardPawn
        when l.frame == Frame.allows && l.square != null:
      return 'This leaves a backward pawn on ${l.square}.';
    case ConceptKind.ignoredThreat when l.frame == Frame.allows:
      return piece == null
          ? 'This leaves the threat unanswered.'
          : 'This leaves the threat to $piece unanswered.';
    case ConceptKind.sacrifice
        when l.frame == Frame.does &&
            piece != null &&
            l.input.verdict != Classification.brilliant:
      final you = l.isYou(l.mover);
      final offer = '${l.who(l.mover)} ${you ? 'offer' : 'offers'} $piece';
      final idea = _ifTaken(l);
      final line = '$offer$idea.';
      return idea.isEmpty || line.length <= maxFlavoredLength
          ? line
          : '$offer.';
    case ConceptKind.sacrifice when l.frame == Frame.does && piece != null:
      final you = l.isYou(l.mover);
      return '${l.who(l.mover)} ${you ? 'sacrifice' : 'sacrifices'} '
          '$piece${_payoff(l, you)}.';
    case ConceptKind.kingExposed:
      return "This weakens the king's cover.";
    case ConceptKind.passivePiece:
      final role = l.role;
      return role == null
          ? 'This puts a piece on a passive square.'
          : 'This puts the ${role.name} on a passive square.';
    default:
      return null;
  }
}

/// Whether [l] is a draw the move makes on the board, from a position the
/// mover was winning.
bool _threwAWin(_Line l) {
  final input = l.input;
  final drawn = switch (l.kind) {
    ConceptKind.stalemate ||
    ConceptKind.insufficientMaterial => l.frame == Frame.does,
    ConceptKind.repetition => input.repetitionDraws,
    _ => false,
  };
  final after = input.winPctAfter;
  return drawn &&
      after != null &&
      after + (input.winPctDrop ?? 0) >= winningWinPct;
}

/// What a sacrifice buys, read from the engine's line after it: mate, or
/// material won back with interest. A line that wins nothing countable
/// still holds (the verdict says so), so the position is what pays.
///
/// The line's count starts from the board before the move, so "comes out
/// up" is said only from a level board. Behind already, the line wins
/// material back; ahead, it wins more.
String _payoff(_Line l, bool you) {
  final mate = l.input.mateAfter;
  if (mate != null && mate > 0) return ' to force mate';
  // `allowed` reads that line from the opponent's side, so what it gave is
  // what the sacrifice won.
  final line = l.input.tags.allowed;
  if (line.gain < 0) {
    final won = describeRoles(line.gave, definite: false);
    final gave = describeRoles(line.won, definite: false);
    final win = you ? 'win' : 'wins';
    final balance = materialFor(l.input.before.board, l.mover);
    if (balance < 0) return ' and $win material back';
    if (balance > 0) {
      return line.won.isEmpty ? ' and $win $won' : ' and $win $won for $gave';
    }
    final come = you ? 'come' : 'comes';
    return line.won.isEmpty
        ? ' and $come out $won up'
        : ' and $come out ahead: $won for $gave';
  }
  return ', and the position makes up for it';
}

/// What taking an offered (or left) piece runs into, when the game's next
/// move took it: "; taking it lets in Re7+", read from the engine's line
/// after the capture. Empty when it was declined, the line is unknown, or
/// its next move is quiet or only takes back on that square.
String _ifTaken(_Line l) {
  final acceptance = l.input.acceptance;
  final offered = l.concept.object;
  if (acceptance == null || offered == null) return '';
  final take = Move.parse(acceptance.uci);
  if (take is! NormalMove || take.to != offered || !l.after.isLegal(take)) {
    return '';
  }
  if (acceptance.mates) return '; taking it walks into mate';
  final reply = Move.parse(acceptance.replyUci.firstOrNull ?? '');
  final taken = l.after.play(take);
  // Taking back on the same square is a trade, not what the offer is for,
  // and a quiet reply is no punishment worth naming.
  if (reply is! NormalMove || reply.to == offered) return '';
  if (!taken.isLegal(reply)) return '';
  if (capturedSquare(taken, reply) == null && !taken.play(reply).isCheck) {
    return '';
  }
  final san = sanOf(taken, reply.uci);
  return san == null ? '' : '; taking it lets in $san';
}

/// "[who] [act]." in the concept's frame, with [extra]: "with check" on the
/// clause that names the moved piece, and the paired idea after "and".
String? _framed(_Line l, Companions extra) {
  var act = _action(l);
  if (act == null) return null;
  // A tactic found further down the engine's line, not on this move.
  if (l.concept.evidence.contains('later in the line')) {
    final (base, third, ing, rest) = act;
    act = (base, third, ing, '$rest later in the line');
  }
  final also = extra.also;
  final second = also == null ? null : _action(l.about(also));
  // Development leads: it names the piece the other idea is about.
  final developsFirst =
      second != null && also!.kind == ConceptKind.developPiece;
  final lead = developsFirst ? second : act;
  final follow = developsFirst ? act : second;
  String clause(_Act a, String verb) => a.$4.isEmpty ? verb : '$verb ${a.$4}';

  // [form] picks the verb: base, third person or -ing.
  String phrase(String Function(_Act) form) {
    final check = extra.withCheck ? ' with check' : '';
    final and = follow == null ? '' : ' and ${clause(follow, form(follow))}';
    return '${clause(lead, form(lead))}$check$and';
  }

  String tail(String Function(_Act) form) => '${phrase(form)}.';
  String base(_Act a) => a.$1;
  final you = l.isYou(l.mover);
  switch (l.frame) {
    case Frame.does:
      return '${l.who(l.mover)} ${tail(you ? base : (a) => a.$2)}';
    case Frame.threatens:
      final threaten = you ? 'threaten' : 'threatens';
      return l.kind == ConceptKind.mateThreat
          ? '${l.who(l.mover)} $threaten mate.'
          : '${l.who(l.mover)} $threaten to ${tail(base)}';
    case Frame.allows:
      final who = l.who(l.mover.opposite);
      return l.pick('allows', [
        'This lets $who ${tail(base)}',
        'Now $who can ${tail(base)}',
        'That allows $who to ${tail(base)}',
      ]);
    case Frame.better:
      final better = l.betterSan;
      if (better == null) return null;
      String ing(_Act a) => a.$3;
      return l.pick('better', [
        'Better was $better, ${tail(ing)}',
        '$better was stronger, ${tail(ing)}',
        '$better instead, ${tail(ing)}',
      ]);
  }
}

/// Praise with the move's idea after it: "Spot on, attacking the rook on
/// e8." Too long for the bar, the idea alone ("White attacks the rook on
/// e8."); null when the idea has no words.
({String plain, bool concrete})? _praiseWithIdea(_Line line, _Line idea) {
  final act = _action(idea);
  if (act == null) return null;
  final praise = line.pick(
    'praise ${line.input.verdict?.name}',
    switch (line.input.verdict) {
      Classification.great => ['The only good move here'],
      Classification.best => ['Spot on', 'The best move here', 'Strong move'],
      Classification.excellent => ['Strong move', 'An excellent move'],
      _ => ['A solid move', 'Solid'],
    },
  );
  final (_, _, ing, rest) = act;
  final text = '$praise, ${rest.isEmpty ? ing : '$ing $rest'}.';
  if (text.length <= maxFlavoredLength) return (plain: text, concrete: false);
  final plain = _framed(idea, noCompanions);
  return plain == null ? null : (plain: _capitalised(plain), concrete: true);
}

/// No concrete concept: the verdict alone, as the numbers read.
String _generic(_Line l) {
  final drop = l.input.winPctDrop ?? 0;
  final better = l.betterSan;
  switch (l.frame) {
    case Frame.better:
      return better == null
          ? 'There was a stronger move.'
          : l.pick('generic better', [
              'Stronger was $better.',
              '$better was the move.',
            ]);
    case Frame.allows:
      return drop >= 2 && better != null
          ? l.pick('generic better', [
              'Stronger was $better.',
              '$better was the move.',
            ])
          : l.pick('generic chance', [
              'This hands the opponent a chance.',
              'This gives the opponent a chance.',
            ]);
    case Frame.does || Frame.threatens:
      return l.pick(
        'generic ${l.input.verdict?.name}',
        switch (l.input.verdict) {
          Classification.brilliant => ['A brilliant sacrifice.'],
          Classification.great => ['The only good move here.'],
          Classification.best => [
            'The best move here.',
            'Spot on.',
            'The engine agrees.',
          ],
          Classification.excellent => ['An excellent move.', 'Strong move.'],
          Classification.good => ['A solid move.', 'Solid.', 'Reasonable.'],
          Classification.inaccuracy =>
            better == null
                ? ['Playable, but not the most accurate.']
                : [
                    'Playable, but $better was more accurate.',
                    '$better was more accurate.',
                  ],
          _ => ['A reasonable move.'],
        },
      );
  }
}

String _capitalised(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

/// The ONE line about a move: "Starting position." at the root, the opening
/// in book, [conceptLine] once both evals are in, else [moveSummaryLine].
/// Seeded by the move, so it always reads the same; [playful] adds reactions.
String coachLine(
  GameNode node, {
  Side? userSide,
  GamePhase phase = GamePhase.middlegame,
  bool playful = true,
}) {
  if (node.isRoot) return 'Starting position.';
  final opening = node.openingName;
  if (opening != null) return opening;
  final input = conceptInputFor(node, phase: phase);
  if (input == null) return moveSummaryLine(node);
  return conceptLine(
    input,
    userSide: userSide,
    seed: _moveSeed(input),
    playful: playful,
  );
}

/// What the coach reacts to on [node] (see [conceptReaction]), or null: at
/// the root, in book, and before the evals are in, as [coachLine] has no
/// concept line there.
CoachReaction? coachReaction(
  GameNode node, {
  Side? userSide,
  GamePhase phase = GamePhase.middlegame,
}) {
  if (node.openingName != null) return null;
  final input = conceptInputFor(node, phase: phase);
  if (input == null) return null;
  return conceptReaction(input, userSide: userSide, seed: _moveSeed(input));
}

/// Picks a move's wording and reaction, so a move always reads the same.
int _moveSeed(ConceptInput input) =>
    fnv1a63('${input.before.fen} ${input.played.uci}');

/// What happened on this move, from the engine numbers alone: [coachLine]'s
/// fallback when there is no concept input, so every verdict needs a line.
String moveSummaryLine(GameNode node) {
  if (node.isRoot) return 'Starting position.';
  if (node.openingName != null) return node.openingName!;

  final before = node.parent?.eval;
  final after = node.eval;
  if (before == null || after == null) return 'Not analyzed yet.';

  // The numbers cannot reach these three, so they are answered first.
  final classification = node.classification;
  switch (classification) {
    case Classification.brilliant:
      return 'Gave up material — and it works.';
    case Classification.great:
      return 'The only good move here.';
    case Classification.miss:
      final better = node.betterMoveSan;
      return better == null
          ? "Let the opponent's mistake go."
          : "Let the opponent's mistake go — $better would have punished it.";
    default:
      break;
  }

  if (classification != null &&
      classification.index >= Classification.inaccuracy.index) {
    final tagged = tacticSummaryLine(node.tags);
    if (tagged != null) return tagged;
  }

  final drop = winPctDrop(
    before: before,
    after: after,
    mover: node.sideThatMoved,
  );
  if (drop >= 2) return 'Gave up ${drop.round()}% of the winning chances.';
  if (node.isEngineMove) return 'The engine\'s first choice.';
  final better = node.betterMoveSan;
  return better == null
      ? 'Held the position.'
      : 'Held the position, though $better was sharper.';
}
