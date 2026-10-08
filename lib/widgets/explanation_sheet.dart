import 'package:flutter/material.dart';

import '../analysis/analysis_session.dart';
import 'safe_bottom.dart';

/// The explanation bottom sheet. Plain values in; capped height, scrolling
/// body.
class ExplanationSheet extends StatelessWidget {
  const ExplanationSheet({
    super.key,
    required this.moveLabel,
    required this.status,
    required this.explanation,
    required this.errorDetail,
    required this.onRetry,
    required this.summaryLine,
    this.explainedBy,
    this.betterLine,
  });

  /// e.g. "White played Nxe5 · Blunder".
  final String moveLabel;

  /// The title: the coach line, the same as the coach bar. The LLM's
  /// answer, when asked for, goes under it.
  final String summaryLine;
  final ExplanationStatus status;
  final String? explanation;
  final String? errorDetail;

  /// The model that wrote [explanation], when known.
  final String? explainedBy;

  /// Asks the model: "Explain more", "Retry" and "Ask again" alike.
  final VoidCallback onRetry;

  /// "9. Nf3 Nc6 10. d4 exd4": the better line, for a mistake or worse.
  final String? betterLine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 60 % of the visible height; the nav bar is ours to handle.
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height - safeBottom) * 0.6,
      ),
      child: SingleChildScrollView(
        padding: withSafeBottom(
          context,
          const EdgeInsets.fromLTRB(20, 0, 20, 24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              moveLabel,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(summaryLine, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            // An answer stays while it is asked again, and if that fails.
            if (explanation != null && status != ExplanationStatus.idle) ...[
              SelectableText(explanation!, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 4),
            ],
            switch (status) {
              ExplanationStatus.loading => Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(explanation == null ? 'Thinking…' : 'Asking again…'),
                ],
              ),
              ExplanationStatus.ready => Row(
                children: [
                  Expanded(
                    child: Text(
                      explainedBy == null ? '' : 'Answered by $explainedBy',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Ask again'),
                  ),
                ],
              ),
              ExplanationStatus.failed => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Couldn't get an explanation."),
                  if (errorDetail != null) ...[
                    const SizedBox(height: 4),
                    Text(errorDetail!, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
              ExplanationStatus.idle => FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.psychology_alt),
                label: const Text('Explain more'),
              ),
            },
            // Engine-only, so shown whatever the LLM status.
            if (betterLine != null) ...[
              const SizedBox(height: 20),
              Text(
                'Better was',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                betterLine!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
