import 'dart:async';
import 'dart:io' show Directory;
import 'dart:math' as math;

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../analysis/analysis_session.dart';
import '../appearance/appearance_controller.dart';
import '../appearance/board_appearance.dart';
import '../feedback/haptics.dart';
import '../feedback/move_sounds.dart';
import '../llm/llm_config.dart';
import '../llm/llm_config_store.dart';
import '../llm/move_explainer.dart';
import '../llm/openai_explainer.dart';
import '../logging/app_log.dart';
import '../model/coach_emoji.dart';
import '../model/game_tree.dart';
import '../model/pv_line.dart';
import '../model/sides.dart';
import '../platform/share_game.dart';
import '../share/game_gif.dart';
import '../widgets/app_bar_parts.dart';
import '../widgets/coach_bar.dart';
import '../widgets/eval_bar.dart';
import '../widgets/explanation_sheet.dart';
import '../widgets/material_bar.dart';
import '../widgets/move_list.dart';
import '../widgets/share_sheet.dart';
import 'app_routes.dart';
import 'summary_screen.dart';

/// The verdict badge over the board, told apart from the identical ones in
/// the strips and coach bar.
const boardVerdictBadgeKey = ValueKey('boardVerdictBadge');
const boardReactionEmojiKey = ValueKey('boardReactionEmoji');

MoveExplainer _openAiExplainer(LlmCredential credential) =>
    OpenAiCompatExplainer(credential: credential);

/// The analysis screen: eval bar, board, move strips, coach bar and
/// navigation. Renders session state and forwards intents.
class BoardScreen extends StatefulWidget {
  const BoardScreen({
    super.key,
    required this.session,
    required this.configStore,
    this.explainerFactory = _openAiExplainer,
    this.sharer,
    this.cacheDirectory = getTemporaryDirectory,
  });

  final AnalysisSession session;
  final LlmConfigStore configStore;

  /// Builds the explainer from the active key; injectable for tests.
  final MoveExplainer Function(LlmCredential credential) explainerFactory;

  /// Hands the game to the share sheet; injectable for tests.
  final GameSharer? sharer;

  /// Where a shared GIF is written; injectable for tests.
  final Future<Directory> Function() cacheDirectory;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

/// Runs an action for a node after 350 ms, unless it is re-scheduled first.
class _Debounced {
  Timer? _timer;
  GameNode? _pending;

  bool isQueuedFor(GameNode node) =>
      identical(_pending, node) && (_timer?.isActive ?? false);

  void schedule(GameNode node, void Function() action) {
    cancel();
    _pending = node;
    _timer = Timer(const Duration(milliseconds: 350), action);
  }

  void cancel() {
    _timer?.cancel();
    _pending = null;
  }
}

class _BoardScreenState extends State<BoardScreen> {
  late final ChessboardController _boardController;

  /// Which side is at the bottom. View state only; starts on the user's
  /// side and returns there for each new game.
  Side _orientation = Side.white;

  /// The tree [_orientation] was chosen for: a new tree means a new game.
  GameTree? _orientedFor;

  /// ONE explainer, built on first use and reused until Settings changes.
  /// Resolves to null without an API key.
  Future<MoveExplainer?>? _explainer;

  final _betterLine = _Debounced();

  /// The buzz at a big moment waits for the cursor to rest, so stepping
  /// past a blunder stays still.
  final _reaction = _Debounced();

  /// The node the cursor rests on, and whether it has buzzed there.
  GameNode? _restingOn;
  bool _reactedHere = false;

  /// The face above the board, shown with the buzz while the cursor stays.
  String? _emoji;

  AnalysisSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _boardController = ChessboardController(game: _gameData());
    _orientedFor = session.tree;
    _orientation = session.userSide ?? Side.white;
    session.addListener(_onSessionChanged);
    _scheduleBetterLine();
  }

