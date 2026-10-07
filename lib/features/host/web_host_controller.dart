import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../../core/network/models/playback_state.dart';
import '../../core/network/models/track_info.dart';
import '../../core/network/signaling/signaling_channel.dart';
import '../../core/network/webrtc/ice_servers.dart';
import '../../core/observability/reporting.dart';

/// How far (in seconds) the host's *local* audible playback is delayed behind
/// the audio source when listeners are connected, so the host hears itself at
/// roughly the same instant the WebRTC listeners do (their path adds encode +
/// network + jitter-buffer latency). No delay when nobody is listening.
const double _listenerLeadSeconds = 0.06;

/// How long a listener's peer connection may sit in the transient
/// `disconnected` state before it's dropped from the session.
const Duration _disconnectGrace = Duration(seconds: 10);

/// Minimal typed views over the JS `RTCIceCandidateEvent` / `RTCIceCandidate`
/// objects, which package:web doesn't declare.
extension type _RtcIceEvent._(JSObject _) implements JSObject {
  external JSObject? get candidate;
}

extension type _RtcIceCandidate._(JSObject _) implements JSObject {
  external String get candidate;
  external String? get sdpMid;
  external int? get sdpMLineIndex;
}

/// Browser-side host for a web-hosted session. The browser can't run the
/// HTTP/WebSocket servers a native host runs, so instead it:
///
/// 1. Decodes a local audio file with WebAudio and plays it locally,
/// 2. Routes the same audio through a `MediaStreamDestination`, and
/// 3. Streams that track to every joined listener over WebRTC, exchanging
///    the handshake over a [SignalingChannel] — Supabase Realtime (works
///    from any page, the default) or the LAN relay (`tool/web_relay.dart`).
///
/// WebRTC keeps listener latency to roughly 30-80ms on a LAN (Opus 20ms +
/// NetEQ jitter buffer), which is the closest browsers can get to the
/// native file-streaming path. Sessions are live: no seeking on listeners.
class WebHostController extends ChangeNotifier {
  WebHostController();

  // ---- Session identity ----
  /// Empty until a session has started (and again after [end]).
  String sessionCode = '';
  String sessionName = '';

  /// What listeners type to join: `AMP-7KQ4ZD` (cloud) or
  /// `192.168.1.10:8080/AMP-7KQ4ZD` (LAN relay).
  String? joinCode;

  /// A link that opens the web app and joins directly (QR / share).
  String? joinLink;

  /// Set when the signaling connection drops mid-session: listeners already
  /// connected keep playing (WebRTC is direct), new ones can't join.
  bool signalingLost = false;

  // ---- Track / playback ----
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  double volume = 1.0;

  // ---- Connected listeners (id -> name) ----
  final Map<String, String> _listeners = {};
  List<String> get listenerNames => _listeners.values.toList(growable: false);
  int get listenerCount => _listeners.length;

  // ---- WebAudio graph ----
  web.AudioContext? _ctx;
  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _source;
  web.MediaStreamAudioDestinationNode? _destination;
  web.GainNode? _gain;
  double _startCtxTime = 0;
  double _startOffsetMs = 0;
  Timer? _positionTimer;

  // ---- Signaling ----
  SignalingChannel? _signaling;
  StreamSubscription<Map<String, dynamic>>? _messagesSub;
  StreamSubscription<void>? _droppedSub;
  JSFunction? _pageHideListener;

  // ---- WebRTC peers (listenerId -> connection) ----
  final Map<String, web.RTCPeerConnection> _pcs = {};
  final Map<String, Timer> _disconnectTimers = {};

  /// Listener ids whose remote description has been applied — until then,
  /// their ICE candidates are buffered ([_pendingIce]) because
  /// `addIceCandidate` before `setRemoteDescription` throws.
  final Set<String> _remoteSet = {};
  final Map<String, List<Map<String, dynamic>>> _pendingIce = {};

  String? errorMessage;
  bool _disposed = false;

  bool get isRunning => sessionCode.isNotEmpty;

