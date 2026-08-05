import 'package:flutter/material.dart';

class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.offsetMs, required this.roundTripMs});

  final int? offsetMs;
  final int? roundTripMs;

  @override
  Widget build(BuildContext context) {
    final rtt = roundTripMs;
    final synced = rtt != null && rtt < 200;

    return Chip(
      avatar: Icon(
        synced ? Icons.check_circle : Icons.hourglass_top,
        color: synced ? Colors.green : Colors.orange,
        size: 18,
      ),
      label: Text(
        rtt == null
            ? 'Syncing…'
            : 'Synced · offset ${offsetMs}ms · rtt ${rtt}ms',
      ),
    );
  }
}
