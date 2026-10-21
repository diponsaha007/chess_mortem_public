import 'dart:io';

import 'package:chess_mortem/appearance/appearance_controller.dart';
import 'package:chess_mortem/appearance/board_appearance.dart';
import 'package:chess_mortem/engine/nnue_assets.dart';
import 'package:chess_mortem/engine/uci_options.dart';
import 'package:chess_mortem/feedback/move_sounds.dart';
import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/llm_config_store.dart';
import 'package:chess_mortem/platform/share_game.dart';
import 'package:chess_mortem/screens/settings_screen.dart';
import 'package:chess_mortem/widgets/appearance_picker.dart';
import 'package:chess_mortem/widgets/key_help.dart';
import 'package:chessground/chessground.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_secure_storage.dart';

/// Nets without a filesystem or network: real file I/O does not progress in
/// a widget test's fake-async zone (nnue_assets_test.dart covers the I/O).
class _FakeNets extends NnueAssets {
  _FakeNets({this.ready = false, this.fails = false});

  bool ready;
  final bool fails;

  @override
  Future<bool> get isReady async => ready;

  @override
  Future<void> download({void Function(double)? onProgress}) async {
    if (fails) throw const HttpException('the net server said no');
    onProgress?.call(1);
    ready = true;
  }

  @override
  Future<void> delete() async => ready = false;
}

