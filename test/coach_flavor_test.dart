import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/coach_flavor.dart';
import 'package:chess_mortem/model/coach_line.dart';
import 'package:chess_mortem/model/concepts/board_concepts.dart';
import 'package:chess_mortem/model/concepts/concept.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

ConceptInput _input(
  String fen,
  String san, {
  Classification? verdict,
  List<String> betterUci = const [],
  List<String> replyUci = const [],
  double? winPctDrop,
}) {
  final before = Chess.fromSetup(Setup.parseFen(fen));
  return ConceptInput(
    before: before,
    played: before.parseSan(san)!,
    verdict: verdict,
    betterUci: betterUci,
    replyUci: replyUci,
    winPctDrop: winPctDrop,
  );
}

String _say(
  ConceptKind kind,
  Frame frame,
  ConceptInput input, {
  String? object,
  Side? userSide,
  int? seed,
  bool playful = true,
}) => coachSentence(
  Concept(
    kind,
    frame,
    object: object == null ? null : Square.fromName(object),
    evidence: '',
  ),
  input,
  userSide: userSide,
  seed: seed,
  playful: playful,
);

/// Every line [moment]'s [voice] can produce over [plain].
Set<String> _pool(
  Moment moment,
  CoachVoice voice,
  String plain,
  FlavorSlots s,
) => {for (final t in flavorBank[moment]![voice]!) ?renderFlavor(t, plain, s)};

const _seeds = 1000;

