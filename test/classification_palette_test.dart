import 'dart:math' as math;

import 'package:chess_mortem/model/classification.dart';
import 'package:chess_mortem/widgets/move_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The contract behind [classificationColor]: each colour
/// is both a badge disc under dark [classificationInk] and a verdict word on
/// the dark surface.
void main() {
  // The app's Material 3 dark surface (ColorScheme.fromSeed, teal, dark).
  const surface = Color(0xFF0E1513);
  const primary = Color(0xFF82D5C8);

  group('classification palette', () {
    test('every verdict reads as text on the dark surface', () {
      for (final c in Classification.values) {
        expect(
          _contrast(classificationColor(c), surface),
          greaterThanOrEqualTo(4.5),
          reason:
              'the coach bar prints ${c.name} in this colour on the surface, '
              'and the badge has to lift off the page',
        );
      }
    });

    test('every symbol is readable on its own disc', () {
      for (final c in Classification.values) {
        expect(
          _contrast(classificationColor(c), classificationInk),
          greaterThanOrEqualTo(4.5),
          reason: 'the ${c.name} symbol sits on this colour',
        );
      }
    });

    test('no verdict reads as the app\'s primary colour', () {
      // Perceptual distance, not contrast: same-lightness colours pass a
      // contrast test while looking alike.
      for (final c in Classification.values) {
        expect(
          _deltaE(classificationColor(c), primary),
          greaterThanOrEqualTo(10),
          reason: '${c.name} is too close to the primary colour',
        );
      }
    });

    test('neighbouring verdicts are told apart at a glance', () {
      // Adjacent tiers are the ones actually confusable — nobody mistakes a
      // Brilliant for a Blunder.
      for (var i = 0; i < Classification.values.length - 1; i++) {
        final a = Classification.values[i];
        final b = Classification.values[i + 1];
        expect(
          _deltaE(classificationColor(a), classificationColor(b)),
          greaterThanOrEqualTo(8),
          reason: '${a.name} and ${b.name} sit next to each other',
        );
      }
    });

    test('the two verdicts sharing a tick are clearly different greens', () {
      // Excellent and Good deliberately share one symbol, so
      // the colour is the ONLY thing telling them apart.
      expect(
        _deltaE(
          classificationColor(Classification.excellent),
          classificationColor(Classification.good),
        ),
        greaterThanOrEqualTo(8),
      );
    });

    test('a good move never looks like a bad one, in any vision', () {
      // THE boundary. Everything above Inaccuracy is a move you played well
      // and everything below it is one that cost you something, and that is
      // the whole message a badge carries at a glance. Confusing Brilliant
      // with Best only mixes up two kinds of praise; confusing Good with
      // Blunder is the app lying to you.
      //
      // Deliberately not asserted for every cross-family pair: a red-green
      // deficiency collapses the hue axis these all live on, so demanding it
      // everywhere forces the muddy, near-black palette that came before —
      // and the symbols (?! ? ?? against ★ ✓ ! !!) already separate the rest.
      const wasFine = [
        Classification.brilliant,
        Classification.great,
        Classification.best,
        Classification.excellent,
        Classification.good,
      ];
      const costYou = [
        Classification.inaccuracy,
        Classification.mistake,
        Classification.blunder,
        Classification.miss,
      ];
      for (final a in wasFine) {
        for (final b in costYou) {
          for (final vision in _Vision.values) {
            expect(
              _deltaE(
                vision.apply(classificationColor(a)),
                vision.apply(classificationColor(b)),
              ),
              greaterThanOrEqualTo(10),
              reason:
                  '${a.name} must never be mistaken for ${b.name} in '
                  '${vision.name} vision',
            );
          }
        }
      }
    });

    test('every verdict has its own colour', () {
      final seen = <int>{};
      for (final c in Classification.values) {
        expect(
          seen.add(classificationColor(c).toARGB32()),
          isTrue,
          reason: '${c.name} repeats another verdict\'s colour',
        );
      }
    });
  });
}

double _channel(int v) {
  final c = v / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4) as double;
}

double _luminance(Color c) =>
    0.2126 * _channel((c.r * 255).round()) +
    0.7152 * _channel((c.g * 255).round()) +
    0.0722 * _channel((c.b * 255).round());

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Perceptual distance in OKLab, scaled by 100 so the numbers read like the
/// familiar dE figures.
double _deltaE(Color x, Color y) {
  final a = _oklab(x);
  final b = _oklab(y);
  return 100 *
      math.sqrt(
        math.pow(a[0] - b[0], 2) +
            math.pow(a[1] - b[1], 2) +
            math.pow(a[2] - b[2], 2),
      );
}

List<double> _oklab(Color c) {
  final r = _channel((c.r * 255).round());
  final g = _channel((c.g * 255).round());
  final b = _channel((c.b * 255).round());
  final l =
      math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
          as double;
  final m =
      math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
          as double;
  final s =
      math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)
          as double;
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

/// Normal vision plus the two common red-green deficiencies, as the usual
/// linear approximations. Enough to catch a palette that only works for
/// people who see every channel.
enum _Vision {
  normal,
  deuteranope,
  protanope;

  Color apply(Color c) {
    if (this == _Vision.normal) return c;
    final r = _channel((c.r * 255).round());
    final g = _channel((c.g * 255).round());
    final b = _channel((c.b * 255).round());
    final m = this == _Vision.deuteranope
        ? const [
            [0.625, 0.375, 0.0],
            [0.7, 0.3, 0.0],
            [0.0, 0.3, 0.7],
          ]
        : const [
            [0.567, 0.433, 0.0],
            [0.558, 0.442, 0.0],
            [0.0, 0.242, 0.758],
          ];
    int out(List<double> row) {
      final v = row[0] * r + row[1] * g + row[2] * b;
      final clamped = v.clamp(0.0, 1.0);
      final encoded = clamped <= 0.0031308
          ? 12.92 * clamped
          : 1.055 * math.pow(clamped, 1 / 2.4) - 0.055;
      return (encoded * 255).round().clamp(0, 255);
    }

    return Color.fromARGB(255, out(m[0]), out(m[1]), out(m[2]));
  }
}
