import 'package:dartchess/dartchess.dart';

/// "White" / "Black".
String sideName(Side side) => side == Side.white ? 'White' : 'Black';

/// Which side [playerName] played, matched case- and whitespace-insensitively
/// against the PGN's [white] and [black] tags. Null when the name is unset
/// or empty, or matches neither player.
Side? sideOfPlayer(String? playerName, {String? white, String? black}) {
  final wanted = playerName?.trim().toLowerCase();
  if (wanted == null || wanted.isEmpty) return null;
  if (white?.trim().toLowerCase() == wanted) return Side.white;
  if (black?.trim().toLowerCase() == wanted) return Side.black;
  return null;
}
