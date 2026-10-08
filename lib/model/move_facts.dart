/// What is TRUE about one move, read off the board, for the LLM prompt.
/// Pure and board-only: no engine, no evals, no verdict.
///
/// The sentences are for a reader and may be reworded freely. Material is
/// named in pieces, never in centipawns.
library;

import 'package:dartchess/dartchess.dart';

import 'exchange.dart';
import 'material_balance.dart';
import 'sides.dart';

/// Facts about [move] played in [before]. [replyUci] is the opponent's best
/// answer when known. Empty for an illegal move.
List<String> moveFacts({
  required Position before,
  required Move move,
  required String san,
  String? replyUci,
}) {
  if (!before.isLegal(move)) return const [];
  final mover = before.turn;
  final after = before.play(move);

  final facts = <String>[
    ?_castling(before, move, san),
    ?_capture(before, move),
    ?_gameState(after),
    ?_promotionTarget(move),
  ];

  // Nothing about a finished game beyond the result: after mate, the mated
  // king "attacks" the mating piece.
  final landing = after.isGameOver ? null : landingSquare(before, move);
  if (landing != null) {
    facts
      ..addAll(_threats(after, landing, mover))
      ..addAll(_pins(after, landing, mover))
      ..addAll(
        _safetyOfMovedPiece(
          after,
          landing,
          mover,
          capturedValue: _capturedValue(before, move),
        ),
      )
      ..addAll(_leftLoose(before, after, mover, landing))
      ..addAll(_uncovered(before, after, move, mover));
  }

  facts.addAll(_reply(before, after, mover, replyUci, move));
  return facts;
}

// ---- Move geometry ----

/// Which side [move] castles to, or null when it is not castling. dartchess
/// encodes castling as king-takes-own-rook.
CastlingSide? castlingSide(Position before, Move move) {
  if (move is! NormalMove) return null;
  final piece = before.board.pieceAt(move.from);
  final onTarget = before.board.pieceAt(move.to);
  if (piece?.role != Role.king) return null;
  if (onTarget?.role != Role.rook || onTarget?.color != piece?.color) {
    return null;
  }
  return move.to.file > move.from.file ? CastlingSide.king : CastlingSide.queen;
}

/// Where the moved piece ends up: the king's real square when castling
/// (`move.to` is the rook's corner then), `move.to` otherwise.
Square? landingSquare(Position before, Move move) {
  if (move is! NormalMove) return null;
  final side = castlingSide(before, move);
  if (side == null) return move.to;
  return kingCastlesTo(before.board.pieceAt(move.from)!.color, side);
}

/// The square [move] captures ON, or null. Not `move.to` for en passant,
/// which lands behind the pawn it takes.
Square? capturedSquare(Position before, Move move) {
  if (move is! NormalMove) return null;
  if (castlingSide(before, move) != null) return null;
  if (before.board.pieceAt(move.to) != null) return move.to;

  final moved = before.board.pieceAt(move.from);
  if (moved?.role == Role.pawn && move.from.file != move.to.file) {
    return Square.fromCoords(move.to.file, move.from.rank);
  }
  return null;
}

// ---- What was played ----

/// The bare route ("Bb4 is the bishop from d2 to b4") is left out: a model
/// reads it back as the explanation. Castling is not obvious from the SAN.
String? _castling(Position before, Move move, String san) {
  final side = castlingSide(before, move);
  if (side == null) return null;
  final to = landingSquare(before, move)!;
  return '$san castles ${side == CastlingSide.king ? 'kingside' : 'queenside'}, '
      'putting the king on ${to.name}.';
}

String? _promotionTarget(Move move) {
  if (move is! NormalMove || move.promotion == null) return null;
  return 'The pawn promotes to a ${move.promotion!.name} on ${move.to.name}.';
}

String? _capture(Position before, Move move) {
  final taken = capturedSquare(before, move);
  if (taken == null) return null;
  final piece = before.board.pieceAt(taken)!;
  final how = taken == (move as NormalMove).to ? '' : ' en passant';
  return 'It captures the ${_describe(piece)} on ${taken.name}$how.';
}

String? _gameState(Position after) {
  if (after.isCheckmate) return 'It is checkmate.';
  if (after.isStalemate) return 'It is stalemate.';
  if (after.isCheck) return 'It gives check.';
  return null;
}

// ---- What the move does to the board ----

/// Enemy pieces the moved piece now attacks — only those worth more than it,
/// or undefended — and whether that is a fork.
List<String> _threats(Position after, Square landing, Side mover) {
  final piece = after.board.pieceAt(landing);
  if (piece == null) return const [];

  final targets = <Square>[];
  for (final square in attacks(piece, landing, after.board.occupied).squares) {
    final target = after.board.pieceAt(square);
    if (target == null || target.color == mover) continue;
    if (target.role == Role.king) continue; // check is stated on its own
    if (valueOf(target.role) > valueOf(piece.role) ||
        _isLoose(after.board, square, target.color)) {
      targets.add(square);
    }
  }
  if (targets.isEmpty) return const [];

  final named = [
    for (final square in targets)
      'the ${_describe(after.board.pieceAt(square)!)} on ${square.name}',
  ];
  final verb = targets.length == 1 ? 'attacks' : 'forks';
  return [
    'The ${piece.role.name} on ${landing.name} $verb ${joinWithAnd(named)}.',
  ];
}

