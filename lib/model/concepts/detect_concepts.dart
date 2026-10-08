/// Every concept a coach line could name for one move, each in its frame.
/// Pure: the engine's lines and the tagger's readings come in, candidates
/// come out, unranked.
///
/// - DOES / THREATENS: `moveConcepts` on the played move.
/// - BETTER: `moveConcepts` on the engine's move, plus what `tags.missed`
///   read in its line. Only when the played move was not the engine's.
/// - ALLOWS: `moveConcepts` on the opponent's best reply, as seen from the
///   mover, plus what `tags.allowed` read in the reply line and what the
///   played move left en prise.
/// - The rules add what needs no engine: a stalemate, the third repetition,
///   too little material to mate (DOES), and a mate in one the move lets in
///   (ALLOWS). A stalemate an engine line ends in is ALLOWS / BETTER.
/// - The verdict and the book add the concepts only they know: only_move
///   (Great), missed_win (Miss), sacrifice (Brilliant), opening_name.
library;

import 'package:dartchess/dartchess.dart';

import '../classification.dart';
import '../game_phase.dart';
import '../material_balance.dart' show valueOf;
import '../move_facts.dart' show capturedSquare, landingSquare;
import '../move_tags.dart';
import '../pv_line.dart' show sanOf;
import 'board_concepts.dart';
import 'concept.dart';

/// The game's next move, when it was played and searched: what taking an
/// offered piece runs into. [replyUci] is the engine's line after it, and
/// [mates] whether that line mates the side that took.
typedef Acceptance = ({String uci, List<String> replyUci, bool mates});

/// What the detectors need to know about one move. The app builds it from a
/// `GameNode` (`node_concepts.dart`).
class ConceptInput {
  const ConceptInput({
    required this.before,
    required this.played,
    this.previous,
    this.earlierCapture,
    this.opponentSlipped = false,
    this.opponentBrilliant = false,
    this.acceptance,
    this.betterUci = const [],
    this.replyUci = const [],
    this.tags = MoveTags.none,
    this.verdict,
    this.openingName,
    this.phase = GamePhase.middlegame,
    this.mateBefore,
    this.mateAfter,
    this.winPctDrop,
    this.winPctAfter,
    this.drawBefore = false,
    this.drawAfter = false,
    this.perpetualInHand = false,
    this.repetitions = 1,
    this.repetitionDraws = false,
    this.repeatedByChecks = false,
  });

  final Position before;
  final Move played;

  /// The opponent's move that led to [before].
  final PreviousMove? previous;

  /// The opponent's capture the move before [previous], when its piece
  /// still stands where it took.
  final EarlierCapture? earlierCapture;

  /// Whether that move was a mistake or worse.
  final bool opponentSlipped;

  /// Whether that move was Brilliant: what it left to be taken is a sound
  /// sacrifice, never a gift.
  final bool opponentBrilliant;

  /// The move that followed this one in the game, when it is known.
  final Acceptance? acceptance;

  /// The engine's line from [before]; its first move is the better move.
  final List<String> betterUci;

  /// The engine's line after the played move; its first move is the reply.
  final List<String> replyUci;

  /// `tagMove`'s readings of the two lines.
  final MoveTags tags;
  final Classification? verdict;
  final String? openingName;
  final GamePhase phase;

  /// Moves to mate before the played move, from the MOVER's side, as
  /// [mateAfter].
  final int? mateBefore;

  /// Moves to mate after the played move, from the MOVER's side: positive
  /// when the mover mates, negative when the mover is mated, null when no
  /// mate is in sight.
  final int? mateAfter;

  /// Winning chances the move gave up, in points (`winPctDrop`); null when
  /// unknown.
  final double? winPctDrop;

  /// The mover's winning chances after the move (`winPctFor`); null when
  /// unknown.
  final double? winPctAfter;

  /// The engine scores the position before / after the move a draw
  /// (`isDrawScore`): what a perpetual check reads as.
  final bool drawBefore;
  final bool drawAfter;

  /// A perpetual check was already running: the draw stood before the
  /// opponent's last move, and that move answered a check.
  final bool perpetualInHand;

