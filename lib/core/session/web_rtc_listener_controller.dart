import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../audio/remote_audio_sink.dart';
import '../observability/reporting.dart';
import '../network/models/device_info.dart';
import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';
import '../network/signaling/signaling_channel.dart';
import '../network/webrtc/ice_servers.dart';
import '../network/webrtc/opus_sdp.dart';
import 'active_session.dart';

/// How long a peer connection may sit in the transient `disconnected` state
/// (WiFi blip, NAT rebinding) before the host is treated as gone.
const Duration _disconnectGrace = Duration(seconds: 10);

/// Listener-side controller for a **web-hosted** session: the audio source is
/// a browser running the Ampme web app, which streams its audio to this
/// device over WebRTC. A [SignalingChannel] — Supabase Realtime by default,
/// or the LAN relay — carries only the handshake (offer/answer/ICE); the
/// audio itself flows host -> listener directly, so latency stays low.
///
/// This is a live stream: there's no seekable position, no clock sync (the
/// host's clock is irrelevant — audio arrives in real time), and playback
/// starts as soon as the remote audio track arrives. It implements
/// [ActiveSession] so the join UI treats it exactly like a native-hosted
/// session.
class WebRtcListenerController extends ChangeNotifier
    implements ActiveSession {
  WebRtcListenerController({required this.selfDevice}) {
    _sink = RemoteAudioSink(onBlocked: _handleAudioBlocked);
  }

  final DeviceInfo selfDevice;

  late final RemoteAudioSink _sink;
  SignalingChannel? _signaling;
  StreamSubscription<Map<String, dynamic>>? _messagesSub;
  StreamSubscription<void>? _droppedSub;
  rtc.RTCPeerConnection? _pc;
  Timer? _positionTimer;
  Timer? _disconnectTimer;
  bool _disposed = false;
  bool _peerConnected = false;

  /// ICE candidates that arrived before the remote description was set are
  /// buffered here and flushed right after — the host's candidates can arrive
  /// while the native peer is still being created, and `addCandidate` before
  /// `setRemoteDescription` throws (dropping a candidate can strand the
  /// connection).
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
  bool needsAudioUnlock = false;

  @override
  bool get isLiveSession => true;

  /// Registers with the session over [signaling]. Resolves once the host
  /// acknowledged us; throws [SignalingException] if the session can't be
  /// found or the signaling service is unreachable.
  Future<void> connect(SignalingChannel signaling) async {
    _signaling = signaling;
    // Listen before connecting: the host's offer can follow its
    // acknowledgement immediately.
    _messagesSub = signaling.messages.listen(_handleMessage);
    final Map<String, dynamic> welcome;
    try {
      welcome = await signaling.connect();
    } catch (_) {
      await _teardown();
      rethrow;
    }
    sessionName = welcome['sessionName'] as String? ?? 'Web session';
    currentTrack = TrackInfo(
      trackId: welcome['code'] as String? ?? 'web',
      fileName: 'Live from web host',
      streamUrl: '',
      durationMs: 0,
      isLive: true,
    );
    _droppedSub = signaling.disconnected.listen((_) {
      // Signaling only matters until the peer is up; once audio flows
      // directly, losing it is harmless.
      if (!_peerConnected) _handleHostGone();
    });
    _notify();
  }

  void _handleMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'offer':
        unawaited(_answerOffer(message['sdp'] as String? ?? ''));
      case 'ice':
        unawaited(_addIceCandidate(message));
      case 'end':
        _handleHostGone();
      default:
        break;
    }
  }

  Future<void> _answerOffer(String sdp) async {
    if (sdp.isEmpty || _disposed) return;
    try {
      // A fresh offer (host re-connecting us) replaces any previous peer.
      await _teardownPeer();
      await RemoteAudioSink.prepare();
      final pc = await rtc.createPeerConnection(<String, dynamic>{
        'iceServers': iceServers(),
      });
      _pc = pc;
      _remoteDescriptionSet = false;
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return; // gathering complete
        _signaling?.send({
          'type': 'ice',
          'to': 'host',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };
      pc.onTrack = (event) {
        if (_disposed || event.track.kind != 'audio') return;
        if (event.streams.isNotEmpty) {
          unawaited(_sink.attach(event.streams.first, event.track));
        }
        playbackState = PlaybackState.playing;
        _startPositionTimer();
        _notify();
      };
      pc.onConnectionState = _handleConnectionState;

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
      // Ask the host for stereo, music-bitrate Opus instead of the mono
      // voice defaults.
      final answerSdp = withMusicOpusParams(answer.sdp ?? '');
      await pc.setLocalDescription(
        rtc.RTCSessionDescription(answerSdp, answer.type),
      );
      _signaling?.send({'type': 'answer', 'to': 'host', 'sdp': answerSdp});
    } catch (e, st) {
      reportError(e, st, context: 'answerWebRtcOffer');
    }
  }

  void _handleConnectionState(rtc.RTCPeerConnectionState state) {
    switch (state) {
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _peerConnected = true;
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
        if (isReconnecting) {
          isReconnecting = false;
          _notify();
        }
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Often transient; ICE recovers on its own within a few seconds.
        isReconnecting = true;
        _notify();
        _disconnectTimer ??= Timer(_disconnectGrace, _handleHostGone);
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _handleHostGone();
      default:
        break;
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

  void _handleAudioBlocked() {
    needsAudioUnlock = true;
    _notify();
  }

  /// Starts audio the browser refused to autoplay. Must be called from a
  /// user gesture (tap) handler.
  @override
  Future<void> unlockAudio() async {
    await _sink.resume();
    needsAudioUnlock = _sink.isBlocked;
    _notify();
  }

  void _handleHostGone() {
    if (hostLeft || _disposed) return;
    hostLeft = true;
    isReconnecting = false;
    playbackState = PlaybackState.stopped;
    _positionTimer?.cancel();
    _positionTimer = null;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    unawaited(_teardownPeer());
    unawaited(_sink.dispose());
    _notify();
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    final startedAt = DateTime.now();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      position = DateTime.now().difference(startedAt);
      _notify();
    });
  }

  @override
  Future<void> setLocalVolume(double value) async {
    volume = value;
    await _sink.setVolume(value);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _teardownPeer() async {
    final pc = _pc;
    _pc = null;
    _remoteDescriptionSet = false;
    _peerConnected = false;
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
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    await _teardownPeer();
    await _sink.dispose();
    await _messagesSub?.cancel();
    _messagesSub = null;
    await _droppedSub?.cancel();
    _droppedSub = null;
    final signaling = _signaling;
    _signaling = null;
    await signaling?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }
}
