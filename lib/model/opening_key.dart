/// How a position is keyed in the opening book. Flutter-free and shared with
/// `scripts/build_opening_book.dart`, so build and lookup cannot drift.
library;

import 'package:dartchess/dartchess.dart';

/// The FEN without its move counters, so transpositions match. dartchess only
/// emits an en-passant square when the capture is legal.
String openingEpd(Position position) =>
    position.fen.split(' ').take(4).join(' ');

/// 63-bit (non-negative) FNV-1a of [openingEpd]. Needs 64-bit ints: correct
/// on the VM and AOT, NOT on the web.
int openingKey(Position position) => fnv1a63(openingEpd(position));

/// FNV-1a over the UTF-16 code units of [text], truncated to 63 bits.
int fnv1a63(String text) {
  var hash = 0xcbf29ce484222325;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash *= 0x100000001b3;
  }
  return hash & 0x7FFFFFFFFFFFFFFF;
}
