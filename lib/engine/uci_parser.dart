/// Pure parsing of UCI output, and the ONE place a side-to-move score becomes
/// White-perspective.
library;

import 'package:dartchess/dartchess.dart';

import '../model/eval.dart';
import '../model/move_facts.dart' show landingSquare;

/// A parsed `info ...` line. Score fields are still side-to-move
/// relative — call [toWhitePerspective] before storing anywhere.
class UciInfo {
  const UciInfo({
    required this.depth,
    this.cp,
    this.mateIn,
    this.pv = const [],
    this.multipv = 1,
  });

  final int depth;
  final int? cp;
  final int? mateIn;
  final List<String> pv;

  /// The `MultiPV` rank, 1 = best. Omitted by a single-line search.
  final int multipv;

  bool get hasScore => cp != null || mateIn != null;

  UciInfo withPv(List<String> pv) =>
      UciInfo(depth: depth, cp: cp, mateIn: mateIn, pv: pv, multipv: multipv);
}

/// [line] as dartchess writes it, played out from [position].
///
/// UCI castles as the king's two-square step (`e1g1`); dartchess's
/// `Move.uci` is king-takes-rook (`e1h1`). Without this, castling never
/// equals the engine's best move and could never be Best. The line is cut at
/// the first move that is not legal.
List<String> normalizeUciLine(Position position, List<String> line) {
  final out = <String>[];
  var board = position;
  for (final uci in line) {
    final parsed = Move.parse(uci);
    if (parsed is! NormalMove || !board.isLegal(parsed)) break;
    final move = board.normalizeMove(parsed);
    out.add(move.uci);
    board = board.play(move);
  }
  return out;
}

/// [uci] (dartchess's form) as the engine wants it: castling back to the
/// king's two-square step, the reverse of [normalizeUciLine]. Used for
/// `searchmoves`, which Stockfish matches against its own move strings.
String toEngineUci(Position position, String uci) {
  final move = Move.parse(uci);
  if (move is! NormalMove) return uci;
  final to = landingSquare(position, move);
  if (to == null || to == move.to) return uci;
  return '${move.from.name}${to.name}';
}

final _depthRe = RegExp(r'\bdepth (\d+)');
final _multipvRe = RegExp(r'\bmultipv (\d+)');
final _cpRe = RegExp(r'\bscore cp (-?\d+)');
final _mateRe = RegExp(r'\bscore mate (-?\d+)');
final _pvRe = RegExp(r'\bpv ((?:[a-h][1-8][a-h][1-8][qrbn]? ?)+)$');
final _bestMoveRe = RegExp(r'^bestmove ([a-h][1-8][a-h][1-8][qrbn]?|\(none\))');

/// Parses a scored `info` line; null for anything else.
UciInfo? parseInfoLine(String line) {
  if (!line.startsWith('info ')) return null;
  final depthMatch = _depthRe.firstMatch(line);
  if (depthMatch == null) return null;

  final cp = _cpRe.firstMatch(line);
  final mate = _mateRe.firstMatch(line);
  if (cp == null && mate == null) return null;

  final pvMatch = _pvRe.firstMatch(line);
  final multipvMatch = _multipvRe.firstMatch(line);
  return UciInfo(
    depth: int.parse(depthMatch.group(1)!),
    cp: cp == null ? null : int.parse(cp.group(1)!),
    mateIn: mate == null ? null : int.parse(mate.group(1)!),
    pv: pvMatch == null ? const [] : pvMatch.group(1)!.trim().split(' '),
    multipv: multipvMatch == null ? 1 : int.parse(multipvMatch.group(1)!),
  );
}

/// The move from a `bestmove` line; null for another line or `(none)`.
String? parseBestMoveLine(String line) {
  final match = _bestMoveRe.firstMatch(line);
  if (match == null) return null;
  final move = match.group(1)!;
  return move == '(none)' ? null : move;
}

/// Combines the last info line and the bestmove into a White-perspective
/// [EngineEval].
///
/// [alternatives] (the runner-up `multipv` lines of the same search) get the
/// same flip, and are dropped entirely unless [info] is the line for
/// [bestMoveUci] — after a `stop` the two can disagree.
///
/// With [position] (the one searched), castling is rewritten from UCI's
/// king-to-g1 into dartchess's king-takes-rook (see [normalizeUciLine]).
EngineEval toWhitePerspective({
  required UciInfo info,
  required String? bestMoveUci,
  required Side sideToMove,
  List<UciInfo> alternatives = const [],
  Position? position,
}) {
  if (position != null) {
    info = info.withPv(normalizeUciLine(position, info.pv));
    alternatives = [
      for (final line in alternatives)
        line.withPv(normalizeUciLine(position, line.pv)),
    ];
    if (bestMoveUci != null) {
      bestMoveUci = normalizeUciLine(position, [bestMoveUci]).firstOrNull;
    }
  }

  // `mate 0` has no sign to flip; the side to move is the mated one.
  if (info.mateIn == 0) {
    return EngineEval.checkmate(
      mated: sideToMove,
      bestMoveUci: bestMoveUci,
      depth: info.depth,
    );
  }

  final flip = sideToMove == Side.black;
  final ranksTheBestMove =
      bestMoveUci != null && info.pv.isNotEmpty && info.pv.first == bestMoveUci;
  return EngineEval(
    cp: info.cp == null ? null : (flip ? -info.cp! : info.cp!),
    mateIn: info.mateIn == null ? null : (flip ? -info.mateIn! : info.mateIn!),
    bestMoveUci: bestMoveUci,
    pvUci: List.unmodifiable(info.pv.take(10)),
    alternatives: List.unmodifiable([
      if (ranksTheBestMove)
        for (final line in alternatives)
          if (line.pv.isNotEmpty && line.hasScore)
            EngineLine(
              cp: line.cp == null ? null : (flip ? -line.cp! : line.cp!),
              mateIn: line.mateIn == null
                  ? null
                  : (flip ? -line.mateIn! : line.mateIn!),
              pvUci: List.unmodifiable(line.pv.take(10)),
            ),
    ]),
    depth: info.depth,
  );
}
