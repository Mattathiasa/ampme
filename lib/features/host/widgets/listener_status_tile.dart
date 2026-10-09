import 'package:flutter/material.dart';

import '../../../core/network/models/listener_status.dart';
import '../../../core/network/models/playback_state.dart';
import '../../../theme/amp_tokens.dart';
import '../../../ui/device_tile.dart';
import '../../../utils/formatters.dart';

/// A device connected to this (native) host and how its clock sync is doing.
class ListenerStatusTile extends StatelessWidget {
  const ListenerStatusTile({super.key, required this.status});

  final ListenerStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final inSync = status.roundTripMs < 200;
    return DeviceTile(
      name: status.deviceName,
      playing: status.playbackState == PlaybackState.playing,
      status:
          '${formatDuration(Duration(milliseconds: status.positionMs))} · '
          'offset ${status.syncOffsetMs} ms · rtt ${status.roundTripMs} ms',
      trailing: Icon(
        inSync ? Icons.check_circle_rounded : Icons.error_outline_rounded,
        color: inSync ? tokens.syncGood : tokens.syncWarn,
      ),
    );
  }
}
