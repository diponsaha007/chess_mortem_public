/// What ONE move shows on the board: every concept of
/// `concepts.json` that board code can see, with no engine and no
/// frame. `detect_concepts.dart` runs it on the played move (DOES /
/// THREATENS), the engine's better move (BETTER) and the opponent's reply
/// (ALLOWS).
///
/// It lists candidates, it never chooses: a move is usually several things
/// at once ("develops a knight and attacks the centre"), and ranking them is
/// `salience.dart`'s job. Material is in pawns (`material_balance.dart`) and every
/// "is it lost" question is Static Exchange Evaluation (`exchange.dart`).
library;

import 'package:dartchess/dartchess.dart';

import '../exchange.dart';
import '../game_phase.dart';
import '../material_balance.dart';
import '../move_facts.dart' show capturedSquare, castlingSide, landingSquare;
import '../move_tags.dart' show isTrapped;
import 'concept.dart';

/// One concept seen on the board, before a frame is given to it.
typedef Found = ({ConceptKind kind, Square? object, String evidence});

/// What the opponent's last move was, as far as a detector needs it.
typedef PreviousMove = ({Square to, bool captured});

/// A capture the opponent made one move BEFORE its last, whose capturing
/// piece still stands on [to]: the move between was a check or a capture to
/// answer first (29.Qd8+ Bf8 30.Nxe1), so taking on [to] now is taking back.
typedef EarlierCapture = ({Square to, Role took});

/// Every concept [move] shows when played in [before].
///
/// [followUp] is the next move of the line (the likely recapture), so a
/// structure change the recapture completes — doubled pawns after Bxc6 bxc6
/// — is seen. [previous] is the opponent's last move, [earlier] its capture
/// the move before that.
List<Found> moveConcepts(
  Position before,
  Move move, {
  Move? followUp,
  PreviousMove? previous,
  EarlierCapture? earlier,
  GamePhase phase = GamePhase.middlegame,
}) {
  if (!before.isLegal(move)) return const [];
  final m = _Move(before, move, followUp);
  return [
    ..._outcome(m),
    ..._material(m, previous, earlier),
    ..._tactics(m),
    ..._safety(m),
    ..._king(m, phase),
    ..._pieces(m, phase),
    ..._pawns(m, phase),
  ];
}

/// The move and the boards around it, with the facts every detector asks.
class _Move {
  _Move(this.before, this.move, this.followUp)
    : after = before.play(move),
      mover = before.turn,
      piece = before.board.pieceAt(_from(move))!,
      from = _from(move),
      to = landingSquare(before, move)!,
      taken = capturedSquare(before, move) {
    // The follow-up only completes what THIS move started: the recapture
    // of a capture, on the same square. Otherwise its structure changes are
    // the reply's own.
    final follow = followUp;
    final next =
        taken != null &&
            follow is NormalMove &&
            follow.to == to &&
            after.isLegal(follow)
        ? after.play(follow)
        : null;
    settled = next ?? after;
  }

  final Position before;
  final Move move;
  final Position after;

  /// The next move of the line, if any.
  final Move? followUp;

  /// [after] plus the follow-up, when it was legal.
  late final Position settled;
  final Side mover;
  final Piece piece;
  final Square from;
  final Square to;
  final Square? taken;

  Side get opponent => mover.opposite;
  Role get role => piece.role;
  Board get board => after.board;
  bool get isCastle => castlingSide(before, move) != null;

  /// The piece standing on [to] after the move (a promotion changes it).
  Piece get landed => board.pieceAt(to)!;

  int get takenValue =>
      taken == null ? 0 : valueOf(before.board.pieceAt(taken!)!.role);

  /// What the landed piece attacks from [to].
  SquareSet get attacksNow => attacks(landed, to, board.occupied);

  /// What the moving piece attacked from [from].
  SquareSet get attacksBefore => attacks(piece, from, before.board.occupied);
}

Square _from(Move move) => (move as NormalMove).from;

String _at(Board board, Square square) {
  final piece = board.pieceAt(square)!;
  return 'the ${piece.color.name} ${piece.role.name} on ${square.name}';
}

// ---- Mate and check ----

List<Found> _outcome(_Move m) {
  final found = <Found>[];
  if (m.after.isCheckmate) {
    found.add((kind: ConceptKind.checkmate, object: null, evidence: 'mate'));
    final king = m.board.kingOf(m.opponent)!;
    if (_relativeRank(m.opponent, king) == 0) {
      found.add((
        kind: ConceptKind.backRankMate,
        object: king,
        evidence: 'mate on the back rank',
      ));
    }
  } else if (m.after.isCheck) {
    found.add((kind: ConceptKind.check, object: null, evidence: 'gives check'));
  }
  if (m.after.isCheck && !m.after.checkers.has(m.to)) {
    found.add((
      kind: ConceptKind.discoveredCheck,
      object: m.board.kingOf(m.opponent),
      evidence: 'the check comes from a piece that did not move',
    ));
  }
  final threat = m.after.isGameOver ? null : _mateInOne(m.after, m.mover);
  if (threat != null) {
    found.add((
      kind: ConceptKind.mateThreat,
      object: null,
      evidence: 'threatens $threat mate',
    ));
  }
  if (m.move case NormalMove(promotion: final Role promoted)) {
    found.add((
      kind: ConceptKind.promotion,
      object: m.to,
      evidence: 'promotes to a ${promoted.name}',
    ));
  } else if (m.role == Role.pawn && _relativeRank(m.mover, m.to) == 6) {
    final stop = m.to.offset(m.mover == Side.white ? 8 : -8);
    if (stop != null && !m.board.occupied.has(stop)) {
      found.add((
        kind: ConceptKind.promotion,
        object: m.to,
        evidence: 'the pawn on ${m.to.name} is one step from promoting',
      ));
    }
  }
  if (m.before.legalMoves.values.fold(0, (n, set) => n + set.size) == 1) {
    found.add((
      kind: ConceptKind.forcedMove,
      object: null,
      evidence: 'the only legal move',
    ));
  }
  return found;
}

