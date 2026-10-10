import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chessground/chessground.dart' show ChessboardColorScheme;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../appearance/board_appearance.dart';
import '../model/classification.dart';
import '../widgets/eval_bar.dart';
import '../widgets/move_list.dart';
import 'gif_frames.dart';

/// Draws [GifFrame]s the way the board screen shows a move: the user's board
/// and pieces, the last move, the verdict badge, the eval bar and the green
/// improvement arrow, with the players' names above and below. Boards drawn
/// from a texture (wood, marble) use their plain square colours: a texture
/// makes every frame several times larger.
class GifPainter {
  GifPainter._({
    required this.scheme,
    required this.orientation,
    required this.topName,
    required this.bottomName,
    required Map<PieceKind, ui.Image> pieces,
  }) : _pieces = pieces;

  static const double square = 56;
  static const double boardSize = square * 8;
  static const double _margin = 12;
  static const double _gap = 6;
  static const double _stripHeight = 30;
  static const double _footerHeight = 26;
  static const double _captionFontSize = 14;
  static const double _captionLineHeight = 1.3;
  static const int _captionLines = 4;
  static const double _captionHeight =
      _captionLines * _captionFontSize * _captionLineHeight + 8;
  static const double _boardLeft = _margin + EvalBar.width + _gap;
  static const double _boardTop = _margin + _stripHeight;

  static const int width = (_boardLeft + boardSize + _margin) ~/ 1;
  static const double _captionTop = _boardTop + boardSize + _stripHeight;
  static const double _footerTop = _captionTop + _captionHeight;
  static const int height = (_footerTop + _footerHeight + _margin / 2) ~/ 1;

  /// The app icon's ink: the GIF reads as the app's.
  static const background = Color(0xFF14152A);
  static const _text = Color(0xFFF2F2F7);
  static const _faintText = Color(0x99F2F2F7);

  /// The board screen's improvement arrow.
  static final arrowColor = Colors.lightGreen.withValues(alpha: 0.75);

  final ChessboardColorScheme scheme;

  /// The side at the bottom of the board.
  final Side orientation;
  final String topName;
  final String bottomName;
  final Map<PieceKind, ui.Image> _pieces;

  /// Decodes the piece set once, at the size it is drawn.
  static Future<GifPainter> load({
    required BoardAppearance appearance,
    required Side orientation,
    required String whiteName,
    required String blackName,
  }) async {
    final scheme = appearance.boardTheme.scheme;
    final assets = appearance.pieceStyle.assets;
    final pieces = <PieceKind, ui.Image>{};
    for (final kind in PieceKind.values) {
      final asset = assets[kind];
      if (asset != null) pieces[kind] = await _pieceImage(asset);
    }
    return GifPainter._(
      scheme: scheme,
      orientation: orientation,
      topName: orientation == Side.white ? blackName : whiteName,
      bottomName: orientation == Side.white ? whiteName : blackName,
      pieces: pieces,
    );
  }

  /// The 2x variant scaled down to a square, which stays sharp; the base
  /// file where a set has none.
  static Future<ui.Image> _pieceImage(AssetImage asset) async {
    final key = asset.keyName;
    final slash = key.lastIndexOf('/');
    final sharp = '${key.substring(0, slash)}/2.0x${key.substring(slash)}';
    try {
      return await _decode(sharp, square.toInt());
    } on FlutterError {
      return _decode(key, square.toInt());
    }
  }

