import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/coach_flavor.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_config_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

/// Fool's mate: the user (White, "Bob") walks into it.
const _pgn = '[White "Bob"]\n[Black "Ann"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n';

/// The position after 2. g4, where Black mates in one.
const _afterG4 =
    'rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2';

const _evals = {
  _afterG4: EngineEval(
    mateIn: -1,
    bestMoveUci: 'd8h4',
    pvUci: ['d8h4'],
    depth: 15,
  ),
};

/// Takes a second per search, so the board rests on every position it
/// follows for longer than the buzz waits.
class _SlowEngine extends FakeEngine {
  _SlowEngine() : super(evalsByFen: {..._evals});

  @override
  Future<EngineEval> evaluate(String fen, {int depth = 15}) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    return super.evaluate(fen, depth: depth);
  }
}

const _heavy = 'HapticFeedbackType.heavyImpact';
const _medium = 'HapticFeedbackType.mediumImpact';
const _click = 'HapticFeedbackType.selectionClick';

GameNode _mainline(AnalysisSession session, int ply) {
  var node = session.tree.root;
  for (var i = 0; i < ply; i++) {
    node = node.children.first;
  }
  return node;
}

void main() {
  late List<String> haptics;

  /// The big-moment buzzes so far, without the taps.
  List<String> reactions() =>
      haptics.where((h) => h == _heavy || h == _medium).toList();

  Future<void> pumpBoard(WidgetTester tester, AnalysisSession session) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    haptics = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BoardScreen(
          session: session,
          configStore: FakeConfigStore(hasKey: true),
          explainerFactory: (_) => FakeExplainer(),
        ),
      ),
    );
  }

  Future<AnalysisSession> analysed() async {
    final session = AnalysisSession(
      engine: FakeEngine(evalsByFen: {..._evals}),
      playerName: 'Bob',
    );
    await session.loadPgn(_pgn);
    return session;
  }

  test('the fixture: g4 allows the mate, Qh4# delivers it', () async {
    final session = await analysed();
    expect(
      session.coachReactionFor(_mainline(session, 3))?.moment,
      Moment.allowedMate,
    );
    expect(
      session.coachReactionFor(_mainline(session, 4))?.moment,
      Moment.checkmate,
    );
  });

  testWidgets('resting on a big moment buzzes, once per arrival', (
    tester,
  ) async {
    final session = await analysed();
    await pumpBoard(tester, session);
    await tester.pumpAndSettle();

    session.goToNode(_mainline(session, 4));
    await tester.pump(const Duration(milliseconds: 400));
    // Mated: bad news for the user, the heavy buzz.
    expect(reactions(), [_heavy]);

    // Staying put buzzes no more.
    await tester.pump(const Duration(seconds: 2));
    expect(reactions(), hasLength(1));

    // Leaving and coming back is a new arrival.
    session.goBack();
    await tester.pump(const Duration(milliseconds: 400));
    expect(reactions(), hasLength(2), reason: 'g4 allows the mate');
    session.goForward();
    await tester.pump(const Duration(milliseconds: 400));
    expect(reactions(), hasLength(3));
    await tester.pumpAndSettle();
  });

  testWidgets('stepping past a big moment stays still', (tester) async {
    final session = await analysed();
    await pumpBoard(tester, session);
    await tester.pumpAndSettle();

    session.goToNode(_mainline(session, 4));
    await tester.pump(const Duration(milliseconds: 100));
    session.goToNode(session.tree.root);
    await tester.pump(const Duration(seconds: 1));
    expect(reactions(), isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('the sweep walks the board without a buzz', (tester) async {
    final session = AnalysisSession(engine: _SlowEngine(), playerName: 'Bob');
    final visited = <GameNode>{};
    session.addListener(() => visited.add(session.current));
    final loading = session.loadPgn(_pgn);
    await pumpBoard(tester, session);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await loading;
    await tester.pumpAndSettle();

    // The board did rest on the blunder, long enough to buzz.
    expect(visited, contains(_mainline(session, 3)));
    expect(reactions(), isEmpty);
  });

  testWidgets('a step through the game ticks', (tester) async {
    final session = await analysed();
    await pumpBoard(tester, session);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Next move'));
    await tester.pumpAndSettle();
    expect(haptics, [_click]);
  });
}
