import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/model/coach_emoji.dart';
import 'package:chess_mortem/model/coach_flavor.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:chess_mortem/widgets/eval_bar.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_config_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

/// Fool's mate: the user (White, "Bob") walks into it.
const _pgn = '[White "Bob"]\n[Black "Ann"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n';

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

GameNode _mainline(AnalysisSession session, int ply) {
  var node = session.tree.root;
  for (var i = 0; i < ply; i++) {
    node = node.children.first;
  }
  return node;
}

void main() {
  group('reactionEmoji', () {
    const youLost = ['😰', '😱', '😬', '🤦', '😵', '🙈'];
    const opponentLost = ['🤭', '😏', '👀', '🎁', '😈', '🙊'];
    const wow = ['🤩', '🤯', '😮', '🔥', '💎', '✨'];

    test('a piece you hung gets a worried face; theirs, a cheeky one', () {
      for (var seed = 0; seed < 20; seed++) {
        expect(
          reactionEmoji(
            CoachReaction(
              Moment.hungPiece,
              CoachVoice.you,
              role: Role.knight,
              seed: seed,
            ),
          ),
          isIn(youLost),
        );
        expect(
          reactionEmoji(
            CoachReaction(
              Moment.hungPiece,
              CoachVoice.opponent,
              role: Role.knight,
              seed: seed,
            ),
          ),
          isIn(opponentLost),
        );
      }
    });

    test('a Brilliant of yours is a wow', () {
      expect(
        reactionEmoji(
          const CoachReaction(Moment.brilliant, CoachVoice.you, seed: 7),
        ),
        isIn(wow),
      );
    });

    test('different moves get different faces; one move, always one', () {
      String? face(int seed) => reactionEmoji(
        CoachReaction(Moment.lostPiece, CoachVoice.you, seed: seed),
      );
      expect({for (var seed = 0; seed < 40; seed++) face(seed)}.length, 6);
      expect(face(12345), face(12345));
    });

    test('the moments, with and without a face', () {
      String? face(Moment moment, {Role? role}) =>
          reactionEmoji(CoachReaction(moment, CoachVoice.neutral, role: role));
      expect(face(Moment.checkmate), isNotNull);
      expect(face(Moment.allowedMate), isNotNull);
      expect(face(Moment.giftAccepted, role: Role.bishop), isNotNull);
      expect(face(Moment.tacticLanded, role: Role.queen), isNotNull);
      expect(face(Moment.walkedIntoTactic, role: Role.rook), isNotNull);
      expect(face(Moment.drawnWin), isNotNull);
      // A verdict alone, or a mate threat with no piece named.
      expect(face(Moment.great), isNull);
      expect(face(Moment.miss), isNull);
      expect(face(Moment.walkedIntoTactic), isNull);
    });
  });

  group('on the board', () {
    Future<AnalysisSession> pumpBoard(
      WidgetTester tester, {
      Size size = const Size(412, 915),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = AnalysisSession(
        engine: FakeEngine(evalsByFen: {..._evals}),
        playerName: 'Bob',
      );
      await session.loadPgn(_pgn);
      await tester.pumpWidget(
        MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(hasKey: true),
            explainerFactory: (_) => FakeExplainer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('a face above the board while the cursor rests on the move', (
      tester,
    ) async {
      final session = await pumpBoard(tester);
      final boardSize = tester.getSize(find.byType(Chessboard));

      session.goToNode(_mainline(session, 3)); // 2. g4, allowing mate
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(boardReactionEmojiKey), findsNothing);
      await tester.pumpAndSettle();

      final face = find.byKey(boardReactionEmojiKey);
      expect(face, findsOneWidget);
      expect(
        find.descendant(of: face, matching: find.byType(Text)),
        findsOneWidget,
      );
      // Above the board, over the board rather than the eval bar, and
      // taking no room from it.
      final board = tester.getRect(find.byType(Chessboard));
      final faceRect = tester.getRect(face);
      expect(faceRect.bottom, lessThanOrEqualTo(board.top));
      expect(faceRect.center.dx, closeTo(board.center.dx, 1));
      expect(tester.getSize(find.byType(Chessboard)), boardSize);
      expect(tester.getRect(find.byType(EvalBar)).left, lessThan(board.left));

      // Staying keeps it; stepping to a quiet move removes it.
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(boardReactionEmojiKey), findsOneWidget);
      session.goToNode(_mainline(session, 2));
      await tester.pumpAndSettle();
      expect(find.byKey(boardReactionEmojiKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('in landscape the face sits beside the board', (tester) async {
      final session = await pumpBoard(tester, size: const Size(915, 412));
      final boardSize = tester.getSize(find.byType(Chessboard));

      session.goToNode(_mainline(session, 3));
      await tester.pumpAndSettle();

      final face = find.byKey(boardReactionEmojiKey);
      expect(face, findsOneWidget);
      final board = tester.getRect(find.byType(Chessboard));
      final faceRect = tester.getRect(face);
      // Right of the board, level with its middle, taking no room from it.
      expect(faceRect.left, greaterThanOrEqualTo(board.right));
      expect(faceRect.center.dy, closeTo(board.center.dy, 30));
      expect(tester.getSize(find.byType(Chessboard)), boardSize);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no face on a quiet move', (tester) async {
      final session = await pumpBoard(tester);
      session.goToNode(_mainline(session, 1));
      await tester.pumpAndSettle();
      expect(find.byKey(boardReactionEmojiKey), findsNothing);
    });
  });
}
