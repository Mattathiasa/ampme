import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/permissions/app_permissions.dart';
import '../../utils/platform_info.dart';
import '../host/widgets/transport_controls.dart';
import 'join_view_model.dart';
import 'widgets/qr_scanner_screen.dart';
import 'widgets/session_list_tile.dart';
import 'widgets/sync_status_badge.dart';

class JoinScreen extends StatelessWidget {
  const JoinScreen({super.key, this.initialCode});

  /// A code to join straight away — set when the app was opened from a
  /// join link (`…/web/?join=AMP-XXXXXX`).
  final String? initialCode;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => JoinViewModel(),
      child: _JoinScreenBody(initialCode: initialCode),
    );
  }
}

class _JoinScreenBody extends StatefulWidget {
  const _JoinScreenBody({this.initialCode});

  final String? initialCode;

  @override
  State<_JoinScreenBody> createState() => _JoinScreenBodyState();
}

class _JoinScreenBodyState extends State<_JoinScreenBody> {
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialCode = widget.initialCode?.trim();
    if (initialCode != null && initialCode.isNotEmpty) {
      _codeController.text = initialCode;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final viewModel = context.read<JoinViewModel>();
      if (initialCode != null && initialCode.isNotEmpty) {
        viewModel.joinByCode(initialCode);
      } else {
        viewModel.startScanning();
      }
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
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Join by code',
                  hintText: 'e.g. AMP-7KQ4ZD or 192.168.1.5:54213',
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
                  // QR scanning needs a camera (mobile_scanner has no
                  // Windows/Linux implementation), so it's hidden on desktop.
                  if (supportsQrScanning()) ...[
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
    final granted = await AppPermissions.requestCameraAccess(context: context);
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
        if (session.isReconnecting) ...[
          const _ReconnectingBanner(),
          const SizedBox(height: 12),
        ],
        if (session.needsAudioUnlock) ...[
          FilledButton.icon(
            onPressed: viewModel.unlockAudio,
            icon: const Icon(Icons.volume_up),
            label: const Text('Tap to start audio'),
          ),
          const SizedBox(height: 4),
          Text(
            'Your browser won’t start audio until you tap.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
        ],
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
        if (session.isLiveSession)
          // A live mic broadcast has no position to sync, so show a live
          // chip instead.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.fiber_manual_record,
                  size: 14,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Live stream',
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          )
        else
          SyncStatusBadge(
            offsetMs: session.clockOffsetMs,
            roundTripMs: session.roundTripMs,
          ),
        const SizedBox(height: 16),
        if (session.trackDownloadProgress case final progress?) ...[
          Text('Getting the song from the host… ${(progress * 100).round()}%'),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 16),
        ],
        if (track?.hasVideo ?? false) ...[
          const Row(
            children: [
              Icon(Icons.movie_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Video on the host screen — this device plays its sound')),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: track == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Waiting for the host to pick a song…')),
                  )
                : track.isLive || track.isLiveCapture
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

/// Shown while the control connection to the host is being re-established
/// after a transient drop (WiFi blip, host briefly backgrounded).
class _ReconnectingBanner extends StatelessWidget {
  const _ReconnectingBanner();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final orange = dark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: orange.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Connection lost — reconnecting…',
              style: TextStyle(color: orange, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
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
