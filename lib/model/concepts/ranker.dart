/// The learned half of salience: a linear score over a few features of each
/// candidate, the highest wins. The weights are fitted offline and live in
/// `salience_weights.dart` as a const; there is no ML runtime.
///
/// It only ranks what the detectors found, so it can never name something
/// that is not on the board. The hand-written priority table and the
/// engine-line tests are features, so the weights only correct them.
library;

import 'package:dartchess/dartchess.dart';

import '../classification.dart';
import '../material_balance.dart';
import 'concept.dart';
import 'detect_concepts.dart';
import 'salience.dart';

/// One candidate the ranker scores, with its named features.
class RankedCandidate {
  const RankedCandidate(this.concept, this.features);

  final Concept concept;
  final Map<String, double> features;

  double score(Map<String, double> weights) {
    var sum = 0.0;
    for (final MapEntry(:key, :value) in features.entries) {
      sum += (weights[key] ?? 0) * value;
    }
    return sum;
  }
}

/// The candidates in every frame the move can take ([frameOrder]'s first),
/// one per frame × kind (the object that best passes the line tests), plus
/// a generic line in each frame.
List<RankedCandidate> rankerCandidates(
  ConceptInput input,
  List<Concept> found,
) {
  final ordered = frameOrder(input, found);
  final frames = [
    ...ordered,
    for (final frame in Frame.values)
      if (!ordered.contains(frame) &&
          (frame != Frame.better || !input.isEngineMove))
        frame,
  ];
  final drop = ((input.winPctDrop ?? 0) / 20).clamp(0.0, 1.0);
  final group = _verdictGroup(input);
  final after = input.before.play(input.played);
  final landing = switch (input.played) {
    NormalMove(:final to) => to,
    _ => null,
  };

  // One representative per frame × kind: the one that touches the line,
  // then is worth most.
  final best = <(Frame, ConceptKind), (Concept, bool, int)>{};
  for (final c in found) {
    if (!frames.contains(c.frame)) continue;
    // A tactic the line does not cash in, or a loss the engine's own move
    // shares, is never said: the weights may rank, not overrule the tests.
    if (!passesLineTests(input, c, found)) continue;
    final touches = _touches(input, c);
    final value = _value(input, after, c);
    final key = (c.frame, c.kind);
    final held = best[key];
    if (held == null || _better((touches, value), (held.$2, held.$3))) {
      best[key] = (c, touches, value);
    }
  }
  for (final frame in frames) {
    if (frame == Frame.threatens) continue;
    best.putIfAbsent(
      (frame, ConceptKind.genericQuality),
      () => (
        Concept(ConceptKind.genericQuality, frame, evidence: 'generic'),
        false,
        0,
      ),
    );
  }

  final concrete = <Frame, int>{};
  for (final (c, _, _) in best.values) {
    if (c.kind != ConceptKind.genericQuality &&
        (priority[c.frame]?.contains(c.kind) ?? false)) {
      concrete[c.frame] = (concrete[c.frame] ?? 0) + 1;
    }
  }

  return [
    for (final (c, touches, value) in best.values)
      RankedCandidate(c, {
        'k:${c.frame.name}/${c.kind.id}': 1,
        'frame${frames.indexOf(c.frame)}': 1,
        '$group:frame${frames.indexOf(c.frame)}': 1,
        ..._tableFeatures(c),
        if (touches) 'touches:${c.frame.name}': 1,
        'value': value / 9,
        if (c.object != null && c.object == landing) 'moved': 1,
        '$group:${c.frame.name}/${c.kind.id}': 1,
        'drop:${c.frame.name}': drop,
        if (value > 0) 'value:${c.kind.id}': value / 9,
        if (_captured(input, c)) 'captured:${c.frame.name}': 1,
        if (c.kind == ConceptKind.genericQuality) ...{
          'generic:concrete': (concrete[c.frame] ?? 0) / 5,
          'generic:${input.phase.name}': 1,
        },
      }),
  ];
}

/// The candidate [weights] score highest; ties go to the earlier one.
Concept chooseRanked(
  ConceptInput input,
  List<Concept> found,
  Map<String, double> weights,
) => rankConcepts(input, found, weights).first;

/// Every candidate, highest score first; ties keep their order.
List<Concept> rankConcepts(
  ConceptInput input,
  List<Concept> found,
  Map<String, double> weights,
) {
  final scored = [
    for (final candidate in rankerCandidates(input, found))
      (candidate.concept, candidate.score(weights)),
  ];
  // List.sort is not stable: the index breaks ties.
  final order = [for (var i = 0; i < scored.length; i++) i]
    ..sort((a, b) {
      final by = scored[b].$2.compareTo(scored[a].$2);
      return by != 0 ? by : a.compareTo(b);
    });
  return [for (final i in order) scored[i].$1];
}

String _verdictGroup(ConceptInput input) {
  if (input.openingName != null) return 'book';
  return switch (input.verdict) {
    Classification.brilliant || Classification.great => 'great',
    Classification.inaccuracy => 'inaccuracy',
    Classification.mistake || Classification.blunder => 'mistake',
    Classification.miss => 'miss',
    _ => 'good',
  };
}

/// The hand table's rank as a prior: 1 at the top of the frame's table,
/// falling to 0 at its end; `offTable` when the table leaves it out.
Map<String, double> _tableFeatures(Concept c) {
  if (c.kind == ConceptKind.genericQuality) return const {};
  final table = priority[c.frame];
  final index = table?.indexOf(c.kind) ?? -1;
  if (index < 0) return const {'offTable': 1};
  return {'table': 1 - index / table!.length};
}

bool _better((bool, int) a, (bool, int) b) {
  if (a.$1 != b.$1) return a.$1;
  return a.$2 > b.$2;
}

/// Whether the frame's engine line touches the concept's piece.
bool _touches(ConceptInput input, Concept c) {
  final object = c.object;
  if (object == null) return false;
  return switch (c.frame) {
    Frame.allows => lineTouches(
      input.before.play(input.played),
      input.replyUci,
      object,
    ),
    Frame.better => lineTouches(input.before, input.betterUci, object),
    _ => false,
  };
}

/// Whether the frame's line captures the concept's piece in its first four
/// moves: the piece that is actually won or lost.
bool _captured(ConceptInput input, Concept c) {
  final object = c.object;
  if (object == null) return false;
  return switch (c.frame) {
    Frame.allows => lineTakes(
      input.before.play(input.played),
      input.replyUci,
      object,
    ),
    Frame.better => lineTakes(input.before, input.betterUci, object),
    Frame.does || Frame.threatens => lineTakes(
      input.before.play(input.played),
      input.replyUci,
      object,
      plies: 3,
    ),
  };
}

/// The value of the piece the concept is about, where it stands.
int _value(ConceptInput input, Position after, Concept c) {
  final object = c.object;
  if (object == null) return 0;
  final board = c.frame == Frame.better ? input.before.board : after.board;
  final piece = board.pieceAt(object) ?? input.before.board.pieceAt(object);
  return piece == null ? 0 : valueOf(piece.role);
}
