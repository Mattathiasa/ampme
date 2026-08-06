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
  StreamSubscription? _disconnectedSub;
  Timer? _statusTimer;

  String? sessionName;
  String? hostDeviceId;
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  int? clockOffsetMs;
  int? roundTripMs;

  /// This device's own playback volume (0..1). Each listener controls its own
  /// output, so the host's playback isn't a single master volume.
  double volume = 1.0;

  /// Set once the host ends the session or the connection drops; the UI uses
  /// this to show "host left" and return to discovery.
  bool hostLeft = false;

  /// Sets this device's local playback volume without affecting other devices.
  Future<void> setLocalVolume(double value) async {
    volume = value;
    await audioEngine.setVolume(value);
    notifyListeners();
  }

  Future<void> connect({required String hostIp, required int controlPort}) async {
    final client = ControlClient(deviceId: selfDevice.deviceId);
    _client = client;
    await client.connect(hostIp: hostIp, controlPort: controlPort);

    _messagesSub = client.messages.listen(_handleMessage);
    _positionSub = audioEngine.positionStream.listen((pos) {
      // just_audio emits ~4x/sec; only rebuild when the visible (whole
      // second) value changes to keep the transport slider live without
      // churning the widget tree.
      final changedSecond = pos.inSeconds != position.inSeconds;
      position = pos;
      if (changedSecond) notifyListeners();
    });
    _stateSub = audioEngine.stateStream.listen((state) {
      playbackState = state;
      notifyListeners();
    });
    _disconnectedSub = client.disconnected.listen((_) => _handleHostGone());
    _statusTimer = Timer.periodic(_statusReportInterval, (_) => _sendStatus());
  }

  void _handleHostGone() {
    if (hostLeft) return;
    hostLeft = true;
    audioEngine.pause();
    notifyListeners();
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
        // Volume is per-device: each listener controls its own output via
        // setLocalVolume, so the host's volume changes don't override it here.
        break;
      case ControlMessageType.sessionEnded:
        _handleHostGone();
      case ControlMessageType.clockSyncRequest:
      case ControlMessageType.clockSyncResponse:
      case ControlMessageType.listenerStatusUpdate:
        break; // not expected in the listener->UI direction
    }
  }

  Future<void> _loadCurrentTrack() async {
    final track = currentTrack;
    if (track == null) return;
    await audioEngine.loadUrl(Uri.parse(track.streamUrl), title: track.fileName);
    if (track.isLive) {
      // A live broadcast has no scheduled start instant — it's always "now",
      // so begin playing as soon as it's loaded.
      playbackState = PlaybackState.playing;
      await audioEngine.play();
      notifyListeners();
    }
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
    await _disconnectedSub?.cancel();
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
