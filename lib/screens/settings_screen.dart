import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../appearance/appearance_controller.dart';
import '../engine/nnue_assets.dart';
import '../engine/uci_options.dart';
import '../feedback/move_sounds.dart';
import '../llm/llm_config.dart';
import '../llm/llm_config_store.dart';
import '../logging/app_log.dart';
import '../widgets/appearance_picker.dart';
import '../widgets/info_note.dart';
import '../widgets/key_help.dart';
import '../widgets/safe_bottom.dart';

const bundledEngineTileKey = ValueKey('settingsBundledEngine');
const latestEngineTileKey = ValueKey('settingsLatestEngine');
const criticalMovesSwitchKey = ValueKey('settingsCriticalMovesSwitch');
const moveSoundsSwitchKey = ValueKey('settingsMoveSoundsSwitch');
const licencesButtonKey = ValueKey('settingsLicences');
const playerNameTileKey = ValueKey('settingsPlayerName');
const playerNameFieldKey = ValueKey('settingsPlayerNameField');
const sourceCodeTileKey = ValueKey('settingsSourceCode');
const privacyPolicyTileKey = ValueKey('settingsPrivacyPolicy');

/// Where the app's source is published with every release.
const sourceCodeUrl = 'https://github.com/diponsaha007/chess_mortem_public';

/// PRIVACY.md in that repo; `HEAD` follows its default branch.
const privacyPolicyUrl = '$sourceCodeUrl/blob/HEAD/PRIVACY.md';

// What each setting means, behind its ⓘ.

const _playerNote = InfoNote(
  title: 'Your name',
  body:
      'Your name as it appears in your PGNs. The board then opens on your '
      'side, and reviews your key moves only.',
);

const _depthNote = InfoNote(
  title: 'Search depth',
  body:
      'How far ahead the engine looks. Higher is stronger but slower, and '
      'applies from now on. A saved game is analysed again when it is '
      'reopened at a higher depth.',
);

const _criticalNote = InfoNote(
  title: 'Brilliant & Great',
  body:
      'After a best move, the engine checks the next-best one, so the app '
      'can tell when only one move worked. Adds a little time on those moves.',
);

const _engineNote = InfoNote(
  title: 'Engine',
  body:
      'Select the engine that analyses your games. A change takes effect '
      'when the app is restarted.',
);

final _keysNote = InfoNote(
  title: 'API keys',
  body:
      'Written explanations need a key from an AI provider. All of these '
      'give one for free, no card needed:\n'
      '${_freeProviders.map((name) => '• $name').join('\n')}\n\n'
      'A key is stored encrypted on this device and sent only to its '
      'provider.\n\n'
      'Tip: each free key has a rate limit. Add a key from every provider '
      'and switch to another when one runs out.',
);

/// The providers whose free, card-less key was checked.
final _freeProviders = [
  for (final provider in LlmProvider.values)
    if (provider.freeWithoutCard) provider.label,
];

