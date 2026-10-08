/// The tactics in an engine line, named the way lichess's puzzle tagger
/// names them (`tagger/cook.py` + `tagger/util.py` in lichess-puzzler), so
/// the LLM is TOLD "fork" instead of guessing it. Pure and board-only apart
/// from the line itself.
///
/// The tagger reads a puzzle: one setup move (the blunder), then the
/// solution. Here the solution is an engine PV, so the rules are ported as
/// written and their quirks kept; only moves the side playing the line makes
/// are tested for a motif.
library;

import 'package:dartchess/dartchess.dart';

import 'exchange.dart';
import 'material_balance.dart';
import 'move_facts.dart'
    show
        capturedSquare,
        castlingSide,
        isSlider,
        joinWithAnd,
        landingSquare,
        numberWord;

/// A tactic named in a line.
enum Motif {
  mate('mate'),
  backRankMate('back-rank mate'),
  hangingPiece('hanging piece'),
  fork('fork'),
  pin('pin'),
  skewer('skewer'),
  discoveredAttack('discovered attack'),
  trappedPiece('trapped piece');

  const Motif(this.label);

  final String label;

  bool get isMate => this == mate || this == backRankMate;
}

/// What one engine line does, from the side playing it (the side to move at
/// its start).
class LineReading {
  const LineReading({
    this.motifs = const {},
    this.won = const [],
    this.gave = const [],
    this.hung,
    this.pays = false,
  });

  static const none = LineReading();

  /// Tactics in the line. Only filled when the line [pays], so a pin that
  /// leads nowhere is never named.
  final Set<Motif> motifs;

  /// Pieces the opponent is down by the line's last settled position, most
  /// valuable first. Equal trades cancel out.
  final List<Role> won;

  /// Pieces the side playing the line gave for them.
  final List<Role> gave;

  /// The piece left hanging, when [Motif.hangingPiece] is set.
  final Role? hung;

  /// The line mates, or wins enough to be worth saying. Without it [won] and
  /// [gave] are only what the line happened to count.
  final bool pays;

  int get gain => _gainOf((won, gave));

  bool get mates => motifs.any((motif) => motif.isMate);

  bool get winsMaterial => pays && gain > 0;

  bool get isEmpty => !pays;

  /// The tactics other than the mate itself, in [Motif] order.
  List<Motif> get tactics => [
    for (final motif in Motif.values)
      if (!motif.isMate &&
          motif != Motif.hangingPiece &&
          motifs.contains(motif))
        motif,
  ];
}

/// The two lines around a played move.
class MoveTags {
  const MoveTags({
    this.allowed = LineReading.none,
    this.missed = LineReading.none,
    this.ledger = const [],
  });

  static const none = MoveTags();

  /// The engine's line after the move, read from the OPPONENT's side: what
  /// the move let them do.
  final LineReading allowed;

  /// The engine's line from before the move, read from the mover's side:
  /// what the better move would have done. Empty when the move was the
  /// engine's.
  final LineReading missed;

  /// Each exchange of the played line and where material stands after it,
  /// as far as [allowed] trusts the line.
  final List<LedgerEntry> ledger;
}

/// One exchange of a line: its captures in numbered SAN, and where material
/// stands once it settles, against the position before the move.
class LedgerEntry {
  const LedgerEntry(this.moves, this.standing);

  /// "17.Bxd5 exd5".
  final String moves;

  /// "level", "White is up a pawn", "Black has a knight for a pawn".
  final String standing;

  bool get isLevel => standing == 'level';

  @override
  String toString() => '$moves: $standing';
}

/// The longest line read, in plies from the position before the move: the
/// played move and a full PV.
const int maxLinePlies = 11;

/// How far a material count may run ahead of the engine's own verdict, in
/// pawns. Piece values are rough, so some slack; past it the count comes
/// from moves nobody is forced into, and the line is cut there.
const double evalSlack = 1.5;

