import 'package:chess_mortem/llm/llm_config.dart';
import 'package:chess_mortem/llm/llm_config_store.dart';

/// Skips secure storage. [hasKey] false stands in for a fresh install.
class FakeConfigStore extends LlmConfigStore {
  FakeConfigStore({this.hasKey = true});

  final bool hasKey;

  @override
  Future<LlmConfig> load() async => LlmConfig(
    credentials: [
      if (hasKey)
        LlmCredential(
          name: 'test key',
          provider: LlmProvider.groq,
          apiKey: 'test-key',
        ),
    ],
    activeName: hasKey ? 'test key' : null,
  );

  @override
  Future<void> save(LlmConfig config) async {}
}