void main() {
  group('a hung piece', () {
    // Bg5 walks into h6xg5.
    final input = _input(
      '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1',
      'Bg5',
      verdict: Classification.blunder,
      replyUci: ['h6g5'],
    );
    String say(Side? user, int seed) => _say(
      ConceptKind.hangingPiece,
      Frame.allows,
      input,
      object: 'g5',
      userSide: user,
      seed: seed,
    );
    const plain = 'This leaves the bishop on g5 hanging.';

    test('the same move reads the same every time', () {
      expect(say(Side.white, 42), say(Side.white, 42));
    });

    test('playful off is the plain line', () {
      expect(
        _say(
          ConceptKind.hangingPiece,
          Frame.allows,
          input,
          object: 'g5',
          seed: 42,
          playful: false,
        ),
        plain,
      );
    });

    test('each voice draws from its own reactions, for every seed', () {
      for (final (user, voice) in [
        (Side.white, CoachVoice.you),
        (Side.black, CoachVoice.opponent),
        (null, CoachVoice.neutral),
      ]) {
        final pool = _pool(
          Moment.hungPiece,
          voice,
          plain,
          FlavorSlots(voice: voice, side: 'White', piece: 'the bishop on g5'),
        );
        final seen = {for (var s = 0; s < _seeds; s++) say(user, s)};
        expect(seen.difference(pool), isEmpty, reason: '$voice');
        // The seed spreads the picks over the whole pool.
        expect(seen, pool, reason: '$voice');
      }
    });

    test('a hung pawn is too small for a joke', () {
      final pawn = _input(
        '4k3/8/8/5p2/8/8/4P3/4K3 w - - 0 1',
        'e4',
        verdict: Classification.blunder,
        replyUci: ['f5e4'],
      );
      for (var s = 0; s < _seeds; s++) {
        expect(
          _say(
            ConceptKind.hangingPiece,
            Frame.allows,
            pawn,
            object: 'e4',
            userSide: Side.white,
            seed: s,
          ),
          'This leaves the pawn on e4 hanging.',
        );
      }
    });
  });

  test('a generic line never gets a joke, even on a Blunder', () {
    final input = _input(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      'a3',
      verdict: Classification.blunder,
      betterUci: ['e2e4'],
      winPctDrop: 30,
    );
    for (var s = 0; s < _seeds; s++) {
      for (final frame in [Frame.allows, Frame.better]) {
        final plain = _say(
          ConceptKind.genericQuality,
          frame,
          input,
          userSide: Side.white,
          seed: s,
          playful: false,
        );
        expect(
          _say(
            ConceptKind.genericQuality,
            frame,
            input,
            userSide: Side.white,
            seed: s,
          ),
          plain,
        );
      }
    }
  });

  test('quiet moves and inaccuracies stay plain', () {
    final input = _input(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      'Nf3',
      verdict: Classification.best,
    );
    final slip = _input(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      'a3',
      verdict: Classification.inaccuracy,
      betterUci: ['g1f3'],
    );
    for (var s = 0; s < _seeds; s++) {
      for (final (kind, frame, inp, object) in [
        (ConceptKind.developPiece, Frame.does, input, 'f3'),
        (ConceptKind.centralControl, Frame.does, input, 'f3'),
        (ConceptKind.developPiece, Frame.better, slip, 'f3'),
      ]) {
        expect(
          _say(kind, frame, inp, object: object, userSide: Side.white, seed: s),
          _say(
            kind,
            frame,
            inp,
            object: object,
            userSide: Side.white,
            seed: s,
            playful: false,
          ),
        );
      }
    }
  });

  test('a Miss jokes only when it can name the better move', () {
    final withSan = _input(
      'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
      'Kd2',
      verdict: Classification.miss,
      betterUci: ['b5c7'],
    );
    final pool = _pool(
      Moment.miss,
      CoachVoice.you,
      '',
      const FlavorSlots(
        voice: CoachVoice.you,
        side: 'White',
        betterSan: 'Nc7+',
      ),
    );
    final noSan = _input(
      'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
      'Kd2',
      verdict: Classification.miss,
    );
    for (var s = 0; s < 50; s++) {
      expect(
        pool,
        contains(
          _say(
            ConceptKind.missedWin,
            Frame.better,
            withSan,
            userSide: Side.white,
            seed: s,
          ),
        ),
      );
      expect(
        _say(
          ConceptKind.missedWin,
          Frame.better,
          noSan,
          userSide: Side.white,
          seed: s,
        ),
        "This lets the opponent's mistake go.",
      );
    }
  });

  test('a delivered mate always gets its moment', () {
    final input = _input(
      '6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1',
      'Ra8#',
      verdict: Classification.best,
    );
    final pool = flavorBank[Moment.checkmate]![CoachVoice.opponent]!.toSet();
    for (var s = 0; s < 50; s++) {
      expect(
        pool,
        contains(
          _say(
            ConceptKind.checkmate,
            Frame.does,
            input,
            userSide: Side.black,
            seed: s,
          ),
        ),
      );
    }
  });

  test('Brilliant is an event on its own, even on a generic line', () {
    final input = _input(
      '1r2k1r1/pbppnp1p/1b3P2/8/Q7/B1PB1q2/P4PPP/3R2K1 w - - 0 21',
      'Qxd7+',
      verdict: Classification.brilliant,
    );
    final line = _say(
      ConceptKind.genericQuality,
      Frame.does,
      input,
      userSide: Side.white,
      seed: 7,
    );
    expect(line, contains('A brilliant sacrifice.'));
    expect(line, isNot('A brilliant sacrifice.'));
  });

  test('a line that opens with a pawn move keeps SAN\'s case', () {
    final input = _input(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      'a3',
      verdict: Classification.mistake,
      betterUci: ['e2e4'],
    );
    for (var s = 0; s < 100; s++) {
      final line = _say(
        ConceptKind.genericQuality,
        Frame.better,
        input,
        seed: s,
      );
      expect(line, isNot(startsWith('E4')));
    }
  });

  group('momentFor', () {
    test('a tactic on a pawn is not a moment', () {
      expect(
        momentFor(
          kind: ConceptKind.fork,
          frame: Frame.allows,
          verdict: Classification.blunder,
          role: Role.pawn,
          betterSan: null,
          mated: false,
        ),
        isNull,
      );
    });

    test('winning a minor piece on a Best move is not a moment', () {
      expect(
        momentFor(
          kind: ConceptKind.captureFree,
          frame: Frame.does,
          verdict: Classification.best,
          role: Role.knight,
          betterSan: null,
          mated: false,
        ),
        isNull,
      );
      expect(
        momentFor(
          kind: ConceptKind.captureFree,
          frame: Frame.does,
          verdict: Classification.best,
          role: Role.rook,
          betterSan: null,
          mated: false,
        ),
        Moment.tacticLanded,
      );
    });
  });

  group('the bank', () {
    test('every moment has at least three reactions per voice, none twice', () {
      for (final moment in Moment.values) {
        for (final voice in CoachVoice.values) {
          final pool = flavorBank[moment]![voice]!;
          expect(
            pool.length,
            greaterThanOrEqualTo(3),
            reason: '$moment $voice',
          );
          expect(pool.toSet().length, pool.length, reason: '$moment $voice');
        }
      }
    });

    final all = [
      for (final byVoice in flavorBank.values)
        for (final pool in byVoice.values) ...pool,
    ];

    test('no gendered pronoun, no site, no claim of "free"', () {
      final banned = RegExp(
        r'\b(he|she|his|her|him|hers|free|chess\.com|lichess)\b',
        caseSensitive: false,
      );
      for (final t in all) {
        expect(banned.hasMatch(t), isFalse, reason: t);
      }
    });

    test('a Miss never says the position was won', () {
      // A Miss can be in a level position: the gift was points, not a win.
      for (final byVoice in flavorBank[Moment.miss]!.values) {
        for (final t in byVoice) {
          expect(
            RegExp(r'\bwin', caseSensitive: false).hasMatch(t),
            isFalse,
            reason: t,
          );
        }
      }
    });

    test('the neutral voice never speaks to a "you"', () {
      for (final byVoice in flavorBank.values) {
        for (final t in byVoice[CoachVoice.neutral]!) {
          expect(
            RegExp(r'\byou', caseSensitive: false).hasMatch(t),
            isFalse,
            reason: t,
          );
        }
      }
    });

    test('a rebuilt line fits the coach bar with the longest slots', () {
      const slots = FlavorSlots(
        voice: CoachVoice.opponent,
        side: 'Black',
        piece: 'the bishop on d5',
        betterSan: 'Nxf7+',
      );
      for (final t in all.where((t) => !t.contains('{plain}'))) {
        expect(
          renderFlavor(t, '', slots)!.length,
          lessThanOrEqualTo(maxFlavoredLength),
          reason: t,
        );
      }
    });

    test('a reaction that would overflow leaves the plain line', () {
      final long = 'x' * (maxFlavoredLength - 3);
      for (var s = 0; s < 50; s++) {
        expect(
          flavor(
            long,
            Moment.great,
            const FlavorSlots(voice: CoachVoice.you, side: 'White'),
            s,
          ),
          long,
        );
      }
    });
  });

  group('a gift accepted', () {
    // Black's rook just checked on e2, where nothing guards it.
    const fen = '3rk3/8/8/8/8/8/4r3/R3K3 w - - 0 1';
    ConceptInput take({
      Classification verdict = Classification.best,
      PreviousMove? previous = (to: Square.e2, captured: false),
      bool opponentSlipped = true,
    }) {
      final before = Chess.fromSetup(Setup.parseFen(fen));
      return ConceptInput(
        before: before,
        played: before.parseSan('Kxe2')!,
        verdict: verdict,
        previous: previous,
        opponentSlipped: opponentSlipped,
        replyUci: const ['d8d7'],
      );
    }

    const plain = 'You win the checking rook on e2 for free.';
    const slots = FlavorSlots(voice: CoachVoice.you, side: 'White');

    test('the piece the opponent just moved, taken for nothing', () {
      final gifts = _pool(Moment.giftAccepted, CoachVoice.you, plain, slots);
      for (var seed = 0; seed < 50; seed++) {
        expect(
          conceptLine(take(), userSide: Side.white, seed: seed, playful: true),
          isIn(gifts),
        );
      }
    });

    test('a piece left there earlier is not a gift', () {
      final line = conceptLine(
        take(previous: (to: Square.d8, captured: false)),
        userSide: Side.white,
        seed: 1,
        playful: true,
      );
      expect(
        line,
        isNot(isIn(_pool(Moment.giftAccepted, CoachVoice.you, plain, slots))),
      );
    });

    test('a piece given up on purpose is not a gift', () {
      final line = conceptLine(
        take(opponentSlipped: false),
        userSide: Side.white,
        seed: 1,
        playful: true,
      );
      expect(
        line,
        isNot(isIn(_pool(Moment.giftAccepted, CoachVoice.you, plain, slots))),
      );
    });

    test('never on an inaccuracy, and never for a pawn', () {
      expect(
        conceptLine(
          take(verdict: Classification.inaccuracy),
          userSide: Side.white,
          seed: 1,
          playful: true,
        ),
        plain,
      );
      expect(
        momentFor(
          kind: ConceptKind.captureFree,
          frame: Frame.does,
          verdict: Classification.best,
          role: Role.pawn,
          betterSan: null,
          mated: false,
          gift: true,
        ),
        isNull,
      );
    });
  });
}