/// Settings: the board's look, player name, analysis, engine and API keys.
/// Saves itself on every change.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.configStore,
    this.onEngineDepthChanged,
    this.onRanksAlternativesChanged,
    this.onPlayerNameChanged,
    this.nnueAssets,
    this.runningEngineName,
    this.launchLink = launchInBrowser,
  });

  final LlmConfigStore configStore;

  /// The engine running now; the selection only applies at the next start.
  final String? runningEngineName;

  /// Injectable for tests; created (and disposed) here otherwise.
  final NnueAssets? nnueAssets;

  /// Called on every save, with the saved depth.
  final ValueChanged<int>? onEngineDepthChanged;

  /// Called on every save, with the saved Brilliant & Great switch.
  final ValueChanged<bool>? onRanksAlternativesChanged;

  /// Called when a save changes the player name, with the new name.
  final ValueChanged<String?>? onPlayerNameChanged;

  /// Injectable for tests.
  final LinkLauncher launchLink;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  LlmConfig _config = LlmConfig();
  bool _loaded = false;

  /// Why the settings could not be read. Nothing is editable then: a save
  /// would overwrite the stored keys with the defaults.
  String? _loadError;

  late final NnueAssets _nets = widget.nnueAssets ?? NnueAssets();

  bool _netsReady = false;
  double? _downloadProgress;
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    widget.configStore.load().then(
      (config) {
        if (!mounted) return;
        setState(() {
          _config = config;
          _loaded = true;
        });
      },
      onError: (Object e) {
        AppLog.instance.error('settings', 'could not read settings: $e');
        if (mounted) setState(() => _loadError = '$e');
      },
    );
    _nets.isReady
        .then((ready) {
          if (mounted) setState(() => _netsReady = ready);
        })
        .catchError((_) {}); // unreadable storage: not downloaded
  }

  @override
  void dispose() {
    if (widget.nnueAssets == null) _nets.dispose();
    super.dispose();
  }

  /// The selected engine when it differs from the running one, else null.
  String? get _pendingEngineName {
    final selected = engineNameFor(useLatest: _config.useLatestEngine);
    final running = widget.runningEngineName;
    return running == null || selected == running ? null : selected;
  }

  /// Every edit is its own save.
  void _apply(LlmConfig next) {
    final nameChanged = next.playerName != _config.playerName;
    setState(() => _config = next);
    _save(nameChanged: nameChanged);
  }

  /// Applies to the session even when storage fails: the change still holds
  /// until the app closes.
  Future<void> _save({required bool nameChanged}) async {
    final config = _config;
    try {
      await widget.configStore.save(config);
    } catch (e) {
      AppLog.instance.error('settings', 'could not save settings: $e');
    }
    widget.onEngineDepthChanged?.call(config.engineDepth);
    widget.onRanksAlternativesChanged?.call(config.ranksAlternatives);
    if (nameChanged) widget.onPlayerNameChanged?.call(config.playerName);
  }

  /// Cancel leaves the name alone; an empty box clears it (as `''`).
  Future<void> _editPlayerName() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _PlayerNameDialog(initial: _config.playerName),
    );
    if (name == null) return; // cancelled
    _apply(_config.copyWith(playerName: name.trim()));
  }

  /// Picking the newer engine downloads its nets first and selects it only
  /// on success.
  Future<void> _selectEngine({required bool useLatest}) async {
    if (!useLatest) {
      _apply(_config.copyWith(useLatestEngine: false));
      setState(() => _downloadError = null);
      return;
    }
    if (_netsReady) {
      _apply(_config.copyWith(useLatestEngine: true));
      return;
    }
    await _downloadNets(thenSelect: true);
  }

  /// [thenSelect] separates picking the engine from the plain Download button.
  Future<void> _downloadNets({bool thenSelect = false}) async {
    setState(() {
      _downloadProgress = 0;
      _downloadError = null;
    });
    try {
      await _nets.download(
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _netsReady = true;
        _downloadProgress = null;
      });
      if (thenSelect) _apply(_config.copyWith(useLatestEngine: true));
    } catch (e) {
      AppLog.instance.error('nets', 'download failed: $e');
      if (!mounted) return;
      setState(() {
        _downloadProgress = null;
        _downloadError =
            '${_reasonFor(e)} Still using $bundledEngineName'
            '${showLogsScreen ? ' — see Logs for details' : ''}.';
      });
    }
  }

  String _reasonFor(Object error) {
    if (error is SocketException) return 'No connection to the net server.';
    if (error is HttpException) return error.message;
    return 'The download did not finish.';
  }

  Future<void> _removeNets() async {
    try {
      await _nets.delete();
    } catch (e) {
      AppLog.instance.error('nets', 'could not delete the nets: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _netsReady = false;
      _downloadError = null;
    });
    // The selection may never point at an engine that cannot start.
    _apply(_config.copyWith(useLatestEngine: false));
  }

  Future<void> _editKey({LlmCredential? existing}) async {
    final edited = await showDialog<LlmCredential>(
      context: context,
      builder: (context) => _KeyEditorDialog(
        existing: existing,
        isNameTaken: (name) =>
            _config.isNameTaken(name, except: existing?.name),
      ),
    );
    if (edited == null) return;

    final credentials = [..._config.credentials];
    final index = credentials.indexWhere((c) => c.name == existing?.name);
    if (index == -1) {
      credentials.add(edited);
    } else {
      credentials[index] = edited;
    }
    _apply(
      _config.copyWith(
        credentials: credentials,
        // A new or edited key becomes the active one.
        activeName: edited.name,
      ),
    );
  }

  void _deleteKey(LlmCredential credential) =>
      _apply(_config.withoutCredential(credential.name));

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.controllerOf(context);
    final sounds = MoveSoundsScope.maybeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Settings could not be read on this device: $_loadError',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: withSafeBottom(context, const EdgeInsets.all(16)),
              children: [
                if (appearance != null || sounds != null)
                  _Section(
                    title: 'Board',
                    children: [
                      if (appearance != null)
                        AppearancePicker(controller: appearance),
                      if (sounds != null)
                        SwitchListTile(
                          key: moveSoundsSwitchKey,
                          title: const Text('Move sounds'),
                          value: sounds.enabled,
                          onChanged: sounds.setEnabled,
                        ),
                    ],
                  ),
                _Section(title: 'Analysis', children: _analysisRows(context)),
                _Section(
                  title: 'Engine',
                  note: _engineNote,
                  children: _engineRows(context),
                ),
                _Section(
                  title: 'Explanations',
                  note: _keysNote,
                  children: _explanationRows(context),
                ),
                _Section(title: 'About', children: _aboutRows(context)),
              ],
            ),
    );
  }

  List<Widget> _analysisRows(BuildContext context) {
    final theme = Theme.of(context);
    return [
      ListTile(
        key: playerNameTileKey,
        title: const _RowTitle('Your name', _playerNote),
        subtitle: Text(
          _config.playerName?.isNotEmpty == true
              ? _config.playerName!
              : 'Not set',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: _editPlayerName,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: _RowTitle('Search depth', _depthNote)),
                Text(
                  '${_config.engineDepth}',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            Slider(
              value: _config.engineDepth.toDouble(),
              min: 10,
              max: 22,
              divisions: 12,
              label: '${_config.engineDepth}',
              // Saved once, when the drag ends.
              onChanged: (v) => setState(() {
                _config = _config.copyWith(engineDepth: v.round());
              }),
              onChangeEnd: (_) => _save(nameChanged: false),
            ),
          ],
        ),
      ),
      SwitchListTile(
        key: criticalMovesSwitchKey,
        title: const _RowTitle('Brilliant & Great', _criticalNote),
        value: _config.ranksAlternatives,
        onChanged: (on) => _apply(_config.copyWith(ranksAlternatives: on)),
      ),
    ];
  }

  List<Widget> _engineRows(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _downloadProgress != null;
    return [
      _EngineChoice(
        key: bundledEngineTileKey,
        name: bundledEngineName,
        detail: 'Bundled. Works offline.',
        selected: !_config.useLatestEngine,
        onTap: busy ? null : () => _selectEngine(useLatest: false),
      ),
      _EngineChoice(
        key: latestEngineTileKey,
        name: latestEngineName,
        detail: _netsReady ? 'Stronger. Nets ready.' : 'Stronger. Needs 80 MB.',
        selected: _config.useLatestEngine,
        onTap: busy ? null : () => _selectEngine(useLatest: true),
        action: _netsReady
            ? TextButton(
                onPressed: busy ? null : _removeNets,
                child: const Text('Delete'),
              )
            : TextButton(
                onPressed: busy ? null : () => _downloadNets(),
                child: const Text('Download'),
              ),
      ),
      if (_downloadProgress != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 4),
              Text(
                'Downloading nets… ${(_downloadProgress! * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      if (_downloadError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _downloadError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      if (widget.runningEngineName != null || _pendingEngineName != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.runningEngineName != null)
                Text(
                  'Running now: ${widget.runningEngineName}',
                  style: theme.textTheme.bodySmall,
                ),
              if (_pendingEngineName != null)
                Text(
                  '$_pendingEngineName takes over at the next app start.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  /// The engine is copyleft: where the app's source is, what it sends, and
  /// the page that credits the engine and the piece sets.
  List<Widget> _aboutRows(BuildContext context) {
    final theme = Theme.of(context);
    final detail = theme.textTheme.bodySmall;
    void open(String url) => openLink(context, url, launch: widget.launchLink);
    return [
      ListTile(
        key: sourceCodeTileKey,
        leading: const Icon(Icons.code),
        title: const Text('Source code'),
        subtitle: Text('Free software, GPL-3.0 or later', style: detail),
        trailing: const Icon(Icons.open_in_new),
        onTap: () => open(sourceCodeUrl),
      ),
      ListTile(
        key: privacyPolicyTileKey,
        leading: const Icon(Icons.privacy_tip_outlined),
        title: const Text('Privacy policy'),
        subtitle: Text('Nothing is collected', style: detail),
        trailing: const Icon(Icons.open_in_new),
        onTap: () => open(privacyPolicyUrl),
      ),
      ListTile(
        key: licencesButtonKey,
        leading: const Icon(Icons.description_outlined),
        title: const Text('Licences'),
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'Chess Mortem',
          applicationLegalese:
              'Copyright © 2026 Apurba Saha\n'
              'GPL-3.0 or later, with no warranty.',
        ),
      ),
    ];
  }

  List<Widget> _explanationRows(BuildContext context) {
    final theme = Theme.of(context);
    return [
      if (_config.credentials.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'No keys yet — the engine writes the coach line alone. '
            '"Add key" shows how to get a free one.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      for (final credential in _config.credentials)
        _KeyTile(
          credential: credential,
          selected: credential.name == _config.active?.name,
          onSelected: () =>
              _apply(_config.copyWith(activeName: credential.name)),
          onEdit: () => _editKey(existing: credential),
          onDelete: () => _deleteKey(credential),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _editKey(),
          icon: const Icon(Icons.add),
          label: const Text('Add key'),
        ),
      ),
    ];
  }
}

/// One titled card of settings.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.note});

  final String title;

  /// A note about the whole group, beside its title.
  final InfoNote? note;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                if (note != null) InfoDot(note!),
              ],
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A setting's name with its ⓘ beside the name, not by the control.
class _RowTitle extends StatelessWidget {
  const _RowTitle(this.text, this.note);

  final String text;
  final InfoNote note;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        InfoDot(note),
      ],
    );
  }
}

