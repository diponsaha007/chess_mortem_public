import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/game_result.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine.dart';

/// A game both sides spoil: White drops a queen on move 2, Black on move 3.
/// The evals come from [FakeEngine], which scores by the move number, so the
/// verdicts here are whatever that produces — what matters is that BOTH sides
/// have reviewable mistakes, so a filter that does nothing is visible.
const _pgn = '''
[White "Queen_Walker_Test"]
[Black "Night_Owl_Test"]
[Result "1-0"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
''';

const _pgnNoTags = '''
[Event "Test"]

1. e4 e5 2. Nf3 *
''';

void main() {
  group('who is "you"', () {
    test('is nobody until the name is configured', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      expect(session.userSide, isNull);
      expect(session.reviewsOneSide, isFalse);
    });

    test('matches the White or the Black tag', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      session.playerName = 'Queen_Walker_Test';
      expect(session.userSide, Side.white);

      session.playerName = 'Night_Owl_Test';
      expect(session.userSide, Side.black);
      expect(session.reviewsOneSide, isTrue);
    });

    test('ignores case and stray whitespace', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      session.playerName = '  QUEEN_WALKER_TEST ';
      expect(session.userSide, Side.white);
    });

    test('a name in neither tag identifies nobody', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      session.playerName = 'somebody else';
      expect(session.userSide, isNull);
    });

    test('an empty name is the same as no name', () async {
      // Settings clears the field by writing '', not null, so the empty
      // string has to mean "not set" everywhere downstream.
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      session.playerName = '';
      expect(session.userSide, isNull);
      session.playerName = '   ';
      expect(session.userSide, isNull);
    });

    test('a PGN with no player tags identifies nobody', () async {
      final session = AnalysisSession(engine: FakeEngine(), playerName: 'me');
      await session.loadPgn(_pgnNoTags);

      expect(session.userSide, isNull);
    });
  });

  group('the result', () {
    test('is read from the PGN', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgn);

      expect(session.result, GameResult.whiteWon);
    });

    test('is null when the game was never finished', () async {
      final session = AnalysisSession(engine: FakeEngine());
      await session.loadPgn(_pgnNoTags);

      expect(session.result, isNull);
    });
  });

  group('key-move navigation', () {
    test('walks both players when nobody is identified', () async {
      final session = await _sessionWithMistakesOnBothSides();

      final visited = _walkKeyMoves(session);
      expect(visited, isNotEmpty);
      expect(
        visited.map((n) => n.sideThatMoved).toSet().length,
        greaterThan(1),
        reason: 'this game is only a useful fixture if both sides slip',
      );
    });

    test('walks only your own once you are identified', () async {
      final session = await _sessionWithMistakesOnBothSides();
      session.playerName = 'Queen_Walker_Test';

      final visited = _walkKeyMoves(session);
      expect(visited, isNotEmpty);
      expect(
        visited.map((n) => n.sideThatMoved),
        everyElement(Side.white),
        reason: 'a post-mortem of your game should not stop on their blunders',
      );
    });

    test('backwards is filtered the same way as forwards', () async {
      final session = await _sessionWithMistakesOnBothSides();
      session.playerName = 'Night_Owl_Test';

      // Start at the end and walk back.
      var node = session.tree.mainline.last;
      session.goToNode(node);
      final visited = <dynamic>[];
      while (session.previousKeyMove != null) {
        node = session.previousKeyMove!;
        session.goToNode(node);
        visited.add(node);
      }
      expect(visited, isNotEmpty);
      expect(visited.map((n) => n.sideThatMoved), everyElement(Side.black));
    });
  });
}

/// A loaded game whose every move is a blunder.
///
/// The verdicts are written straight onto the nodes rather than coaxed out of
/// the classifier: what is under test is which moves the review STOPS on,
/// and scripting an engine into producing one on each side would only make
/// the test depend on the scoring thresholds as well.
Future<AnalysisSession> _sessionWithMistakesOnBothSides() async {
  final session = AnalysisSession(engine: FakeEngine());
  await session.loadPgn(_pgn);
  for (final node in session.tree.mainline) {
    node.classification = Classification.blunder;
  }
  return session;
}

/// Every move the "next key move" button would stop on, from the start.
List<dynamic> _walkKeyMoves(AnalysisSession session) {
  session.goToNode(session.tree.root);
  final visited = <dynamic>[];
  while (session.nextKeyMove != null) {
    final node = session.nextKeyMove!;
    session.goToNode(node);
    visited.add(node);
  }
  return visited;
}