  /// How many times the position after the move has stood in the game, this
  /// time included: from 3 a draw can be claimed.
  final int repetitions;

  /// Whether that repetition ends the game (`drawnByRepetition`).
  final bool repetitionDraws;

  /// Whether the mover checked on every move since the position last stood.
  final bool repeatedByChecks;

  bool get isEngineMove => betterUci.isEmpty || betterUci.first == played.uci;
}

/// The candidates for [input], each concept in each frame once, in
/// detection order (never a ranking).
List<Concept> detectConcepts(ConceptInput input) {
  final out = <Concept>{};
  void add(ConceptKind kind, Frame frame, Square? object, String evidence) {
    if (kind.frames.contains(frame)) {
      out.add(Concept(kind, frame, object: object, evidence: evidence));
    }
  }

  final before = input.before;
  final mover = before.turn;
  if (!before.isLegal(input.played)) return const [];
  final after = before.play(input.played);
  final reply = _parse(input.replyUci, 0);

  // Rules facts first, so their evidence is the one kept.
  _draws(input, after, add);
  final mateInOne = mateInOneUci(after, preferred: reply?.uci);
  if (mateInOne != null) {
    add(
      ConceptKind.checkmate,
      Frame.allows,
      null,
      'mate in one: ${sanOf(after, mateInOne)}',
    );
  }

  // What the move does, and what it sets up.
  for (final f in moveConcepts(
    before,
    input.played,
    followUp: reply,
    previous: input.previous,
    earlier: input.earlierCapture,
    phase: input.phase,
  )) {
    switch (f.kind) {
      // Not safe where the engine's reply takes it at once.
      case ConceptKind.escapeAttack when _takes(reply, f.object):
        continue;
      // No structure claim about a pawn the line takes straight after.
      case ConceptKind.isolatedPawn ||
              ConceptKind.backwardPawn ||
              ConceptKind.doubledPawns
          when _takes(_parse(input.replyUci, 1), f.object):
        continue;
      // The engine's own move leaving a piece en prise ignores the threat
      // on purpose; anyone else's is a weakness (below).
      case ConceptKind.ignoredThreat
          when input.betterUci.isNotEmpty &&
              input.isEngineMove &&
              _playsOn(before, input.played, f):
        add(f.kind, Frame.does, f.object, f.evidence);
      // What the move leaves behind is read from the opponent's side.
      case _ when _ownWeakness(f, _settled(after, reply), mover):
        add(f.kind, Frame.allows, f.object, f.evidence);
      case ConceptKind.mateThreat:
        add(f.kind, Frame.threatens, f.object, f.evidence);
      case ConceptKind.checkmate when !after.isCheckmate:
        add(f.kind, Frame.allows, f.object, f.evidence); // an unmet mate
      // A pawn one step from queening THREATENS to promote; only a
      // promotion DOES it.
      case ConceptKind.promotion:
        final promotes =
            input.played is NormalMove &&
            (input.played as NormalMove).promotion != null;
        add(
          f.kind,
          promotes ? Frame.does : Frame.threatens,
          f.object,
          f.evidence,
        );
      default:
        add(f.kind, Frame.does, f.object, f.evidence);
        add(f.kind, Frame.threatens, f.object, f.evidence);
    }
  }
  _makesRoomToDouble(input, after, reply, add);
  final played = [input.played.uci, ...input.replyUci];
  final line = readLine(start: before, pvUci: played);
  _fromReading(
    line,
    Frame.does,
    add,
    target: _trappedAt(before, played, mover.opposite, line),
  );
  final mate = input.mateAfter;
  final mateAgainst = input.mateBefore;
  if (mateAgainst != null && mateAgainst < 0 && (mate == null || mate > 0)) {
    const stops = 'the opponent had a forced mate and has none now';
    add(ConceptKind.defendThreat, Frame.does, null, stops);
    add(ConceptKind.checkmate, Frame.does, null, stops);
  }
  if (mate != null && mate > 0 && !after.isCheckmate) {
    final onBoard = 'mate in $mate is on the board';
    add(ConceptKind.matingNet, Frame.does, null, onBoard);
    add(ConceptKind.checkmate, Frame.does, null, onBoard);
  }

  // What the engine's move would have done.
  if (!input.isEngineMove) {
    final better = _parse(input.betterUci, 0)!;
    final previous = input.previous;
    for (final f in moveConcepts(
      before,
      better,
      followUp: _parse(input.betterUci, 1),
      previous: previous,
      earlier: input.earlierCapture,
      phase: input.phase,
    )) {
      if (f.kind == ConceptKind.ignoredThreat && !_playsOn(before, better, f)) {
        continue;
      }
      if (f.kind == ConceptKind.escapeAttack &&
          _takes(_parse(input.betterUci, 1), f.object)) {
        continue;
      }
      // A piece with no square that the better move merely attacks was
      // trapped already; only the line's reading says the move traps it.
      if (f.kind == ConceptKind.trappedPiece) continue;
      add(f.kind, Frame.better, f.object, 'the better move: ${f.evidence}');
    }
    _fromReading(
      input.tags.missed,
      Frame.better,
      add,
      target: _trappedAt(
        before,
        input.betterUci,
        mover.opposite,
        input.tags.missed,
      ),
    );
    _lineEvents(before, input.betterUci, mover, Frame.better, add);
    _laterTactics(before, input.betterUci, Frame.better, add);
    final mateBefore = input.mateBefore;
    if (mateBefore != null && mateBefore > 0 && (mate == null || mate <= 0)) {
      add(
        ConceptKind.checkmate,
        Frame.better,
        null,
        'mate in $mateBefore was on the board',
      );
    }
  }

  // What the move lets the opponent do.
  if (reply != null && after.isLegal(reply)) {
    // Taking back what the move just took is a trade, not a win, unless
    // the piece taken back is worth more than the one it took.
    final took = capturedSquare(before, input.played);
    final landing = landingSquare(before, input.played)!;
    final evenBack =
        took != null &&
        _takes(reply, landing) &&
        valueOf(after.board.roleAt(landing)!) <=
            valueOf(before.board.roleAt(took)!);
    for (final f in moveConcepts(
      after,
      reply,
      followUp: _parse(input.replyUci, 1),
      previous: (to: landing, captured: took != null),
      phase: input.phase,
    )) {
      // The reply's own weaknesses are not what the move allowed.
      final replied = _settled(after.play(reply), _parse(input.replyUci, 1));
      final promotes = reply is NormalMove && reply.promotion != null;
      final kind = _ownWeakness(f, replied, mover.opposite)
          ? null
          : switch (f.kind) {
              ConceptKind.captureFree ||
              ConceptKind.winMaterial when evenBack => null,
              ConceptKind.captureFree => ConceptKind.winMaterial,
              ConceptKind.escapeCheck || ConceptKind.check => null,
              // A reply one step from queening has not promoted: the line
              // (_lineEvents) says so if it does.
              ConceptKind.promotion when !promotes => null,
              _ => f.kind,
            };
      if (kind != null) {
        add(kind, Frame.allows, f.object, 'the reply: ${f.evidence}');
      }
    }
  }
  _laterTactics(after, input.replyUci, Frame.allows, add);
  _fromReading(
    input.tags.allowed,
    Frame.allows,
    add,
    target: _trappedAt(after, input.replyUci, mover, input.tags.allowed),
  );
  if (input.tags.allowed.hung != null) {
    add(
      ConceptKind.hangingPiece,
      Frame.allows,
      null,
      'the reply line takes it',
    );
  }
  _lineEvents(after, input.replyUci, mover.opposite, Frame.allows, add);
  if (mate != null && mate < 0) {
    add(ConceptKind.checkmate, Frame.allows, null, 'mated in ${-mate}');
  }

  _perpetual(input, after, add);
  _stalemateLines(input, after, add);

  // What only the verdict or the book know.
  switch (input.verdict) {
    case Classification.great:
      add(ConceptKind.onlyMove, Frame.does, null, 'Great: the only move');
    case Classification.miss:
      add(ConceptKind.missedWin, Frame.better, null, 'Miss: the win was there');
    case Classification.brilliant:
      add(ConceptKind.sacrifice, Frame.does, null, 'Brilliant: a sacrifice');
    default:
  }
  if (input.openingName != null) {
    add(ConceptKind.openingName, Frame.does, null, input.openingName!);
  }
  for (final frame in Frame.values) {
    if (frame == Frame.better && input.isEngineMove) continue;
    add(ConceptKind.genericQuality, frame, null, 'the verdict alone');
  }
  return out.toList();
}

