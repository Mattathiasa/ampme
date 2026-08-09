import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/models/playback_state.dart';
import '../../core/network/models/track_info.dart';
import '../../core/observability/reporting.dart';
import '../../utils/id_generator.dart';

/// How far (in seconds) the host's *local* audible playback is delayed behind
/// the audio source when listeners are connected, so the host hears itself at
/// roughly the same instant the WebRTC listeners do (their path adds encode +
/// network + jitter-buffer latency). No delay when nobody is listening.
const double _listenerLeadSeconds = 0.06;

/// Browser-side host for a web-hosted session. The browser can't run the
/// HTTP/WebSocket servers a native host runs, so instead it:
///
/// 1. Decodes a local audio file with WebAudio and plays it locally,
/// 2. Routes the same audio through a `MediaStreamDestination`, and
/// 3. Streams that track to every joined listener over WebRTC — signaled via
///    the LAN relay (`tool/web_relay.dart`), which both sides connect to
///    outbound.
///
/// WebRTC keeps listener latency to roughly 30-80ms on a LAN (Opus 20ms +
/// NetEQ jitter buffer), which is the closest browsers can get to the
/// native file-streaming path. Sessions are live: no seeking on listeners.
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

class WebHostController extends ChangeNotifier {
  WebHostController();

  // ---- Session identity / relay ----
  String sessionCode = '';
  String sessionName = '';
  String relayHost = '';
  int relayPort = 8080;
  String? joinCode; // "192.168.1.10:8080/AMP-4821"

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

  // ---- Relay connection ----
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Completer<void>? _started;

  // ---- WebRTC peers (listenerId -> connection) ----
  final Map<String, web.RTCPeerConnection> _pcs = {};

  /// Listener ids whose remote description has been applied — until then,
  /// their ICE candidates are buffered ([_pendingIce]) because
  /// `addIceCandidate` before `setRemoteDescription` throws.
  final Set<String> _remoteSet = {};
  final Map<String, List<Map<String, dynamic>>> _pendingIce = {};

  String? errorMessage;

  /// Resolves to `relayHost:relayPort` from the page's own origin when the
  /// page is served by the relay (the normal setup), so the join code shown
  /// to listeners is correct without any input.
  static String defaultRelayHost() => web.window.location.host;

