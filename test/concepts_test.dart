import 'dart:convert';
import 'dart:io';

import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/concepts/board_concepts.dart';
import 'package:chess_mortem/model/concepts/concept.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

Position _fen(String fen) => Chess.fromSetup(Setup.parseFen(fen));

/// The candidates for [san] played in [fen].
List<Concept> _detect(
  String fen,
  String san, {
  PreviousMove? previous,
  EarlierCapture? earlierCapture,
  List<String> betterUci = const [],
  List<String> replyUci = const [],
  Classification? verdict,
  String? openingName,
}) {
  final before = _fen(fen);
  return detectConcepts(
    ConceptInput(
      before: before,
      played: before.parseSan(san)!,
      previous: previous,
      earlierCapture: earlierCapture,
      betterUci: betterUci,
      replyUci: replyUci,
      verdict: verdict,
      openingName: openingName,
    ),
  );
}

Matcher _has(ConceptKind kind, Frame frame, [String? square]) => contains(
  Concept(
    kind,
    frame,
    object: square == null ? null : Square.fromName(square),
    evidence: '',
  ),
);

Matcher _lacks(ConceptKind kind) =>
    isNot(contains(predicate<Concept>((c) => c.kind == kind)));

void main() {
  test('the kinds are concepts.json, id for id and frame for frame', () {
    final json =
        jsonDecode(File('lib/model/concepts/concepts.json').readAsStringSync())
            as Map<String, dynamic>;
    final concepts = {
      for (final c in json['concepts'] as List)
        (c as Map<String, dynamic>)['id'] as String: {
          for (final f in c['frames'] as List) Frame.values.byName(f as String),
        },
    };
    expect({for (final k in ConceptKind.values) k.id}, concepts.keys.toSet());
    for (final kind in ConceptKind.values) {
      expect(kind.frames, concepts[kind.id], reason: kind.id);
    }
  });

  group('does', () {
    test('a central pawn move', () {
      expect(
        _detect(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          'e4',
        ),
        _has(ConceptKind.centralControl, Frame.does, 'e4'),
      );
    });

    test('a pawn move that opens the way for a bishop still at home', () {
      // A reviewer: "clearing the way for their B to jump into action".
      expect(
        _detect(
          'r1bqk1nr/pppp1ppp/2n5/2b1p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R w KQkq - 4 4',
          'd3',
        ),
        _has(ConceptKind.developPiece, Frame.does, 'c1'),
      );
    });

    test('the last piece off the castling path', () {
      expect(
        _detect(
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 2',
          'Bc4',
        ),
        allOf(
          _has(ConceptKind.enableCastling, Frame.does),
          _has(ConceptKind.developPiece, Frame.does, 'c4'),
        ),
      );
    });

    test('taking back what was just taken', () {
      expect(
        _detect(
          'rnbqkbnr/pp1p1ppp/8/2pp4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
          'exd5',
          previous: (to: Square.d5, captured: true),
        ),
        _has(ConceptKind.recapture, Frame.does, 'd5'),
      );
    });

    test('a bishop stepping away from an equal attacker', () {
      // A reviewer: "Your bishop steps away from the knight's attack."
      expect(
        _detect(
          'r1bq1k1r/pp1n1ppp/3Np3/3pP3/1n1P4/3B1N2/PP3PPP/R2Q1RK1 w - - 2 14',
          'Bb1',
        ),
        _has(ConceptKind.escapeAttack, Frame.does, 'b1'),
      );
    });

    test('a queen pinning a pawn to the king', () {
      expect(
        _detect(
          'r1b2rk1/pp4p1/4pb1p/2R4Q/3P4/3BB3/qP4PP/5RK1 w - - 0 21',
          'Qg6',
        ),
        _has(ConceptKind.pin, Frame.does, 'g7'),
      );
    });

    test('a knight fork of king and rook, named by the rook', () {
      final found = _detect('r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1', 'Nc7+');
      expect(found, _has(ConceptKind.fork, Frame.does, 'a8'));
      expect(found, _has(ConceptKind.check, Frame.does));
    });

    test('a passed pawn pushed', () {
      expect(
        _detect('8/p7/4k3/8/2P5/8/5K2/8 w - - 0 1', 'c5'),
        _has(ConceptKind.passedPawn, Frame.does, 'c5'),
      );
    });

    test('the kings in opposition', () {
      expect(
        _detect('8/p7/4k3/8/8/3K4/P7/8 w - - 0 1', 'Ke4'),
        _has(ConceptKind.opposition, Frame.does, 'e6'),
      );
    });

    test('a move out of check', () {
      expect(
        _detect('4k3/4r3/8/8/8/8/8/4K3 w - - 0 1', 'Kd1'),
        allOf(
          _has(ConceptKind.escapeCheck, Frame.does, 'd1'),
          _lacks(ConceptKind.kingActivity),
        ),
      );
    });

    test('taking the checking piece is the capture, not an escape', () {
      // The rook on e2 checks the king and nothing guards it.
      expect(
        _detect('3rk3/8/8/8/8/8/4r3/R3K3 w - - 0 1', 'Kxe2'),
        allOf(
          _has(ConceptKind.captureFree, Frame.does, 'e2'),
          _lacks(ConceptKind.escapeCheck),
        ),
      );
      // The king takes a knight on its way out of a rook's check.
      expect(
        _detect('4k3/4r3/8/8/8/8/8/3nK3 w - - 0 1', 'Kxd1'),
        _has(ConceptKind.escapeCheck, Frame.does, 'd1'),
      );
    });

    test('a quiet developing move is not a capture or a tactic', () {
      final found = _detect(
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        'Nf3',
      );
      for (final kind in [
        ConceptKind.capture,
        ConceptKind.fork,
        ConceptKind.pin,
        ConceptKind.hangingPiece,
        ConceptKind.escapeAttack,
      ]) {
        expect(found, _lacks(kind));
      }
      expect(found, _has(ConceptKind.developPiece, Frame.does, 'f3'));
      expect(found, _has(ConceptKind.attackPiece, Frame.does, 'e5'));
    });
  });

  group('threatens', () {
    test('a queen lining up mate on f7', () {
      expect(
        _detect(
          'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3',
          'Qh5',
        ),
        _has(ConceptKind.mateThreat, Frame.threatens),
      );
    });
  });

  group('allows', () {
    test('a bishop left where a pawn takes it', () {
      expect(
        _detect('4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1', 'Bg5'),
        _has(ConceptKind.hangingPiece, Frame.allows, 'g5'),
      );
    });

    test('the reply is read from the opponent: a knight fork', () {
      // 1.Kf1?? Nd2+ forks the king and the queen on b3.
      final found = _detect(
        '4k3/8/8/8/4n3/1Q6/8/4K3 w - - 0 1',
        'Kf1',
        replyUci: ['e4d2'],
      );
      expect(found, _has(ConceptKind.fork, Frame.allows, 'b3'));
    });
  });

  group('better', () {
    test('only when the move was not the engine\'s', () {
      const fen = 'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1';
      expect(
        _detect(fen, 'Kd2', betterUci: ['b5c7', 'e8d7']),
        _has(ConceptKind.fork, Frame.better, 'a8'),
      );
      expect(
        _detect(fen, 'Nc7+', betterUci: ['b5c7', 'e8d7']),
        isNot(contains(predicate<Concept>((c) => c.frame == Frame.better))),
      );
    });
  });

  group('ignoring a threat', () {
    // Byrne-Fischer 1956, 17...Be6!!: the queen on b6 stays attacked by the
    // bishop on c5.
    const fischer =
        'r3r1k1/pp3pbp/1qp3p1/2B5/2BP2b1/Q1n2N2/P4PPP/3R1K1R b - - 3 17';

    test('the engine\'s own quiet move ignores it on purpose', () {
      final found = _detect(fischer, 'Be6', betterUci: ['g4e6']);
      expect(found, _has(ConceptKind.ignoredThreat, Frame.does, 'b6'));
      expect(found, isNot(_has(ConceptKind.ignoredThreat, Frame.allows, 'b6')));
    });

    test('anyone else\'s move leaves it: a weakness', () {
      final found = _detect(fischer, 'Be6', betterUci: ['g4f3']);
      expect(found, isNot(_has(ConceptKind.ignoredThreat, Frame.does, 'b6')));
      expect(found, _has(ConceptKind.ignoredThreat, Frame.allows, 'b6'));
    });

    test('without the engine\'s line nothing is claimed on purpose', () {
      expect(
        _detect(fischer, 'Be6'),
        isNot(_has(ConceptKind.ignoredThreat, Frame.does, 'b6')),
      );
    });

    test('a check or a capture forces play; it ignores nothing', () {
      for (final (san, uci) in [('Re1+', 'e8e1'), ('Nxd1', 'c3d1')]) {
        expect(
          _detect(fischer, san, betterUci: [uci]),
          isNot(_has(ConceptKind.ignoredThreat, Frame.does, 'b6')),
          reason: san,
        );
      }
    });

    test('a pawn left en prise is not worth the line', () {
      // 1.e4 Nf6 2.a3: the e4 pawn stays attacked.
      expect(
        _detect(
          'rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2',
          'a3',
          betterUci: ['a2a3'],
        ),
        isNot(
          contains(
            predicate<Concept>(
              (c) =>
                  c.kind == ConceptKind.ignoredThreat && c.frame == Frame.does,
            ),
          ),
        ),
      );
    });

    test('the better move can ignore it too', () {
      final found = _detect(fischer, 'Qb5', betterUci: ['g4e6']);
      expect(found, _has(ConceptKind.ignoredThreat, Frame.better, 'b6'));
    });
  });

  group('from the verdict and the book', () {
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    test('Great is the only move, Miss the missed win', () {
      expect(
        _detect(start, 'e4', verdict: Classification.great),
        _has(ConceptKind.onlyMove, Frame.does),
      );
      expect(
        _detect(start, 'e4', verdict: Classification.miss),
        _has(ConceptKind.missedWin, Frame.better),
      );
    });

    test('a book move carries its opening name', () {
      expect(
        _detect(start, 'e4', openingName: "King's Pawn Game"),
        _has(ConceptKind.openingName, Frame.does),
      );
    });

    test('a generic line is always a candidate, in every frame it takes', () {
      final found = _detect(start, 'a3', betterUci: ['e2e4']);
      for (final frame in ConceptKind.genericQuality.frames) {
        expect(found, _has(ConceptKind.genericQuality, frame));
      }
    });
  });

  group('claims a detector must not make', () {
    test('a push to the seventh threatens to promote; it does not promote', () {
      final found = _detect('8/8/4Bp1P/4bKp1/6P1/p7/1k6/8 w - - 1 53', 'h7');
      expect(found, _has(ConceptKind.promotion, Frame.threatens, 'h7'));
      expect(found, isNot(_has(ConceptKind.promotion, Frame.does, 'h7')));
    });

    test('a reply pushing to the seventh is not an allowed promotion', () {
      final found = _detect(
        '8/1b6/4kPP1/1p2P3/pP3K2/P7/4p1r1/4R3 b - - 0 40',
        'Bd5',
        replyUci: ['g6g7', 'e6f7'],
      );
      expect(
        found.where(
          (c) => c.kind == ConceptKind.promotion && c.frame == Frame.allows,
        ),
        isEmpty,
      );
    });

    test('a pawn that was passed already is pushed, not created', () {
      final found = _detect('8/5K1k/8/6P1/8/8/8/8 w - - 5 70', 'g6+');
      final passed = found.firstWhere(
        (c) => c.kind == ConceptKind.passedPawn && c.frame == Frame.does,
      );
      expect(passed.evidence, contains('pushes the passed pawn'));
    });

    test('no fork when a target can take the forking piece', () {
      // Qg4 hits the queen on g3, which just trades itself off.
      expect(
        _detect(
          'r4r2/ppp3pk/2n1p2p/2b1p3/4P3/2NP2qP/PPP1Q1P1/R1BK3R w - - 4 18',
          'Qg4',
        ),
        isNot(
          contains(
            predicate<Concept>(
              (c) => c.kind == ConceptKind.fork && c.frame == Frame.does,
            ),
          ),
        ),
      );
    });

    test('a capture taken back for what it took is not hanging', () {
      // Nxd5 Nxd5 exd5: an even trade.
      expect(
        _detect(
          'r5k1/pp3ppp/4rn2/1B1pq2b/4P3/2NP1P1P/PPP5/R4QRK w - - 3 20',
          'Nxd5',
        ),
        isNot(_has(ConceptKind.hangingPiece, Frame.allows, 'd5')),
      );
    });

    test('a piece the reply takes at once is not moved to safety', () {
      // h6 leaves h7, but the engine's reply Bxh6 takes it on h6.
      expect(
        _detect(
          'r1bq1rk1/pp2nppp/2n1p3/2ppP2Q/3P4/P1PB4/2P2PPP/R1B1K1NR b KQ - 6 9',
          'h6',
          replyUci: ['c1h6', 'g7h6', 'h5h6'],
        ),
        isNot(_has(ConceptKind.escapeAttack, Frame.does, 'h6')),
      );
      // hxg3 is a capture that is taken straight back: hxg3 Kxg3.
      expect(
        _detect(
          '3kr3/8/1p2P3/p1p1R3/2P2K1p/P5p1/1PB4P/8 w - - 0 34',
          'hxg3',
          replyUci: ['h4g3', 'f4g3'],
        ),
        isNot(_has(ConceptKind.escapeAttack, Frame.does, 'g3')),
      );
    });

    test('a pawn taken straight after was not isolated by the move', () {
      // hxg3 hxg3 leaves Black's g3 pawn alone, but Kxg3 takes it.
      expect(
        _detect(
          '3kr3/8/1p2P3/p1p1R3/2P2K1p/P5p1/1PB4P/8 w - - 0 34',
          'hxg3',
          replyUci: ['h4g3', 'f4g3'],
        ),
        _lacks(ConceptKind.isolatedPawn),
      );
    });

    test('taking back what the move took is not a win for the opponent', () {
      const fen =
          'r1bqk1nr/1pp1b1p1/p1np3p/4pp2/2BPP3/2N2N1P/PPP2PP1/R1BQK2R w KQkq - 0 8';
      // dxe5 dxe5: a pawn for a pawn.
      final trade = _detect(fen, 'dxe5', replyUci: ['d6e5', 'd1e2']);
      expect(trade, isNot(_has(ConceptKind.winMaterial, Frame.allows, 'e5')));
      // Nxe5 dxe5: a knight for a pawn is a loss.
      expect(
        _detect(fen, 'Nxe5', replyUci: ['d6e5', 'd1h5']),
        _has(ConceptKind.winMaterial, Frame.allows, 'e5'),
      );
    });

    test('pawns the reply doubles are not the played move\'s doing', () {
      expect(
        _detect(
          'r2q1rk1/ppp2pp1/2np3p/2bNp2B/3PP3/2P3Q1/PP3PPP/R1B1K2R b KQ - 0 11',
          'Kh7',
          replyUci: ['d4c5'],
        ),
        isNot(
          contains(
            predicate<Concept>(
              (c) =>
                  c.kind == ConceptKind.doubledPawns && c.frame == Frame.does,
            ),
          ),
        ),
      );
    });
  });

  test('an illegal move has no candidates', () {
    final before = _fen(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    );
    expect(
      detectConcepts(
        ConceptInput(
          before: before,
          played: const NormalMove(from: Square.e2, to: Square.e5),
        ),
      ),
      isEmpty,
    );
  });

  group('a capture is said as a capture', () {
    test('a pawn that takes is not "moved to safety"', () {
      final found = _detect('4k3/8/8/4p3/3P4/8/8/4K3 w - - 0 1', 'dxe5');
      expect(found, _lacks(ConceptKind.escapeAttack));
      expect(found, _has(ConceptKind.capture, Frame.does, 'e5'));
    });

    test('taking back after a check in between is not free', () {
      // Black's rook took on e1, White checked, Black blocked: Nxe1 now
      // only takes back.
      final found = _detect(
        '3Q1bk1/8/8/8/8/5N2/7K/4r3 w - - 0 1',
        'Nxe1',
        earlierCapture: (to: Square.e1, took: Role.rook),
      );
      expect(found, _has(ConceptKind.recapture, Frame.does, 'e1'));
      expect(found, _lacks(ConceptKind.captureFree));
    });

    test('without the earlier capture the same rook is free', () {
      final found = _detect('3Q1bk1/8/8/8/8/5N2/7K/4r3 w - - 0 1', 'Nxe1');
      expect(found, _has(ConceptKind.captureFree, Frame.does, 'e1'));
    });
  });

  group('luft', () {
    test('the pawn in front of the king stepping up', () {
      expect(
        _detect('6k1/5ppp/8/8/8/8/5PPP/6K1 w - - 0 1', 'h3'),
        _has(ConceptKind.luft, Frame.does, 'h3'),
      );
    });

    test('not a pawn storm from the third rank', () {
      expect(
        _detect('6k1/5p1p/6p1/8/8/8/5PPP/6K1 b - - 0 1', 'g5'),
        _lacks(ConceptKind.luft),
      );
    });

    test('not a check that offers the pawn', () {
      expect(
        _detect('8/8/8/8/1k6/8/2P5/1K6 w - - 0 1', 'c3+'),
        _lacks(ConceptKind.luft),
      );
    });
  });

  test('a check that also hits a pawn is not a fork', () {
    expect(
      _detect('6k1/1p6/8/8/8/8/8/3Q2K1 w - - 0 1', 'Qd5+'),
      _lacks(ConceptKind.fork),
    );
  });

  group('a pawn pin', () {
    test('along its own file, with nothing beside it, holds nothing', () {
      expect(
        _detect('7R/8/8/p7/k7/8/8/6K1 w - - 0 1', 'Ra8'),
        _lacks(ConceptKind.pin),
      );
    });

    test('holds when the pawn guards a piece off the line', () {
      expect(
        _detect('7R/8/8/p7/kn6/8/8/6K1 w - - 0 1', 'Ra8'),
        _has(ConceptKind.pin, Frame.does, 'a5'),
      );
    });
  });

  test('taking back what was just taken is never free', () {
    final found = _detect(
      '4k3/8/3p4/4N3/8/8/8/4K3 b - - 0 1',
      'dxe5',
      previous: (to: Square.e5, captured: true),
    );
    expect(found, _has(ConceptKind.recapture, Frame.does, 'e5'));
    expect(found, _lacks(ConceptKind.captureFree));
  });

  test('a piece taken removes a defender only of what it guarded', () {
    // Qxf8+ takes a rook that never guarded the bishop on d6; the bishop is
    // merely attacked by the queen now on f8.
    expect(
      _detect(
        '4kr2/r4pQp/pq1bp3/5n2/1pN2P2/8/PPP3BP/1K1R3R w - - 3 25',
        'Qxf8+',
      ),
      isNot(_has(ConceptKind.removeDefender, Frame.does, 'd6')),
    );
  });

  test('a defender taken that its target takes back is a trade', () {
    // Bxe6 takes the guard of f7, but the f7 pawn takes back on e6.
    expect(
      _detect(
        'r2qkbnr/ppp2p1p/2npb1p1/8/2B1P3/1QN2N2/PP3PPP/R1B1K2R w KQkq - 2 8',
        'Bxe6',
      ),
      isNot(_has(ConceptKind.removeDefender, Frame.does, 'f7')),
    );
  });

  test('a defender taken removes nothing the capturer itself attacks', () {
    // Nxc6 took a knight that guarded d8, but the queen is lost only to the
    // knight now on c6.
    expect(
      _detect(
        'r1bq1rk1/pp2bppp/2np4/8/2BN4/4nQ2/PPP2PPP/RN3RK1 w - - 0 11',
        'Nxc6',
      ),
      isNot(_has(ConceptKind.removeDefender, Frame.does, 'd8')),
    );
  });

  test('a pin the move makes is the pin, not a pinned piece attacked', () {
    // Qe5 pins the g7 pawn to the king itself.
    expect(
      _detect(
        '6rk/1p4pp/3QN1r1/3P1p2/p3p3/P1P4P/1P3PP1/3R1RK1 w - - 1 33',
        'Qe5',
      ),
      isNot(_has(ConceptKind.exploitPin, Frame.does, 'g7')),
    );
    // Re1 lines up on the e5 pawn and the king behind it.
    expect(
      _detect(
        'r1b1k1nr/ppp2ppp/2qb4/4p3/8/5N2/PPPP1PPP/RNBQ1RK1 w kq - 2 7',
        'Re1',
      ),
      isNot(_has(ConceptKind.exploitPin, Frame.does, 'e5')),
    );
  });
}