/// Reads [pvUci] from [start], material counted from [start]. The move that
/// led to [start] is unknown, so the rules that look back at it assume
/// nothing was traded.
LineReading readLine({required Position start, required List<String> pvUci}) {
  final line = _Line.replay(start, pvUci, maxLinePlies);
  if (line.plies.isEmpty) return LineReading.none;
  final end = _checkpoints(line).lastOrNull?.$2;
  final (won, gave) = _roleDiff(start.board, end, line.pov);
  return _reading(line, won, gave, null, null);
}

/// Both lines around [played] in [before], each measured from [before] so a
/// capture and its recapture cancel out. [refutationUci] is the engine's line
/// after the move; [betterUci] the engine's line from [before], read only
/// when it does not start with [played]. [previous] is the move that led to
/// [before], played in [beforePrevious].
///
/// `allowed` is what the opponent comes out ahead by, against [before].
/// `missed` is what the better line wins against [before], named only when
/// it also ends ahead of the PLAYED line — or a recapture both moves make
/// reads as a miss.
///
/// [evalDrop] is what the engine says the move cost, in pawns for the
/// mover. With it, each line is cut at the first count the engine does not
/// back (more than [evalSlack] past the drop), and a single pawn is worth
/// naming. Without it the whole line counts and a sacrifice's worth is the
/// bar.
MoveTags tagMove({
  required Position before,
  required Move played,
  required List<String> refutationUci,
  List<String> betterUci = const [],
  Move? previous,
  Position? beforePrevious,
  double? evalDrop,
}) {
  if (!before.isLegal(played)) return MoveTags.none;
  final mover = before.turn;
  final limit = evalDrop == null ? null : evalDrop + evalSlack;
  final minGain = evalDrop == null ? sacrificeThreshold : 1;

  // The played line, cut where the opponent's gain outruns the engine.
  final playedLine = _Line.replay(before, [
    played.uci,
    ...refutationUci,
  ], maxLinePlies);
  final (playedPlies, playedEnd) = _lastBacked(
    _checkpoints(playedLine, upTo: _voluntaryLoss(playedLine, mover)),
    (board) => _gainOf(_roleDiff(before.board, board, mover.opposite)),
    limit,
  );
  final refutation = _Line.replay(
    before.play(played),
    refutationUci,
    playedPlies > 0 ? playedPlies - 1 : 0,
  );
  final (lost, tookBack) = _roleDiff(before.board, playedEnd, mover.opposite);
  final allowed = _reading(
    refutation,
    lost,
    tookBack,
    played,
    before,
    minGain: minGain,
  );
  final ledger = _ledger(playedLine, playedPlies, before.board);

  final isBetter = betterUci.isNotEmpty && betterUci.first != played.uci;
  if (!isBetter) {
    return MoveTags(allowed: allowed, ledger: ledger);
  }
  final betterLine = _Line.replay(before, betterUci, maxLinePlies);
  final (betterPlies, betterEnd) = _lastBacked(
    _checkpoints(betterLine, upTo: _voluntaryLoss(betterLine, mover.opposite)),
    (board) => _gainOf(_roleDiff(playedEnd, board, mover)),
    limit,
  );
  // Named only when it is a real gain: ahead of the played line AND of
  // [before]. Merely not losing what `allowed` lost is not a miss.
  // Worded against [before] — "wins the queen for a rook" — since a diff of
  // two end positions reads as nonsense ("two rooks for a queen").
  final real = _roleDiff(before.board, betterEnd, mover);
  final ahead = _gainOf(_roleDiff(playedEnd, betterEnd, mover));
  final (won, gave) = ahead >= minGain && _gainOf(real) >= minGain
      ? real
      : (const <Role>[], const <Role>[]);
  return MoveTags(
    allowed: allowed,
    missed: _reading(
      _Line.replay(before, betterUci, betterPlies),
      won,
      gave,
      previous,
      beforePrevious,
      minGain: minGain,
    ),
    ledger: ledger,
  );
}

