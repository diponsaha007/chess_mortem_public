import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../llm/explanation_prompt.dart';
import '../llm/move_explainer.dart';
import '../logging/app_log.dart';
import '../model/analysis_codec.dart';
import '../model/classification.dart';
import '../model/coach_flavor.dart' show CoachReaction;
import '../model/coach_line.dart';
import '../model/eval.dart';
import '../model/game_phase.dart';
import '../model/game_result.dart';
import '../model/game_tree.dart';
import '../model/opening_book.dart';
import '../model/repetition.dart';
import '../model/sides.dart';
import 'analysis_store.dart';

enum ExplanationStatus { idle, loading, ready, failed }

/// What the board says when the engine will not start: only a new process
/// fixes it.
const engineStartFailedMessage =
    "Engine couldn't start. Please reopen the app.";

/// The app's single shared state: the game tree, the cursor into it, and
/// analysis progress.
class AnalysisSession extends ChangeNotifier {
  AnalysisSession({
    required this.engine,
    this.searchDepth = 15,
    this.ranksAlternatives = true,
    this.book = const OpeningBook.empty(),
    this.playerName,
    this.store,
  });

  final ChessEngine engine;

  /// Where a game's analysis is kept between runs; null keeps nothing.
  final AnalysisStore? store;
  int searchDepth;

  /// Search the runner-up for Best moves, so Brilliant and Great can be
  /// awarded. Affects moves classified from now on.
  bool ranksAlternatives;

  final OpeningBook book;

  GameTree tree = GameTree.empty();

  /// The deepest named opening the game reached.
  String? openingName;

  /// The node shown on the board.
  late GameNode current = tree.root;

  String? loadError;

  /// Progress in POSITIONS: the root plus one per ply.
  int analyzedCount = 0;
  int totalToAnalyze = 0;
  bool get isAnalyzing => totalToAnalyze > 0 && analyzedCount < totalToAnalyze;

  /// The same progress in MOVES, for display.
  int get analyzedMoves => analyzedCount ~/ 2;
  int get totalMoves => totalToAnalyze ~/ 2;

  /// "Stockfish 16 · depth 15". The depth is read from the evals, not from
  /// [searchDepth], which only affects later searches.
  String get engineLabel {
    final depth = analyzedDepth;
    return depth == null ? engine.name : '${engine.name} · depth $depth';
  }

  /// The depth every analysed mainline move shares, or null if none or mixed.
  int? get analyzedDepth {
    final depths = tree.mainline
        .map((n) => n.eval?.depth)
        .whereType<int>()
        .toSet();
    return depths.length == 1 ? depths.single : null;
  }

  // PGN tags. Only these are read.
  String? get whitePlayer => tree.header('White');
  String? get blackPlayer => tree.header('Black');
  String? get whiteElo => tree.header('WhiteElo');
  String? get blackElo => tree.header('BlackElo');
  GameResult? get result => GameResult.parse(tree.header('Result'));

  /// The user's name as it appears in their PGNs.
  String? playerName;

  /// Which side the user played in this game. Never derived from board
  /// orientation.
  Side? get userSide =>
      sideOfPlayer(playerName, white: whitePlayer, black: blackPlayer);

  /// True when the key-move skip buttons walk only the user's moves.
  bool get reviewsOneSide => userSide != null;

  /// Phase boundaries, from the board BEFORE each mainline move.
  GameDivision get division {
    final positions = [tree.root, ...tree.mainline];
    if (positions.length < 2) return GameDivision.empty;
    return divide([
      for (final node in positions.take(positions.length - 1))
        node.position.board,
    ]);
  }

  // Explanation state per node. Failures are kept apart from
  // GameNode.explanation so a retry is possible.
  final Set<GameNode> _explaining = {};
  final Map<GameNode, String> _explanationErrors = {};

  /// Mistakes whose better line is already in the tree.
  final Set<GameNode> _betterLinesBuilt = Set.identity();

  /// Positions whose runner-up was searched, found or not.
  final Set<GameNode> _runnerUpSearched = Set.identity();

  /// Bumped when a new game replaces the tree, so work for the old one stops.
  int _generation = 0;

