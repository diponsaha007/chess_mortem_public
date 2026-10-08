import 'package:flutter/material.dart';

/// What one row or control means, shown on demand.
class InfoNote {
  const InfoNote({required this.title, required this.body});

  final String title;
  final String body;

  void show(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// The tappable ⓘ that opens an [InfoNote]. An [InkResponse], not an
/// [IconButton], whose 48 px target would set every row's height.
class InfoDot extends StatelessWidget {
  const InfoDot(this.note, {super.key});

  final InfoNote note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkResponse(
      onTap: () => note.show(context),
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(
          Icons.info_outline,
          size: 15,
          color: theme.colorScheme.outline,
          semanticLabel: 'What ${note.title} means',
        ),
      ),
    );
  }
}
