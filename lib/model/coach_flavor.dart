/// The playful layer over a coach line: a cheeky reaction at the moments a
/// player remembers (a piece hung, a mate, a Brilliant), and nothing at
/// all on a quiet or generic line.
///
/// A reaction adds feeling, never a fact: it either wraps the plain
/// sentence unchanged or rebuilds it from the same slots (the piece, the
/// side, the better move's SAN). It teases the move, never the player, and
/// names no site or person.
library;

import 'package:dartchess/dartchess.dart';

import 'classification.dart';
import 'concepts/concept.dart';
import 'opening_key.dart' show fnv1a63;

/// Whose move the line is about, as the reader sees it.
enum CoachVoice {
  /// The user moved.
  you,

  /// The user's opponent moved.
  opponent,

  /// No user is known: sides are "White" and "Black".
  neutral,
}

/// A moment worth a reaction. Only a concrete event counts; the verdict
/// alone is enough for Brilliant and Great, which are events themselves.
enum Moment {
  checkmate,
  brilliant,
  great,
  allowedMate,
  hungPiece,
  lostPiece,
  walkedIntoTactic,
  miss,
  giftAccepted,
  tacticLanded,

  /// A won game drawn on the board: stalemate, repetition, too little
  /// material left.
  drawnWin,
}

/// The moment the line for [kind] in [frame] is about, or null for a line
/// that stays plain. [role] is the piece the line names (null when it names
/// none), [betterSan] the better move it names, [mated] whether the move
/// left the opponent checkmated, [threwWin] whether it drew a won game on
/// the board, and [gift] whether the piece it takes is
/// the one the opponent just moved, with a mistake.
Moment? momentFor({
  required ConceptKind kind,
  required Frame frame,
  required Classification? verdict,
  required Role? role,
  required String? betterSan,
  required bool mated,
  bool threwWin = false,
  bool gift = false,
}) {
  if (kind == ConceptKind.openingName) return null;
  if (mated && frame == Frame.does) return Moment.checkmate;
  if (threwWin) return Moment.drawnWin;
  if (verdict == Classification.brilliant) return Moment.brilliant;
  if (verdict == Classification.great) return Moment.great;
  if (kind == ConceptKind.missedWin) {
    return betterSan == null ? null : Moment.miss;
  }
  final slip = verdict != null && verdict.isMistakeOrWorse;
  final piece = role != null && role != Role.pawn && role != Role.king;
  if (frame == Frame.allows && slip) {
    switch (kind) {
      case ConceptKind.checkmate || ConceptKind.backRankMate:
        return Moment.allowedMate;
      case ConceptKind.hangingPiece when piece:
        return Moment.hungPiece;
      case ConceptKind.winMaterial || ConceptKind.trappedPiece when piece:
        return Moment.lostPiece;
      case ConceptKind.fork ||
              ConceptKind.skewer ||
              ConceptKind.pin ||
              ConceptKind.discoveredAttack ||
              ConceptKind.discoveredCheck
          when piece:
        return Moment.walkedIntoTactic;
      case ConceptKind.mateThreat:
        return Moment.walkedIntoTactic;
      default:
        return null;
    }
  }
  // A piece the opponent just put where it is taken for nothing.
  final taken =
      kind == ConceptKind.captureFree || kind == ConceptKind.winMaterial;
  final sound =
      verdict == Classification.best ||
      verdict == Classification.excellent ||
      verdict == Classification.good;
  if (frame == Frame.does && gift && taken && piece && sound) {
    return Moment.giftAccepted;
  }
  final good =
      verdict == Classification.best || verdict == Classification.excellent;
  final big = role == Role.queen || role == Role.rook;
  if (frame == Frame.does && good && big) {
    switch (kind) {
      case ConceptKind.fork || ConceptKind.skewer || ConceptKind.captureFree:
        return Moment.tacticLanded;
      default:
        return null;
    }
  }
  return null;
}

/// The moment a move's line reacts to, in whose voice: what the haptic buzz
/// reads.
class CoachReaction {
  const CoachReaction(this.moment, this.voice, {this.role, this.seed});

  final Moment moment;
  final CoachVoice voice;

  /// The piece the line is about, when it names one.
  final Role? role;

  /// The move's seed, so anything picked for it is picked the same way every
  /// time; null picks the first.
  final int? seed;

  /// Whether this is good news for the reader: the user's own big moment,
  /// or the opponent's slip. With no user known, it is read for the mover.
  bool get cheers {
    final goodForMover = switch (moment) {
      Moment.checkmate ||
      Moment.brilliant ||
      Moment.great ||
      Moment.giftAccepted ||
      Moment.tacticLanded => true,
      Moment.allowedMate ||
      Moment.hungPiece ||
      Moment.lostPiece ||
      Moment.walkedIntoTactic ||
      Moment.miss ||
      Moment.drawnWin => false,
    };
    return voice == CoachVoice.opponent ? !goodForMover : goodForMover;
  }

