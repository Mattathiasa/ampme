import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'host_view_model.dart';
import 'widgets/listener_status_tile.dart';
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
              : () => viewModel.startSession(_sessionNameController.text),
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

    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(controller.sessionName, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Broadcasting on ${controller.localIp ?? 'unknown IP'}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: viewModel.isPickingFile ? null : viewModel.pickAndLoadTrack,
          icon: const Icon(Icons.library_music),
          label: Text(track == null ? 'Choose a song' : track.fileName),
        ),
        if (viewModel.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              viewModel.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (track != null) ...[
          const SizedBox(height: 16),
          TransportControls(
            playbackState: controller.playbackState,
            position: controller.position,
            duration: Duration(milliseconds: track.durationMs),
            onPlay: viewModel.play,
            onPause: viewModel.pause,
            onSeek: viewModel.seek,
            volume: 1.0,
            onVolumeChanged: viewModel.setVolume,
          ),
        ],
        const SizedBox(height: 24),
        Text('Connected devices', style: Theme.of(context).textTheme.titleMedium),
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
