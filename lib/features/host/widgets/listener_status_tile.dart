import 'package:flutter/material.dart';

import '../../../core/network/models/listener_status.dart';
import '../../../core/network/models/playback_state.dart';
import '../../../utils/formatters.dart';
import '../../../widgets/playing_indicator.dart';

class ListenerStatusTile extends StatelessWidget {
  const ListenerStatusTile({super.key, required this.status});

  final ListenerStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inSync = status.roundTripMs < 200;
    final isPlaying = status.playbackState == PlaybackState.playing;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            child: PlayingIndicator(
              isPlaying: isPlaying,
              color: scheme.onSecondaryContainer,
              size: 18,
            ),
          ),
          title: Text(
            status.deviceName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${formatDuration(Duration(milliseconds: status.positionMs))} · '
            'offset ${status.syncOffsetMs}ms · rtt ${status.roundTripMs}ms',
          ),
          trailing: Icon(
            inSync ? Icons.check_circle : Icons.warning_amber,
            color: inSync ? Colors.green : Colors.orange,
          ),
        ),
      ),
    );
  }
}