/// A mating move for [side] if it could move again in [position] (a null
/// move), in SAN, else null. The threat a quiet move makes.
String? _mateInOne(Position position, Side side) {
  final Position probe;
  if (position.turn == side) {
    probe = position;
  } else {
    if (position.isCheck) return null; // the opponent must answer the check
    final parts = position.fen.split(' ');
    parts[1] = side == Side.white ? 'w' : 'b';
    parts[3] = '-';
    try {
      probe = Chess.fromSetup(Setup.parseFen(parts.join(' ')));
    } on PositionSetupException {
      return null;
    }
  }
  for (final entry in probe.legalMoves.entries) {
    for (final to in entry.value.squares) {
      final move = NormalMove(from: entry.key, to: to);
      final moves =
          probe.board.pawns.has(entry.key) && SquareSet.backranks.has(to)
          ? [NormalMove(from: entry.key, to: to, promotion: Role.queen)]
          : [move];
      for (final candidate in moves) {
        if (!probe.isLegal(candidate)) continue;
        if (probe.play(candidate).isCheckmate) {
          return probe.makeSan(candidate).$2;
        }
      }
    }
  }
  return null;
}

// ---- Captures and trades ----

List<Found> _material(
  _Move m,
  PreviousMove? previous,
  EarlierCapture? earlier,
) {
  final found = <Found>[];
  final taken = m.taken;
  // Taking back what the opponent took a move earlier only restores the
  // material: never free, and a win only by what it takes beyond that.
  final takesBackLate = earlier != null && earlier.to == taken;
  if (takesBackLate) {
    final what = _at(m.before.board, taken!);
    found.add((
      kind: ConceptKind.capture,
      object: taken,
      evidence: 'takes $what',
    ));
    found.add((
      kind: ConceptKind.recapture,
      object: taken,
      evidence: 'takes back on ${taken.name}',
    ));
    final back = staticExchange(m.board, m.to, m.opponent);
    if (m.takenValue - back > valueOf(earlier.took)) {
      found.add((
        kind: ConceptKind.winMaterial,
        object: taken,
        evidence:
            'takes $what, which had taken only '
            '${earlier.took == Role.pawn ? 'a pawn' : 'a ${earlier.took.name}'}',
      ));
    }
  } else if (taken != null) {
    final what = _at(m.before.board, taken);
    // What the opponent wins back on the landing square.
    final back = staticExchange(m.board, m.to, m.opponent);
    final net = m.takenValue - back;
    found.add((
      kind: ConceptKind.capture,
      object: taken,
      evidence: 'takes $what',
    ));
    final recaptures =
        previous != null && previous.captured && previous.to == taken;
    if (recaptures) {
      found.add((
        kind: ConceptKind.recapture,
        object: taken,
        evidence: 'takes back on ${taken.name}',
      ));
    }
    if (net > 0 && back == 0 && recaptures) {
      // Taking back is never free: the piece just took something.
      found.add((
        kind: ConceptKind.winMaterial,
        object: taken,
        evidence: 'takes back $what',
      ));
    } else if (net > 0 && back == 0) {
      // Nothing comes back on the square: free.
      found.add((
        kind: ConceptKind.captureFree,
        object: taken,
        evidence: 'takes $what for free',
      ));
      found.add((
        kind: ConceptKind.winMaterial,
        object: taken,
        evidence: 'takes $what for free',
      ));
    } else if (net > 0) {
      // Ahead after the exchange, but not by the whole piece. When what
      // comes back is the capturing piece itself, the line can say so: "the
      // rook on b3 for the bishop".
      final costs = back == valueOf(m.role) ? ', for the ${m.role.name}' : '';
      found.add((
        kind: ConceptKind.winMaterial,
        object: taken,
        evidence: 'takes $what and comes out $net ahead$costs',
      ));
    } else if (net == 0 && m.takenValue > 0) {
      found.add((
        kind: ConceptKind.evenTrade,
        object: taken,
        evidence: 'takes $what, which can be taken back evenly',
      ));
      final ahead =
          materialFor(m.before.board, m.mover) -
          materialFor(m.before.board, m.opponent);
      if (ahead >= 2) {
        found.add((
          kind: ConceptKind.tradeWhenAhead,
          object: taken,
          evidence: 'trades while $ahead ahead',
        ));
      }
    }
  } else if (!m.isCastle && m.role != Role.king) {
    // Offers a trade: an enemy piece of the same value attacks the landing
    // square, and taking there only trades.
    final offers = m.board
        .attacksTo(m.to, m.opponent)
        .squares
        .where((s) => valueOf(m.board.pieceAt(s)!.role) == valueOf(m.role));
    if (m.role != Role.pawn &&
        offers.isNotEmpty &&
        exchangeLoss(m.board, m.to, m.mover) == 0) {
      found.add((
        kind: ConceptKind.evenTrade,
        object: offers.first,
        evidence: 'offers a trade with ${_at(m.board, offers.first)}',
      ));
    }
  }

  final offered = offeredPieces(
    m.after,
    m.mover,
    capturedValue: m.takenValue,
  ).where((s) => canBeCaptured(m.after, s));
  if (offered.isNotEmpty) {
    found.add((
      kind: ConceptKind.sacrifice,
      object: offered.first,
      evidence: 'leaves ${_at(m.board, offered.first)} to be taken',
    ));
  }
  return found;
}

// ---- Tactics made by the moved piece ----

