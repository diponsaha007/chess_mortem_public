import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../appearance/appearance_controller.dart';
import '../model/classification.dart';
import '../model/game_tree.dart';

/// The moves as horizontally-scrolling strips: one for the mainline, plus an
/// indented strip per variation the cursor is at or inside.
class MoveList extends StatefulWidget {
  const MoveList({
    super.key,
    required this.tree,
    required this.current,
    required this.onTap,
  });

  final GameTree tree;
  final GameNode current;
  final ValueChanged<GameNode> onTap;

  @override
  State<MoveList> createState() => _MoveListState();
}

class _MoveListState extends State<MoveList> {
  final _currentChipKey = GlobalKey();

  /// On the fork of the deepest open variation, so its parent strip scrolls
  /// to where the variation starts.
  final _branchChipKey = GlobalKey();

  /// The mainline strip's scroll, so the start position (which has no chip
  /// to bring into view) can scroll it back to the first move.
  final _mainlineScroll = ScrollController();

  /// A deep what-if chain must not grow down and squeeze the board.
  static const _maxStrips = 4;

  @override
  void dispose() {
    _mainlineScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollToCurrent();
  }

  @override
  void didUpdateWidget(MoveList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current != widget.current) _scrollToCurrent();
  }

  void _scrollToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.current.isRoot) {
        if (_mainlineScroll.hasClients) {
          _mainlineScroll.animateTo(
            0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
        return;
      }
      for (final key in [_branchChipKey, _currentChipKey]) {
        final chipContext = key.currentContext;
        if (chipContext == null) continue;
        Scrollable.ensureVisible(
          chipContext,
          alignment: 0.5, // park it mid-strip
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// The strips to render: the mainline, then every variation on the path
  /// from the root to the current move, then any unexplored alternatives at
  /// the fork the cursor is sitting on.
  List<_Line> _openLines() {
    final root = widget.tree.root;
    if (root.children.isEmpty) return const [];

    final lines = <_Line>[
      _Line(first: root.children.first, indent: 0, branchPoint: null),
    ];

    final path = <GameNode>[];
    for (var node = widget.current; !node.isRoot; node = node.parent!) {
      path.add(node);
    }
    var indent = 0;
    for (final node in path.reversed) {
      final parent = node.parent!;
      if (parent.children.first != node) {
        indent++;
        lines.add(_Line(first: node, indent: indent, branchPoint: parent));
      }
    }

    // Unexplored alternatives to the current move.
    final parent = widget.current.parent;
    if (parent != null) {
      for (final sibling in parent.children.skip(1)) {
        if (sibling == widget.current) continue;
        lines.add(
          _Line(first: sibling, indent: indent + 1, branchPoint: parent),
        );
      }
    }

    return lines.length <= _maxStrips
        ? lines
        : lines.sublist(lines.length - _maxStrips);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _openLines();
    final deepestBranch = lines.isEmpty ? null : lines.last.branchPoint;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          _MoveStrip(
            line: line,
            current: widget.current,
            currentChipKey: _currentChipKey,
            branchChipKey: _branchChipKey,
            branchNode: deepestBranch,
            onTap: widget.onTap,
            controller: line.branchPoint == null ? _mainlineScroll : null,
          ),
      ],
    );
  }
}

/// One rendered strip: [first] and its `children[0]` successors.
class _Line {
  const _Line({
    required this.first,
    required this.indent,
    required this.branchPoint,
  });

  final GameNode first;
  final int indent;

  /// The move this line departs from, null for the mainline.
  final GameNode? branchPoint;
}

class _MoveStrip extends StatelessWidget {
  const _MoveStrip({
    required this.line,
    required this.current,
    required this.currentChipKey,
    required this.branchChipKey,
    required this.branchNode,
    required this.onTap,
    this.controller,
  });

  final _Line line;
  final ScrollController? controller;
  final GameNode current;
  final GlobalKey currentChipKey;
  final GlobalKey branchChipKey;
  final GameNode? branchNode;
  final ValueChanged<GameNode> onTap;

  static const _indentStep = 14.0;

  @override
  Widget build(BuildContext context) {
    final nodes = <GameNode>[];
    for (var node = line.first; ; node = node.children.first) {
      nodes.add(node);
      if (node.children.isEmpty) break;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(4 + _indentStep * line.indent, 2, 4, 2),
      child: Row(
        children: [
          if (line.branchPoint != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                '↳',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  height: 1,
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final node in nodes)
                    _MoveChip(
                      key: node == current
                          ? currentChipKey
                          : (node == branchNode ? branchChipKey : null),
                      node: node,
                      isCurrent: node == current,
                      onTap: onTap,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoveChip extends StatelessWidget {
  const _MoveChip({
    super.key,
    required this.node,
    required this.isCurrent,
    required this.onTap,
  });

  final GameNode node;
  final bool isCurrent;
  final ValueChanged<GameNode> onTap;

  static const _glyphSize = 15.0;

  /// "12." before White's moves, "12..." when a Black move starts a strip.
  String get _movePrefix {
    final moveNumber = (node.ply + 1) ~/ 2;
    if (node.ply.isOdd) return '$moveNumber.';
    final startsLine =
        node.parent!.children.first != node || node.parent!.isRoot;
    return startsLine ? '$moveNumber...' : '';
  }

  /// The SAN minus its piece letter, which is drawn as a glyph.
  String get _sanText {
    final san = node.san ?? '';
    if (san.isEmpty || node.movedPiece?.role == Role.pawn) return san;
    return 'NBRQK'.contains(san[0]) ? san.substring(1) : san;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final piece = node.movedPiece;
    final classification = node.classification;

    return InkWell(
      onTap: () => onTap(node),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: isCurrent ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (piece != null) ...[
              Image(
                // Unicode ♘ is unreliable in Android's font fallback.
                image: AppearanceScope.of(context).pieceStyle.image(piece),
                width: _glyphSize,
                height: _glyphSize,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: 1),
            ],
            Text.rich(
              TextSpan(
                children: [
                  if (_movePrefix.isNotEmpty)
                    TextSpan(
                      text: _movePrefix,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  TextSpan(
                    text: _sanText,
                    style: TextStyle(
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                      fontStyle: node.isUserMove
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
            if (node.isBook) ...[
              const SizedBox(width: 2),
              const BookBadge(size: 13),
            ] else if (classification != null) ...[
              const SizedBox(width: 2),
              ClassificationBadge(classification: classification, size: 14),
            ],
          ],
        ),
      ),
    );
  }
}

/// The move-quality vocabulary, in ONE place. At most two characters, never
/// an icon. Excellent and Good share a tick in two greens.
String classificationSymbol(Classification c) => switch (c) {
  Classification.brilliant => '!!',
  Classification.great => '!',
  Classification.best => '★',
  Classification.excellent => '✓',
  Classification.good => '✓',
  Classification.inaccuracy => '?!',
  Classification.mistake => '?',
  Classification.blunder => '??',
  Classification.miss => '×',
};

/// The verdict as a small coloured disc — the same widget on the board, the
/// strips, the coach bar and the summary.
class ClassificationBadge extends StatelessWidget {
  const ClassificationBadge({
    super.key,
    required this.classification,
    this.size = 16,
  });

  final Classification classification;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.14),
      decoration: BoxDecoration(
        color: classificationColor(classification),
        shape: BoxShape.circle,
      ),
      child: FittedBox(
        child: Text(
          classificationSymbol(classification),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: classificationInk,
            fontWeight: FontWeight.w800,
            height: 1,
            // Otherwise `height: 1` lifts baseline glyphs (★, ✓) off-centre.
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }
}

/// The dark ink every verdict symbol is drawn in, on a LIGHT fill.
const classificationInk = Color(0xFF10221F);

/// A verdict's colour: the badge disc and the coach bar's verdict word.
/// `classification_palette_test.dart` pins >= 4.5:1 contrast against both
/// the dark surface and [classificationInk].
Color classificationColor(Classification c) => switch (c) {
  Classification.brilliant => const Color(0xFF29C5F6),
  Classification.great => const Color(0xFF8B84FF),
  Classification.best => const Color(0xFF06C39A),
  Classification.excellent => const Color(0xFF4CAF50),
  Classification.good => const Color(0xFF8BC34A),
  Classification.inaccuracy => const Color(0xFFFBBF24),
  Classification.mistake => const Color(0xFFFB923C),
  Classification.blunder => const Color(0xFFFA5252),
  Classification.miss => const Color(0xFFF783AC),
};

/// A book move's mark, everywhere a verdict badge would go. [disc] puts it on
/// a backdrop so it reads over the board's squares.
class BookBadge extends StatelessWidget {
  const BookBadge({super.key, this.size = 16, this.disc = false});

  final double size;
  final bool disc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!disc) {
      return Icon(Icons.menu_book, size: size, color: scheme.outline);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.menu_book,
        size: size * 0.62,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
