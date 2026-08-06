import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/audio_engine.dart';
import '../audio/just_audio_engine.dart';
import '../audio/live_mic_broadcaster.dart';
import '../network/audio_http_server.dart';
import '../network/control_server.dart';
import '../network/discovery/session_broadcaster.dart';
import '../network/models/control_message.dart';
import '../network/models/device_info.dart';
import '../network/models/listener_status.dart';
import '../network/models/playback_state.dart';
import '../network/models/session_beacon.dart';
import '../network/models/track_info.dart';
import '../network/network_utils.dart';
import '../../utils/id_generator.dart';

/// How far into the future a `play`/`seek` command's target start time is
/// set. Must be comfortably longer than typical LAN round-trip + listener
/// buffering time so every listener has already pre-buffered and armed
/// its scheduled `Timer` before the instant arrives.
const Duration _scheduleLeadTime = Duration(milliseconds: 800);

/// Orchestrates a hosted session: owns the audio engine (what the host
/// itself hears), the local HTTP server (audio streaming + control
/// WebSocket upgrade), the control server (listener messaging), and the
/// UDP beacon broadcaster (discoverability). `ChangeNotifier` so a
/// `HostViewModel` can listen directly with `provider`.
class HostSessionController extends ChangeNotifier {
  HostSessionController({required this.hostDevice, AudioEngine? audioEngine})
    : audioEngine = audioEngine ?? JustAudioEngine();

  final DeviceInfo hostDevice;
  final AudioEngine audioEngine;

  final _httpServer = AudioHttpServer();
  final _controlServer = ControlServer();
  final _broadcaster = SessionBroadcaster();
  final _micBroadcaster = LiveMicBroadcaster();
  final _knownListeners = <String>{};

  final String sessionId = generateId();
  String sessionName = '';
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  double volume = 1.0;
  String? localIp;

  /// The code a listener types to join this session (host IP + port). Null
  /// until the server is started and the local IP is known.
  String? get joinCode {
    final ip = localIp;
    final port = _httpServer.port;
    if (ip == null || port == null) return null;
    return '$ip:$port';
  }

  final _listenerStatuses = <String, ListenerStatus>{};
  Map<String, ListenerStatus> get listenerStatuses => Map.unmodifiable(_listenerStatuses);

  StreamSubscription? _incomingSub;
  StreamSubscription? _disconnectSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _stateSub;

  Future<void> start(String name) async {
    sessionName = name;
    final port = await _httpServer.start();
    _httpServer.onWebSocketConnected = _controlServer.handleConnection;

    _incomingSub = _controlServer.incoming.listen(_handleIncoming);
    _disconnectSub = _controlServer.disconnections.listen(_handleDisconnect);
    _positionSub = audioEngine.positionStream.listen((pos) {
      // Only rebuild when the visible (whole second) value changes, so the
      // host's transport slider advances live without excessive rebuilds.
      final changedSecond = pos.inSeconds != position.inSeconds;
      position = pos;
      if (changedSecond) notifyListeners();
    });
    _stateSub = audioEngine.stateStream.listen((state) {
      playbackState = state;
      notifyListeners();
    });

    localIp = await getLocalWifiIp();
    await _broadcaster.start(
      () => SessionBeacon(
        sessionName: sessionName,
        hostDeviceId: hostDevice.deviceId,
        hostIp: localIp ?? '0.0.0.0',
        controlPort: port,
        streamPort: port,
        appVersion: '1.0.0',
      ),
    );
    notifyListeners();
  }

  /// Whether the host is currently broadcasting live microphone audio
  /// ("amplify the room") rather than a picked file.
  bool get isLiveBroadcasting => _micBroadcaster.isBroadcasting;

  Future<void> loadTrack(File file, {required String fileName}) async {
    // A file and a live broadcast are mutually exclusive sources.
    if (_micBroadcaster.isBroadcasting) await stopLiveBroadcast();

    final trackId = generateId();
    _httpServer.setCurrentTrack(trackId: trackId, file: file);
    final duration = await audioEngine.loadLocalFile(file.path, title: fileName);
    position = Duration.zero;

    final ip = localIp ?? await getLocalWifiIp();
    final streamUrl = 'http://$ip:${_httpServer.port}/stream/$trackId';
    currentTrack = TrackInfo(
      trackId: trackId,
      fileName: fileName,
      streamUrl: streamUrl,
      durationMs: duration?.inMilliseconds ?? 0,
    );

    _controlServer.broadcast(
      ControlMessage.trackChanged(senderId: hostDevice.deviceId, track: currentTrack!),
    );
    notifyListeners();
  }

