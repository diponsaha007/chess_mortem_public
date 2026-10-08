import 'package:chess_mortem/llm/explanation_prompt.dart';
import 'package:chess_mortem/llm/move_explainer.dart';
import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/model/eval.dart';
import 'package:chess_mortem/model/game_tree.dart';
import 'package:chess_mortem/model/move_tags.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// After 1.e4 e5 2.Nf3 Nc6, White to move.
const _fen = 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

ExplanationContext _ctx({
  String played = 'Bc4',
  Side mover = Side.white,
  Classification verdict = Classification.good,
  double before = 0.3,
  double after = 0.2,
  int? mateInBefore,
  int? mateInAfter,
  String? best = 'Bb5',
  List<String> bestLine = const ['Bb5', 'a6', 'Ba4', 'Nf6', 'O-O'],
  List<String> refutation = const ['Nf6', 'd3', 'Bc5'],
  List<String> facts = const [],
  List<String> betterFacts = const [],
  MoveTags tags = MoveTags.none,
  bool evenTrade = false,
  int? plyBefore = 4,
  String? previous,
  String? opening,
  String? coachLine,
  List<String> runnerUp = const [],
  double? runnerUpPawns,
  String fen = _fen,
}) => ExplanationContext(
  fenBefore: fen,
  playedSan: played,
  mover: mover,
  classification: verdict,
  evalBeforePawns: before,
  evalAfterPawns: after,
  mateInBefore: mateInBefore,
  mateInAfter: mateInAfter,
  bestMoveSan: best,
  bestLineSan: bestLine,
  refutationLineSan: refutation,
  facts: facts,
  betterFacts: betterFacts,
  tags: tags,
  startsEvenTrade: evenTrade,
  plyBefore: plyBefore,
  previousSan: previous,
  openingName: opening,
  coachLine: coachLine,
  runnerUpLineSan: runnerUp,
  runnerUpPawns: runnerUpPawns,
);

