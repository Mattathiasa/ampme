import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../../core/network/file_transfer.dart';
import '../../core/network/models/control_message.dart';
import '../../core/network/models/playback_state.dart';
import '../../core/network/models/track_info.dart';
import '../../core/network/signaling/signaling_channel.dart';
import '../../core/network/webrtc/data_channels.dart';
import '../../core/network/webrtc/ice_servers.dart';
import '../../core/observability/reporting.dart';
import '../../core/sync/acoustic_calibration.dart';
import '../../utils/id_generator.dart';
import '../../core/audio/live_pcm_player.dart';
import '../../core/audio/pcm_ring.dart';
import '../../core/network/live_frames.dart';
import 'audio_extract.dart';
import 'sync_math.dart';
import 'web_live_capture.dart';

/// Range of the host's own speaker offset (ms). Positive delays this
/// browser's speaker relative to the phones (use it if the host still sounds
/// ahead, e.g. because a phone is on Bluetooth).
const int minSpeakerOffsetMs = -300;
const int maxSpeakerOffsetMs = 500;

const String _speakerOffsetStorageKey = 'ampme.speakerOffsetMs';

/// How far behind a shared tab every device (this one included) plays it:
/// room for the audio to reach every phone and be buffered there.
const int liveDelayMs = 1000;

/// Live audio history sent to a device that joins mid-share (so it can start
/// on the shared timeline straight away).
const int _liveHistoryMs = liveDelayMs + 3000;

/// Above this much queued live audio, a slow device skips frames (heard as a
/// brief gap) instead of falling ever further behind.
const int _maxBufferedLiveBytes = 512 * 1024;

/// The sender id this host uses in control messages.
const String _hostId = 'host';

/// How long a listener's peer connection may sit in the transient
/// `disconnected` state before it's dropped from the session.
const Duration _disconnectGrace = Duration(seconds: 10);

/// How long a play/seek waits for listeners to confirm they're buffered.
const Duration _readyAckTimeout = Duration(milliseconds: 1500);

/// A listener that opened the control channel but never spoke the protocol
/// within this long runs an older app version (it expects a live stream).
const Duration _protocolTimeout = Duration(seconds: 6);

/// Keep at most this much song data queued per listener, so control
/// messages (clock sync!) never sit behind megabytes of file data.
const int _maxBufferedFileBytes = 256 * 1024;

/// Minimal typed views over the JS `RTCIceCandidateEvent` / `RTCIceCandidate`
/// / `RTCDataChannelEvent` objects, which package:web doesn't declare.
extension type _RtcIceEvent._(JSObject _) implements JSObject {
  external JSObject? get candidate;
}

extension type _RtcIceCandidate._(JSObject _) implements JSObject {
  external String get candidate;
  external String? get sdpMid;
  external int? get sdpMLineIndex;
}

/// What the host screen shows for each connected device.
enum ListenerPhase { connecting, receivingSong, ready, needsUpdate }

class WebListener {
  WebListener(this.id, this.name);

  final String id;
  String name;
  ListenerPhase phase = ListenerPhase.connecting;

  /// Fraction of the current song sent to this device.
  double fileProgress = 0;

  /// Smoothed distance between this device's playhead and the host's (ms,
  /// positive = ahead). Null until it reports while playing.
  int? driftMs;

  /// The device's measured clock-sync round trip (ms).
  int? roundTripMs;
}

/// Per-listener WebRTC state.
class _Peer {
  _Peer(this.pc);

  final web.RTCPeerConnection pc;
  web.RTCDataChannel? control;
  web.RTCDataChannel? file;
  web.RTCDataChannel? live;
  bool remoteSet = false;
  final List<Map<String, dynamic>> pendingIce = [];
  Timer? disconnectTimer;
  Timer? protocolTimer;
  bool spokeProtocol = false;

  /// Track whose bytes were fully queued to this listener / are being sent.
  String? sentTrackId;
  String? sendingTrackId;
}