  @override
  void dispose() {
    _betterLine.cancel();
    _reaction.cancel();
    _discardExplainer();
    session.removeListener(_onSessionChanged);
    _boardController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    _faceTheUser();
    _scheduleBetterLine();
    _scheduleReaction();
    final game = _gameData();
    // Evals streaming in notify without moving the cursor.
    if (game.fen == _boardController.fen &&
        game.lastMove == _boardController.lastMove) {
      return;
    }
    _boardController.updatePosition(
      game,
      // Animate one step; jump when tapping a distant move.
      animate: _isOneStepFromBoard(session.current),
      resetPremove: true,
    );
  }

  bool _isOneStepFromBoard(GameNode node) {
    final shown = _boardController.fen;
    if (node.parent?.position.fen == shown) return true;
    return node.children.any((child) => child.position.fen == shown);
  }

  GameData _gameData() {
    final node = session.current;
    return GameData(
      fen: node.position.fen,
      lastMove: node.move,
      sideToMove: node.position.turn,
      playerSide: PlayerSide.both, // any position can take a what-if move
      validMoves: session.acceptsMoves
          ? makeLegalMoves(node.position)
          : const {},
      kingSquareInCheck: node.position.isCheck
          ? node.position.board.kingOf(node.position.turn)
          : null,
    );
  }

  void _flipBoard() => setState(() => _orientation = _orientation.opposite);

  /// Turns the board to the user's side once per game.
  void _faceTheUser() {
    if (identical(_orientedFor, session.tree)) return;
    _orientedFor = session.tree;
    _turnTo(session.userSide ?? Side.white);
  }

  void _turnTo(Side side) {
    if (side == _orientation) return;
    setState(() => _orientation = side);
  }

  /// Builds the "should have played" branch for the move on screen.
  /// Scheduled, not called from the listener, because it notifies, and
  /// notifying inside a notification is a concurrent modification. Not
  /// while the board follows the sweep: the branch would queue engine
  /// searches for every mistake it passes.
  void _scheduleBetterLine() {
    if (session.followsSweep) {
      _betterLine.cancel();
      return;
    }
    final node = session.current;
    if (_betterLine.isQueuedFor(node)) return;
    _betterLine.schedule(node, () => unawaited(session.ensureBetterLine(node)));
  }

  /// Buzzes for a big moment once the cursor rests on it, once per arrival.
  /// A what-if move reacts when its eval arrives, if the user is still
  /// there. Never while the board follows the sweep, which steps through
  /// every position by itself.
  void _scheduleReaction() {
    final node = session.current;
    if (!identical(node, _restingOn)) {
      _restingOn = node;
      _reactedHere = false;
      if (_emoji != null) setState(() => _emoji = null);
    }
    if (session.followsSweep) {
      _reaction.cancel();
      _reactedHere = true;
      return;
    }
    if (_reactedHere || _reaction.isQueuedFor(node)) return;
    if (session.coachReactionFor(node) == null) {
      _reaction.cancel();
      return;
    }
    _reaction.schedule(node, () => _react(node));
  }

  void _react(GameNode node) {
    if (!mounted || !identical(session.current, node)) return;
    if (session.followsSweep) return;
    final reaction = session.coachReactionFor(node);
    if (reaction == null) return;
    _reactedHere = true;
    Haptics.react(reaction);
    setState(() => _emoji = reactionEmoji(reaction));
  }

  /// Asks the LLM to expand on [node]'s coach line, offering Settings when
  /// there is no key. Asks again over an old answer: the key may have changed.
  Future<void> _explainMore(GameNode node) async {
    final explainer = await _explainerOrPromptForKey();
    if (explainer == null || !mounted) return;
    await session.fetchExplanation(
      explainer,
      node: node,
      again: node.explanation != null,
    );
  }

  /// The explainer, or null when no key is set. Never prompts.
  Future<MoveExplainer?> _explainerIfConfigured() =>
      _explainer ??= _loadExplainer();

  Future<MoveExplainer?> _loadExplainer() async {
    final LlmConfig config;
    try {
      config = await widget.configStore.load();
    } catch (_) {
      return null; // no keystore on this device: same as no key
    }
    return config.hasApiKey ? widget.explainerFactory(config.active!) : null;
  }