  static Future<ui.Image> _decode(String key, int size) async {
    final data = await rootBundle.load(key);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      targetWidth: size,
      targetHeight: size,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// [frame] as [width] x [height] straight RGBA bytes.
  Future<Uint8List> render(GifFrame frame) async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), frame);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  void paint(Canvas canvas, GifFrame frame) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = background,
    );
    final summary = frame.summary;
    if (summary != null) {
      _summaryCard(canvas, summary);
      _footer(canvas);
      return;
    }
    _name(canvas, topName, _margin);
    _name(canvas, bottomName, _boardTop + boardSize);
    _evalBar(canvas, frame);

    canvas.save();
    canvas.translate(_boardLeft, _boardTop);
    _board(canvas, frame);
    final arrow = frame.arrow;
    if (arrow != null) _arrow(canvas, arrow.$1, arrow.$2);
    _badge(canvas, frame);
    canvas.restore();

    _caption(canvas, frame);
    _footer(canvas);
  }

  /// The closing card, as the summary screen ranks it: the result, then
  /// each player's accuracy, then the verdicts side by side, White on the
  /// left.
  void _summaryCard(Canvas canvas, GifSummary summary) {
    const left = width / 4;
    const right = width * 3 / 4;
    const centre = width / 2;
    var y = 22.0;

    final opening = summary.opening;
    if (opening != null) {
      y += _textAt(
        canvas,
        opening,
        const TextStyle(color: _faintText, fontSize: 14),
        centreX: centre,
        top: y,
        maxWidth: width - 2 * _margin,
      );
    }
    y += 6;

    final result = summary.result;
    y += _textAt(
      canvas,
      result?.label ?? 'Unfinished',
      const TextStyle(color: _text, fontSize: 34, fontWeight: FontWeight.w800),
      centreX: centre,
      top: y,
      maxWidth: width - 2 * _margin,
    );
    if (result != null) {
      final winner = result.winner;
      y += _textAt(
        canvas,
        winner == null ? 'Draw' : '${summary.player(winner).name} won',
        const TextStyle(color: _text, fontSize: 15),
        centreX: centre,
        top: y,
        maxWidth: width - 2 * _margin,
      );
    }
    y += 22;

    var playersBottom = y;
    for (final side in Side.values) {
      final player = summary.player(side);
      final x = side == Side.white ? left : right;
      var py = y;
      canvas.drawCircle(
        Offset(x, py + 8),
        8,
        Paint()..color = side == Side.white ? Colors.white : Colors.black,
      );
      canvas.drawCircle(
        Offset(x, py + 8),
        8,
        Paint()
          ..color = _faintText
          ..style = PaintingStyle.stroke,
      );
      py += 22;
      py += _textAt(
        canvas,
        player.name,
        const TextStyle(
          color: _text,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        centreX: x,
        top: py,
        maxWidth: width / 2 - 2 * _margin,
      );
      final rating = player.rating;
      py += _textAt(
        canvas,
        rating ?? '',
        const TextStyle(color: _faintText, fontSize: 13),
        centreX: x,
        top: py,
        maxWidth: width / 2 - 2 * _margin,
      );
      py += 6;
      final accuracy = player.accuracy;
      py += _textAt(
        canvas,
        accuracy == null ? '—' : '${accuracy.toStringAsFixed(1)}%',
        const TextStyle(
          color: _text,
          fontSize: 32,
          fontWeight: FontWeight.w800,
        ),
        centreX: x,
        top: py,
        maxWidth: width / 2 - 2 * _margin,
      );
      py += _textAt(
        canvas,
        'accuracy',
        const TextStyle(color: _faintText, fontSize: 13),
        centreX: x,
        top: py,
        maxWidth: width / 2 - 2 * _margin,
      );
      playersBottom = math.max(playersBottom, py);
    }
    y = playersBottom + 18;

    // Every tier, zeros included, Book under Great: the summary's table.
    final rows = <Classification?>[
      for (final c in Classification.values) ...[
        c,
        if (c == Classification.great) null,
      ],
    ];
    final rowHeight = math.min(32.0, (_footerTop - 8 - y) / rows.length);
    for (final tier in rows) {
      final mid = y + rowHeight / 2;
      _verdictDisc(canvas, Offset(centre - 52, mid), 18, tier);
      _textAt(
        canvas,
        tier?.label ?? 'Book',
        const TextStyle(color: _text, fontSize: 14),
        left: centre - 36,
        top: mid - 10,
        maxWidth: 110,
      );
      for (final side in Side.values) {
        final player = summary.player(side);
        final count = tier == null
            ? player.bookMoves
            : player.counts[tier] ?? 0;
        _textAt(
          canvas,
          '$count',
          TextStyle(
            color: count == 0 ? _faintText : _text,
            fontSize: 15,
            fontWeight: count == 0 ? FontWeight.w400 : FontWeight.w700,
          ),
          centreX: side == Side.white ? left : right,
          top: mid - 10,
          maxWidth: 60,
        );
      }
      y += rowHeight;
    }
  }

  /// One line of [text] centred on [centreX], or starting at [left];
  /// returns its height.
  double _textAt(
    Canvas canvas,
    String text,
    TextStyle style, {
    double? centreX,
    double? left,
    required double top,
    required double maxWidth,
  }) {
    final painter = _layout(text, style, maxWidth: maxWidth);
    final x = left ?? centreX! - painter.width / 2;
    painter.paint(canvas, Offset(x, top));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// Top-left corner of [square] on the board as drawn.
  Offset _cornerOf(Square sq) {
    final file = orientation == Side.white ? sq.file.value : 7 - sq.file.value;
    final rank = orientation == Side.white ? 7 - sq.rank.value : sq.rank.value;
    return Offset(file * square, rank * square);
  }

  Offset _centreOf(Square sq) =>
      _cornerOf(sq) + const Offset(square / 2, square / 2);

  void _board(Canvas canvas, GifFrame frame) {
    final light = Paint()..color = scheme.lightSquare;
    final dark = Paint()..color = scheme.darkSquare;
    for (final sq in Square.values) {
      final isLight = (sq.file.value + sq.rank.value).isOdd;
      canvas.drawRect(
        _cornerOf(sq) & const Size.square(square),
        isLight ? light : dark,
      );
    }

    final last = frame.lastMove;
    if (last != null) {
      final highlight = Paint()
        ..color = scheme.lastMove.solidColor ?? const Color(0x809CC700);
      for (final sq in [last.$1, last.$2]) {
        canvas.drawRect(_cornerOf(sq) & const Size.square(square), highlight);
      }
    }

    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final (sq, piece) in frame.board.pieces) {
      final image = _pieces[piece.kind];
      if (image == null) continue;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        _cornerOf(sq) & const Size.square(square),
        paint,
      );
    }
  }

  /// A straight arrow from centre to centre, its head ending on [to].
  void _arrow(Canvas canvas, Square from, Square to) {
    final start = _centreOf(from);
    final tip = _centreOf(to);
    final delta = tip - start;
    final length = delta.distance;
    if (length == 0) return;
    final dir = delta / length;
    final normal = Offset(-dir.dy, dir.dx);
    const headLength = square * 0.45;
    const headWidth = square * 0.5;
    final base = tip - dir * headLength;
    final paint = Paint()..color = arrowColor;
    canvas.drawLine(
      start,
      base,
      Paint()
        ..color = arrowColor
        ..strokeWidth = square * 0.17,
    );
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          (base + normal * headWidth / 2).dx,
          (base + normal * headWidth / 2).dy,
        )
        ..lineTo(
          (base - normal * headWidth / 2).dx,
          (base - normal * headWidth / 2).dy,
        )
        ..close(),
      paint,
    );
  }

  /// The board screen's badge: top-right of the landing square, nudged
  /// inside the board on the edges.
  void _badge(Canvas canvas, GifFrame frame) {
    final sq = frame.badgeSquare;
    final classification = frame.classification;
    if (sq == null || (!frame.isBook && classification == null)) return;
    const size = square * 0.46;
    final corner = _cornerOf(sq);
    final left = (corner.dx + square - size * 0.72).clamp(
      0.0,
      boardSize - size,
    );
    final top = (corner.dy - size * 0.28).clamp(0.0, boardSize - size);
    final centre = Offset(left + size / 2, top + size / 2);
    _verdictDisc(canvas, centre, size, frame.isBook ? null : classification);
  }

  /// The badge disc: a verdict's symbol on its colour, or the book mark for
  /// null.
  void _verdictDisc(
    Canvas canvas,
    Offset centre,
    double size,
    Classification? classification,
  ) {
    if (classification == null) {
      canvas.drawCircle(
        centre,
        size / 2,
        Paint()..color = const Color(0xFFE3E3EA),
      );
      _centredText(
        canvas,
        String.fromCharCode(Icons.menu_book.codePoint),
        centre,
        TextStyle(
          fontFamily: Icons.menu_book.fontFamily,
          package: Icons.menu_book.fontPackage,
          fontSize: size * 0.7,
          color: const Color(0xFF5B5B66),
        ),
      );
      return;
    }
    canvas.drawCircle(
      centre,
      size / 2,
      Paint()..color = classificationColor(classification),
    );
    final symbol = classificationSymbol(classification);
    _centredText(
      canvas,
      symbol,
      centre,
      TextStyle(
        color: classificationInk,
        fontWeight: FontWeight.w800,
        fontSize: size * (symbol.length > 1 ? 0.5 : 0.62),
        height: 1,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }

  /// The eval bar's rules: White's winning chances, mirrored with the board,
  /// the score at the leading side's end.
  void _evalBar(Canvas canvas, GifFrame frame) {
    const rect = Rect.fromLTWH(_margin, _boardTop, EvalBar.width, boardSize);
    final bottomIsWhite = orientation == Side.white;
    final whiteFraction = (frame.eval?.winPctWhite ?? 50) / 100;
    final bottomFraction = (bottomIsWhite ? whiteFraction : 1 - whiteFraction)
        .clamp(0.0, 1.0);
    final bottomFill = bottomIsWhite ? Colors.white : Colors.black;
    final topFill = bottomIsWhite ? Colors.black : Colors.white;
    canvas.drawRect(rect, Paint()..color = topFill);
    final split = rect.bottom - rect.height * bottomFraction;
    canvas.drawRect(
      Rect.fromLTRB(rect.left, split, rect.right, rect.bottom),
      Paint()..color = bottomFill,
    );

    final label = EvalBar.scoreLabel(frame.eval);
    if (label == null) return;
    final labelAtBottom = (whiteFraction >= 0.5) == bottomIsWhite;
    final fill = labelAtBottom ? bottomFill : topFill;
    final painter = _layout(
      label,
      TextStyle(
        fontSize: 9.5,
        height: 1.1,
        fontWeight: FontWeight.w700,
        color: fill == Colors.white ? Colors.black : Colors.white,
      ),
      maxWidth: double.infinity,
    );
    // Scaled down to the bar's width, as the bar's FittedBox does.
    final scale = math.min(1.0, (EvalBar.width - 2) / painter.width);
    final w = painter.width * scale;
    final h = painter.height * scale;
    final dx = rect.left + (rect.width - w) / 2;
    final dy = labelAtBottom ? rect.bottom - 3 - h : rect.top + 3;
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    painter.dispose();
  }

  void _name(Canvas canvas, String name, double top) {
    final painter = _layout(
      name,
      const TextStyle(color: _text, fontSize: 15, fontWeight: FontWeight.w600),
      maxWidth: boardSize,
    );
    painter.paint(
      canvas,
      Offset(_boardLeft, top + (_stripHeight - painter.height) / 2),
    );
    painter.dispose();
  }

  /// "3… Nf6  Blunder · White allowed…", as the coach bar reads, under the
  /// board. The height is fixed: every frame of a GIF is the same size.
  void _caption(Canvas canvas, GifFrame frame) {
    final label = frame.moveLabel;
    if (label == null) return;
    final classification = frame.classification;
    final line = frame.coachLine;
    final painter = TextPainter(
      text: TextSpan(
        style: const TextStyle(
          color: _text,
          fontSize: _captionFontSize,
          height: _captionLineHeight,
        ),
        children: [
          TextSpan(
            text: '$label  ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (frame.isBook)
            const TextSpan(
              text: 'Book',
              style: TextStyle(color: _faintText),
            )
          else if (classification != null)
            TextSpan(
              text: classification.label,
              style: TextStyle(
                color: classificationColor(classification),
                fontWeight: FontWeight.w700,
              ),
            ),
          if (line != null) TextSpan(text: ' · $line'),
        ],
      ),
      textDirection: TextDirection.ltr,
      maxLines: _captionLines,
      ellipsis: '…',
    )..layout(maxWidth: boardSize);
    painter.paint(canvas, const Offset(_boardLeft, _captionTop + 4));
    painter.dispose();
  }

  void _footer(Canvas canvas) {
    final painter = _layout(
      'Chess Mortem',
      const TextStyle(
        color: _text,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
      maxWidth: boardSize,
    );
    const top = _footerTop;
    painter.paint(
      canvas,
      Offset(
        _boardLeft + boardSize - painter.width,
        top + (_footerHeight - painter.height) / 2,
      ),
    );
    painter.dispose();
  }

  void _centredText(
    Canvas canvas,
    String text,
    Offset centre,
    TextStyle style,
  ) {
    final painter = _layout(text, style, maxWidth: square);
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  static TextPainter _layout(
    String text,
    TextStyle style, {
    required double maxWidth,
  }) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(0, maxWidth));

  void dispose() {
    for (final image in _pieces.values) {
      image.dispose();
    }
  }
}
