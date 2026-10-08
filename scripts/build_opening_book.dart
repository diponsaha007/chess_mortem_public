// Generates assets/openings.bin from the lichess chess-openings dataset.
//
//   dart run scripts/build_opening_book.dart              # fetch from GitHub
//   dart run scripts/build_opening_book.dart --from <dir> # use local a.tsv..e.tsv
//
// Source: https://github.com/lichess-org/chess-openings (CC0). The TSVs have
// three columns: eco, name, pgn — e.g. "C50\tItalian Game\t1. e4 e5 2. Nf3 Nc6
// 3. Bc4".
//
// Command-line only: no Flutter import anywhere in this file's import graph,
// so it runs under plain `dart run`.
import 'dart:convert';
import 'dart:io';

import 'package:chess_mortem/model/opening_book.dart';
import 'package:chess_mortem/model/opening_key.dart';
// `File` is dart:io's here — dartchess exports a board-file enum of the same
// name that this script has no use for.
import 'package:dartchess/dartchess.dart' hide File;
import 'package:http/http.dart' as http;

const _baseUrl =
    'https://raw.githubusercontent.com/lichess-org/chess-openings/master';
const _files = ['a.tsv', 'b.tsv', 'c.tsv', 'd.tsv', 'e.tsv'];
const _outputPath = 'assets/openings.bin';

/// A move number token like "1." or "12...", which carries no move.
final _moveNumber = RegExp(r'^\d+\.+$');

Future<void> main(List<String> args) async {
  final fromIndex = args.indexOf('--from');
  final localDir = fromIndex >= 0 && fromIndex + 1 < args.length
      ? args[fromIndex + 1]
      : null;

  final rows = <_OpeningRow>[];
  for (final file in _files) {
    final text = localDir == null
        ? await _fetch('$_baseUrl/$file')
        : File('$localDir/$file').readAsStringSync();
    rows.addAll(_parseTsv(text, file));
  }
  stdout.writeln('Read ${rows.length} opening lines.');

  final lines = <(_OpeningRow, List<Position>)>[];
  var skipped = 0;
  for (final row in rows) {
    final positions = _replay(row);
    if (positions == null) {
      skipped++;
    } else {
      lines.add((row, positions));
    }
  }

  // Pass 1: a line's LAST position gets its name; on a transposition the
  // line listed first (the shorter, more general one) keeps it.
  final named = <int, String>{};
  for (final (row, positions) in lines) {
    if (positions.isEmpty) continue;
    named[openingKey(positions.last)] ??= '${row.eco} ${row.name}';
  }

  // Pass 2: every position along a line gets the latest name seen on it, so
  // a mid-line position still resolves to its opening.
  final book = <int, String>{};
  final keyToEpd = <int, String>{};
  for (final (_, positions) in lines) {
    String? currentName;
    for (final position in positions) {
      final key = openingKey(position);
      final epd = openingEpd(position);
      final clash = keyToEpd[key];
      if (clash != null && clash != epd) {
        throw StateError('Key collision: "$clash" and "$epd" share $key');
      }
      keyToEpd[key] = epd;

      currentName = named[key] ?? currentName;
      if (currentName != null) book[key] ??= currentName;
    }
  }

  final bytes = OpeningBook.encode(book);
  File(_outputPath).writeAsBytesSync(bytes);

  final distinctNames = book.values.toSet().length;
  stdout.writeln('Skipped $skipped unreplayable lines.');
  stdout.writeln(
    'Wrote $_outputPath: ${book.length} positions, '
    '$distinctNames names, ${bytes.length} bytes.',
  );

  // Prove the asset we just wrote reads back as what we put in.
  final roundTrip = OpeningBook.decode(bytes);
  if (roundTrip.length != book.length) {
    throw StateError(
      'Round-trip lost entries: '
      '${roundTrip.length} != ${book.length}',
    );
  }
  stdout.writeln('Round-trip OK.');
}

Future<String> _fetch(String url) async {
  stdout.writeln('Fetching $url');
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw HttpException('${response.statusCode} for $url');
  }
  return response.body;
}

class _OpeningRow {
  _OpeningRow(this.eco, this.name, this.pgn);
  final String eco;
  final String name;
  final String pgn;
}

List<_OpeningRow> _parseTsv(String text, String file) {
  final rows = <_OpeningRow>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    if (parts[0] == 'eco') continue; // header
    rows.add(_OpeningRow(parts[0], parts[1], parts[2]));
  }
  if (rows.isEmpty) throw StateError('No rows parsed from $file');
  return rows;
}

/// Replays [row]'s SAN moves, returning every position along the line
/// (excluding the starting position, which is in no opening). Null when a
/// move does not parse, so a bad row is skipped rather than aborting a build.
List<Position>? _replay(_OpeningRow row) {
  var position = Chess.initial as Position;
  final positions = <Position>[];
  for (final token in row.pgn.split(RegExp(r'\s+'))) {
    if (token.isEmpty || _moveNumber.hasMatch(token)) continue;
    final move = position.parseSan(token);
    if (move == null) {
      stderr.writeln('Skipping "${row.name}": cannot play "$token"');
      return null;
    }
    position = position.play(move);
    positions.add(position);
  }
  return positions;
}
