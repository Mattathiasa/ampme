import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../host/widgets/transport_controls.dart';
import 'join_view_model.dart';
import 'widgets/session_list_tile.dart';
import 'widgets/sync_status_badge.dart';

class JoinScreen extends StatelessWidget {
  const JoinScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => JoinViewModel(),
      child: const _JoinScreenBody(),
    );
  }
}

class _JoinScreenBody extends StatefulWidget {
  const _JoinScreenBody();

  @override
  State<_JoinScreenBody> createState() => _JoinScreenBodyState();
}

class _JoinScreenBodyState extends State<_JoinScreenBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<JoinViewModel>().startScanning();
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<JoinViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('Join a Session')),
      body: SafeArea(
        child: viewModel.session != null
            ? _buildJoinedSession(context, viewModel)
            : _buildDiscovery(context, viewModel),
      ),
    );
  }

  Widget _buildDiscovery(BuildContext context, JoinViewModel viewModel) {
    return Column(
      children: [
        if (viewModel.errorMessage != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              viewModel.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (viewModel.isConnecting) const LinearProgressIndicator(),
        Expanded(
          child: viewModel.nearbySessions.isEmpty
              ? const Center(child: Text('Looking for nearby sessions…'))
              : ListView(
                  children: viewModel.nearbySessions
                      .map(
                        (discovered) => SessionListTile(
                          discovered: discovered,
                          onTap: viewModel.isConnecting ? () {} : () => viewModel.join(discovered),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _buildJoinedSession(BuildContext context, JoinViewModel viewModel) {
    final session = viewModel.session!;
    final track = session.currentTrack;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(session.sessionName ?? 'Session', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        SyncStatusBadge(offsetMs: session.clockOffsetMs, roundTripMs: session.roundTripMs),
        const SizedBox(height: 16),
        if (track == null)
          const Text('Waiting for the host to pick a song…')
        else
          TransportControls(
            playbackState: session.playbackState,
            position: session.position,
            duration: Duration(milliseconds: track.durationMs),
          ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () async {
            await viewModel.leave();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Leave session'),
        ),
      ],
    );
  }
}