  Future<void> play() async {
    final track = currentTrack;
    if (track == null) return;

    final startAt = DateTime.now().add(_scheduleLeadTime);
    await audioEngine.scheduleStart(at: startAt, position: position);
    _controlServer.broadcast(
      ControlMessage.play(
        senderId: hostDevice.deviceId,
        trackId: track.trackId,
        positionMs: position.inMilliseconds,
        startAtHostTimeMs: startAt.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> pause() async {
    await audioEngine.pause();
    final track = currentTrack;
    if (track == null) return;
    _controlServer.broadcast(
      ControlMessage.pause(
        senderId: hostDevice.deviceId,
        trackId: track.trackId,
        positionMs: position.inMilliseconds,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> seek(Duration target) async {
    final track = currentTrack;
    if (track == null) return;

    final startAt = DateTime.now().add(_scheduleLeadTime);
    await audioEngine.scheduleStart(at: startAt, position: target);
    _controlServer.broadcast(
      ControlMessage.seek(
        senderId: hostDevice.deviceId,
        trackId: track.trackId,
        positionMs: target.inMilliseconds,
        startAtHostTimeMs: startAt.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> setVolume(double newVolume) async {
    volume = newVolume;
    await audioEngine.setVolume(newVolume);
    _controlServer.broadcast(
      ControlMessage.volume(senderId: hostDevice.deviceId, volume: newVolume),
    );
    notifyListeners();
  }

  /// Starts capturing the host microphone and broadcasting it live to
  /// listeners ("amplify the room"). The host doesn't play this back itself
  /// (it's the source — playing would feed back), so listeners hear it while
  /// the host's own [audioEngine] stays idle.
  Future<void> startLiveBroadcast() async {
    if (_micBroadcaster.isBroadcasting) return;

    // Stop any file playback so the two sources don't overlap.
    await audioEngine.pause();
    await _micBroadcaster.start();

    final trackId = generateId();
    _httpServer.setLiveSource(
      trackId: trackId,
      pcm: _micBroadcaster.pcmStream,
      sampleRate: LiveMicBroadcaster.sampleRate,
      channels: LiveMicBroadcaster.channels,
    );

    final ip = localIp ?? await getLocalWifiIp();
    final streamUrl = 'http://$ip:${_httpServer.port}/live/$trackId';
    currentTrack = TrackInfo(
      trackId: trackId,
      fileName: 'Live audio',
      streamUrl: streamUrl,
      durationMs: 0,
      isLive: true,
    );
    position = Duration.zero;
    playbackState = PlaybackState.playing;

    _controlServer.broadcast(
      ControlMessage.trackChanged(senderId: hostDevice.deviceId, track: currentTrack!),
    );
    notifyListeners();
  }

  /// Ends the live broadcast, tells listeners to stop, and returns the
  /// session to "no track selected".
  Future<void> stopLiveBroadcast() async {
    if (!_micBroadcaster.isBroadcasting) return;
    final endedTrack = currentTrack;

    await _micBroadcaster.stop();
    _httpServer.clearLiveSource();

    if (endedTrack != null) {
      _controlServer.broadcast(
        ControlMessage.pause(
          senderId: hostDevice.deviceId,
          trackId: endedTrack.trackId,
          positionMs: 0,
          hostTimeMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    currentTrack = null;
    playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  void _handleIncoming(IncomingControlMessage incoming) {
    if (_knownListeners.add(incoming.deviceId)) {
      _sendWelcome(incoming.deviceId);
    }

    final message = incoming.message;
    switch (message.type) {
      case ControlMessageType.clockSyncRequest:
        final t0 = message.payload['clientSendTimeMs'] as int;
        _controlServer.sendTo(
          incoming.deviceId,
          ControlMessage.clockSyncResponse(
            senderId: hostDevice.deviceId,
            clientSendTimeMs: t0,
            hostTimeMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case ControlMessageType.listenerStatusUpdate:
        _listenerStatuses[incoming.deviceId] = ListenerStatus(
          deviceId: incoming.deviceId,
          deviceName: message.payload['deviceName'] as String,
          playbackState: PlaybackStateJson.fromJsonValue(message.payload['playbackState'] as String),
          positionMs: message.payload['positionMs'] as int,
          syncOffsetMs: message.payload['syncOffsetMs'] as int,
          roundTripMs: message.payload['roundTripMs'] as int,
        );
        notifyListeners();
      default:
        break;
    }
  }

  void _sendWelcome(String deviceId) {
    _controlServer.sendTo(
      deviceId,
      ControlMessage.welcome(
        senderId: hostDevice.deviceId,
        sessionId: sessionId,
        sessionName: sessionName,
        hostDeviceId: hostDevice.deviceId,
        currentTrack: currentTrack,
        playbackState: playbackState.toJsonValue(),
        positionMs: position.inMilliseconds,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _handleDisconnect(String deviceId) {
    _knownListeners.remove(deviceId);
    _listenerStatuses.remove(deviceId);
    notifyListeners();
  }

  Future<void> stop() async {
    // Tell listeners the session is ending before we tear the sockets down,
    // so they leave cleanly instead of only inferring it from the drop.
    if (_knownListeners.isNotEmpty) {
      _controlServer.broadcast(ControlMessage.sessionEnded(senderId: hostDevice.deviceId));
    }
    await _incomingSub?.cancel();
    await _disconnectSub?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _broadcaster.stop();
    await _controlServer.dispose();
    await _httpServer.stop();
  }

  @override
  void dispose() {
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    await stop();
    await _micBroadcaster.dispose();
    await audioEngine.dispose();
  }
}
