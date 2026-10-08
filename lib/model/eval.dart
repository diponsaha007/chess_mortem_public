import 'dart:math';

import 'package:dartchess/dartchess.dart';

/// lichess's winning-chance sigmoid. Its input is ALWAYS ceiling-clamped
/// to ±1000 cp, and a mate IS ±1000, so a forced mate reads 97.55 %.
double winPctFromCp(int cpCeiled) =>
    50 + 50 * (2 / (1 + exp(-0.00368208 * cpCeiled)) - 1);

/// Anything carrying a White-perspective score: a whole [EngineEval] or one
/// of its runner-up [EngineLine]s.
abstract class Scored {
  const Scored();

  /// Centipawns clamped to +/-[EngineEval.cpCeiling], a mate mapped to the
  /// ceiling. White-perspective.
  int get cpCeiled;

  /// White's winning chances in percent (0-100).
  double get winPctWhite => winPctFromCp(cpCeiled);
}

int _ceiled(int? cp, int? mateIn) => mateIn != null
    ? (mateIn > 0 ? EngineEval.cpCeiling : -EngineEval.cpCeiling)
    : cp!.clamp(-EngineEval.cpCeiling, EngineEval.cpCeiling);

/// One runner-up move, White-perspective: the best of every move but the
/// engine's own.
class EngineLine extends Scored {
  const EngineLine({this.cp, this.mateIn, this.pvUci = const []})
    : assert(
        (cp == null) != (mateIn == null),
        'exactly one of cp / mateIn must be set',
      );

  final int? cp;
  final int? mateIn;

  /// The line, UCI moves; the first is the move this line is about.
  final List<String> pvUci;

  String? get moveUci => pvUci.isEmpty ? null : pvUci.first;

  /// A runner-up line never scores a finished position, so unlike
  /// [EngineEval] there is no checkmate case.
  @override
  int get cpCeiled => _ceiled(cp, mateIn);

  @override
  String toString() =>
      'EngineLine($moveUci, ${mateIn != null ? 'mate $mateIn' : 'cp $cp'})';
}

/// Engine evaluation of one position. ALWAYS White-perspective; the UCI
/// side-to-move score is flipped once, in `uci_parser.dart`.
class EngineEval extends Scored {
  const EngineEval({
    this.cp,
    this.mateIn,
    this.matedSide,
    required this.bestMoveUci,
    this.pvUci = const [],
    this.alternatives = const [],
    required this.depth,
  }) : assert(
         (cp == null) != (mateIn == null),
         'exactly one of cp / mateIn must be set',
       );

  /// A position that IS checkmate. UCI's `mate 0` has no sign to say who
  /// won, so the mated side is carried explicitly.
  const EngineEval.checkmate({
    required Side mated,
    this.bestMoveUci,
    required this.depth,
  }) : cp = null,
       mateIn = 0,
       matedSide = mated,
       pvUci = const [],
       alternatives = const [];

  /// lichess's `Cp.CEILING`: every score is clamped here, and a mate IS this.
  static const int cpCeiling = 1000;

  final int? cp;

  /// Moves until mate: positive = White mates. 0 = already mated, see
  /// [matedSide].
  final int? mateIn;

  /// The side standing checkmated when this position IS mate, else null.
  final Side? matedSide;

  bool get isCheckmate => matedSide != null;

  /// Null in a terminal position.
  final String? bestMoveUci;

  /// Principal variation, UCI.
  final List<String> pvUci;

  /// True when [pvUci] starts with [bestMoveUci]. A search cut short by
  /// `stop` can leave them disagreeing, and then the line is not used.
  bool get pvStartsWithBest => pvUci.isNotEmpty && pvUci.first == bestMoveUci;

  /// The runner-up moves from the same search, best first, all at the best
  /// line's depth. EMPTY MEANS UNKNOWN, not "nothing else was close".
  final List<EngineLine> alternatives;

  EngineLine? get secondBest =>
      alternatives.isEmpty ? null : alternatives.first;

  /// This eval with [line] as its runner-up, from the separate `searchmoves`
  /// search. A checkmate has no moves, so it is returned as is.
  EngineEval withRunnerUp(EngineLine line) => isCheckmate
      ? this
      : EngineEval(
          cp: cp,
          mateIn: mateIn,
          bestMoveUci: bestMoveUci,
          pvUci: pvUci,
          alternatives: List.unmodifiable([line]),
          depth: depth,
        );

  final int depth;

  /// Score in pawns, for display only; mates show as +/-99.
  double get pawns {
    if (matedSide != null) return matedSide == Side.white ? -99.0 : 99.0;
    if (mateIn != null) return mateIn! > 0 ? 99.0 : -99.0;
    return cp! / 100.0;
  }

  @override
  int get cpCeiled {
    // Checkmate first: mateIn is 0 there, which has no sign.
    if (matedSide != null) {
      return matedSide == Side.white ? -cpCeiling : cpCeiling;
    }
    return _ceiled(cp, mateIn);
  }

  @override
  String toString() {
    if (matedSide != null) return 'EngineEval(checkmate, $matedSide mated)';
    return mateIn != null
        ? 'EngineEval(mate $mateIn, best $bestMoveUci)'
        : 'EngineEval(cp $cp, best $bestMoveUci)';
  }
}