/// A pin the move creates: one enemy piece between the moved slider and the
/// enemy king (absolute) or a more valuable queen (relative).
List<String> _pins(Position after, Square landing, Side mover) {
  final piece = after.board.pieceAt(landing);
  if (piece == null || !isSlider(piece.role)) return const [];

  final behind = <Square>[
    ?after.board.kingOf(mover.opposite),
    ...after.board.piecesOf(mover.opposite, Role.queen).squares,
  ];
  // Reach on an empty board: whether this piece moves along that line at all.
  final lines = attacks(piece, landing, SquareSet.empty);

  for (final target in behind) {
    if (!lines.has(target)) continue;
    final blockers = between(
      landing,
      target,
    ).squares.where(after.board.occupied.has).toList();
    if (blockers.length != 1) continue;

    final pinned = after.board.pieceAt(blockers.single)!;
    if (pinned.color == mover) continue;
    final backing = after.board.pieceAt(target)!;
    if (backing.role != Role.king &&
        valueOf(pinned.role) >= valueOf(backing.role)) {
      continue;
    }
    return [
      'It pins the ${_describe(pinned)} on ${blockers.single.name} to the '
          '${backing.role.name} on ${target.name}.',
    ];
  }
  return const [];
}

/// What [move] captures, in pawns; 0 for a quiet move.
int _capturedValue(Position before, Move move) {
  final taken = capturedSquare(before, move);
  return taken == null ? 0 : valueOf(before.board.pieceAt(taken)!.role);
}

/// Whether the piece that just moved can be taken, and for what. After a
/// capture that can be taken back, the trade is what is stated — "nothing
/// defending it" on its own reads as a piece given away.
List<String> _safetyOfMovedPiece(
  Position after,
  Square landing,
  Side mover, {
  int capturedValue = 0,
}) {
  final piece = after.board.pieceAt(landing);
  if (piece == null || piece.role == Role.king) return const [];

  final defenders = after.board.attacksTo(landing, mover);
  // A king cannot capture a defended piece.
  final attackers = defenders.isEmpty
      ? after.board.attacksTo(landing, mover.opposite)
      : after.board.attacksTo(landing, mover.opposite).diff(after.board.kings);
  final cheapest = cheapestAttacker(after.board, attackers);
  if (cheapest == null) return const [];
  final attacker = after.board.pieceAt(cheapest)!;

  final where = 'The ${piece.role.name} on ${landing.name}';
  if (capturedValue > 0) {
    final recapture = staticExchange(after.board, landing, mover.opposite);
    if (recapture > 0) {
      final taker = 'the ${_describe(attacker)} on ${cheapest.name}';
      final net = capturedValue - recapture;
      if (net == 0) {
        return [
          'It can be taken back by $taker, which makes it an even trade.',
        ];
      }
      return [
        net > 0
            ? 'Even if $taker takes back on ${landing.name}, '
                  '${sideName(mover)} comes out ahead.'
            : 'If $taker takes back on ${landing.name}, '
                  '${sideName(mover)} loses more than it took.',
      ];
    }
  }
  if (defenders.isEmpty) {
    return [
      '$where is attacked by the ${_describe(attacker)} '
          'on ${cheapest.name} and has nothing defending it.',
    ];
  }
  if (valueOf(attacker.role) < valueOf(piece.role)) {
    return [
      '$where can be taken by the ${_describe(attacker)} '
          'on ${cheapest.name}, which is worth less than it.',
    ];
  }
  return [
    '$where is attacked ${_times(attackers.size)} and defended '
        '${_times(defenders.size)}.',
  ];
}

/// The mover's pieces this move left attacked and undefended when they were
/// safe before it. At most two.
List<String> _leftLoose(
  Position before,
  Position after,
  Side mover,
  Square landing,
) {
  final facts = <String>[];
  for (final square in after.board.bySide(mover).squares) {
    if (square == landing) continue; // covered by _safetyOfMovedPiece
    final piece = after.board.pieceAt(square)!;
    if (piece.role == Role.king) continue;
    if (!_isLoose(after.board, square, mover)) continue;
    if (_isLoose(before.board, square, mover)) continue;
    facts.add(
      'It leaves the ${piece.role.name} on ${square.name} attacked '
      'with nothing defending it.',
    );
    if (facts.length == 2) break;
  }
  return facts;
}