void main() {
  group('explanationSystemPrompt', () {
    test('asks for ONE part: the coach line above it is the headline', () {
      expect(explanationSystemPrompt, contains('one\nor two sentences'));
      expect(explanationSystemPrompt, contains('at most 40 words'));
      expect(explanationSystemPrompt, contains('no\nheadline'));
      expect(explanationSystemPrompt, isNot(contains('two parts')));
    });

    test('asks for the idea, never a walk through the line', () {
      expect(explanationSystemPrompt, contains('Give the idea, not the moves'));
      expect(explanationSystemPrompt, contains('Never walk through a line'));
    });

    test('an honest "I cannot see it" is offered as a good answer', () {
      // A quiet move's reason is often nowhere in the facts; a model told
      // to explain anyway invents one.
      expect(explanationSystemPrompt, contains("The engine's reason is"));
      expect(
        explanationSystemPrompt,
        contains('An\nhonest short answer beats a confident wrong one.'),
      );
    });

    test('names the sides: "you" went to the wrong player', () {
      expect(explanationSystemPrompt, contains('never say "you"'));
    });

    test('claims the facts true, never complete', () {
      // moveFacts counts attackers and defenders with no notion of pins or
      // exchange order, so completeness is not the code's to promise.
      expect(explanationSystemPrompt, contains('Everything below is true'));
      expect(explanationSystemPrompt, isNot(contains('complete')));
    });
  });

  group('buildPrompt, every verdict', () {
    test('names the move numbered, its side and its verdict', () {
      final prompt = buildPrompt(_ctx());
      expect(
        prompt,
        startsWith('Move: 3.Bc4, played by White. Verdict: Good.'),
      );
    });

    test('evals as words, never numbers', () {
      // Given "(+0.3)", models quote it back.
      final prompt = buildPrompt(_ctx(before: 0.3, after: -2.0));
      expect(
        prompt,
        contains('White was level before it, and is clearly worse after it.'),
      );
      expect(prompt, isNot(matches(RegExp(r'[+-]\d\.\d'))));
    });

    test('a mate is described in words, never as 99 pawns', () {
      final prompt = buildPrompt(
        _ctx(verdict: Classification.best, after: -99, mateInAfter: -1),
      );
      expect(prompt, contains('being mated in 1 move'));
      expect(prompt, isNot(contains('99')));
    });

    test('the board is a piece list by colour, not a FEN', () {
      final prompt = buildPrompt(_ctx());
      expect(
        prompt,
        contains(
          'Pieces before the move: White: Ke1 Qd1 Ra1 Rh1 Bc1 Bf1 Nb1 Nf3, '
          'pawns a2 b2 c2 d2 f2 g2 h2 e4. Black: Ke8 Qd8 Ra8 Rh8 Bc8 Bf8 '
          'Nc6 Ng8, pawns e5 a7 b7 c7 d7 f7 g7 h7.',
        ),
      );
      expect(prompt, isNot(contains(_fen)));
    });

    test('contains no raw UCI coordinates', () {
      for (final verdict in Classification.values) {
        expect(
          buildPrompt(_ctx(verdict: verdict)),
          isNot(matches(RegExp(r'\b[a-h][1-8][a-h][1-8]\b'))),
          reason: verdict.name,
        );
      }
    });

    test('the coach line is handed over as what the player already read', () {
      final prompt = buildPrompt(
        _ctx(coachLine: 'Bb5 instead, pinning the knight on c6.'),
      );
      expect(
        prompt,
        contains('Already shown: "Bb5 instead, pinning the knight on c6."'),
      );
    });

    test('board facts are handed over', () {
      final prompt = buildPrompt(
        _ctx(facts: const ['The bishop on c4 attacks the black pawn on f7.']),
      );
      expect(prompt, contains('Facts about Bc4:\n'));
      expect(
        prompt,
        contains('- The bishop on c4 attacks the black pawn on f7.'),
      );
    });

    test('no facts, no heading', () {
      expect(buildPrompt(_ctx()), isNot(contains('Facts about')));
    });

    test('ends on exactly one "Write:" task', () {
      for (final verdict in Classification.values) {
        final prompt = buildPrompt(_ctx(verdict: verdict));
        expect('Write:'.allMatches(prompt), hasLength(1), reason: verdict.name);
        expect(prompt.split('\n').last, contains('Write:'));
      }
    });
  });

  group('buildPrompt for a move the engine liked', () {
    ExplanationContext liked(
      Classification verdict, {
      double after = 0.3,
      int? mateInBefore,
      int? mateInAfter,
      List<String> runnerUp = const [],
      double? runnerUpPawns,
    }) => _ctx(
      played: 'Bb5',
      verdict: verdict,
      after: after,
      mateInBefore: mateInBefore,
      mateInAfter: mateInAfter,
      bestLine: const ['Bb5', 'a6'],
      refutation: const ['a6', 'Ba4'],
      runnerUp: runnerUp,
      runnerUpPawns: runnerUpPawns,
    );

    test('Best asks what it achieves, and accepts "simply sound"', () {
      for (final verdict in [Classification.best, Classification.excellent]) {
        final prompt = buildPrompt(liked(verdict));
        expect(prompt, contains('Expected continuation: 3...a6 4.Ba4'));
        expect(prompt, contains('Write: what Bb5 achieves.'));
        expect(prompt, contains('If it is simply a sound move'));
        expect(prompt, isNot(contains('Better was')));
      }
    });

    // The reported failure: the best defence in a lost position came back
    // described as a "brutal blunder".
    test('a best move in a lost position is framed as damage control', () {
      final prompt = buildPrompt(
        liked(
          Classification.best,
          after: -99,
          mateInBefore: -2,
          mateInAfter: -3,
        ),
      );
      expect(
        prompt,
        contains('what Bb5 holds off — White is still in trouble'),
      );
    });

    test('Great is set against the runner-up, read from the engine', () {
      // Asked "what would go wrong without it" with nothing to go on, every
      // model invented the answer.
      final prompt = buildPrompt(
        liked(
          Classification.great,
          runnerUp: const ['Bc4', 'Nf6', 'Ng5'],
          runnerUpPawns: -1.8,
        ),
      );
      expect(
        prompt,
        contains(
          'Next-best move: Bc4 (line: 3.Bc4 Nf6 4.Ng5), after which White '
          'would be clearly worse.',
        ),
      );
      expect(
        prompt,
        contains('Write: what Bb5 achieves that the next-best move does not.'),
      );
    });

    test('with no runner-up searched, none is claimed', () {
      final prompt = buildPrompt(liked(Classification.great));
      expect(prompt, isNot(contains('Next-best move:')));
    });

    test('Brilliant is asked what the material buys', () {
      final prompt = buildPrompt(liked(Classification.brilliant));
      expect(prompt, contains('Write: what the material Bb5 gives up buys.'));
      expect(prompt, isNot(contains('achieves.')));
    });
  });

  group('buildPrompt for a Good move', () {
    test('asks the one thing the better move adds', () {
      final prompt = buildPrompt(_ctx());
      expect(
        prompt,
        contains('Better was Bb5 (line: 3.Bb5 a6 4.Ba4 Nf6 5.O-O).'),
      );
      expect(prompt, contains('Write: the one thing Bb5 adds over Bc4.'));
      // The refutation belongs to bad moves only.
      expect(prompt, isNot(contains('best answer')));
    });

    test('the better move\'s own facts come with it', () {
      final prompt = buildPrompt(
        _ctx(betterFacts: const ['The bishop on b5 attacks the knight on c6.']),
      );
      expect(
        prompt,
        contains(
          'Facts about Bb5:\n- The bishop on b5 attacks the knight on c6.',
        ),
      );
    });
  });

  group('buildPrompt for a Miss', () {
    test('is about the chance the opponent gave, not a loss', () {
      final prompt = buildPrompt(
        _ctx(
          played: 'd3',
          verdict: Classification.miss,
          before: 4.8,
          after: 0.4,
          previous: 'Nd4',
        ),
      );
      expect(
        prompt,
        contains("Black's last move, Nd4, was a mistake, and d3 let it go."),
      );
      expect(prompt, contains('Write: what Bb5 would have won or achieved.'));
      expect(prompt, contains('d3 is not a blunder'));
      expect(prompt, isNot(contains('best answer')));
    });

    test("still reads without the opponent's move or a better one", () {
      final prompt = buildPrompt(
        _ctx(
          played: 'd3',
          verdict: Classification.miss,
          best: null,
          bestLine: const [],
        ),
      );
      expect(prompt, contains("Black's last move was a mistake"));
      expect(prompt, contains('what the right move would have won'));
      expect(prompt, isNot(contains('null')));
    });
  });

  group('buildPrompt for a slip', () {
    // 15...Bxe5: White wins a pawn four moves later.
    const slipFen =
        '2r2rk1/pp1b1ppp/1q1bpn2/n3N3/3P4/1P3B1P/PB3PP1/RN1QR1K1 b - - 4 15';
    ExplanationContext slip({
      Classification verdict = Classification.mistake,
      List<LedgerEntry> ledger = const [
        LedgerEntry('19.Nxd5', 'White is up a pawn'),
      ],
      bool evenTrade = false,
      MoveTags? tags,
      List<String> refutation = const [
        'dxe5',
        'Nd5',
        'Bxd5',
        'exd5',
        'Nc3',
        'Be6',
        'Nxd5',
        'Qc5',
      ],
    }) => _ctx(
      fen: slipFen,
      played: 'Bxe5',
      mover: Side.black,
      verdict: verdict,
      before: 0.2,
      after: -1.4,
      best: 'Rfd8',
      bestLine: const ['Rfd8', 'Nd2'],
      refutation: refutation,
      tags: tags ?? MoveTags(ledger: ledger),
      evenTrade: evenTrade,
      plyBefore: 29,
    );

    test('the punishing line is numbered and cut short', () {
      final prompt = buildPrompt(slip());
      // 19.Nxd5 is the 7th ply: given whole lines, models recite them.
      expect(
        prompt,
        contains("White's best answer: 16.dxe5 Nd5 17.Bxd5 exd5 18.Nc3 Be6\n"),
      );
    });

    test('material is told WHEN it changes', () {
      expect(
        buildPrompt(slip()),
        contains('Material along it: After 19.Nxd5, White is up a pawn.'),
      );
    });

    test('asks what the move overlooks, then the better move', () {
      expect(
        buildPrompt(slip()).split('\n').last,
        'Write: what Bxe5 overlooks or leaves loose, then in a few words what '
        'Rfd8 does instead.',
      );
    });

    test('a line of even trades forbids claiming material', () {
      // A Mistake here would be a quiet slip; a Blunder keeps the guard.
      final prompt = buildPrompt(
        slip(
          verdict: Classification.blunder,
          ledger: const [LedgerEntry('16.dxe5', 'level')],
        ),
      );
      expect(prompt, contains('Material stays level along it'));
      expect(prompt, contains('not a piece'));
    });

    test('an even trade says the damage comes after it', () {
      expect(
        buildPrompt(slip(evenTrade: true)),
        contains('Bxe5 itself is an even trade; the damage comes after it.'),
      );
    });

    test('a named tactic is handed over, so "fork" is read, never guessed', () {
      // White's king steps off e3, leaving the knight on d4 to the bishop.
      final before = Chess.fromSetup(
        Setup.parseFen('4k3/8/1b6/8/3N4/4K3/8/8 w - - 0 1'),
      );
      final tags = tagMove(
        before: before,
        played: Move.parse('e3e2')!,
        refutationUci: const ['b6d4'],
      );
      final prompt = buildPrompt(
        _ctx(
          fen: before.fen,
          played: 'Ke2',
          verdict: Classification.blunder,
          before: 0,
          after: -3,
          best: 'Ke4',
          bestLine: const ['Ke4'],
          refutation: const ['Bxd4'],
          tags: tags,
          plyBefore: 0,
        ),
      );
      expect(
        prompt,
        contains(
          'Tactic it allows: Black takes the knight that was left hanging.',
        ),
      );
    });

    test('a quiet slip is asked what the better move does, or to say so', () {
      final prompt = buildPrompt(
        slip(
          verdict: Classification.inaccuracy,
          ledger: const [LedgerEntry('16.dxe5', 'level')],
        ),
      );
      expect(prompt, contains('the difference is positional'));
      expect(prompt, contains('only if the facts show it'));
      expect(prompt, contains('otherwise say the reason is long-term'));
      expect(prompt, contains('Do not claim Bxe5 loses or allows anything.'));
      // Not asked why the move is bad: there is no fact for it.
      expect(prompt, isNot(contains('best answer')));
      expect(prompt, isNot(contains('overlooks')));
    });

    test('a blunder is never treated as a quiet slip', () {
      final prompt = buildPrompt(
        slip(
          verdict: Classification.blunder,
          ledger: const [LedgerEntry('16.dxe5', 'level')],
        ),
      );
      expect(prompt, contains("White's best answer"));
      expect(prompt, isNot(contains('the difference is positional')));
    });

    test('degrades gracefully with no best move and no refutation', () {
      final prompt = buildPrompt(
        _ctx(
          played: 'Nxe5',
          verdict: Classification.mistake,
          best: null,
          bestLine: const [],
          refutation: const [],
        ),
      );
      expect(prompt, isNot(contains('null')));
      expect(prompt, isNot(contains('best answer')));
      expect(
        prompt.split('\n').last,
        'Write: what Nxe5 overlooks or leaves loose.',
      );
    });
  });

  group('buildPrompt for a book move', () {
    test('asks for the plan, never a verdict', () {
      final prompt = buildPrompt(
        _ctx(
          fen: Chess.initial.fen,
          played: 'c5',
          mover: Side.black,
          verdict: Classification.inaccuracy,
          opening: 'B20 Sicilian Defense',
          plyBefore: 1,
        ),
      );
      expect(prompt, contains('This is opening theory: B20 Sicilian Defense.'));
      expect(prompt, contains('Write: what c5 aims for in this opening.'));
      // Theory is not something to be refuted, even at a small eval dip.
      expect(prompt, isNot(contains('best answer')));
      expect(prompt, isNot(contains('Better was')));
    });
  });

  group('buildExplanationContext', () {
    test('carries the runner-up, from the mover\'s side', () {
      final tree = GameTree.fromPgn('1. e4 e5 *');
      final reply = tree.mainline[1];
      reply.classification = Classification.great;
      // White-perspective: +1.8 for White is -1.8 for Black, who moved.
      final before = const EngineEval(
        cp: 20,
        bestMoveUci: 'e7e5',
        pvUci: ['e7e5'],
        depth: 15,
      ).withRunnerUp(const EngineLine(cp: 180, pvUci: ['a7a6', 'd2d4']));
      final context = buildExplanationContext(
        node: reply,
        before: before,
        after: const EngineEval(cp: 20, bestMoveUci: 'g1f3', depth: 15),
      );
      expect(context.runnerUpLineSan, ['a6', 'd4']);
      expect(context.runnerUpPawns, closeTo(-1.8, 1e-9));
    });

    test('no runner-up searched is none, never a guess', () {
      final tree = GameTree.fromPgn('1. e4 *');
      final move = tree.mainline.first;
      move.classification = Classification.best;
      final context = buildExplanationContext(
        node: move,
        before: const EngineEval(cp: 20, bestMoveUci: 'e2e4', depth: 15),
        after: const EngineEval(cp: 20, bestMoveUci: 'e7e5', depth: 15),
      );
      expect(context.runnerUpLineSan, isEmpty);
      expect(context.runnerUpPawns, isNull);
    });
  });

  group('standingPhrase', () {
    test('spells out mates from the mover\'s own perspective', () {
      expect(standingPhrase(pawns: 99, mateIn: 3), 'mating in 3 moves');
      expect(standingPhrase(pawns: -99, mateIn: -1), 'being mated in 1 move');
      expect(standingPhrase(pawns: 99, mateIn: 0), 'checkmate on the board');
    });

    test('grades a centipawn score in words only', () {
      expect(standingPhrase(pawns: 0.2), 'level');
      expect(standingPhrase(pawns: -0.9), 'slightly worse');
      expect(standingPhrase(pawns: 2.0), 'clearly better');
      expect(standingPhrase(pawns: -4.5), 'losing');
      expect(standingPhrase(pawns: 8.0), 'completely winning');
    });
  });

  group('explanationFrom', () {
    test('keeps the whole answer, paragraphs and all', () {
      // Splitting off a "headline" hid the first line of a one-part answer.
      expect(
        explanationFrom('Hangs the rook.\n\nBxa8 just takes it.').detail,
        'Hangs the rook.\n\nBxa8 just takes it.',
      );
    });

    test('drops bold markers and surrounding space', () {
      expect(
        explanationFrom('  **Hangs** the rook.  ').detail,
        'Hangs the rook.',
      );
    });
  });

  group('stripReasoning', () {
    test('leaves an ordinary answer alone', () {
      expect(
        stripReasoning('Hangs the rook.\n\nBxa8 just takes it.'),
        'Hangs the rook.\n\nBxa8 just takes it.',
      );
    });

    test('drops a closed think block and keeps the answer', () {
      expect(
        stripReasoning('<think>let me check e4</think>\n\nSolid.\n\nHolds d5.'),
        'Solid.\n\nHolds d5.',
      );
    });

    test('drops thinking under any of the tags models use', () {
      for (final tag in ['think', 'thinking', 'reasoning', 'THINK']) {
        expect(
          stripReasoning('<$tag>hmm</${tag.toLowerCase()}>Answer.'),
          'Answer.',
        );
      }
    });

    test('keeps what a model wrote between two think blocks', () {
      expect(
        stripReasoning('<think>one</think>Answer.<think>two</think>'),
        'Answer.',
      );
    });

    test('thinking cut off by the token cap leaves nothing', () {
      expect(stripReasoning("<think>Here's a thinking process: 1. Ana"), '');
    });
  });
}