/// The motifs of [line], kept only when the line pays off: it mates, or
/// [won] outweighs [gave] by [minGain].
LineReading _reading(
  _Line line,
  List<Role> won,
  List<Role> gave,
  Move? setup,
  Position? beforeSetup, {
  int minGain = sacrificeThreshold,
}) {
  final mate = line.plies.isNotEmpty && _endsInMate(line);
  final pays = mate || _gainOf((won, gave)) >= minGain;
  if (!pays) return LineReading(won: won, gave: gave);

  final hung = line.plies.isEmpty
      ? null
      : _hangingPiece(line, setup, beforeSetup);
  return LineReading(
    motifs: {
      if (mate) Motif.mate,
      if (mate && _backRankMate(line)) Motif.backRankMate,
      if (hung != null) Motif.hangingPiece,
      if (_fork(line)) Motif.fork,
      if (_pinPreventsAttack(line) || _pinPreventsEscape(line)) Motif.pin,
      if (_skewer(line)) Motif.skewer,
      if (_discoveredAttack(line)) Motif.discoveredAttack,
      if (_trappedPiece(line)) Motif.trappedPiece,
    },
    won: won,
    gave: gave,
    hung: hung,
    pays: true,
  );
}

/// True when [move] captures and the best the opponent can do on that
/// square is take back exactly what was taken: an even trade, not a loss.
bool startsEvenTrade(Position before, Move move) {
  final taken = capturedSquare(before, move);
  if (taken == null || !before.isLegal(move)) return false;
  final after = before.play(move);
  final landing = landingSquare(before, move)!;
  final took = valueOf(before.board.pieceAt(taken)!.role);
  return staticExchange(after.board, landing, after.turn) == took;
}

// ---- The line ----

class _Ply {
  const _Ply(this.before, this.move, this.after, this.san);

  final Position before;
  final Move move;
  final Position after;
  final String san;

  /// Where the moved piece stands now — the king's square when castling.
  Square get to => landingSquare(before, move)!;

  Square get from => (move as NormalMove).from;

  Role get movedRole => after.board.pieceAt(to)!.role;

  /// The enemy piece this move takes on [to], if any. En passant takes
  /// elsewhere and is not counted, as in the tagger.
  Piece? get takenOnTo {
    final piece = before.board.pieceAt(to);
    return piece != null && piece.color != before.turn ? piece : null;
  }

  bool get isCapture => capturedSquare(before, move) != null;

  bool get isCastling => castlingSide(before, move) != null;

  /// Material is not counted here: this took something that can be won
  /// straight back.
  bool get isPending =>
      isCapture &&
      !after.isCheckmate &&
      staticExchange(after.board, to, after.turn) > 0;
}

class _Line {
  _Line(this.start, this.plies);

  factory _Line.replay(Position start, List<String> pvUci, int maxPlies) {
    final plies = <_Ply>[];
    var position = start;
    for (final uci in pvUci.take(maxPlies)) {
      final move = Move.parse(uci);
      if (move is! NormalMove || !position.isLegal(move)) break;
      final (next, san) = position.makeSan(move);
      plies.add(_Ply(position, move, next, san));
      position = next;
      if (next.isGameOver) break;
    }
    return _Line(start, plies);
  }

  final Position start;
  final List<_Ply> plies;

  /// The side playing the line: the tagger's `pov`.
  Side get pov => start.turn;

  /// The pov's own moves, with their indexes into [plies] — the tagger's
  /// `mainline[1::2]`.
  Iterable<(int, _Ply)> get povMoves sync* {
    for (var i = 0; i < plies.length; i += 2) {
      yield (i, plies[i]);
    }
  }
}

// ---- Material ----

/// Every SETTLED position of [line] — the last move took nothing, or took
/// something that cannot be won back — as (plies played, board). The start
/// counts as settled with no plies played.
List<(int, Board)> _checkpoints(_Line line, {int? upTo}) => [
  (0, line.start.board),
  for (final (i, ply) in line.plies.take(upTo ?? line.plies.length).indexed)
    if (!ply.isPending) (i + 1, ply.after.board),
];

