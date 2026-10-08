import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/coach_flavor.dart';
import 'package:chess_mortem/model/coach_line.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Black's rook just checked on e2, where nothing guards it: Kxe2 takes it.
ConceptInput _gift() {
  final before = Chess.fromSetup(
    Setup.parseFen('3rk3/8/8/8/8/8/4r3/R3K3 w - - 0 1'),
  );
  return ConceptInput(
    before: before,
    played: before.parseSan('Kxe2')!,
    verdict: Classification.best,
    previous: (to: Square.e2, captured: false),
    opponentSlipped: true,
    replyUci: const ['d8d7'],
  );
}

/// A quiet developing move: nothing to react to.
ConceptInput _quiet() {
  final before = Chess.fromSetup(
    Setup.parseFen(
      'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
    ),
  );
  return ConceptInput(
    before: before,
    played: before.parseSan('Nf3')!,
    verdict: Classification.best,
    replyUci: const ['b8c6'],
  );
}

void main() {
  group('the reaction follows the line', () {
    test('a big moment reacts, in the reader\'s voice', () {
      for (final (user, voice) in [
        (Side.white, CoachVoice.you),
        (Side.black, CoachVoice.opponent),
        (null, CoachVoice.neutral),
      ]) {
        expect(
          conceptReaction(_gift(), userSide: user, seed: 7),
          CoachReaction(Moment.giftAccepted, voice),
          reason: '$user',
        );
      }
    });

    test('the phone buzzes exactly where the line reacts', () {
      for (final input in [_gift(), _quiet()]) {
        final plain = conceptLine(input, userSide: Side.white, seed: 3);
        final playful = conceptLine(
          input,
          userSide: Side.white,
          seed: 3,
          playful: true,
        );
        final reaction = conceptReaction(input, userSide: Side.white, seed: 3);
        expect(reaction != null, playful != plain, reason: plain);
      }
    });

    test('a quiet move says nothing', () {
      expect(conceptReaction(_quiet(), userSide: Side.white, seed: 1), isNull);
    });

    test('the starting position says nothing', () {
      final tree = GameTree.fromPgn('[Event "Test"]\n\n1. e4 e5 *\n');
      expect(coachReaction(tree.root, userSide: Side.white), isNull);
      // Not analysed yet: no concept line, so no reaction either.
      expect(
        coachReaction(tree.root.children.first, userSide: Side.white),
        isNull,
      );
    });
  });

  group('cheers', () {
    test('the user\'s own big moment is good news, a slip bad', () {
      expect(
        const CoachReaction(Moment.brilliant, CoachVoice.you).cheers,
        isTrue,
      );
      expect(
        const CoachReaction(Moment.hungPiece, CoachVoice.you).cheers,
        isFalse,
      );
    });

    test('the opponent\'s slip is good news for the user', () {
      expect(
        const CoachReaction(Moment.hungPiece, CoachVoice.opponent).cheers,
        isTrue,
      );
      expect(
        const CoachReaction(Moment.checkmate, CoachVoice.opponent).cheers,
        isFalse,
      );
    });
  });
}