/// Browser-side host for a web-hosted session.
///
/// Every device plays **its own copy** of the song, started at the same
/// instant — the same scheme phone-hosted sessions use, so a browser host,
/// Android app listeners and browser listeners stay in step with each other:
///
/// 1. The song file is sent to each listener over a WebRTC data channel.
/// 2. A second data channel carries the sync protocol ([ControlMessage]):
///    NTP-style clock sync, `prepare`/`ready`, `play`/`seek` at a scheduled
///    host wall-clock instant, and a position reference every second that
///    listeners use to correct drift.
/// 3. The host's own speaker plays the song through WebAudio, started at
///    that same instant.
///
/// A [SignalingChannel] — Supabase Realtime (works from any page, the
/// default) or the LAN relay (`tool/web_relay.dart`) — only carries the
/// WebRTC handshake.
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

  /// Shifts this browser's own speaker relative to the shared timeline (ms).
  /// Remembered in this browser across sessions.
  int speakerOffsetMs = _loadSpeakerOffset();

  static int _loadSpeakerOffset() {
    try {
      final v = int.tryParse(
        web.window.localStorage.getItem(_speakerOffsetStorageKey) ?? '',
      );
      return (v ?? 0).clamp(minSpeakerOffsetMs, maxSpeakerOffsetMs);
    } catch (_) {
      return 0; // storage blocked (private mode etc.)
    }
  }

  // ---- Track / playback ----
  TrackInfo? currentTrack;
  PlaybackState playbackState = PlaybackState.stopped;
  Duration position = Duration.zero;
  double volume = 1.0;
  /// What listeners receive: the picked song, or a video's sound only.
  Uint8List? _fileBytes;
  String? _fileMime;
  String? _fileSendName;

  /// 0..1 while a video's sound is being prepared for the phones.
  double? preparingSoundProgress;

  // ---- Shared tab (live capture) ----
  WebLiveCapture? _capture;
  PcmRing? _liveRing;
  LivePcmPlayer? _livePlayer;
  int _liveEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000 & 0x3fffffff;
  StreamSubscription<CaptureBatch>? _captureSub;

  /// True while a browser tab's audio is being shared.
  bool get isSharingTab => _capture != null;

  /// True once the shared tab's audio is playing on the shared timeline.
  bool get liveIsPlaying => _livePlayer?.isPlaying ?? false;

  /// Whether this browser can share a tab's audio at all.
  bool get canShareTab => canCaptureTabAudio;

  /// Something is audibly playing on the shared timeline (song or tab).
  bool get _audible => _source != null || liveIsPlaying;

  /// For a video file: the muted `<video>` the host screen shows. Its picture
  /// follows the WebAudio timeline (the sound everyone hears).
  web.HTMLVideoElement? get video => _video;
  web.HTMLVideoElement? _video;
  String? _videoUrl;
  Timer? _videoStartTimer;
  Timer? _videoSyncTimer;

  // ---- Connected listeners ----
  final Map<String, WebListener> _listeners = {};
  List<WebListener> get listeners => _listeners.values.toList(growable: false);
  int get listenerCount => _listeners.length;

  // ---- WebAudio ----
  web.AudioContext? _ctx;
  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _source;
  web.GainNode? _gain;

  // ---- Visualizer ----
  web.AnalyserNode? _analyser;
  JSUint8Array? _bins;
  List<double> _bands = const [];

  /// The running source plays song position [_anchorOffsetMs] at context
  /// time [_anchorCtxTime] (seconds), shifted by [_anchorSpeakerOffsetMs].
  double _anchorCtxTime = 0;
  double _anchorOffsetMs = 0;
  int _anchorSpeakerOffsetMs = 0;
  Timer? _positionTimer;
  Timer? _referenceTimer;

  /// Serializes play/seek handshakes so their prepare/ready windows and
  /// scheduled instants never interleave.
  Future<void>? _inFlightStart;
  final Set<String> _readyAcks = {};
  bool _awaitingReadyAcks = false;

  // ---- Signaling ----
  SignalingChannel? _signaling;
  StreamSubscription<Map<String, dynamic>>? _messagesSub;
  StreamSubscription<void>? _droppedSub;
  JSFunction? _pageHideListener;

  // ---- WebRTC peers (listenerId -> connection) ----
  final Map<String, _Peer> _peers = {};

  String? errorMessage;
  bool _disposed = false;

  bool get isRunning => sessionCode.isNotEmpty;

  /// What this browser is playing right now as [bands] levels in 0..1
  /// (log-spaced, bass first) — the host visualizer's input. Null until
  /// audio has been set up.
  List<double>? spectrum(int bands) {
    final ctx = _ctx;
    final gain = _gain;
    if (ctx == null || gain == null) return null;
    var analyser = _analyser;
    var bins = _bins;
    if (analyser == null || bins == null) {
      analyser = _analyser = ctx.createAnalyser()
        ..fftSize = 1024
        ..smoothingTimeConstant = 0.7;
      // An analyser only runs while the graph pulls it, so route it to the
      // destination through a muted gain (the sound itself is unaffected).
      final mute = ctx.createGain()..gain.value = 0;
      gain.connect(analyser);
      analyser.connect(mute);
      mute.connect(ctx.destination);
      bins = _bins = Uint8List(analyser.frequencyBinCount).toJS;
    }
    analyser.getByteFrequencyData(bins);
    final data = bins.toDart;
    // Up to ~11 kHz: above that there's little energy to show.
    final usable = (data.length * 0.5).floor();
    if (_bands.length != bands) _bands = List<double>.filled(bands, 0);
    final out = _bands;
    for (var i = 0; i < bands; i++) {
      final lo = math.pow(usable, i / bands).floor().clamp(1, usable - 1);
      final hi = math.max(lo + 1, math.pow(usable, (i + 1) / bands).floor()).clamp(lo + 1, usable);
      var sum = 0;
      for (var b = lo; b < hi; b++) {
        sum += data[b];
      }
      out[i] = math.pow(sum / (hi - lo) / 255, 1.6).toDouble();
    }
    return out;
  }

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
    _messagesSub = signaling.messages.listen(_handleSignal);
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

  // ---- Track loading ----

  /// Decodes [bytes] (an audio or video file the user picked), makes it the
  /// session's track and starts copying it to every listener. Any track
  /// already playing is stopped. For a video, this page shows the picture and
  /// every device (this one included) plays its sound.
  Future<void> loadTrack(Uint8List bytes, String fileName) async {
    errorMessage = null;
    if (isSharingTab) stopTabShare();
    try {
      final ctx = _ctx ??= web.AudioContext();
      // Decode a copy: decodeAudioData detaches the ArrayBuffer it's given,
      // and the original bytes still have to be sent to listeners.
      final copy = Uint8List.fromList(bytes);
      final buffer = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
      _stopSource();
      _stopReferenceTimer();
      _buffer = buffer;
      _gain ??= ctx.createGain()
        ..gain.value = volume
        ..connect(ctx.destination);
      final hasVideo = isVideoFile(fileName);
      _setVideo(hasVideo ? bytes : null, mime: audioMimeFor(fileName));
      if (hasVideo) {
        // Phones only play the sound: send them an audio-only copy, not the
        // video (smaller, and they never decode a picture nobody sees).
        preparingSoundProgress = 0;
        _notify();
        final audio = await extractAudio(
          buffer,
          onProgress: (p) {
            preparingSoundProgress = p;
            _notify();
          },
        );
        preparingSoundProgress = null;
        _fileBytes = audio.bytes;
        _fileMime = audio.mime;
        _fileSendName = '${_baseName(fileName)}.${audio.extension}';
      } else {
        _fileBytes = bytes;
        _fileMime = audioMimeFor(fileName);
        _fileSendName = fileName;
      }
      final track = TrackInfo(
        trackId: generateId(),
        fileName: fileName,
        streamUrl: '',
        durationMs: (buffer.duration * 1000).round(),
        hasVideo: hasVideo,
      );
      currentTrack = track;
      position = Duration.zero;
      playbackState = PlaybackState.stopped;
      for (final entry in _peers.entries) {
        if (_isOpen(entry.value.control)) {
          _send(entry.key, ControlMessage.trackChanged(senderId: _hostId, track: track));
        }
        unawaited(_sendFile(entry.key));
      }
      _notify();
    } catch (e, st) {
      preparingSoundProgress = null;
      errorMessage = 'Could not read the sound in that file '
          '(is it a format this browser plays?): $e';
      reportError(e, st, context: 'webHost.loadTrack');
      _notify();
    }
  }

  // ---- Transport ----

  Future<void> play() async {
    final ctx = _ctx;
    final track = currentTrack;
    final buffer = _buffer;
    if (ctx == null || track == null || buffer == null) return;
    try {
      // Resume inside the tap (browsers only allow audio after a gesture).
      if (ctx.state != 'running') {
        await ctx.resume().toDart;
      }
      final atEnd = position.inMilliseconds >= track.durationMs - 50;
      await _synchronizedStart(atEnd ? Duration.zero : position, asSeek: false);
    } catch (e, st) {
      errorMessage = 'Playback failed: $e';
      reportError(e, st, context: 'webHost.play');
      _notify();
    }
  }

  Future<void> pause() async {
    final track = currentTrack;
    if (track == null) return;
    if (playbackState == PlaybackState.playing) {
      position = Duration(milliseconds: _timelinePositionAt(_nowMs()));
    }
    _stopSource();
    _stopReferenceTimer();
    playbackState = PlaybackState.paused;
    _broadcast(
      ControlMessage.pause(
        senderId: _hostId,
        trackId: track.trackId,
        positionMs: position.inMilliseconds,
        hostTimeMs: _nowMs(),
      ),
    );
    _notify();
  }

  Future<void> seek(Duration target) async {
    final track = currentTrack;
    if (track == null) return;
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(0, track.durationMs),
    );
    position = clamped;
    if (playbackState == PlaybackState.playing) {
      await _synchronizedStart(clamped, asSeek: true);
    } else {
      _video?.currentTime = clamped.inMilliseconds / 1000; // show that frame
      _notify();
    }
  }

  Future<void> setVolume(double value) async {
    volume = value;
    _gain?.gain.value = value;
    _livePlayer?.volume = value;
    _notify();
  }

  /// Moves this browser's speaker relative to the phones, live.
  Future<void> setSpeakerOffset(int ms) async {
    speakerOffsetMs = ms.clamp(minSpeakerOffsetMs, maxSpeakerOffsetMs);
    try {
      web.window.localStorage.setItem(_speakerOffsetStorageKey, '$speakerOffsetMs');
    } catch (_) {}
    if (playbackState == PlaybackState.playing && _source != null) {
      // Re-start the local source on the same timeline with the new offset.
      final at = _nowMs() + 60;
      _startSourceAt(at, Duration(milliseconds: _timelinePositionAt(at)));
    }
    _notify();
  }

  /// Asks every listener to pre-buffer at [startPosition], waits (bounded)
  /// for them to confirm, then picks a start instant far enough ahead for
  /// the command to reach everyone and starts all devices — this browser's
  /// speaker included — at that instant.
  Future<void> _synchronizedStart(Duration startPosition, {required bool asSeek}) async {
    while (_inFlightStart != null) {
      await _inFlightStart;
    }
    final run = _doSynchronizedStart(startPosition, asSeek: asSeek);
    _inFlightStart = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightStart, run)) _inFlightStart = null;
    }
  }

  Future<void> _doSynchronizedStart(Duration startPosition, {required bool asSeek}) async {
    final track = currentTrack;
    if (track == null) return;
    // Silence the old playhead right away (a seek shouldn't keep playing
    // the old spot during the handshake).
    _stopSource();
    _stopReferenceTimer();
    playbackState = PlaybackState.playing;
    position = startPosition;
    _notify();

    // Only devices that already hold this song can confirm; the others
    // catch up (seek into place) as soon as their copy arrives.
    final waitingFor = [
      for (final entry in _peers.entries)
        if (_isOpen(entry.value.control) && entry.value.sentTrackId == track.trackId)
          entry.key,
    ];
    if (waitingFor.isNotEmpty) {
      _readyAcks.clear();
      _awaitingReadyAcks = true;
      try {
        _broadcast(
          ControlMessage.prepare(
            senderId: _hostId,
            trackId: track.trackId,
            positionMs: startPosition.inMilliseconds,
          ),
        );
        final deadline = DateTime.now().add(_readyAckTimeout);
        while (DateTime.now().isBefore(deadline)) {
          final pending = waitingFor.where(
            (id) => !_readyAcks.contains(id) && _peers.containsKey(id),
          );
          if (pending.isEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } finally {
        _awaitingReadyAcks = false;
      }
    }
    // The user may have paused or changed the song during the handshake.
    if (currentTrack != track || playbackState != PlaybackState.playing) return;

    final lead = startLeadMs(
      _listeners.values.map((l) => l.roundTripMs).whereType<int>(),
    );
    final startAt = _nowMs() + lead;
    _startSourceAt(startAt, startPosition);
    final message = asSeek
        ? ControlMessage.seek(
            senderId: _hostId,
            trackId: track.trackId,
            positionMs: startPosition.inMilliseconds,
            startAtHostTimeMs: startAt,
          )
        : ControlMessage.play(
            senderId: _hostId,
            trackId: track.trackId,
            positionMs: startPosition.inMilliseconds,
            startAtHostTimeMs: startAt,
          );
    _broadcast(message);
    _startReferenceTimer();
    _notify();
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Starts this browser's speaker so that song position [offset] plays at
  /// host wall time [atWallMs] (plus [speakerOffsetMs]).
  void _startSourceAt(int atWallMs, Duration offset) {
    final ctx = _ctx;
    final buffer = _buffer;
    final gain = _gain;
    if (ctx == null || buffer == null || gain == null) return;
    _stopSource();

    final source = ctx.createBufferSource()
      ..buffer = buffer
      ..connect(gain);
    source.onended = ((web.Event _) {
      if (_source != source) return;
      _source = null;
      _positionTimer?.cancel();
      _stopReferenceTimer();
      playbackState = PlaybackState.stopped;
      position = Duration(milliseconds: (buffer.duration * 1000).round());
      _stopVideo();
      _notify();
    }).toJS;

    // Wall time -> context time, sampled together so the mapping is fresh.
    final ctxNow = ctx.currentTime;
    final wallNow = _nowMs();
    var when = ctxNow + (atWallMs - wallNow + speakerOffsetMs) / 1000.0;
    var offsetSec = offset.inMilliseconds / 1000.0;
    if (when < ctxNow) {
      // Already late: start now, further into the song.
      offsetSec += ctxNow - when;
      when = ctxNow;
    }
    _anchorCtxTime = when;
    _anchorOffsetMs = offsetSec * 1000;
    _anchorSpeakerOffsetMs = speakerOffsetMs;
    if (offsetSec >= buffer.duration) return;
    source.start(when, offsetSec);
    _source = source;
    _startPositionTimer();
    _startVideo(when, offsetSec);
  }

  // ---- Shared tab (live capture) ----

  /// Asks the user to pick a browser tab and shares its audio: every device
  /// (this one included) plays it [liveDelayMs] after the tab, together.
  Future<void> startTabShare() async {
    errorMessage = null;
    final ctx = _ctx ??= web.AudioContext();
    try {
      if (ctx.state != 'running') await ctx.resume().toDart;
      final capture = await WebLiveCapture.pickTab(ctx);
      if (isSharingTab) stopTabShare(announce: false);
      // The tab replaces any song or video.
      _stopSource();
      _stopReferenceTimer();
      _setVideo(null);
      _buffer = null;
      _fileBytes = null;
      _fileMime = null;
      _fileSendName = null;
      _gain ??= ctx.createGain()
        ..gain.value = volume
        ..connect(ctx.destination);

      final rate = ctx.sampleRate.round();
      final epoch = ++_liveEpoch;
      final ring = PcmRing(channels: LiveFrames.channels, sampleRate: rate, capacitySeconds: 30);
      _capture = capture;
      _liveRing = ring;
      _livePlayer = LivePcmPlayer(ctx, ring, destination: _gain)..volume = volume;
      capture.onEnded(() {
        if (identical(_capture, capture)) stopTabShare();
      });
      final track = TrackInfo(
        trackId: generateId(),
        fileName: 'Shared tab audio',
        streamUrl: '',
        durationMs: 0,
        liveEpoch: epoch,
        liveSampleRate: rate,
      );
      currentTrack = track;
      position = Duration.zero;
      playbackState = PlaybackState.playing;
      _broadcast(ControlMessage.trackChanged(senderId: _hostId, track: track));
      for (final l in _listeners.values) {
        if (l.phase != ListenerPhase.needsUpdate) l.phase = ListenerPhase.ready;
      }
      _captureSub = capture.batches.listen((b) => _handleCaptureBatch(track, epoch, rate, b));
      _notify();
    } catch (e, st) {
      final cancelled = e.toString().contains('NotAllowedError') ||
          e.toString().contains('AbortError');
      if (!cancelled) {
        errorMessage = e is StateError ? e.message : 'Could not share that tab: $e';
        reportError(e, st, context: 'webHost.startTabShare');
      }
      _notify();
    }
  }

  void _handleCaptureBatch(TrackInfo track, int epoch, int rate, CaptureBatch b) {
    final ring = _liveRing;
    final player = _livePlayer;
    final ctx = _ctx;
    if (ring == null || player == null || ctx == null || currentTrack != track) return;
    if (player.startWallMs == null) {
      // Frame 0 was captured at this wall time; everyone hears it
      // [liveDelayMs] later.
      final capturedAt = _nowMs() - ((ctx.currentTime - b.ctxTime) * 1000).round() -
          (b.frame * 1000 ~/ rate);
      final startWall = capturedAt + liveDelayMs;
      player.start(startWall);
      _broadcast(
        ControlMessage.play(
          senderId: _hostId,
          trackId: track.trackId,
          positionMs: 0,
          startAtHostTimeMs: startWall,
        ),
      );
      _startReferenceTimer();
    }
    final pcm = LiveFrames.interleave([b.left, b.right]);
    ring.write(b.frame, pcm);
    final message = LiveFrames.encode(epoch: epoch, sampleRate: rate, frame: b.frame, pcm: pcm);
    for (final peer in _peers.values) {
      final ch = peer.live;
      if (!_isOpen(ch) || ch!.bufferedAmount > _maxBufferedLiveBytes) continue;
      try {
        ch.send(message.toJS);
      } catch (_) {}
    }
  }

  /// Sends a device that just connected the recent shared-tab audio, so it
  /// can start on the timeline right away.
  void _sendLiveHistory(String id) {
    final ch = _peers[id]?.live;
    final ring = _liveRing;
    final track = currentTrack;
    if (!_isOpen(ch) || ring == null || track == null || !track.isLiveCapture) return;
    final rate = ring.sampleRate;
    var frame = ring.endFrame - rate * _liveHistoryMs ~/ 1000;
    if (frame < ring.startFrame) frame = ring.startFrame;
    const block = 4096;
    while (frame < ring.endFrame) {
      final n = ring.endFrame - frame < block ? ring.endFrame - frame : block;
      final pcm = Int16List(n * ring.channels);
      ring.read(frame, pcm);
      try {
        ch!.send(
          LiveFrames.encode(epoch: track.liveEpoch!, sampleRate: rate, frame: frame, pcm: pcm).toJS,
        );
      } catch (_) {
        return;
      }
      frame += n;
    }
    _listeners[id]?.phase = ListenerPhase.ready;
    _notify();
  }

  /// Stops sharing the tab; listeners stop too ([announce]).
  void stopTabShare({bool announce = true}) {
    final capture = _capture;
    if (capture == null) return;
    final track = currentTrack;
    final pos = _timelinePositionAt(_nowMs());
    _capture = null;
    unawaited(_captureSub?.cancel());
    _captureSub = null;
    capture.stop();
    _livePlayer?.dispose();
    _livePlayer = null;
    _liveRing?.close();
    _liveRing = null;
    _stopReferenceTimer();
    if (announce && track != null) {
      _broadcast(
        ControlMessage.pause(
          senderId: _hostId,
          trackId: track.trackId,
          positionMs: pos,
          hostTimeMs: _nowMs(),
        ),
      );
    }
    currentTrack = null;
    playbackState = PlaybackState.stopped;
    position = Duration.zero;
    _notify();
  }

  // ---- Video (picture follows the sound) ----

  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  void _setVideo(Uint8List? bytes, {String? mime}) {
    _stopVideo();
    final oldUrl = _videoUrl;
    _video?.remove();
    _video = null;
    _videoUrl = null;
    if (oldUrl != null) web.URL.revokeObjectURL(oldUrl);
    if (bytes == null) return;
    final url = web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime ?? 'video/mp4')),
    );
    _videoUrl = url;
    _video = (web.document.createElement('video') as web.HTMLVideoElement)
      ..muted = true // the sound comes from the WebAudio timeline
      ..playsInline = true
      ..preload = 'auto'
      ..controls = false
      ..src = url
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = 'black';
  }

  /// Starts the picture at context time [when] from [offsetSec], then keeps
  /// it on the sound: tiny drift is absorbed by the playback rate, larger
  /// drift by a seek.
  void _startVideo(double when, double offsetSec) {
    final video = _video;
    final ctx = _ctx;
    if (video == null || ctx == null) return;
    _stopVideo();
    video.currentTime = offsetSec;
    video.playbackRate = 1;
    final delayMs = ((when - ctx.currentTime) * 1000).round();
    _videoStartTimer = Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), () {
      video.play().toDart.catchError((Object _) => null);
    });
    _videoSyncTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_source == null || video.paused) return;
      final soundMs = _audibleSoundPositionMs();
      if (soundMs == null) return;
      final drift = (video.currentTime * 1000 - soundMs).round();
      final fix = videoCorrection(drift);
      if (fix.seek) {
        video
          ..currentTime = soundMs / 1000
          ..playbackRate = 1;
      } else {
        video.playbackRate = fix.rate;
      }
    });
  }

  /// Song position currently coming out of this computer's speakers (render
  /// position minus the output latency the browser reports).
  double? _audibleSoundPositionMs() {
    final ctx = _ctx;
    if (ctx == null) return null;
    double latency = 0;
    try {
      latency = ctx.outputLatency + ctx.baseLatency;
    } catch (_) {
      // Not reported by this browser.
    }
    final t = ctx.currentTime - latency;
    if (t < _anchorCtxTime) return null; // not started yet
    return _anchorOffsetMs + (t - _anchorCtxTime) * 1000;
  }

  void _stopVideo() {
    _videoStartTimer?.cancel();
    _videoStartTimer = null;
    _videoSyncTimer?.cancel();
    _videoSyncTimer = null;
    final video = _video;
    if (video != null && !video.paused) video.pause();
  }

  /// Where the shared timeline (what listeners should be playing) is at host
  /// wall time [wallMs], derived from this browser's audio clock.
  int _timelinePositionAt(int wallMs) {
    final live = _livePlayer;
    if (live != null && live.isPlaying) return live.positionAt(wallMs);
    final ctx = _ctx;
    if (ctx == null || _source == null) return position.inMilliseconds;
    final ctxAt = ctx.currentTime + (wallMs - _nowMs()) / 1000.0;
    final rendered = _anchorOffsetMs + (ctxAt - _anchorCtxTime) * 1000;
    final timeline = rendered + _anchorSpeakerOffsetMs;
    return timeline < 0 ? 0 : timeline.round();
  }

  /// Stops the current source node (if any) without firing its end handler.
  void _stopSource() {
    _stopVideo();
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
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_source == null) return;
      final next = Duration(milliseconds: _timelinePositionAt(_nowMs()));
      final changed = next.inSeconds != position.inSeconds;
      position = next;
      if (changed) _notify();
    });
  }

  /// Every second, sends listeners where the timeline is right now; each one
  /// re-anchors if it has drifted (see ListenerSessionController).
  void _startReferenceTimer() {
    _referenceTimer?.cancel();
    _referenceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final track = currentTrack;
      if (track == null || !_audible) return;
      final now = _nowMs();
      _broadcast(
        ControlMessage.positionSync(
          senderId: _hostId,
          trackId: track.trackId,
          positionMs: _timelinePositionAt(now),
          hostTimeMs: now,
        ),
      );
    });
  }

  void _stopReferenceTimer() {
    _referenceTimer?.cancel();
    _referenceTimer = null;
  }

  // ---- Control protocol (per listener, over the control data channel) ----

  void _handleControlFrame(String id, String frame) {
    final ControlMessage message;
    try {
      message = ControlMessage.decode(frame);
    } catch (_) {
      return;
    }
    final peer = _peers[id];
    final listener = _listeners[id];
    if (peer == null || listener == null) return;
    if (!peer.spokeProtocol) {
      peer.spokeProtocol = true;
      peer.protocolTimer?.cancel();
      if (listener.phase == ListenerPhase.needsUpdate) {
        listener.phase = ListenerPhase.connecting;
        _notify();
      }
    }
    switch (message.type) {
      case ControlMessageType.clockSyncRequest:
        _send(
          id,
          ControlMessage.clockSyncResponse(
            senderId: _hostId,
            clientSendTimeMs: message.payload['clientSendTimeMs'] as int,
            hostTimeMs: _nowMs(),
          ),
        );
      case ControlMessageType.ready:
        if (_awaitingReadyAcks) _readyAcks.add(id);
      case ControlMessageType.listenerStatusUpdate:
        _handleStatus(listener, message.payload);
      case ControlMessageType.calibrate:
        _playCalibrationChirp(id);
      default:
        break;
    }
  }

  /// A listener is calibrating with its mic: play the host chirp through
  /// this browser's speakers 1.5 s from now (the same output path as the
  /// music) and tell the listener exactly when.
  void _playCalibrationChirp(String id) {
    final ctx = _ctx ??= web.AudioContext();
    if (ctx.state != 'running') unawaited(ctx.resume().toDart);
    final atMs = _nowMs() + 1500;
    final rate = ctx.sampleRate;
    final pcm = AcousticCalibration.chirp(rate.round(), up: true);
    final buffer = ctx.createBuffer(1, pcm.length, rate)..copyToChannel(pcm.toJS, 0);
    final gain = ctx.createGain()..gain.value = 0.8;
    final source = ctx.createBufferSource()..buffer = buffer;
    source.connect(gain);
    gain.connect(ctx.destination);
    source.start(ctx.currentTime + (atMs - _nowMs()) / 1000);
    _send(id, ControlMessage.calibrate(senderId: _hostId, chirpAtHostTimeMs: atMs));
  }

  void _handleStatus(WebListener listener, Map<String, dynamic> payload) {
    final rtt = payload['roundTripMs'] as int?;
    if (rtt != null && rtt > 0) listener.roundTripMs = rtt;
    final listenerPlaying = payload['playbackState'] == 'playing';
    final positionMs = payload['positionMs'] as int?;
    if (playbackState != PlaybackState.playing ||
        !_audible ||
        !listenerPlaying ||
        positionMs == null) {
      if (listener.driftMs != null) {
        listener.driftMs = null;
        _notify();
      }
      return;
    }
    final drift = listenerDriftMs(
      listenerPositionMs: positionMs,
      roundTripMs: listener.roundTripMs ?? 0,
      receivedAtMs: _nowMs(),
      hostPositionAt: _timelinePositionAt,
    );
    final previous = listener.driftMs;
    // Light smoothing: the reported position is interpolated and jittery.
    listener.driftMs = previous == null || (drift - previous).abs() > 250
        ? drift
        : (previous * 0.5 + drift * 0.5).round();
    _notify();
  }

  void _handleControlOpen(String id) {
    final peer = _peers[id];
    if (peer == null) return;
    final track = currentTrack;
    final now = _nowMs();
    final playing = playbackState == PlaybackState.playing && _audible;
    _send(
      id,
      ControlMessage.welcome(
        senderId: _hostId,
        sessionId: sessionCode,
        sessionName: sessionName,
        hostDeviceId: _hostId,
        currentTrack: track,
        playbackState: playing ? 'playing' : playbackState.toJsonValue(),
        positionMs: playing ? _timelinePositionAt(now) : position.inMilliseconds,
        hostTimeMs: now,
      ),
    );
    peer.protocolTimer = Timer(_protocolTimeout, () {
      final listener = _listeners[id];
      if (peer.spokeProtocol || listener == null) return;
      listener.phase = ListenerPhase.needsUpdate;
      _notify();
    });
  }

  /// Copies the current song to listener [id] over its file channel, keeping
  /// only a small amount queued at a time.
  Future<void> _sendFile(String id) async {
    final peer = _peers[id];
    final channel = peer?.file;
    final track = currentTrack;
    final bytes = _fileBytes;
    if (peer == null || channel == null || track == null || bytes == null) return;
    if (!_isOpen(channel)) return; // sent once the channel opens
    if (peer.sentTrackId == track.trackId || peer.sendingTrackId == track.trackId) {
      return;
    }
    peer.sendingTrackId = track.trackId;
    final listener = _listeners[id];
    listener
      ?..phase = ListenerPhase.receivingSong
      ..fileProgress = 0;
    _notify();
    try {
      channel.send(
        FileTransferFrames.start(
          trackId: track.trackId,
          size: bytes.length,
          mime: _fileMime,
          name: _fileSendName ?? track.fileName,
        )
            .toJS,
      );
      var sent = 0;
      var lastNotified = 0.0;
      for (final chunk in FileTransferFrames.chunks(bytes)) {
        while (channel.bufferedAmount > _maxBufferedFileBytes) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (!_stillSending(peer, track, channel)) return;
        }
        if (!_stillSending(peer, track, channel)) return;
        channel.send(chunk.toJS);
        sent += chunk.length;
        final progress = sent / bytes.length;
        if (listener != null && progress - lastNotified >= 0.02) {
          listener.fileProgress = progress;
          lastNotified = progress;
          _notify();
        }
      }
      channel.send(FileTransferFrames.end(track.trackId).toJS);
      peer
        ..sentTrackId = track.trackId
        ..sendingTrackId = null;
      listener
        ?..phase = ListenerPhase.ready
        ..fileProgress = 1;
      _notify();
    } catch (e, st) {
      peer.sendingTrackId = null;
      reportError(e, st, context: 'webHost.sendFile');
    }
  }

  bool _stillSending(_Peer peer, TrackInfo track, web.RTCDataChannel channel) =>
      _peers.containsValue(peer) &&
      currentTrack == track &&
      peer.sendingTrackId == track.trackId &&
      _isOpen(channel);

  static bool _isOpen(web.RTCDataChannel? channel) =>
      channel != null && channel.readyState == 'open';

  void _send(String id, ControlMessage message) {
    final channel = _peers[id]?.control;
    if (!_isOpen(channel)) return;
    try {
      channel!.send(message.encode().toJS);
    } catch (_) {
      // Closing; the connection-state handler cleans up.
    }
  }

  void _broadcast(ControlMessage message) {
    for (final id in _peers.keys.toList()) {
      _send(id, message);
    }
  }

  // ---- Signaling / WebRTC setup ----

  void _handleSignal(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'listener-joined':
        final id = message['id'] as String?;
        if (id == null) return;
        _listeners[id] = WebListener(id, message['deviceName'] as String? ?? 'Unknown device');
        _notify();
        // A re-join (same id) replaces the old connection.
        _closePeer(id);
        unawaited(_connectPeer(id));
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
    try {
      final config = <String, Object?>{'iceServers': iceServers()}.jsify()
          as web.RTCConfiguration;
      final pc = web.RTCPeerConnection(config);
      final peer = _Peer(pc);
      _peers[id] = peer;
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
        if (_peers[id] != peer) return; // superseded by a newer connection
        switch (pc.connectionState) {
          case 'connected':
            peer.disconnectTimer?.cancel();
            peer.disconnectTimer = null;
          case 'disconnected':
            // Usually transient; give ICE a chance to recover.
            peer.disconnectTimer ??= Timer(_disconnectGrace, () => _dropListener(id));
          case 'failed':
          case 'closed':
            _dropListener(id);
        }
      }).toJS;

      final control = pc.createDataChannel(
        controlChannelLabel,
        web.RTCDataChannelInit(ordered: true),
      );
      peer.control = control;
      control.onopen = ((web.Event _) => _handleControlOpen(id)).toJS;
      control.onmessage = ((web.MessageEvent event) {
        final data = event.data;
        if (data.isA<JSString>()) {
          _handleControlFrame(id, (data as JSString).toDart);
        }
      }).toJS;

      final file = pc.createDataChannel(
        fileChannelLabel,
        web.RTCDataChannelInit(ordered: true),
      );
      file.binaryType = 'arraybuffer';
      peer.file = file;
      file.onopen = ((web.Event _) => unawaited(_sendFile(id))).toJS;

      final live = pc.createDataChannel(
        liveChannelLabel,
        web.RTCDataChannelInit(ordered: true),
      );
      live.binaryType = 'arraybuffer';
      peer.live = live;
      live.onopen = ((web.Event _) => _sendLiveHistory(id)).toJS;

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
    final peer = _peers[from];
    if (peer == null) return;
    try {
      await peer.pc
          .setRemoteDescription(
            web.RTCSessionDescriptionInit(type: 'answer', sdp: sdp),
          )
          .toDart;
      peer.remoteSet = true;
      // Flush candidates that raced ahead of the answer.
      final pending = List.of(peer.pendingIce);
      peer.pendingIce.clear();
      for (final message in pending) {
        await _applyIceCandidate(from, message);
      }
    } catch (e, st) {
      reportError(e, st, context: 'webHost.applyAnswer');
    }
  }

  Future<void> _applyIceCandidate(
    String from,
    Map<String, dynamic> message,
  ) async {
    final peer = _peers[from];
    if (peer == null) return;
    if (!peer.remoteSet) {
      // Remote description not applied yet — hold the candidate.
      peer.pendingIce.add(message);
      return;
    }
    try {
      await peer.pc
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
    _closePeer(id);
    if (removed) _notify();
  }

  void _closePeer(String id) {
    final peer = _peers.remove(id);
    if (peer == null) return;
    peer.disconnectTimer?.cancel();
    peer.protocolTimer?.cancel();
    try {
      peer.pc.close();
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
      _broadcast(ControlMessage.sessionEnded(senderId: _hostId));
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
    _broadcast(ControlMessage.sessionEnded(senderId: _hostId));
    _signaling?.send({'type': 'end'});
    _removePageHideHook();
    if (isSharingTab) stopTabShare(announce: false);
    _stopSource();
    _stopReferenceTimer();
    for (final id in _peers.keys.toList()) {
      _closePeer(id);
    }
    _listeners.clear();

    sessionCode = '';
    joinCode = null;
    joinLink = null;
    signalingLost = false;
    currentTrack = null;
    _buffer = null;
    _setVideo(null);
    _fileBytes = null;
    _fileMime = null;
    _fileSendName = null;
    preparingSoundProgress = null;
    position = Duration.zero;
    playbackState = PlaybackState.stopped;

    final ctx = _ctx;
    _ctx = null;
    _gain = null;
    _analyser = null;
    _bins = null;
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
