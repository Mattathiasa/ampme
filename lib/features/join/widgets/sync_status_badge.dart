import 'package:flutter/material.dart';

/// Shows how tightly this device is synced to the host: a green "in sync"
/// state once the clock estimate settles, amber while still converging.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.offsetMs, required this.roundTripMs});

  final int? offsetMs;
  final int? roundTripMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rtt = roundTripMs;
    final synced = rtt != null && rtt < 200;
    final color = rtt == null
        ? scheme.outline
        : (synced ? Colors.green : Colors.orange);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            rtt == null
                ? Icons.hourglass_top
                : (synced ? Icons.check_circle : Icons.sync),
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            rtt == null
                ? 'Syncing…'
                : 'In sync · offset ${offsetMs ?? 0}ms · rtt ${rtt}ms',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