List<Found> _tactics(_Move m) {
  final found = <Found>[];
  final board = m.board;
  final enemy = board.bySide(m.opponent);
  final attacked = m.attacksNow.intersect(enemy);
  final attackerValue = valueOf(m.landed.role);

  // Targets: a piece worth more than the attacker, or one that is simply
  // lost (static exchange). The king counts as a target of a fork.
  final targets = [
    for (final s in attacked.squares)
      if (board.pieceAt(s)!.role == Role.king ||
          valueOf(board.pieceAt(s)!.role) > attackerValue ||
          staticExchange(board, s, m.mover) > 0)
        s,
  ];
  final nonKing = [
    for (final s in targets)
      if (board.pieceAt(s)!.role != Role.king) s,
  ];
  // A fork holds only if no target can simply take the forking piece
  // (Qg4 "forking" a queen that trades itself off on g4 is no fork). A
  // capture that loses more than it takes (Bxd4 Bxd4) answers nothing.
  final answerable = targets.any(
    (t) =>
        board.pieceAt(t)!.role != Role.king &&
        attacks(board.pieceAt(t)!, t, board.occupied).has(m.to) &&
        (_captureGain(m.after, t, m.to) ?? -1) >= 0,
  );
  // A fork wins a piece: a check that also hits a pawn is a check.
  final hitsPiece = nonKing.any((s) => board.pieceAt(s)!.role != Role.pawn);
  if (targets.length >= 2 && hitsPiece && !answerable) {
    found.add((
      kind: ConceptKind.fork,
      object: _mostValuable(board, nonKing),
      evidence: 'attacks ${targets.map((s) => _at(board, s)).join(' and ')}',
    ));
  }

  final before = m.before.board;
  for (final s in nonKing) {
    if (m.attacksBefore.has(s)) continue;
    final target = _at(board, s);
    final wasAttacked = before.attacksTo(s, m.mover).isNotEmpty;
    found.add((
      kind: ConceptKind.attackPiece,
      object: s,
      evidence: 'attacks $target',
    ));
    if (m.taken == null) {
      found.add((
        kind: ConceptKind.gainTempo,
        object: s,
        evidence: 'attacks $target, which has to be answered',
      ));
    }
    if (m.role == Role.pawn && board.pieceAt(s)!.role != Role.pawn) {
      found.add((
        kind: ConceptKind.pawnKick,
        object: s,
        evidence: 'the pawn attacks $target',
      ));
    }
    if (wasAttacked) {
      found.add((
        kind: ConceptKind.pileOn,
        object: s,
        evidence: 'adds an attacker to $target',
      ));
    }
    if (isTrapped(m.after, s)) {
      found.add((
        kind: ConceptKind.attackTrappedPiece,
        object: s,
        evidence: '$target has no safe square',
      ));
      found.add((
        kind: ConceptKind.trappedPiece,
        object: s,
        evidence: '$target has no safe square',
      ));
    }
  }
  // A pawn kick needs no winning target: any piece a pawn attacks must move.
  if (m.role == Role.pawn) {
    for (final s in attacked.squares) {
      final role = board.pieceAt(s)!.role;
      if (role == Role.pawn || role == Role.king || nonKing.contains(s)) {
        continue;
      }
      found.add((
        kind: ConceptKind.pawnKick,
        object: s,
        evidence: 'the pawn attacks ${_at(board, s)}',
      ));
    }
    // A lever: the pawn now attacks an enemy pawn.
    final pawns = attacked.intersect(board.pawns);
    if (pawns.first case final Square lever) {
      found.add((
        kind: ConceptKind.pawnChainAttack,
        object: lever,
        evidence: 'the pawn strikes at ${_at(board, lever)}',
      ));
    }
  }

  // Pins and skewers along the moved slider's lines.
  if (_isSlider(m.landed.role)) {
    for (final (front, back) in _lineUps(board, m.to)) {
      // A "pinned" piece that wins material by taking the pinner is not
      // held; one that can only trade itself off still is.
      if ((_captureGain(m.after, front, m.to) ?? 0) > 0) continue;
      final frontValue = _kingValue(board.pieceAt(front)!.role);
      final backValue = _kingValue(board.pieceAt(back)!.role);
      if ((backValue > frontValue && backValue > attackerValue ||
              board.pieceAt(back)!.role == Role.king) &&
          _pinHolds(board, front, m.to)) {
        found.add((
          kind: ConceptKind.pin,
          object: front,
          evidence: 'pins ${_at(board, front)} to ${_at(board, back)}',
        ));
      } else if (frontValue > backValue &&
          board.pieceAt(back)!.role != Role.pawn) {
        found.add((
          kind: ConceptKind.skewer,
          object: back,
          evidence: 'skewers ${_at(board, front)} and ${_at(board, back)}',
        ));
      }
    }
  }

  // Attacking or taking a piece that is pinned, or whose defender is. A pin
  // the moved piece makes itself is the pin, read above.
  final pinned = _pinnedPieces(board, m.opponent, except: m.to);
  for (final s in attacked.squares) {
    if (pinned.contains(s)) {
      found.add((
        kind: ConceptKind.exploitPin,
        object: s,
        evidence: 'attacks ${_at(board, s)}, which is pinned',
      ));
    }
  }
  final taken = m.taken;
  if (taken != null) {
    final defenders = m.before.board.attacksTo(taken, m.opponent);
    if (defenders.squares.any(
      _pinnedPieces(m.before.board, m.opponent).contains,
    )) {
      found.add((
        kind: ConceptKind.exploitPin,
        object: taken,
        evidence: 'the defender of ${taken.name} is pinned',
      ));
    }
  }

  // A discovered attack: a slider behind the moved piece now reaches a target.
  for (final s
      in board
          .bySide(m.mover)
          .intersect(board.bishopsAndQueens | board.rooksAndQueens)
          .squares) {
    if (s == m.to) continue;
    final slider = board.pieceAt(s)!;
    final gained = attacks(
      slider,
      s,
      board.occupied,
    ).diff(attacks(slider, s, m.before.board.occupied)).intersect(enemy);
    for (final t in gained.squares) {
      final role = board.pieceAt(t)!.role;
      if (role == Role.king) continue; // discovered check, above
      if (valueOf(role) > valueOf(slider.role) ||
          staticExchange(board, t, m.mover) > 0) {
        found.add((
          kind: ConceptKind.discoveredAttack,
          object: t,
          evidence: 'uncovers ${_at(board, s)} onto ${_at(board, t)}',
        ));
      }
    }
  }

  // Removing a defender by chasing it or checking it away: some other enemy
  // piece holds only because the attacked piece (or king) guards it.
  final chased = {
    ...m.attacksNow.intersect(enemy).squares.where((d) => d != taken),
    if (m.after.isCheck) ?board.kingOf(m.opponent),
  };
  for (final d in chased) {
    final gone = board.removePieceAt(d);
    for (final s in enemy.squares) {
      if (s == d || board.pieceAt(s)!.role == Role.king) continue;
      if (!board.attacksTo(s, m.opponent).has(d)) continue;
      if (staticExchange(board, s, m.mover) <= 0 &&
          staticExchange(gone, s, m.mover) > 0) {
        found.add((
          kind: ConceptKind.removeDefender,
          object: s,
          evidence: '${_at(board, d)} is the defender of ${_at(board, s)}',
        ));
      }
    }
  }
  // Taking a defender: another enemy piece is now lost, and the piece taken
  // was guarding it (not merely now attacked by the capturing piece: it is
  // lost even with the capturer off the board).
  if (taken != null) {
    final victim = m.before.board.pieceAt(taken)!;
    final guarded = attacks(victim, taken, m.before.board.occupied);
    final withoutCapturer = board.removePieceAt(m.to);
    for (final s in enemy.squares) {
      if (board.pieceAt(s)!.role == Role.king || !guarded.has(s)) continue;
      // A target that can take back on the square leaves it to do so: Bxe6
      // fxe6 is a trade, not the f7 pawn's defender removed.
      if (board.attacksTo(m.to, m.opponent).has(s)) continue;
      final was = staticExchange(m.before.board, s, m.mover);
      final now = staticExchange(board, s, m.mover);
      final alone = staticExchange(withoutCapturer, s, m.mover);
      if (now > 0 && now > was && alone > 0 && alone > was) {
        found.add((
          kind: ConceptKind.removeDefender,
          object: s,
          evidence: 'takes the defender of ${_at(board, s)}',
        ));
      }
    }
  }
  return found;
}