/// A rook move that clears the square the mover's NEXT rook move in the
/// engine line doubles on (Re7, then Rae8): it prepares the doubling.
void _makesRoomToDouble(
  ConceptInput input,
  Position after,
  Move? reply,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  final played = input.played;
  final next = _parse(input.replyUci, 1);
  if (played is! NormalMove || next is! NormalMove || reply == null) return;
  if (input.before.board.roleAt(played.from) != Role.rook) return;
  if (!after.isLegal(reply)) return;
  final position = after.play(reply);
  // Another rook takes the square; the same one coming back is no doubling.
  if (next.to != played.from || next.from == played.to) return;
  if (doubledRook(position, next) == null) return;
  add(
    ConceptKind.doubleRooks,
    Frame.does,
    next.to,
    'makes room for the rook on ${next.from.name} to double on '
    '${next.to.name}',
  );
}

/// A perpetual check: the engine scores the position a draw and its line is
/// one side checking on every move. DOES when the played move is such a
/// check; ALLOWS when the reply line is the opponent's, and the move gave up
/// a real edge for it; BETTER when the engine's own line was the mover's.
void _perpetual(
  ConceptInput input,
  Position after,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  final mover = input.before.turn;
  final drop = input.winPctDrop ?? 0;
  if (input.drawAfter &&
      after.isCheck &&
      isPerpetualLine(after, input.replyUci, mover)) {
    add(
      ConceptKind.perpetualCheck,
      Frame.does,
      null,
      input.perpetualInHand
          ? 'keeps up the perpetual check'
          : 'starts a perpetual check',
    );
  }
  if (input.drawAfter &&
      drop >= _perpetualGiveUp &&
      isPerpetualLine(after, input.replyUci, mover.opposite)) {
    add(
      ConceptKind.perpetualCheck,
      Frame.allows,
      null,
      'the reply line checks for ever',
    );
  }
  if (!input.isEngineMove &&
      input.drawBefore &&
      drop >= _perpetualGiveUp &&
      isPerpetualLine(input.before, input.betterUci, mover, minChecks: 3)) {
    add(
      ConceptKind.perpetualCheck,
      Frame.better,
      null,
      'the better move: a perpetual check',
    );
  }
}