/// One engine to pick from.
class _EngineChoice extends StatelessWidget {
  const _EngineChoice({
    super.key,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.action,
  });

  final String name;
  final String detail;
  final bool selected;

  /// Null (greyed out) while the nets download.
  final VoidCallback? onTap;

  /// Download/Delete for the engine's nets.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      enabled: enabled,
      onTap: onTap,
      selected: selected,
      leading: _RadioIcon(selected: selected, enabled: enabled),
      title: Text(name),
      subtitle: Text(detail, style: theme.textTheme.bodySmall),
      trailing: action,
    );
  }
}

/// A radio mark drawn as an icon: Material's [Radio] wants a `RadioGroup`
/// ancestor these list tiles do not have.
class _RadioIcon extends StatelessWidget {
  const _RadioIcon({required this.selected, this.enabled = true});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: !enabled
          ? theme.disabledColor
          : selected
          ? theme.colorScheme.primary
          : theme.colorScheme.outline,
    );
  }
}

/// One saved key: its name, what it talks to, and edit/delete actions.
class _KeyTile extends StatelessWidget {
  const _KeyTile({
    required this.credential,
    required this.selected,
    required this.onSelected,
    required this.onEdit,
    required this.onDelete,
  });

  final LlmCredential credential;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: onSelected,
      selected: selected,
      leading: _RadioIcon(selected: selected),
      title: Text(credential.name),
      subtitle: Text(
        '${credential.provider.label} · '
        '${credential.provider.presetFor(credential.model)?.label ?? credential.model}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit ${credential.name}',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete ${credential.name}',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// The model picker's entry for a model typed in by hand.
const _otherModel = '';

/// Add/edit one key. Returns the credential, or null if cancelled.
class _KeyEditorDialog extends StatefulWidget {
  const _KeyEditorDialog({required this.existing, required this.isNameTaken});

  final LlmCredential? existing;

  /// Asked by the form; the caller owns the list, so it owns the rule.
  final bool Function(String name) isNameTaken;

  @override
  State<_KeyEditorDialog> createState() => _KeyEditorDialogState();
}

class _KeyEditorDialogState extends State<_KeyEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late LlmProvider _provider;

  /// The picked preset's model id, or [_otherModel] for one typed in.
  late String _preset;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _provider = existing?.provider ?? LlmProvider.recommended;
    _nameController = TextEditingController(
      text: existing?.name ?? _suggestedName(_provider),
    );
    _apiKeyController = TextEditingController(text: existing?.apiKey ?? '');
    final model = existing?.model ?? _provider.defaultModel;
    final isPreset = _provider.presetFor(model) != null;
    _preset = isPreset ? model : _otherModel;
    _modelController = TextEditingController(text: isPreset ? '' : model);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  /// The provider's own name, so a new key needs nothing typed but the key
  /// itself. Empty when a key is already called that.
  String _suggestedName(LlmProvider provider) =>
      widget.isNameTaken(provider.label) ? '' : provider.label;

  /// Follow the provider with the model only while a preset is picked, and
  /// with the name only while it is a default. What the user typed
  /// themselves is theirs to keep.
  void _onProviderChanged(LlmProvider provider) {
    final name = _nameController.text.trim();
    final isDefaultName =
        name.isEmpty || LlmProvider.values.any((p) => p.label == name);
    setState(() {
      _provider = provider;
      if (_preset != _otherModel) _preset = provider.defaultModel;
      if (isDefaultName && widget.existing == null) {
        _nameController.text = _suggestedName(provider);
      }
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      LlmCredential(
        name: _nameController.text.trim(),
        provider: _provider,
        apiKey: _apiKeyController.text.trim(),
        model: _preset == _otherModel ? _modelController.text.trim() : _preset,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add key' : 'Edit key'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<LlmProvider>(
                initialValue: _provider,
                // Or the longest label overflows a narrow phone's dialog.
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Provider'),
                items: [
                  for (final provider in LlmProvider.values)
                    DropdownMenuItem(
                      value: provider,
                      child: Text(provider.label),
                    ),
                ],
                onChanged: (provider) {
                  if (provider != null) _onProviderChanged(provider);
                },
              ),
              const SizedBox(height: 16),
              if (widget.existing == null) ...[
                KeyHelp(provider: _provider),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API key'),
                validator: (value) =>
                    (value?.trim().isEmpty ?? true) ? 'Paste the key' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'Your own label, e.g. "free groq"',
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) return 'Give the key a name';
                  if (widget.isNameTaken(name)) return 'That name is taken';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                // A new provider brings its own list, so the field is rebuilt.
                key: ValueKey('model-${_provider.name}'),
                initialValue: _preset,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  helperText: 'The first one is recommended',
                ),
                items: [
                  for (final preset in _provider.presets)
                    DropdownMenuItem(
                      value: preset.model,
                      child: Text(preset.label),
                    ),
                  const DropdownMenuItem(
                    value: _otherModel,
                    child: Text('Other model…'),
                  ),
                ],
                onChanged: (model) {
                  if (model != null) setState(() => _preset = model);
                },
              ),
              if (_preset == _otherModel) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model id',
                    helperText: 'As the provider lists it',
                  ),
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Type the model id'
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Done')),
      ],
    );
  }
}

/// Asks for the user's name. Stateful so the dialog owns its controller,
/// disposed only once the dialog has animated out.
class _PlayerNameDialog extends StatefulWidget {
  const _PlayerNameDialog({this.initial});

  final String? initial;

  @override
  State<_PlayerNameDialog> createState() => _PlayerNameDialogState();
}

class _PlayerNameDialogState extends State<_PlayerNameDialog> {
  late final _controller = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Pops the raw text; `''` clears the name, only Cancel pops null.
  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your name'),
      content: TextField(
        key: playerNameFieldKey,
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name in the PGN',
          hintText: 'e.g. your username on the site you play',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