// ---- The mover's own pieces: escaping, defending, hanging ----

List<Found> _safety(_Move m) {
  final found = <Found>[];
  // Taking the checking piece is said as the capture ("the checking rook");
  // getting out of check is only how it ends.
  final takesChecker = m.taken != null && m.before.checkers.has(m.taken!);
  if (m.before.isCheck && !takesChecker) {
    found.add((
      kind: ConceptKind.escapeCheck,
      object: m.to,
      evidence: 'answers the check',
    ));
  }

  final threatenedBefore = _enPrise(m.before.board, m.mover);
  final threatenedAfter = _enPrise(m.board, m.mover);
  // Attacked: en prise, or hit by a piece worth no more than it.
  final wasHit =
      threatenedBefore.containsKey(m.from) ||
      _hitByEqualOrLess(m.before.board, m.from);
  // A capture is said as the capture: "moves to safety" would hide what it
  // took.
  if (wasHit && !m.isCastle && m.role != Role.king && m.taken == null) {
    if (!threatenedAfter.containsKey(m.to) &&
        !_hitByEqualOrLess(m.board, m.to, strictly: true)) {
      found.add((
        kind: ConceptKind.escapeAttack,
        object: m.to,
        evidence:
            'the ${m.role.name} on ${m.from.name} was attacked and is '
            'safe on ${m.to.name}',
      ));
    }
  }
  for (final s in threatenedBefore.keys) {
    if (s == m.from || threatenedAfter.containsKey(s)) continue;
    final attackers = m.before.board.attacksTo(s, m.opponent);
    final taken = m.taken;
    if (taken != null && attackers.has(taken)) {
      found.add((
        kind: ConceptKind.removeAttacker,
        object: taken,
        evidence: 'takes the piece attacking ${_at(m.before.board, s)}',
      ));
    } else {
      // Stepping into the attacker's line blocks the attack; it does not
      // defend the piece.
      final blocks = attackers.squares.any((a) => between(a, s).has(m.to));
      found.add((
        kind: ConceptKind.defendHanging,
        object: s,
        evidence: blocks
            ? 'blocks the attack on ${_at(m.before.board, s)}'
            : '${_at(m.before.board, s)} was hanging and is safe now',
      ));
    }
  }
  if (threatenedBefore.isNotEmpty && threatenedAfter.isEmpty) {
    found.add((
      kind: ConceptKind.defendThreat,
      object: threatenedBefore.keys.first,
      evidence: 'nothing is left en prise',
    ));
  }
  final mateThreat = _mateInOne(m.before, m.opponent);
  // A check only puts the threat off: the opponent answers it, and the
  // mate is still there.
  if (!m.before.isCheck && !m.after.isCheck && mateThreat != null) {
    if (m.after.isGameOver || _mateInOne(m.after, m.opponent) == null) {
      found.add((
        kind: ConceptKind.defendThreat,
        object: null,
        evidence: 'stops $mateThreat mate',
      ));
    } else {
      found.add((
        kind: ConceptKind.ignoredThreat,
        object: null,
        evidence: '$mateThreat still mates',
      ));
      found.add((
        kind: ConceptKind.checkmate,
        object: null,
        evidence: '$mateThreat still mates',
      ));
    }
  }
  for (final s in threatenedAfter.keys) {
    // A capturing piece that is taken back for what it took is a trade.
    if (s == m.to && threatenedAfter[s]! <= m.takenValue) continue;
    final newly = !threatenedBefore.containsKey(s == m.to ? m.from : s);
    found.add((
      kind: newly ? ConceptKind.hangingPiece : ConceptKind.ignoredThreat,
      object: s,
      evidence:
          '${_at(m.board, s)} can be taken for '
          '${threatenedAfter[s]} gain',
    ));
    if (!newly) {
      found.add((
        kind: ConceptKind.hangingPiece,
        object: s,
        evidence: '${_at(m.board, s)} is still en prise',
      ));
    }
  }
  return found;
}