  @override
  bool operator ==(Object other) =>
      other is CoachReaction && other.moment == moment && other.voice == voice;

  @override
  int get hashCode => Object.hash(moment, voice);

  @override
  String toString() => 'CoachReaction(${moment.name}, ${voice.name})';
}

/// What a reaction may use besides the plain line.
class FlavorSlots {
  const FlavorSlots({
    required this.voice,
    required this.side,
    this.piece,
    this.betterSan,
  });

  final CoachVoice voice;

  /// The mover: "White" or "Black".
  final String side;

  /// "the queen on d5", when the line names a piece.
  final String? piece;

  /// The better move's SAN, when the line names one.
  final String? betterSan;
}

/// The longest line the coach bar shows whole, verdict and move hints
/// beside it (three lines on a phone).
const maxFlavoredLength = 90;

/// [plain] with a reaction for [moment], picked by [seed]. A reaction that
/// needs a slot it lacks, or runs past [maxFlavoredLength], is skipped; with
/// none left the plain line stands.
String flavor(String plain, Moment moment, FlavorSlots slots, int seed) {
  final pool = flavorBank[moment]![slots.voice]!;
  final start = pickIndex(seed, 'flavor ${moment.name}', pool.length);
  for (var i = 0; i < pool.length; i++) {
    final line = renderFlavor(pool[(start + i) % pool.length], plain, slots);
    if (line != null && line.length <= maxFlavoredLength) return line;
  }
  return plain;
}

/// [template] filled in, or null when it needs a slot [slots] lacks.
/// `{plain}` is the plain line, `{P}` the piece, `{W}` the mover's side and
/// `{B}` the better move.
String? renderFlavor(String template, String plain, FlavorSlots slots) {
  final piece = slots.piece;
  final better = slots.betterSan;
  if (template.contains('{P}') && piece == null) return null;
  if (template.contains('{B}') && better == null) return null;
  final text = template
      .replaceAll('{plain}', plain)
      .replaceAll('{P}', piece ?? '')
      .replaceAll('{W}', slots.side)
      .replaceAll('{B}', better ?? '');
  // Only a leading piece needs it: the plain line, the side and the
  // templates arrive capitalised, and SAN keeps its own case.
  return template.startsWith('{P}')
      ? text[0].toUpperCase() + text.substring(1)
      : text;
}

/// A stable index into a list of [length], from [seed]; [salt] keeps two
/// lists picked from one seed from moving in step.
int pickIndex(int seed, String salt, int length) =>
    fnv1a63('$salt $seed') % length;

