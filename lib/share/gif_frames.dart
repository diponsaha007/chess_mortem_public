import 'package:dartchess/dartchess.dart';

import '../model/accuracy.dart';
import '../model/classification.dart';
import '../model/eval.dart';
import '../model/game_result.dart';
import '../model/game_tree.dart';

/// How long a frame stays up.
const gifMoveDuration = Duration(milliseconds: 800);

/// A turning point holds long enough to read its badge and arrow.
const gifKeyMoveDuration = Duration(milliseconds: 2000);

/// The start position, before the first move.
const gifStartDuration = Duration(milliseconds: 1000);

/// The final position, before the GIF loops.
const gifEndDuration = Duration(milliseconds: 3000);

/// A frame with a coach line holds long enough to read it.
const gifCaptionDuration = Duration(milliseconds: 4000);

/// The closing summary card.
const gifSummaryDuration = Duration(milliseconds: 5000);

/// One picture of the shared GIF: a position with the analysis drawn on the
/// board — the same verdict badge, eval bar and improvement arrow the board
/// screen shows.
class GifFrame {
  const GifFrame({
    required this.board,
    required this.duration,
    this.lastMove,
    this.badgeSquare,
    this.classification,
    this.isBook = false,
    this.eval,
    this.arrow,
    this.moveLabel,
    this.coachLine,
    this.summary,
  });

  final Board board;
  final Duration duration;

  /// The move that led here, as from and landing squares.
  final (Square, Square)? lastMove;

  /// Where the verdict badge goes: the landing square (the king's when
  /// castling). Null at the start.
  final Square? badgeSquare;

  final Classification? classification;

  /// A book move shows the book mark in place of its verdict.
  final bool isBook;

  /// White-perspective, for the eval bar. Null before it was searched.
  final EngineEval? eval;

  /// The better move, from and to, on a mistake or worse only.
  final (Square, Square)? arrow;

  /// "3… Nf6": the move, numbered. Null at the start.
  final String? moveLabel;

  /// The coach line, on the frames that hold long enough to read it.
  final String? coachLine;

  /// Set on the closing card, which shows this in place of the board.
  final GifSummary? summary;
}

/// The game in numbers, as the summary screen ranks it: the result, the
/// opening, and each player's accuracy and verdicts.
class GifSummary {
  const GifSummary({
    required this.white,
    required this.black,
    required this.result,
    required this.opening,
  });

  final GifPlayer white;
  final GifPlayer black;
  final GameResult? result;

  /// The last book position's name; null when the game left book at once.
  final String? opening;

  GifPlayer player(Side side) => side == Side.white ? white : black;

  factory GifSummary.of(GameTree tree) {
    final mainline = tree.mainline;
    GifPlayer playerFor(Side side) {
      final colour = side == Side.white ? 'White' : 'Black';
      final counts = <Classification, int>{};
      var book = 0;
      for (final node in mainline) {
        if (node.sideThatMoved != side) continue;
        // Book moves are counted apart, as accuracy leaves them out.
        if (node.isBook) {
          book++;
          continue;
        }
        final tier = node.classification;
        if (tier != null) counts[tier] = (counts[tier] ?? 0) + 1;
      }
      return GifPlayer(
        name: tree.header(colour) ?? colour,
        rating: tree.header('${colour}Elo'),
        accuracy: gameAccuracy(
          accuracySamples(root: tree.root, mainline: mainline, mover: side),
        ),
        counts: counts,
        bookMoves: book,
      );
    }

    String? opening;
    for (final node in mainline) {
      if (!node.isBook) break;
      opening = node.openingName;
    }
    return GifSummary(
      white: playerFor(Side.white),
      black: playerFor(Side.black),
      result: GameResult.parse(tree.header('Result')),
      opening: opening,
    );
  }
}

class GifPlayer {
  const GifPlayer({
    required this.name,
    required this.rating,
    required this.accuracy,
    required this.counts,
    required this.bookMoves,
  });

  final String name;
  final String? rating;
  final double? accuracy;

  /// Verdicts of the moves out of book.
  final Map<Classification, int> counts;
  final int bookMoves;
}

/// The frames for [tree]'s mainline: the start position, then one per move.
/// [coachLineFor] writes the caption of a turning point and of the last move;
/// a line shown for less than a second could not be read. A summary card
/// closes it.
List<GifFrame> gifFramesFor(
  GameTree tree, {
  String Function(GameNode node)? coachLineFor,
}) {
  final moves = tree.mainline;
  return [
    GifFrame(
      board: tree.root.position.board,
      duration: moves.isEmpty ? gifEndDuration : gifStartDuration,
      eval: tree.root.eval,
    ),
    for (final (i, node) in moves.indexed)
      _frameFor(
        node,
        isLast: i == moves.length - 1,
        coachLineFor: coachLineFor,
      ),
    if (moves.isNotEmpty)
      GifFrame(
        board: moves.last.position.board,
        duration: gifSummaryDuration,
        summary: GifSummary.of(tree),
      ),
  ];
}

GifFrame _frameFor(
  GameNode node, {
  required bool isLast,
  String Function(GameNode node)? coachLineFor,
}) {
  final played = node.move;
  final landing = node.landingSquare;
  final classification = node.classification;
  // A book move shows the book mark, so its verdict never holds the frame.
  final turningPoint =
      !node.isBook && (classification?.isTurningPoint ?? false);
  var duration = turningPoint ? gifKeyMoveDuration : gifMoveDuration;
  if (isLast) duration = gifEndDuration;
  final coachLine = (turningPoint || isLast) ? coachLineFor?.call(node) : null;
  if (coachLine != null) duration = gifCaptionDuration;
  return GifFrame(
    board: node.position.board,
    duration: duration,
    lastMove: played is NormalMove && landing != null
        ? (played.from, landing)
        : null,
    badgeSquare: landing,
    classification: classification,
    isBook: node.isBook,
    eval: node.eval,
    arrow: _betterArrow(node),
    moveLabel: moveLabelOf(node),
    coachLine: coachLine,
  );
}

/// "3. Nf3" for White, "3… Nf6" for Black.
String? moveLabelOf(GameNode node) {
  final san = node.san;
  if (san == null) return null;
  final number = (node.ply + 1) ~/ 2;
  return node.sideThatMoved == Side.white ? '$number. $san' : '$number… $san';
}

/// The engine's move from the PARENT's eval, shown only on a mistake or
/// worse: elsewhere the GIF would fill with arrows nobody needs.
(Square, Square)? _betterArrow(GameNode node) {
  final classification = node.classification;
  if (node.isBook || classification == null) return null;
  if (!classification.isMistakeOrWorse || node.isEngineMove) return null;
  final uci = node.engineMoveUci;
  if (uci == null) return null;
  final better = Move.parse(uci);
  if (better is! NormalMove) return null;
  return (better.from, better.to);
}