/// Winning chances a move must give up (or miss) for a perpetual to be what
/// it allowed: the Inaccuracy threshold.
const double _perpetualGiveUp = 5;

/// The draws the rules call on the board the move leaves: stalemate, the
/// third repetition, and too little material left to mate (when there was
/// enough before).
void _draws(
  ConceptInput input,
  Position after,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  if (after.isStalemate) {
    add(ConceptKind.stalemate, Frame.does, null, 'no legal move, no check');
  }
  if (input.repetitions >= 3) {
    add(
      ConceptKind.repetition,
      Frame.does,
      null,
      'the position stands a ${repetitionOrdinal(input.repetitions)} time',
    );
  }
  if (after.isInsufficientMaterial && !input.before.isInsufficientMaterial) {
    add(
      ConceptKind.insufficientMaterial,
      Frame.does,
      null,
      'neither side can mate',
    );
  }
}

/// "third" for 3: how a line counts repetitions.
String repetitionOrdinal(int n) => switch (n) {
  3 => 'third',
  4 => 'fourth',
  5 => 'fifth',
  _ => '${n}th',
};

/// A stalemate at the end of an engine line, forced by the side that is
/// stalemated: ALLOWS when the reply line gets the opponent there and the
/// move gave up a real edge for it; BETTER when the engine's line saved the
/// mover that way.
void _stalemateLines(
  ConceptInput input,
  Position after,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  final mover = input.before.turn;
  final drop = input.winPctDrop ?? 0;
  if (drop < _perpetualGiveUp) return;
  if (input.drawAfter &&
      lineStalemates(after, input.replyUci) == mover.opposite) {
    add(
      ConceptKind.stalemate,
      Frame.allows,
      null,
      'the reply line ends in stalemate',
    );
  }
  if (!input.isEngineMove &&
      input.drawBefore &&
      lineStalemates(input.before, input.betterUci) == mover) {
    add(
      ConceptKind.stalemate,
      Frame.better,
      null,
      'the better line ends in stalemate',
    );
  }
}

