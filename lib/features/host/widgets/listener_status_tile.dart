import 'package:flutter/material.dart';

import '../../../core/network/models/listener_status.dart';
import '../../../core/network/models/playback_state.dart';
import '../../../utils/formatters.dart';

class ListenerStatusTile extends StatelessWidget {
  const ListenerStatusTile({super.key, required this.status});

  final ListenerStatus status;

  @override
  Widget build(BuildContext context) {
    final inSync = status.roundTripMs < 200;
    return ListTile(
      leading: Icon(
        status.playbackState == PlaybackState.playing ? Icons.play_circle : Icons.pause_circle,
      ),
      title: Text(status.deviceName),
      subtitle: Text(
        '${formatDuration(Duration(milliseconds: status.positionMs))} · '
        'offset ${status.syncOffsetMs}ms · rtt ${status.roundTripMs}ms',
      ),
      trailing: Icon(
        inSync ? Icons.check_circle : Icons.warning_amber,
        color: inSync ? Colors.green : Colors.orange,
      ),
    );
  }
}