/// How many plies of [line] come before [giver] hands material over by
/// choice: a quiet move, not out of check, by a piece that was not in
/// trouble where it stood, onto a square the next move takes on at a profit.
/// Past that the loss is [giver]'s decision, not something forced on them —
/// the engine's line gives a knight for play, and the move before is not to
/// blame for it. The line's first move never counts: that IS the move.
int _voluntaryLoss(_Line line, Side giver) {
  for (var i = 1; i + 1 < line.plies.length; i++) {
    final ply = line.plies[i];
    if (ply.before.turn != giver || ply.isCapture) continue;
    if (ply.before.isCheck) continue;
    if (_isInBadSpot(ply.before.board, ply.from)) continue;
    // Taken and simply retaken is a trade, not a gift.
    if (staticExchange(ply.after.board, ply.to, giver.opposite) <= 0) continue;
    if (capturedSquare(line.plies[i + 1].before, line.plies[i + 1].move) ==
        ply.to) {
      return i;
    }
  }
  return line.plies.length;
}

/// The checkpoint a line's material is read at, as (plies played, board):
/// the last one before a [gain] above [limit] (every checkpoint with no
/// [limit]), then — if the gain slips back later in the line — the later,
/// smaller one. Only material that STAYS won is claimed; a piece given back
/// for a bishop two moves on was never lost.
(int, Board) _lastBacked(
  List<(int, Board)> checkpoints,
  int Function(Board) gain,
  double? limit,
) {
  var cut = 0;
  for (var i = 1; i < checkpoints.length; i++) {
    if (limit != null && gain(checkpoints[i].$2) > limit) break;
    cut = i;
  }
  var chosen = checkpoints[cut];
  for (final later in checkpoints.skip(cut + 1)) {
    if (gain(later.$2) < gain(chosen.$2)) chosen = later;
  }
  return chosen;
}

/// What [pov] is up by on [to] compared with [from], role for role, most
/// valuable first: roles the opponent has fewer of are won, roles [pov] has
/// fewer of are given. Equal trades cancel out, a knight for a bishop too.
/// Nothing when [to] is unknown.
(List<Role>, List<Role>) _roleDiff(Board from, Board? to, Side pov) {
  if (to == null) return (const <Role>[], const <Role>[]);
  final won = <Role>[];
  final gave = <Role>[];
  for (final role in rolesByValue) {
    if (role == Role.king) continue;
    final theirLoss =
        from.piecesOf(pov.opposite, role).size -
        to.piecesOf(pov.opposite, role).size;
    final ourLoss = from.piecesOf(pov, role).size - to.piecesOf(pov, role).size;
    final net = theirLoss - ourLoss;
    for (var i = 0; i < net.abs(); i++) {
      (net > 0 ? won : gave).add(role);
    }
  }
  // A knight for a bishop is no gain either way.
  for (final role in [...won]) {
    final even = gave.indexWhere((g) => valueOf(g) == valueOf(role));
    if (even < 0) continue;
    gave.removeAt(even);
    won.remove(role);
  }
  return (won, gave);
}

int _gainOf((List<Role>, List<Role>) diff) =>
    diff.$1.fold(0, (sum, role) => sum + valueOf(role)) -
    diff.$2.fold(0, (sum, role) => sum + valueOf(role));

/// One clause per exchange in the first [plies] of [line]: its captures in
/// numbered SAN and where material stands, against [from], once it settles.
/// Quiet moves are left out; an exchange still open at the cut is dropped.
List<LedgerEntry> _ledger(_Line line, int plies, Board from) {
  final start = line.start;
  final startPly = start.fullmoves * 2 - (start.turn == Side.white ? 2 : 1);
  final clauses = <LedgerEntry>[];
  int? firstCapture;
  for (final (i, ply) in line.plies.take(plies).indexed) {
    if (ply.isCapture) {
      firstCapture ??= i;
    }
    if (firstCapture == null || ply.isPending) continue;
    final moves = _numbered(line.plies, firstCapture, i, startPly);
    clauses.add(LedgerEntry(moves, _standing(from, ply.after.board)));
    firstCapture = null;
  }
  return clauses;
}