/// The side stalemated at the end of [pvUci] played from [start], or null
/// when the line ends any other way.
Side? lineStalemates(Position start, List<String> pvUci) {
  var position = start;
  for (final uci in pvUci) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) return null;
    position = position.play(move);
    if (position.isStalemate) return position.turn;
  }
  return null;
}

/// A move that mates at once in [position], in UCI: [preferred] (the
/// engine's reply) when it mates, else the first found. Null when there is
/// none. The rules alone, no engine.
String? mateInOneUci(Position position, {String? preferred}) {
  if (position.isGameOver) return null;
  final moves = legalMoveUcis(position);
  if (preferred != null && moves.contains(preferred)) {
    moves
      ..remove(preferred)
      ..insert(0, preferred);
  }
  for (final uci in moves) {
    if (position.play(Move.parse(uci)!).isCheckmate) return uci;
  }
  return null;
}

/// Whether [f], a piece [move] leaves en prise, is one a reviewer would say
/// the move ignores: a QUIET move (a check or a capture forces play rather
/// than ignoring anything), not while escaping check, and not a pawn or the
/// piece that moved (that one is offered, or simply misplaced).
bool _playsOn(Position before, Move move, Found f) {
  final object = f.object;
  if (object == null || before.isCheck) return false;
  if (capturedSquare(before, move) != null || before.play(move).isCheck) {
    return false;
  }
  if (object == landingSquare(before, move)) return false;
  final piece = before.board.pieceAt(object);
  return piece != null && piece.role != Role.pawn;
}

/// Whether [f] is a weakness of [side] itself: something it left en prise
/// or exposed, or damage to its own pawns. Read as what the move ALLOWS.
bool _ownWeakness(Found f, Board board, Side side) => switch (f.kind) {
  ConceptKind.hangingPiece ||
  ConceptKind.ignoredThreat ||
  ConceptKind.kingExposed ||
  ConceptKind.passivePiece => true,
  ConceptKind.doubledPawns ||
  ConceptKind.isolatedPawn ||
  ConceptKind.backwardPawn => switch (f.object) {
    final Square s => board.sideAt(s) == side,
    null => false,
  },
  _ => false,
};

/// The tactics a tagged line named, as concepts in [frame]. [target] is the
/// piece the line traps ([_trappedAt]); the other motifs stay unnamed, as
/// the line cannot say which move plays them.
void _fromReading(
  LineReading reading,
  Frame frame,
  void Function(ConceptKind, Frame, Square?, String) add, {
  Square? target,
}) {
  if (reading.isEmpty) return;
  const kinds = {
    Motif.mate: ConceptKind.checkmate,
    Motif.backRankMate: ConceptKind.backRankMate,
    Motif.hangingPiece: ConceptKind.hangingPiece,
    Motif.fork: ConceptKind.fork,
    Motif.pin: ConceptKind.pin,
    Motif.skewer: ConceptKind.skewer,
    Motif.discoveredAttack: ConceptKind.discoveredAttack,
    Motif.trappedPiece: ConceptKind.trappedPiece,
  };
  for (final motif in reading.motifs) {
    final object = motif == Motif.trappedPiece ? target : null;
    add(kinds[motif]!, frame, object, 'the line: ${motif.label}');
    if (motif == Motif.pin) {
      add(ConceptKind.exploitPin, frame, null, 'the line: pin');
    }
    // The reading cannot tell the move that attacks the trapped piece from
    // the one that traps it, so only "traps" gets the square.
    if (motif == Motif.trappedPiece) {
      add(
        ConceptKind.attackTrappedPiece,
        frame,
        null,
        'the line: trapped piece',
      );
    }
  }
  if (reading.winsMaterial) {
    add(
      ConceptKind.winMaterial,
      frame,
      null,
      'the line: ${describeLine(reading)}',
    );
  }
}

