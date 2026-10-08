import 'dart:async';
import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:multistockfish/multistockfish.dart';

import '../logging/app_log.dart';
import '../model/eval.dart';
import 'engine.dart';
import 'uci_options.dart';
import 'uci_parser.dart';

/// [ChessEngine] backed by multistockfish: process lifecycle, a request
/// queue and timeouts. Parsing lives in `uci_parser.dart`.
class StockfishEngine implements ChessEngine {
  StockfishEngine({
    int? threads,
    this.hashMb = 128,
    this.flavor = StockfishFlavor.sf16,
    this.bigNetPath,
    this.smallNetPath,
  }) : threads = threads ?? searchThreads(Platform.numberOfProcessors),
       assert(
         flavor != StockfishFlavor.latestNoNNUE ||
             (bigNetPath != null && smallNetPath != null),
         'The newer engine has no embedded net; both paths are required.',
       );

  /// How long one search may run before the engine is asked to stop.
  static const _searchTimeout = Duration(seconds: 30);

  @override
  String get name => switch (flavor) {
    StockfishFlavor.latestNoNNUE => latestEngineName,
    StockfishFlavor.sf16 => bundledEngineName,
    StockfishFlavor.variant => 'Fairy-Stockfish',
  };

  /// [StockfishFlavor.latestNoNNUE] needs the two net paths below.
  final StockfishFlavor flavor;
  final String? bigNetPath;
  final String? smallNetPath;

  final int threads;

  /// Transposition table size, never cleared between positions.
  final int hashMb;

  Stockfish? _stockfish;
  StreamSubscription<String>? _outputSub;

  /// Serializes searches so two calls never read each other's output.
  Future<void> _queue = Future.value();

  /// State of the search currently in flight (null when idle).
  _Search? _search;

  /// Searches given up on whose `bestmove` has not arrived yet. Their output
  /// comes before the next search's, and would otherwise answer it.
  int _abandoned = 0;

  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) =>
      _enqueue(() => _evaluateNow(fen, depth));

  @override
  Future<EngineLine?> evaluateRunnerUp(
    String fen, {
    required List<String> searchMoves,
    int depth = 15,
  }) => _enqueue(() => _runnerUpNow(fen, searchMoves, depth));

  /// Runs [task] after every search queued before it.
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<EngineEval> _evaluateNow(String fen, int depth) async {
    final setup = Setup.parseFen(fen);

    // Never search a finished position: `mate 0` has no sign.
    final position = Chess.fromSetup(setup, ignoreImpossibleCheck: true);
    if (position.isGameOver) return _terminalEval(position, depth);

    final (bestMove, search) = await _go(fen, goCommand(depth));
    final info = search.bestLine;
    if (info == null) {
      // No scored line at all: score it from the board, don't fail the sweep.
      return _terminalEval(position, depth);
    }

    return toWhitePerspective(
      info: info,
      bestMoveUci: bestMove,
      sideToMove: setup.turn,
      position: position,
    );
  }

  Future<EngineLine?> _runnerUpNow(
    String fen,
    List<String> searchMoves,
    int depth,
  ) async {
    final setup = Setup.parseFen(fen);
    final position = Chess.fromSetup(setup, ignoreImpossibleCheck: true);
    if (position.isGameOver || searchMoves.isEmpty) return null;

    final (bestMove, search) = await _go(
      fen,
      goCommand(
        depth,
        searchMoves: [
          for (final uci in searchMoves) toEngineUci(position, uci),
        ],
      ),
    );
    final info = search.bestLine;
    if (info == null) return null;
    final line = toWhitePerspective(
      info: info,
      bestMoveUci: bestMove,
      sideToMove: setup.turn,
      position: position,
    );
    if (line.isCheckmate || line.pvUci.isEmpty) return null;
    return EngineLine(cp: line.cp, mateIn: line.mateIn, pvUci: line.pvUci);
  }

  /// Sends [go] for [fen] and waits for `bestmove`, asking the engine to
  /// stop at [_searchTimeout].
  Future<(String?, _Search)> _go(String fen, String go) async {
    final stockfish = await _ensureStarted();
    final search = _Search();
    _search = search;
    final clock = Stopwatch()..start();
    stockfish.stdin = 'position fen $fen';
    stockfish.stdin = go;

    try {
      final bestMove = await search.done.future.timeout(
        _searchTimeout,
        onTimeout: () async {
          // Ask the engine to wrap up; it answers with a bestmove.
          stockfish.stdin = 'stop';
          return search.done.future.timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw EngineTimeoutException(fen),
          );
        },
      );
      return (bestMove, search);
    } on EngineTimeoutException {
      _abandoned++;
      AppLog.instance.error(
        'engine',
        'gave up on a position after ${formatDuration(clock.elapsed)}',
      );
      rethrow;
    } finally {
      _search = null;
    }
  }

  EngineEval _terminalEval(Position position, int depth) {
    // The side to move is the side that was mated.
    if (position.isCheckmate) {
      return EngineEval.checkmate(mated: position.turn, depth: depth);
    }
    return EngineEval(cp: 0, bestMoveUci: null, depth: depth); // stalemate/draw
  }

  /// Set when starting failed; never retried (see [EngineStartException]).
  EngineStartException? _startError;

  Future<Stockfish> _ensureStarted() async {
    if (_stockfish != null) return _stockfish!;
    if (_startError != null) throw _startError!;

    final stockfish = Stockfish.instance;
    try {
      // start() does the uci handshake; never send `uci` again.
      await stockfish.start(
        flavor: flavor,
        bigNetPath: bigNetPath,
        smallNetPath: smallNetPath,
      );
      _outputSub = stockfish.stdout.listen(_onLine);

      final ready = Completer<void>();
      _handshake = ready;
      for (final command in startupCommands(threads: threads, hashMb: hashMb)) {
        stockfish.stdin = command;
      }
      await ready.future.timeout(const Duration(seconds: 10));
      _handshake = null;
    } catch (e) {
      // Usually an engine from an earlier run still alive in this process
      // (a hot restart): it holds the native pipes until the app is closed.
      AppLog.instance.error(
        'engine',
        '$name did not start: $e. If the app was hot-restarted or reopened '
            'without being closed, an engine from before is still running; '
            'closing the app completely starts a clean one.',
      );
      throw _startError = EngineStartException(e);
    }

    AppLog.instance.info(
      'engine',
      'started $name with $threads threads, $hashMb MB hash '
          '(${Platform.numberOfProcessors} cores available)',
    );

    _stockfish = stockfish;
    return stockfish;
  }

  Completer<void>? _handshake;

  void _onLine(String line) {
    if (line.startsWith('readyok')) {
      if (_handshake != null && !_handshake!.isCompleted) {
        _handshake!.complete();
      }
      return;
    }

    if (_abandoned > 0) {
      if (line.startsWith('bestmove')) _abandoned--;
      return;
    }

    final search = _search;
    if (search == null) return;

    final info = parseInfoLine(line);
    if (info != null) {
      // The last one wins: the deepest completed iteration.
      if (info.multipv == 1) search.bestLine = info;
      return;
    }

    if (line.startsWith('bestmove') && !search.done.isCompleted) {
      search.done.complete(parseBestMoveLine(line));
    }
  }

  @override
  Future<void> dispose() async {
    await _outputSub?.cancel();
    if (_stockfish != null) {
      await _stockfish!.quit();
      _stockfish = null;
    }
  }
}

class _Search {
  final Completer<String?> done = Completer();

  /// The last scored `info` line for the engine's own choice, or null when
  /// none came back at all.
  UciInfo? bestLine;
}
