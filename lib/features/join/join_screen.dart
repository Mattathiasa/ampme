import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/permissions/app_permissions.dart';
import '../host/widgets/transport_controls.dart';
import 'join_view_model.dart';
import 'widgets/qr_scanner_screen.dart';
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
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<JoinViewModel>().startScanning();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<JoinViewModel>();
    final session = viewModel.session;

    final Widget body;
    if (session == null) {
      body = _buildDiscovery(context, viewModel);
    } else if (session.hostLeft) {
      body = _buildHostLeft(context, viewModel);
    } else {
      body = _buildJoinedSession(context, viewModel);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Join a Session')),
      body: SafeArea(child: body),
    );
  }

  Widget _buildHostLeft(BuildContext context, JoinViewModel viewModel) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 64),
            const SizedBox(height: 16),
            Text(
              'The host ended the session',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                await viewModel.leave();
                await viewModel.startScanning();
              },
              child: const Text('Back to sessions'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscovery(BuildContext context, JoinViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: 'Join by code',
                  hintText: 'e.g. 192.168.1.5:54213',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) => _submitCode(context, viewModel),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: viewModel.isConnecting
                          ? null
                          : () => _submitCode(context, viewModel),
                      icon: const Icon(Icons.login),
                      label: const Text('Join'),
                    ),
                  ),
                  if (!kIsWeb) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: viewModel.isConnecting
                            ? null
                            : () => _scanQr(context, viewModel),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan QR'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (viewModel.errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              viewModel.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (viewModel.isConnecting) const LinearProgressIndicator(),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Nearby sessions', style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: viewModel.nearbySessions.isEmpty
              ? _buildScanningEmptyState(context)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
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

  Widget _buildScanningEmptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    strokeWidth: 3,
                    color: scheme.primary.withValues(alpha: 0.6),
                  ),
                  Icon(Icons.wifi_tethering, color: scheme.primary),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Scanning for nearby sessions…',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Make sure you’re on the same WiFi as the host, or enter a join code above.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitCode(BuildContext context, JoinViewModel viewModel) async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    FocusScope.of(context).unfocus();
    await viewModel.joinByCode(code);
  }

  Future<void> _scanQr(BuildContext context, JoinViewModel viewModel) async {
    FocusScope.of(context).unfocus();
    final granted = await AppPermissions.requestCameraAccess();
    if (!context.mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera access is needed to scan a QR code.')),
      );
      return;
    }
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (code == null || !context.mounted) return;
    _codeController.text = code;
    await viewModel.joinByCode(code);
  }

  Widget _buildJoinedSession(BuildContext context, JoinViewModel viewModel) {
    final theme = Theme.of(context);
    final session = viewModel.session!;
    final track = session.currentTrack;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.headphones, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                session.sessionName ?? 'Session',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SyncStatusBadge(offsetMs: session.clockOffsetMs, roundTripMs: session.roundTripMs),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: track == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Waiting for the host to pick a song…')),
                  )
                : track.isLive
                    ? _LiveListenerView(
                        volume: session.volume,
                        onVolumeChanged: viewModel.setVolume,
                      )
                    : TransportControls(
                        title: track.fileName,
                        playbackState: session.playbackState,
                        position: session.position,
                        duration: Duration(milliseconds: track.durationMs),
                        volume: session.volume,
                        onVolumeChanged: viewModel.setVolume,
                      ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () async {
            await viewModel.leave();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Leave session'),
        ),
      ],
    );
  }
}

/// Listener view for a live "amplify the room" broadcast: no scrubbing (it's
/// live), just a LIVE indicator and this device's own volume.
class _LiveListenerView extends StatelessWidget {
  const _LiveListenerView({required this.volume, required this.onVolumeChanged});

  final double volume;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, color: scheme.secondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Live audio', style: theme.textTheme.titleMedium),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fiber_manual_record, size: 10, color: scheme.secondary),
                  const SizedBox(width: 5),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Streaming live from the host.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.volume_down, color: scheme.onSurfaceVariant),
            Expanded(
              child: Slider(value: volume.clamp(0.0, 1.0), onChanged: onVolumeChanged),
            ),
            Icon(Icons.volume_up, color: scheme.onSurfaceVariant),
          ],
        ),
      ],
    );
  }
}
