import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/models/playback_state.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/sync_nudge_store.dart';
import '../../utils/platform_info.dart';
import '../../theme/amp_tokens.dart';
import '../../ui/amp_button.dart';
import '../../ui/amp_page_route.dart';
import '../../ui/amp_scaffold.dart';
import '../../ui/code_field.dart';
import '../../ui/eq_visualizer.dart';
import '../../ui/glass_card.dart';
import '../../ui/live_pill.dart';
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

    return AmpScaffold(
      title: 'Join a Session',
      body: AnimatedSwitcher(
        duration: AmpTokens.slow,
        switchInCurve: AmpTokens.ease,
        child: KeyedSubtree(
          key: ValueKey(session == null ? 'find' : (session.hostLeft ? 'left' : 'in')),
          child: body,
        ),
      ),
    );
  }

  Widget _buildHostLeft(BuildContext context, JoinViewModel viewModel) {
    final tokens = AmpTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: tokens.signal.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: tokens.signal.withValues(alpha: 0.5)),
              ),
              child: Icon(Icons.link_off_rounded, size: 40, color: tokens.signal),
            ),
            const SizedBox(height: 20),
            Text(
              'The host ended the session',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            AmpButton(
              label: 'Back to sessions',
              icon: Icons.arrow_back_rounded,
              onPressed: () async {
                await viewModel.leave();
                await viewModel.startScanning();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscovery(BuildContext context, JoinViewModel viewModel) {
    final tokens = AmpTokens.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const EnterAnimation(
          child: ScreenHeadline(
            'Join the room.',
            caption:
                'Type the code from the host screen, scan its QR, or tap a '
                'session found on this WiFi.',
          ),
        ),
        EnterAnimation(
          index: 1,
          child: CodeField(
            controller: _codeController,
            onSubmitted: (value) => _submitCode(context, viewModel),
          ),
        ),
        const SizedBox(height: 14),
        EnterAnimation(
          index: 2,
          child: Row(
            children: [
              Expanded(
                child: AmpButton(
                  label: 'Join',
                  icon: Icons.login_rounded,
                  busy: viewModel.isConnecting,
                  onPressed: () => _submitCode(context, viewModel),
                ),
              ),
              // QR scanning needs a camera (mobile_scanner has no
              // Windows/Linux implementation), so it's hidden on desktop.
              if (supportsQrScanning()) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: AmpButton(
                    label: 'Scan QR',
                    icon: Icons.qr_code_scanner_rounded,
                    kind: AmpButtonKind.ghost,
                    onPressed: viewModel.isConnecting ? null : () => _scanQr(context, viewModel),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (viewModel.errorMessage != null) ...[
          const SizedBox(height: 14),
          AlertStrip(message: viewModel.errorMessage!),
        ],
        const SizedBox(height: 28),
        // Shown in caps; the e2e and widget tests look for this exact text.
        Text(
          'Nearby sessions',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: tokens.textDim, letterSpacing: 1.6),
        ),
        const SizedBox(height: 12),
        if (viewModel.nearbySessions.isEmpty)
          _buildScanningEmptyState(context)
        else
          ...viewModel.nearbySessions.map(
            (discovered) => SessionListTile(
              discovered: discovered,
              onTap: viewModel.isConnecting ? () {} : () => viewModel.join(discovered),
            ),
          ),
      ],
    );
  }

  Widget _buildScanningEmptyState(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final theme = Theme.of(context);
    return GlassCard(
      child: Row(
        children: [
          const _Radar(size: 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scanning for nearby sessions…', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Make sure you’re on the same WiFi as the host, or enter a join code above.',
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
                ),
              ],
            ),
          ),
        ],
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Camera access is needed to scan a QR code.')));
      return;
    }
    final code = await Navigator.of(
      context,
    ).push<String>(AmpPageRoute(builder: (_) => const QrScannerScreen()));
    if (code == null || !context.mounted) return;
    _codeController.text = code;
    await viewModel.joinByCode(code);
  }

  Widget _buildJoinedSession(BuildContext context, JoinViewModel viewModel) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    final session = viewModel.session!;
    final track = session.currentTrack;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (session.isReconnecting)
          const AlertStrip(message: 'Connection lost — reconnecting…', busy: true),
        if (session.needsAudioUnlock) ...[
          AmpButton(
            label: 'Tap to start audio',
            icon: Icons.volume_up_rounded,
            onPressed: viewModel.unlockAudio,
          ),
          const SizedBox(height: 6),
          Text(
            'Your browser won’t start audio until you tap.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
          ),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (session.isLiveSession)
                LivePill(label: 'Live stream', color: tokens.signal)
              else
                SyncStatusBadge(offsetMs: session.clockOffsetMs, roundTripMs: session.roundTripMs),
              const SizedBox(height: 14),
              Text(
                session.sessionName ?? 'Session',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.displaySmall,
              ),
              const SizedBox(height: 6),
              Text(
                'You’re a speaker in this room.',
                style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
              ),
            ],
          ),
        ),
        if (session.trackDownloadProgress case final progress?) ...[
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.downloading_rounded, color: tokens.volt),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Getting the song from the host…',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      '${(progress * 100).round()}%',
                      style: TextStyle(
                        fontFamily: AmpTokens.mono,
                        fontWeight: FontWeight.w700,
                        color: tokens.volt,
                        fontFeatures: AmpTokens.tabular,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (track?.hasVideo ?? false) ...[
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.movie_rounded, size: 20, color: tokens.volt),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Video on the host screen — this device plays its sound'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        GlassCard(
          accent: session.playbackState == PlaybackState.playing ? tokens.volt : null,
          child: track == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: [
                      const EqVisualizer(playing: false, idle: true, height: 48, bars: 24),
                      const SizedBox(height: 16),
                      Text(
                        'Waiting for the host to pick a song…',
                        style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
                      ),
                    ],
                  ),
                )
              : track.isLive || track.isLiveCapture
              ? _LiveListenerView(volume: session.volume, onVolumeChanged: viewModel.setVolume)
              : TransportControls(
                  title: track.fileName,
                  playbackState: session.playbackState,
                  position: session.position,
                  duration: Duration(milliseconds: track.durationMs),
                  volume: session.volume,
                  onVolumeChanged: viewModel.setVolume,
                ),
        ),
        if (track != null && !track.isLive) ...[
          const SizedBox(height: 16),
          _SyncNudgeCard(
            nudgeMs: session.syncNudgeMs,
            onChanged: viewModel.setSyncNudge,
            calibrationRun: viewModel.calibrationRun,
            calibrationMessage: viewModel.calibrationMessage,
            onCalibrate: () => viewModel.calibrateWithMic(context: context),
            suggestCalibration: viewModel.suggestCalibration &&
                session.playbackState == PlaybackState.playing,
            onDismissSuggestion: viewModel.dismissCalibrationHint,
          ),
        ],
        const SizedBox(height: 24),
        AmpButton(
          label: 'Leave session',
          icon: Icons.logout_rounded,
          kind: AmpButtonKind.danger,
          onPressed: () async {
            await viewModel.leave();
          },
        ),
      ],
    );
  }
}

