/// Pure helpers that assemble the LLM prompt. No I/O.
library;

import 'package:dartchess/dartchess.dart';

import '../model/classification.dart';
import '../model/eval.dart';
import '../model/game_tree.dart';
import '../model/move_facts.dart';
import '../model/move_tags.dart';
import '../model/pv_line.dart';
import '../model/sides.dart';
import 'llm_config.dart';
import 'move_explainer.dart';

/// The [ExplanationContext] for a played move: evals flipped to the mover,
/// PVs in SAN, board facts attached.
ExplanationContext buildExplanationContext({
  required GameNode node,
  required EngineEval before,
  required EngineEval after,
  String? coachLine,
}) {
  final mover = node.sideThatMoved;
  final sign = mover == Side.white ? 1 : -1;
  final positionBefore = node.parent!.position;
  final runnerUp = before.secondBest;

  return ExplanationContext(
    fenBefore: positionBefore.fen,
    playedSan: node.san!,
    mover: mover,
    classification: node.classification!,
    evalBeforePawns: sign * before.pawns,
    evalAfterPawns: sign * after.pawns,
    mateInBefore: before.mateIn == null ? null : sign * before.mateIn!,
    mateInAfter: after.mateIn == null ? null : sign * after.mateIn!,
    bestMoveSan: sanOf(positionBefore, before.bestMoveUci),
    bestLineSan: pvToSan(positionBefore, before.pvUci),
    // [after] was searched from the position the move created, so its PV is
    // the engine's refutation — already cached.
    refutationLineSan: pvToSan(node.position, after.pvUci),
    facts: moveFacts(
      before: positionBefore,
      move: node.move!,
      san: node.san!,
      replyUci: after.bestMoveUci,
    ),
    openingName: node.openingName,
    tags: node.tags,
    startsEvenTrade: startsEvenTrade(positionBefore, node.move!),
    plyBefore: node.ply - 1,
    betterFacts: _betterFacts(positionBefore, before, node.move!),
    previousSan: node.parent?.san,
    coachLine: coachLine,
    runnerUpLineSan: runnerUp == null
        ? const []
        : pvToSan(positionBefore, runnerUp.pvUci),
    runnerUpPawns: runnerUp?.cp == null ? null : sign * runnerUp!.cp! / 100,
    runnerUpMateIn: runnerUp?.mateIn == null ? null : sign * runnerUp!.mateIn!,
  );
}

/// [moveFacts] for the engine's move from [positionBefore], when it is not
/// the move played. What the move itself does only: the reply's two-move
/// material count reads as the better move's cost ("gives up a pawn").
List<String> _betterFacts(
  Position positionBefore,
  EngineEval before,
  Move played,
) {
  final uci = before.bestMoveUci;
  final best = uci == null ? null : Move.parse(uci);
  if (best == null || uci == played.uci || !positionBefore.isLegal(best)) {
    return const [];
  }
  return moveFacts(
    before: positionBefore,
    move: best,
    san: positionBefore.makeSan(best).$2,
  );
}

/// Pins the model to verbalizing. Kept short on purpose: small models drop
/// the rules first when the instructions run long. The coach line above the
/// answer is the headline, so the answer is ONE part: the reason.
const explanationSystemPrompt = '''
You are a chess coach. The player has just read a one-line verdict on a move
("Already shown" below). Add the reason behind it, without repeating it: one
or two sentences, at most 40 words.

Give the idea, not the moves: what the move changes — a piece left loose, a
king opened up, a square or file given away, a threat met or ignored, a plan
it serves. Never walk through a line; name at most two moves.

Everything below is true, and it is all you know. Never contradict it, and
never name a piece, square, threat or tactic it does not show. When it does
not show why, say so in one sentence — for example "The engine's reason is
long-term here; there is no single tactic to point to." — and stop. An
honest short answer beats a confident wrong one.

Write about White and Black by name; never say "you". Plain prose: no
headline, no list, no markdown, no numbers.''';

/// The chat-completions body for one explanation.
Map<String, Object?> chatPayload(LlmCredential credential, String prompt) => {
  'model': credential.model,
  'max_tokens': credential.provider.maxTokensFor(credential.model),
  'messages': [
    {'role': 'system', 'content': explanationSystemPrompt},
    {'role': 'user', 'content': prompt},
  ],
  ...credential.provider.requestExtras(credential.model),
};

/// Tagged thinking. Non-greedy, so two blocks both go.
final _thinkBlock = RegExp(
  r'<(think|thinking|reasoning)>[\s\S]*?</\1>',
  caseSensitive: false,
);

/// Thinking cut off by the token cap: an opening tag with no closing one.
final _unclosedThink = RegExp(
  r'<(?:think|thinking|reasoning)>[\s\S]*$',
  caseSensitive: false,
);

/// Drops a reasoning model's thinking. An UNCLOSED block
/// strips to nothing on purpose, so the caller fails with a Retry button.
String stripReasoning(String raw) =>
    raw.replaceAll(_thinkBlock, '').replaceFirst(_unclosedThink, '').trim();

