import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/coach_flavor.dart';
import 'package:chess_mortem/model/coach_line.dart';
import 'package:chess_mortem/model/concepts/board_concepts.dart';
import 'package:chess_mortem/model/concepts/concept.dart';
import 'package:chess_mortem/model/concepts/detect_concepts.dart';
import 'package:chess_mortem/model/concepts/node_concepts.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_phase.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/model/move_tags.dart';
import 'package:chess_mortem/model/repetition.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

ConceptInput _input(
  String fen,
  String san, {
  Classification? verdict,
  PreviousMove? previous,
  List<String> betterUci = const [],
  List<String> replyUci = const [],
  MoveTags tags = MoveTags.none,
  double? winPctDrop,
  double? winPctAfter,
  int? mateAfter,
  bool drawBefore = false,
  bool drawAfter = false,
  bool perpetualInHand = false,
  int repetitions = 1,
}) {
  final before = Chess.fromSetup(Setup.parseFen(fen));
  return ConceptInput(
    before: before,
    played: before.parseSan(san)!,
    verdict: verdict,
    previous: previous,
    betterUci: betterUci,
    replyUci: replyUci,
    tags: tags,
    winPctDrop: winPctDrop,
    winPctAfter: winPctAfter,
    mateAfter: mateAfter,
    drawBefore: drawBefore,
    drawAfter: drawAfter,
    perpetualInHand: perpetualInHand,
    repetitions: repetitions,
  );
}

String _say(
  ConceptKind kind,
  Frame frame,
  ConceptInput input, {
  String? object,
  Side? userSide,
}) => coachSentence(
  Concept(
    kind,
    frame,
    object: object == null ? null : Square.fromName(object),
    evidence: '',
  ),
  input,
  userSide: userSide,
);