/// The reactions, by moment and voice. `{plain}` keeps the plain sentence
/// whole, so its rules ("later in the line", what a sacrifice buys) are
/// never paraphrased away; only the simplest lines are rebuilt.
const Map<Moment, Map<CoachVoice, List<String>>> flavorBank = {
  Moment.checkmate: {
    CoachVoice.you: [
      'Checkmate. Absolute cinema.',
      'Checkmate. Drop the mic.',
      "Checkmate. Shake hands, it's over.",
      "Checkmate. That's how it's done.",
    ],
    CoachVoice.opponent: [
      'Checkmate. Well, that happened.',
      'Checkmate. Right in the king.',
      'Checkmate. Rematch?',
      'Checkmate. Shake it off.',
    ],
    CoachVoice.neutral: [
      'Checkmate. Curtains.',
      'Checkmate. Game over.',
      'Checkmate. Lights out.',
    ],
  },
  Moment.brilliant: {
    CoachVoice.you: [
      '{plain} Absolute cinema.',
      '{plain} Take a bow.',
      'Galaxy brain. {plain}',
      '{plain} Frame this one.',
      '{plain} Main-character energy.',
    ],
    CoachVoice.opponent: [
      '{plain} Rude, but brilliant.',
      '{plain} Annoyingly good.',
      '{plain} Okay, that was nice.',
      '{plain} Respect.',
    ],
    CoachVoice.neutral: [
      '{plain} What a shot.',
      '{plain} Pure art.',
      'Galaxy brain. {plain}',
    ],
  },
  Moment.great: {
    CoachVoice.you: [
      'Clutch. {plain}',
      'Ice in the veins. {plain}',
      'Nerves of steel. {plain}',
      'Found it. {plain}',
      'Cold-blooded. {plain}',
      'No panic. {plain}',
    ],
    CoachVoice.opponent: [
      'Annoyingly accurate. {plain}',
      'They found it. {plain}',
      'Not bad, not bad. {plain}',
    ],
    CoachVoice.neutral: [
      'Clutch. {plain}',
      'Found it. {plain}',
      'Nerves of steel. {plain}',
    ],
  },
  Moment.allowedMate: {
    CoachVoice.you: [
      'Mayday. {plain}',
      '{plain} Say goodbye to your king.',
      'Houston, we have a problem. {plain}',
      '{plain} Pack it up.',
    ],
    CoachVoice.opponent: [
      'Smell that? {plain}',
      'Go for the kill. {plain}',
      'Your opponent left the door wide open. {plain}',
      '{plain} Finish it.',
    ],
    CoachVoice.neutral: [
      'Mayday. {plain}',
      '{plain} Curtains.',
      'The door is wide open. {plain}',
    ],
  },
  Moment.hungPiece: {
    CoachVoice.you: [
      'You hung {P}. It has left the chat.',
      '{P}, just hanging there. Your opponent says thanks.',
      'You hung {P}. Just… why?',
      '{P} was hanging, and not in a cool way.',
      'You gift-wrapped {P}. Ouch.',
    ],
    CoachVoice.opponent: [
      'Your opponent hung {P}. Christmas came early.',
      'Your opponent just gift-wrapped {P}.',
      'Your opponent dropped {P}. LOL.',
      '{P} is hanging. Your opponent is feeling generous.',
      "Your opponent hung {P}. Don't ask questions, just take it.",
    ],
    CoachVoice.neutral: [
      '{W} hung {P}. Ouch.',
      '{W} just gift-wrapped {P}.',
      "{P} is hanging. Someone's feeling generous.",
    ],
  },
  Moment.lostPiece: {
    CoachVoice.you: [
      'Oof. {plain}',
      'Yikes. {plain}',
      '{plain} Pain.',
      'Big oof. {plain}',
    ],
    CoachVoice.opponent: [
      'Ooh, a gift. {plain}',
      'Thanks for that. {plain}',
      '{plain} LOL.',
      'Opportunity knocks. {plain}',
    ],
    CoachVoice.neutral: ['Yikes. {plain}', 'Oof. {plain}', '{plain} Pain.'],
  },
  Moment.walkedIntoTactic: {
    CoachVoice.you: [
      'Walked right into it. {plain}',
      'Uh-oh. {plain}',
      "{plain} Didn't see that coming, did you?",
      'Plot twist: {plain}',
    ],
    CoachVoice.opponent: [
      'Your opponent walked into it. {plain}',
      'Ooh, juicy. {plain}',
      "{plain} Don't miss it.",
      'Look closer. {plain}',
    ],
    CoachVoice.neutral: [
      'Uh-oh. {plain}',
      'Walked right into it. {plain}',
      'Plot twist: {plain}',
    ],
  },
  Moment.miss: {
    CoachVoice.you: [
      "Your opponent slipped and you said 'no thanks'. {B} would have punished it.",
      'Gift refused. {B} would have cashed in.',
      'You walked right past the open door. {B} would have punished it.',
      'So close. {B} would have cashed in.',
    ],
    CoachVoice.opponent: [
      'Your opponent let you off the hook; {B} would have punished it.',
      'Dodged a bullet: your opponent missed {B}.',
      'Phew. Your opponent missed {B}.',
    ],
    CoachVoice.neutral: [
      '{W} let it slide; {B} would have punished it.',
      'Gift refused: {B} would have cashed in.',
      '{W} walked right past it. {B} would have cashed in.',
    ],
  },
  Moment.giftAccepted: {
    CoachVoice.you: [
      'Gift accepted. {plain}',
      'Yes, please. {plain}',
      'Thank you very much. {plain}',
    ],
    CoachVoice.opponent: [
      'Your opponent says thanks. {plain}',
      'Well, that was generous. {plain}',
      'Special delivery. {plain}',
    ],
    CoachVoice.neutral: [
      'Gift accepted. {plain}',
      'Thanks very much. {plain}',
      'Special delivery. {plain}',
    ],
  },
  Moment.tacticLanded: {
    CoachVoice.you: [
      '{plain} Juicy.',
      "{plain} Chef's kiss.",
      '{plain} Delicious.',
    ],
    CoachVoice.opponent: [
      '{plain} Sneaky.',
      '{plain} Ouch.',
      'Heads up. {plain}',
    ],
    CoachVoice.neutral: ['{plain} Juicy.', '{plain} Sneaky.', '{plain} Nice.'],
  },
  Moment.drawnWin: {
    CoachVoice.you: [
      'Noooo. {plain}',
      'Heartbreak. {plain}',
      '{plain} So close.',
      '{plain} Pain.',
    ],
    CoachVoice.opponent: [
      'Phew. {plain}',
      'Saved by the bell. {plain}',
      '{plain} Lucky escape.',
      'Houdini would be proud. {plain}',
    ],
    CoachVoice.neutral: [
      'Heartbreak. {plain}',
      'Oof. {plain}',
      '{plain} So close.',
    ],
  },
};