  /// The explainer, offering Settings when there is no key.
  Future<MoveExplainer?> _explainerOrPromptForKey() async {
    final explainer = await _explainerIfConfigured();
    if (!mounted) return null;
    if (explainer != null) return explainer;

    final goToSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No API key'),
        content: const Text(
          'Detailed explanations come from an AI model. Set up a free key. '
          'Settings shows you how.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (!mounted) return null;
    if (goToSettings == true) unawaited(_openSettings());
    return null;
  }

  /// Drops the cached explainer, so the next request rebuilds it from the
  /// current config, and disposes it once it is built.
  void _discardExplainer() {
    final explainer = _explainer;
    _explainer = null;
    if (explainer != null) unawaited(explainer.then((e) => e?.dispose()));
  }

  /// Opens the explanation sheet for the current move. It always opens: the
  /// coach line needs no key. The LLM is asked only from the sheet's
  /// "Explain more".
  Future<void> _showExplanation() async {
    // Captured up front, so a slow answer lands on the move asked about.
    final node = session.current;
    if (!session.canExplain(node)) return;
    // The board stays on the move the sheet is about.
    session.stopFollowing();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => ExplanationSheet(
          moveLabel: _moveLabel(node),
          summaryLine: session.coachLineFor(node),
          status: session.explanationStatus(node),
          explanation: node.explanation?.detail,
          explainedBy: node.explanation?.model,
          errorDetail: session.explanationError(node),
          betterLine: _betterLineText(node),
          onRetry: () => _explainMore(node),
        ),
      ),
    );
  }

  /// The line that should have been played, for a mistake or worse only —
  /// an inaccuracy's "Best:" hint already says enough. Null when one move
  /// long.
  String? _betterLineText(GameNode node) {
    final parent = node.parent;
    if (parent == null) return null;
    if (node.classification?.isMistakeOrWorse != true) return null;
    final line = node.betterKeyLine;
    if (line.length < 2) return null;
    return formatLine(line, startingPly: parent.ply);
  }

  String _moveLabel(GameNode node) {
    final verdict = node.classification?.label;
    final played = '${sideName(node.sideThatMoved)} played ${node.san}';
    return verdict == null ? played : '$played · $verdict';
  }

  Future<void> _openSettings() async {
    await openSettings(
      context,
      session: session,
      configStore: widget.configStore,
      // Naming yourself turns the board to your side.
      onPlayerNameChanged: () {
        if (!mounted) return;
        setState(() {});
        final side = session.userSide;
        if (side != null) _turnTo(side);
      },
    );
    if (!mounted) return;
    // The key may have changed.
    _discardExplainer();
  }

  /// Asks PGN or GIF where a file can be shared; elsewhere sends the PGN.
  Future<void> _share() async {
    final sharer = widget.sharer ?? GameSharer();
    if (!sharer.sharesFiles) return _sharePgn(sharer);
    final format = await showShareFormatSheet(
      context,
      gifReady: !session.isAnalyzing,
    );
    if (!mounted) return;
    switch (format) {
      case ShareFormat.pgn:
        await _sharePgn(sharer);
      case ShareFormat.gif:
        await _shareGif(sharer);
      case null:
        return;
    }
  }

  /// "White vs Black", where the PGN names both.
  String? get _shareSubject {
    final white = session.tree.header('White');
    final black = session.tree.header('Black');
    return white != null && black != null ? '$white vs $black' : null;
  }

  /// Shares the game as it was imported. Where there is no share sheet, it
  /// is copied instead, so the action still does something.
  Future<void> _sharePgn(GameSharer sharer) async {
    final pgn = session.pgn;
    if (pgn == null) return;
    if (await sharer.share(pgn, subject: _shareSubject)) return;
    await Clipboard.setData(ClipboardData(text: pgn));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('PGN copied')));
  }

  /// Renders the mainline as a GIF behind a progress dialog, then shares the
  /// file. Closing the dialog cancels.
  Future<void> _shareGif(GameSharer sharer) async {
    final export = GameGifExport(
      session.tree,
      orientation: _orientation,
      appearance: AppearanceScope.of(context),
      // Read by someone else: sides by colour, not "You".
      coachLineFor: (node) => session.coachLineFor(node, neutral: true),
    );
    final navigator = Navigator.of(context);
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            GifProgressDialog(progress: export.progress, total: export.total),
      ).whenComplete(() {
        dialogOpen = false;
        export.cancel();
      }),
    );

    String? failure;
    try {
      final bytes = await export.render();
      if (dialogOpen) navigator.pop();
      if (bytes == null || !mounted) return;
      final file = await writeSharedFile(
        await widget.cacheDirectory(),
        gifFileName(session.tree.header('White'), session.tree.header('Black')),
        bytes,
      );
      final shown = await sharer.shareFile(
        file.path,
        mimeType: 'image/gif',
        subject: _shareSubject,
      );
      if (!shown) failure = 'Could not open the share sheet';
    } catch (e) {
      AppLog.instance.error('share', 'GIF failed: $e');
      if (dialogOpen) navigator.pop();
      failure = 'Could not make the GIF';
    }
    if (failure == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(failure)));
  }

  void _openSummary() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SummaryScreen(
          session: session,
          perspective: _orientation,
          // Picking a player card there flips the board here.
          onPerspectiveChanged: _turnTo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppTitle(
          trailing: [
            if (session.isAnalyzing) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text(
                '${session.analyzedMoves}/${session.totalMoves}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ],
        ),
        // Three icons: more overflows a narrow phone.
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_vert),
            tooltip: 'Flip board',
            onPressed: _flipBoard,
          ),
          IconButton(
            icon: const Icon(Icons.assessment_outlined),
            tooltip: 'Game summary',
            onPressed: _openSummary,
          ),
          AppMenu(
            onShare: session.pgn == null ? null : () => unawaited(_share()),
            onSettings: () => unawaited(_openSettings()),
          ),
        ],
      ),
      // Android draws the nav bar over the app; keep the board clear of it.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => _body(constraints),
        ),
      ),
    );
  }

  Widget _body(BoxConstraints constraints) {
    final node = session.current;
    final board = _BoardBlock(
      controller: _boardController,
      node: node,
      orientation: _orientation,
      onMove: (move) {
        Haptics.tap();
        session.playMove(move);
        _playSound();
      },
      session: session,
      emoji: _emoji,
    );
    final controls = _NavigationRow(
      session: session,
      onExplain: _showExplanation,
      onMoved: _playSound,
    );
    final moves = MoveList(
      tree: session.tree,
      current: node,
      onTap: (target) {
        Haptics.tap();
        session.goToNode(target);
        _playSound();
      },
    );
    final coach = CoachBar(
      node: node,
      line: session.coachLineFor(node),
      onTap: _showExplanation,
    );

    // Landscape puts the moves beside the board.
    final isWide = constraints.maxWidth > constraints.maxHeight;

    return Column(
      children: [
        if (session.loadError != null) _loadErrorBanner(),
        _progressSlot(),
        if (isWide)
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 3, child: board),
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(child: SingleChildScrollView(child: moves)),
                      const Divider(height: 1),
                      coach,
                      controls,
                    ],
                  ),
                ),
              ],
            ),
          )
        else ...[
          // Everything below is intrinsically sized; the board takes the rest.
          Expanded(child: board),
          const Divider(height: 1),
          moves,
          const Divider(height: 1),
          coach,
          controls,
        ],
      ],
    );
  }

  /// The click of the move now on the board, after a step the user took.
  void _playSound() => MoveSoundsScope.read(context)?.play(session.current);

  Widget _loadErrorBanner() => MaterialBanner(
    content: Text(
      session.loadError!,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
    actions: [
      TextButton(
        onPressed: () => unawaited(Navigator.of(context).maybePop()),
        child: const Text('Back to games'),
      ),
    ],
  );

  /// Fixed height, so the layout does not jump when analysis ends.
  Widget _progressSlot() => SizedBox(
    height: 4,
    child: session.isAnalyzing
        ? LinearProgressIndicator(
            value: (session.analyzedCount / session.totalToAnalyze).clamp(
              0.0,
              1.0,
            ),
          )
        : null,
  );
}

