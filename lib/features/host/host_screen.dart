import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/models/playback_state.dart';
import '../../theme/amp_tokens.dart';
import '../../ui/amp_button.dart';
import '../../ui/amp_page_route.dart';
import '../../ui/amp_scaffold.dart';
import '../../ui/eq_visualizer.dart';
import '../../ui/glass_card.dart';
import '../../ui/live_pill.dart';
import '../../ui/source_tile.dart';
import 'host_view_model.dart';
import 'widgets/invite_card.dart';
import 'widgets/listener_status_tile.dart';
import 'widgets/native_video_view.dart';
import 'widgets/transport_controls.dart';

class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(create: (_) => HostViewModel(), child: const _HostScreenBody());
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

    return AmpScaffold(
      title: started ? '' : 'Host a Session',
      body: AnimatedSwitcher(
        duration: AmpTokens.slow,
        switchInCurve: AmpTokens.ease,
        child: !started
            ? KeyedSubtree(key: const ValueKey('setup'), child: _buildSetup(context, viewModel))
            : KeyedSubtree(key: const ValueKey('live'), child: _buildSession(context, viewModel)),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, HostViewModel viewModel) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const EnterAnimation(
          child: ScreenHeadline(
            'Start the party.',
            caption:
                'Phones on this WiFi find your session automatically; '
                'anyone else joins with the code.',
          ),
        ),
        EnterAnimation(
          index: 1,
          child: TextField(
            controller: _sessionNameController,
            style: theme.textTheme.titleMedium,
            decoration: const InputDecoration(
              labelText: 'Session name',
              prefixIcon: Icon(Icons.edit_rounded),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (viewModel.errorMessage != null) AlertStrip(message: viewModel.errorMessage!),
        EnterAnimation(
          index: 2,
          child: AmpButton(
            label: 'Start Session',
            icon: Icons.bolt_rounded,
            busy: viewModel.isStarting,
            onPressed: () => viewModel.startSession(_sessionNameController.text, context: context),
          ),
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
    final tokens = AmpTokens.of(context);
    final listenerCount = controller.listenerStatuses.length;
    final playing = controller.playbackState == PlaybackState.playing || anyLiveSource;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LivePill(
                label: playing ? 'Live · playing' : 'Live · waiting',
                color: playing ? tokens.volt : tokens.textDim,
              ),
              const SizedBox(height: 14),
              Text(
                controller.sessionName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.displaySmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Broadcasting on ${controller.localIp ?? 'unknown IP'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textDim,
                  fontFamily: AmpTokens.mono,
                ),
              ),
            ],
          ),
        ),
        if (isLive) ...[
          _BroadcastCard(
            color: tokens.signal,
            pill: 'Amplifying the room',
            text:
                'Your microphone is streaming live to every connected device. '
                'Play music out loud and it carries to the whole group.',
          ),
          const SizedBox(height: 16),
        ] else if (isSystemAudio) ...[
          _BroadcastCard(
            color: tokens.volt,
            pill: 'Streaming device audio',
            text:
                'Everything this device plays — from any app — is streaming '
                'live to every connected device. Open your music app and hit play.',
          ),
          const SizedBox(height: 16),
        ] else if (track != null) ...[
          if (viewModel.isPreparingVideo) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(
              'Preparing the sound for the phones…',
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
            ),
            const SizedBox(height: 12),
          ],
          if (track.hasVideo && controller.videoPath != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AmpTokens.radiusCard),
              child: NativeVideoView(
                path: controller.videoPath!,
                engine: controller.audioEngine,
                playing: controller.playbackState == PlaybackState.playing,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The picture plays here; every joined device plays the sound.',
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
            ),
            const SizedBox(height: 16),
          ],
          GlassCard(
            accent: controller.playbackState == PlaybackState.playing ? tokens.volt : null,
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
          const SizedBox(height: 16),
        ],
        if (controller.joinCode != null) ...[
          InviteCard(
            joinCode: controller.joinCode!,
            hint: 'Enter this code (or scan the QR) on another device to join.',
          ),
          const SizedBox(height: 16),
        ],
        const SectionLabel('Source'),
        SourceTile(
          icon: track?.hasVideo ?? false ? Icons.movie_rounded : Icons.library_music_rounded,
          title: (track == null || track.isLive) ? 'Choose a song or video' : track.fileName,
          subtitle: (track == null || track.isLive)
              ? 'Copied to every phone, then started together'
              : 'Tap to pick another',
          active: track != null && !track.isLive && !anyLiveSource,
          onPressed: (viewModel.isPickingFile || anyLiveSource) ? null : viewModel.pickAndLoadTrack,
        ),
        SourceTile(
          icon: viewModel.isTogglingLive
              ? Icons.hourglass_top_rounded
              : (isLive ? Icons.stop_circle_rounded : Icons.mic_rounded),
          title: isLive ? 'Stop live broadcast' : 'Broadcast live audio',
          subtitle: 'Your microphone, live to every phone',
          accent: tokens.signal,
          active: isLive,
          onPressed: viewModel.isTogglingLive
              ? null
              : () => viewModel.toggleLiveBroadcast(context: context),
        ),
        // "Broadcast device audio" only exists on platforms that can capture
        // other apps' output (Android 10+ today).
        if (viewModel.systemAudioSupported)
          SourceTile(
            icon: viewModel.isTogglingSystemAudio
                ? Icons.hourglass_top_rounded
                : (isSystemAudio ? Icons.stop_circle_rounded : Icons.smartphone_rounded),
            title: isSystemAudio ? 'Stop broadcasting device audio' : 'Broadcast device audio',
            subtitle: 'Whatever any app on this phone outputs',
            active: isSystemAudio,
            onPressed: viewModel.isTogglingSystemAudio
                ? null
                : () => viewModel.toggleSystemAudioBroadcast(context: context),
          ),
        if (viewModel.errorMessage != null) AlertStrip(message: viewModel.errorMessage!),
        const SizedBox(height: 8),
        SectionLabel('Speakers', count: listenerCount),
        if (controller.listenerStatuses.isEmpty)
          GlassCard(
            child: Row(
              children: [
                Icon(Icons.radar_rounded, color: tokens.volt, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'No listeners connected yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
                  ),
                ),
              ],
            ),
          )
        else
          ...controller.listenerStatuses.values.map((status) => ListenerStatusTile(status: status)),
      ],
    );
  }
}

/// Shown on the host while a live source (mic or device audio) is on, in
/// place of the file transport controls.
class _BroadcastCard extends StatelessWidget {
  const _BroadcastCard({required this.color, required this.pill, required this.text});

  final Color color;
  final String pill;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      accent: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LivePill(label: pill, color: color),
          const SizedBox(height: 16),
          EqVisualizer(playing: true, color: color, height: 64),
          const SizedBox(height: 14),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: AmpTokens.of(context).textDim),
          ),
        ],
      ),
    );
  }
}
