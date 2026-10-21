import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../analysis/analysis_session.dart';
import '../feedback/haptics.dart';
import '../llm/llm_config_store.dart';
import '../model/game_library.dart';
import '../model/game_result.dart';
import '../model/hint_store.dart';
import '../model/saved_game.dart';
import '../model/sides.dart';
import '../platform/incoming_pgn.dart';
import '../widgets/app_bar_parts.dart';
import '../widgets/safe_bottom.dart';
import '../widgets/side_marks.dart';
import 'app_routes.dart';
import 'board_screen.dart';

/// The home screen: paste a PGN, or reopen a saved one.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.session,
    required this.configStore,
    required this.library,
    this.hints = const HintStore(),
    this.incoming,
  });

  final AnalysisSession session;
  final LlmConfigStore configStore;
  final GameLibrary library;

  /// Which one-time hints were dismissed.
  final HintStore hints;

  /// PGNs shared into the app or opened with it; null where nothing can be.
  final IncomingPgn? incoming;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  AnalysisSession get session => widget.session;
  GameLibrary get library => widget.library;

  /// The "set your name" card: until a name is set or it is dismissed.
  /// Hidden until the store has answered, so it never flashes.
  bool _nameHintDismissed = true;

  bool get _showsNameHint =>
      !_nameHintDismissed && (session.playerName?.trim().isEmpty ?? true);

  @override
  void initState() {
    super.initState();
    unawaited(_loadHints());
    unawaited(widget.incoming?.listen(_receive));
  }

  @override
  void dispose() {
    widget.incoming?.stop();
    super.dispose();
  }

  Future<void> _loadHints() async {
    final dismissed = await widget.hints.isNameHintDismissed();
    if (mounted) setState(() => _nameHintDismissed = dismissed);
  }

  void _dismissNameHint() {
    setState(() => _nameHintDismissed = true);
    unawaited(widget.hints.dismissNameHint());
  }

  /// A PGN shared into the app or opened with it: saved and opened like a
  /// pasted one, over whatever screen was showing.
  Future<void> _receive(String text) async {
    final game = await library.add(text);
    if (!mounted) return;
    if (game == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That could not be read as a PGN of a whole game.'),
        ),
      );
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    _open(game);
  }

  /// Loads [game] and pushes the board. `loadPgn` is NOT awaited — it awaits
  /// the whole sweep, and the board should show while the engine works.
  void _open(SavedGame game) {
    unawaited(library.touch(game));
    unawaited(session.loadPgn(game.pgn, gameId: game.id));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            BoardScreen(session: session, configStore: widget.configStore),
      ),
    );
  }

  /// Pastes a PGN and, if it is one, opens it.
  Future<void> _paste() async {
    final game = await showDialog<SavedGame>(
      context: context,
      builder: (_) => _PasteDialog(library: library),
    );
    if (game != null && mounted) _open(game);
  }

  /// Confirms, then offers Undo: the PGN may be the user's only copy.
  Future<void> _delete(SavedGame game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete game?'),
        content: Text(
          '${_titleOf(game)} and its analysis will be removed from your '
          'library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    Haptics.step();
    await library.remove(game);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed ${_titleOf(game)}'),
        // A snackbar with an action stays until tapped unless told
        // otherwise; Undo is a few seconds' chance, not a standing prompt.
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(library.restore(game)),
        ),
      ),
    );
  }

  /// The name decides the YOU chip on every card, so the list rebuilds.
  Future<void> _openSettings() => openSettings(
    context,
    session: session,
    configStore: widget.configStore,
    onPlayerNameChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AppTitle(),
        actions: [AppMenu(onSettings: () => unawaited(_openSettings()))],
      ),
      body: ListenableBuilder(
        listenable: library,
        builder: (context, _) =>
            library.isEmpty ? _empty(context) : _list(context),
      ),
      // The empty state has its own button.
      floatingActionButton: ListenableBuilder(
        listenable: library,
        builder: (context, _) => library.isEmpty
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: _paste,
                icon: const Icon(Icons.add),
                label: const Text('Paste PGN'),
              ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final games = library.games;
    return ListView.separated(
      // The bottom pad clears the floating button.
      padding: withSafeBottom(
        context,
        const EdgeInsets.fromLTRB(12, 6, 12, 88),
      ),
      itemCount: games.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_showsNameHint)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _NameHint(
                    onSetName: () => unawaited(_openSettings()),
                    onDismiss: _dismissNameHint,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
                child: Text(
                  'RECENT GAMES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          );
        }
        final game = games[index - 1];
        return _GameCard(
          game: game,
          playerName: session.playerName,
          onOpen: () => _open(game),
          onDelete: () => unawaited(_delete(game)),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: withSafeBottom(context, const EdgeInsets.all(44)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainer,
              ),
              child: Icon(
                Icons.inbox_outlined,
                size: 30,
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Text('No games yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Paste a PGN from any site you play on. It will be saved and '
              'analysed here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.add),
              label: const Text('Paste PGN'),
            ),
          ],
        ),
      ),
    );
  }

  String _titleOf(SavedGame game) =>
      '${game.white ?? 'White'} vs ${game.black ?? 'Black'}';
}