/// The eval bar, board and material strips, sized to fit BOTH dimensions.
class _BoardBlock extends StatelessWidget {
  const _BoardBlock({
    required this.controller,
    required this.node,
    required this.orientation,
    required this.onMove,
    required this.session,
    this.emoji,
  });

  final ChessboardController controller;
  final GameNode node;
  final Side orientation;
  final void Function(Move move) onMove;

  /// For the players' names.
  final AnalysisSession session;

  /// The reaction face, drawn in the room above the board if there is any.
  final String? emoji;

  /// Less room than this above the board and the face goes beside it; less
  /// there too and it is left out.
  static const double _minEmojiRoom = 28;

  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The material strips are inside the budget.
        final size = math.min(
          constraints.maxWidth - EvalBar.width - _gap,
          constraints.maxHeight - 2 * MaterialBar.height,
        );
        if (size <= 0) return const SizedBox.shrink();
        final board = node.position.board;
        final face = emoji;
        // A Stack whether or not there is a face, so showing one never
        // remounts the board. The face takes no room from it.
        return Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _materialStrip(board, orientation.opposite, size),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EvalBar(
                        eval: node.eval,
                        height: size,
                        orientation: orientation,
                      ),
                      const SizedBox(width: _gap),
                      // Our own badge over the board, not chessground's.
                      SizedBox(
                        width: size,
                        height: size,
                        child: Stack(
                          children: [
                            Chessboard(
                              controller: controller,
                              size: size,
                              orientation: orientation,
                              settings: boardSettingsFor(
                                AppearanceScope.of(context),
                              ),
                              onMove: (move, {viaDragAndDrop}) => onMove(move),
                              shapes: _arrows(node),
                            ),
                            ..._verdictBadge(node, size, orientation),
                          ],
                        ),
                      ),
                    ],
                  ),
                  _materialStrip(board, orientation, size),
                ],
              ),
            ),
            if (face != null) ?_emojiSlot(face, constraints, size),
          ],
        );
      },
    );
  }

  /// Where the face goes: above the board (portrait), else in the gap to its
  /// right (landscape), else nowhere. Never in the board's own space.
  Widget? _emojiSlot(String face, BoxConstraints constraints, double size) {
    final above = (constraints.maxHeight - size - 2 * MaterialBar.height) / 2;
    final beside = (constraints.maxWidth - EvalBar.width - _gap - size) / 2;
    Widget emoji(double room) => Center(
      child: _ReactionEmoji(
        key: boardReactionEmojiKey,
        node: node,
        emoji: face,
        size: math.min(room * 0.7, 48),
      ),
    );
    if (above >= _minEmojiRoom) {
      // Centred over the board, not the eval bar beside it.
      return Positioned(
        top: 0,
        height: above,
        left: EvalBar.width + _gap,
        right: 0,
        child: emoji(above),
      );
    }
    if (beside >= _minEmojiRoom) {
      return Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: beside,
        child: emoji(beside),
      );
    }
    return null;
  }

  Widget _materialStrip(Board board, Side side, double size) => Padding(
    padding: const EdgeInsets.only(left: EvalBar.width + _gap),
    child: MaterialBar(
      board: board,
      side: side,
      name: side == Side.white ? session.whitePlayer : session.blackPlayer,
      rating: side == Side.white ? session.whiteElo : session.blackElo,
      width: size,
    ),
  );
}

