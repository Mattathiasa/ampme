import 'package:flutter/material.dart';

import 'glass_card.dart';

/// A screen on the Ampme canvas: transparent app bar over [AmpBackground],
/// content centred and capped at [maxWidth] so it reads well on desktop.
class AmpScaffold extends StatelessWidget {
  const AmpScaffold({
    super.key,
    required this.title,
    required this.body,
    this.maxWidth = 640,
    this.actions,
  });

  final String title;
  final Widget body;
  final double maxWidth;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: Text(title), actions: actions),
      body: AmpBackground(
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// A big display headline for a screen's first state ("START A SESSION.").
/// The last word lights up volt.
class ScreenHeadline extends StatelessWidget {
  const ScreenHeadline(this.text, {super.key, this.caption});

  final String text;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = text.split(' ');
    final last = words.removeLast();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: words.isEmpty ? '' : '${words.join(' ')} '),
                TextSpan(
                  text: last,
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              ],
            ),
            style: theme.textTheme.displayMedium,
          ),
          if (caption != null) ...[
            const SizedBox(height: 12),
            Text(
              caption!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A warning strip (signal orange) — lost connections, errors.
class AlertStrip extends StatelessWidget {
  const AlertStrip({super.key, required this.message, this.busy = false, this.icon});

  final String message;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final signal = Theme.of(context).colorScheme.secondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: signal.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: signal.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          if (busy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: signal),
            )
          else
            Icon(icon ?? Icons.warning_amber_rounded, color: signal, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: signal, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
