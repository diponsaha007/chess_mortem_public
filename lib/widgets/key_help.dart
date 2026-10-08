import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../llm/llm_config.dart';

const keyPageButtonKey = ValueKey('keyHelpOpenKeyPage');

/// Hands a link to the system; true when something opened it.
typedef LinkLauncher = Future<bool> Function(Uri url);

/// The real launcher: the system browser.
Future<bool> launchInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Opens [url] in the browser. With no browser to hand it to, the link is
/// copied instead and the user is told, so the step is never a dead end.
Future<void> openLink(
  BuildContext context,
  String url, {
  LinkLauncher launch = launchInBrowser,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (await launch(Uri.parse(url))) return;
  } catch (_) {
    // Nothing could take the link: copy it instead.
  }
  await Clipboard.setData(ClipboardData(text: url));
  messenger?.showSnackBar(
    const SnackBar(content: Text('Link copied — paste it in your browser.')),
  );
}

/// How to get a key for [provider], where the key is asked for: three steps
/// and the button that starts the first one.
class KeyHelp extends StatelessWidget {
  const KeyHelp({
    super.key,
    required this.provider,
    this.launch = launchInBrowser,
  });

  final LlmProvider provider;

  /// Injectable for tests; the browser otherwise.
  final LinkLauncher launch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final steps = [
      provider.freeWithoutCard
          ? 'Open the key page and sign in. It is free and asks for no card.'
          : 'Open the key page and sign in.',
      'Create a key and copy it.',
      'Paste it below.',
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              provider == LlmProvider.recommended
                  ? 'Getting a key (recommended provider)'
                  : 'Getting a key',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final (index, step) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${index + 1}. $step', style: small),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: keyPageButtonKey,
                onPressed: () =>
                    openLink(context, provider.keyPageUrl, launch: launch),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(
                  provider.freeWithoutCard ? 'Get a free key' : 'Open key page',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