/// The face, popping in once per arrival on [node].
class _ReactionEmoji extends StatelessWidget {
  const _ReactionEmoji({
    super.key,
    required this.node,
    required this.emoji,
    required this.size,
  });

  final GameNode node;
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ObjectKey(node),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Text(
        emoji,
        style: TextStyle(fontSize: size, height: 1),
        textHeightBehavior: const TextHeightBehavior(
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

Set<Shape> _arrows(GameNode node) => {
  ..._improvementArrow(node),
  ..._replyArrow(node),
};

/// Green: what should have been played instead — the PARENT's eval.
Set<Shape> _improvementArrow(GameNode node) {
  final bestUci = node.engineMoveUci;
  if (bestUci == null || node.isEngineMove) return const {};
  final best = Move.parse(bestUci);
  if (best is! NormalMove) return const {};
  return {
    Arrow(
      color: Colors.lightGreen.withValues(alpha: 0.75),
      orig: best.from,
      dest: best.to,
    ),
  };
}

/// Blue: the opponent's best reply — this node's own eval.
Set<Shape> _replyArrow(GameNode node) {
  final replyUci = node.replyMoveUci;
  if (replyUci == null) return const {};
  final reply = Move.parse(replyUci);
  if (reply is! NormalMove) return const {};
  return {
    Arrow(
      color: Colors.lightBlueAccent.withValues(alpha: 0.75),
      orig: reply.from,
      dest: reply.to,
    ),
  };
}

/// The verdict badge at the top-right of the landing square, nudged inside
/// the board on the edge squares.
List<Widget> _verdictBadge(GameNode node, double size, Side orientation) {
  final square = node.landingSquare;
  if (square == null) return const [];
  final classification = node.classification;
  if (!node.isBook && classification == null) return const [];

  final squareSize = size / 8;
  final badge = squareSize * 0.46;
  final file = orientation == Side.white
      ? square.file.value
      : 7 - square.file.value;
  final rank = orientation == Side.white
      ? 7 - square.rank.value
      : square.rank.value;
  final left = (file * squareSize + squareSize - badge * 0.72).clamp(
    0.0,
    size - badge,
  );
  final top = (rank * squareSize - badge * 0.28).clamp(0.0, size - badge);

  return [
    Positioned(
      key: boardVerdictBadgeKey,
      left: left,
      top: top,
      width: badge,
      height: badge,
      child: node.isBook
          ? BookBadge(size: badge, disc: true)
          : ClassificationBadge(classification: classification!, size: badge),
    ),
  ];
}

/// Move navigation plus the explain action.
class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.session,
    required this.onExplain,
    required this.onMoved,
  });

