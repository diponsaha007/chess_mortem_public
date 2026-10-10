import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'safe_bottom.dart';

/// What the Share action sends.
enum ShareFormat { pgn, gif }

/// Asks PGN or GIF. The GIF needs the verdicts, so it waits for the analysis
/// ([gifReady]). Null when dismissed.
Future<ShareFormat?> showShareFormatSheet(
  BuildContext context, {
  required bool gifReady,
}) => showModalBottomSheet<ShareFormat>(
  context: context,
  builder: (context) => Padding(
    padding: withSafeBottom(context, const EdgeInsets.symmetric(vertical: 8)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Share game',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('PGN'),
          subtitle: const Text('The moves, as text'),
          onTap: () => Navigator.of(context).pop(ShareFormat.pgn),
        ),
        ListTile(
          leading: const Icon(Icons.gif_box_outlined),
          title: const Text('GIF'),
          subtitle: Text(
            gifReady
                ? 'Every move, with its verdict'
                : 'After the analysis finishes',
          ),
          enabled: gifReady,
          onTap: () => Navigator.of(context).pop(ShareFormat.gif),
        ),
      ],
    ),
  ),
);

/// "Making GIF…" with the frames done out of [total], and Cancel. Closing
/// it in any way stops the work; whoever opened it listens for that.
class GifProgressDialog extends StatelessWidget {
  const GifProgressDialog({
    super.key,
    required this.progress,
    required this.total,
  });

  final ValueListenable<int> progress;
  final int total;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Making GIF…'),
      content: ValueListenableBuilder<int>(
        valueListenable: progress,
        builder: (context, done, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            const SizedBox(height: 12),
            Text('$done / $total'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