/// The square of the piece [reading] says [loser] loses to a trap, when the
/// line's FIRST move already leaves it trapped there: "Be7, trapping the
/// knight on e8" is then this move's doing, not something later on.
Square? _trappedAt(
  Position start,
  List<String> pvUci,
  Side loser,
  LineReading reading,
) {
  if (!reading.motifs.contains(Motif.trappedPiece)) return null;
  final square = lostPiece(start, pvUci, loser, reading);
  final first = _parse(pvUci, 0);
  if (square == null || first == null || !start.isLegal(first)) return null;
  final next = start.play(first);
  return next.board.sideAt(square) == loser && isTrapped(next, square)
      ? square
      : null;
}

/// Where the most valuable piece [reading] says [loser] loses stood when
/// [pvUci] started from [start], followed through its moves: the knight
/// trapped on e8 that is finally taken on g7. Null when the line takes no
/// piece of that kind.
Square? lostPiece(
  Position start,
  List<String> pvUci,
  Side loser,
  LineReading reading,
) {
  if (reading.won.isEmpty) return null;
  final role = reading.won.first;
  final origin = <Square, Square>{};
  var position = start;
  for (final uci in pvUci) {
    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) return null;
    final board = position.board;
    if (position.turn == loser) {
      origin[move.to] = origin.remove(move.from) ?? move.from;
    } else if (board.sideAt(move.to) == loser) {
      final from = origin.remove(move.to) ?? move.to;
      if (board.roleAt(move.to) == role) return from;
    }
    position = position.play(move);
  }
  return null;
}

/// The tactics of the line's SECOND move for the side playing it (a fork
/// set up by a capture or a check first).
void _laterTactics(
  Position start,
  List<String> pvUci,
  Frame frame,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  if (pvUci.length < 3) return;
  var position = start;
  for (final uci in pvUci.take(2)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) return;
    position = position.play(move);
  }
  final move = Move.parse(pvUci[2]);
  if (move == null) return;
  const tactics = {
    ConceptKind.fork,
    ConceptKind.pin,
    ConceptKind.skewer,
    ConceptKind.discoveredAttack,
    ConceptKind.removeDefender,
  };
  for (final f in moveConcepts(position, move, followUp: _parse(pvUci, 3))) {
    if (tactics.contains(f.kind)) {
      add(f.kind, frame, f.object, 'later in the line: ${f.evidence}');
    }
  }
}

/// Promotions and mates further down a line, for the side playing it.
void _lineEvents(
  Position start,
  List<String> pvUci,
  Side side,
  Frame frame,
  void Function(ConceptKind, Frame, Square?, String) add,
) {
  var position = start;
  for (final uci in pvUci.take(6)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) return;
    final mover = position.turn;
    position = position.play(move);
    if (mover == side && move is NormalMove && move.promotion != null) {
      add(
        ConceptKind.promotion,
        frame,
        move.to,
        'the line promotes on ${move.to.name}',
      );
    }
    if (position.isCheckmate) {
      if (mover == side) {
        add(ConceptKind.checkmate, frame, null, 'the line mates');
      }
      return;
    }
  }
}

/// The board once [next] (the likely recapture) is played, when legal: where
/// `moveConcepts` reads the pawn structure.
Board _settled(Position position, Move? next) =>
    next != null && position.isLegal(next)
    ? position.play(next).board
    : position.board;

/// Whether [next] lands on [square], taking what stands there.
bool _takes(Move? next, Square? square) =>
    next is NormalMove && square != null && next.to == square;

Move? _parse(List<String> pvUci, int index) =>
    pvUci.length <= index ? null : Move.parse(pvUci[index]);