/// The answer as shown: one part, whole. Bold markers are dropped, since
/// the sheet shows plain text and some models add them anyway. [model]
/// names who wrote it.
MoveExplanation explanationFrom(String answer, {String? model}) =>
    MoveExplanation(
      detail: answer.replaceAll(RegExp(r'\*\*|__'), '').trim(),
      model: model,
    );

/// How the mover stands, in words only: a model given "+5.6" quotes it
/// back. A mate is spelled out.
String standingPhrase({required double pawns, int? mateIn}) {
  if (mateIn != null) {
    if (mateIn == 0) return 'checkmate on the board';
    final moves = mateIn.abs() == 1 ? 'move' : 'moves';
    return mateIn > 0
        ? 'mating in ${mateIn.abs()} $moves'
        : 'being mated in ${mateIn.abs()} $moves';
  }
  final magnitude = pawns.abs();
  if (magnitude < 0.5) return 'level';
  if (magnitude < 1.5) return pawns > 0 ? 'slightly better' : 'slightly worse';
  if (magnitude < 3) return pawns > 0 ? 'clearly better' : 'clearly worse';
  if (magnitude < 6) return pawns > 0 ? 'winning' : 'losing';
  return pawns > 0 ? 'completely winning' : 'completely lost';
}

/// Plies of a line the model sees. Given ten, it recites ten; the move that
/// decides it is named separately (the material line).
const _promptPlies = 6;

/// [san] numbered from [startingPly] when the ply is known, bare otherwise,
/// cut to [_promptPlies].
String _line(List<String> san, int? startingPly) {
  final shown = san.take(_promptPlies).toList();
  return startingPly == null
      ? shown.join(' ')
      : formatLine(
          shown,
          startingPly: startingPly,
        ).replaceAll('. ', '.').replaceAll('… ', '...');
}

/// True when the mover is still in trouble after this move.
bool _stillWorseAfter(ExplanationContext ctx) =>
    ctx.mateInAfter != null ? ctx.mateInAfter! < 0 : ctx.evalAfterPawns < -1.5;

const _roleOrder = [Role.king, Role.queen, Role.rook, Role.bishop, Role.knight];

/// Every piece by colour and square ("White: Ke1 Qa3 …, pawns a2 c2"): a
/// FEN is easy to misread, and this says whose each piece is.
String _pieceList(String fen) {
  final board = Setup.parseFen(fen).board;
  String side(Side color) {
    final pieces = [
      for (final role in _roleOrder)
        for (final square in board.piecesOf(color, role).squares)
          '${role.uppercaseLetter}${square.name}',
    ];
    final pawns = [
      for (final square in board.piecesOf(color, Role.pawn).squares)
        square.name,
    ];
    return [
      pieces.join(' '),
      if (pawns.isNotEmpty) 'pawns ${pawns.join(' ')}',
    ].join(', ');
  }

  return 'White: ${side(Side.white)}. Black: ${side(Side.black)}.';
}

