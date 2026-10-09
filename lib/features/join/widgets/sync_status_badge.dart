import 'package:flutter/material.dart';

import '../../../theme/amp_tokens.dart';
import '../../../ui/live_pill.dart';

/// How tightly this device is locked to the host's clock: volt "in sync"
/// once the estimate settles, amber while it's still converging.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.offsetMs, required this.roundTripMs});

  final int? offsetMs;
  final int? roundTripMs;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final rtt = roundTripMs;
    final synced = rtt != null && rtt < 200;
    final color = rtt == null ? tokens.textDim : (synced ? tokens.syncGood : tokens.syncWarn);
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LivePill(label: rtt == null ? 'Syncing' : 'In sync', color: color, pulsing: !synced),
        if (rtt != null)
          Text(
            'clock offset ${offsetMs ?? 0} ms · rtt $rtt ms',
            style: TextStyle(
              color: tokens.textDim,
              fontSize: 12,
              fontFamily: AmpTokens.mono,
              fontFeatures: AmpTokens.tabular,
            ),
          ),
      ],
    );
  }
}