  /// The library entry the tree came from: the name its analysis is saved
  /// under. Null for a game that is not in the library.
  String? _gameId;

  /// The PGN text the tree was read from, as it was given: what Share sends.
  /// Null before a game is loaded and after one fails to parse.
  String? get pgn => _pgn;
  String? _pgn;

  /// Something worth saving was computed since the last save.
  bool _unsaved = false;

  /// The depth this game's mainline was searched at, saved with it: a game
  /// reopened at a HIGHER setting is analysed again.
  int _savedDepth = 0;

  /// Saves run one after another, so an older one never lands last.
  Future<void> _saves = Future.value();

  /// The cursor steps onto each move the sweep searches, so there is
  /// something to watch, and returns to the start when it ends. Any
  /// navigation or what-if move hands the cursor back to the user.
  bool _followingSweep = false;

  /// True while the cursor is still following the sweep.
  bool get followsSweep => _followingSweep;

  /// Leaves the cursor where it is for the rest of the sweep.
  void stopFollowing() => _followingSweep = false;

  /// Parses [pgn], replaces the game and runs the analysis sweep. Sets
  /// [loadError] instead of throwing. The tree is replaced before the first
  /// await, so a caller may push the board without waiting.
  ///
  /// With a [gameId] the analysis saved under it is read back first, so only
  /// what is missing is searched, and whatever is computed is saved again.
  Future<void> loadPgn(String pgn, {String? gameId}) async {
    try {
      tree = GameTree.fromPgn(pgn);
      _pgn = pgn;
      loadError = null;
    } catch (e) {
      // Arbitrary user input: whatever the parser throws, don't crash.
      _pgn = null;
      loadError = 'Could not read PGN: $e';
      notifyListeners();
      return;
    }
    current = tree.root;
    _explaining.clear();
    _explanationErrors.clear();
    _betterLinesBuilt.clear();
    _runnerUpSearched.clear();
    _followingSweep = false;
    _generation++;
    _gameId = gameId;
    _unsaved = false;
    _savedDepth = searchDepth;
    _tagOpening();
    notifyListeners();
    if (!await _restore()) return;
    await _analyzeMainline();
  }

  /// Reads the saved evals, runner-ups included, back onto the tree; the
  /// sweep recomputes the verdicts from them. False when another game was
  /// loaded meanwhile.
  Future<bool> _restore() async {
    final store = this.store;
    final id = _gameId;
    if (store == null || id == null) return true;
    final generation = _generation;
    final saved = await store.load(id);
    if (generation != _generation) return false;
    final searched = applyAnalysis(
      tree,
      saved,
      engineName: engine.name,
      minDepth: searchDepth,
    );
    if (searched == null) return true;
    _savedDepth = savedDepthOf(saved) ?? searchDepth;
    _runnerUpSearched.addAll(searched);
    _drawRestoredRepetitions();
    _classifyRestoredVariations();
    return true;
  }

  /// A saved search where a repetition ends the game (saved before the draw
  /// was read), replaced by the draw.
  void _drawRestoredRepetitions() {
    void visit(GameNode node) {
      final eval = node.eval;
      if (eval != null && eval.bestMoveUci != null && drawnByRepetition(node)) {
        node.eval = _drawEval();
        _unsaved = true;
      }
      node.children.forEach(visit);
    }

    visit(tree.root);
  }

  EngineEval _drawEval() =>
      EngineEval(cp: 0, bestMoveUci: null, depth: searchDepth);

  /// Verdicts for the restored what-if moves and better lines, which the
  /// sweep never visits. No runner-up search: whatever one found is already
  /// in the saved evals, and a better line never asks.
  void _classifyRestoredVariations() {
    final mainline = Set<GameNode>.identity()..addAll(tree.mainline);
    void visit(GameNode node) {
      if (!mainline.contains(node)) _classifyFromParent(node);
      node.children.forEach(visit);
    }

    visit(tree.root);
  }