const nameHintKey = ValueKey('libraryNameHint');

/// The one-time nudge to set a name: what it changes, and the way there.
/// Gone for good once dismissed or once a name is set.
class _NameHint extends StatelessWidget {
  const _NameHint({required this.onSetName, required this.onDismiss});

  final VoidCallback onSetName;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: nameHintKey,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Which player are you?',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Add your name as it is in your PGNs to review from your side.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDismiss, child: const Text('Not now')),
                TextButton(onPressed: onSetName, child: const Text('Set name')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Paste a PGN; an unreadable one is refused with the reason under the field.
/// Stateful so the controller is disposed only once the dialog unmounts.
class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.library});

  final GameLibrary library;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _controller = TextEditingController();
  String? _error;

  /// A second tap while saving would pop twice: this dialog, then the board.
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    _submitting = true;
    final added = await widget.library.add(_controller.text);
    if (!mounted) return;
    if (added == null) {
      setState(() {
        _submitting = false;
        _error = 'That PGN could not be read.';
      });
      return;
    }
    Navigator.pop(context, added);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste PGN'),
      content: TextField(
        controller: _controller,
        maxLines: 8,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Paste a PGN here',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => unawaited(_submit()),
          child: const Text('Analyze'),
        ),
      ],
    );
  }
}

/// One saved game: a line per player (winner bold, loser dimmed) and the
/// result in digits and words.
class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.game,
    required this.playerName,
    required this.onOpen,
    required this.onDelete,
  });

  final SavedGame game;
  final String? playerName;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(14);
    final userSide = game.userSide(playerName);
    final result = game.result;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: radius,
      child: InkWell(
        onTap: onOpen,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _PlayerLine(
                          side: Side.white,
                          name: game.white,
                          elo: game.whiteElo,
                          isYou: userSide == Side.white,
                          result: result,
                        ),
                        const SizedBox(height: 4),
                        _PlayerLine(
                          side: Side.black,
                          name: game.black,
                          elo: game.blackElo,
                          isYou: userSide == Side.black,
                          result: result,
                        ),
                      ],
                    ),
                  ),
                  if (result != null) ...[
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            result.label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _outcomeWord(result, userSide),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${game.moveCount} moves · '
                      '${libraryTimeLabel(game.lastOpenedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  // Constrained so the 48 px tap target does not set the
                  // card's height.
                  SizedBox(
                    width: 36,
                    height: 32,
                    child: IconButton(
                      onPressed: onDelete,
                      padding: EdgeInsets.zero,
                      iconSize: 19,
                      tooltip: 'Delete game',
                      icon: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// From the user's side when known, by colour otherwise.
  static String _outcomeWord(GameResult result, Side? userSide) {
    if (result.isDraw) return 'DRAWN';
    if (userSide == null) {
      return result == GameResult.whiteWon ? 'WHITE WON' : 'BLACK WON';
    }
    return result.wonBy(userSide) ? 'YOU WON' : 'YOU LOST';
  }
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({
    required this.side,
    required this.name,
    required this.elo,
    required this.isYou,
    required this.result,
  });

  final Side side;
  final String? name;
  final String? elo;
  final bool isYou;
  final GameResult? result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final won = result?.wonBy(side) ?? false;
    final lost = result != null && !result!.isDraw && !won;
    return Row(
      children: [
        SideDot(side: side),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            name ?? sideName(side),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: lost ? theme.colorScheme.outline : null,
              fontWeight: won ? FontWeight.w600 : null,
            ),
          ),
        ),
        if (elo != null) ...[
          const SizedBox(width: 6),
          Text(
            elo!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        if (isYou) ...[const SizedBox(width: 6), const YouChip()],
      ],
    );
  }
}

/// How long ago a game was last opened, roughly.
String libraryTimeLabel(DateTime when, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(when);
  if (delta.inMinutes < 1) return 'Just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} ${delta.inHours == 1 ? 'hour' : 'hours'} ago';
  }
  if (delta.inDays == 1) return 'Yesterday';
  if (delta.inDays < 7) return '${delta.inDays} days ago';
  if (delta.inDays < 14) return 'Last week';
  if (delta.inDays < 60) return '${delta.inDays ~/ 7} weeks ago';
  final months = delta.inDays ~/ 30;
  return months < 12 ? '$months months ago' : 'Over a year ago';
}