/// Whether an enemy piece worth no more (less, when [strictly]) than the
/// piece on [square] attacks it.
bool _hitByEqualOrLess(Board board, Square square, {bool strictly = false}) {
  final piece = board.pieceAt(square)!;
  final value = valueOf(piece.role);
  return board.attacksTo(square, piece.color.opposite).squares.any((s) {
    final role = board.pieceAt(s)!.role;
    if (role == Role.king) return false;
    return strictly ? valueOf(role) < value : valueOf(role) <= value;
  });
}

/// [owner]'s pieces the opponent wins something by taking, with the loss.
Map<Square, int> _enPrise(Board board, Side owner) {
  final lost = <Square, int>{};
  for (final s in board.bySide(owner).squares) {
    if (board.pieceAt(s)!.role == Role.king) continue;
    final loss = exchangeLoss(board, s, owner);
    if (loss > 0) lost[s] = loss;
  }
  return lost;
}

// ---- The king ----

List<Found> _king(_Move m, GamePhase phase) {
  final found = <Found>[];
  final side = castlingSide(m.before, m.move);
  if (side != null) {
    found.add((
      kind: ConceptKind.castle,
      object: m.to,
      evidence: 'castles ${side.name}side',
    ));
  }

  // The last piece off the castling path, with the right still there.
  for (final cs in CastlingSide.values) {
    if (side != null || m.after.castles.rookOf(m.mover, cs) == null) continue;
    final path = m.after.castles.pathOf(m.mover, cs);
    if (path.isIntersected(m.before.board.occupied) &&
        !path.isIntersected(m.board.occupied)) {
      found.add((
        kind: ConceptKind.enableCastling,
        object: null,
        evidence: 'clears the way to castle ${cs.name}side',
      ));
    }
  }

  final king = m.before.board.kingOf(m.mover);
  if (m.role == Role.pawn && king != null) {
    final shelter =
        _relativeRank(m.mover, king) == 0 &&
        (m.from.file - king.file).abs() <= 1 &&
        _relativeRank(m.mover, m.from) <= 2;
    if (shelter) {
      // Luft is the pawn right in front of the king stepping up: the square
      // it leaves is the king's. Not a check, and not a pawn offered.
      final luft =
          _relativeRank(m.mover, m.from) == 1 &&
          (m.to.rank - m.from.rank).abs() == 1 &&
          m.taken == null &&
          !m.after.isCheck &&
          staticExchange(m.board, m.to, m.opponent) <= 0;
      if (luft && (king.file <= 2 || king.file >= 5)) {
        found.add((
          kind: ConceptKind.luft,
          object: m.to,
          evidence: 'gives the king on ${king.name} a square',
        ));
      }
      found.add((
        kind: ConceptKind.kingExposed,
        object: king,
        evidence: 'moves a pawn in front of the king on ${king.name}',
      ));
    }
  }

  if (m.role == Role.king && side == null) {
    if (m.before.castles.rookOf(m.mover, CastlingSide.king) != null ||
        m.before.castles.rookOf(m.mover, CastlingSide.queen) != null) {
      found.add((
        kind: ConceptKind.kingExposed,
        object: m.to,
        evidence: 'the king moves and can no longer castle',
      ));
    }
    if (!m.before.isCheck &&
        (phase == GamePhase.endgame ||
            _centreDistance(m.to) < _centreDistance(m.from))) {
      found.add((
        kind: ConceptKind.kingActivity,
        object: m.to,
        evidence: 'the king steps to ${m.to.name}',
      ));
    }
    final other = m.board.kingOf(m.opponent);
    if (other != null && _onlyKingsAndPawns(m.board)) {
      final df = (other.file - m.to.file).abs();
      final dr = (other.rank - m.to.rank).abs();
      if ((df == 0 && dr.isEven) ||
          (dr == 0 && df.isEven) ||
          (df == 2 && dr == 2)) {
        found.add((
          kind: ConceptKind.opposition,
          object: other,
          evidence: 'the kings face each other with the opponent to move',
        ));
      }
    }
  }
  return found;
}

bool _onlyKingsAndPawns(Board board) =>
    board.occupied.diff(board.kings).diff(board.pawns).isEmpty;

/// Steps from the nearest of d4, e4, d5, e5.
int _centreDistance(Square s) {
  final df = s.file <= 3 ? 3 - s.file : s.file - 4;
  final dr = s.rank <= 3 ? 3 - s.rank : s.rank - 4;
  return df > dr ? df : dr;
}

// ---- Piece placement ----

