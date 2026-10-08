import 'dart:async';
import 'dart:isolate';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/engine/engine.dart';
import 'package:chess_mortem/engine/stockfish_engine.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multistockfish/multistockfish.dart';

import 'fakes/fake_engine.dart';

void main() {
  test('an engine that will not start is not started again', () async {
    var spawns = 0;
    Future<bool> refuse(SendPort main, SendPort out, StockfishFlavor f) async {
      spawns++;
      return false; // the plugin's "could not start"
    }

    await runZoned(() async {
      final engine = StockfishEngine(threads: 1);
      await expectLater(
        engine.evaluate(Chess.initial.fen),
        throwsA(isA<EngineStartException>()),
      );
      await expectLater(
        engine.evaluate(Chess.initial.fen),
        throwsA(isA<EngineStartException>()),
      );
      expect(spawns, 1, reason: 'a second start piles a second engine on');
    }, zoneValues: {stockfishSpawnIsolatesKey: refuse});
  });

  test('the board says what to do when the engine will not start', () async {
    final session = AnalysisSession(engine: _DeadEngine());
    await session.loadPgn('1. e4 e5 *');
    expect(session.loadError, engineStartFailedMessage);
    expect(session.isAnalyzing, isFalse);
  });
}

class _DeadEngine extends FakeEngine {
  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) =>
      Future.error(EngineStartException('TimeoutException after 0:00:05'));
}
