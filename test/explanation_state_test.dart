import 'dart:async';

import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

const _pgn = '''
[Event "Test"]

1. e4 e5 2. Nf3 *
''';

Future<AnalysisSession> _loadedSession() async {
  final session = AnalysisSession(engine: FakeEngine());
  await session.loadPgn(_pgn);
  return session;
}

void main() {
  group('explanation state', () {
    test('a successful fetch caches on the node and reports ready', () async {
      final session = await _loadedSession();
      final explainer = FakeExplainer();
      final node = session.tree.mainline.first;

      await session.fetchExplanation(explainer, node: node);

      expect(session.explanationStatus(node), ExplanationStatus.ready);
      expect(node.explanation?.detail, 'Loses a pawn to Nxe5.');
      expect(session.explanationError(node), isNull);

      // Asking again is free.
      await session.fetchExplanation(explainer, node: node);
      expect(explainer.calls, 1);
    });

    test('a failure is not written onto the node, and a retry works', () async {
      final session = await _loadedSession();
      final explainer = FakeExplainer()..throwOnce = Exception('offline');
      final node = session.tree.mainline.first;

      await session.fetchExplanation(explainer, node: node);

      expect(session.explanationStatus(node), ExplanationStatus.failed);
      expect(node.explanation, isNull); // the whole point: still retryable
      expect(session.explanationError(node), contains('offline'));

      await session.fetchExplanation(explainer, node: node);

      expect(session.explanationStatus(node), ExplanationStatus.ready);
      expect(node.explanation, isNotNull);
      expect(session.explanationError(node), isNull);
      expect(explainer.calls, 2);
    });

    test('asking again replaces the answer, as a new model would', () async {
      final session = await _loadedSession();
      final node = session.tree.mainline.first;
      await session.fetchExplanation(FakeExplainer(), node: node);

      final other = FakeExplainer(response: 'Grabs the centre.');
      await session.fetchExplanation(other, node: node, again: true);

      expect(other.calls, 1);
      expect(node.explanation?.detail, 'Grabs the centre.');
      expect(session.explanationStatus(node), ExplanationStatus.ready);
    });

    test('a failed ask-again keeps the old answer and says why', () async {
      final session = await _loadedSession();
      final node = session.tree.mainline.first;
      await session.fetchExplanation(FakeExplainer(), node: node);

      final failing = FakeExplainer()..throwOnce = Exception('offline');
      await session.fetchExplanation(failing, node: node, again: true);

      // Never replaced by a failure: the old answer is still worth reading.
      expect(node.explanation?.detail, 'Loses a pawn to Nxe5.');
      expect(session.explanationStatus(node), ExplanationStatus.failed);
      expect(session.explanationError(node), contains('offline'));

      // Retrying clears the error.
      await session.fetchExplanation(failing, node: node, again: true);
      expect(session.explanationStatus(node), ExplanationStatus.ready);
      expect(session.explanationError(node), isNull);
    });

    test('an Error (not an Exception) is caught too', () async {
      final session = await _loadedSession();
      // A malformed response can throw an Error, not an Exception.
      final explainer = FakeExplainer()..throwOnce = StateError('no element');
      final node = session.tree.mainline.first;

      await session.fetchExplanation(explainer, node: node);

      expect(session.explanationStatus(node), ExplanationStatus.failed);
      expect(session.explanationError(node), isNotNull);
    });

    test('a timeout gets a friendly message', () async {
      final session = await _loadedSession();
      final explainer = FakeExplainer()..throwOnce = TimeoutException('x');
      final node = session.tree.mainline.first;

      await session.fetchExplanation(explainer, node: node);

      expect(session.explanationError(node), 'The request timed out.');
    });

    test('loading belongs to one node only', () async {
      final session = await _loadedSession();
      final gate = Completer<void>();
      final explainer = FakeExplainer()..gate = gate;
      final first = session.tree.mainline.first;
      final second = session.tree.mainline[1];

      final pending = session.fetchExplanation(explainer, node: first);

      expect(session.explanationStatus(first), ExplanationStatus.loading);
      expect(session.explanationStatus(second), ExplanationStatus.idle);

      gate.complete();
      await pending;

      expect(session.explanationStatus(first), ExplanationStatus.ready);
      expect(session.explanationStatus(second), ExplanationStatus.idle);
    });

    test(
      'a second fetch while one is in flight does not duplicate the call',
      () async {
        final session = await _loadedSession();
        final gate = Completer<void>();
        final explainer = FakeExplainer()..gate = gate;
        final node = session.tree.mainline.first;

        final pending = session.fetchExplanation(explainer, node: node);
        await session.fetchExplanation(explainer, node: node);
        gate.complete();
        await pending;

        expect(explainer.calls, 1);
      },
    );

    test('canExplain is false at the root and without evals', () async {
      final session = await _loadedSession();
      expect(session.canExplain(session.tree.root), isFalse);
      expect(session.canExplain(session.tree.mainline.first), isTrue);

      session.tree.root.eval = null; // parent eval gone
      expect(session.canExplain(session.tree.mainline.first), isFalse);
    });

    test('fetchExplanation defaults to the current move', () async {
      final session = await _loadedSession();
      final explainer = FakeExplainer();
      final node = session.tree.mainline.first;
      session.goToNode(node);

      await session.fetchExplanation(explainer);

      expect(node.explanation, isNotNull);
    });

    test('loading a new game drops the recorded errors', () async {
      final session = await _loadedSession();
      final explainer = FakeExplainer()..throwOnce = Exception('offline');
      final node = session.tree.mainline.first;
      await session.fetchExplanation(explainer, node: node);
      expect(session.explanationStatus(node), ExplanationStatus.failed);

      await session.loadPgn(_pgn);

      final fresh = session.tree.mainline.first;
      expect(session.explanationStatus(fresh), ExplanationStatus.idle);
    });

    test(
      'the context carries the refutation line of the played move',
      () async {
        // The played node's OWN eval holds the engine's continuation from the
        // position after the move — that is the refutation the prompt needs.
        final initial = Chess.initial;
        final afterE4 = initial.makeSan(initial.parseSan('e4')!).$1.fen;
        final engine = FakeEngine(
          evalsByFen: {
            afterE4: const EngineEval(
              cp: -20,
              bestMoveUci: 'e7e5',
              pvUci: ['e7e5', 'g1f3'],
              depth: 15,
            ),
          },
        );
        final session = AnalysisSession(engine: engine);
        await session.loadPgn(_pgn);
        final explainer = FakeExplainer();
        final node = session.tree.mainline.first;

        await session.fetchExplanation(explainer, node: node);

        final context = explainer.contexts.single;
        expect(context.playedSan, 'e4');
        expect(context.refutationLineSan, ['e5', 'Nf3']);
      },
    );
  });
}
