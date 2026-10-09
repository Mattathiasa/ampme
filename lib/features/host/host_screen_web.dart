import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/models/playback_state.dart';
import '../../core/network/signaling/signaling_config.dart';
import '../../theme/amp_tokens.dart';
import '../../ui/amp_button.dart';
import '../../ui/amp_page_route.dart';
import '../../ui/amp_scaffold.dart';
import '../../ui/device_tile.dart';
import '../../ui/eq_visualizer.dart';
import '../../ui/glass_card.dart';
import '../../ui/live_pill.dart';
import '../../ui/source_tile.dart';
import '../../ui/sync_ring.dart';
import 'web_host_controller.dart'
    show ListenerPhase, WebListener, liveDelayMs, maxSpeakerOffsetMs, minSpeakerOffsetMs;
import 'web_host_view_model.dart';
import 'widgets/invite_card.dart';
import 'widgets/transport_controls.dart';
import 'widgets/web_video_view.dart';

/// The browser build's host screen.
///
/// A browser can't run the HTTP/WebSocket servers a native host runs, so
/// web hosting works over WebRTC instead: the browser sends the picked song
/// to every joined device and starts them all — itself included — at the
/// same scheduled instant. The WebRTC handshake goes through Supabase
/// Realtime by default
/// (works from any page — `flutter run`, GitHub Pages, …), or through the
/// LAN relay (`dart run tool/web_relay.dart`) for no-internet setups.
/// Listeners join with the `AMP-` code or link shown here.
///
/// Kept API-compatible (`const HostScreen({super.key})`) so `home_screen`
/// and `host_gate` can reference it identically on every platform.
class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => WebHostViewModel(),
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
  final _sessionNameController = TextEditingController(text: 'My Session');
  final _relayController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // When the page itself is served by the LAN relay (plain HTTP on a LAN
    // address), that origin *is* the relay — prefill it. Loopback origins
    // (`flutter run`) are a dev server, not a relay, so leave it empty.
    final page = Uri.base;
    final loopback = page.host == 'localhost' || page.host == '127.0.0.1';
    if (page.scheme == 'http' && !loopback && page.hasPort) {
      _relayController.text = '${page.host}:${page.port}';
    }
  }

  @override
  void dispose() {
    _sessionNameController.dispose();
    _relayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<WebHostViewModel>();
    final running = viewModel.isRunning;
    return AmpScaffold(
      title: running ? '' : 'Host a Session',
      maxWidth: running ? 1180 : 560,
      body: AnimatedSwitcher(
        duration: AmpTokens.slow,
        switchInCurve: AmpTokens.ease,
        child: !running
            ? KeyedSubtree(key: const ValueKey('setup'), child: _buildSetup(context, viewModel))
            : KeyedSubtree(key: const ValueKey('live'), child: _buildSession(context, viewModel)),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, WebHostViewModel viewModel) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    final cloud = SignalingConfig.cloudEnabled;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const EnterAnimation(
          child: ScreenHeadline(
            'Start the party.',
            caption:
                'Name your session, then invite phones and browsers with a code, '
                'link or QR. Every device plays in step.',
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
        if (viewModel.hostController.errorMessage != null)
          AlertStrip(message: viewModel.hostController.errorMessage!),
        if (cloud) ...[
          EnterAnimation(
            index: 2,
            child: AmpButton(
              label: 'Start Session',
              icon: Icons.bolt_rounded,
              busy: viewModel.isStarting,
              onPressed: () => viewModel.startCloudSession(_sessionNameController.text),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Sound travels directly between devices; only the handshake goes '
            'through the internet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
          ),
          const SizedBox(height: 20),
        ],
        EnterAnimation(
          index: 3,
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: !cloud,
              leading: Icon(Icons.router_rounded, color: tokens.textDim),
              title: const Text('Advanced: use a LAN relay (no internet)'),
              childrenPadding: const EdgeInsets.only(bottom: 16),
              children: [
                TextField(
                  controller: _relayController,
                  style: const TextStyle(fontFamily: AmpTokens.mono),
                  decoration: const InputDecoration(
                    labelText: 'Relay address',
                    hintText: 'e.g. 192.168.1.10:8080',
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Run `dart run tool/web_relay.dart` on a computer on this WiFi and '
                  'enter the address it prints. Only works when this page is opened '
                  'over plain http:// (browsers block LAN connections from https:// '
                  'pages).',
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
                ),
                const SizedBox(height: 14),
                AmpButton(
                  label: 'Start on LAN relay',
                  icon: Icons.lan_rounded,
                  kind: AmpButtonKind.ghost,
                  onPressed: viewModel.isStarting
                      ? null
                      : () => viewModel.startRelaySession(
                          _sessionNameController.text,
                          _relayController.text,
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context, WebHostViewModel viewModel) {
    final controller = viewModel.hostController;
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    final track = controller.currentTrack;
    final playing = controller.playbackState == PlaybackState.playing || controller.liveIsPlaying;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LivePill(
            label: playing ? 'Live · playing' : 'Live · waiting',
            color: playing ? tokens.volt : tokens.textDim,
            pulsing: playing,
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
            controller.listenerCount == 0
                ? 'Streaming from this browser · waiting for speakers'
                : 'Streaming from this browser · ${controller.listenerCount + 1} speakers in sync',
            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
          ),
        ],
      ),
    );

    final nowPlaying = <Widget>[
      if (track != null && controller.video != null) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(AmpTokens.radiusCard),
          child: WebVideoView(video: controller.video!),
        ),
        const SizedBox(height: 8),
        Text(
          'The picture plays here; every joined device plays the sound.',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
        ),
        const SizedBox(height: 16),
      ],
      if (track != null && track.isLiveCapture) ...[
        _LiveShareCard(
          playing: controller.liveIsPlaying,
          volume: controller.volume,
          spectrum: controller.spectrum,
          onVolumeChanged: viewModel.setVolume,
          onStop: viewModel.stopTabShare,
        ),
        const SizedBox(height: 16),
      ],
      if (track != null && !track.isLiveCapture) ...[
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
            spectrum: controller.spectrum,
          ),
        ),
        const SizedBox(height: 16),
      ],
    ];

    final source = <Widget>[
      const SectionLabel('Source'),
      SourceTile(
        icon: track?.hasVideo ?? false ? Icons.movie_rounded : Icons.library_music_rounded,
        title: track == null || track.isLiveCapture ? 'Choose a song or video' : track.fileName,
        subtitle: track == null || track.isLiveCapture
            ? 'MP3, WAV, MP4, WebM… sent to every phone, then started together'
            : 'Tap to pick another',
        active: track != null && !track.isLiveCapture,
        onPressed: viewModel.isPickingFile ? null : viewModel.pickAndLoadTrack,
      ),
      SourceTile(
        icon: Icons.tab_rounded,
        title: 'Share a browser tab (YouTube…)',
        subtitle: controller.canShareTab
            ? 'Every device hears the tab ${liveDelayMs / 1000} s behind it, together'
            : 'Sharing a tab needs Chrome or Edge on a computer.',
        accent: tokens.signal,
        active: controller.isSharingTab,
        onPressed: controller.canShareTab && !controller.isSharingTab
            ? viewModel.startTabShare
            : null,
      ),
      if (controller.preparingSoundProgress case final progress?) ...[
        const SizedBox(height: 4),
        Text(
          'Preparing the sound for the phones… ${(progress * 100).round()}%',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 8),
      ],
      if (controller.errorMessage != null) AlertStrip(message: controller.errorMessage!),
    ];

    final speakers = <Widget>[
      SectionLabel('Speakers', count: controller.listenerCount),
      if (controller.listenerCount == 0)
        GlassCard(
          child: Row(
            children: [
              Icon(Icons.radar_rounded, color: tokens.volt, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'No listeners yet. Scan the QR code or open the link on '
                  'another device, or enter the code in the Ampme app.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
                ),
              ),
            ],
          ),
        )
      else
        ...controller.listeners.map(
          (listener) => _ListenerTile(
            listener: listener,
            hostPlaying: controller.playbackState.name == 'playing',
          ),
        ),
    ];

    final side = <Widget>[
      if (controller.joinCode != null) ...[
        InviteCard(joinCode: controller.joinCode!, joinLink: controller.joinLink),
        const SizedBox(height: 16),
      ],
      if (track != null && !track.isLiveCapture && controller.listenerCount > 0) ...[
        _SpeakerOffsetCard(
          offsetMs: controller.speakerOffsetMs,
          onChanged: viewModel.setSpeakerOffset,
        ),
        const SizedBox(height: 16),
      ],
    ];

    final end = AmpButton(
      label: 'End session',
      icon: Icons.stop_circle_rounded,
      kind: AmpButtonKind.danger,
      onPressed: () => viewModel.end(),
    );

    final lost = controller.signalingLost
        ? const AlertStrip(
            message:
                'Lost the connection to the signaling service. Devices already '
                'listening keep playing; new devices can’t join until you start a '
                'new session.',
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              ?lost,
              header,
              ...nowPlaying,
              ...side,
              ...source,
              const SizedBox(height: 8),
              ...speakers,
              const SizedBox(height: 24),
              end,
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
          children: [
            ?lost,
            header,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 7,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [...nowPlaying, ...source, const SizedBox(height: 8), ...speakers],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [...side, const SizedBox(height: 8), end],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Shown while a browser tab's audio is shared.
class _LiveShareCard extends StatelessWidget {
  const _LiveShareCard({
    required this.playing,
    required this.volume,
    required this.spectrum,
    required this.onVolumeChanged,
    required this.onStop,
  });

  final bool playing;
  final double volume;
  final List<double>? Function(int bands) spectrum;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    return GlassCard(
      accent: tokens.signal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              LivePill(
                label: playing ? 'Live tab audio' : 'Starting…',
                color: tokens.signal,
                pulsing: playing,
              ),
            ],
          ),
          const SizedBox(height: 16),
          EqVisualizer(playing: playing, spectrum: spectrum, height: 72, color: tokens.signal),
          const SizedBox(height: 14),
          Text(
            'Every device — this one included — plays the tab '
            '${liveDelayMs / 1000} s behind it, all together. The picture '
            'in the shared tab runs that much ahead of the sound.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
          ),
          const SizedBox(height: 6),
          VolumeRow(volume: volume, onChanged: onVolumeChanged),
          const SizedBox(height: 6),
          AmpButton(
            label: 'Stop sharing',
            icon: Icons.stop_rounded,
            kind: AmpButtonKind.danger,
            onPressed: onStop,
          ),
        ],
      ),
    );
  }
}