/// A discovered attack: a slider of the mover's that did NOT move now sees a
/// worthwhile target it could not see before. Castling is skipped — it moves
/// two pieces, so neither is "uncovered".
List<String> _uncovered(
  Position before,
  Position after,
  Move move,
  Side mover,
) {
  if (move is! NormalMove) return const [];
  if (castlingSide(before, move) != null) return const [];

  for (final square in after.board.bySide(mover).squares) {
    final piece = after.board.pieceAt(square)!;
    if (!isSlider(piece.role)) continue;
    if (before.board.pieceAt(square) != piece) continue;

    final now = attacks(piece, square, after.board.occupied);
    final was = attacks(piece, square, before.board.occupied);
    for (final target in now.squares) {
      if (was.has(target)) continue;
      final victim = after.board.pieceAt(target);
      if (victim == null || victim.color == mover) continue;
      if (valueOf(victim.role) < valueOf(piece.role) &&
          !_isLoose(after.board, target, victim.color)) {
        continue;
      }
      return [
        'Moving off ${move.from.name} uncovers the ${piece.role.name} '
            'on ${square.name} against the ${_describe(victim)} '
            'on ${target.name}.',
      ];
    }
  }
  return const [];
}

// ---- What comes back ----

/// The opponent's best answer, and the material balance over the two moves.
List<String> _reply(
  Position before,
  Position after,
  Side mover,
  String? replyUci,
  Move move,
) {
  final reply = replyUci == null ? null : Move.parse(replyUci);
  if (reply == null || !after.isLegal(reply)) return const [];

  final (settled, replySan) = after.makeSan(reply);
  final takenOn = capturedSquare(after, reply);
  final taken = takenOn == null ? null : after.board.pieceAt(takenOn);
  final opponent = sideName(mover.opposite);
  final facts = <String>[
    taken == null
        ? '$opponent answers $replySan.'
        : '$opponent answers $replySan, taking the '
              '${_describe(taken)} on ${takenOn!.name}.',
  ];

  // A promotion changes the piece count without a trade.
  if (move is NormalMove && move.promotion != null) return facts;

  // Mid-exchange the count means nothing: "a bishop for nothing" would be
  // said of a bishop about to be taken back.
  if (taken != null && staticExchange(settled.board, reply.to, mover) > 0) {
    facts.add('${sideName(mover)} can take back on ${reply.to.name}.');
    return facts;
  }

  final lost = _rolesLost(before.board, settled.board, mover);
  final won = _rolesLost(before.board, settled.board, mover.opposite);
  if (lost.isEmpty && won.isEmpty) return facts;

  final side = sideName(mover);
  if (lost.isEmpty) {
    facts.add('Over those two moves $side wins ${_roles(won)}.');
  } else if (won.isEmpty) {
    facts.add(
      'Over those two moves $side gives up ${_roles(lost)} '
      'for nothing in return.',
    );
  } else {
    final even = _value(lost) == _value(won);
    facts.add(
      'Over those two moves $side ${even ? 'trades' : 'gives up'} '
      '${_roles(lost)} for ${_roles(won)}.',
    );
  }
  return facts;
}

int _value(List<Role> roles) =>
    roles.fold(0, (sum, role) => sum + valueOf(role));

/// The pieces [side] no longer has, role for role.
List<Role> _rolesLost(Board before, Board after, Side side) => [
  for (final role in Role.values)
    for (
      var i = 0;
      i < before.piecesOf(side, role).size - after.piecesOf(side, role).size;
      i++
    )
      role,
];

// ---- Helpers ----

/// Attacked by the opponent and defended by nothing. A plain count that
/// ignores pins and exchange order — hence "facts are true", never "complete".
bool _isLoose(Board board, Square square, Side owner) =>
    board.attacksTo(square, owner.opposite).isNotEmpty &&
    board.attacksTo(square, owner).isEmpty;

/// Bishop, rook or queen: a piece that attacks along a line.
bool isSlider(Role role) =>
    role == Role.bishop || role == Role.rook || role == Role.queen;

String _describe(Piece piece) => '${piece.color.name} ${piece.role.name}';

String _times(int count) => count == 1 ? 'once' : '$count times';

/// "a knight", "a rook and two pawns".
String _roles(List<Role> roles) {
  final counts = <Role, int>{};
  for (final role in roles) {
    counts[role] = (counts[role] ?? 0) + 1;
  }
  return joinWithAnd([
    for (final MapEntry(key: role, value: n) in counts.entries)
      n == 1 ? 'a ${role.name}' : '${numberWord(n)} ${role.name}s',
  ]);
}

/// "two" to "five", digits past that.
String numberWord(int n) =>
    const {2: 'two', 3: 'three', 4: 'four', 5: 'five'}[n] ?? '$n';

/// "a", "a and b", "a, b and c". [parts] must not be empty.
String joinWithAnd(List<String> parts) {
  if (parts.length == 1) return parts.single;
  return '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}
