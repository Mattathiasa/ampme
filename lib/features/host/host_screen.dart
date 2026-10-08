import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network/models/playback_state.dart';
import 'host_view_model.dart';
import 'widgets/listener_status_tile.dart';
import 'widgets/native_video_view.dart';
import 'widgets/transport_controls.dart';

class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => HostViewModel(),
      child: const _HostScreenBody(),
    );
  }
}

class _HostScreenBody extends StatefulWidget {
  const _HostScreenBody();

  @override
  State<_HostScreenBody> createState() => _HostScreenBodyState();
}

class _HostScreenBodyState extends State<_HostScreenBody> {
  final _sessionNameController = TextEditingController(text: "My Session");

  @override
  void dispose() {
    _sessionNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<HostViewModel>();
    final controller = viewModel.hostController;
    final started = controller.sessionName.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Host a Session')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: !started
              ? _buildSetup(context, viewModel)
              : _buildSession(context, viewModel),
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, HostViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _sessionNameController,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        const SizedBox(height: 16),
        if (viewModel.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              viewModel.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: viewModel.isStarting
              ? null
              : () => viewModel.startSession(
                  _sessionNameController.text,
                  context: context,
                ),
          child: viewModel.isStarting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start Session'),
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context, HostViewModel viewModel) {
    final controller = viewModel.hostController;
    final track = controller.currentTrack;
    final isLive = viewModel.isLiveBroadcasting;
    final isSystemAudio = viewModel.isSystemAudioBroadcasting;
    final anyLiveSource = isLive || isSystemAudio;

    final theme = Theme.of(context);
    final listenerCount = controller.listenerStatuses.length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.podcasts, color: theme.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(controller.sessionName, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        'Broadcasting on ${controller.localIp ?? 'unknown IP'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const _LiveChip(),
              ],
            ),
          ),
        ),
        if (controller.joinCode != null) ...[
          const SizedBox(height: 16),
          _JoinCodeCard(joinCode: controller.joinCode!),
        ],
        const SizedBox(height: 16),
        Text('Audio source', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: (viewModel.isPickingFile || anyLiveSource) ? null : viewModel.pickAndLoadTrack,
          icon: Icon(track?.hasVideo ?? false ? Icons.movie : Icons.library_music),
          label: Text(
            (track == null || track.isLive) ? 'Choose a song or video' : track.fileName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        _LiveBroadcastButton(
          isLive: isLive,
          isBusy: viewModel.isTogglingLive,
          onPressed: () => viewModel.toggleLiveBroadcast(context: context),
        ),
        // "Broadcast device audio" only exists on platforms that can capture
        // other apps' output (Android 10+ today).
        if (viewModel.systemAudioSupported) ...[const SizedBox(height: 10), _DeviceAudioBroadcastButton(
          isActive: isSystemAudio,
          isBusy: viewModel.isTogglingSystemAudio,
          onPressed: () => viewModel.toggleSystemAudioBroadcast(context: context),
        )],
        if (viewModel.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              viewModel.errorMessage!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (isLive) ...[
          const SizedBox(height: 16),
          const _LiveBroadcastCard(),
        ] else if (isSystemAudio) ...[
          const SizedBox(height: 16),
          const _DeviceAudioBroadcastCard(),
        ] else if (track != null) ...[
          if (viewModel.isPreparingVideo) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            const Text('Preparing the sound for the phones…'),
          ],
          if (track.hasVideo && controller.videoPath != null) ...[
            const SizedBox(height: 16),
            NativeVideoView(
              path: controller.videoPath!,
              engine: controller.audioEngine,
              playing: controller.playbackState == PlaybackState.playing,
            ),
            const SizedBox(height: 4),
            Text(
              'The picture plays here; every joined device plays the sound.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TransportControls(
                title: track.fileName,
                playbackState: controller.playbackState,
                position: controller.position,
                duration: Duration(milliseconds: track.durationMs),
                onPlay: viewModel.play,
                onPause: viewModel.pause,
                onSeek: viewModel.seek,
                volume: controller.volume,
                onVolumeChanged: viewModel.setVolume,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Connected devices', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            if (listenerCount > 0)
              Badge(label: Text('$listenerCount')),
          ],
        ),
        if (controller.listenerStatuses.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No listeners connected yet.'),
          )
        else
          ...controller.listenerStatuses.values.map(
            (status) => ListenerStatusTile(status: status),
          ),
      ],
    );
  }
}

