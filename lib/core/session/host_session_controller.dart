import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/audio_engine.dart';
import '../audio/just_audio_engine.dart';
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
  final _knownListeners = <String>{};

  final String sessionId = generateId();
  String sessionName = '';
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  String? localIp;

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
      position = pos;
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

  Future<void> loadTrack(File file, {required String fileName}) async {
    final trackId = generateId();
    _httpServer.setCurrentTrack(trackId: trackId, file: file);
    final duration = await audioEngine.loadLocalFile(file.path);
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

  Future<void> setVolume(double volume) async {
    await audioEngine.setVolume(volume);
    _controlServer.broadcast(ControlMessage.volume(senderId: hostDevice.deviceId, volume: volume));
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
    await audioEngine.dispose();
  }
}