/// The captures of plies [first]..[last] in numbered SAN: "17.Bxd5 exd5".
String _numbered(List<_Ply> plies, int first, int last, int startPly) {
  final parts = <String>[];
  for (var i = first; i <= last; i++) {
    if (!plies[i].isCapture) continue;
    final ply = startPly + i + 1;
    final number = (ply + 1) ~/ 2;
    parts.add(
      ply.isOdd
          ? '$number.${plies[i].san}'
          : (parts.isEmpty ? '$number...${plies[i].san}' : plies[i].san),
    );
  }
  return parts.join(' ');
}

/// "level", "White is up a pawn", "Black has a knight for a pawn".
String _standing(Board from, Board to) {
  final (won, gave) = _roleDiff(from, to, Side.white);
  final gain = _gainOf((won, gave));
  if (gain == 0) return 'level';
  final (leader, up, down) = gain > 0
      ? ('White', won, gave)
      : ('Black', gave, won);
  if (down.isEmpty) {
    return '$leader is up ${describeRoles(up, definite: false)}';
  }
  return '$leader has ${describeRoles(up, definite: false)} '
      'for ${describeRoles(down, definite: false)}';
}

// ---- Motifs (cook.py) ----

bool _endsInMate(_Line line) {
  final last = line.plies.last.after;
  return last.isCheckmate && last.turn == line.pov.opposite;
}

/// `back_rank_mate`: the mated king on its back rank, walled in by its own
/// unattacked pieces, checked along that rank.
bool _backRankMate(_Line line) {
  final board = line.plies.last.after.board;
  final defender = line.pov.opposite;
  final king = board.kingOf(defender);
  if (king == null) return false;
  final backRank = defender == Side.white ? 0 : 7;
  if (king.rank != backRank) return false;

  final forward = defender == Side.white ? 1 : -1;
  final front = [
    for (final df in [-1, 0, 1])
      if (king.file + df >= 0 && king.file + df <= 7)
        Square.fromCoords(File(king.file + df), Rank(backRank + forward)),
  ];
  for (final square in front) {
    final piece = board.pieceAt(square);
    if (piece == null || piece.color == line.pov) return false;
    if (board.attacksTo(square, line.pov).isNotEmpty) return false;
  }
  return line.plies.last.after.checkers.squares.any(
    (checker) => checker.rank == backRank,
  );
}

/// `hanging_piece`: the first move takes an undefended non-pawn piece that
/// was not just part of a trade, and the gain is kept a move later. Returns
/// the role taken.
Role? _hangingPiece(_Line line, Move? setup, Position? beforeSetup) {
  final first = line.plies.first;
  final captured = first.takenOnTo;
  if (captured == null || captured.role == Role.pawn) return null;
  if (!_isHanging(line.start.board, captured, first.to)) return null;

  if (setup is NormalMove && beforeSetup != null && setup.to == first.to) {
    final setupTook = beforeSetup.board.pieceAt(setup.to);
    if (setupTook != null &&
        valueOf(setupTook.role) >= valueOf(captured.role)) {
      return null;
    }
  }
  if (line.plies.length < 3) return captured.role;
  final kept =
      materialFor(line.plies[2].after.board, line.pov) >=
      materialFor(first.after.board, line.pov);
  return kept ? captured.role : null;
}

/// `fork`: a non-king move, not itself en prise, that attacks two non-pawn
/// pieces each worth more than it or hanging. The line's last pov move is
/// not counted.
bool _fork(_Line line) {
  final moves = line.povMoves.toList();
  for (final (_, ply) in moves.take(moves.length - 1)) {
    if (ply.movedRole == Role.king) continue;
    final board = ply.after.board;
    if (_isInBadSpot(board, ply.to)) continue;

    final moved = board.pieceAt(ply.to)!;
    var targets = 0;
    for (final square in attacks(moved, ply.to, board.occupied).squares) {
      final piece = board.pieceAt(square);
      if (piece == null || piece.color == line.pov) continue;
      if (piece.role == Role.pawn) continue;
      if (_kingValue(piece.role) > _kingValue(moved.role) ||
          (_isHanging(board, piece, square) &&
              !board.attacksTo(ply.to, line.pov.opposite).has(square))) {
        targets++;
      }
    }
    if (targets > 1) return true;
  }
  return false;
}

