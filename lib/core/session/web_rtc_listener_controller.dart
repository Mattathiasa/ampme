import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../observability/reporting.dart';
import '../network/models/device_info.dart';
import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';
import 'active_session.dart';

/// Listener-side controller for a **web-hosted** session: the audio source is
/// a browser running the Ampme web app, which streams its audio to this
/// device over WebRTC. The [SignalingRelay](tool/web_relay.dart) on the LAN
/// carries only the handshake (offer/answer/ICE) — the audio itself flows
/// host -> listener directly, so latency stays low.
///
/// This is a live stream: there's no seekable position, no clock sync (the
/// host's clock is irrelevant — audio arrives in real time), and playback
/// starts as soon as the remote audio track arrives. It implements
/// [ActiveSession] so the join UI treats it exactly like a native-hosted
/// session.
class WebRtcListenerController extends ChangeNotifier
    implements ActiveSession {
  WebRtcListenerController({required this.selfDevice});

  final DeviceInfo selfDevice;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  rtc.RTCPeerConnection? _pc;
  Timer? _positionTimer;
  bool _disposed = false;
  Completer<void>? _connected;

  /// ICE candidates that arrived before the remote description was set are
  /// buffered here and flushed right after — the host's candidates can arrive
  /// while the native peer is still being created, and `addCandidate` before
  /// `setRemoteDescription` throws (dropping a candidate can strand the
  /// connection on a STUN-less LAN).
  final _pendingCandidates = <rtc.RTCIceCandidate>[];
  bool _remoteDescriptionSet = false;

  // ---- ActiveSession surface ----
  @override
  String? sessionName;
  @override
  TrackInfo? currentTrack;
  @override
  PlaybackState playbackState = PlaybackState.stopped;
  @override
  Duration position = Duration.zero;
  @override
  double volume = 1.0;
  @override
  bool hostLeft = false;
  @override
  bool isReconnecting = false;
  @override
  int? clockOffsetMs;
  @override
  int? roundTripMs;

  @override
  bool get isLiveSession => true;

  /// Connects to the relay and registers for [code]. Resolves once the relay
  /// confirms the session exists (welcome). Throws if the host is gone
  /// (no-host) or the relay is unreachable.
  Future<void> connect({
    required String relayHost,
    required int relayPort,
    required String code,
  }) async {
    final uri = Uri.parse('ws://$relayHost:$relayPort/ws');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _sub = channel.stream.listen(
      _handleMessage,
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: false,
    );

    final connected = Completer<void>();
    _connected = connected;
    _send({
      'type': 'listener',
      'code': code,
      'id': selfDevice.deviceId,
      'deviceName': selfDevice.deviceName,
    });

    try {
      await connected.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await _teardown();
      throw StateError('The relay or session is unreachable.');
    }
  }

  void _handleMessage(dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> message;
    try {
      message = _decode(data);
    } catch (_) {
      return; // drop malformed frames
    }

    switch (message['type']) {
      case 'welcome':
        sessionName = message['sessionName'] as String? ?? 'Web session';
        currentTrack = TrackInfo(
          trackId: message['code'] as String? ?? 'web',
          fileName: 'Live from web host',
          streamUrl: '',
          durationMs: 0,
          isLive: true,
        );
        notifyListeners();
        _connected?.complete();
      case 'offer':
        unawaited(_answerOffer(message['sdp'] as String? ?? ''));
      case 'answer':
      case 'listener-joined':
      case 'listener-left':
        break; // not expected on the listener side
      case 'ice':
        unawaited(_addIceCandidate(message));
      case 'no-host':
        _connected?.completeError(StateError('Session not found.'));
        _connected = null;
      case 'end':
        _handleHostGone();
      case 'error':
        _connected?.completeError(
          StateError(message['message'] as String? ?? 'Relay error.'),
        );
        _connected = null;
      default:
        break;
    }
  }

  Future<void> _answerOffer(String sdp) async {
    if (sdp.isEmpty) return;
    try {
      final pc = await rtc.createPeerConnection(<String, dynamic>{
        // LAN-only: host candidates are enough, no STUN/TURN needed.
        'iceServers': <Map<String, dynamic>>[],
      });
      _pc = pc;
      _remoteDescriptionSet = false;
      pc.onIceCandidate = (candidate) {
        _send({
          'type': 'ice',
          'from': selfDevice.deviceId,
          'code': currentTrack?.trackId,
          'to': 'host',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };
      pc.onTrack = (event) {
        // Remote audio plays automatically once the track is attached;
        // no renderer needed for audio-only.
        if (_disposed) return;
        playbackState = PlaybackState.playing;
        _startPositionTimer();
        notifyListeners();
      };
      pc.onConnectionState = (state) {
        if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _handleHostGone();
        }
      };

      await pc.setRemoteDescription(rtc.RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      // Flush any candidates that raced ahead of the remote description.
      for (final candidate in _pendingCandidates) {
        try {
          await pc.addCandidate(candidate);
        } catch (_) {
          // Best-effort; a stale candidate is harmless.
        }
      }
      _pendingCandidates.clear();

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _send({
        'type': 'answer',
        'from': selfDevice.deviceId,
        'code': currentTrack?.trackId,
        'to': 'host',
        'sdp': answer.sdp,
      });
    } catch (e, st) {
      reportError(e, st, context: 'answerWebRtcOffer');
    }
  }

  Future<void> _addIceCandidate(Map<String, dynamic> message) async {
    final candidate = rtc.RTCIceCandidate(
      message['candidate'] as String? ?? '',
      message['sdpMid'] as String?,
      message['sdpMLineIndex'] as int?,
    );
    final pc = _pc;
    if (pc == null || !_remoteDescriptionSet) {
      // The peer isn't ready for candidates yet — hold them until it is.
      _pendingCandidates.add(candidate);
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } catch (e, st) {
      reportError(e, st, context: 'addWebRtcIceCandidate');
    }
  }

  void _handleHostGone() {
    if (hostLeft) return;
    hostLeft = true;
    playbackState = PlaybackState.stopped;
    _positionTimer?.cancel();
    _positionTimer = null;
    unawaited(_teardownPeer());
    notifyListeners();
  }

  void _handleClosed() {
    if (_disposed) return;
    // Relay dropped. If we never connected, surface it via the completer;
    // otherwise treat it as the session ending (the host usually ends the
    // relay session when it leaves, which sends `end` — this is the fallback
    // when the relay itself dies).
    final connected = _connected;
    if (connected != null && !connected.isCompleted) {
      connected.completeError(StateError('Connection to the relay was lost.'));
      _connected = null;
    } else {
      _handleHostGone();
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    final startedAt = DateTime.now();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      position = DateTime.now().difference(startedAt);
      notifyListeners();
    });
  }

  @override
  Future<void> setLocalVolume(double value) async {
    volume = value;
    // WebRTC remote-audio volume isn't exposed by flutter_webrtc, so this
    // is per-device UI state only.
    notifyListeners();
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(_encode(message));
  }

  Future<void> _teardownPeer() async {
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {
        // Already closed.
      }
    }
  }

  Future<void> _teardown() async {
    _positionTimer?.cancel();
    _positionTimer = null;
    await _teardownPeer();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }

  // Small (de)serialization helpers kept local to this controller so the
  // network framing stays a private detail.
  Map<String, dynamic> _decode(String source) =>
      jsonDecode(source) as Map<String, dynamic>;

  String _encode(Map<String, dynamic> message) => jsonEncode(message);
}