  final AnalysisSession session;
  final VoidCallback onExplain;

  /// After each step: the move's sound.
  final VoidCallback onMoved;

  static const _padding = EdgeInsets.all(12);
  static const _iconSize = 28.0;

  @override
  Widget build(BuildContext context) {
    final node = session.current;
    final status = session.explanationStatus(node);
    final nextKeyMove = session.nextKeyMove;
    final previousKeyMove = session.previousKeyMove;
    final mine = session.reviewsOneSide;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_double_arrow_left),
            iconSize: _iconSize,
            padding: _padding,
            tooltip: mine ? 'Your previous key move' : 'Previous key move',
            onPressed: previousKeyMove == null
                ? null
                : () {
                    Haptics.step();
                    session.goToNode(previousKeyMove);
                    onMoved();
                  },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            iconSize: _iconSize,
            padding: _padding,
            tooltip: 'Previous move',
            onPressed: session.canGoBack
                ? () {
                    Haptics.tap();
                    session.goBack();
                    onMoved();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            iconSize: _iconSize,
            padding: _padding,
            tooltip: 'Next move',
            onPressed: session.canGoForward
                ? () {
                    Haptics.tap();
                    session.goForward();
                    onMoved();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_double_arrow_right),
            iconSize: _iconSize,
            padding: _padding,
            tooltip: mine ? 'Your next key move' : 'Next key move',
            onPressed: nextKeyMove == null
                ? null
                : () {
                    Haptics.step();
                    session.goToNode(nextKeyMove);
                    onMoved();
                  },
          ),
          // Greyed out while loading, never swapped for a spinner.
          IconButton.filled(
            iconSize: _iconSize,
            padding: _padding,
            tooltip: 'Why this move?',
            onPressed:
                status == ExplanationStatus.loading || !session.canExplain(node)
                ? null
                : onExplain,
            icon: Icon(
              status == ExplanationStatus.failed
                  ? Icons.error_outline
                  : Icons.psychology_alt,
            ),
          ),
        ],
      ),
    );
  }
}
