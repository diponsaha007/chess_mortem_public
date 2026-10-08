/// A model the app was measured on, with the request settings that suit it.
/// The key editor offers these by [label]; any other model id still works,
/// with the provider's cautious defaults.
class LlmPreset {
  const LlmPreset({
    required this.model,
    required this.label,
    this.extras = const {},
    this.maxTokens = defaultMaxTokens,
  });

  final String model;

  /// What the model picker shows.
  final String label;

  /// Extra request fields: how much the model thinks. Each was checked to
  /// be accepted by this model; an unknown field is a 400.
  final Map<String, Object?> extras;

  /// Covers thinking AND answer: a runaway stop, not the length rule (the
  /// prompt sets the length).
  final int maxTokens;

  static const defaultMaxTokens = 1200;
}

/// Known OpenAI-compatible providers. A new provider is just another entry.
enum LlmProvider {
  groq(
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    presets: [
      // Medium thinking roughly halves the wrong claims of low for ~1 s,
      // and uses up to ~1100 tokens.
      LlmPreset(
        model: 'openai/gpt-oss-120b',
        label: 'gpt-oss 120B',
        extras: {'reasoning_effort': 'medium'},
        maxTokens: 2000,
      ),
    ],
    keyPageUrl: 'https://console.groq.com/keys',
    freeWithoutCard: true,
  ),
  gemini(
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    presets: [
      // Thinks little by default; asking for more made it slower, not
      // better. It rejects reasoning_effort "none".
      LlmPreset(model: 'gemini-3.5-flash-lite', label: 'Gemini 3.5 Flash-Lite'),
    ],
    keyPageUrl: 'https://aistudio.google.com/apikey',
    freeWithoutCard: true,
  ),
  openRouter(
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    presets: [
      // A free model, so a key without credits works. Left to think, the
      // free models spend the whole token cap and answer nothing.
      LlmPreset(
        model: 'nvidia/nemotron-3-super-120b-a12b:free',
        label: 'Nemotron Super 120B (free)',
        extras: {
          'reasoning': {'enabled': false},
        },
      ),
    ],
    formerDefaults: ['qwen/qwen3.6-27b'],
    keyPageUrl: 'https://openrouter.ai/keys',
    freeWithoutCard: true,
  ),
  nvidiaNim(
    label: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    presets: [
      // Thinking made it nine times slower and no more accurate.
      LlmPreset(
        model: 'nvidia/nemotron-3-super-120b-a12b',
        label: 'Nemotron Super 120B',
        extras: {
          'chat_template_kwargs': {'enable_thinking': false},
        },
      ),
    ],
    formerDefaults: ['nvidia/nemotron-3.5-lightning-30b-a3b'],
    keyPageUrl: 'https://build.nvidia.com/settings/api-keys',
    freeWithoutCard: true,
  );

  const LlmProvider({
    required this.label,
    required this.baseUrl,
    required this.presets,
    required this.keyPageUrl,
    this.formerDefaults = const [],
    this.freeWithoutCard = false,
  });

  /// The one a new user is pointed at: free, and the one the prompts were
  /// written for.
  static const recommended = groq;

  final String label;
  final String baseUrl;

  /// The measured models, best first. Never empty.
  final List<LlmPreset> presets;

  /// Models a new key used to start on; a key still on one moves to
  /// [defaultModel].
  final List<String> formerDefaults;

  /// Where a signed-in user creates a key.
  final String keyPageUrl;

  /// A key costs nothing and needs no payment card. Claimed only where it
  /// was checked; the key help words itself from this.
  final bool freeWithoutCard;

  /// The model a new key starts with.
  String get defaultModel => presets.first.model;

  /// The preset for [model], or null for a model typed in by hand.
  LlmPreset? presetFor(String model) {
    for (final preset in presets) {
      if (preset.model == model) return preset;
    }
    return null;
  }

  /// Extra request fields for [model]: its preset's, or for any other model
  /// the "do not think" switches known to be safe. Nothing goes to a model
  /// not known to accept it, since an unknown field is a 400.
  ///
  /// * NVIDIA: `chat_template_kwargs.enable_thinking: false`, for the whole
  ///   catalog.
  /// * Groq Qwen: `reasoning_effort: none`.
  /// * Groq gpt-oss: has no off switch, and `none` is a 400 there; `low`.
  Map<String, Object?> requestExtras(String model) {
    if (presetFor(model) case final preset?) return preset.extras;
    if (this == nvidiaNim) {
      return const {
        'chat_template_kwargs': {'enable_thinking': false},
      };
    }
    if (this == groq) {
      final id = model.toLowerCase();
      if (id.contains('gpt-oss')) return const {'reasoning_effort': 'low'};
      if (id.contains('qwen')) return const {'reasoning_effort': 'none'};
    }
    return const {};
  }

