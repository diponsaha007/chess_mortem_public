import 'package:chess_mortem/analysis/analysis_session.dart';
import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/llm_config_store.dart';
import 'package:chess_mortem/model/game_library.dart';
import 'package:chess_mortem/model/hint_store.dart';
import 'package:chess_mortem/platform/incoming_pgn.dart';
import 'package:chess_mortem/screens/board_screen.dart';
import 'package:chess_mortem/screens/library_screen.dart';
import 'package:chess_mortem/screens/settings_screen.dart';
import 'package:chess_mortem/widgets/key_help.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_config_store.dart';
import 'fakes/fake_engine.dart';
import 'fakes/fake_library_store.dart';
import 'fakes/fake_secure_storage.dart';

const _pgn = '''
[White "Queen_Walker_Test"]
[Black "Night_Owl_Test"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0
''';

const _otherPgn = '''
[White "Rook_Example"]
[Black "Queen_Walker_Test"]
[Result "1-0"]

1. d4 d5 2. c4 1-0
''';

class _FakeHints extends HintStore {
  _FakeHints({this.dismissed = false});

  bool dismissed;

  @override
  Future<bool> isNameHintDismissed() async => dismissed;

  @override
  Future<void> dismissNameHint() async => dismissed = true;
}

const _incomingChannel = MethodChannel('chess_mortem/incoming');

void main() {
  void phone(WidgetTester tester, [Size size = const Size(360, 740)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<GameLibrary> library([List<String> pgns = const [_pgn]]) async {
    final library = GameLibrary(store: FakeLibraryStore(const []));
    await library.load();
    for (final pgn in pgns) {
      await library.add(pgn);
    }
    return library;
  }

  Future<AnalysisSession> pumpLibrary(
    WidgetTester tester,
    GameLibrary library, {
    String? playerName,
    HintStore? hints,
    IncomingPgn? incoming,
  }) async {
    final session = AnalysisSession(
      engine: FakeEngine(),
      playerName: playerName,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          session: session,
          configStore: FakeConfigStore(hasKey: false),
          library: library,
          hints: hints ?? _FakeHints(dismissed: true),
          incoming: incoming,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  group('the name hint', () {
    for (final size in const [Size(320, 568), Size(360, 740)]) {
      testWidgets('asks once who you are, and stays gone at $size', (
        tester,
      ) async {
        phone(tester, size);
        final hints = _FakeHints();
        await pumpLibrary(tester, await library(), hints: hints);

        expect(find.byKey(nameHintKey), findsOne);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();

        expect(find.byKey(nameHintKey), findsNothing);
        expect(hints.dismissed, isTrue);
      });
    }

    testWidgets('is not shown once a name is set', (tester) async {
      phone(tester);
      await pumpLibrary(
        tester,
        await library(),
        playerName: 'Queen_Walker_Test',
        hints: _FakeHints(),
      );
      expect(find.byKey(nameHintKey), findsNothing);
    });

    testWidgets('is not shown after a dismissal', (tester) async {
      phone(tester);
      await pumpLibrary(
        tester,
        await library(),
        hints: _FakeHints(dismissed: true),
      );
      expect(find.byKey(nameHintKey), findsNothing);
    });

    testWidgets('leads to Settings', (tester) async {
      phone(tester);
      await pumpLibrary(tester, await library(), hints: _FakeHints());
      await tester.tap(find.text('Set name'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOne);
    });
  });

  group('a PGN from outside the app', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// What the app was launched with.
    void launchedWith(String? text) {
      messenger.setMockMethodCallHandler(
        _incomingChannel,
        (call) async => call.method == 'takePending' ? text : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(_incomingChannel, null),
      );
    }

    /// The platform side handing one over while the app is open.
    Future<void> arrives(String text) => messenger.handlePlatformMessage(
      _incomingChannel.name,
      _incomingChannel.codec.encodeMethodCall(MethodCall('incoming', text)),
      (_) {},
    );

    testWidgets('the app opened with a game saves it and shows the board', (
      tester,
    ) async {
      phone(tester);
      launchedWith(_otherPgn);
      final games = await library();

      final session = await pumpLibrary(tester, games, incoming: IncomingPgn());

      expect(games.games, hasLength(2));
      expect(find.byType(BoardScreen), findsOne);
      expect(session.whitePlayer, 'Rook_Example');
    });

    testWidgets('one shared while another game is open replaces it', (
      tester,
    ) async {
      phone(tester);
      launchedWith(null);
      final games = await library();
      final session = await pumpLibrary(tester, games, incoming: IncomingPgn());
      await tester.tap(find.text('Night_Owl_Test'));
      await tester.pumpAndSettle();
      expect(session.whitePlayer, 'Queen_Walker_Test');

      await arrives(_otherPgn);
      await tester.pumpAndSettle();

      expect(games.games, hasLength(2));
      expect(find.byType(BoardScreen), findsOne); // one board, not two
      expect(session.whitePlayer, 'Rook_Example');
    });

    testWidgets('text that is not a game is refused and says so', (
      tester,
    ) async {
      phone(tester);
      launchedWith('Check out this great article about rook endgames!');
      final games = await library();

      await pumpLibrary(tester, games, incoming: IncomingPgn());

      expect(games.games, hasLength(1));
      expect(find.byType(BoardScreen), findsNothing);
      expect(find.textContaining('could not be read as a PGN'), findsOne);
    });
  });

  group('the key help', () {
    Future<void> openAddKey(WidgetTester tester) async {
      phone(tester, const Size(360, 740));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            configStore: LlmConfigStore(FakeSecureStorage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Add key'), 100);
      await tester.ensureVisible(find.text('Add key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
    }

    String fieldText(WidgetTester tester, String label) => tester
        .widget<TextFormField>(find.widgetWithText(TextFormField, label))
        .controller!
        .text;

    testWidgets('a new key starts on the recommended provider, filled in', (
      tester,
    ) async {
      await openAddKey(tester);

      expect(LlmProvider.recommended.freeWithoutCard, isTrue);
      expect(find.text('Get a free key'), findsOne);
      expect(find.textContaining('asks for no card'), findsOne);
      expect(fieldText(tester, 'Name'), LlmProvider.recommended.label);
      // The model is picked from the measured ones, the first selected.
      expect(find.text(LlmProvider.recommended.presets.first.label), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching provider follows it', (tester) async {
      await openAddKey(tester);
      await tester.tap(find.byType(DropdownButtonFormField<LlmProvider>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NVIDIA NIM').last);
      await tester.pumpAndSettle();

      expect(LlmProvider.nvidiaNim.freeWithoutCard, isTrue);
      expect(find.text('Get a free key'), findsOne);
      expect(fieldText(tester, 'Name'), 'NVIDIA NIM');
      // The model follows the provider.
      expect(find.text(LlmProvider.nvidiaNim.presets.first.label), findsOne);
    });

    testWidgets('with no browser the link is copied instead', (tester) async {
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
      final asked = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyHelp(
              provider: LlmProvider.gemini,
              launch: (url) async {
                asked.add(url);
                return false;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(keyPageButtonKey));
      await tester.pumpAndSettle();

      expect(asked.single.toString(), LlmProvider.gemini.keyPageUrl);
      expect(copied, LlmProvider.gemini.keyPageUrl);
      expect(find.textContaining('Link copied'), findsOne);
    });

    test('every provider has a secure key page', () {
      for (final provider in LlmProvider.values) {
        expect(
          provider.keyPageUrl,
          startsWith('https://'),
          reason: provider.name,
        );
      }
    });
  });
}
