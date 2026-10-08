import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/llm_config_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_secure_storage.dart';

void main() {
  group('LlmConfigStore', () {
    test('round-trips the saved keys and the selected one', () async {
      final storage = FakeSecureStorage();
      final store = LlmConfigStore(storage);

      await store.save(
        LlmConfig(
          credentials: [
            LlmCredential(
              name: 'free groq',
              provider: LlmProvider.groq,
              apiKey: 'gsk-1',
            ),
            LlmCredential(
              name: 'nvidia',
              provider: LlmProvider.nvidiaNim,
              apiKey: 'nvapi-2',
              model: 'nvidia/some-model',
            ),
          ],
          activeName: 'nvidia',
          engineDepth: 20,
          ranksAlternatives: false,
          useLatestEngine: true,
        ),
      );

      final loaded = await store.load();
      expect(loaded.credentials, hasLength(2));
      expect(loaded.activeName, 'nvidia');
      expect(loaded.active?.provider, LlmProvider.nvidiaNim);
      expect(loaded.active?.apiKey, 'nvapi-2');
      expect(loaded.active?.model, 'nvidia/some-model');
      expect(loaded.engineDepth, 20);
      expect(loaded.ranksAlternatives, isFalse);
      expect(loaded.useLatestEngine, isTrue);
    });

    test('an empty store configures nothing', () async {
      final config = await LlmConfigStore(FakeSecureStorage()).load();
      expect(config.credentials, isEmpty);
      expect(config.hasApiKey, isFalse);
      expect(config.engineDepth, 15);
      expect(config.ranksAlternatives, isTrue);
      // A fresh install must analyse offline, so the bundled engine wins.
      expect(config.useLatestEngine, isFalse);
    });

    test('storage from before the setting existed keeps the default', () async {
      // Reading a missing value as "off" would quietly turn off Brilliant and
      // Great for everyone upgrading.
      final storage = FakeSecureStorage({'engine_depth': '18'});
      final config = await LlmConfigStore(storage).load();
      expect(config.ranksAlternatives, isTrue);
    });

    test(
      'the old line count carries over: one line was the switch off',
      () async {
        Future<bool> load(String lines) async => (await LlmConfigStore(
          FakeSecureStorage({'engine_lines': lines}),
        ).load()).ranksAlternatives;
        expect(await load('1'), isFalse);
        expect(await load('3'), isTrue);
        expect(await load('5'), isTrue);
      },
    );

    test('the switch, once written, wins over the old line count', () async {
      final storage = FakeSecureStorage({
        'engine_lines': '1',
        'rank_alternatives': 'on',
      });
      expect((await LlmConfigStore(storage).load()).ranksAlternatives, isTrue);
    });

    test(
      'unreadable storage degrades to no keys instead of throwing',
      () async {
        final storage = FakeSecureStorage({
          'llm_credentials': 'not json at all',
        });
        expect((await LlmConfigStore(storage).load()).credentials, isEmpty);

        final partial = FakeSecureStorage({
          // One good entry, one this build cannot use.
          'llm_credentials':
              '[{"name":"ok","provider":"groq","apiKey":"k"},'
              '{"provider":"groq","apiKey":"no name"}]',
        });
        final config = await LlmConfigStore(partial).load();
        expect(config.credentials, hasLength(1));
        expect(config.active?.name, 'ok');
      },
    );

    test(
      'the single key older builds saved becomes a named credential',
      () async {
        final storage = FakeSecureStorage({
          'llm_provider': 'nvidiaNim',
          'llm_api_key': 'nvapi-old',
          'llm_model': 'nvidia/old-model',
          'engine_depth': '18',
        });
        final store = LlmConfigStore(storage);

        final config = await store.load();
        expect(config.credentials, hasLength(1));
        expect(config.active?.name, LlmProvider.nvidiaNim.label);
        expect(config.active?.apiKey, 'nvapi-old');
        expect(config.active?.model, 'nvidia/old-model');
        expect(config.engineDepth, 18);

        // Written through, so the migration happens once and the next launch
        // reads the new shape.
        expect(storage.values['llm_credentials'], contains('nvapi-old'));
        expect((await store.load()).active?.apiKey, 'nvapi-old');
      },
    );

    test(
      'a legacy provider that no longer exists falls back to Groq',
      () async {
        final storage = FakeSecureStorage({
          'llm_provider': 'retired',
          'llm_api_key': 'k',
        });
        final config = await LlmConfigStore(storage).load();
        expect(config.active?.provider, LlmProvider.groq);
      },
    );

    test('a legacy empty key migrates to nothing at all', () async {
      final storage = FakeSecureStorage({'llm_api_key': ''});
      expect((await LlmConfigStore(storage).load()).credentials, isEmpty);
    });
  });
}
