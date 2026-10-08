import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/feedback/move_sounds.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_config_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_explainer.dart';

/// A quiet move, a capture, a recapture with check, castling, then mate.
const _pgn =
    '[White "Ann"]\n[Black "Cy"]\n\n'
    '1. e4 d5 2. exd5 Qxd5 3. Nc3 Qe5+ 4. Be2 Bg4 5. Nf3 Bxf3 6. O-O Nc6 '
    '7. Re1 O-O-O 8. Bc4 e6 9. Rxe5 *\n';

class _RecordingPlayer implements SoundPlayer {
  final played = <MoveSound>[];

  @override
  void play(MoveSound sound) => played.add(sound);

  @override
  void dispose() {}
}

GameNode _ply(GameTree tree, int ply) {
  var node = tree.root;
  for (var i = 0; i < ply; i++) {
    node = node.children.first;
  }
  return node;
}

void main() {
  group('moveSoundFor', () {
    final tree = GameTree.fromPgn(_pgn);

    test('nothing at the start', () {
      expect(moveSoundFor(tree.root), isNull);
    });

    test('a quiet move, a capture, a check', () {
      expect(moveSoundFor(_ply(tree, 1)), MoveSound.move); // e4
      expect(moveSoundFor(_ply(tree, 3)), MoveSound.capture); // exd5
      expect(moveSoundFor(_ply(tree, 6)), MoveSound.check); // Qe5+
    });

    test('castling is an ordinary move, either side', () {
      expect(moveSoundFor(_ply(tree, 11)), MoveSound.move); // O-O
      expect(moveSoundFor(_ply(tree, 14)), MoveSound.move); // O-O-O
    });
  });

  group('MoveSounds', () {
    test('plays the move\'s sound, and nothing when switched off', () {
      final tree = GameTree.fromPgn(_pgn);
      final player = _RecordingPlayer();
      final sounds = MoveSounds(player: player);

      sounds.play(_ply(tree, 3));
      sounds.setEnabled(false);
      sounds.play(_ply(tree, 3));
      sounds.play(tree.root);

      expect(player.played, [MoveSound.capture]);
    });

    test('the switch is on by default and survives a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final first = MoveSounds();
      await first.load();
      expect(first.enabled, isTrue);

      first.setEnabled(false);
      await Future<void>.delayed(Duration.zero);

      final second = MoveSounds();
      await second.load();
      expect(second.enabled, isFalse);
    });
  });

  testWidgets('stepping through the game clicks each move', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final player = _RecordingPlayer();
    final session = AnalysisSession(engine: FakeEngine(evalsByFen: {}));
    await session.loadPgn(_pgn);

    await tester.pumpWidget(
      MoveSoundsScope(
        sounds: MoveSounds(player: player),
        child: MaterialApp(
          home: BoardScreen(
            session: session,
            configStore: FakeConfigStore(hasKey: true),
            explainerFactory: (_) => FakeExplainer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    session.goToNode(session.tree.root);
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Next move'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Previous move'));
    await tester.pumpAndSettle();

    // e4, d5, exd5, then back onto d5.
    expect(player.played, [
      MoveSound.move,
      MoveSound.move,
      MoveSound.capture,
      MoveSound.move,
    ]);
  });
}