/// `pin_prevents_attack`: a pinned enemy piece cannot take a pov piece it
/// attacks off the pin line.
bool _pinPreventsAttack(_Line line) {
  for (final (_, ply) in line.povMoves) {
    final board = ply.after.board;
    for (final square in board.bySide(line.pov.opposite).squares) {
      final pinLine = _pinLine(board, square);
      if (pinLine == null) continue;
      final piece = board.pieceAt(square)!;
      for (final target in attacks(piece, square, board.occupied).squares) {
        final attacked = board.pieceAt(target);
        if (attacked == null || attacked.color != line.pov) continue;
        if (pinLine.has(target)) continue;
        if (valueOf(attacked.role) > valueOf(piece.role) ||
            _isHanging(board, attacked, target)) {
          return true;
        }
      }
    }
  }
  return false;
}

/// `pin_prevents_escape`: a pinned enemy piece, attacked along its pin by
/// something cheaper, or hanging with somewhere to go off the line.
bool _pinPreventsEscape(_Line line) {
  for (final (_, ply) in line.povMoves) {
    final board = ply.after.board;
    for (final pinned in board.bySide(line.pov.opposite).squares) {
      final pinLine = _pinLine(board, pinned);
      if (pinLine == null) continue;
      final pinnedPiece = board.pieceAt(pinned)!;
      for (final attacker in board.attacksTo(pinned, line.pov).squares) {
        if (!pinLine.has(attacker)) continue;
        final attackerPiece = board.pieceAt(attacker)!;
        if (valueOf(pinnedPiece.role) > valueOf(attackerPiece.role)) {
          return true;
        }
        if (_isHanging(board, pinnedPiece, pinned) &&
            !board.attacksTo(attacker, line.pov.opposite).has(pinned) &&
            _canStepOff(board, pinned, pinLine)) {
          return true;
        }
      }
    }
  }
  return false;
}

/// `skewer`: a slider takes a piece that was behind the one the opponent
/// just moved off the line, which was worth more and was en prise.
bool _skewer(_Line line) {
  for (final (i, ply) in line.povMoves.skip(1)) {
    final prev = line.plies[i - 1];
    final capture = ply.takenOnTo;
    if (capture == null || !isSlider(ply.movedRole)) continue;
    if (ply.after.isCheckmate) continue;

    final path = between(ply.from, ply.to);
    if (prev.to == ply.to || !path.has(prev.from)) continue;
    if (_kingValue(prev.movedRole) > _kingValue(capture.role) &&
        _isInBadSpot(prev.after.board, ply.to)) {
      return true;
    }
  }
  return false;
}

/// `discovered_attack`: a discovered check, or a capture along a line the
/// pov's previous move opened. Returns false outright on a recapture, as the
/// tagger does.
bool _discoveredAttack(_Line line) {
  for (final (_, ply) in line.povMoves) {
    final checkers = ply.after.checkers;
    if (checkers.isNotEmpty && !checkers.has(ply.to)) return true;
  }
  for (final (i, ply) in line.povMoves.skip(1)) {
    if (!ply.isCapture) continue;
    final prev = line.plies[i - 1];
    if (prev.to == ply.to) return false;
    final ownPrevious = line.plies[i - 2];
    if (between(ply.from, ply.to).has(ownPrevious.from) &&
        ply.to != ownPrevious.to &&
        ply.from != ownPrevious.to &&
        !ownPrevious.isCastling) {
      return true;
    }
  }
  return false;
}

/// `trapped_piece`: a non-pawn piece is taken that, a move earlier, had no
/// safe square to go to.
bool _trappedPiece(_Line line) {
  for (final (i, ply) in line.povMoves.skip(1)) {
    final captured = ply.takenOnTo;
    if (captured == null || captured.role == Role.pawn) continue;
    final prev = line.plies[i - 1];
    final square = prev.to == ply.to ? prev.from : ply.to;
    if (isTrapped(prev.before, square)) return true;
  }
  return false;
}

