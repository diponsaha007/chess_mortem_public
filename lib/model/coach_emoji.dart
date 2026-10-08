/// The face above the board at the moments board code is sure of: a
/// Brilliant, a mate delivered or allowed, a piece thrown away or won, a won
/// game drawn on the board. Never for a verdict alone (Great, Miss), which
/// the board cannot show.
///
/// Every emoji here is from Emoji 5.0 or older, so phones from Android 8.1
/// draw it rather than an empty box.
library;

import 'package:dartchess/dartchess.dart';

import 'coach_flavor.dart';

/// The face for [reaction], or null where there is none. The same move
/// always gets the same face; different moves get different ones.
String? reactionEmoji(CoachReaction reaction) {
  final group = _groupOf(reaction);
  if (group == null) return null;
  final faces = switch (reaction.voice) {
    CoachVoice.neutral => group.neutral,
    _ when reaction.cheers => group.good,
    _ => group.bad,
  };
  final seed = reaction.seed;
  return faces[seed == null ? 0 : pickIndex(seed, 'emoji', faces.length)];
}

/// Faces by whose news it is: good or bad for the reader, or no reader.
typedef _Faces = ({List<String> good, List<String> bad, List<String> neutral});

const _Faces _brilliant = (
  good: ['🤩', '🤯', '😮', '🔥', '💎', '✨'],
  bad: ['😮', '🤯', '😳', '👏', '🔥'],
  neutral: ['🤩', '🤯', '😮', '💎', '🔥'],
);

const _Faces _mated = (
  good: ['👑', '🏆', '🎉', '😎'],
  bad: ['💀', '😵', '😭'],
  neutral: ['👑', '🏆', '💀'],
);

const _Faces _mateAllowed = (
  good: ['😈', '👀', '🤭'],
  bad: ['😱', '💀', '🙀'],
  neutral: ['😱', '💀', '👀'],
);

const _Faces _pieceLost = (
  good: ['🤭', '😏', '👀', '🎁', '😈', '🙊'],
  bad: ['😰', '😱', '😬', '🤦', '😵', '🙈'],
  neutral: ['😱', '😬', '🙈', '👀', '🤦'],
);

const _Faces _pieceWon = (
  good: ['😎', '🤑', '💪', '🎯'],
  bad: ['😤', '😩', '🙄'],
  neutral: ['🎯', '💪', '👀'],
);

const _Faces _drawnWin = (
  good: ['😅', '😌', '🙏'],
  bad: ['😩', '😭', '🤦', '😫'],
  neutral: ['😬', '🤦', '😮'],
);

_Faces? _groupOf(CoachReaction reaction) => switch (reaction.moment) {
  Moment.brilliant => _brilliant,
  Moment.checkmate => _mated,
  Moment.allowedMate => _mateAllowed,
  Moment.hungPiece || Moment.lostPiece => _pieceLost,
  // A mate threat walked into names no piece.
  Moment.walkedIntoTactic when _isPiece(reaction.role) => _pieceLost,
  Moment.giftAccepted || Moment.tacticLanded => _pieceWon,
  Moment.drawnWin => _drawnWin,
  Moment.walkedIntoTactic || Moment.great || Moment.miss => null,
};

bool _isPiece(Role? role) =>
    role != null && role != Role.pawn && role != Role.king;
