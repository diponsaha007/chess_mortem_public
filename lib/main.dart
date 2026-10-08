import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:multistockfish/multistockfish.dart';

import 'analysis/analysis_session.dart';
import 'analysis/analysis_store.dart';
import 'appearance/appearance_controller.dart';
import 'appearance/board_appearance.dart';
import 'engine/nnue_assets.dart';
import 'engine/stockfish_engine.dart';
import 'feedback/move_sounds.dart';
import 'llm/llm_config.dart';
import 'llm/llm_config_store.dart';
import 'logging/crash_guard.dart';
import 'model/game_library.dart';
import 'model/opening_book.dart';
import 'platform/incoming_pgn.dart';
import 'screens/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installCrashGuard();

  _registerLicenses();
  final configStore = LlmConfigStore();
  final book = await _loadOpeningBook();
  final config = await _loadConfig(configStore);

  final analysisStore = AnalysisStore();
  final session = AnalysisSession(
    engine: await _buildEngine(config),
    book: book,
    searchDepth: config.engineDepth,
    ranksAlternatives: config.ranksAlternatives,
    playerName: config.playerName,
    store: analysisStore,
  );
  final library = GameLibrary();
  await _loadLibrary(library);
  // Analyses of games deleted in an earlier run. Not awaited: housekeeping.
  unawaited(analysisStore.prune({for (final game in library.games) game.id}));
  final appearance = AppearanceController();
  await appearance.load();
  final sounds = MoveSounds(player: AudioSoundPlayer());
  await sounds.load();

  runApp(
    ChessMortemApp(
      session: session,
      configStore: configStore,
      library: library,
      appearance: appearance,
      sounds: sounds,
    ),
  );
}

/// The engine the user chose, or the bundled one when the newer engine's
/// nets are not on disk.
Future<StockfishEngine> _buildEngine(LlmConfig config) async {
  if (!config.useLatestEngine) return StockfishEngine();
  final nets = NnueAssets();
  try {
    if (!await nets.isReady) return StockfishEngine();
    return StockfishEngine(
      flavor: StockfishFlavor.latestNoNNUE,
      bigNetPath: await nets.bigNetPath,
      smallNetPath: await nets.smallNetPath,
    );
  } catch (_) {
    return StockfishEngine();
  } finally {
    nets.dispose();
  }
}

/// The copyleft engine the app is built on, for the licences page: its
/// source has to be offered with the app. The code the scoring and tactic
/// names are ported from, the opening data, the board artwork (each piece
/// set under its own licence) and the move sounds are credited beside it.
void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Stockfish'],
      'GNU General Public License v3.0\n'
      'https://github.com/official-stockfish/Stockfish',
    );
    yield const LicenseEntryWithLineBreaks(
      ['scalachess (game phases, winning chances)'],
      'Copyright (c) 2012-2014 Thibault Duplessis\n'
      '\n'
      'The MIT license\n'
      '\n'
      'Permission is hereby granted, free of charge, to any person obtaining '
      'a copy of this software and associated documentation files (the '
      '"Software"), to deal in the Software without restriction, including '
      'without limitation the rights to use, copy, modify, merge, publish, '
      'distribute, sublicense, and/or sell copies of the Software, and to '
      'permit persons to whom the Software is furnished to do so, subject to '
      'the following conditions:\n'
      '\n'
      'The above copyright notice and this permission notice shall be '
      'included in all copies or substantial portions of the Software.\n'
      '\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS '
      'OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF '
      'MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. '
      'IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY '
      'CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, '
      'TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE '
      'SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['lila (accuracy, move verdicts)'],
      'The lila authors\n'
      'GNU Affero General Public License v3.0 or later',
    );
    yield const LicenseEntryWithLineBreaks(
      ['lichess-puzzler (tactic names)'],
      'The lichess-puzzler authors\n'
      'GNU Affero General Public License v3.0',
    );
    yield const LicenseEntryWithLineBreaks([
      'chess-openings (opening names)',
    ], 'Creative Commons Zero (CC0)');
    yield const LicenseEntryWithLineBreaks(
      ['Board themes'],
      'The lila authors and pirouetti\n'
      'GNU Affero General Public License v3.0 or later',
    );
    for (final style in PieceStyle.values) {
      yield LicenseEntryWithLineBreaks([
        'Piece set: ${style.label}',
      ], '${style.author}\n${style.licence}');
    }
    yield const LicenseEntryWithLineBreaks(
      ['Move sounds'],
      'Impact Sounds by Kenney (www.kenney.nl)\n'
      'Creative Commons Zero (CC0)',
    );
  });
}

/// The opening book, or an empty one if the asset is unreadable.
Future<OpeningBook> _loadOpeningBook() async {
  try {
    final data = await rootBundle.load(OpeningBook.assetPath);
    return OpeningBook.decode(data.buffer.asUint8List());
  } catch (_) {
    return const OpeningBook.empty();
  }
}

/// The defaults when secure storage fails, e.g. no keystore.
Future<LlmConfig> _loadConfig(LlmConfigStore store) async {
  try {
    return await store.load();
  } catch (_) {
    return LlmConfig();
  }
}

/// Reads the saved games, seeding the bundled sample on a first run.
Future<void> _loadLibrary(GameLibrary library) async {
  String? sample;
  try {
    sample = await rootBundle.loadString('assets/game.pgn');
  } catch (_) {}
  try {
    await library.load(sampleWhenEmpty: sample);
  } catch (_) {} // unreadable storage: an empty library
}

class ChessMortemApp extends StatelessWidget {
  const ChessMortemApp({
    super.key,
    required this.session,
    required this.configStore,
    required this.library,
    required this.appearance,
    required this.sounds,
  });

  final AnalysisSession session;
  final LlmConfigStore configStore;
  final GameLibrary library;
  final AppearanceController appearance;
  final MoveSounds sounds;

  @override
  Widget build(BuildContext context) {
    // Above the MaterialApp, so the pushed board and Settings see it too.
    return AppearanceScope(
      controller: appearance,
      child: MoveSoundsScope(
        sounds: sounds,
        child: MaterialApp(
          title: 'Chess Mortem',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
          ),
          home: LibraryScreen(
            session: session,
            configStore: configStore,
            library: library,
            incoming: IncomingPgn(),
          ),
        ),
      ),
    );
  }
}
