import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'web_host_controller.dart';
import 'web_host_view_model.dart';
import 'widgets/transport_controls.dart';

/// The browser build's host screen.
///
/// A browser can't run the HTTP/WebSocket servers a native host runs, so
/// web hosting works differently: the browser decodes the picked file with
/// WebAudio, plays it locally, and streams it to every joined listener over
/// WebRTC (signaled via the LAN relay — `dart run tool/web_relay.dart`).
/// Listeners join by entering the code shown here (relay address + session
/// token, e.g. `192.168.1.10:8080/AMP-4821`).
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
    _relayController.text = WebHostController.defaultRelayHost();
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
    return ListView(
      children: [
        TextField(
          controller: _sessionNameController,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relayController,
          decoration: const InputDecoration(
            labelText: 'Relay address (optional)',
            hintText: 'ip:port — defaults to this page\'s address',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'The relay is the small program (dart run tool/web_relay.dart) that '
          'connects this page to listeners. If this page was opened from the '
          'relay, you can leave this empty.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (viewModel.hostController.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              viewModel.hostController.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: viewModel.isStarting
              ? null
              : () => viewModel.startSession(
                  _sessionNameController.text,
                  relayAddress: _relayController.text.trim(),
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

  Widget _buildSession(BuildContext context, WebHostViewModel viewModel) {
    final controller = viewModel.hostController;
    final theme = Theme.of(context);
    final track = controller.currentTrack;

    return ListView(
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
          _JoinCodeCard(joinCode: controller.joinCode!),
        ],
        const SizedBox(height: 16),
        Text('Audio source', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: viewModel.isPickingFile ? null : viewModel.pickAndLoadTrack,
          icon: const Icon(Icons.library_music),
          label: Text(
            track == null ? 'Choose a song' : track.fileName,
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
                    'No listeners yet. Open Ampme on another device and join '
                    'with the code above.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  )
                else
                  ...controller.listenerNames.map(
                    (name) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.headphones, size: 20),
                      title: Text(name),
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

/// Shows the code/QR devices use to join this web-hosted session.
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
            const Text('Enter this code on another device to join.'),
            const SizedBox(height: 12),
            Center(
              child: QrImageView(data: joinCode, size: 160, backgroundColor: Colors.white),
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