  /// Starts a session over [signaling]. Resolves once the signaling service
  /// accepted this page as the host; throws (leaving the controller idle) if
  /// it can't be reached.
  Future<void> start({
    required SignalingChannel signaling,
    required String name,
    required String code,
    required String joinCode,
    String? joinLink,
  }) async {
    if (isRunning) await end();
    errorMessage = null;
    signalingLost = false;
    _signaling = signaling;
    _messagesSub = signaling.messages.listen(_handleMessage);
    _droppedSub = signaling.disconnected.listen((_) {
      if (!isRunning) return;
      signalingLost = true;
      _notify();
    });
    try {
      await signaling.connect();
    } catch (_) {
      await _teardownSignaling();
      rethrow;
    }
    sessionName = name;
    sessionCode = code;
    this.joinCode = joinCode;
    this.joinLink = joinLink;
    _installPageHideHook();
    _notify();
  }

  /// Decodes [bytes] (an audio file the user picked) and makes it the
  /// session's track. Any track already playing is stopped.
  Future<void> loadTrack(Uint8List bytes, String fileName) async {
    errorMessage = null;
    try {
      final ctx = _ctx ??= web.AudioContext();
      // Copy to a clean buffer so the ArrayBuffer handed to the decoder is
      // exactly the file bytes (file_picker views may be offset/sliced).
      final copy = Uint8List.fromList(bytes);
      final buffer = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
      _stopSource();
      _buffer = buffer;
      _destination ??= ctx.createMediaStreamDestination();
      _gain ??= ctx.createGain()
        ..gain.value = volume
        ..connect(ctx.destination);
      // Listeners may have joined before a track was loaded (the join code is
      // shown before the song is picked); they were recorded but never offered
      // a connection because there was no media stream yet. Connect them now.
      for (final id in _listeners.keys) {
        if (!_pcs.containsKey(id)) unawaited(_connectPeer(id));
      }
      currentTrack = TrackInfo(
        trackId: sessionCode,
        fileName: fileName,
        streamUrl: '',
        durationMs: (buffer.duration * 1000).round(),
        isLive: true,
      );
      position = Duration.zero;
      playbackState = PlaybackState.stopped;
      _notify();
    } catch (e, st) {
      errorMessage = 'Could not decode that audio file: $e';
      reportError(e, st, context: 'webHost.loadTrack');
      _notify();
    }
  }

  Future<void> play() async {
    final ctx = _ctx;
    final buffer = _buffer;
    if (ctx == null || buffer == null) return;
    try {
      if (ctx.state == 'suspended') {
        await ctx.resume().toDart;
      }
      // Finished? Start over instead of "playing" from the very end.
      final atEnd = position.inMilliseconds >= (buffer.duration * 1000).round();
      _startSource(atEnd ? Duration.zero : position);
      playbackState = PlaybackState.playing;
      _notify();
    } catch (e, st) {
      errorMessage = 'Playback failed: $e';
      reportError(e, st, context: 'webHost.play');
      _notify();
    }
  }

  Future<void> pause() async {
    final ctx = _ctx;
    if (ctx == null) return;
    try {
      if (ctx.state == 'running') {
        await ctx.suspend().toDart;
      }
      playbackState = PlaybackState.paused;
      _notify();
    } catch (e, st) {
      reportError(e, st, context: 'webHost.pause');
    }
  }

  Future<void> seek(Duration target) async {
    position = target;
    if (playbackState == PlaybackState.playing) {
      _startSource(target);
    }
    _notify();
  }

  Future<void> setVolume(double value) async {
    volume = value;
    _gain?.gain.value = value;
    _notify();
  }

