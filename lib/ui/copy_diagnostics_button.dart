import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/amp_tokens.dart';

/// "Copy diagnostics": puts the recent errors and sync readings on the
/// clipboard (see `Diagnostics`), so a bad-sync report is a paste into a
/// message instead of a cable and a log.
class CopyDiagnosticsButton extends StatelessWidget {
  const CopyDiagnosticsButton({super.key, required this.report});

  /// Makes the report text.
  final Future<String> Function() report;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    return Center(
      child: TextButton.icon(
        icon: Icon(Icons.bug_report_outlined, size: 18, color: tokens.textDim),
        label: Text('Copy diagnostics', style: TextStyle(color: tokens.textDim)),
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          await Clipboard.setData(ClipboardData(text: await report()));
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Diagnostics copied — paste them into a message to the developer.'),
            ),
          );
        },
      ),
    );
  }
}