void main() {
  test('a capture names the piece taken, not the one that took it', () {
    // Kxg5 took a pawn: the king now stands on g5.
    final input = _input('8/8/3k4/5Kp1/6P1/8/8/8 w - - 3 63', 'Kxg5');
    expect(
      _say(ConceptKind.captureFree, Frame.does, input, object: 'g5'),
      'White wins the pawn on g5 for free.',
    );
  });

  test('the subject follows the user, and the verb agrees with it', () {
    final input = _input(
      'rnbqkbnr/pp1p1ppp/8/2pp4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4',
      'exd5',
    );
    String say(Side? user) => _say(
      ConceptKind.recapture,
      Frame.does,
      input,
      object: 'd5',
      userSide: user,
    );
    expect(say(Side.white), 'You take back on d5.');
    expect(say(Side.black), 'Your opponent takes back on d5.');
    expect(say(null), 'White takes back on d5.');
  });

  test('an ignored threat: on purpose, or a fault', () {
    const fischer =
        'r3r1k1/pp3pbp/1qp3p1/2B5/2BP2b1/Q1n2N2/P4PPP/3R1K1R b - - 3 17';
    final best = _input(fischer, 'Be6', betterUci: ['g4e6']);
    expect(
      _say(
        ConceptKind.ignoredThreat,
        Frame.does,
        best,
        object: 'b6',
        userSide: Side.black,
      ),
      'You ignore the threat to the queen on b6.',
    );
    final slip = _input(fischer, 'Qb5', betterUci: ['g4e6']);
    expect(
      _say(ConceptKind.ignoredThreat, Frame.better, slip, object: 'b6'),
      'Better was Be6, ignoring the threat to the queen on b6.',
    );
    expect(
      _say(ConceptKind.ignoredThreat, Frame.allows, best, object: 'b6'),
      'This leaves the threat to the queen on b6 unanswered.',
    );
  });

  group('each frame builds its own sentence', () {
    const fen = '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1';

    test('allows: what the opponent may now do', () {
      final input = _input(fen, 'Bg5', replyUci: ['h6g5']);
      expect(
        _say(ConceptKind.hangingPiece, Frame.allows, input, object: 'g5'),
        'This leaves the bishop on g5 hanging.',
      );
      expect(
        _say(
          ConceptKind.winMaterial,
          Frame.allows,
          input,
          object: 'g5',
          userSide: Side.white,
        ),
        'This lets your opponent win the bishop on g5.',
      );
    });

    test('better: the engine\'s move and what it would have done', () {
      final input = _input(
        'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
        'Kd2',
        betterUci: ['b5c7', 'e8d7'],
      );
      expect(
        _say(ConceptKind.fork, Frame.better, input, object: 'a8'),
        'Better was Nc7+, forking the rook on a8.',
      );
    });

    test('threatens: what the move sets up', () {
      final input = _input(
        'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3',
        'Qh5',
      );
      expect(
        _say(
          ConceptKind.mateThreat,
          Frame.threatens,
          input,
          userSide: Side.white,
        ),
        'You threaten mate.',
      );
    });
  });

  group('a sacrifice says what it buys', () {
    test('material back with interest, counted along the engine line', () {
      // The knight is left en prise; White declines, and the knight forks
      // its way to the rook on d1.
      const fen =
          '2r1k2r/1p3pp1/p2qpn2/2np1b1p/7P/P1N1PP2/1PP1BQP1/2KR2NR b k - 1 13';
      const reply = ['e3e4', 'a4c3', 'e4f5', 'c3d1', 'e2d1', 'e6f5'];
      final before = Chess.fromSetup(Setup.parseFen(fen));
      final played = before.parseSan('Na4')!;
      final input = _input(
        fen,
        'Na4',
        verdict: Classification.brilliant,
        replyUci: reply,
        tags: tagMove(
          before: before,
          played: played,
          refutationUci: reply,
          evalDrop: -0.2,
        ),
      );
      String say(Side? user) => _say(
        ConceptKind.sacrifice,
        Frame.does,
        input,
        object: 'a4',
        userSide: user,
      );
      expect(
        say(Side.black),
        'You sacrifice the knight on a4 and come out ahead: '
        'a rook and a pawn for a bishop.',
      );
      expect(
        say(null),
        'Black sacrifices the knight on a4 and comes out ahead: '
        'a rook and a pawn for a bishop.',
      );
    });

    test('a forced mate is the payoff, whatever the material', () {
      final input = _input(
        '1r2k1r1/pbppnp1p/1b3P2/8/Q7/B1PB1q2/P4PPP/3R2K1 w - - 0 21',
        'Qxd7+',
        verdict: Classification.brilliant,
        mateAfter: 3,
      );
      expect(
        _say(ConceptKind.sacrifice, Frame.does, input, object: 'd7'),
        'White sacrifices the queen on d7 to force mate.',
      );
    });

    test('with nothing counted back, the position is what pays', () {
      final input = _input(
        '1r2k1r1/pbppnp1p/1b3P2/8/Q7/B1PB1q2/P4PPP/3R2K1 w - - 0 21',
        'Qxd7+',
        verdict: Classification.brilliant,
      );
      expect(
        _say(
          ConceptKind.sacrifice,
          Frame.does,
          input,
          object: 'd7',
          userSide: Side.white,
        ),
        'You sacrifice the queen on d7, and the position makes up for it.',
      );
    });
  });

  test('a mixed gain is only "material": the net is easy to get wrong', () {
    final input = _input(
      'r1bq1rk1/5pp1/2pb3p/1p2p3/p1B5/2PP1Q1P/P1P2PP1/R1B1R1K1 w - - 0 18',
      'Qxc6',
      betterUci: ['c4b5', 'c6b5', 'f3a8'],
      tags: const MoveTags(
        missed: LineReading(
          won: [Role.rook, Role.pawn],
          gave: [Role.bishop],
          pays: true,
        ),
      ),
    );
    expect(
      _say(ConceptKind.winMaterial, Frame.better, input),
      'Better was Bxb5, winning material.',
    );
  });

  test('no material is claimed that the shown line does not capture', () {
    // The reading says two pawns, but the reply's first moves take nothing.
    final input = _input(
      '2kr4/1p2Rpp1/p6p/2p5/8/N6P/PP3PP1/6K1 b - - 0 24',
      'Rd2',
      replyUci: ['a3c4'],
      tags: const MoveTags(
        allowed: LineReading(won: [Role.pawn, Role.pawn], pays: true),
      ),
    );
    expect(
      _say(ConceptKind.winMaterial, Frame.allows, input),
      isNot(contains('win')),
    );
  });

  test('one piece won cleanly, and seen captured, is named', () {
    final input = _input(
      '4k3/8/7p/8/8/8/8/2B1K3 w - - 0 1',
      'Bg5',
      replyUci: ['h6g5'],
      tags: const MoveTags(
        allowed: LineReading(won: [Role.bishop], pays: true),
      ),
    );
    expect(
      _say(ConceptKind.winMaterial, Frame.allows, input),
      'This lets Black win a bishop.',
    );
  });

  test('a trade offered is an offer, not a trade made', () {
    final input = _input(
      'r1bq1rk1/ppp1bppp/2np1n2/4p3/2B1P3/2NP1N1P/PPP2PP1/R1BQ1RK1 b - - 2 7',
      'Be6',
    );
    expect(
      coachSentence(
        Concept(
          ConceptKind.evenTrade,
          Frame.does,
          object: Square.c4,
          evidence: 'offers a trade with the white bishop on c4',
        ),
        input,
        userSide: Side.black,
      ),
      'You offer a trade with the bishop on c4.',
    );
  });

  test('a tactic further down the line says so', () {
    final input = _input(
      'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
      'Kd2',
      betterUci: ['b5c7', 'e8d7'],
    );
    expect(
      coachSentence(
        Concept(
          ConceptKind.fork,
          Frame.better,
          object: Square.a8,
          evidence: 'later in the line: attacks …',
        ),
        input,
      ),
      'Better was Nc7+, forking the rook on a8 later in the line.',
    );
  });

  test('doubled pawns say whose they are', () {
    String say(ConceptInput input, Side? user) => coachSentence(
      detectConcepts(input).firstWhere(
        (c) => c.kind == ConceptKind.doubledPawns && c.frame == Frame.does,
      ),
      input,
      userSide: user,
    );
    // Bxg7 fxg7: White's g-pawns end up doubled, not Black's.
    final bxg7 = _input(
      '2k2b1r/pb1r1pQ1/5P2/1qnp4/Npp5/4B1P1/1P3PBP/R4RK1 b - - 5 21',
      'Bxg7',
      replyUci: ['f6g7', 'h8g8'],
    );
    expect(
      say(bxg7, Side.black),
      "You double your opponent's pawns on the g-file.",
    );
    expect(
      say(bxg7, Side.white),
      'Your opponent doubles your pawns on the g-file.',
    );
    expect(say(bxg7, null), "Black doubles White's pawns on the g-file.");
    // dxc5 dxc5: the pawn on c5 after the move is White's, but the doubled
    // pawns are Black's, once Black takes back.
    final dxc5 = _input(
      'r2q1r2/ppp2ppk/2np3p/2bNp2B/3PP3/2P3Q1/PP3PPP/R1B1K2R w KQ - 1 12',
      'dxc5',
      replyUci: ['d6c5', 'e1g1'],
    );
    expect(
      say(dxc5, Side.white),
      "You double your opponent's pawns on the c-file.",
    );
  });

  test('a tactic later in the line names the piece there at the time', () {
    // Qxg7 Rxa7 Kb8: the king forks the ROOK that took on a7, not the pawn
    // that stood there before the line.
    final input = _input(
      '2k3r1/pN3pP1/8/8/1ppq4/6P1/1P3P1P/R2R2K1 b - - 1 27',
      'Qxb2',
      betterUci: ['d4g7', 'a1a7', 'c8b8', 'd1a1'],
    );
    expect(
      coachSentence(
        Concept(
          ConceptKind.fork,
          Frame.better,
          object: Square.a7,
          evidence: 'later in the line: attacks …',
        ),
        input,
      ),
      'Better was Qxg7, forking the rook on a7 later in the line.',
    );
  });

  test('a Miss says the better move would have punished it, and no count', () {
    final input = _input(
      'r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1',
      'Kd2',
      verdict: Classification.miss,
      betterUci: ['b5c7'],
      tags: const MoveTags(
        missed: LineReading(won: [Role.pawn, Role.pawn], pays: true),
      ),
    );
    expect(
      _say(ConceptKind.missedWin, Frame.better, input),
      "This lets the opponent's mistake go; Nc7+ would have punished it.",
    );
  });

  test('a generic line reads the verdict, and names no concept', () {
    final input = _input(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      'a3',
      verdict: Classification.inaccuracy,
      betterUci: ['e2e4'],
    );
    expect(
      _say(ConceptKind.genericQuality, Frame.does, input),
      'Playable, but e4 was more accurate.',
    );
    expect(
      _say(ConceptKind.genericQuality, Frame.better, input),
      'Stronger was e4.',
    );
  });

  group('two ideas of one move, in one sentence', () {
    const bb5 =
        'rnbqkbnr/ppp2ppp/3p4/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3';

    test('development leads, the check rides on it, the purpose follows', () {
      final input = _input(
        bb5,
        'Bb5+',
        verdict: Classification.good,
        betterUci: ['d2d4'],
        replyUci: ['c7c6'],
      );
      expect(
        conceptLine(input, userSide: Side.white),
        'You develop the bishop with check and clear the way to castle.',
      );
    });

    test('a knight developed toward the centre', () {
      final input = _input(
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        'Nf3',
        verdict: Classification.best,
        replyUci: ['b8c6'],
      );
      expect(
        conceptLine(input, userSide: Side.white),
        'You develop the knight and fight for the centre.',
      );
    });

    test('the better move\'s check', () {
      final input = _input(
        bb5,
        'h3',
        verdict: Classification.mistake,
        betterUci: ['f1b5', 'c7c6'],
        replyUci: ['g8f6'],
      );
      expect(
        conceptLine(input),
        'Better was Bb5+, developing the bishop with check.',
      );
    });

    test('the reply\'s check', () {
      final input = _input(
        'r2k4/8/8/1N6/8/8/8/4K3 b - - 0 1',
        'Ke8',
        verdict: Classification.blunder,
        betterUci: ['d8d7'],
        replyUci: ['b5c7', 'e8d7', 'c7a8'],
        tags: const MoveTags(
          allowed: LineReading(won: [Role.rook], pays: true),
        ),
      );
      expect(
        conceptLine(input, userSide: Side.black),
        'This lets your opponent fork the rook on a8 with check.',
      );
    });

    test('too long for the bar: the paired idea is dropped first', () {
      final input = _input(
        bb5,
        'h3',
        verdict: Classification.mistake,
        betterUci: ['f1b5', 'c7c6'],
      );
      Concept better(ConceptKind kind) => Concept(
        kind,
        Frame.better,
        object: Square.b5,
        evidence: 'the better move: …',
      );
      expect(
        coachSentence(
          better(ConceptKind.developPiece),
          input,
          companions: (withCheck: true, also: better(ConceptKind.activeSquare)),
        ),
        'Better was Bb5+, developing the bishop with check.',
      );
    });
  });

  test('taking the piece that gives check names it, and no escape', () {
    final input = _input(
      '3rk3/8/8/8/8/8/4r3/R3K3 w - - 0 1',
      'Kxe2',
      verdict: Classification.best,
      previous: (to: Square.e2, captured: false),
      replyUci: ['d8d7'],
    );
    expect(
      conceptLine(input, userSide: Side.white),
      'You win the checking rook on e2 for free.',
    );
  });

  group('a perpetual check is the story', () {
    // Qe8+ Kh7 Qe4+ Kh8 Qe8+: the queen checks for ever, and the engine
    // scores it a draw.
    const fen = '7k/6p1/8/8/8/8/r4PPP/4Q1K1 w - - 0 1';
    const checks = ['h8h7', 'e8e4', 'h7h8', 'e4e8'];

    test('the check that starts it forces the draw', () {
      final input = _input(
        fen,
        'Qe8+',
        verdict: Classification.great,
        betterUci: const ['e1e8'],
        replyUci: checks,
        drawAfter: true,
      );
      expect(conceptLine(input), 'White forces a draw by perpetual check.');
    });

    test('the checks after it keep it up', () {
      final input = _input(
        fen,
        'Qe8+',
        verdict: Classification.best,
        betterUci: const ['e1e8'],
        replyUci: checks,
        drawAfter: true,
        perpetualInHand: true,
      );
      expect(conceptLine(input), 'White keeps up the perpetual check.');
    });

    test('a slip that lets the opponent check for ever says so', () {
      // ...Ra2 leaves the back rank to the queen.
      final input = _input(
        'r6k/6p1/8/8/8/8/5PPP/4Q1K1 b - - 0 1',
        'Ra2',
        verdict: Classification.blunder,
        betterUci: const ['h8g8', 'e1e7'],
        replyUci: const ['e1e8', ...checks],
        drawAfter: true,
        winPctDrop: 40,
      );
      expect(
        conceptLine(input),
        'This lets White force a draw by perpetual check.',
      );
    });

    test('a level position with checks in the line is no perpetual', () {
      final input = _input(
        fen,
        'Qe8+',
        verdict: Classification.best,
        betterUci: const ['e1e8'],
        replyUci: checks,
      );
      expect(conceptLine(input), isNot(contains('perpetual')));
    });
  });

  group('what the rules decide is said as it is', () {
    // Qc7 leaves the king on a8 no move, and it is not in check.
    const boxed = 'k7/8/1K6/8/8/8/8/2Q5 w - - 0 1';

    test('a stalemate from a won position throws the win away', () {
      final input = _input(
        boxed,
        'Qc7',
        verdict: Classification.blunder,
        betterUci: const ['c1c8'],
        winPctAfter: 50,
        winPctDrop: 47,
      );
      expect(conceptLine(input), 'Stalemate: a won game ends in a draw.');
    });

    test('a stalemate from a level position is just a draw', () {
      final input = _input(boxed, 'Qc7', winPctAfter: 50, winPctDrop: 0);
      expect(conceptLine(input), 'Stalemate: the game is drawn.');
    });

    // After Qd3 the black rook throws itself on b3; Qxb3 leaves the king on
    // a1 no move.
    const desperado = '8/1r6/8/8/4Q3/8/2K5/k7 w - - 0 1';

    test('a slip whose reply line ends in stalemate says so', () {
      final input = _input(
        desperado,
        'Qd3',
        verdict: Classification.blunder,
        betterUci: const ['e4b7'],
        replyUci: const ['b7b3', 'd3b3'],
        drawAfter: true,
        winPctDrop: 47,
      );
      expect(conceptLine(input), 'This lets Black force stalemate.');
    });

    test('a stalemate in a line that cost nothing is not the story', () {
      final input = _input(
        desperado,
        'Qd3',
        verdict: Classification.best,
        replyUci: const ['b7b3', 'd3b3'],
        drawAfter: true,
        winPctDrop: 0,
      );
      expect(conceptLine(input), isNot(contains('stalemate')));
    });

    test('a stalemate the better line forced is the better move', () {
      final input = _input(
        '8/1r6/8/8/8/3Q4/2K5/k7 b - - 0 1',
        'Ka2',
        verdict: Classification.mistake,
        betterUci: const ['b7b3', 'd3b3'],
        drawBefore: true,
        winPctDrop: 40,
      );
      expect(conceptLine(input), 'Better was Rb3, forcing stalemate.');
    });

    test('a mate in one is named from the board, with no engine line', () {
      // ...Rd2 leaves the back rank: Re8 mates.
      final input = _input(
        '3r2k1/5ppp/8/8/8/8/5PPP/4R1K1 b - - 0 1',
        'Rd2',
        verdict: Classification.blunder,
      );
      expect(conceptLine(input), 'This lets White mate at once with Re8#.');
    });

    test('the third repetition is a draw', () {
      // 1.Nf3 Nf6 2.Ng1, and ...Ng8 brings the start back.
      const fen = 'rnbqkb1r/pppppppp/5n2/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 3 2';
      ConceptInput third({
        bool draws = true,
        bool byChecks = false,
        double? after,
        double? drop,
        int times = 3,
      }) => ConceptInput(
        before: Chess.fromSetup(Setup.parseFen(fen)),
        played: Move.parse('f6g8')!,
        repetitions: times,
        repetitionDraws: draws,
        repeatedByChecks: byChecks,
        winPctAfter: after,
        winPctDrop: drop,
      );
      expect(
        conceptLine(third()),
        'That repeats the position a third time: a draw by repetition.',
      );
      expect(
        conceptLine(third(byChecks: true)),
        'That repeats the position a third time: a draw by perpetual check.',
      );
      expect(
        conceptLine(third(after: 50, drop: 35)),
        'That repeats the position a third time, and a won game is drawn.',
      );
      expect(
        conceptLine(third(times: 5)),
        'That repeats the position a fifth time: a draw by repetition.',
      );
      // The game went on: nobody took the draw, so the move is read as usual.
      expect(conceptLine(third(draws: false)), isNot(contains('repeats')));
      expect(
        _say(ConceptKind.repetition, Frame.does, third(draws: false)),
        'That repeats the position a third time: a draw could be claimed.',
      );
    });

    test('a won game drawn on the board gets a reaction', () {
      final input = _input(
        boxed,
        'Qc7',
        verdict: Classification.blunder,
        betterUci: const ['c1c8'],
        winPctAfter: 50,
        winPctDrop: 47,
      );
      expect(
        conceptReaction(input, userSide: Side.white)?.moment,
        Moment.drawnWin,
      );
      expect(conceptReaction(input, userSide: Side.white)!.cheers, isFalse);
      expect(conceptReaction(input, userSide: Side.black)!.cheers, isTrue);
      // A level stalemate is just a draw.
      expect(
        conceptReaction(_input(boxed, 'Qc7', winPctAfter: 50, winPctDrop: 0)),
        isNull,
      );
    });

    test('taking the last pawn leaves too little to mate', () {
      final input = _input('8/8/8/8/4p3/4K3/8/7k w - - 0 1', 'Kxe4');
      expect(
        conceptLine(input),
        'That leaves too little material to mate: the game is drawn.',
      );
    });
  });

  group('rooks on one file', () {
    test('a rook joining another on an open file doubles them', () {
      final input = _input(
        '6k1/pppp1ppp/8/8/8/8/PPPPRPPP/R5K1 w - - 0 1',
        'Rae1',
        verdict: Classification.best,
        betterUci: const ['a1e1'],
        replyUci: const ['g8f8'],
      );
      expect(conceptLine(input), 'White doubles the rooks on the e-file.');
    });

    test('a rook clearing the square the next rook doubles on prepares it', () {
      final input = _input(
        '6k1/pppp1ppp/8/8/8/8/PPPP1PPP/R3R1K1 w - - 0 1',
        'Re2',
        verdict: Classification.excellent,
        betterUci: const ['e1e2'],
        replyUci: const ['g8f8', 'a1e1'],
      );
      expect(
        conceptLine(input),
        'White makes room to double the rooks on the e-file.',
      );
    });

    test('a pawn of its own on the file is no doubling', () {
      final before = Chess.fromSetup(
        Setup.parseFen('6k1/pppp1ppp/8/8/8/8/PPPPRPPP/R5K1 w - - 0 1'),
      );
      expect(doubledRook(before, Move.parse('a1e1')!), isNotNull);
      final blocked = Chess.fromSetup(
        Setup.parseFen('6k1/pppp1ppp/8/8/4P3/8/PPPPRPPP/R5K1 w - - 0 1'),
      );
      expect(doubledRook(blocked, Move.parse('a1e1')!), isNull);
    });
  });

  group('praise carries the idea', () {
    test('a good move that attacks a rook says so after the praise', () {
      // Nd6 hits the rook on e8, and the rook has to move.
      final input = _input(
        '4r1k1/5ppp/8/1N6/8/8/5PPP/6K1 w - - 0 1',
        'Nd6',
        verdict: Classification.best,
        betterUci: const ['b5d6'],
        replyUci: const ['e8e6', 'd6b5'],
      );
      expect(conceptLine(input), 'Spot on, attacking the rook on e8.');
    });

    test('an attack the reply ignores is not named', () {
      final input = _input(
        '4r1k1/5ppp/8/1N6/8/8/5PPP/6K1 w - - 0 1',
        'Nd6',
        verdict: Classification.best,
        betterUci: const ['b5d6'],
        replyUci: const ['g8f8', 'h2h3', 'f8g8'],
      );
      expect(conceptLine(input), isNot(contains('attacking the rook')));
    });

    test('a defence that also attacks says both', () {
      // Qd7 covers the pawn on b7 and hits the loose knight on d6.
      final input = _input(
        '6k1/1p3ppp/3N4/8/8/7q/5P1P/6K1 b - - 0 1',
        'Qd7',
        verdict: Classification.best,
        betterUci: const ['h3d7'],
        replyUci: const ['d6b5'],
      );
      expect(
        conceptLine(input),
        'Black defends the pawn on b7 and attacks the knight on d6.',
      );
    });
  });

  test('stepping into the attacker\'s line blocks, it does not defend', () {
    // c3 shuts the bishop on b4 off the queen on d2, and hits it.
    final input = _input(
      '6k1/1ppp1ppp/8/8/1b6/8/2PQ1PPP/6K1 w - - 0 1',
      'c3',
      verdict: Classification.good,
      betterUci: const ['c2c3'],
      replyUci: const ['b4a5'],
    );
    expect(
      conceptLine(input),
      'White blocks the attack on the queen on d2 and kicks the bishop on b4 '
      'with a pawn.',
    );
  });

  group('a tactic the line reads is named with its square', () {
    test('the pin that wins the queen, not "material"', () {
      // Qe3 walks into ...Re8, pinning the queen to the king.
      final before = Chess.fromSetup(
        Setup.parseFen('r7/5k2/8/8/8/3Q4/8/4K3 w - - 0 1'),
      );
      const reply = ['a8e8', 'e3e8', 'f7e8', 'e1d2'];
      final input = _input(
        'r7/5k2/8/8/8/3Q4/8/4K3 w - - 0 1',
        'Qe3',
        verdict: Classification.blunder,
        betterUci: const ['d3d5', 'f7f6'],
        replyUci: reply,
        winPctDrop: 60,
        tags: MoveTags(
          allowed: readLine(
            start: before.play(Move.parse('d3e3')!),
            pvUci: reply,
          ),
        ),
      );
      expect(conceptLine(input), 'This lets Black pin the queen on e3.');
    });

    test('the piece lost is followed back to where the line found it', () {
      // The knight on e8 is taken on g7, after it took the pawn there.
      final start = Chess.fromSetup(
        Setup.parseFen('4N1k1/6p1/8/8/8/4r3/8/K7 b - - 0 1'),
      );
      const won = LineReading(won: [Role.knight]);
      expect(
        lostPiece(start, const ['e3e2', 'e8g7', 'g8g7'], Side.white, won),
        Square.e8,
      );
      expect(lostPiece(start, const ['e3e2'], Side.white, won), isNull);
    });
  });

  group('captures say what they win and what they cost', () {
    String say(
      String fen,
      String san,
      List<String> reply,
      Classification verdict, {
      List<String>? better,
      MoveTags? tags,
    }) {
      final before = Chess.fromSetup(Setup.parseFen(fen));
      final played = before.parseSan(san)!;
      return conceptLine(
        ConceptInput(
          before: before,
          played: played,
          replyUci: reply,
          betterUci: better ?? [played.uci],
          verdict: verdict,
          tags:
              tags ??
              MoveTags(
                allowed: readLine(start: before.play(played), pvUci: reply),
              ),
        ),
      );
    }

    test('a piece won for the one that took it', () {
      expect(
        say(
          '6k1/8/4b3/8/8/1R6/2P5/6K1 b - - 0 1',
          'Bxb3',
          ['c2b3'],
          Classification.best,
          // Read the way the app reads it: from before the capture, so the
          // bishop taken back is weighed against the rook.
          tags: tagMove(
            before: Chess.fromSetup(
              Setup.parseFen('6k1/8/4b3/8/8/1R6/2P5/6K1 b - - 0 1'),
            ),
            played: Move.parse('e6b3')!,
            refutationUci: const ['c2b3'],
          ),
        ),
        'Black wins the rook on b3 for the bishop.',
      );
    });

    test('a pawn taking a knight wins it, it offers nothing', () {
      expect(
        say(
          'r1bqk2r/pppp1ppp/8/8/3p4/2N5/PPP2PPP/R1BQKB1R b KQkq - 0 1',
          'dxc3',
          ['c1g5'],
          Classification.best,
        ),
        'Black wins the knight on c3 for a pawn.',
      );
      final before = Chess.fromSetup(
        Setup.parseFen(
          'r1bqk2r/pppp1ppp/8/8/3p4/2N5/PPP2PPP/R1BQKB1R b KQkq - 0 1',
        ),
      );
      final found = moveConcepts(
        before,
        before.parseSan('dxc3')!,
        phase: GamePhase.opening,
      );
      expect(found.map((f) => f.kind), isNot(contains(ConceptKind.gambit)));
    });

    test('a queen whose guard is pinned is taken for nothing', () {
      // The bishop on g2 guards c6 but is pinned to its king by the rook.
      expect(
        say('6rk/8/2Qr4/8/8/8/6B1/6K1 b - - 0 1', 'Rxc6', [
          'g1h1',
        ], Classification.best),
        'Black takes the queen on c6, whose defender is pinned.',
      );
    });

    test('a capture taken back for more than it took gives that piece', () {
      expect(
        say(
          '6k1/6p1/8/8/8/8/PB6/6K1 w - - 0 1',
          'Bxg7',
          ['g8g7'],
          Classification.good,
          better: ['g1f2'],
        ),
        'This gives the bishop for a pawn.',
      );
    });

    test('a rook left to be taken is said even when the verdict is fine', () {
      // In a lost position a rook can go without moving the chances much.
      expect(
        say(
          'r5k1/8/8/8/8/1b6/8/R5K1 w - - 0 1',
          'Ra2',
          ['b3a2'],
          Classification.good,
          better: ['a1a8'],
        ),
        'This leaves the rook on a2 hanging.',
      );
    });
  });

  group('board facts are about this move', () {
    Iterable<ConceptKind> kinds(String fen, String san, {String? followUp}) {
      final before = Chess.fromSetup(Setup.parseFen(fen));
      return moveConcepts(
        before,
        before.parseSan(san)!,
        followUp: followUp == null ? null : Move.parse(followUp),
      ).map((f) => f.kind);
    }

    test('pawns doubled by a capture elsewhere are not this move\'s', () {
      // Bxh6, then ...dxc3 takes the knight: Black's own doing.
      expect(
        kinds(
          '6k1/2p2pp1/7p/8/3p4/2N5/PP3PPP/2B3K1 w - - 0 1',
          'Bxh6',
          followUp: 'd4c3',
        ),
        isNot(contains(ConceptKind.doubledPawns)),
      );
    });

    test('a fork holds when taking the forker loses', () {
      // ...d4 hits the knight and the bishop; Bxd4 Bxd4 costs a piece.
      expect(
        kinds('4k3/8/8/2bp4/8/2N1B3/8/4K3 b - - 0 1', 'd4'),
        contains(ConceptKind.fork),
      );
    });

    test('a piece that wins by taking the pinner is not pinned', () {
      // Bxh6 "pins" g7 to the rook, but gxh6 just wins the bishop.
      expect(
        kinds('5rk1/6p1/7p/8/8/8/8/2B3K1 w - - 0 1', 'Bxh6'),
        isNot(contains(ConceptKind.pin)),
      );
      // A rook that can only trade itself off for the pinner stays pinned.
      expect(
        kinds('3k4/8/8/1B1r4/8/2R5/8/4K3 w - - 0 1', 'Rd3'),
        contains(ConceptKind.pin),
      );
    });
  });

  group('a sacrifice says what it buys from where the mover stood', () {
    // White is a queen down before Rd4; the line wins the queen back.
    final input = _input(
      '3qk3/8/8/2p5/8/8/8/3RK3 w - - 0 1',
      'Rd4',
      verdict: Classification.brilliant,
      tags: const MoveTags(
        allowed: LineReading(gave: [Role.queen], pays: true),
      ),
    );

    test('behind already, it wins material back', () {
      expect(
        _say(ConceptKind.sacrifice, Frame.does, input, object: 'd4'),
        'White sacrifices the rook on d4 and wins material back.',
      );
    });
  });

  group('an offer', () {
    // Rd4 leaves the rook to the pawn on c5.
    const fen = '4k3/8/8/2p5/8/8/8/3RK2Q w - - 0 1';
    String say(Acceptance? acceptance) {
      final before = Chess.fromSetup(Setup.parseFen(fen));
      return coachSentence(
        Concept(
          ConceptKind.sacrifice,
          Frame.does,
          object: Square.d4,
          evidence: '',
        ),
        ConceptInput(
          before: before,
          played: before.parseSan('Rd4')!,
          verdict: Classification.best,
          replyUci: const ['e8e7'],
          acceptance: acceptance,
        ),
      );
    }

    test('declined, says only the offer', () {
      expect(say(null), 'White offers the rook on d4.');
      expect(
        say((uci: 'e8e7', replyUci: const ['d4d7'], mates: false)),
        'White offers the rook on d4.',
      );
    });

    test('taken, says what taking it lets in', () {
      expect(
        say((uci: 'c5d4', replyUci: const ['h1h8'], mates: false)),
        'White offers the rook on d4; taking it lets in Qh8+.',
      );
    });

    test('taken, names no quiet move as what it lets in', () {
      expect(
        say((uci: 'c5d4', replyUci: const ['e1d2'], mates: false)),
        'White offers the rook on d4.',
      );
    });

    test('taken into a mate, says so', () {
      expect(
        say((uci: 'c5d4', replyUci: const ['e1d2'], mates: true)),
        'White offers the rook on d4; taking it walks into mate.',
      );
    });
  });

  test('an inaccuracy with nothing concrete names the better move only', () {
    final input = _input(
      '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1',
      'Kd1',
      verdict: Classification.inaccuracy,
      betterUci: ['e2e4'],
    );
    expect(
      _say(ConceptKind.genericQuality, Frame.does, input),
      isIn(['Playable, but e4 was more accurate.', 'e4 was more accurate.']),
    );
  });

  group('the tree fills in what the moves around one know', () {
    GameNode at(GameTree tree, int ply) {
      var node = tree.root;
      for (var i = 0; i < ply; i++) {
        node = node.children.first;
      }
      return node;
    }

    GameTree searched(String pgn) {
      final tree = GameTree.fromPgn(pgn);
      for (var node = tree.root; ; node = node.children.first) {
        node.eval = EngineEval(cp: 0, bestMoveUci: 'a2a3', depth: 15);
        if (node.children.isEmpty) break;
      }
      return tree;
    }

    test('a capture two moves back, its piece still there', () {
      // 4.dxe5 Bxf3 5.Qxf3 dxe5: the pawn on e5 took a pawn.
      final tree = searched(
        '1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 *',
      );
      expect(conceptInputFor(at(tree, 10))!.earlierCapture, (
        to: Square.e5,
        took: Role.pawn,
      ));
      // 5.Qxf3: Black's move before Bxf3, 3...Bg4, took nothing.
      expect(conceptInputFor(at(tree, 9))!.earlierCapture, isNull);
    });

    test('not after captures there that came out even', () {
      // 5.exd5 Nxd5 traded pawns on d5; 7.Bxd5 starts a new trade.
      final even = searched(
        '1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. Ng5 d5 5. exd5 Nxd5 6. d3 Be7 '
        '7. Bxd5 *',
      );
      expect(conceptInputFor(at(even, 13))!.earlierCapture, isNull);
      // 3.Bxc6 bxc6 6.Nxc6 left White a pawn up there: dxc6 takes it back.
      final ahead = searched(
        '1. e4 Nc6 2. Bb5 Nf6 3. Bxc6 bxc6 4. Ne2 e6 5. Nd4 Be7 6. Nxc6 O-O '
        '7. d3 dxc6 *',
      );
      expect(conceptInputFor(at(ahead, 14))!.earlierCapture, (
        to: Square.c6,
        took: Role.pawn,
      ));
    });

    test('a position counts each time it stood, the root included', () {
      final tree = searched('1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 *');
      expect(conceptInputFor(at(tree, 4))!.repetitions, 2);
      expect(conceptInputFor(at(tree, 7))!.repetitions, 2);
      expect(conceptInputFor(at(tree, 8))!.repetitions, 3);
      expect(conceptInputFor(at(tree, 1))!.repetitions, 1);
    });

    test('the third time is a draw only where the line stops', () {
      const shuffle = '1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8';
      final ended = searched('$shuffle *');
      expect(drawnByRepetition(at(ended, 8)), isTrue);
      expect(drawnByRepetition(at(ended, 4)), isFalse);
      final went = searched('$shuffle 5. e4 *');
      expect(drawnByRepetition(at(went, 8)), isFalse);
      expect(repeatedByChecks(at(ended, 8)), isFalse);
    });

    test('a repetition made by checks is a perpetual', () {
      // Qh5+ Kg8 Qe8+ Kh7, twice, and Qh5+ stands a third time.
      final tree = searched(
        '[FEN "8/6pk/8/8/8/8/r7/3Q3K w - - 0 1"]\n\n'
        '1. Qh5+ Kg8 2. Qe8+ Kh7 3. Qh5+ Kg8 4. Qe8+ Kh7 5. Qh5+ *',
      );
      final third = at(tree, 9);
      expect(repetitionsOf(third), 3);
      expect(repeatedByChecks(third), isTrue);
      expect(repeatedByChecks(at(tree, 8)), isFalse, reason: 'twice only');
      expect(
        conceptLine(conceptInputFor(third)!),
        'That repeats the position a third time: a draw by perpetual check.',
      );
    });

    test('the game\'s next move, once searched', () {
      final tree = searched('1. e4 e5 2. Nf3 *');
      final acceptance = conceptInputFor(at(tree, 2))!.acceptance;
      expect(acceptance?.uci, 'g1f3');
      expect(conceptInputFor(at(tree, 3))!.acceptance, isNull);
    });
  });

  test('chasing a defender attacks it; only taking it removes it', () {
    // g6 hits the pawn on f7, which guards the pawn on e6.
    final input = _input(
      'r3k2r/2qbbpp1/p2pp3/np4Pp/3NPPn1/PBN1B3/1PP1Q2P/R4RK1 w kq - 1 15',
      'g6',
      verdict: Classification.best,
    );
    expect(
      _say(ConceptKind.removeDefender, Frame.does, input, object: 'e6'),
      'White attacks the defender of the pawn on e6.',
    );
  });

  test('a backward pawn the move leaves is the move\'s own doing', () {
    // d4 leaves the pawn on c5 behind.
    final input = _input(
      '1r1q1rk1/p4pp1/3bpn1p/2pp1b2/5P2/P1NP3P/1PP1N1P1/R1BQ1RK1 b - - 1 14',
      'd4',
      verdict: Classification.inaccuracy,
      replyUci: ['c3a4'],
    );
    expect(
      _say(ConceptKind.backwardPawn, Frame.allows, input, object: 'c5'),
      'This leaves a backward pawn on c5.',
    );
  });

  group('en passant', () {
    // hxg6 takes the pawn that stood on g5; the capture happens on g6.
    final input = _input(
      '8/8/7k/6pP/8/8/8/4K3 w - g6 0 1',
      'hxg6+',
      verdict: Classification.best,
      replyUci: ['h6g6'],
    );

    test('a trade is said where it happens', () {
      expect(
        _say(ConceptKind.evenTrade, Frame.does, input, object: 'g5'),
        'White trades evenly on g6.',
      );
    });

    test('the pawn is named where it stood, en passant', () {
      expect(
        _say(ConceptKind.capture, Frame.does, input, object: 'g5'),
        'White takes the pawn on g5 en passant.',
      );
    });
  });
}