  /// Saves the analysis if anything new was computed. Never throws: a
  /// failed save costs a re-analysis, nothing more.
  void _saveIfChanged() {
    final store = this.store;
    final id = _gameId;
    if (store == null || id == null || !_unsaved) return;
    _unsaved = false;
    // Encoded now, so a game loaded before the write starts is not mixed in.
    final analysis = encodeAnalysis(
      tree,
      engineName: engine.name,
      depth: _savedDepth,
      runnerUpSearched: _runnerUpSearched,
    );
    _saves = _saves.then((_) async {
      try {
        await store.save(id, analysis);
      } catch (e) {
        AppLog.instance.warn('analysis', 'could not save the analysis: $e');
      }
    });
  }

  /// Labels the book moves at the head of the mainline. Stops at the first
  /// position out of book, so a later transposition is not "theory".
  void _tagOpening() {
    openingName = null;
    if (book.isEmpty) return;
    var node = tree.root;
    while (node.children.isNotEmpty) {
      node = node.children.first;
      final name = book.nameFor(node.position);
      if (name == null) return;
      node.openingName = name;
      openingName = name;
    }
  }

  /// Searches in flight, so the sweep and a what-if move reaching the same
  /// position share one search.
  final Map<GameNode, Future<EngineEval>> _searching = {};

  /// Searches [node] unless it has an eval: the one call to
  /// `engine.evaluate`, so no position is searched twice. A repetition that
  /// ends the game is a draw, with nothing to search: the engine sees the
  /// position, not the game, so it would score the board as it stands.
  Future<void> _evaluate(GameNode node) async {
    if (node.eval != null) return;
    if (drawnByRepetition(node)) {
      node.eval = _drawEval();
      _unsaved = true;
      return;
    }
    final search = _searching[node] ??= engine.evaluate(
      node.position.fen,
      depth: searchDepth,
    );
    try {
      node.eval ??= await search;
    } finally {
      _searching.remove(node);
    }
    _unsaved = true;
  }

  /// Positions between saves during the sweep: closing the app mid-game
  /// loses at most this many.
  static const _saveEvery = 10;

  /// Evaluates the root and every mainline node, classifying as it goes.
  Future<void> _analyzeMainline() async {
    final generation = _generation;
    final mainline = tree.mainline;
    totalToAnalyze = mainline.length + 1;
    analyzedCount = 0;
    _followingSweep = true;
    notifyListeners();

    final clock = Stopwatch()..start();
    AppLog.instance.info(
      'analysis',
      'analysing $totalMoves moves at depth $searchDepth',
    );

    try {
      for (final node in [tree.root, ...mainline]) {
        // The file records the SHALLOWEST depth the mainline was searched at.
        final searched = node.eval == null;
        if (searched) _savedDepth = math.min(_savedDepth, searchDepth);
        await _evaluate(node);
        if (generation != _generation) return;
        await _classify(node);
        if (generation != _generation) return;
        analyzedCount++;
        if (analyzedCount % _saveEvery == 0) _saveIfChanged();
        // Only searched positions: restored ones would flash past in a frame.
        if (_followingSweep && searched) current = node;
        notifyListeners();
      }
      _saveIfChanged();
      if (_followingSweep) {
        _followingSweep = false;
        current = tree.root;
        notifyListeners();
      }
      AppLog.instance.info(
        'analysis',
        'analysed $totalMoves moves in ${formatDuration(clock.elapsed)}',
      );
    } catch (e) {
      // A search of an earlier game failing says nothing about this one.
      if (generation != _generation) return;
      AppLog.instance.error(
        'analysis',
        'stopped after $analyzedMoves of $totalMoves moves: $e',
      );
      // The cursor stays on the move where the sweep stopped.
      _followingSweep = false;
      loadError = e is EngineStartException
          ? engineStartFailedMessage
          : 'Analysis failed: $e';
      totalToAnalyze = 0;
      notifyListeners();
    }
  }

  /// A what-if move. Reuses an existing edge (no engine work) and evaluates
  /// otherwise. Moves the cursor either way.
  Future<GameNode> playMove(Move move) async {
    _followingSweep = false;
    final node = tree.addMove(current, move, isUserMove: true);
    current = node;
    notifyListeners();

    if (node.eval == null) {
      final generation = _generation;
      await _evaluate(node);
      if (generation != _generation) return node;
      await _classify(node);
      if (generation != _generation) return node;
      _saveIfChanged();
      notifyListeners();
    }
    return node;
  }