// ---- Helpers (util.py) ----

int _kingValue(Role role) => role == Role.king ? 99 : valueOf(role);

/// `is_defended`, including a defender behind an attacking slider.
bool _isDefended(Board board, Piece piece, Square square) {
  if (board.attacksTo(square, piece.color).isNotEmpty) return true;
  for (final attacker
      in board.attacksTo(square, piece.color.opposite).squares) {
    if (!isSlider(board.pieceAt(attacker)!.role)) continue;
    final without = board.removePieceAt(attacker);
    if (without.attacksTo(square, piece.color).isNotEmpty) return true;
  }
  return false;
}

bool _isHanging(Board board, Piece piece, Square square) =>
    !_isDefended(board, piece, square);

bool _canBeTakenByLowerPiece(Board board, Piece piece, Square square) {
  for (final attacker
      in board.attacksTo(square, piece.color.opposite).squares) {
    final role = board.pieceAt(attacker)!.role;
    if (role != Role.king && valueOf(role) < valueOf(piece.role)) return true;
  }
  return false;
}

/// `is_in_bad_spot`: attacked, and hanging or takeable by something cheaper.
bool _isInBadSpot(Board board, Square square) {
  final piece = board.pieceAt(square);
  if (piece == null) return false;
  if (board.attacksTo(square, piece.color.opposite).isEmpty) return false;
  return _isHanging(board, piece, square) ||
      _canBeTakenByLowerPiece(board, piece, square);
}

/// `is_trapped`, for the side to move in [position]: the piece on [square]
/// is attacked badly and every square it can reach is attacked badly too.
bool isTrapped(Position position, Square square) {
  final board = position.board;
  final piece = board.pieceAt(square);
  if (piece == null || piece.color != position.turn) return false;
  if (position.isCheck || _pinLine(board, square) != null) return false;
  if (piece.role == Role.pawn || piece.role == Role.king) return false;
  if (!_isInBadSpot(board, square)) return false;

  for (final to in position.legalMovesOf(square).squares) {
    final taken = board.pieceAt(to);
    if (taken != null && valueOf(taken.role) >= valueOf(piece.role)) {
      return false;
    }
    final escaped = position.play(NormalMove(from: square, to: to));
    if (!_isInBadSpot(escaped.board, to)) return false;
  }
  return true;
}

/// The whole line through [square] and its own king when the piece there is
/// pinned to that king by an enemy slider, else null. python-chess's
/// `Board.pin`.
SquareSet? _pinLine(Board board, Square square) {
  final piece = board.pieceAt(square);
  if (piece == null || piece.role == Role.king) return null;
  final king = board.kingOf(piece.color);
  if (king == null) return null;
  final line = ray(king, square);
  if (line.isEmpty) return null;

  final straight = king.file == square.file || king.rank == square.rank;
  final snipers = board
      .bySide(piece.color.opposite)
      .intersect(straight ? board.rooksAndQueens : board.bishopsAndQueens)
      .intersect(line);
  for (final sniper in snipers.squares) {
    final blockers = between(king, sniper).intersect(board.occupied);
    if (blockers.size == 1 && blockers.has(square)) return line;
  }
  return null;
}

/// Whether the pinned piece on [square] has a pseudo-legal move off
/// [pinLine] — it could flee if the pin were not there.
bool _canStepOff(Board board, Square square, SquareSet pinLine) {
  final piece = board.pieceAt(square)!;
  final own = board.bySide(piece.color);
  if (piece.role != Role.pawn) {
    return attacks(
      piece,
      square,
      board.occupied,
    ).diff(own).diff(pinLine).isNotEmpty;
  }
  final captures = pawnAttacks(
    piece.color,
    square,
  ).intersect(board.bySide(piece.color.opposite));
  final push = square.offset(piece.color == Side.white ? 8 : -8);
  final pushes = push == null || board.occupied.has(push)
      ? SquareSet.empty
      : SquareSet.fromSquare(push);
  return captures.union(pushes).diff(pinLine).isNotEmpty;
}

