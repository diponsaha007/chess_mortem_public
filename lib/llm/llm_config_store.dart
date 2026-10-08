import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'llm_config.dart';

/// Loads and saves [LlmConfig] in secure storage.
class LlmConfigStore {
  LlmConfigStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _credentialsKey = 'llm_credentials';
  static const _activeKey = 'llm_active_credential';
  static const _depthKey = 'engine_depth';
  static const _alternativesKey = 'rank_alternatives';
  static const _playerNameKey = 'player_name';

  static const _flavorKey = 'engine_flavor';
  static const _latestFlavor = 'latest';

  // The MultiPV count builds before the runner-up search stored. Read when
  // the switch was never written: 1 meant off.
  static const _legacyLinesKey = 'engine_lines';

  // Pre-list builds' single key. Read once and migrated.
  static const _legacyProviderKey = 'llm_provider';
  static const _legacyApiKeyKey = 'llm_api_key';
  static const _legacyModelKey = 'llm_model';

  Future<LlmConfig> load() async {
    final depth = int.tryParse(await _storage.read(key: _depthKey) ?? '') ?? 15;
    final alternatives = await _storage.read(key: _alternativesKey);
    final ranksAlternatives = alternatives == null
        ? await _storage.read(key: _legacyLinesKey) != '1'
        : alternatives != 'off';
    final latest = await _storage.read(key: _flavorKey) == _latestFlavor;
    final player = await _storage.read(key: _playerNameKey);
    final stored = await _storage.read(key: _credentialsKey);

    final List<LlmCredential> credentials;
    final String? activeName;
    if (stored == null) {
      credentials = await _migrateLegacyKey();
      activeName = credentials.isEmpty ? null : credentials.first.name;
    } else {
      credentials = _decode(stored);
      activeName = await _storage.read(key: _activeKey);
    }

    return LlmConfig(
      credentials: credentials,
      activeName: activeName,
      engineDepth: depth,
      ranksAlternatives: ranksAlternatives,
      useLatestEngine: latest,
      playerName: player,
    );
  }

  Future<void> save(LlmConfig config) async {
    final json = config.credentials.map((c) => c.toJson()).toList();
    await _storage.write(key: _credentialsKey, value: jsonEncode(json));
    await _storage.write(key: _activeKey, value: config.active?.name ?? '');
    await _storage.write(key: _depthKey, value: '${config.engineDepth}');
    await _storage.write(
      key: _alternativesKey,
      value: config.ranksAlternatives ? 'on' : 'off',
    );
    await _storage.write(
      key: _flavorKey,
      value: config.useLatestEngine ? _latestFlavor : 'sf16',
    );
    await _storage.write(key: _playerNameKey, value: config.playerName ?? '');
  }

  List<LlmCredential> _decode(String stored) {
    final Object? json;
    try {
      json = jsonDecode(stored);
    } on FormatException {
      return const [];
    }
    if (json is! List) return const [];
    return [for (final entry in json) ?LlmCredential.fromJson(entry)];
  }

  /// The single key older builds saved, as one named credential; else the
  /// `--dart-define=GROQ_API_KEY` dev key.
  Future<List<LlmCredential>> _migrateLegacyKey() async {
    final provider =
        LlmProvider.byName(await _storage.read(key: _legacyProviderKey)) ??
        LlmProvider.groq;
    final apiKey = await _storage.read(key: _legacyApiKeyKey) ?? '';
    if (apiKey.isNotEmpty) {
      final migrated = LlmCredential(
        name: provider.label,
        provider: provider,
        apiKey: apiKey,
        model: await _storage.read(key: _legacyModelKey),
      );
      // Written through so the migration runs once.
      await save(LlmConfig(credentials: [migrated], activeName: migrated.name));
      return [migrated];
    }

    const devKey = String.fromEnvironment('GROQ_API_KEY');
    if (devKey.isEmpty) return const [];
    // Not persisted: a later build without the define must not keep it.
    return [
      LlmCredential(
        name: 'Dev key',
        provider: LlmProvider.groq,
        apiKey: devKey,
      ),
    ];
  }
}
