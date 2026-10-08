import 'package:dartchess/dartchess.dart';

import '../model/classification.dart';
import '../model/move_tags.dart';

/// Everything the LLM needs to explain one move, all computed in Dart
/// beforehand — the model only verbalizes.
class ExplanationContext {
  const ExplanationContext({
    required this.fenBefore,
    required this.playedSan,
    required this.mover,
    required this.classification,
    required this.evalBeforePawns,
    required this.evalAfterPawns,
    this.mateInBefore,
    this.mateInAfter,
    required this.bestMoveSan,
    required this.bestLineSan,
    required this.refutationLineSan,
    this.facts = const [],
    this.openingName,
    this.tags = MoveTags.none,
    this.startsEvenTrade = false,
    this.plyBefore,
    this.betterFacts = const [],
    this.previousSan,
    this.coachLine,
    this.runnerUpLineSan = const [],
    this.runnerUpPawns,
    this.runnerUpMateIn,
  });

  /// Position before the move was played.
  final String fenBefore;

  final String playedSan;
  final Side mover;
  final Classification classification;

  /// Pawns from the MOVER's perspective.
  final double evalBeforePawns;
  final double evalAfterPawns;

  /// Moves to mate from the MOVER's perspective (positive = the mover
  /// mates), so a mate is worded rather than shown as +/-99 pawns.
  final int? mateInBefore;
  final int? mateInAfter;

  /// The engine's move in SAN; null in a terminal position.
  final String? bestMoveSan;

  /// The engine's line from before the move, in SAN.
  final List<String> bestLineSan;

  /// The engine's line from the position AFTER the move — for a mistake,
  /// the refutation.
  final List<String> refutationLineSan;

  /// Board facts from `moveFacts`.
  final List<String> facts;

  /// Set while in book: theory is explained by its plan.
  final String? openingName;

  /// The tactics in the refutation and in the better line, computed — never
  /// left for the model to spot.
  final MoveTags tags;

  /// The move captured, and taking back on that square only evens it out.
  final bool startsEvenTrade;

  /// The opponent's move just before this one: the mistake a Miss let go.
  final String? previousSan;

  /// The app's own one-line verdict on the move (`coachLine`), from board
  /// code: the model expands on it and must not contradict it.
  final String? coachLine;

  /// Half-moves played before [fenBefore]'s position, so lines can be
  /// numbered ("16.dxe5 Nd5") — without numbers a model gives moves to the
  /// wrong side. Null leaves them bare.
  final int? plyBefore;

  /// Board facts about the engine's move, when it differs from the one
  /// played — so "what it does better" has something true to say.
  final List<String> betterFacts;

  /// The best move other than the engine's own, from before the move, in
  /// SAN: what "what goes wrong otherwise" is read from. Empty is unknown.
  final List<String> runnerUpLineSan;

  /// How the mover would stand after [runnerUpLineSan]'s first move, from
  /// the MOVER's perspective, as [evalBeforePawns] / [mateInBefore].
  final double? runnerUpPawns;
  final int? runnerUpMateIn;
}

/// One explained move: the model's answer, under the coach line.
class MoveExplanation {
  const MoveExplanation({required this.detail, this.model});

  final String detail;

  /// Which model wrote it, as the key editor names it: asking again after
  /// switching keys is how two models are compared. Null when unknown.
  final String? model;

  @override
  bool operator ==(Object other) =>
      other is MoveExplanation &&
      other.detail == detail &&
      other.model == model;

  @override
  int get hashCode => Object.hash(detail, model);

  @override
  String toString() => 'MoveExplanation($detail, by $model)';
}

/// Turns engine analysis into prose. Swappable.
abstract class MoveExplainer {
  Future<MoveExplanation> explainMove(ExplanationContext context);

  /// Releases the HTTP client (or model) this explainer holds.
  Future<void> dispose();
}
