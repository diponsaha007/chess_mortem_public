import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../appearance/appearance_controller.dart';
import '../appearance/board_appearance.dart';

const appearancePreviewKey = ValueKey('appearancePreview');

ValueKey<String> boardThemeSwatchKey(BoardTheme theme) =>
    ValueKey('boardTheme-${theme.name}');

ValueKey<String> pieceStyleSwatchKey(PieceStyle style) =>
    ValueKey('pieceStyle-${style.name}');

/// A middlegame with every piece type on show, so a set can be judged.
const _previewFen =
    'r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8';

/// Picks the board and the pieces, over a live preview. A tap applies and
/// saves at once.
class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key, required this.controller});

  final AppearanceController controller;

  static const double _previewSize = 176;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final appearance = controller.appearance;
        final settings = boardSettingsFor(appearance);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: StaticChessboard(
                    key: appearancePreviewKey,
                    size: _previewSize,
                    orientation: Side.white,
                    fen: _previewFen,
                    settings: StaticChessboardSettings(
                      colorScheme: appearance.boardTheme.scheme,
                      pieceAssets: settings.pieceAssets,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _RowLabel('Board', appearance.boardTheme.label),
              _SwatchRow(
                children: [
                  for (final theme in BoardTheme.values)
                    _Swatch(
                      key: boardThemeSwatchKey(theme),
                      label: theme.label,
                      selected: theme == appearance.boardTheme,
                      onTap: () => controller.setBoardTheme(theme),
                      child: _BoardTile(theme),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _RowLabel('Pieces', appearance.pieceStyle.label),
              _SwatchRow(
                children: [
                  for (final style in PieceStyle.values)
                    _Swatch(
                      key: pieceStyleSwatchKey(style),
                      label: style.label,
                      selected: style == appearance.pieceStyle,
                      onTap: () => controller.setPieceStyle(style),
                      child: _PieceTile(style, appearance.boardTheme),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "Board · Wood": what the row picks and what is picked.
class _RowLabel extends StatelessWidget {
  const _RowLabel(this.name, this.value);

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Text.rich(
        TextSpan(
          text: name,
          children: [
            TextSpan(
              text: '  $value',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        style: theme.textTheme.bodyLarge,
      ),
    );
  }
}

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _Swatch.extent,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: children,
    ),
  );
}

/// One choice. The ring means "the one in use"; an unselected swatch keeps a
/// transparent ring so selecting nudges nothing.
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  /// A full 48 px touch target around a 40 px tile.
  static const double extent = 52;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: extent,
            height: extent,
            padding: const EdgeInsets.all(3),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: 3,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Four squares of a board, in its two colours.
class _BoardTile extends StatelessWidget {
  const _BoardTile(this.theme);

  final BoardTheme theme;

  @override
  Widget build(BuildContext context) {
    final light = ColoredBox(color: theme.scheme.lightSquare);
    final dark = ColoredBox(color: theme.scheme.darkSquare);
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: light),
              Expanded(child: dark),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: dark),
              Expanded(child: light),
            ],
          ),
        ),
      ],
    );
  }
}

/// A set's white knight, on a dark square of the board in use.
class _PieceTile extends StatelessWidget {
  const _PieceTile(this.style, this.board);

  final PieceStyle style;
  final BoardTheme board;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: board.scheme.darkSquare,
    child: Image(
      image: style.image(Piece.whiteKnight),
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    ),
  );
}
