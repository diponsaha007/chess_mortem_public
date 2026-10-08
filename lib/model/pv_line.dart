/// Pure helpers for reading an engine line.
library;

import 'package:dartchess/dartchess.dart';

/// [uci] in SAN from [position], or null when it is missing, unparseable or
/// illegal there.
String? sanOf(Position position, String? uci) {
  final move = uci == null ? null : Move.parse(uci);
  if (move == null || !position.isLegal(move)) return null;
  return position.makeSan(move).$2;
}

/// A UCI principal variation in SAN, replayed from [before]. Stops at the
/// first bad move and caps at [maxPlies].
List<String> pvToSan(Position before, List<String> pvUci, {int maxPlies = 10}) {
  final sans = <String>[];
  var position = before;
  for (final uci in pvUci.take(maxPlies)) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final (next, san) = position.makeSan(move);
    sans.add(san);
    position = next;
  }
  return sans;
}

/// The instructive prefix of a line: it ends on the first capture, check or
/// mate at or after [minPlies] (at least 1), otherwise runs to [maxPlies].
List<String> keyLine(List<String> san, {int minPlies = 4, int maxPlies = 10}) {
  assert(minPlies >= 1);
  final capped = san.take(maxPlies).toList();
  for (var i = minPlies - 1; i < capped.length; i++) {
    final move = capped[i];
    if (move.contains('x') || move.contains('+') || move.contains('#')) {
      return capped.sublist(0, i + 1);
    }
  }
  return capped;
}

/// "9. Nf3 Nc6 10. d4" / "9… Kxf7 10. Nxe5+". [startingPly] is the ply of
/// the position the line starts FROM; an odd one opens with the ellipsis.
String formatLine(List<String> san, {required int startingPly}) {
  final parts = <String>[];
  for (var i = 0; i < san.length; i++) {
    final ply = startingPly + i + 1;
    if (ply.isOdd) {
      parts.add('${(ply + 1) ~/ 2}.');
    } else if (i == 0) {
      parts.add('${(ply + 1) ~/ 2}…');
    }
    parts.add(san[i]);
  }
  return parts.join(' ');
}
