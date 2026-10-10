import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../utils/user_activation.dart';
import '../audio/audio_engine.dart';
import '../audio/bytes_uri.dart';
import '../audio/live_source.dart';
import '../audio/pcm_ring.dart';
import '../audio/remote_audio_sink.dart';
import '../network/default_receive_sink.dart';
import '../network/file_transfer.dart';
import '../network/live_frames.dart';
import '../network/models/device_info.dart';
import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';
import '../network/pipe_control_link.dart';
import '../network/signaling/signaling_channel.dart';
import '../network/webrtc/data_channels.dart';
import '../network/webrtc/ice_servers.dart';
import '../observability/reporting.dart';
import 'active_session.dart';
import 'listener_session_controller.dart';

/// How long a peer connection may sit in the transient `disconnected` state
/// (WiFi blip, NAT rebinding) before the host is treated as gone.
const Duration _disconnectGrace = Duration(seconds: 10);

/// Listener-side controller for a **web-hosted** session (a browser running
/// the Ampme web app).
///
/// The host sends the whole song to this device over a WebRTC data channel
/// and drives playback with the same protocol phone-hosted sessions use
/// (clock sync, prepare/ready, play at a scheduled host instant, periodic
/// position references), over a second data channel. So this is a thin
/// transport: the actual session logic is a [ListenerSessionController]
/// whose control link is the data channel and whose tracks resolve to the
/// received bytes — every device plays its own copy, started at the same
/// instant, instead of each one trailing a live stream by its own delay.
///
/// A [SignalingChannel] (Supabase Realtime, or the LAN relay) only carries the
/// WebRTC handshake.
class WebRtcListenerController extends ChangeNotifier implements ActiveSession {
  WebRtcListenerController({required this.selfDevice, AudioEngine? audioEngine}) {
    _session = ListenerSessionController(
      selfDevice: selfDevice,
      audioEngine: audioEngine ?? createWebSessionEngine(),
      trackResolver: _resolveTrack,
    )..addListener(_notify);
    _audioUnlocked = pageHasUserActivation;
  }

  final DeviceInfo selfDevice;

  late final ListenerSessionController _session;
  final FileReceiver _files = FileReceiver(sinkFactory: defaultReceiveSinkFactory);
  StreamSubscription<double>? _progressSub;

  /// Playable URI per received track (temp file / blob URL), reused when the
  /// session reloads the same track (e.g. after a reconnect).
  final Map<String, Uri> _uris = {};

  /// The live capture being received (only the newest epoch is kept).
  int? _liveEpoch;
  PcmRing? _liveRing;
  LiveSource? _liveSource;

  SignalingChannel? _signaling;
  StreamSubscription<Map<String, dynamic>>? _messagesSub;
  StreamSubscription<void>? _droppedSub;
  rtc.RTCPeerConnection? _pc;
  PipeControlLink? _link;
  StreamController<String>? _controlFrames;
  Timer? _disconnectTimer;
  bool _peerConnected = false;
  bool _disposed = false;
  bool _audioUnlocked = true;
  bool _hostGone = false;
  String? _signaledName;

  /// Fraction (0..1) of the current song received so far; null when idle.
  @override
  double? trackDownloadProgress;

  /// ICE candidates that arrived before the remote description was set.
  final _pendingCandidates = <rtc.RTCIceCandidate>[];
  bool _remoteDescriptionSet = false;

  // ---- ActiveSession surface (delegated to the inner session) ----
  @override
  String? get sessionName => _session.sessionName ?? _signaledName;
  @override
  TrackInfo? get currentTrack => _session.currentTrack;
  @override
  PlaybackState get playbackState => _session.playbackState;
  @override
  Duration get position => _session.position;
  @override
  double get volume => _session.volume;
  @override
  int get syncNudgeMs => _session.syncNudgeMs;
  @override
  void setSyncNudge(int ms) => _session.setSyncNudge(ms);
  @override
  bool get hostLeft => _hostGone || _session.hostLeft;
  @override
  bool get isReconnecting => _session.isReconnecting;
  @override
  int? get clockOffsetMs => _session.clockOffsetMs;
  @override
  int? get roundTripMs => _session.roundTripMs;
  @override
  bool get isLiveSession => false;
  @override
  bool get needsAudioUnlock => !_audioUnlocked && !hostLeft;

  /// Registers with the session over [signaling]. Resolves once the host
  /// acknowledged us; throws [SignalingException] if the session can't be
  /// found or the signaling service is unreachable.
  Future<void> connect(SignalingChannel signaling) async {
    _signaling = signaling;
    _progressSub = _files.progress.listen((p) {
      // The song is in: re-sync the clock on a now-idle link.
      if (p >= 1 && trackDownloadProgress != null) _link?.resetSync();
      trackDownloadProgress = p >= 1 ? null : p;
      _notify();
    });
    // Listen before connecting: the host's offer can follow its
    // acknowledgement immediately.
    _messagesSub = signaling.messages.listen(_handleSignal);
    final Map<String, dynamic> welcome;
    try {
      welcome = await signaling.connect();
    } catch (_) {
      await _teardown();
      rethrow;
    }
    _signaledName = welcome['sessionName'] as String? ?? 'Web session';
    _droppedSub = signaling.disconnected.listen((_) {
      // Signaling only matters until the peer is up; afterwards everything
      // flows over the direct connection.
      if (!_peerConnected) _handleHostGone();
    });
    _notify();
  }