/// Toggle for the "amplify the room" live microphone broadcast. Reads as a
/// call-to-action when off and a clearly-active state (sage/secondary) when on.
class _LiveBroadcastButton extends StatelessWidget {
  const _LiveBroadcastButton({
    required this.isLive,
    required this.isBusy,
    required this.onPressed,
  });

  final bool isLive;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = isBusy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(isLive ? Icons.stop_circle_outlined : Icons.mic);
    final label = Text(isLive ? 'Stop live broadcast' : 'Broadcast live audio');

    if (isLive) {
      return FilledButton.icon(
        onPressed: isBusy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.secondary,
          foregroundColor: scheme.onSecondary,
        ),
        icon: icon,
        label: label,
      );
    }
    return OutlinedButton.icon(
      onPressed: isBusy ? null : onPressed,
      icon: icon,
      label: label,
    );
  }
}

/// Toggle for the "broadcast device audio" capture (audio other apps are
/// playing). Reads as a call-to-action when off and a clearly-active state
/// when on; hidden entirely on platforms that can't capture system audio.
class _DeviceAudioBroadcastButton extends StatelessWidget {
  const _DeviceAudioBroadcastButton({
    required this.isActive,
    required this.isBusy,
    required this.onPressed,
  });

  final bool isActive;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = isBusy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(isActive ? Icons.stop_circle_outlined : Icons.smartphone);
    final label = Text(
      isActive ? 'Stop broadcasting device audio' : 'Broadcast device audio',
    );

    if (isActive) {
      return FilledButton.icon(
        onPressed: isBusy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.tertiary,
          foregroundColor: scheme.onTertiary,
        ),
        icon: icon,
        label: label,
      );
    }
    return OutlinedButton.icon(
      onPressed: isBusy ? null : onPressed,
      icon: icon,
      label: label,
    );
  }
}

/// Shown on the host while a device-audio broadcast is active, in place of
/// the file transport controls.
class _DeviceAudioBroadcastCard extends StatelessWidget {
  const _DeviceAudioBroadcastCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.tertiaryContainer,
              ),
              child: Icon(Icons.music_note, color: scheme.tertiary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Streaming device audio', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Everything this device plays — from any app — is streaming '
                    'live to every connected device. Open your music app and hit play.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown on the host while a live mic broadcast is active, in place of the
/// file transport controls.
class _LiveBroadcastCard extends StatelessWidget {
  const _LiveBroadcastCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.secondaryContainer,
              ),
              child: Icon(Icons.graphic_eq, color: scheme.secondary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Amplifying the room', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Your microphone is streaming live to every connected device. '
                    'Play music out loud and it carries to the whole group.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pulsing "LIVE" badge shown while a session is broadcasting.
class _LiveChip extends StatelessWidget {
  const _LiveChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 10, color: scheme.error),
          const SizedBox(width: 5),
          Text(
            'LIVE',
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the code/QR other devices (including the web app) use to join this
/// session, since web browsers can't auto-discover it over UDP.
class _JoinCodeCard extends StatelessWidget {
  const _JoinCodeCard({required this.joinCode});

  final String joinCode;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Join code', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Enter this code (or scan the QR) on another device to join.'),
            const SizedBox(height: 12),
            Center(
              child: QrImageView(
                data: joinCode,
                size: 160,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    joinCode,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy code',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: joinCode));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Join code copied')),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