void main() {
  Future<LlmConfigStore> pumpSettings(
    WidgetTester tester, {
    Map<String, String>? stored,
    NnueAssets? nets,
    String? running = bundledEngineName,
    ValueChanged<int>? onDepth,
    ValueChanged<bool>? onRanksAlternatives,
    LinkLauncher? launchLink,
    LinkLauncher? launchPage,
    GameSharer? sharer,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = LlmConfigStore(FakeSecureStorage(stored));
    await tester.pumpWidget(
      MaterialApp(
        // Pushed onto a Navigator the way the board screen pushes it, so the
        // dialogs it opens have a route to sit over.
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(
              configStore: store,
              nnueAssets: nets ?? _FakeNets(),
              runningEngineName: running,
              onEngineDepthChanged: onDepth,
              onRanksAlternativesChanged: onRanksAlternatives,
              launchLink: launchLink ?? (_) async => true,
              launchPage: launchPage ?? (_) async => true,
              sharer: sharer ?? _FakeSharer(hasSheet: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('picking a board and pieces changes the preview at once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final appearance = AppearanceController();

    await tester.pumpWidget(
      AppearanceScope(
        controller: appearance,
        child: MaterialApp(
          home: SettingsScreen(
            configStore: LlmConfigStore(FakeSecureStorage()),
            nnueAssets: _FakeNets(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    StaticChessboardSettings preview() => tester
        .widget<StaticChessboard>(find.byKey(appearancePreviewKey))
        .settings;
    expect(preview().colorScheme, ChessboardColorScheme.brown);

    await tester.tap(find.byKey(boardThemeSwatchKey(BoardTheme.green)));
    await tester.tap(find.byKey(pieceStyleSwatchKey(PieceStyle.merida)));
    await tester.pumpAndSettle();

    expect(appearance.appearance.boardTheme, BoardTheme.green);
    expect(appearance.appearance.pieceStyle, PieceStyle.merida);
    expect(preview().colorScheme, ChessboardColorScheme.green);
    expect(preview().pieceAssets, PieceSet.meridaAssets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the move sounds switch turns the sounds off', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final sounds = MoveSounds();
    await sounds.load();

    await tester.pumpWidget(
      MoveSoundsScope(
        sounds: sounds,
        child: MaterialApp(
          home: SettingsScreen(
            configStore: LlmConfigStore(FakeSecureStorage()),
            nnueAssets: _FakeNets(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(moveSoundsSwitchKey);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(sounds.enabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  /// Scrolls to the bottom of the settings list.
  ///
  /// The list is longer than a phone screen and lazily built, so a control
  /// near its end is neither hittable NOR findable until it has been scrolled
  /// to. `scrollUntilVisible` stops as soon as the widget exists, which can
  /// still leave it half off the bottom edge — hence the `ensureVisible`.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(target, 100);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> addKey(
    WidgetTester tester, {
    required String name,
    required String apiKey,
    required String provider,
  }) async {
    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), name);
    await tester.tap(find.byType(DropdownButtonFormField<LlmProvider>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(provider).last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API key'),
      apiKey,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  testWidgets('the licences page opens from About', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(find.byKey(licencesButtonKey), 200);
    await tester.ensureVisible(find.byKey(licencesButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(licencesButtonKey));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  Future<void> tapAbout(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(find.byKey(key), 200);
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets('About links to the published source and the privacy policy', (
    tester,
  ) async {
    final opened = <String>[];
    final read = <String>[];
    await pumpSettings(
      tester,
      launchLink: (url) async {
        opened.add(url.toString());
        return true;
      },
      launchPage: (url) async {
        read.add(url.toString());
        return true;
      },
    );

    await tapAbout(tester, sourceCodeTileKey);
    await tapAbout(tester, privacyPolicyTileKey);

    expect(opened, [sourceCodeUrl]);
    expect(read, [privacyPolicyUrl], reason: 'read inside the app');
    expect(privacyPolicyUrl, startsWith(sourceCodeUrl));
  });

  testWidgets('Rate opens the Play Store app, or the web listing without it', (
    tester,
  ) async {
    final opened = <String>[];
    var hasStore = true;
    await pumpSettings(
      tester,
      launchLink: (url) async {
        opened.add(url.toString());
        return hasStore || url.scheme == 'https';
      },
    );

    await tapAbout(tester, rateAppTileKey);
    expect(opened, [playStoreAppUrl]);

    hasStore = false;
    opened.clear();
    await tapAbout(tester, rateAppTileKey);
    expect(opened, [playStoreAppUrl, playStoreWebUrl]);
  });

  testWidgets('Share sends the Play link', (tester) async {
    final sharer = _FakeSharer(hasSheet: true);
    await pumpSettings(tester, sharer: sharer);
    await tapAbout(tester, shareAppTileKey);
    expect(sharer.shared, [shareAppText]);
    expect(shareAppText, contains(playStoreWebUrl));
    expect(find.text('Link copied'), findsNothing);
  });

  testWidgets('Share copies the link where there is no share sheet', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpSettings(tester, sharer: _FakeSharer(hasSheet: false));
    await tapAbout(tester, shareAppTileKey);
    expect(copied, shareAppText);
    expect(find.text('Link copied'), findsOne);
  });

  testWidgets('a key carries its own provider and model', (tester) async {
    final store = await pumpSettings(tester);

    await addKey(tester, name: 'free groq', apiKey: 'gsk-1', provider: 'Groq');
    await addKey(
      tester,
      name: 'my nvidia',
      apiKey: 'nvapi-2',
      provider: 'NVIDIA NIM',
    );

    // The list shows both, each labelled with what it talks to.
    expect(find.text('free groq'), findsOne);
    expect(find.text('my nvidia'), findsOne);
    expect(
      find.text('NVIDIA NIM · ${LlmProvider.nvidiaNim.presets.first.label}'),
      findsOne,
    );

    final saved = await store.load();
    expect(saved.credentials, hasLength(2));
    // The second key was added last, so it is the selected one — and
    // selecting a key selects its provider and model with it, which is the
    // whole reason keys are a list.
    expect(saved.active?.name, 'my nvidia');
    expect(saved.active?.provider, LlmProvider.nvidiaNim);
    expect(saved.active?.apiKey, 'nvapi-2');
    expect(saved.active?.model, LlmProvider.nvidiaNim.defaultModel);
  });

  testWidgets('selecting a key switches the provider used', (tester) async {
    final store = await pumpSettings(tester);
    await addKey(tester, name: 'groq', apiKey: 'gsk-1', provider: 'Groq');
    await addKey(
      tester,
      name: 'nvidia',
      apiKey: 'nvapi-2',
      provider: 'NVIDIA NIM',
    );

    await tester.tap(find.text('groq'));
    await tester.pumpAndSettle();

    final saved = await store.load();
    expect(saved.active?.name, 'groq');
    expect(saved.active?.provider, LlmProvider.groq);
    expect(saved.active?.apiKey, 'gsk-1');
  });

  testWidgets('a key cannot be added nameless, keyless or twice', (
    tester,
  ) async {
    await pumpSettings(tester);
    await addKey(tester, name: 'groq', apiKey: 'gsk-1', provider: 'Groq');

    // Same name again: the name is how the user tells two keys apart, so it
    // has to stay unique.
    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'groq');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API key'),
      'gsk-2',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('That name is taken'), findsOne);

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), '');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Give the key a name'), findsOne);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('groq'), findsOne);
  });

  testWidgets('deleting the last key leaves nothing selected', (tester) async {
    final store = await pumpSettings(tester);
    await addKey(tester, name: 'groq', apiKey: 'gsk-1', provider: 'Groq');

    await tester.tap(find.byTooltip('Delete groq'));
    await tester.pumpAndSettle();

    final saved = await store.load();
    expect(saved.credentials, isEmpty);
    expect(saved.hasApiKey, isFalse);
  });

  testWidgets('deleting a key keeps the player name', (tester) async {
    final store = await pumpSettings(tester, stored: {'player_name': 'magnus'});
    await addKey(tester, name: 'groq', apiKey: 'gsk-1', provider: 'Groq');

    await tester.tap(find.byTooltip('Delete groq'));
    await tester.pumpAndSettle();

    expect((await store.load()).playerName, 'magnus');
  });

  testWidgets('the key an older build saved is listed, not lost', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      stored: {'llm_provider': 'openRouter', 'llm_api_key': 'sk-or-old'},
    );

    expect(find.text(LlmProvider.openRouter.label), findsOne);
    expect(
      find.textContaining(LlmProvider.openRouter.presets.first.label),
      findsOne,
    );
  });

  testWidgets('a model can still be typed in by hand', (tester) async {
    final store = await pumpSettings(tester);
    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API key'),
      'gsk-1',
    );
    // No box to type in until it is asked for.
    expect(find.widgetWithText(TextFormField, 'Model id'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other model…').last);
    await tester.pumpAndSettle();

    // Empty is refused rather than saved as the default behind a "typed" one.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Type the model id'), findsOne);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Model id'),
      'qwen/qwen3.8-27b',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect((await store.load()).active?.model, 'qwen/qwen3.8-27b');
    // A typed model is listed by its id: it has no label.
    expect(find.text('Groq · qwen/qwen3.8-27b'), findsOne);

    // Editing it opens on the box, with the id in it.
    await tester.tap(find.byTooltip('Edit Groq'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, 'Model id'))
          .controller!
          .text,
      'qwen/qwen3.8-27b',
    );
  });

  testWidgets('the last row clears the system navigation bar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          configStore: LlmConfigStore(FakeSecureStorage()),
          nnueAssets: _FakeNets(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Add key'), 100);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.text('Add key')).dy, lessThan(800 - 48));
  });

  testWidgets('unreadable settings say so instead of loading forever', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(configStore: _BrokenStore())),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('could not be read'), findsOneWidget);
    // Nothing to edit, so nothing can overwrite the stored keys.
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('there is no Save button — every change writes itself', (
    tester,
  ) async {
    final store = await pumpSettings(tester);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);

    final toggle = find.byKey(criticalMovesSwitchKey);
    await tester.scrollUntilVisible(toggle, 100);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Read back from storage without anything else being tapped first.
    expect((await store.load()).ranksAlternatives, isFalse);
  });

  testWidgets('a dragged depth is saved, and pushed into the session', (
    tester,
  ) async {
    final pushed = <int>[];
    final store = await pumpSettings(tester, onDepth: pushed.add);
    final slider = find.byType(Slider);
    await tester.scrollUntilVisible(slider, 100);
    await tester.pumpAndSettle();

    final width = tester.getSize(slider).width;
    await tester.dragFrom(tester.getCenter(slider), Offset(width / 4, 0));
    await tester.pumpAndSettle();

    final saved = (await store.load()).engineDepth;
    expect(saved, greaterThan(15));
    // Told the live session too, or the new depth would wait for a restart.
    expect(pushed.last, saved);
  });

  group('Brilliant & Great', () {
    Future<Finder> criticalSwitch(WidgetTester tester) async {
      final toggle = find.byKey(criticalMovesSwitchKey);
      await tester.scrollUntilVisible(toggle, 100);
      await tester.pumpAndSettle();
      return toggle;
    }

    testWidgets('is on by default', (tester) async {
      // The screen asks the question the user has ("do I want these verdicts?")
      // rather than the one the engine has ("how many lines is MultiPV?").
      final store = await pumpSettings(tester);
      expect(
        tester.widget<SwitchListTile>(await criticalSwitch(tester)).value,
        isTrue,
      );
      // The row is the two verdicts and a switch, nothing else: what the
      // setting costs is behind the ⓘ, not printed under the control.
      expect(find.text('Brilliant & Great'), findsOne);

      expect((await store.load()).ranksAlternatives, isTrue);
    });

    testWidgets('applies to the live session at once, no restart', (
      tester,
    ) async {
      // The runner-up is a search of its own, not an engine option, so there
      // is nothing to restart.
      final pushed = <bool>[];
      final store = await pumpSettings(tester, onRanksAlternatives: pushed.add);
      await tester.tap(await criticalSwitch(tester));
      await tester.pumpAndSettle();
      expect(pushed.last, isFalse);
      expect((await store.load()).ranksAlternatives, isFalse);
      expect(find.textContaining('restarted'), findsNothing);
    });

    testWidgets('explains itself in a dialog, not in a paragraph', (
      tester,
    ) async {
      await pumpSettings(tester);
      expect(
        find.textContaining('Enables Brilliant and Great moves'),
        findsNothing,
        reason: 'the explanation is behind the ⓘ, not printed on the page',
      );

      await tester.tap(
        find.descendant(
          of: await criticalSwitch(tester),
          matching: find.byIcon(Icons.info_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Enables Brilliant and Great moves'),
        findsOne,
      );
    });
  });

  group('choosing an engine', () {
    /// The row for one engine, scrolled into view.
    Future<Finder> engineRow(WidgetTester tester, Key key) async {
      final row = find.byKey(key);
      await tester.scrollUntilVisible(row, 100);
      await tester.pumpAndSettle();
      return row;
    }

    Future<Finder> latestRow(WidgetTester tester) =>
        engineRow(tester, latestEngineTileKey);

    /// Whether that row's radio reads as the selected one. The key is on the
    /// choice widget, so the tile it builds has to be found under it.
    bool isSelected(WidgetTester tester, Finder row) => tester
        .widget<ListTile>(
          find.descendant(of: row, matching: find.byType(ListTile)),
        )
        .selected;

    testWidgets('both engines are on screen, and one is picked', (
      tester,
    ) async {
      // A switch could only ever name ONE engine, which left the bundled one
      // — the engine actually running — off the screen entirely.
      await pumpSettings(tester);
      await latestRow(tester);

      expect(find.text(bundledEngineName), findsOne);
      expect(find.text(latestEngineName), findsOne);
      expect(
        isSelected(tester, await engineRow(tester, bundledEngineTileKey)),
        isTrue,
      );
      expect(isSelected(tester, await latestRow(tester)), isFalse);
      expect(find.text('Running now: $bundledEngineName'), findsOne);
      expect(
        find.textContaining('takes over'),
        findsNothing,
        reason: 'the selection matches what is running',
      );
    });

    testWidgets('says when the choice is still waiting on a restart', (
      tester,
    ) async {
      // The engine is chosen at startup, so picking one other than the one in
      // the process changes nothing until the app is restarted.
      await pumpSettings(
        tester,
        stored: {'engine_flavor': 'latest'},
        nets: _FakeNets(ready: true),
        running: latestEngineName,
      );
      expect(find.textContaining('takes over'), findsNothing);

      await tester.tap(await engineRow(tester, bundledEngineTileKey));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('$bundledEngineName takes over at the next'),
        findsOne,
      );
    });

    testWidgets('offers the download before anything is on the device', (
      tester,
    ) async {
      final store = await pumpSettings(tester);
      await latestRow(tester);

      expect(find.text('Download'), findsOne);
      expect(find.text('Delete'), findsNothing);

      // The button downloads without changing which engine is selected: the
      // files and the choice are two different decisions.
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOne);
      expect(isSelected(tester, await latestRow(tester)), isFalse);
      expect((await store.load()).useLatestEngine, isFalse);
    });

    testWidgets('picking it downloads the nets, then saves the choice', (
      tester,
    ) async {
      final store = await pumpSettings(tester);
      await tester.tap(await latestRow(tester));
      await tester.pumpAndSettle();

      expect(isSelected(tester, await latestRow(tester)), isTrue);
      expect((await store.load()).useLatestEngine, isTrue);
    });

    testWidgets('nets already on disk need no second download', (tester) async {
      final store = await pumpSettings(tester, nets: _FakeNets(ready: true));

      // Not selected, but the nets are there — so the way to it is free, and
      // the space they take is offered back. It sits below the fold, so it has
      // to be scrolled to before it is even built.
      await scrollTo(tester, find.text('Delete'));
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.tap(await latestRow(tester));
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        find.textContaining('$latestEngineName takes over at the next'),
        findsOne,
      );
      expect((await store.load()).useLatestEngine, isTrue);
    });

    testWidgets('deleting the nets falls back to the bundled engine', (
      tester,
    ) async {
      final store = await pumpSettings(
        tester,
        stored: {'engine_flavor': 'latest'},
        nets: _FakeNets(ready: true),
        running: latestEngineName,
      );

      await scrollTo(tester, find.text('Delete'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // The selection cannot be left pointing at an engine whose files have
      // just been removed.
      expect(find.text('Download'), findsOne);
      expect(isSelected(tester, await latestRow(tester)), isFalse);
      expect((await store.load()).useLatestEngine, isFalse);
    });

    testWidgets('a failed download leaves the bundled engine in place', (
      tester,
    ) async {
      final store = await pumpSettings(tester, nets: _FakeNets(fails: true));
      await tester.tap(await latestRow(tester));
      await tester.pumpAndSettle();

      expect(isSelected(tester, await latestRow(tester)), isFalse);
      // The reason, not just the fact — a bare "download failed" is what sent
      // the first round of this straight to guesswork.
      expect(find.textContaining('the net server said no'), findsOne);
      expect(find.textContaining(bundledEngineName), findsWidgets);
      expect((await store.load()).useLatestEngine, isFalse);
    });

    testWidgets('deleting a key does not silently change the engine', (
      tester,
    ) async {
      final store = await pumpSettings(tester);
      await addKey(tester, name: 'groq', apiKey: 'gsk-1', provider: 'Groq');
      await tester.tap(await latestRow(tester));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete groq'));
      await tester.pumpAndSettle();

      expect(isSelected(tester, await latestRow(tester)), isTrue);
      expect((await store.load()).useLatestEngine, isTrue);
    });

    testWidgets('explains both engines from the section, not the page', (
      tester,
    ) async {
      await pumpSettings(tester);
      expect(find.textContaining('when the app is restarted'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Engine'),
            matching: find.byType(Row),
          ),
          matching: find.byIcon(Icons.info_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('when the app is restarted'), findsOne);
    });
  });
}

class _BrokenStore extends LlmConfigStore {
  @override
  Future<LlmConfig> load() async => throw Exception('no keystore');
}

class _FakeSharer extends GameSharer {
  _FakeSharer({required this.hasSheet});

  final bool hasSheet;
  final shared = <String>[];

  @override
  Future<bool> share(String text, {String? subject, String? title}) async {
    if (!hasSheet) return false;
    shared.add(text);
    return true;
  }
}