List<Found> _pieces(_Move m, GamePhase phase) {
  final found = <Found>[];
  if (m.isCastle) {
    // Castling puts the rook on its file; that can be an open one.
    return _rookFile(
      m,
      m.board
          .bySide(m.mover)
          .intersect(m.board.rooks)
          .intersect(SquareSet.backrankOf(m.mover)),
    );
  }
  final role = m.role;

  if (phase != GamePhase.endgame) found.addAll(_development(m));

  if (phase != GamePhase.endgame && role != Role.king && role != Role.queen) {
    final centre = SquareSet.center;
    final gained = m.attacksNow.diff(
      role == Role.pawn ? SquareSet.empty : m.attacksBefore,
    );
    // A centre square its own piece stands on is not won: the move backs
    // up that piece (c3 behind a pawn on d4).
    final own = m.board.bySide(m.mover);
    final controls = gained.intersect(centre).diff(own);
    final supports = gained.intersect(centre).intersect(own);
    if (centre.has(m.to) || controls.isNotEmpty) {
      found.add((
        kind: ConceptKind.centralControl,
        object: m.to,
        evidence: centre.has(m.to)
            ? 'takes the centre square ${m.to.name}'
            : 'now controls ${controls.squares.map((s) => s.name).join(', ')}',
      ));
    } else if (supports.isNotEmpty) {
      final s = supports.first!;
      found.add((
        kind: ConceptKind.centralControl,
        object: m.to,
        evidence: 'supports the ${m.board.roleAt(s)!.name} on ${s.name}',
      ));
    }
  }

  if (role != Role.pawn && role != Role.king) {
    final own = m.board.bySide(m.mover);
    final now = m.attacksNow.diff(own).size;
    final was = attacks(
      m.piece,
      m.from,
      m.before.board.occupied,
    ).diff(m.before.board.bySide(m.mover)).size;
    if (now - was >= 3) {
      found.add((
        kind: ConceptKind.activeSquare,
        object: m.to,
        evidence: 'the ${role.name} reaches $now squares instead of $was',
      ));
    } else if (was - now >= 2 &&
        _relativeRank(m.mover, m.to) < _relativeRank(m.mover, m.from)) {
      found.add((
        kind: ConceptKind.passivePiece,
        object: m.to,
        evidence:
            'the ${role.name} retreats to ${m.to.name}, $now squares '
            'instead of $was',
      ));
    }
  }

  if (role == Role.rook) {
    final doubled = doubledRook(m.before, m.move);
    if (doubled != null) {
      // A rook that joins another on a file is doubling, not developing.
      found.removeWhere(
        (f) => f.kind == ConceptKind.developPiece && f.object == m.to,
      );
      found.add((
        kind: ConceptKind.doubleRooks,
        object: m.to,
        evidence: 'doubles with the rook on ${doubled.name}',
      ));
    }
    found.addAll(_rookFile(m, SquareSet.fromSquare(m.to)));
    if (_relativeRank(m.mover, m.to) == 6) {
      found.add((
        kind: ConceptKind.rookSeventh,
        object: m.to,
        evidence: 'the rook reaches the seventh rank',
      ));
    }
  }
  // Connecting the rooks is the usual "better square" for a rook.
  if (_rooksConnected(m.board, m.mover) &&
      !_rooksConnected(m.before.board, m.mover)) {
    found.add((
      kind: ConceptKind.activeSquare,
      object: m.to,
      evidence: 'the rooks are connected',
    ));
  }

  if ((role == Role.knight || role == Role.bishop) &&
      _isOutpost(m.board, m.to, m.mover)) {
    found.add((
      kind: ConceptKind.outpost,
      object: m.to,
      evidence:
          '${m.to.name} is backed by a pawn and no enemy pawn can '
          'chase it',
    ));
  }
  return found;
}

/// A piece leaving its starting square (a rook or queen too: "into the
/// game"), or a pawn move that opens the way for a bishop still at home.
List<Found> _development(_Move m) {
  final found = <Found>[];
  final start = _starts[m.mover]!;
  if (m.role != Role.pawn &&
      m.role != Role.king &&
      (start[m.from.name] == m.role || _castledRook(m))) {
    found.add((
      kind: ConceptKind.developPiece,
      object: m.to,
      evidence: 'the ${m.role.name} leaves ${m.from.name}',
    ));
  }
  if (m.role == Role.pawn) {
    final bishops = m.board.bySide(m.mover).intersect(m.board.bishops);
    for (final b in bishops.squares) {
      if (start[b.name] != Role.bishop) continue;
      final piece = m.board.pieceAt(b)!;
      final now = attacks(
        piece,
        b,
        m.board.occupied,
      ).diff(m.board.bySide(m.mover));
      final was = attacks(
        piece,
        b,
        m.before.board.occupied,
      ).diff(m.before.board.bySide(m.mover));
      if (now.size > was.size) {
        found.add((
          kind: ConceptKind.developPiece,
          object: b,
          evidence: 'opens the way for the bishop on ${b.name}',
        ));
      }
    }
  }
  return found;
}

/// A rook leaving the square castling put it on, its king still beside it
/// (Rf1-e1 after O-O): it comes into the game from there.
bool _castledRook(_Move m) {
  if (m.role != Role.rook || _relativeRank(m.mover, m.from) != 0) return false;
  final king = m.before.board.kingOf(m.mover);
  if (king == null || king.rank != m.from.rank) return false;
  return switch (m.from.file) {
    File.f => king.file == File.g,
    File.d => king.file == File.c || king.file == File.b,
    _ => false,
  };
}

const _starts = {
  Side.white: {
    'a1': Role.rook,
    'b1': Role.knight,
    'c1': Role.bishop,
    'd1': Role.queen,
    'f1': Role.bishop,
    'g1': Role.knight,
    'h1': Role.rook,
  },
  Side.black: {
    'a8': Role.rook,
    'b8': Role.knight,
    'c8': Role.bishop,
    'd8': Role.queen,
    'f8': Role.bishop,
    'g8': Role.knight,
    'h8': Role.rook,
  },
};

/// What the piece on [from] wins by taking on [to] in [position], once the
/// exchange there is over; null when it cannot legally take.
int? _captureGain(Position position, Square from, Square to) {
  final move = NormalMove(from: from, to: to);
  if (!position.isLegal(move)) return null;
  final taken = valueOf(position.board.roleAt(to)!);
  final back = staticExchange(
    position.play(move).board,
    to,
    position.turn.opposite,
  );
  return taken - back;
}

/// The square of the rook [move] doubles with, or null: a rook coming from
/// another file lands on a file free of its own pawns (open or half-open),
/// with another of its rooks on that file and nothing between them.
Square? doubledRook(Position before, Move move) {
  if (move is! NormalMove || !before.isLegal(move)) return null;
  final board = before.board;
  final side = before.turn;
  if (board.roleAt(move.from) != Role.rook) return null;
  if (move.from.file == move.to.file) return null;
  final after = before.play(move).board;
  final file = SquareSet.fromFile(move.to.file);
  final own = after.bySide(side);
  if (own.intersect(after.pawns).intersect(file).isNotEmpty) return null;
  for (final s in own.intersect(after.rooks).intersect(file).squares) {
    if (s == move.to) continue;
    if (between(s, move.to).intersect(after.occupied).isEmpty) return s;
  }
  return null;
}