  /// Starts a fresh [web.AudioBufferSourceNode] at [offset]. The local
  /// audible start is delayed by [_listenerLeadSeconds] when listeners are
  /// connected, so the host hears itself at roughly the same instant they do.
  void _startSource(Duration offset) {
    final ctx = _ctx;
    final buffer = _buffer;
    final destination = _destination;
    if (ctx == null || buffer == null || destination == null) return;

    _stopSource();

    final source = ctx.createBufferSource()
      ..buffer = buffer
      ..connect(destination)
      ..connect(_gain ?? ctx.destination);
    source.onended = ((web.Event _) {
      if (_source == source) {
        _source = null;
        _positionTimer?.cancel();
        playbackState = PlaybackState.stopped;
        position = Duration(milliseconds: (buffer.duration * 1000).round());
        _notify();
      }
    }).toJS;

    final lead = _listeners.isEmpty ? 0.0 : _listenerLeadSeconds;
    _startCtxTime = ctx.currentTime + lead;
    _startOffsetMs = offset.inMilliseconds.toDouble();
    source.start(_startCtxTime, offset.inMilliseconds / 1000.0);
    _source = source;
    _startPositionTimer();
  }

  /// Stops the current source node (if any) without firing its end handler.
  void _stopSource() {
    final old = _source;
    _source = null;
    _positionTimer?.cancel();
    _positionTimer = null;
    if (old == null) return;
    try {
      old.stop();
      old.disconnect();
    } catch (_) {
      // Already stopped/disconnected.
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    final ctx = _ctx;
    if (ctx == null) return;
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final source = _source;
      if (source == null) return;
      final elapsedMs =
          (ctx.currentTime - _startCtxTime) * 1000 + _startOffsetMs;
      final next = Duration(milliseconds: elapsedMs.round());
      final changed = next.inSeconds != position.inSeconds;
      position = next;
      if (changed) _notify();
    });
  }

  // ---- Signaling protocol ----

  void _handleMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'listener-joined':
        final id = message['id'] as String?;
        if (id == null) return;
        _listeners[id] = message['deviceName'] as String? ?? 'Unknown device';
        _notify();
        // A re-join (same id) replaces the old connection.
        unawaited(_closePeer(id).then((_) => _connectPeer(id)));
      case 'listener-left':
        final id = message['id'] as String?;
        if (id == null) return;
        _dropListener(id);
      case 'answer':
        final from = message['from'] as String?;
        final sdp = message['sdp'] as String?;
        if (from == null || sdp == null) return;
        unawaited(_applyAnswer(from, sdp));
      case 'ice':
        final from = message['from'] as String?;
        if (from == null) return;
        unawaited(_applyIceCandidate(from, message));
      default:
        break;
    }
  }

  Future<void> _connectPeer(String id) async {
    final destination = _destination;
    if (destination == null) return; // offered once a track is loaded
    try {
      final config = <String, Object?>{'iceServers': iceServers()}.jsify()
          as web.RTCConfiguration;
      final pc = web.RTCPeerConnection(config);
      _pcs[id] = pc;
      pc.onicecandidate = ((web.Event event) {
        final candidate = _candidateOf(event);
        if (candidate == null) return; // gathering complete
        _signaling?.send({
          'type': 'ice',
          'to': id,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }).toJS;
      pc.onconnectionstatechange = ((web.Event _) {
        if (_pcs[id] != pc) return; // superseded by a newer connection
        switch (pc.connectionState) {
          case 'connected':
            _disconnectTimers.remove(id)?.cancel();
          case 'disconnected':
            // Usually transient; give ICE a chance to recover.
            _disconnectTimers[id] ??= Timer(
              _disconnectGrace,
              () => _dropListener(id),
            );
          case 'failed':
          case 'closed':
            _dropListener(id);
        }
      }).toJS;

      final stream = destination.stream;
      for (final track in stream.getAudioTracks().toDart) {
        pc.addTrack(track, stream);
      }
      final offer = await pc.createOffer().toDart;
      if (offer == null) {
        throw StateError('createOffer returned no description.');
      }
      await pc
          .setLocalDescription(
            web.RTCLocalSessionDescriptionInit(type: offer.type, sdp: offer.sdp),
          )
          .toDart;
      _signaling?.send({'type': 'offer', 'to': id, 'sdp': offer.sdp});
    } catch (e, st) {
      errorMessage = 'Listener connection failed: $e';
      reportError(e, st, context: 'webHost.connectPeer');
      _notify();
    }
  }

  Future<void> _applyAnswer(String from, String sdp) async {
    final pc = _pcs[from];
    if (pc == null) return;
    try {
      await pc
          .setRemoteDescription(
            web.RTCSessionDescriptionInit(type: 'answer', sdp: sdp),
          )
          .toDart;
      _remoteSet.add(from);
      // Flush candidates that raced ahead of the answer.
      final pending = _pendingIce.remove(from);
      if (pending != null) {
        for (final message in pending) {
          await _applyIceCandidate(from, message);
        }
      }
    } catch (e, st) {
      reportError(e, st, context: 'webHost.applyAnswer');
    }
  }

  Future<void> _applyIceCandidate(
    String from,
    Map<String, dynamic> message,
  ) async {
    final pc = _pcs[from];
    if (pc == null || !_remoteSet.contains(from)) {
      // Remote description not applied yet (or the peer is still being
      // created) — hold the candidate.
      (_pendingIce[from] ??= []).add(message);
      return;
    }
    try {
      await pc
          .addIceCandidate(
            web.RTCIceCandidateInit(
              candidate: message['candidate'] as String? ?? '',
              sdpMid: message['sdpMid'] as String?,
              sdpMLineIndex: message['sdpMLineIndex'] as int?,
            ),
          )
          .toDart;
    } catch (e, st) {
      reportError(e, st, context: 'webHost.applyIceCandidate');
    }
  }

  void _dropListener(String id) {
    final removed = _listeners.remove(id) != null;
    unawaited(_closePeer(id));
    if (removed) _notify();
  }

  Future<void> _closePeer(String id) async {
    _disconnectTimers.remove(id)?.cancel();
    _remoteSet.remove(id);
    _pendingIce.remove(id);
    final pc = _pcs.remove(id);
    if (pc == null) return;
    try {
      pc.close();
    } catch (_) {
      // Already closed.
    }
  }

  /// package:web doesn't ship an `RTCIceCandidateEvent` type, so read the
  /// candidate fields straight off the JS event object via local extension
  /// types (the runtime object is a real RTCIceCandidate).
  ({String candidate, String? sdpMid, int? sdpMLineIndex})? _candidateOf(
    web.Event event,
  ) {
    final obj = (event as _RtcIceEvent).candidate;
    if (obj == null) return null;
    final c = obj as _RtcIceCandidate;
    return (candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex);
  }

  /// Tells listeners the session is over if the tab is closed or navigated
  /// away (best-effort: the page may be gone before the message leaves).
  void _installPageHideHook() {
    _removePageHideHook();
    final listener = ((web.Event _) {
      _signaling?.send({'type': 'end'});
    }).toJS;
    _pageHideListener = listener;
    web.window.addEventListener('pagehide', listener);
  }

  void _removePageHideHook() {
    final listener = _pageHideListener;
    _pageHideListener = null;
    if (listener != null) {
      web.window.removeEventListener('pagehide', listener);
    }
  }

  /// Ends the session: tells listeners, tears everything down, and returns
  /// the controller to its idle state so a new session can be started.
  Future<void> end() async {
    _signaling?.send({'type': 'end'});
    _removePageHideHook();
    _stopSource();
    for (final timer in _disconnectTimers.values) {
      timer.cancel();
    }
    _disconnectTimers.clear();
    for (final pc in _pcs.values) {
      try {
        pc.close();
      } catch (_) {}
    }
    _pcs.clear();
    _remoteSet.clear();
    _pendingIce.clear();
    _listeners.clear();

    sessionCode = '';
    joinCode = null;
    joinLink = null;
    signalingLost = false;
    currentTrack = null;
    _buffer = null;
    position = Duration.zero;
    playbackState = PlaybackState.stopped;

    final ctx = _ctx;
    _ctx = null;
    _destination = null;
    _gain = null;
    _notify();

    await _teardownSignaling();
    if (ctx != null) {
      try {
        await ctx.close().toDart;
      } catch (_) {
        // Already closed.
      }
    }
  }

  Future<void> _teardownSignaling() async {
    await _messagesSub?.cancel();
    _messagesSub = null;
    await _droppedSub?.cancel();
    _droppedSub = null;
    final signaling = _signaling;
    _signaling = null;
    await signaling?.close();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(end());
    super.dispose();
  }
}
