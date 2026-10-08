/// Engine configuration, kept pure and out of [StockfishEngine] so it can be
/// tested (the plugin singleton cannot be injected).
library;

/// Embedded net: the default and the fallback.
const bundledEngineName = 'Stockfish 16';

/// Opt-in; its ~80 MB of nets are downloaded by `NnueAssets`.
const latestEngineName = 'Stockfish 18';

/// The engine a `useLatestEngine` setting selects, for Settings, which has no
/// engine instance to ask.
String engineNameFor({required bool useLatest}) =>
    useLatest ? latestEngineName : bundledEngineName;

/// Search threads for [cores] CPUs (Stockfish defaults to one). Two cores are
/// left for the UI and the concurrent LLM request; past 8 threads the gain is
/// negligible.
int searchThreads(int cores) => cores <= 2 ? 1 : (cores - 2).clamp(1, 8);

/// The most lines one search may rank. The app always searches one line;
/// more are only for comparing searches.
const int maxSearchLines = 5;

/// `MultiPV` clamped to 1..[maxSearchLines].
int searchLines(int requested) => requested.clamp(1, maxSearchLines);

/// Sent once after `start()`, before the first search. No `uci` — `start()`
/// already sent it and a second one resets every option — and no
/// `ucinewgame`, so the hash survives the whole sweep. The app never passes
/// [multiPv]; the runner-up comes from [goCommand]'s `searchmoves`.
List<String> startupCommands({
  required int threads,
  required int hashMb,
  int multiPv = 1,
}) => [
  'setoption name Threads value $threads',
  'setoption name Hash value $hashMb',
  if (multiPv > 1) 'setoption name MultiPV value $multiPv',
  'isready',
];

/// One search to [depth]. With [searchMoves] (engine UCI) the search only
/// considers those moves: the runner-up search behind Brilliant and Great.
String goCommand(int depth, {List<String> searchMoves = const []}) =>
    searchMoves.isEmpty
    ? 'go depth $depth'
    : 'go depth $depth searchmoves ${searchMoves.join(' ')}';