  /// Plays the engine's better line out as a variation under [node]'s
  /// parent. Mistakes or worse only, once per move.
  Future<void> ensureBetterLine(GameNode node) async {
    final parent = node.parent;
    if (parent == null || node.isBook) return;
    if (!(node.classification?.isMistakeOrWorse ?? false)) return;
    // Checked, not added, here: a call before the parent is evaluated must be
    // able to try again later.
    if (_betterLinesBuilt.contains(node)) return;

    final pv = parent.eval?.pvUci ?? const <String>[];
    if (pv.isEmpty || pv.first == node.move?.uci) return;
    final plies = node.betterKeyLine.length;
    if (plies < 2) return;

    final generation = _generation;
    var cursor = parent;
    final added = <GameNode>[];
    for (final uci in pv.take(plies)) {
      final move = Move.parse(uci);
      if (move == null || !cursor.position.isLegal(move)) break;
      cursor = tree.addMove(cursor, move);
      added.add(cursor);
    }
    if (added.length < 2) return;
    _betterLinesBuilt.add(node);
    notifyListeners();

    for (final line in added) {
      await _evaluate(line);
      if (generation != _generation) return;
      // The engine's own moves: no runner-up search for them.
      _classifyFromParent(line);
      notifyListeners();
    }
    _saveIfChanged();
  }

  /// Classifies [node], first searching its parent's runner-up when the
  /// verdict could be promoted. Once per parent.
  Future<void> _classify(GameNode node) async {
    _classifyFromParent(node);
    final parent = node.parent;
    final before = parent?.eval;
    final after = node.eval;
    if (!ranksAlternatives || parent == null) return;
    if (before == null || after == null || _runnerUpSearched.contains(parent)) {
      return;
    }
    if (!needsRunnerUp(
      before: before,
      after: after,
      mover: node.sideThatMoved,
      playedUci: node.move!.uci,
      positionBefore: parent.position,
    )) {
      return;
    }

    _runnerUpSearched.add(parent);
    _unsaved = true;
    final line = await engine.evaluateRunnerUp(
      parent.position.fen,
      searchMoves: runnerUpMoves(parent.position, before.bestMoveUci!),
      depth: runnerUpDepthFor(before.depth),
    );
    if (line == null || parent.eval != before) return;
    parent.eval = before.withRunnerUp(line);
    _classifyFromParent(node);
  }

  void _classifyFromParent(GameNode node) {
    final parent = node.parent;
    final before = parent?.eval;
    final after = node.eval;
    if (parent == null || before == null || after == null) return;
    node.classification = classify(
      before: before,
      after: after,
      mover: node.sideThatMoved,
      playedUci: node.move!.uci,
      positionBefore: parent.position,
      positionAfter: node.position,
      previousCaptureUci: parent.isCapture ? parent.move!.uci : null,
      beforeOpponentMove: parent.parent?.eval,
      opponentWasInCheck: parent.parent?.position.isCheck ?? false,
    );
  }

  // ---- Navigation ----

  void goToNode(GameNode node) {
    _followingSweep = false;
    current = node;
    notifyListeners();
  }

  bool get canGoBack => current.parent != null;
  bool get canGoForward => current.children.isNotEmpty;

  void goBack() {
    if (canGoBack) goToNode(current.parent!);
  }

  /// Follows `children[0]`.
  void goForward() {
    if (canGoForward) goToNode(current.children.first);
  }

  // ---- Key-move review ----

  GameNode? get nextKeyMove => _nextWhere(_keyMoveTest(), forward: true);

  GameNode? get previousKeyMove => _nextWhere(_keyMoveTest(), forward: false);

