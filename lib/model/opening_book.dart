import 'dart:convert';
import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

import 'opening_key.dart';

/// Named opening positions from the generated `assets/openings.bin`. Pure
/// Dart, so the book's build script and the tests share it.
class OpeningBook {
  const OpeningBook._(this._byKey);

  /// A book that knows nothing: no move is ever a book move.
  const OpeningBook.empty() : _byKey = const {};

  final Map<int, String> _byKey;

  static const assetPath = 'assets/openings.bin';

  static const _magic = 'CMOB';
  static const _version = 1;
  static const _headerBytes = 16;
  static const _recordBytes = 12;

  bool get isEmpty => _byKey.isEmpty;
  int get length => _byKey.length;

  /// The opening name for [position], e.g. "C50 Italian Game: Giuoco Piano".
  /// Null when the position is not in the book.
  String? nameFor(Position position) => _byKey[openingKey(position)];

  /// Reads the binary format. Anything malformed gives an empty book.
  factory OpeningBook.decode(Uint8List bytes) {
    try {
      if (bytes.length < _headerBytes) return const OpeningBook.empty();
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < _magic.length; i++) {
        if (bytes[i] != _magic.codeUnitAt(i)) return const OpeningBook.empty();
      }
      if (bytes[4] != _version) return const OpeningBook.empty();

      final count = data.getUint32(8, Endian.little);
      final namesLength = data.getUint32(12, Endian.little);
      final namesStart = _headerBytes + count * _recordBytes;
      if (namesStart + namesLength != bytes.length) {
        return const OpeningBook.empty();
      }

      // Each distinct name is decoded once and shared by its positions.
      final namesBlob = bytes.sublist(namesStart, namesStart + namesLength);
      final byOffset = <int, String>{};
      var lineStart = 0;
      for (var i = 0; i <= namesBlob.length; i++) {
        if (i == namesBlob.length || namesBlob[i] == 0x0a) {
          if (i > lineStart) {
            byOffset[lineStart] = utf8.decode(
              namesBlob.sublist(lineStart, i),
              allowMalformed: true,
            );
          }
          lineStart = i + 1;
        }
      }

      final byKey = <int, String>{};
      for (var i = 0; i < count; i++) {
        final offset = _headerBytes + i * _recordBytes;
        final key = data.getUint64(offset, Endian.little);
        final name = byOffset[data.getUint32(offset + 8, Endian.little)];
        if (name != null) byKey[key] = name;
      }
      return OpeningBook._(byKey);
    } catch (_) {
      return const OpeningBook.empty();
    }
  }

  /// Builds the binary format from `positionKey -> openingName`.
  static Uint8List encode(Map<int, String> byKey) {
    final names = <String, int>{};
    final blob = BytesBuilder();
    for (final name in byKey.values) {
      if (names.containsKey(name)) continue;
      names[name] = blob.length;
      blob.add(utf8.encode(name));
      blob.addByte(0x0a);
    }
    final namesBytes = blob.takeBytes();

    final out = Uint8List(
      _headerBytes + byKey.length * _recordBytes + namesBytes.length,
    );
    final data = ByteData.sublistView(out);
    for (var i = 0; i < _magic.length; i++) {
      out[i] = _magic.codeUnitAt(i);
    }
    out[4] = _version;
    data.setUint32(8, byKey.length, Endian.little);
    data.setUint32(12, namesBytes.length, Endian.little);

    var offset = _headerBytes;
    for (final entry in byKey.entries) {
      data.setUint64(offset, entry.key, Endian.little);
      data.setUint32(offset + 8, names[entry.value]!, Endian.little);
      offset += _recordBytes;
    }
    out.setRange(offset, out.length, namesBytes);
    return out;
  }
}
