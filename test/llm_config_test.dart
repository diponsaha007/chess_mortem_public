import 'package:chess_mortem/llm/llm_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LlmProvider', () {
    test('every provider builds a usable chat-completions endpoint', () {
      for (final provider in LlmProvider.values) {
        // OpenAiCompatExplainer appends '/chat/completions' verbatim, so a
        // trailing slash or a missing scheme silently produces a URL that
        // only fails at request time, on a real device, with a real key.
        expect(provider.baseUrl, startsWith('https://'), reason: provider.name);
        expect(provider.baseUrl, isNot(endsWith('/')), reason: provider.name);

        // Not '/v1/chat/completions': the version segment is the provider's
        // business (Gemini's compat endpoint ends in '/v1beta/openai'), and
        // only the suffix the client appends is ours to guarantee.
        final uri = Uri.parse('${provider.baseUrl}/chat/completions');
        expect(uri.isAbsolute, isTrue, reason: provider.name);
        expect(uri.host, isNotEmpty, reason: provider.name);
        expect(uri.path, endsWith('/chat/completions'), reason: provider.name);
        expect(uri.path, isNot(contains('//')), reason: provider.name);
      }
    });

    test('every provider names itself and a default model', () {
      for (final provider in LlmProvider.values) {
        expect(provider.label, isNotEmpty, reason: provider.name);
        expect(provider.defaultModel, isNotEmpty, reason: provider.name);
      }
      // Labels are what the Settings dropdown shows; duplicates would be
      // indistinguishable there.
      final labels = LlmProvider.values.map((p) => p.label).toSet();
      expect(labels, hasLength(LlmProvider.values.length));
    });

    test('the default model is the first preset, and presets are found', () {
      for (final provider in LlmProvider.values) {
        expect(provider.presets, isNotEmpty, reason: provider.name);
        expect(provider.defaultModel, provider.presets.first.model);
        expect(
          provider.presetFor(provider.defaultModel),
          same(provider.presets.first),
        );
        // The picker lists presets by label.
        final labels = provider.presets.map((p) => p.label).toSet();
        expect(labels, hasLength(provider.presets.length));
        // A replaced default must never be offered again.
        for (final old in provider.formerDefaults) {
          expect(provider.presetFor(old), isNull, reason: old);
        }
      }
      expect(LlmProvider.groq.presetFor('typed/by-hand'), isNull);
      expect(
        LlmProvider.groq.maxTokensFor('typed/by-hand'),
        LlmPreset.defaultMaxTokens,
      );
    });

    test('a provider can be looked up by name, and garbage cannot', () {
      expect(LlmProvider.byName('nvidiaNim'), LlmProvider.nvidiaNim);
      expect(LlmProvider.byName('nope'), isNull);
      expect(LlmProvider.byName(null), isNull);
    });
  });

  group('LlmCredential', () {
    test('falls back to the provider default model', () {
      final credential = LlmCredential(
        name: 'k',
        provider: LlmProvider.nvidiaNim,
        apiKey: 'x',
      );
      expect(credential.model, LlmProvider.nvidiaNim.defaultModel);

      final explicit = LlmCredential(
        name: 'k',
        provider: LlmProvider.nvidiaNim,
        apiKey: 'x',
        model: 'nvidia/llama-3.1-nemotron-70b-instruct',
      );
      expect(explicit.model, 'nvidia/llama-3.1-nemotron-70b-instruct');
    });

    test('round-trips through JSON', () {
      final credential = LlmCredential(
        name: 'free groq',
        provider: LlmProvider.groq,
        apiKey: 'gsk-secret',
        model: 'some-model',
      );
      final restored = LlmCredential.fromJson(credential.toJson())!;
      expect(restored.name, 'free groq');
      expect(restored.provider, LlmProvider.groq);
      expect(restored.apiKey, 'gsk-secret');
      expect(restored.model, 'some-model');
    });

    test('a key left on a replaced default moves to the new one', () {
      // Nobody chose these: they were filled in, and they time out or need
      // paid credits.
      for (final provider in LlmProvider.values) {
        for (final old in provider.formerDefaults) {
          final restored = LlmCredential.fromJson({
            'name': 'k',
            'provider': provider.name,
            'apiKey': 'x',
            'model': old,
          })!;
          expect(restored.model, provider.defaultModel, reason: old);
        }
      }
      expect(LlmProvider.openRouter.formerDefaults, isNotEmpty);
      // A model typed in by hand is the user's, and stays.
      final typed = LlmCredential.fromJson({
        'name': 'k',
        'provider': 'openRouter',
        'apiKey': 'x',
        'model': 'some/other-model',
      })!;
      expect(typed.model, 'some/other-model');
    });

    test('rejects entries it cannot use', () {
      // Storage is decoded on every launch; one bad entry must drop out
      // rather than throwing on the way to the board.
      expect(LlmCredential.fromJson(null), isNull);
      expect(LlmCredential.fromJson('not a map'), isNull);
      expect(
        LlmCredential.fromJson({'name': 'n', 'provider': 1, 'apiKey': 'k'}),
        isNull,
      );
      expect(
        LlmCredential.fromJson({
          'name': 'n',
          'provider': 'groq',
          'apiKey': 'k',
          'model': 3,
        })?.model,
        LlmProvider.groq.defaultModel,
      );
      expect(
        LlmCredential.fromJson({'provider': 'groq', 'apiKey': 'k'}),
        isNull,
      ); // no name
      expect(
        LlmCredential.fromJson({'name': '', 'provider': 'groq', 'apiKey': 'k'}),
        isNull,
      );
      expect(
        LlmCredential.fromJson({'name': 'a', 'provider': 'groq'}),
        isNull,
      ); // no key
      expect(
        LlmCredential.fromJson({
          'name': 'a',
          'provider': 'retired-provider',
          'apiKey': 'k',
        }),
        isNull,
      );
    });
  });

  group('LlmConfig', () {
    LlmCredential credential(String name, LlmProvider provider) =>
        LlmCredential(name: name, provider: provider, apiKey: 'key-$name');

    test('the active key is the named one', () {
      final config = LlmConfig(
        credentials: [
          credential('groq', LlmProvider.groq),
          credential('nvidia', LlmProvider.nvidiaNim),
        ],
        activeName: 'nvidia',
      );
      // The whole point of the list: the provider follows the key, so a
      // token can never be sent to another provider's base URL.
      expect(config.active?.provider, LlmProvider.nvidiaNim);
      expect(config.active?.apiKey, 'key-nvidia');
      expect(config.hasApiKey, isTrue);
    });

    test('falls back to the first key when the name no longer matches', () {
      final config = LlmConfig(
        credentials: [credential('groq', LlmProvider.groq)],
        activeName: 'deleted',
      );
      expect(config.active?.name, 'groq');
    });

    test('no keys means no explanations', () {
      final empty = LlmConfig();
      expect(empty.active, isNull);
      expect(empty.hasApiKey, isFalse);

      final blank = LlmConfig(
        credentials: [
          LlmCredential(name: 'blank', provider: LlmProvider.groq, apiKey: ''),
        ],
      );
      expect(blank.hasApiKey, isFalse);
    });

    test('a name is taken by any other key, but not by itself', () {
      final config = LlmConfig(
        credentials: [
          credential('groq', LlmProvider.groq),
          credential('nvidia', LlmProvider.nvidiaNim),
        ],
      );
      expect(config.isNameTaken('groq'), isTrue);
      // Renaming a key to what it is already called is not a clash.
      expect(config.isNameTaken('groq', except: 'groq'), isFalse);
      expect(config.isNameTaken('new one'), isFalse);
    });
  });
}