  void _handleSignal(Map<String, dynamic> message) {
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
      // Android: keep the WebRTC stack on the media audio path so it never
      // switches the phone into call mode under the music player.
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
      pc.onDataChannel = (channel) {
        if (_pc != pc || _disposed) return;
        switch (channel.label) {
          case controlChannelLabel:
            _attachControl(channel);
          case fileChannelLabel:
            channel.onMessage = (m) => m.isBinary
                ? _files.handleBinary(m.binary)
                : _files.handleText(m.text);
          case liveChannelLabel:
            channel.onMessage = (m) {
              if (!m.isBinary) return;
              final f = LiveFrames.decode(m.binary);
              if (f == null) return;
              _liveRingFor(f.epoch, f.sampleRate)?.write(f.frame, f.pcm);
            };
        }
      };
      pc.onConnectionState = (state) {
        if (_pc == pc) _handleConnectionState(state);
      };

      await pc.setRemoteDescription(rtc.RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
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
      _signaling?.send({'type': 'answer', 'to': 'host', 'sdp': answer.sdp});
    } catch (e, st) {
      reportError(e, st, context: 'answerWebRtcOffer');
    }
  }

  /// Wires the control data channel into a [PipeControlLink] and hands it to
  /// the inner session. Frames are buffered from the first moment so the
  /// host's welcome can't be missed.
  void _attachControl(rtc.RTCDataChannel channel) {
    final frames = StreamController<String>();
    _controlFrames = frames;
    channel.onMessage = (m) {
      if (!m.isBinary && !frames.isClosed) frames.add(m.text);
    };
    final link = PipeControlLink(
      deviceId: selfDevice.deviceId,
      incoming: frames.stream,
      sendFrame: (frame) {
        if (channel.state != rtc.RTCDataChannelState.RTCDataChannelOpen) return;
        unawaited(
          channel.send(rtc.RTCDataChannelMessage(frame)).catchError((Object _) {}),
        );
      },
    );
    channel.onDataChannelState = (state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        link.syncNow(); // requests sent before "open" were dropped
      }
    };
    _link = link;
    _session.attach(link);
  }

  void _handleConnectionState(rtc.RTCPeerConnectionState state) {
    switch (state) {
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _peerConnected = true;
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
        _link?.setReconnecting(false);
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Often transient; ICE recovers on its own within a few seconds.
        _link?.setReconnecting(true);
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
      _pendingCandidates.add(candidate);
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } catch (e, st) {
      reportError(e, st, context: 'addWebRtcIceCandidate');
    }
  }

  /// The ring for live capture [epoch]; a newer epoch replaces an older one,
  /// and frames of an older one are ignored.
  PcmRing? _liveRingFor(int epoch, int sampleRate) {
    final current = _liveEpoch;
    if (current != null && epoch < current) return null;
    if (current == epoch && _liveRing != null) return _liveRing;
    _liveRing?.close();
    unawaited(_liveSource?.close());
    _liveSource = null;
    _liveEpoch = epoch;
    return _liveRing = PcmRing(channels: LiveFrames.channels, sampleRate: sampleRate);
  }

  /// [TrackResolver] for the inner session: waits for the song's bytes to
  /// arrive over the file channel and makes them playable locally; a live
  /// capture resolves to a stream of the frames arriving on the live channel.
  Future<Uri?> _resolveTrack(TrackInfo track) async {
    if (track.isLiveCapture) {
      final epoch = track.liveEpoch!;
      final ring = _liveRingFor(epoch, track.liveSampleRate!);
      if (ring == null) return null;
      return (_liveSource ??= await openLiveSource(ring, epoch)).uri;
    }
    final cached = _uris[track.trackId];
    if (cached != null) return cached;
    final file = await _files.waitFor(track.trackId);
    if (_disposed) return null;
    final uri = file.uri ??
        await bytesToUri(file.bytes!, name: track.fileName, mime: file.mime);
    // One song at a time: free the previous one.
    for (final old in _uris.values) {
      releaseBytesUri(old);
    }
    _uris
      ..clear()
      ..[track.trackId] = uri;
    return uri;
  }

  /// Starts audio the browser refused to autoplay. Must be called from a
  /// user gesture (tap) handler; the next position reference re-aligns it.
  @override
  Future<void> unlockAudio() async {
    _audioUnlocked = true;
    _notify();
    if (_session.hostIsPlaying) {
      await _session.audioEngine.play();
    }
  }

  @override
  Future<void> setLocalVolume(double value) => _session.setLocalVolume(value);

  void _handleHostGone() {
    if (_hostGone || _disposed) return;
    _hostGone = true;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    // Lets the inner session stop its audio and report the host as gone.
    _link?.close();
    unawaited(_session.audioEngine.pause().catchError((Object _) {}));
    unawaited(_teardownPeer());
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
    await _controlFrames?.close();
    _controlFrames = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {
        // Already closed.
      }
    }
  }

  Future<void> _teardown() async {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    await _teardownPeer();
    await _progressSub?.cancel();
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
    _session.removeListener(_notify);
    // Disposes the audio engine and the control link.
    _session.dispose();
    _files.dispose();
    for (final uri in _uris.values) {
      releaseBytesUri(uri);
    }
    _uris.clear();
    _liveRing?.close();
    unawaited(_liveSource?.close());
    unawaited(_teardown());
    super.dispose();
  }
}
