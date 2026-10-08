import 'package:chess_mortem/engine/uci_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('searchThreads', () {
    test('leaves two cores to the UI and the LLM request', () {
      expect(searchThreads(4), 2);
      expect(searchThreads(6), 4);
      expect(searchThreads(8), 6);
    });

    test('never asks for fewer than one thread', () {
      expect(searchThreads(1), 1);
      expect(searchThreads(2), 1);
      expect(searchThreads(0), 1);
    });

    test('caps out, because lazy SMP stops paying', () {
      expect(searchThreads(16), 8);
      expect(searchThreads(64), 8);
    });
  });

  group('engineNameFor', () {
    test('names the engine a setting selects', () {
      expect(engineNameFor(useLatest: false), 'Stockfish 16');
      expect(engineNameFor(useLatest: true), 'Stockfish 18');
    });
  });

  group('startupCommands', () {
    test('sets threads and hash, then waits for readyok', () {
      expect(startupCommands(threads: 6, hashMb: 128), [
        'setoption name Threads value 6',
        'setoption name Hash value 128',
        'isready',
      ]);
    });

    test('never sends uci — it would reset the options just set', () {
      // multistockfish's start() already handshakes. A second `uci` here is
      // what would silently drop the engine back to one thread.
      final commands = startupCommands(threads: 4, hashMb: 64);
      expect(commands, isNot(contains('uci')));
    });

    test('a single line sends no MultiPV — it is already the default', () {
      // The app's own call: the runner-up is a search of its own.
      expect(
        startupCommands(threads: 4, hashMb: 64),
        isNot(contains(contains('MultiPV'))),
      );
      expect(
        startupCommands(threads: 4, hashMb: 64, multiPv: 1),
        isNot(contains(contains('MultiPV'))),
      );
    });

    test('more than one line is set before the first search', () {
      // MultiPV is an option, not a `go` argument, so it has to be in place
      // here or the first position comes back with no alternatives at all.
      expect(startupCommands(threads: 6, hashMb: 128, multiPv: 3), [
        'setoption name Threads value 6',
        'setoption name Hash value 128',
        'setoption name MultiPV value 3',
        'isready',
      ]);
    });
  });

  group('goCommand', () {
    test('a plain search is just the depth', () {
      expect(goCommand(15), 'go depth 15');
    });

    test('the runner-up search is restricted to the moves it may play', () {
      expect(
        goCommand(18, searchMoves: ['a2a3', 'e1g1']),
        'go depth 18 searchmoves a2a3 e1g1',
      );
    });
  });

  group('searchLines', () {
    test('passes a sensible request through', () {
      expect(searchLines(1), 1);
      expect(searchLines(3), 3);
    });

    test('clamps what a phone cannot afford, and what makes no sense', () {
      expect(searchLines(0), 1);
      expect(searchLines(-4), 1);
      expect(searchLines(50), maxSearchLines);
    });
  });
}
