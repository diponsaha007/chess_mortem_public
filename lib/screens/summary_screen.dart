import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../analysis/analysis_session.dart';
import '../model/accuracy.dart';
import '../model/classification.dart';
import '../model/game_phase.dart';
import '../model/game_result.dart';
import '../model/game_tree.dart';
import '../model/sides.dart';
import '../model/win_chart.dart';
import '../widgets/info_note.dart';
import '../widgets/move_list.dart'
    show BookBadge, ClassificationBadge, classificationColor;
import '../widgets/safe_bottom.dart';
import '../widgets/side_marks.dart';
import '../widgets/win_chart.dart';

/// Each player's headline accuracy figure, for tests.
ValueKey<String> accuracyKeyFor(Side side) =>
    ValueKey('summaryAccuracy-${side.name}');

/// One player's card — also the control that picks the perspective.
ValueKey<String> playerCardKeyFor(Side side) =>
    ValueKey('summaryPlayerCard-${side.name}');

/// The game in one screen, ranked: player cards, opening, win chart, then
/// the move-quality and accuracy tables.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({
    super.key,
    required this.session,
    required this.perspective,
    this.onPerspectiveChanged,
  });

  final AnalysisSession session;

  /// The board's orientation when the screen opened.
  final Side perspective;

  /// Tells the board a player card was picked, so it flips too.
  final ValueChanged<Side>? onPerspectiveChanged;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late Side _perspective = widget.perspective;

  AnalysisSession get session => widget.session;

  /// Follows the board if it is flipped underneath.
  @override
  void didUpdateWidget(SummaryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.perspective != oldWidget.perspective) {
      _perspective = widget.perspective;
    }
  }

  void _select(Side side) {
    if (side == _perspective) return;
    setState(() => _perspective = side);
    widget.onPerspectiveChanged?.call(side);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final division = session.division;
    final mainline = session.tree.mainline;
    final counts = {
      for (final side in Side.values) side: _countsFor(mainline, side),
    };
    final bookMoves = {
      for (final side in Side.values)
        side: mainline.where((n) => n.sideThatMoved == side && n.isBook).length,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Game Summary')),
      body: ListView(
        padding: withSafeBottom(context, const EdgeInsets.all(12)),
        children: [
          if (session.isAnalyzing) ...[
            _AnalysingLine(session: session),
            const SizedBox(height: 12),
          ],
          // IntrinsicHeight: a Row in a ListView has unbounded height.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final side in Side.values) ...[
                  if (side == Side.black) const SizedBox(width: 10),
                  Expanded(child: _playerCard(mainline, side, counts[side]!)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap a player to read the game from their side.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          if (session.openingName != null) ...[
            const SizedBox(height: 10),
            _OpeningRow(name: session.openingName!),
          ],
          const SizedBox(height: 10),
          _Card(
            title: _chartTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ChartWithAxis(
                  points: buildWinChartPoints(
                    root: session.tree.root,
                    mainline: mainline,
                    perspective: _perspective,
                  ),
                  currentPly: session.current.ply,
                  division: division,
                  onSelectPly: _goToPly,
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap or drag the graph to jump to a move.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _Card(
            title: 'Move quality',
            child: _MoveQuality(counts: counts, bookMoves: bookMoves),
          ),
          const SizedBox(height: 10),
          _Card(
            title: 'Accuracy detail',
            child: Column(children: _accuracyRows(mainline, division)),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.memory, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Analysed by ${session.engineLabel}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "Your" only when the perspective really is the user's side.
  String get _chartTitle => session.userSide == _perspective
      ? 'Your winning chances'
      : "${sideName(_perspective)}'s winning chances";

  Widget _playerCard(
    List<GameNode> mainline,
    Side side,
    Map<Classification, int> counts,
  ) {
    final isWhite = side == Side.white;
    return _PlayerCard(
      key: playerCardKeyFor(side),
      side: side,
      name: isWhite ? session.whitePlayer : session.blackPlayer,
      rating: isWhite ? session.whiteElo : session.blackElo,
      isYou: session.userSide == side,
      result: session.result,
      accuracy: gameAccuracy(
        accuracySamples(
          root: session.tree.root,
          mainline: mainline,
          mover: side,
        ),
      ),
      counts: counts,
      selected: _perspective == side,
      onSelected: () => _select(side),
    );
  }

  /// This player's non-book moves per tier — the same moves accuracy scores.
  static Map<Classification, int> _countsFor(
    List<GameNode> mainline,
    Side side,
  ) {
    final counts = <Classification, int>{};
    for (final node in mainline) {
      if (node.sideThatMoved != side || node.isBook) continue;
      final tier = node.classification;
      if (tier == null) continue;
      counts[tier] = (counts[tier] ?? 0) + 1;
    }
    return counts;
  }

  /// The phases the game had, then centipawn loss.
  List<Widget> _accuracyRows(List<GameNode> mainline, GameDivision division) {
    String pct(double? value) =>
        value == null ? '—' : '${value.toStringAsFixed(1)}%';
    String cp(int? value) => value == null ? '—' : '$value';

    int? cpLoss(Side side) => averageCentipawnLoss(
      root: session.tree.root,
      mainline: mainline,
      mover: side,
    );

    return [
      const _SummaryHeader(),
      // No phases while the game never left the opening, as on lichess.
      if (division.hasMiddlegame)
        for (final phase in GamePhase.values)
          ?_phaseRow(mainline, division, phase, pct),
      _SummaryRow(
        label: 'Centipawn loss',
        white: cp(cpLoss(Side.white)),
        black: cp(cpLoss(Side.black)),
        info: _centipawnNote,
      ),
    ];
  }

  /// One phase's row, or null when neither player has a scored move in it.
  _SummaryRow? _phaseRow(
    List<GameNode> mainline,
    GameDivision division,
    GamePhase phase,
    String Function(double?) pct,
  ) {
    double? accuracyFor(Side side) => phaseAccuracy(
      mainline: mainline,
      division: division,
      phase: phase,
      mover: side,
    );

    final white = accuracyFor(Side.white);
    final black = accuracyFor(Side.black);
    if (white == null && black == null) return null;
    return _SummaryRow(
      label: phase.label,
      white: pct(white),
      black: pct(black),
      info: _phaseNote,
    );
  }

  void _goToPly(int ply) {
    var node = session.tree.root;
    for (var i = 0; i < ply && node.children.isNotEmpty; i++) {
      node = node.children.first;
    }
    session.goToNode(node);
  }
}

// What each figure means, behind its ⓘ.

const _accuracyNote = InfoNote(
  title: 'Accuracy',
  body: 'How much of their winning chances each player kept.',
);

const _phaseNote = InfoNote(
  title: 'Game phases',
  body: 'Accuracy in each part of the game, scored on its own.',
);

const _centipawnNote = InfoNote(
  title: 'Centipawn loss',
  body: 'Average loss per move, in hundredths of a pawn. Lower is better.',
);

/// Every figure here is provisional until the sweep ends.
class _AnalysingLine extends StatelessWidget {
  const _AnalysingLine({required this.session});

  final AnalysisSession session;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Still analysing: ${session.analyzedMoves} of '
            '${session.totalMoves} moves',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// One player: name, accuracy, result and quality mix. A radio button: fill,
/// ring and outline all mean "the side being read"; the winner is said in
/// words.
class _PlayerCard extends StatelessWidget {
  const _PlayerCard({
    super.key,
    required this.side,
    required this.name,
    required this.rating,
    required this.isYou,
    required this.result,
    required this.accuracy,
    required this.counts,
    required this.selected,
    required this.onSelected,
  });

  final Side side;
  final String? name;
  final String? rating;
  final bool isYou;
  final GameResult? result;
  final double? accuracy;
  final Map<Classification, int> counts;

  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(14);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        // `shape` alone: Material asserts when given `borderRadius` too.
        color: selected
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          // Transparent when unselected, so selecting nudges nothing.
          side: BorderSide(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: InkWell(
          onTap: onSelected,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _content(theme),
          ),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme) {
    final won = result?.wonBy(side) ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SideRadio(side: side, selected: selected),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name ?? sideName(side),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (isYou) ...[const SizedBox(width: 4), const YouChip()],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              'ACCURACY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
              ),
            ),
            InfoDot(_accuracyNote),
          ],
        ),
        Text(
          accuracy == null ? '—' : '${accuracy!.toStringAsFixed(1)}%',
          key: accuracyKeyFor(side),
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w300,
            letterSpacing: -1,
          ),
        ),
        Text(
          _subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: won
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outline,
            fontWeight: won ? FontWeight.w700 : null,
          ),
        ),
        const SizedBox(height: 10),
        _QualityBar(counts: counts),
      ],
    );
  }

  /// Rating and result. The score stays White-first on both cards: Black's
  /// says "lost 1–0".
  String get _subtitle {
    final parts = <String>[
      ?rating,
      if (result != null)
        if (result!.isDraw)
          'drew ${result!.label}'
        else
          '${result!.wonBy(side) ? 'won' : 'lost'} ${result!.label}',
    ];
    return parts.isEmpty ? ' ' : parts.join(' · ');
  }
}