/// Concentric rings that expand outward while scanning for sessions.
class _Radar extends StatefulWidget {
  const _Radar({required this.size});

  final double size;

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volt = AmpTokens.of(context).volt;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            for (var k = 0; k < 2; k++)
              Builder(
                builder: (context) {
                  final t = (_c.value + k / 2) % 1;
                  return Container(
                    width: widget.size * (0.35 + 0.65 * t),
                    height: widget.size * (0.35 + 0.65 * t),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: volt.withValues(alpha: 1 - t), width: 2),
                    ),
                  );
                },
              ),
            Icon(Icons.wifi_tethering_rounded, color: volt, size: widget.size * 0.4),
          ],
        ),
      ),
    );
  }
}

/// Listener view for a live broadcast (mic, device audio or a shared tab):
/// no scrubbing (it's live), just the visualizer and this device's volume.
class _LiveListenerView extends StatelessWidget {
  const _LiveListenerView({required this.volume, required this.onVolumeChanged});

  final double volume;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Live audio', style: theme.textTheme.headlineSmall)),
            LivePill(label: 'Live', color: tokens.signal),
          ],
        ),
        const SizedBox(height: 16),
        EqVisualizer(playing: true, height: 64, color: tokens.signal),
        const SizedBox(height: 12),
        Text(
          'Streaming live from the host.',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
        ),
        const SizedBox(height: 6),
        VolumeRow(volume: volume, onChanged: onVolumeChanged),
      ],
    );
  }
}