// ---- Words ----

/// The [ledger] as one sentence that says WHEN material changes: "Material
/// stays level through 17.Bxd5 exd5; after 19.Nxd5, White is up a pawn." A
/// list of exchanges lets a model put the loss on the wrong move. Null for
/// an empty ledger.
String? materialStory(List<LedgerEntry> ledger) {
  if (ledger.isEmpty) return null;
  final change = ledger.indexWhere((entry) => !entry.isLevel);
  if (change < 0) return 'Material stays level.';

  final first = ledger[change];
  final buffer = StringBuffer(
    change == 0
        ? 'After ${first.moves}, ${first.standing}.'
        : 'Material stays level through ${ledger[change - 1].moves}; '
              'after ${first.moves}, ${first.standing}.',
  );
  final last = ledger.last;
  if (!identical(last, first) && last.standing != first.standing) {
    buffer.write(
      last.isLevel
          ? ' After ${last.moves}, material is level again.'
          : ' After ${last.moves}, ${last.standing}.',
    );
  }
  return buffer.toString();
}

/// The tactic that decided a slip, from the mover's side: what it allowed
/// first, then what it missed. Null when neither line pays off.
String? tacticSummaryLine(MoveTags tags) {
  final hung = tags.allowed.hung;
  if (!tags.allowed.mates && hung != null) {
    return 'Left the ${hung.name} hanging.';
  }
  return _summary(tags.allowed, 'Allowed', 'Lost') ??
      _summary(tags.missed, 'Missed', 'Missed winning');
}

/// "Allowed a forced mate.", "Lost the rook.", "Missed a fork that wins the
/// queen for a rook." Null when [reading] neither mates nor wins material.
String? _summary(LineReading reading, String verb, String plainWin) {
  if (reading.mates) {
    return reading.motifs.contains(Motif.backRankMate)
        ? '$verb a back-rank mate.'
        : '$verb a forced mate.';
  }
  if (!reading.winsMaterial) return null;
  final roles = describeRoles(reading.won);
  final price = reading.gave.isEmpty
      ? ''
      : ' for ${describeRoles(reading.gave, definite: false)}';
  final tactics = reading.tactics;
  return tactics.isEmpty
      ? '$plainWin $roles$price.'
      : '$verb a ${tactics.first.label} that wins $roles$price.';
}

/// "the queen", "two pawns", "the rook and a pawn": only the first piece is
/// definite, and [definite] false makes it "a rook" too.
String describeRoles(List<Role> roles, {bool definite = true}) {
  if (roles.isEmpty) return 'nothing';
  final counts = <Role, int>{};
  for (final role in roles) {
    counts[role] = (counts[role] ?? 0) + 1;
  }
  final named = [
    for (final (i, MapEntry(key: role, value: count)) in counts.entries.indexed)
      count == 1
          ? '${definite && i == 0 && role != Role.pawn ? 'the' : 'a'} '
                '${role.name}'
          : '${numberWord(count)} ${role.name}s',
  ];
  return joinWithAnd(named);
}

/// What [reading] achieves, as a predicate for the side playing it: "mates
/// on the back rank", "wins the queen for a rook, with a fork". Null when
/// the line pays nothing off.
String? describeLine(LineReading reading) {
  if (reading.isEmpty) return null;
  if (reading.mates) {
    return reading.motifs.contains(Motif.backRankMate)
        ? 'mates on the back rank'
        : 'forces mate';
  }
  final hung = reading.hung;
  final gain = hung != null
      ? 'takes the ${hung.name} that was left hanging'
      : 'wins ${describeRoles(reading.won)}'
            '${reading.gave.isEmpty ? '' : ' for ${describeRoles(reading.gave, definite: false)}'}';
  final tactics = reading.tactics;
  if (tactics.isEmpty) return gain;
  return '$gain, with ${joinWithAnd([for (final t in tactics) 'a ${t.label}'])}';
}
