import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_engine.dart';
import '../audio/just_audio_engine.dart';
import '../network/control_client.dart';
import '../network/models/control_message.dart';
import '../network/models/device_info.dart';
import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';

const Duration _statusReportInterval = Duration(seconds: 2);

/// Orchestrates a joined session: owns the audio engine (playing the
/// host's stream URL), the control client (clock sync + incoming
/// play/pause/seek/track commands), and periodic status reporting back to
/// the host. `ChangeNotifier` so a `JoinViewModel` can listen directly
/// with `provider`.
class ListenerSessionController extends ChangeNotifier {
  ListenerSessionController({required this.selfDevice, AudioEngine? audioEngine})
    : audioEngine = audioEngine ?? JustAudioEngine();

  final DeviceInfo selfDevice;
  final AudioEngine audioEngine;

  ControlClient? _client;
  StreamSubscription? _messagesSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _stateSub;
  Timer? _statusTimer;

  String? sessionName;
  String? hostDeviceId;
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  int? clockOffsetMs;
  int? roundTripMs;

  Future<void> connect({required String hostIp, required int controlPort}) async {
    final client = ControlClient(deviceId: selfDevice.deviceId);
    _client = client;
    await client.connect(hostIp: hostIp, controlPort: controlPort);

    _messagesSub = client.messages.listen(_handleMessage);
    _positionSub = audioEngine.positionStream.listen((pos) => position = pos);
    _stateSub = audioEngine.stateStream.listen((state) {
      playbackState = state;
      notifyListeners();
    });
    _statusTimer = Timer.periodic(_statusReportInterval, (_) => _sendStatus());
  }

  void _handleMessage(ControlMessage message) {
    switch (message.type) {
      case ControlMessageType.welcome:
        sessionName = message.payload['sessionName'] as String;
        hostDeviceId = message.payload['hostDeviceId'] as String;
        final trackJson = message.payload['currentTrack'];
        currentTrack = trackJson != null
            ? TrackInfo.fromJson(Map<String, dynamic>.from(trackJson as Map))
            : null;
        if (currentTrack != null) _loadCurrentTrack();
        notifyListeners();
      case ControlMessageType.trackChanged:
        currentTrack = TrackInfo.fromJson(message.payload);
        _loadCurrentTrack();
        notifyListeners();
      case ControlMessageType.play:
      case ControlMessageType.seek:
        _handleScheduledStart(message);
      case ControlMessageType.pause:
        audioEngine.pause();
      case ControlMessageType.volume:
        audioEngine.setVolume((message.payload['volume'] as num).toDouble());
      case ControlMessageType.clockSyncRequest:
      case ControlMessageType.clockSyncResponse:
      case ControlMessageType.listenerStatusUpdate:
        break; // not expected in the listener->UI direction
    }
  }

  Future<void> _loadCurrentTrack() async {
    final track = currentTrack;
    if (track == null) return;
    await audioEngine.loadUrl(Uri.parse(track.streamUrl));
  }

  void _handleScheduledStart(ControlMessage message) {
    final estimate = _client?.clockEstimate;
    final offsetMs = estimate?.offsetMs ?? 0;
    clockOffsetMs = offsetMs;
    roundTripMs = estimate?.roundTripMs;

    final positionMs = message.payload['positionMs'] as int;
    final startAtHostTimeMs = message.payload['startAtHostTimeMs'] as int;
    // offsetMs == hostTime - clientTime, so hostTime -> clientTime is
    // startAtHostTimeMs - offsetMs.
    final localTarget = DateTime.fromMillisecondsSinceEpoch(startAtHostTimeMs - offsetMs);

    audioEngine.scheduleStart(at: localTarget, position: Duration(milliseconds: positionMs));
  }

  void _sendStatus() {
    _client?.send(
      ControlMessage.listenerStatusUpdate(
        senderId: selfDevice.deviceId,
        deviceName: selfDevice.deviceName,
        playbackState: playbackState.toJsonValue(),
        positionMs: position.inMilliseconds,
        syncOffsetMs: clockOffsetMs ?? 0,
        roundTripMs: roundTripMs ?? 0,
      ),
    );
  }

  Future<void> disconnect() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    await _messagesSub?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _client?.dispose();
    _client = null;
  }

  @override
  void dispose() {
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    await disconnect();
    await audioEngine.dispose();
  }
}