  /// The token cap for [model].
  int maxTokensFor(String model) =>
      presetFor(model)?.maxTokens ?? LlmPreset.defaultMaxTokens;

  /// The provider saved under [name], or null if unknown.
  static LlmProvider? byName(String? name) {
    for (final provider in values) {
      if (provider.name == name) return provider;
    }
    return null;
  }
}

/// One saved API key: everything a request needs. [name] is the user's label
/// and the credential's identity, so names are unique.
class LlmCredential {
  LlmCredential({
    required this.name,
    required this.provider,
    required this.apiKey,
    String? model,
  }) : model = (model == null || model.isEmpty) ? provider.defaultModel : model;

  final String name;
  final LlmProvider provider;
  final String apiKey;
  final String model;

  Map<String, Object?> toJson() => {
    'name': name,
    'provider': provider.name,
    'apiKey': apiKey,
    'model': model,
  };

  /// Null for an unreadable entry, so one bad entry does not lose the list.
  static LlmCredential? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final apiKey = json['apiKey'];
    final providerName = json['provider'];
    final provider = LlmProvider.byName(
      providerName is String ? providerName : null,
    );
    if (name is! String || name.isEmpty) return null;
    if (apiKey is! String || provider == null) return null;
    final model = json['model'] is String ? json['model'] as String : null;
    return LlmCredential(
      name: name,
      provider: provider,
      apiKey: apiKey,
      model: provider.formerDefaults.contains(model) ? null : model,
    );
  }

  LlmCredential copyWith({
    String? name,
    LlmProvider? provider,
    String? apiKey,
    String? model,
  }) => LlmCredential(
    name: name ?? this.name,
    provider: provider ?? this.provider,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
  );
}

/// The app's persisted settings: API keys, engine options, player name.
class LlmConfig {
  LlmConfig({
    this.credentials = const [],
    this.activeName,
    this.engineDepth = 15,
    this.ranksAlternatives = true,
    this.useLatestEngine = false,
    this.playerName,
  });

  final List<LlmCredential> credentials;

  /// [LlmCredential.name] of the key in use.
  final String? activeName;
  final int engineDepth;

  /// The "Brilliant & Great" switch: search the runner-up of Best moves.
  /// Off, neither verdict can be awarded.
  final bool ranksAlternatives;

  /// The user's name in their PGNs. Empty and null both mean "not set".
  final String? playerName;

  /// Run Stockfish 18 instead of the bundled 16.
  final bool useLatestEngine;

  /// The named key, or the first one when the name no longer matches.
  LlmCredential? get active {
    for (final credential in credentials) {
      if (credential.name == activeName) return credential;
    }
    return credentials.isEmpty ? null : credentials.first;
  }

  bool get hasApiKey => active?.apiKey.isNotEmpty ?? false;

  /// True when [name] belongs to a credential other than [except].
  bool isNameTaken(String name, {String? except}) => credentials.any(
    (credential) => credential.name == name && credential.name != except,
  );

  /// Null means "unchanged", so a player name is cleared with `''`.
  LlmConfig copyWith({
    List<LlmCredential>? credentials,
    String? activeName,
    int? engineDepth,
    bool? ranksAlternatives,
    bool? useLatestEngine,
    String? playerName,
  }) => LlmConfig(
    credentials: credentials ?? this.credentials,
    activeName: activeName ?? this.activeName,
    engineDepth: engineDepth ?? this.engineDepth,
    ranksAlternatives: ranksAlternatives ?? this.ranksAlternatives,
    useLatestEngine: useLatestEngine ?? this.useLatestEngine,
    playerName: playerName ?? this.playerName,
  );

  /// This config minus the key called [name]. The active name is cleared
  /// when no keys are left, which [copyWith] cannot do.
  LlmConfig withoutCredential(String name) {
    final remaining = [
      for (final credential in credentials)
        if (credential.name != name) credential,
    ];
    return LlmConfig(
      credentials: remaining,
      activeName: remaining.isEmpty ? null : activeName,
      engineDepth: engineDepth,
      ranksAlternatives: ranksAlternatives,
      useLatestEngine: useLatestEngine,
      playerName: playerName,
    );
  }
}