List<Found> _rookFile(_Move m, SquareSet rooks) => [
  for (final s in rooks.squares)
    if (m.board.pawns
            .intersect(m.board.bySide(m.mover))
            .intersect(SquareSet.fromFile(s.file))
            .isEmpty &&
        _seesUpFile(m.board, s, m.mover))
      (
        kind: ConceptKind.rookOpenFile,
        object: s,
        evidence: 'the rook on ${s.name} stands on an open file',
      ),
];

/// Whether the rook of [side] on [square] looks up its file: no piece of
/// its own stands ahead of it (Re1 behind a bishop on e3 stands on no open
/// file). An enemy piece ahead is what the rook presses on.
bool _seesUpFile(Board board, Square square, Side side) {
  final step = side == Side.white ? 8 : -8;
  for (var s = square.offset(step); s != null; s = s.offset(step)) {
    final piece = board.pieceAt(s);
    if (piece != null) return piece.color != side;
  }
  return true;
}

bool _rooksConnected(Board board, Side side) {
  final rooks = board
      .bySide(side)
      .intersect(board.rooks)
      .intersect(SquareSet.backrankOf(side));
  if (rooks.size != 2) return false;
  return between(rooks.first!, rooks.last!).intersect(board.occupied).isEmpty;
}

bool _isOutpost(Board board, Square square, Side side) {
  final rank = _relativeRank(side, square);
  if (rank < 3 || rank > 5) return false;
  final ownPawns = board.pawns.intersect(board.bySide(side));
  if (pawnAttacks(side.opposite, square).intersect(ownPawns).isEmpty) {
    return false;
  }
  final enemyPawns = board.pawns.intersect(board.bySide(side.opposite));
  for (final p in enemyPawns.squares) {
    if ((p.file - square.file).abs() != 1) continue;
    // An enemy pawn still behind the square (from its side) can come to attack it.
    if (_relativeRank(side, p) > rank) return false;
  }
  return true;
}

// ---- Pawns ----

List<Found> _pawns(_Move m, GamePhase phase) {
  final found = <Found>[];
  final before = m.before.board;
  final after = m.settled.board;

  // A pawn the next move takes (axb3 Bxb3, or b3 Rxb3) becomes passed
  // nowhere; one passed already is still pushed.
  final next = m.followUp;
  final taken =
      m.settled.board.pieceAt(m.to) != m.landed ||
      (next is NormalMove && next.to == m.to && m.after.isLegal(next));
  // "pushes" when it was passed already: nothing new is created.
  final already = m.role == Role.pawn && _isPassed(before, m.from, m.mover);
  if (m.role == Role.pawn &&
      (already || !taken) &&
      _isPassed(m.board, m.to, m.mover)) {
    found.add((
      kind: ConceptKind.passedPawn,
      object: m.to,
      evidence: already
          ? 'pushes the passed pawn to ${m.to.name}'
          : 'the pawn on ${m.to.name} becomes passed',
    ));
  }
  for (final s in _passed(
    after,
    m.mover,
  ).diff(_passed(before, m.mover)).squares) {
    if (s == m.to) continue;
    found.add((
      kind: ConceptKind.passedPawn,
      object: s,
      evidence: 'the pawn on ${s.name} becomes passed',
    ));
  }
  // Stopping an enemy passed pawn: blockade, capture, or covering its path.
  for (final p in _passed(before, m.opponent).squares) {
    final ahead = _pathAhead(p, m.opponent);
    final blocks = ahead.isNotEmpty && ahead.first == m.to;
    final takes = m.taken == p;
    final covers =
        m.role != Role.pawn &&
        ahead.any(m.attacksNow.has) &&
        !ahead.any(m.attacksBefore.has);
    if (blocks || takes || covers) {
      found.add((
        kind: ConceptKind.stopPassedPawn,
        object: p,
        evidence: 'stops the passed pawn on ${p.name}',
      ));
    }
  }

  // Structure damage names the damaged pawn, so the caller can tell whose
  // it is (a move that doubles its own pawns ALLOWS it).
  for (final side in Side.values) {
    final pawns = after.pawns.intersect(after.bySide(side));
    final doubled = _doubledFiles(
      after,
      side,
    ).diff(_doubledFiles(before, side));
    for (final marker in doubled.squares) {
      final pawn = pawns.intersect(SquareSet.fromFile(marker.file)).first!;
      found.add((
        kind: ConceptKind.doubledPawns,
        object: pawn,
        evidence:
            'doubles the ${side.name} pawns on the ${marker.file.name}-file',
      ));
    }
    final structure = {
      ConceptKind.isolatedPawn: (_isolated, 'isolated'),
      ConceptKind.backwardPawn: (_backward, 'backward'),
    };
    for (final MapEntry(key: kind, value: (weak, word)) in structure.entries) {
      final now = weak(after, side);
      if (now.size <= weak(before, side).size) continue;
      final pawn = now.diff(weak(before, side)).first ?? now.first!;
      found.add((
        kind: kind,
        object: pawn,
        evidence: 'leaves the ${side.name} pawn on ${pawn.name} $word',
      ));
    }
  }

  if (m.role == Role.pawn) {
    final own = m.board.pawns.intersect(m.board.bySide(m.mover));
    final linked = pawnAttacks(
      m.mover,
      m.to,
    ).union(pawnAttacks(m.mover.opposite, m.to)).intersect(own);
    final wasLinked = pawnAttacks(m.mover, m.from)
        .union(pawnAttacks(m.mover.opposite, m.from))
        .intersect(before.pawns.intersect(before.bySide(m.mover)));
    if (linked.isNotEmpty && wasLinked.isEmpty) {
      found.add((
        kind: ConceptKind.pawnChainCreate,
        object: m.to,
        evidence: 'the pawn on ${m.to.name} joins a chain',
      ));
    }
    // A pawn that captures is taking, not offering.
    if (phase == GamePhase.opening &&
        m.taken == null &&
        exchangeLoss(m.board, m.to, m.mover) > 0) {
      found.add((
        kind: ConceptKind.gambit,
        object: m.to,
        evidence: 'offers the pawn on ${m.to.name}',
      ));
    }
  }
  return found;
}