/// One connected device and how its sync is going.
class _ListenerTile extends StatelessWidget {
  const _ListenerTile({required this.listener, required this.hostPlaying});

  final WebListener listener;
  final bool hostPlaying;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final drift = listener.driftMs;
    // The status strings are also what the e2e test reads ("In sync (N ms)").
    final (Color? color, String status, double? progress) = switch (listener.phase) {
      ListenerPhase.needsUpdate => (
        tokens.signal,
        'Needs the latest Ampme app (or reload the web page) to play in sync',
        null,
      ),
      ListenerPhase.connecting => (null, 'Connecting…', null),
      ListenerPhase.receivingSong => (
        null,
        'Getting the song… ${(listener.fileProgress * 100).round()}%',
        listener.fileProgress,
      ),
      ListenerPhase.ready when hostPlaying && drift != null =>
        drift.abs() <= 40
            ? (tokens.syncGood, 'In sync (${SyncRing.signed(drift)} ms)', null)
            : (tokens.syncWarn, 'Catching up (${SyncRing.signed(drift)} ms)', null),
      ListenerPhase.ready => (null, 'Ready', null),
    };
    final measuring = listener.phase == ListenerPhase.ready && hostPlaying;
    return DeviceTile(
      name: listener.name,
      status: status,
      statusColor: color,
      playing: measuring && drift != null && drift.abs() <= 40,
      progress: progress,
      trailing: measuring
          ? SyncRing(driftMs: drift)
          : listener.phase == ListenerPhase.needsUpdate
          ? Icon(Icons.system_update_rounded, color: tokens.signal)
          : null,
    );
  }
}

