import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network/signaling/signaling_config.dart';
import 'web_host_controller.dart'
    show ListenerPhase, WebListener, maxSpeakerOffsetMs, minSpeakerOffsetMs;
import 'web_host_view_model.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Host a Session')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: !viewModel.isRunning
              ? _buildSetup(context, viewModel)
              : _buildSession(context, viewModel),
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context, WebHostViewModel viewModel) {
    final theme = Theme.of(context);
    final cloud = SignalingConfig.cloudEnabled;
    final spinner = const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    return ListView(
      children: [
        TextField(
          controller: _sessionNameController,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        const SizedBox(height: 16),
        if (viewModel.hostController.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              viewModel.hostController.errorMessage!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (cloud) ...[
          FilledButton(
            onPressed: viewModel.isStarting
                ? null
                : () => viewModel.startCloudSession(_sessionNameController.text),
            child: viewModel.isStarting ? spinner : const Text('Start Session'),
          ),
          const SizedBox(height: 8),
          Text(
            'Listeners join from any browser or the Ampme app with the code or '
            'link shown next. Audio streams directly between devices; only the '
            'connection setup goes through the internet.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: !cloud,
          title: const Text('Advanced: use a LAN relay (no internet)'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            TextField(
              controller: _relayController,
              decoration: const InputDecoration(
                labelText: 'Relay address',
                hintText: 'e.g. 192.168.1.10:8080',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Run `dart run tool/web_relay.dart` on a computer on this WiFi and '
              'enter the address it prints. Only works when this page is opened '
              'over plain http:// (browsers block LAN connections from https:// '
              'pages).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: viewModel.isStarting
                  ? null
                  : () => viewModel.startRelaySession(
                      _sessionNameController.text,
                      _relayController.text,
                    ),
              child: const Text('Start on LAN relay'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context, WebHostViewModel viewModel) {
    final controller = viewModel.hostController;
    final theme = Theme.of(context);
    final track = controller.currentTrack;

    return ListView(
      children: [
        if (controller.signalingLost) ...[
          Text(
            'Lost the connection to the signaling service. Devices already '
            'listening keep playing; new devices can’t join until you start a '
            'new session.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
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
                      Text('Streaming from this browser', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (controller.joinCode != null) ...[
          const SizedBox(height: 16),
          _JoinCodeCard(
            joinCode: controller.joinCode!,
            joinLink: controller.joinLink,
          ),
        ],
        const SizedBox(height: 16),
        Text('Audio source', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: viewModel.isPickingFile ? null : viewModel.pickAndLoadTrack,
          icon: Icon(track?.hasVideo ?? false ? Icons.movie : Icons.library_music),
          label: Text(
            track == null ? 'Choose a song or video' : track.fileName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (controller.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              controller.errorMessage!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (track != null && controller.video != null) ...[
          const SizedBox(height: 16),
          WebVideoView(video: controller.video!),
          const SizedBox(height: 4),
          Text(
            'The picture plays here; every joined device plays the sound.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (track != null) ...[
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
        if (track != null && controller.listenerCount > 0) ...[
          const SizedBox(height: 16),
          _SpeakerOffsetCard(
            offsetMs: controller.speakerOffsetMs,
            onChanged: viewModel.setSpeakerOffset,
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Connected devices', style: theme.textTheme.titleMedium),
                    const SizedBox(width: 8),
                    if (controller.listenerCount > 0)
                      Badge(label: Text('${controller.listenerCount}')),
                  ],
                ),
                const SizedBox(height: 8),
                if (controller.listenerCount == 0)
                  const Text(
                    'No listeners yet. Scan the QR code or open the link on '
                    'another device, or enter the code in the Ampme app.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  )
                else
                  ...controller.listeners.map(
                    (listener) => _ListenerTile(
                      listener: listener,
                      hostPlaying: controller.playbackState.name == 'playing',
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => viewModel.end(),
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('End session'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}

/// Shows the code, link and QR code devices use to join this web-hosted
/// session. The QR encodes the link, so any phone camera can open the web
/// app and join directly; the Ampme app's scanner understands it too.
class _JoinCodeCard extends StatelessWidget {
  const _JoinCodeCard({required this.joinCode, this.joinLink});

  final String joinCode;
  final String? joinLink;

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$what copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = joinLink;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Invite listeners', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Scan the QR code, open the link, or enter the code.'),
            const SizedBox(height: 12),
            Center(
              child: QrImageView(
                data: link ?? joinCode,
                size: 180,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    joinCode,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy code',
                  onPressed: () => _copy(context, joinCode, 'Join code'),
                ),
              ],
            ),
            if (link != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      link,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link),
                    tooltip: 'Copy link',
                    onPressed: () => _copy(context, link, 'Join link'),
                  ),
                ],
              ),
            ],
          ],
        ),
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
    final theme = Theme.of(context);
    final drift = listener.driftMs;
    final (IconData icon, Color? color, String status) = switch (listener.phase) {
      ListenerPhase.needsUpdate => (
          Icons.system_update,
          theme.colorScheme.error,
          'Needs the latest Ampme app (or reload the web page) to play in sync',
        ),
      ListenerPhase.connecting => (Icons.sync, null, 'Connecting…'),
      ListenerPhase.receivingSong => (
          Icons.downloading,
          null,
          'Getting the song… ${(listener.fileProgress * 100).round()}%',
        ),
      ListenerPhase.ready when hostPlaying && drift != null => drift.abs() <= 40
          ? (Icons.check_circle, Colors.green, 'In sync (${_signed(drift)} ms)')
          : (Icons.timelapse, Colors.orange, 'Catching up (${_signed(drift)} ms)'),
      ListenerPhase.ready => (Icons.check_circle_outline, null, 'Ready'),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: color),
      title: Text(listener.name),
      subtitle: Text(status),
    );
  }

  static String _signed(int ms) => ms > 0 ? '+$ms' : '$ms';
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
    void nudge(int by) =>
        onChanged((offsetMs + by).clamp(minSpeakerOffsetMs, maxSpeakerOffsetMs));
    final label = offsetMs == 0 ? '0 ms' : '${offsetMs > 0 ? '+' : ''}$offsetMs ms';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('This speaker', style: theme.textTheme.titleMedium),
                ),
                Text(label, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'All devices start together automatically. If this computer '
              'still sounds ahead of the phones, add delay; behind, remove some.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
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
                  icon: const Icon(Icons.add),
                  tooltip: 'Later (+10 ms)',
                  onPressed: offsetMs < maxSpeakerOffsetMs ? () => nudge(10) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