/// Lets this device play a little earlier or later than the shared timeline,
/// to cancel its own speaker delay (Bluetooth speakers, slow audio paths) —
/// the drift loop then holds it there.
class _SyncNudgeCard extends StatelessWidget {
  const _SyncNudgeCard({
    required this.nudgeMs,
    required this.onChanged,
    required this.onCalibrate,
    this.calibrationRun,
    this.calibrationMessage,
    this.suggestCalibration = false,
    this.onDismissSuggestion,
  });

  final bool suggestCalibration;
  final VoidCallback? onDismissSuggestion;
  final int nudgeMs;
  final ValueChanged<int> onChanged;
  final VoidCallback onCalibrate;
  final int? calibrationRun;
  final String? calibrationMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    void step(int by) => onChanged((nudgeMs + by).clamp(minSyncNudgeMs, maxSyncNudgeMs));
    final label = nudgeMs == 0
        ? '0 ms'
        : nudgeMs > 0
        ? '$nudgeMs ms earlier'
        : '${-nudgeMs} ms later';
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'THIS DEVICE',
                  style: theme.textTheme.labelSmall?.copyWith(color: tokens.textDim),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AmpTokens.mono,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: nudgeMs == 0 ? tokens.textDim : tokens.volt,
                  fontFeatures: AmpTokens.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Sounds behind the others (an echo)? Move it earlier until the echo '
            'disappears. Bluetooth speakers usually need 150–250 ms.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_rounded),
                tooltip: 'Later (10 ms)',
                onPressed: nudgeMs > minSyncNudgeMs ? () => step(-10) : null,
              ),
              Expanded(
                child: Slider(
                  value: nudgeMs.toDouble(),
                  min: minSyncNudgeMs.toDouble(),
                  max: maxSyncNudgeMs.toDouble(),
                  divisions: (maxSyncNudgeMs - minSyncNudgeMs) ~/ 10,
                  label: label,
                  onChanged: (v) => onChanged(v.round()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Earlier (10 ms)',
                onPressed: nudgeMs < maxSyncNudgeMs ? () => step(10) : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (suggestCalibration && calibrationRun == null) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              decoration: BoxDecoration(
                color: tokens.volt.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AmpTokens.radiusField),
              ),
              child: Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, color: tokens.volt, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'For exact sync on this speaker, calibrate once (about 10 s). '
                      'It measures this speaker\'s delay with the mic.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Not now',
                    onPressed: onDismissSuggestion,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          AmpButton(
            label: calibrationRun == null
                ? 'Calibrate with mic'
                : 'Listening… ${calibrationRun! + 1} of 3',
            icon: Icons.mic_rounded,
            kind: AmpButtonKind.ghost,
            onPressed: calibrationRun == null ? onCalibrate : null,
          ),
          const SizedBox(height: 8),
          Text(
            calibrationMessage ??
                'Hold this device near the others; you’ll hear a few blips. '
                    'Its music pauses for a moment while it measures.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: calibrationMessage == null ? tokens.textDim : tokens.volt,
            ),
          ),
        ],
      ),
    );
  }
}
