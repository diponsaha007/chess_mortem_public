import 'dart:io' as io;
import 'dart:typed_data';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/opening_book.dart';
import 'package:chess_mortem/model/opening_key.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';

Position _play(String sans) {
  var position = Chess.initial as Position;
  for (final san in sans.split(' ')) {
    position = position.play(position.parseSan(san)!);
  }
  return position;
}

OpeningBook _bookOf(Map<String, String> byLine) => OpeningBook.decode(
  OpeningBook.encode({
    for (final entry in byLine.entries)
      openingKey(_play(entry.key)): entry.value,
  }),
);

void main() {
  group('openingKey', () {
    test('two orders that reach the same position share a key', () {
      // 1.e4 e5 2.Nf3 and 1.Nf3 e5 2.e4 are the same position.
      expect(openingKey(_play('e4 e5 Nf3')), openingKey(_play('Nf3 e5 e4')));
    });

    test('different positions get different keys', () {
      expect(openingKey(_play('e4')), isNot(openingKey(_play('d4'))));
    });

    test('the key ignores the move counters but not castling rights', () {
      final epd = openingEpd(_play('e4 e5 Nf3 Nc6'));
      expect(epd.split(' '), hasLength(4));
      expect(epd, contains('KQkq'));
    });

    test('the key is non-negative, so it round-trips through uint64', () {
      for (final line in ['e4', 'd4 d5', 'c4 e5 Nc3', 'Nf3 Nf6 g3 g6']) {
        expect(openingKey(_play(line)), greaterThanOrEqualTo(0));
      }
    });
  });

  group('OpeningBook', () {
    test('encodes and decodes back to the same entries', () {
      final book = _bookOf({
        'e4': 'B00 King\'s Pawn Game',
        'e4 c5': 'B20 Sicilian Defense',
        'd4': 'A40 Queen\'s Pawn Game',
      });

      expect(book.length, 3);
      expect(book.nameFor(_play('e4 c5')), 'B20 Sicilian Defense');
      expect(book.nameFor(_play('d4')), 'A40 Queen\'s Pawn Game');
      expect(book.nameFor(_play('h4')), isNull);
    });

    test('a name shared by several positions is stored once', () {
      final bytes = OpeningBook.encode({
        1: 'B20 Sicilian Defense',
        2: 'B20 Sicilian Defense',
        3: 'B20 Sicilian Defense',
      });
      final decoded = OpeningBook.decode(bytes);
      expect(decoded.length, 3);
      expect(decoded.nameFor(_play('e4')), isNull);
      // One 20-byte name plus three 12-byte records plus the header.
      expect(bytes.length, lessThan(80));
    });

    test('an empty book misses everything', () {
      expect(const OpeningBook.empty().isEmpty, isTrue);
      expect(const OpeningBook.empty().nameFor(_play('e4')), isNull);
    });

    test('a corrupt or truncated asset degrades to an empty book', () {
      expect(OpeningBook.decode(Uint8List(0)).isEmpty, isTrue);
      expect(OpeningBook.decode(Uint8List.fromList([1, 2, 3])).isEmpty, isTrue);

      final good = OpeningBook.encode({1: 'A00 Test'});
      expect(
        OpeningBook.decode(good.sublist(0, good.length - 4)).isEmpty,
        isTrue,
      );
      final wrongMagic = Uint8List.fromList(good)..[0] = 0x58;
      expect(OpeningBook.decode(wrongMagic).isEmpty, isTrue);
    });
  });

  group('the shipped assets/openings.bin', () {
    // Reads the real generated asset, so a corrupt or stale checkout is
    // caught here rather than as a silently empty book on a device.
    // dart:io is aliased: dartchess exports a board-file enum called `File`.
    final book = OpeningBook.decode(
      io.File(OpeningBook.assetPath).readAsBytesSync(),
    );

    test('decodes to a book with thousands of positions', () {
      expect(book.isEmpty, isFalse);
      expect(book.length, greaterThan(5000));
    });

    test('names the openings you would expect', () {
      expect(
        book.nameFor(_play('e4 e5 Nf3 Nc6 Bc4 Bc5')),
        'C50 Italian Game: Giuoco Piano',
      );
      expect(
        book.nameFor(_play('e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6')),
        'B90 Sicilian Defense: Najdorf Variation',
      );
      expect(
        book.nameFor(_play('d4 Nf6 c4 g6 Nc3 Bg7')),
        'E61 King\'s Indian Defense',
      );
    });

    test('finds a line reached by transposition', () {
      // 1.Nf3 e5 2.e4 is 1.e4 e5 2.Nf3 with the moves swapped.
      expect(
        book.nameFor(_play('Nf3 e5 e4')),
        book.nameFor(_play('e4 e5 Nf3')),
      );
      expect(book.nameFor(_play('Nf3 e5 e4')), isNotNull);
    });

    test('a middlegame position is not in it', () {
      expect(book.nameFor(_play('e4 e5 Qh5 Nc6 Bc4 Nf6 Qxf7')), isNull);
    });
  });

  group('AnalysisSession opening tagging', () {
    Future<AnalysisSession> sessionWith(OpeningBook book, String pgn) async {
      final session = AnalysisSession(engine: FakeEngine(), book: book);
      await session.loadPgn(pgn);
      return session;
    }

    test('labels the book prefix and stops at the first miss', () async {
      final book = _bookOf({
        'e4': 'B00 King\'s Pawn Game',
        'e4 e5': 'C20 King\'s Pawn Game',
        // 2.Nf3 is deliberately absent.
        'e4 e5 Nf3 Nc6': 'C44 King\'s Knight Opening',
      });
      final session = await sessionWith(
        book,
        '[Event "T"]\n\n1. e4 e5 2. Nf3 Nc6 *\n',
      );
      final mainline = session.tree.mainline;

      expect(mainline[0].openingName, 'B00 King\'s Pawn Game');
      expect(mainline[1].openingName, 'C20 King\'s Pawn Game');
      expect(mainline[2].isBook, isFalse, reason: 'the book run ended here');
      // Even though this position IS in the book, the run already stopped.
      expect(mainline[3].isBook, isFalse);
      expect(session.openingName, 'C20 King\'s Pawn Game');
    });

    test('no book means no move is ever book', () async {
      final session = await sessionWith(
        const OpeningBook.empty(),
        '[Event "T"]\n\n1. e4 e5 *\n',
      );
      expect(session.tree.mainline.every((n) => !n.isBook), isTrue);
      expect(session.openingName, isNull);
    });

    test('book moves are skipped when stepping through key moves', () async {
      final session = await sessionWith(
        _bookOf({'e4': 'B00 King\'s Pawn Game'}),
        '[Event "T"]\n\n1. e4 e5 *\n',
      );
      // Force the book move to look terrible; it must still be skipped.
      session.tree.mainline.first.classification = Classification.blunder;
      expect(session.nextKeyMove, isNull);
    });
  });
}