/// Shifts this browser's own speaker against the phones, for what the app
/// can't measure (a phone on Bluetooth, a slow sound card).
class _SpeakerOffsetCard extends StatelessWidget {
  const _SpeakerOffsetCard({required this.offsetMs, required this.onChanged});

  final int offsetMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    void nudge(int by) => onChanged((offsetMs + by).clamp(minSpeakerOffsetMs, maxSpeakerOffsetMs));
    final label = offsetMs == 0 ? '0 ms' : '${offsetMs > 0 ? '+' : ''}$offsetMs ms';
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'THIS SPEAKER',
                  style: theme.textTheme.labelSmall?.copyWith(color: tokens.textDim),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AmpTokens.mono,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: tokens.volt,
                  fontFeatures: AmpTokens.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'All devices start together automatically. If this computer '
            'still sounds ahead of the phones, add delay; behind, remove some.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_rounded),
                tooltip: 'Earlier (-10 ms)',
                onPressed: offsetMs > minSpeakerOffsetMs ? () => nudge(-10) : null,
              ),
              Expanded(
                child: Slider(
                  value: offsetMs.toDouble(),
                  min: minSpeakerOffsetMs.toDouble(),
                  max: maxSpeakerOffsetMs.toDouble(),
                  divisions: (maxSpeakerOffsetMs - minSpeakerOffsetMs) ~/ 10,
                  label: label,
                  onChanged: (v) => onChanged(v.round()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Later (+10 ms)',
                onPressed: offsetMs < maxSpeakerOffsetMs ? () => nudge(10) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
