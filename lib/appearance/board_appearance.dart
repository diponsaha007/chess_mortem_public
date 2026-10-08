import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';

/// The boards the user can pick. The enum's `name` is what is stored, so a
/// value is never renamed.
enum BoardTheme {
  brown('Brown', ChessboardColorScheme.brown),
  blue('Blue', ChessboardColorScheme.blue),
  green('Green', ChessboardColorScheme.green),
  ic('Ivory', ChessboardColorScheme.ic),
  grey('Grey', ChessboardColorScheme.grey),
  wood('Wood', ChessboardColorScheme.wood),
  wood2('Light wood', ChessboardColorScheme.wood2),
  wood3('Dark wood', ChessboardColorScheme.wood3),
  wood4('Walnut', ChessboardColorScheme.wood4),
  maple('Maple', ChessboardColorScheme.maple),
  maple2('Pale maple', ChessboardColorScheme.maple2),
  marble('Marble', ChessboardColorScheme.marble),
  blueMarble('Blue marble', ChessboardColorScheme.blueMarble),
  blue2('Slate', ChessboardColorScheme.blue2),
  blue3('Ocean', ChessboardColorScheme.blue3),
  canvas('Canvas', ChessboardColorScheme.canvas),
  leather('Leather', ChessboardColorScheme.leather),
  metal('Metal', ChessboardColorScheme.metal),
  olive('Olive', ChessboardColorScheme.olive),
  newspaper('Newspaper', ChessboardColorScheme.newspaper),
  greenPlastic('Tournament', ChessboardColorScheme.greenPlastic),
  purple('Purple', ChessboardColorScheme.purple),
  purpleDiag('Purple weave', ChessboardColorScheme.purpleDiag);

  const BoardTheme(this.label, this.scheme);

  final String label;
  final ChessboardColorScheme scheme;

  /// The theme stored as [name], or the default for an unknown one: a theme
  /// dropped in a later build must not break an upgrade.
  static BoardTheme byName(String? name) =>
      values.asNameMap()[name] ?? BoardAppearance.standard.boardTheme;
}

/// The piece sets offered: only freely licensed ones, which a GPL app can
/// ship. [author] and [licence] feed the licences page.
enum PieceStyle {
  cburnett('Classic', 'Colin M.L. Burnett', 'GPLv2+', PieceSet.cburnettAssets),
  merida(
    'Merida',
    'Armando Hernandez Marroquin',
    'GPLv2+',
    PieceSet.meridaAssets,
  ),
  chessnut('Chessnut', 'Alexis Luengas', 'Apache 2.0', PieceSet.chessnutAssets),
  pirouetti('Pirouetti', 'pirouetti', 'AGPLv3+', PieceSet.pirouettiAssets),
  mpchess('Mpchess', 'Maxime Chupin', 'GPLv3+', PieceSet.mpchessAssets),
  fantasy('Fantasy', 'Maurizio Monge', 'MIT', PieceSet.fantasyAssets),
  spatial('Spatial', 'Maurizio Monge', 'MIT', PieceSet.spatialAssets),
  celtic('Celtic', 'Maurizio Monge', 'MIT', PieceSet.celticAssets),
  rhosgfx('Rhos', 'RhosGFX', 'CC0 1.0', PieceSet.rhosgfxAssets),
  firi('Firi', 'James Faure', 'CC BY 4.0', PieceSet.firiAssets),
  totoy('Totoy', 'Kosal Sen', 'CC BY 4.0', PieceSet.totoyAssets),
  kiwenSuwi('Kiwen-suwi', 'neverRare', 'CC BY 4.0', PieceSet.kiwenSuwiAssets),
  shapes('Shapes', 'flugsio', 'CC BY-SA 4.0', PieceSet.shapesAssets),
  pixel('Pixel', 'therealqtpi', 'AGPLv3+', PieceSet.pixelAssets),
  letter('Letter', 'usolando', 'AGPLv3+', PieceSet.letterAssets);

  const PieceStyle(this.label, this.author, this.licence, this.assets);

  final String label;
  final String author;
  final String licence;
  final PieceAssets assets;

  /// The image of [piece] in this set.
  AssetImage image(Piece piece) => assets[piece.kind]!;

  /// The set stored as [name], or the default for an unknown one.
  static PieceStyle byName(String? name) =>
      values.asNameMap()[name] ?? BoardAppearance.standard.pieceStyle;
}

/// How the board looks: its squares and its pieces. View state only — the
/// verdict colours and the arrows carry meaning and are never themed.
@immutable
class BoardAppearance {
  const BoardAppearance({
    this.boardTheme = BoardTheme.brown,
    this.pieceStyle = PieceStyle.cburnett,
  });

  static const standard = BoardAppearance();

  final BoardTheme boardTheme;
  final PieceStyle pieceStyle;

  BoardAppearance copyWith({BoardTheme? boardTheme, PieceStyle? pieceStyle}) =>
      BoardAppearance(
        boardTheme: boardTheme ?? this.boardTheme,
        pieceStyle: pieceStyle ?? this.pieceStyle,
      );

  @override
  bool operator ==(Object other) =>
      other is BoardAppearance &&
      other.boardTheme == boardTheme &&
      other.pieceStyle == pieceStyle;

  @override
  int get hashCode => Object.hash(boardTheme, pieceStyle);
}

const coordinatesWhiteKey = ValueKey('coordinates-white');
const coordinatesBlackKey = ValueKey('coordinates-black');

final _settingsCache = <BoardAppearance, ChessboardSettings>{};

/// The analysis board's settings for [appearance]. Cached, so the board sees
/// the same object until the appearance changes.
///
/// chessground 10.1.1 never repaints its coordinates, so the two coordinate
/// backgrounds get distinct keys to force a rebuild on flip. Do NOT key the
/// Chessboard instead: its controller would be attached twice.
ChessboardSettings boardSettingsFor(BoardAppearance appearance) =>
    _settingsCache.putIfAbsent(appearance, () {
      final scheme = appearance.boardTheme.scheme;
      return ChessboardSettings(
        enablePremoves: false,
        pieceAssets: appearance.pieceStyle.assets,
        colorScheme: scheme.copyWith(
          whiteCoordBackground: _keyed(
            scheme.whiteCoordBackground,
            coordinatesWhiteKey,
          ),
          blackCoordBackground: _keyed(
            scheme.blackCoordBackground,
            coordinatesBlackKey,
          ),
        ),
      );
    });

/// [background] again, under [key]. The stock ones are unkeyed constants.
ChessboardBackground _keyed(ChessboardBackground background, Key key) {
  if (background is ImageChessboardBackground) {
    return ImageChessboardBackground(
      key: key,
      lightSquare: background.lightSquare,
      darkSquare: background.darkSquare,
      image: background.image,
      coordinates: background.coordinates,
      orientation: background.orientation,
    );
  }
  return SolidColorChessboardBackground(
    key: key,
    lightSquare: background.lightSquare,
    darkSquare: background.darkSquare,
    coordinates: background.coordinates,
    orientation: background.orientation,
  );
}
