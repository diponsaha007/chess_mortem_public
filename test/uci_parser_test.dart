import 'package:chess_mortem/engine/uci_parser.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toEngineUci', () {
    Position castleReady() {
      Position position = Chess.initial;
      for (final san in ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']) {
        position = position.play(position.parseSan(san)!);
      }
      return position;
    }

    test('castling goes back to the king\'s two-square step', () {
      // searchmoves is matched against the engine's own strings; e1h1 would
      // be silently ignored and the runner-up search would lose a move.
      expect(toEngineUci(castleReady(), 'e1h1'), 'e1g1');
    });

    test('it is the reverse of normalizeUciLine', () {
      final position = castleReady();
      final ours = normalizeUciLine(position, ['e1g1']).single;
      expect(toEngineUci(position, ours), 'e1g1');
    });

    test('every other move is unchanged', () {
      expect(toEngineUci(castleReady(), 'd2d3'), 'd2d3');
      expect(toEngineUci(castleReady(), 'h1g1'), 'h1g1');
    });
  });

  group('parseInfoLine', () {
    test('parses a real Stockfish info line', () {
      const line =
          'info depth 15 seldepth 22 multipv 1 score cp -37 '
          'nodes 400913 nps 1146680 hashfull 152 tbhits 0 time 350 '
          'pv e7e5 g1f3 b8c6 f1b5 a7a6';
      final info = parseInfoLine(line)!;

      expect(info.depth, 15);
      expect(info.cp, -37);
      expect(info.mateIn, isNull);
      expect(info.pv, ['e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6']);
    });

    test('parses a mate score', () {
      final info = parseInfoLine('info depth 12 score mate -3 pv h7h8')!;
      expect(info.mateIn, -3);
      expect(info.cp, isNull);
    });

    test('reads which line of a MultiPV search this is', () {
      const second =
          'info depth 20 seldepth 26 multipv 2 score cp -140 '
          'nodes 900000 nps 1000000 time 900 pv d7d6 d2d4 g8f6';
      final info = parseInfoLine(second)!;
      expect(info.multipv, 2);
      expect(info.cp, -140);
      expect(info.pv.first, 'd7d6');
    });

    test('a single-line search says rank 1 without being told', () {
      // Stockfish omits `multipv` entirely at MultiPV 1, and a rank of 0 or
      // null there would lose the best line rather than the alternatives.
      expect(parseInfoLine('info depth 12 score cp 20 pv e2e4')!.multipv, 1);
    });

    test('returns null for lines without a score', () {
      expect(
        parseInfoLine('info depth 15 currmove e2e4 currmovenumber 1'),
        isNull,
      );
      expect(parseInfoLine('Stockfish 16 by the Stockfish developers'), isNull);
      expect(parseInfoLine('bestmove e2e4 ponder e7e5'), isNull);
    });
  });

  group('parseBestMoveLine', () {
    test('parses a normal best move', () {
      expect(parseBestMoveLine('bestmove e2e4 ponder e7e5'), 'e2e4');
    });

    test('parses a promotion', () {
      expect(parseBestMoveLine('bestmove e7e8q'), 'e7e8q');
    });

    test('terminal position has no best move', () {
      expect(parseBestMoveLine('bestmove (none)'), isNull);
    });

    test('other lines return null', () {
      expect(parseBestMoveLine('info depth 15 score cp 10'), isNull);
    });
  });

  group('toWhitePerspective', () {
    const info = UciInfo(depth: 15, cp: 50, pv: ['e7e5']);

    test('keeps sign when white is to move', () {
      final eval = toWhitePerspective(
        info: info,
        bestMoveUci: 'e2e4',
        sideToMove: Side.white,
      );
      expect(eval.cp, 50);
    });

    test('negates score when black is to move', () {
      final eval = toWhitePerspective(
        info: info,
        bestMoveUci: 'e7e5',
        sideToMove: Side.black,
      );
      expect(eval.cp, -50);
    });

    test('negates mate scores too', () {
      const mateInfo = UciInfo(depth: 15, mateIn: 2);
      final eval = toWhitePerspective(
        info: mateInfo,
        bestMoveUci: 'a1a2',
        sideToMove: Side.black,
      );
      expect(eval.mateIn, -2);
    });

    test('a delivered mate is won by the side that is NOT to move', () {
      // `score mate 0` is the position itself being checkmate, and negating
      // it leaves it at 0 — so the sign cannot say who won. Whoever is to
      // move is the side that got mated.
      const mated = UciInfo(depth: 0, mateIn: 0);

      final whiteMated = toWhitePerspective(
        info: mated,
        bestMoveUci: null,
        sideToMove: Side.black,
      );
      expect(whiteMated.isCheckmate, isTrue);
      expect(whiteMated.matedSide, Side.black);
      expect(whiteMated.cpCeiled, EngineEval.cpCeiling);
      expect(whiteMated.winPctWhite, greaterThan(90));

      final blackMated = toWhitePerspective(
        info: mated,
        bestMoveUci: null,
        sideToMove: Side.white,
      );
      expect(blackMated.matedSide, Side.white);
      expect(blackMated.cpCeiled, -EngineEval.cpCeiling);
      expect(blackMated.winPctWhite, lessThan(10));
    });

    test('caps the PV at 10 plies', () {
      final longPv = List.generate(20, (_) => 'e2e4');
      final eval = toWhitePerspective(
        info: UciInfo(depth: 15, cp: 0, pv: longPv),
        bestMoveUci: 'e2e4',
        sideToMove: Side.white,
      );
      expect(eval.pvUci, hasLength(10));
    });

    test('no alternatives means no alternatives — not a tie', () {
      final eval = toWhitePerspective(
        info: info,
        bestMoveUci: 'e2e4',
        sideToMove: Side.white,
      );
      expect(eval.alternatives, isEmpty);
      expect(eval.secondBest, isNull);
    });

    test('runner-up lines get the same flip as the main score', () {
      // The whole point of carrying them: they are compared against the best
      // line, so one of the two being in the engine's perspective and the
      // other in White's would invent a gap out of nothing.
      final eval = toWhitePerspective(
        info: const UciInfo(depth: 20, cp: 30, pv: ['d7d5']),
        bestMoveUci: 'd7d5',
        sideToMove: Side.black,
        alternatives: const [
          UciInfo(depth: 20, cp: -40, pv: ['g8f6'], multipv: 2),
          UciInfo(depth: 20, mateIn: -1, pv: ['h7h6'], multipv: 3),
        ],
      );

      expect(eval.cp, -30);
      expect(eval.alternatives, hasLength(2));
      expect(eval.secondBest!.moveUci, 'g8f6');
      expect(eval.secondBest!.cp, 40);
      expect(eval.alternatives.last.mateIn, 1);
      // Black to move, so Black's best line is the one with the lowest
      // White-perspective score.
      expect(eval.secondBest!.winPctWhite, greaterThan(eval.winPctWhite));
    });

    test('alternatives are dropped when rank 1 is not the bestmove', () {
      // A search cut short by `stop` can leave the last `info` and the
      // `bestmove` on different moves. The gap is only ever read as "how far
      // ahead the best move was", so measured against the wrong move it
      // belongs to a move nobody played and nobody was shown.
      final eval = toWhitePerspective(
        info: const UciInfo(depth: 20, cp: 300, pv: ['d2d4']),
        bestMoveUci: 'e2e4',
        sideToMove: Side.white,
        alternatives: const [
          UciInfo(depth: 20, cp: -300, pv: ['c2c4'], multipv: 2),
        ],
      );
      expect(eval.bestMoveUci, 'e2e4');
      expect(eval.alternatives, isEmpty);
      expect(eval.secondBest, isNull);
    });

    test('a terminal search keeps no alternatives either', () {
      final eval = toWhitePerspective(
        info: const UciInfo(depth: 1, cp: 0, pv: ['e2e4']),
        bestMoveUci: null,
        sideToMove: Side.white,
        alternatives: const [
          UciInfo(depth: 1, cp: -10, pv: ['d2d4'], multipv: 2),
        ],
      );
      expect(eval.alternatives, isEmpty);
    });

    test('a line with no move is dropped rather than carried blank', () {
      final eval = toWhitePerspective(
        info: const UciInfo(depth: 15, cp: 0, pv: ['e2e4']),
        bestMoveUci: 'e2e4',
        sideToMove: Side.white,
        alternatives: const [UciInfo(depth: 15, cp: -20, multipv: 2)],
      );
      expect(eval.alternatives, isEmpty);
    });

    test('castling is written as the played move writes it', () {
      // UCI castles as e1g1; dartchess's Move.uci is e1h1. Unnormalized, a
      // castle never equalled the engine's best move and read as Excellent.
      Position position = Chess.initial;
      for (final san in ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']) {
        position = position.play(position.parseSan(san)!);
      }
      final played = position.parseSan('O-O')!.uci;

      final eval = toWhitePerspective(
        info: const UciInfo(depth: 15, cp: 20, pv: ['e1g1', 'g8f6', 'd2d3']),
        bestMoveUci: 'e1g1',
        sideToMove: Side.white,
        alternatives: const [
          UciInfo(depth: 15, cp: 10, pv: ['d2d3', 'g8f6', 'e1g1'], multipv: 2),
        ],
        position: position,
      );

      expect(eval.bestMoveUci, played);
      expect(eval.pvUci, [played, 'g8f6', 'd2d3']);
      expect(eval.alternatives.single.pvUci.last, played);
    });

    test('a best move that is illegal in the position reads as none', () {
      final eval = toWhitePerspective(
        info: const UciInfo(depth: 15, cp: 20, pv: ['e2e4']),
        bestMoveUci: 'e7e5',
        sideToMove: Side.white,
        position: Chess.initial,
      );
      expect(eval.bestMoveUci, isNull);
      expect(eval.cp, 20);
    });
  });
}
