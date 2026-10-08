import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/game_tree.dart';

/// The three clicks a move can make.
enum MoveSound { move, capture, check }

/// The sound of the move INTO [node], or null at the root. A check wins over
/// a capture; castling is an ordinary move.
MoveSound? moveSoundFor(GameNode node) {
  if (node.isRoot) return null;
  if (node.position.isCheck) return MoveSound.check;
  if (node.isCapture) return MoveSound.capture;
  return MoveSound.move;
}

/// Plays a clip. A class so tests can listen without the audio plugin.
abstract class SoundPlayer {
  void play(MoveSound sound);
  void dispose();
}

/// Plays nothing: the default, so a widget needs no audio to be used alone.
class SilentSoundPlayer implements SoundPlayer {
  const SilentSoundPlayer();

  @override
  void play(MoveSound sound) {}

  @override
  void dispose() {}
}

/// The clips in `assets/sounds/`, one low-latency player each. Takes no audio
/// focus, so a click never pauses the user's music.
class AudioSoundPlayer implements SoundPlayer {
  AudioSoundPlayer() {
    for (final sound in MoveSound.values) {
      final player = AudioPlayer();
      _players[sound] = player;
      unawaited(_prepare(player, sound));
    }
  }

  static final _context = AudioContextConfig(
    focus: AudioContextConfigFocus.mixWithOthers,
  ).build();

  final _players = <MoveSound, AudioPlayer>{};

  Future<void> _prepare(AudioPlayer player, MoveSound sound) async {
    try {
      await player.setAudioContext(_context);
      await player.setPlayerMode(PlayerMode.lowLatency);
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSource(AssetSource('sounds/${sound.name}.ogg'));
    } catch (_) {
      // No sound on this device; the move still plays.
    }
  }

  @override
  void play(MoveSound sound) {
    final player = _players[sound];
    if (player == null) return;
    unawaited(
      player.stop().then((_) => player.resume()).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    for (final player in _players.values) {
      unawaited(player.dispose().catchError((Object _) {}));
    }
    _players.clear();
  }
}

/// Whether moves click, and the clicking. One Settings switch, on by
/// default, saved in plain preferences.
class MoveSounds extends ChangeNotifier {
  MoveSounds({SoundPlayer player = const SilentSoundPlayer()})
    : _player = player;

  static const _key = 'move_sounds';

  final SoundPlayer _player;

  bool get enabled => _enabled;
  bool _enabled = true;

  /// The saved switch; on when nothing is stored or storage cannot be read.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_key) ?? true;
    } catch (_) {
      _enabled = true;
    }
    notifyListeners();
  }

  void setEnabled(bool on) {
    if (on == _enabled) return;
    _enabled = on;
    notifyListeners();
    // A failed save costs the choice at the next start, nothing more.
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setBool(_key, on))
          .catchError((Object _) => false),
    );
  }

  /// The sound of the move into [node], if sounds are on.
  void play(GameNode node) {
    if (!_enabled) return;
    final sound = moveSoundFor(node);
    if (sound != null) _player.play(sound);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

/// Hands [MoveSounds] to everything under it. Sits above the `MaterialApp`,
/// so pushed routes see it too.
class MoveSoundsScope extends InheritedNotifier<MoveSounds> {
  const MoveSoundsScope({
    super.key,
    required MoveSounds sounds,
    required super.child,
  }) : super(notifier: sounds);

  /// The sounds, or null with no scope mounted.
  static MoveSounds? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoveSoundsScope>()?.notifier;

  /// The sounds without listening, for event handlers.
  static MoveSounds? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MoveSoundsScope>()?.notifier;
}