  /// The moves the skip buttons stop on: mistakes or worse, and Brilliant /
  /// Great. With no mistake to stop on, inaccuracies too, so a clean game
  /// still has something to review. Book moves never count, and only the
  /// user's own once [userSide] is known.
  bool Function(GameNode) _keyMoveTest() {
    final side = userSide;
    bool reviewable(GameNode node) =>
        !node.isBook &&
        node.classification != null &&
        (side == null || node.sideThatMoved == side);

    final hasMistakes = tree.mainline.any(
      (n) => reviewable(n) && n.classification!.isMistakeOrWorse,
    );
    return (node) {
      if (!reviewable(node)) return false;
      final c = node.classification!;
      return c.isMistakeOrWorse ||
          c == Classification.brilliant ||
          c == Classification.great ||
          (!hasMistakes && c == Classification.inaccuracy);
    };
  }

  /// Searches the mainline from [current] — or from where its variation
  /// branched off.
  GameNode? _nextWhere(bool Function(GameNode) test, {required bool forward}) {
    final mainline = tree.mainline;
    final onMainline = Set<GameNode>.identity()..addAll(mainline);

    var anchor = current;
    while (!anchor.isRoot && !onMainline.contains(anchor)) {
      anchor = anchor.parent!;
    }
    final index = anchor.isRoot ? -1 : mainline.indexOf(anchor);

    final range = forward
        ? mainline.skip(index + 1)
        : mainline.take(index < 0 ? 0 : index).toList().reversed;
    for (final node in range) {
      if (test(node)) return node;
    }
    return null;
  }

  // ---- Explanations ----

  /// The ONE line about [node], in the user's voice ("You" / "Your
  /// opponent") when [userSide] is known, unless [neutral] (sides by colour,
  /// for someone else to read). [playful] adds the reaction at big moments;
  /// the LLM is given the plain line.
  String coachLineFor(
    GameNode node, {
    bool playful = true,
    bool neutral = false,
  }) => coachLine(
    node,
    userSide: neutral ? null : userSide,
    phase: _phaseOf(node),
    playful: playful,
  );

  /// The big moment [node]'s line reacts to, in the same voice, or null:
  /// what the haptics read.
  CoachReaction? coachReactionFor(GameNode node) =>
      coachReaction(node, userSide: userSide, phase: _phaseOf(node));

  /// The phase [node]'s move is judged in; a variation has none of its own.
  GamePhase _phaseOf(GameNode node) =>
      node.isVariation ? GamePhase.middlegame : division.phaseAt(node.ply);

  /// Whether [node] has the engine data an explanation needs.
  bool canExplain(GameNode node) =>
      !node.isRoot &&
      node.classification != null &&
      node.eval != null &&
      node.parent?.eval != null;

  /// A failed "ask again" reads as failed even with an older answer kept,
  /// so its error and Retry show.
  ExplanationStatus explanationStatus(GameNode node) {
    if (_explaining.contains(node)) return ExplanationStatus.loading;
    if (_explanationErrors.containsKey(node)) return ExplanationStatus.failed;
    if (node.explanation != null) return ExplanationStatus.ready;
    return ExplanationStatus.idle;
  }

  String? explanationError(GameNode node) => _explanationErrors[node];

  /// Fetches and caches the explanation for [node] (default: [current]).
  /// Only a success is cached on the node. A cached answer is kept unless
  /// [again] — the user asking again, often of another model — and even
  /// then it is replaced only by a new answer, never by a failure.
  Future<void> fetchExplanation(
    MoveExplainer explainer, {
    GameNode? node,
    bool again = false,
  }) async {
    final target = node ?? current;
    if (!canExplain(target)) return;
    if (_explaining.contains(target)) return;
    if (target.explanation != null && !again) return;

    final generation = _generation;
    _explaining.add(target);
    _explanationErrors.remove(target);
    notifyListeners();
    try {
      target.explanation = await explainer.explainMove(
        buildExplanationContext(
          node: target,
          before: target.parent!.eval!,
          after: target.eval!,
          coachLine: coachLineFor(target, playful: false),
        ),
      );
      // Another game is open now; its file is not this answer's.
      if (generation != _generation) return;
      _unsaved = true;
      _saveIfChanged();
    } catch (e) {
      // Catch-all: malformed JSON can throw an Error, and the user should
      // get a Retry button either way.
      _explanationErrors[target] = e is TimeoutException
          ? 'The request timed out.'
          : e.toString();
    } finally {
      _explaining.remove(target);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    engine.dispose();
    super.dispose();
  }
}