  /// Starts a session: connects to the relay and registers this page as the
  /// host for a fresh session code. [relayHost]/[relayPort] default to the
  /// page's origin (i.e. the relay that served it).
  Future<void> start(
    String name, {
    String? relayHost,
    int? relayPort,
  }) async {
    errorMessage = null;
    sessionName = name;
    if (relayHost != null && relayHost.isNotEmpty) {
      this.relayHost = relayHost;
      if (relayPort != null) this.relayPort = relayPort;
    } else {
      final host = web.window.location.hostname;
      final port = web.window.location.port;
      this.relayHost = host.isEmpty ? 'localhost' : host;
      this.relayPort = port.isEmpty ? 8080 : int.tryParse(port) ?? 8080;
    }

    sessionCode = 'AMP-${generateId().substring(0, 4).toUpperCase()}';
    joinCode = '$relayHost:$relayPort/$sessionCode';

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://$relayHost:$relayPort/ws'),
    );
    _channel = channel;
    final started = Completer<void>();
    _started = started;
    _sub = channel.stream.listen(
      _handleMessage,
      onDone: () => _handleRelayClosed(),
      onError: (_) => _handleRelayClosed(),
      cancelOnError: false,
    );
    _send({
      'type': 'host',
      'code': sessionCode,
      'sessionName': sessionName,
    });
    notifyListeners();
    await started.future.timeout(const Duration(seconds: 10));
  }

  /// Decodes [bytes] (an audio file the user picked) and makes it the
  /// session's track.
  Future<void> loadTrack(Uint8List bytes, String fileName) async {
    errorMessage = null;
    try {
      final ctx = _ctx ??= web.AudioContext();
      // Copy to a clean buffer so the ArrayBuffer handed to the decoder is
      // exactly the file bytes (file_picker views may be offset/sliced).
      final copy = Uint8List.fromList(bytes);
      final buffer = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
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
      notifyListeners();
    } catch (e, st) {
      errorMessage = 'Could not decode that audio file: $e';
      reportError(e, st, context: 'webHost.loadTrack');
      notifyListeners();
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
      _startSource(position);
      playbackState = PlaybackState.playing;
      notifyListeners();
    } catch (e, st) {
      errorMessage = 'Playback failed: $e';
      reportError(e, st, context: 'webHost.play');
      notifyListeners();
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
      notifyListeners();
    } catch (e, st) {
      reportError(e, st, context: 'webHost.pause');
    }
  }

  Future<void> seek(Duration target) async {
    position = target;
    if (playbackState == PlaybackState.playing) {
      _startSource(target);
    }
    notifyListeners();
  }

  Future<void> setVolume(double value) async {
    volume = value;
    _gain?.gain.value = value;
    notifyListeners();
  }

  /// Starts a fresh [web.AudioBufferSourceNode] at [offset]. The local
  /// audible start is delayed by [_listenerLeadSeconds] when listeners are
  /// connected, so the host hears itself at roughly the same instant they do.
  void _startSource(Duration offset) {
    final ctx = _ctx;
    final buffer = _buffer;
    final destination = _destination;
    if (ctx == null || buffer == null || destination == null) return;

    final old = _source;
    _source = null;
    try {
      old?.stop();
      old?.disconnect();
    } catch (_) {
      // Already stopped/disconnected.
    }

    final source = ctx.createBufferSource()
      ..buffer = buffer
      ..connect(destination)
      ..connect(_gain ?? ctx.destination);
    source.onended = ((web.Event _) {
      if (_source == source) {
        _source = null;
        playbackState = PlaybackState.stopped;
        position = Duration(milliseconds: (buffer.duration * 1000).round());
        notifyListeners();
      }
    }).toJS;

    final lead = _listeners.isEmpty ? 0.0 : _listenerLeadSeconds;
    _startCtxTime = ctx.currentTime + lead;
    _startOffsetMs = offset.inMilliseconds.toDouble();
    source.start(_startCtxTime, offset.inMilliseconds / 1000.0);
    _source = source;
    _startPositionTimer();
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
      if (changed) notifyListeners();
    });
  }

  // ---- Relay protocol ----

  void _handleMessage(dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (message['type']) {
      case 'welcome':
        _started?.complete();
        _started = null;
      case 'listener-joined':
        final id = message['id'] as String?;
        if (id == null) return;
        _listeners[id] = message['deviceName'] as String? ?? 'Unknown device';
        notifyListeners();
        unawaited(_connectPeer(id));
      case 'listener-left':
        final id = message['id'] as String?;
        if (id == null) return;
        _listeners.remove(id);
        unawaited(_closePeer(id));
        notifyListeners();
      case 'answer':
        final from = message['from'] as String?;
        final sdp = message['sdp'] as String?;
        if (from == null || sdp == null) return;
        unawaited(_applyAnswer(from, sdp));
      case 'ice':
        final from = message['from'] as String?;
        if (from == null) return;
        unawaited(_applyIceCandidate(from, message));
      case 'end':
      case 'error':
        break; // handled via relay close / errors below
      default:
        break;
    }
  }

  void _handleRelayClosed() {
    final started = _started;
    if (started != null && !started.isCompleted) {
      started.completeError(StateError('Could not reach the relay.'));
      _started = null;
    }
    // The session can keep running without the relay once peers are
    // connected (WebRTC is direct); new listeners just can't join.
  }

  Future<void> _connectPeer(String id) async {
    final destination = _destination;
    if (destination == null) return;
    try {
      final pc = web.RTCPeerConnection();
      _pcs[id] = pc;
      pc.onicecandidate = ((web.Event event) {
        final candidate = _candidateOf(event);
        if (candidate == null) return; // gathering complete
        _send({
          'type': 'ice',
          'code': sessionCode,
          'to': id,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }).toJS;
      pc.onconnectionstatechange = ((web.Event _) {
        final state = pc.connectionState;
        if (state == 'failed' || state == 'closed' || state == 'disconnected') {
          _listeners.remove(id);
          _pcs.remove(id);
          notifyListeners();
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
      _send({
        'type': 'offer',
        'code': sessionCode,
        'to': id,
        'sdp': offer.sdp,
      });
    } catch (e, st) {
      errorMessage = 'Listener connection failed: $e';
      reportError(e, st, context: 'webHost.connectPeer');
      notifyListeners();
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
    if (pc == null) return;
    if (!_remoteSet.contains(from)) {
      // Remote description not applied yet — hold the candidate.
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

  Future<void> _closePeer(String id) async {
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

  /// Ends the session: tells listeners over the relay, then tears down
  /// everything.
  Future<void> end() async {
    _send({'type': 'end', 'code': sessionCode});
    _positionTimer?.cancel();
    _positionTimer = null;
    for (final pc in _pcs.values) {
      try {
        pc.close();
      } catch (_) {}
    }
    _pcs.clear();
    _listeners.clear();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  void _send(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // Relay gone; peers already connected keep playing.
    }
  }

  @override
  void dispose() {
    unawaited(end());
    super.dispose();
  }
}