bool _isPassed(Board board, Square square, Side side) {
  final enemy = board.pawns.intersect(board.bySide(side.opposite));
  final rank = _relativeRank(side, square);
  for (final p in enemy.squares) {
    if ((p.file - square.file).abs() <= 1 && _relativeRank(side, p) > rank) {
      return false;
    }
  }
  return true;
}

SquareSet _passed(Board board, Side side) => SquareSet.fromSquares([
  for (final s in board.pawns.intersect(board.bySide(side)).squares)
    if (_isPassed(board, s, side)) s,
]);

/// The squares a pawn of [side] on [square] still has to cross, nearest first.
List<Square> _pathAhead(Square square, Side side) {
  final path = <Square>[];
  var s = square.offset(side == Side.white ? 8 : -8);
  while (s != null) {
    path.add(s);
    s = s.offset(side == Side.white ? 8 : -8);
  }
  return path;
}

SquareSet _doubledFiles(Board board, Side side) {
  final pawns = board.pawns.intersect(board.bySide(side));
  return SquareSet.fromSquares([
    for (final file in File.values)
      if (pawns.intersect(SquareSet.fromFile(file)).size >= 2)
        Square.fromCoords(file, Rank.first),
  ]);
}

SquareSet _isolated(Board board, Side side) {
  final pawns = board.pawns.intersect(board.bySide(side));
  return SquareSet.fromSquares([
    for (final p in pawns.squares)
      if (!_neighbourFiles(p.file).isIntersected(pawns)) p,
  ]);
}

/// Pawns whose neighbours have all advanced past them and whose stop square
/// an enemy pawn attacks.
SquareSet _backward(Board board, Side side) {
  final pawns = board.pawns.intersect(board.bySide(side));
  final enemy = board.pawns.intersect(board.bySide(side.opposite));
  return SquareSet.fromSquares([
    for (final p in pawns.squares)
      if (_neighbourFiles(p.file).intersect(pawns).isNotEmpty &&
          _neighbourFiles(p.file)
              .intersect(pawns)
              .squares
              .every((n) => _relativeRank(side, n) > _relativeRank(side, p)) &&
          switch (p.offset(side == Side.white ? 8 : -8)) {
            final Square stop => pawnAttacks(side, stop).isIntersected(enemy),
            null => false,
          })
        p,
  ]);
}

SquareSet _neighbourFiles(File file) {
  var set = SquareSet.empty;
  for (final d in const [-1, 1]) {
    final f = file.value + d;
    if (f >= 0 && f <= 7) set = set.union(SquareSet.fromFile(File(f)));
  }
  return set;
}

// ---- Lines ----

bool _isSlider(Role role) =>
    role == Role.bishop || role == Role.rook || role == Role.queen;

/// Whether pinning the piece on [front] to the slider on [pinner] stops
/// anything. A pawn is held only if it loses a push, a capture or the
/// defence of a piece off the pin line: a pawn pinned along its own file
/// with nothing beside it was never doing anything.
bool _pinHolds(Board board, Square front, Square pinner) {
  final piece = board.pieceAt(front)!;
  if (piece.role != Role.pawn) return true;
  final line = ray(pinner, front);
  final push = front.offset(piece.color == Side.white ? 8 : -8);
  final reach = [
    if (push != null && !board.occupied.has(push)) push,
    ...pawnAttacks(piece.color, front).intersect(board.occupied).squares,
  ];
  return reach.any((s) => !line.has(s));
}

int _kingValue(Role role) => role == Role.king ? 99 : valueOf(role);

/// For each line the slider on [square] attacks: the first enemy piece it
/// hits and the enemy piece right behind it, when there is one.
List<(Square, Square)> _lineUps(Board board, Square square) {
  final piece = board.pieceAt(square)!;
  final enemy = board.bySide(piece.color.opposite);
  final pairs = <(Square, Square)>[];
  for (final front in attacks(
    piece,
    square,
    board.occupied,
  ).intersect(enemy).squares) {
    final line = ray(square, front);
    final through = attacks(
      piece,
      square,
      board.occupied.withoutSquare(front),
    ).intersect(line).diff(between(square, front)).withoutSquare(front);
    final behind = through.intersect(board.occupied);
    for (final back in behind.squares) {
      // Only the next piece past [front], on the far side of it.
      if (between(square, back).intersect(board.occupied).size != 1) continue;
      if (!between(square, back).has(front)) continue;
      if (enemy.has(back)) pairs.add((front, back));
    }
  }
  return pairs;
}

/// [side]'s pieces pinned by an enemy slider to something worth more
/// (the king included), by any slider but the one on [except]. A pawn
/// counts only when the pin stops something ([_pinHolds]).
Set<Square> _pinnedPieces(Board board, Side side, {Square? except}) {
  final pinned = <Square>{};
  final sliders = board
      .bySide(side.opposite)
      .intersect(board.bishopsAndQueens | board.rooksAndQueens);
  for (final s in sliders.squares) {
    if (s == except) continue;
    final value = valueOf(board.pieceAt(s)!.role);
    for (final (front, back) in _lineUps(board, s)) {
      final backValue = _kingValue(board.pieceAt(back)!.role);
      if (backValue > _kingValue(board.pieceAt(front)!.role) &&
          (backValue > value || board.pieceAt(back)!.role == Role.king) &&
          _pinHolds(board, front, s)) {
        pinned.add(front);
      }
    }
  }
  return pinned;
}

Square _mostValuable(Board board, List<Square> squares) => squares.reduce(
  (a, b) => valueOf(board.pieceAt(a)!.role) >= valueOf(board.pieceAt(b)!.role)
      ? a
      : b,
);

/// 0 for [side]'s back rank, 7 for the opponent's.
int _relativeRank(Side side, Square square) =>
    side == Side.white ? square.rank.value : 7 - square.rank.value;