/// The user message for one move: what is true, then ONE closing "Write:"
/// line chosen by the verdict, asking only for what the facts can support.
String buildPrompt(ExplanationContext ctx) {
  // Never "you should have played the move you played".
  final betterMove = ctx.bestMoveSan == ctx.playedSan ? null : ctx.bestMoveSan;
  final mover = sideName(ctx.mover);
  final opponent = sideName(ctx.mover.opposite);
  final played = ctx.playedSan;
  final ply = ctx.plyBefore;
  final buffer = StringBuffer();

  buffer
    ..writeln(
      'Move: ${_line([played], ply)}, played by $mover. '
      'Verdict: ${ctx.classification.label}.',
    )
    ..writeln(
      '$mover was '
      '${standingPhrase(pawns: ctx.evalBeforePawns, mateIn: ctx.mateInBefore)} '
      'before it, and is '
      '${standingPhrase(pawns: ctx.evalAfterPawns, mateIn: ctx.mateInAfter)} '
      'after it.',
    );
  if (ctx.coachLine != null) {
    buffer.writeln('Already shown: "${ctx.coachLine}"');
  }
  buffer.writeln('Pieces before the move: ${_pieceList(ctx.fenBefore)}');

  // The facts are claimed TRUE, never complete.
  void facts(String about, List<String> list) {
    if (list.isEmpty) return;
    buffer.writeln('Facts about $about:');
    for (final fact in list) {
      buffer.writeln('- $fact');
    }
  }

  facts(played, ctx.facts);

  void reply(String label) {
    if (ctx.refutationLineSan.isEmpty) return;
    final after = ply == null ? null : ply + 1;
    buffer.writeln('$label: ${_line(ctx.refutationLineSan, after)}');
  }

  void better() {
    if (betterMove == null) return;
    buffer.writeln(
      ctx.bestLineSan.isEmpty
          ? 'Better was $betterMove.'
          : 'Better was $betterMove (line: ${_line(ctx.bestLineSan, ply)}).',
    );
    facts(betterMove, ctx.betterFacts);
  }

  if (ctx.openingName != null) {
    buffer
      ..writeln('This is opening theory: ${ctx.openingName}.')
      ..write('Write: what $played aims for in this opening. Do not judge it.');
    return buffer.toString();
  }

  switch (ctx.classification) {
    case Classification.brilliant || Classification.great:
      reply('Expected continuation');
      // What goes wrong otherwise, from the engine: asked without it, every
      // model invents the answer.
      if (ctx.runnerUpLineSan.isNotEmpty) {
        final standing = standingPhrase(
          pawns: ctx.runnerUpPawns ?? 0,
          mateIn: ctx.runnerUpMateIn,
        );
        buffer.writeln(
          'Next-best move: ${ctx.runnerUpLineSan.first} '
          '(line: ${_line(ctx.runnerUpLineSan, ply)}), '
          'after which $mover would be $standing.',
        );
      }
      buffer.write(
        ctx.classification == Classification.brilliant
            ? 'Write: what the material $played gives up buys.'
            : 'Write: what $played achieves that the next-best move does not.',
      );

    case Classification.best || Classification.excellent:
      reply('Expected continuation');
      buffer
        ..write(
          _stillWorseAfter(ctx)
              ? 'Write: what $played holds off — $mover is still in trouble. '
              : 'Write: what $played achieves. ',
        )
        ..write('If it is simply a sound move, say so in one sentence.');

    case Classification.good:
      better();
      buffer.write(
        betterMove == null
            ? 'Write: what $played does.'
            : 'Write: the one thing $betterMove adds over $played.',
      );

    case Classification.miss:
      // The point is the chance the opponent gave, not the move's own cost:
      // it did not lose, so it must not read as a blunder.
      final missed = betterMove == null ? null : describeLine(ctx.tags.missed);
      final previous = ctx.previousSan == null ? '' : ', ${ctx.previousSan},';
      buffer.writeln(
        "$opponent's last move$previous was a mistake, and $played let it go.",
      );
      better();
      if (missed != null) {
        buffer.writeln('Tactic $betterMove had: $mover $missed.');
      }
      buffer.write(
        'Write: what ${betterMove ?? 'the right move'} would have won or '
        'achieved. $played is not a blunder; the chance is what was missed.',
      );

    case Classification.inaccuracy ||
        Classification.mistake ||
        Classification.blunder:
      final story = materialStory(ctx.tags.ledger);
      final level = story == null || story == 'Material stays level.';
      final allowed = describeLine(ctx.tags.allowed);
      final missed = betterMove == null ? null : describeLine(ctx.tags.missed);
      final mateInvolved =
          (ctx.mateInAfter != null && ctx.mateInAfter! < 0) ||
          (ctx.mateInBefore != null && ctx.mateInBefore! > 0);

      // A QUIET slip: nothing is lost and no tactic is named, so the
      // engine's reason is positional and there is no fact for it. Asked
      // why the move is bad, a model invents one; asked what the better
      // move does, it can read that off its facts — or say it can't.
      // A Blunder with level material is still a blunder, and with no line
      // at all "nothing is lost" is unknown, not true.
      final quiet =
          level &&
          allowed == null &&
          missed == null &&
          !mateInvolved &&
          ctx.refutationLineSan.isNotEmpty &&
          ctx.classification != Classification.blunder;
      if (quiet) {
        better();
        buffer.write(
          'No material changes hands and no tactic was found, so the '
          'difference is positional and may not be visible from these facts. '
          'Write: what ${betterMove ?? 'the best move'} does that $played '
          'does not, only if the facts show it; otherwise say the reason is '
          'long-term. Do not claim $played loses or allows anything.',
        );
        return buffer.toString();
      }

      reply("$opponent's best answer");
      if (ctx.refutationLineSan.isNotEmpty) {
        // WHEN material changes, so a recapture is never read as a piece
        // given away — and when it never does, the model is told so, or it
        // invents a lost knight to explain the verdict.
        buffer.writeln(
          level
              ? 'Material stays level along it: the cost is in the position, '
                    'not a piece.'
              : 'Material along it: $story',
        );
      }
      // Named tactics, so "fork" is read, never guessed.
      if (allowed != null) {
        buffer.writeln('Tactic it allows: $opponent $allowed.');
      }
      if (ctx.startsEvenTrade) {
        buffer.writeln(
          '$played itself is an even trade; the damage comes after it.',
        );
      }
      better();
      if (missed != null) {
        buffer.writeln('Tactic $betterMove had: $mover $missed.');
      }
      buffer.write(
        'Write: what $played overlooks or leaves loose'
        '${betterMove == null ? '' : ', then in a few words what $betterMove does instead'}.',
      );
  }
  return buffer.toString();
}