/// The player's moves as one 6 px bar, worst on the right.
class _QualityBar extends StatelessWidget {
  const _QualityBar({required this.counts});

  final Map<Classification, int> counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final present = [
      for (final tier in Classification.values)
        if ((counts[tier] ?? 0) > 0) tier,
    ];
    if (present.isEmpty) {
      return Container(
        height: 6,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }
    return SizedBox(
      height: 6,
      child: Row(
        children: [
          for (final tier in present) ...[
            Expanded(
              flex: counts[tier]!,
              child: Container(
                decoration: BoxDecoration(
                  color: classificationColor(tier),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
            if (tier != present.last) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }
}

/// The player's colour as a dot inside a selection ring. Not a Material
/// [Radio], whose dot is one flat colour.
class _SideRadio extends StatelessWidget {
  const _SideRadio({required this.side, required this.selected});

  final Side side;
  final bool selected;

  static const double _size = 18;
  static const double _dot = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Center(
        child: SideDot(side: side, size: _dot),
      ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  const _OpeningRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const BookBadge(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

/// A titled block.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// The win chart with a 0/50/100 axis beside it.
class _ChartWithAxis extends StatelessWidget {
  const _ChartWithAxis({
    required this.points,
    required this.currentPly,
    required this.division,
    required this.onSelectPly,
  });

  final List<WinChartPoint> points;
  final int currentPly;
  final GameDivision division;
  final ValueChanged<int> onSelectPly;

  static const double _height = 130;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
      fontSize: 9,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('100', style: style),
              Text('50', style: style),
              Text('0', style: style),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: WinChart(
            points: points,
            currentPly: currentPly,
            division: division,
            onSelectPly: onSelectPly,
            height: _height,
          ),
        ),
      ],
    );
  }
}

/// Move counts for every tier, zeros included, with Book directly under
/// Great. Book is not a [Classification], so it is added by hand.
class _MoveQuality extends StatelessWidget {
  const _MoveQuality({required this.counts, required this.bookMoves});

  final Map<Side, Map<Classification, int>> counts;
  final Map<Side, int> bookMoves;

  static const _bookSitsAbove = Classification.best;

  @override
  Widget build(BuildContext context) {
    int count(Side side, Classification tier) => counts[side]![tier] ?? 0;

    return Column(
      children: [
        const _SummaryHeader(),
        for (final tier in Classification.values) ...[
          if (tier == _bookSitsAbove)
            _SummaryRow(
              leading: const BookBadge(),
              label: 'Book',
              white: '${bookMoves[Side.white]}',
              black: '${bookMoves[Side.black]}',
            ),
          _SummaryRow(
            leading: ClassificationBadge(classification: tier, size: 16),
            label: tier.label,
            white: '${count(Side.white, tier)}',
            black: '${count(Side.black, tier)}',
          ),
        ],
      ],
    );
  }
}

/// The White / Black column headings shared by every table here.
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          const Expanded(flex: 2, child: SizedBox.shrink()),
          Expanded(
            child: Text('White', textAlign: TextAlign.center, style: style),
          ),
          Expanded(
            child: Text('Black', textAlign: TextAlign.center, style: style),
          ),
        ],
      ),
    );
  }
}

/// Label, White column, Black column — the one row shape on this screen, so
/// the columns line up down the page.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    this.leading,
    required this.label,
    required this.white,
    required this.black,
    this.info,
  });

  final Widget? leading;
  final String label;
  final String white;
  final String black;

  /// Shown as a tappable ⓘ beside the label.
  final InfoNote? info;

  Widget? get _leading => leading == null
      ? null
      : Padding(padding: const EdgeInsets.only(right: 8), child: leading);

  Widget? get _info => info == null ? null : InfoDot(info!);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Row(
              children: [
                ?_leading,
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ?_info,
              ],
            ),
          ),
          Expanded(child: Text(white, textAlign: TextAlign.center)),
          Expanded(child: Text(black, textAlign: TextAlign.center)),
        ],
      ),
    );
  }
}
