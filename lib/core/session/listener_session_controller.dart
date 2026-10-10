import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_engine.dart';
import '../audio/just_audio_engine.dart';
import '../observability/reporting.dart';
import '../network/control_client.dart';
import '../network/control_link.dart';
import 'active_session.dart';
import 'sync_nudge_store.dart';
import '../sync/acoustic_calibration.dart';
import '../sync/calibration_mic.dart';
import '../sync/chirp_player.dart';
import '../network/models/control_message.dart';
import '../network/models/device_info.dart';
import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';
import '../network/network_utils.dart';

const Duration _statusReportInterval = Duration(seconds: 2);

/// How far into the future a scheduled start is set, matching the host's lead
/// time. Leaves room for a fresh clock-sync burst + readiness before the
/// audible instant.
const Duration _scheduleLeadTime = Duration(milliseconds: 800);

/// How long to wait for the clock-sync burst to produce fresh samples after
/// [ControlClient.syncNow] before converting host times (fits inside
/// [_scheduleLeadTime]).
const Duration _freshSyncWait = Duration(milliseconds: 350);

/// Turns a track the host announced into a URI the audio engine can play.
/// Returns null when the track can't be played (the load is skipped).
typedef TrackResolver = Future<Uri?> Function(TrackInfo track);

/// Orchestrates a joined session: owns the audio engine (playing the
/// host's stream URL), the control client (clock sync + incoming
/// play/pause/seek/track commands), and periodic status reporting back to
/// the host. `ChangeNotifier` so a `JoinViewModel` can listen directly
/// with `provider`.
class ListenerSessionController extends ChangeNotifier
    implements ActiveSession {
  ListenerSessionController({
    required this.selfDevice,
    AudioEngine? audioEngine,
    this.trackResolver,
    CalibrationMic Function()? micFactory,
  })  : audioEngine = audioEngine ?? JustAudioEngine(),
        _micFactory = micFactory ?? RecordCalibrationMic.new;

  final CalibrationMic Function() _micFactory;
  Completer<int?>? _calibrationReply;

  /// The host's latest timeline reference (position at host time), so
  /// playback can resume in sync after a calibration borrowed the player.
  ({int positionMs, int hostTimeMs})? _lastHostReference;

  final DeviceInfo selfDevice;
  final AudioEngine audioEngine;

  /// How announced tracks become playable URIs. Null (phone-hosted sessions)
  /// streams `track.streamUrl` from the host's LAN HTTP server; browser-hosted
  /// sessions resolve to the song bytes received over WebRTC.
  final TrackResolver? trackResolver;

  ControlLink? _client;

  /// How far ahead of the target a drift-correction seek aims, learned from
  /// the error left after the previous correction: a seek in a compressed
  /// file (decoder restart from a keyframe) or on a slow device takes a
  /// while, and without this every correction lands late by that much.
  int seekLeadMs = 0;

  /// This device's speaker delay compensation (see [ActiveSession.syncNudgeMs]):
  /// every target position is shifted this far ahead.
  @override
  int syncNudgeMs = 0;

  @override
  void setSyncNudge(int ms) {
    syncNudgeMs = ms.clamp(minSyncNudgeMs, maxSyncNudgeMs);
    notifyListeners();
  }
  DateTime? _lastCorrectionAt;
  static const Duration _correctionSettleTime = Duration(milliseconds: 2000);

  /// Test hook: pretends the last drift correction happened [age] ago.
  @visibleForTesting
  void debugAgeLastCorrection(Duration age) {
    final last = _lastCorrectionAt;
    if (last != null) _lastCorrectionAt = last.subtract(age);
  }

  /// Whether the host's latest command was play/seek (vs pause): lets a
  /// browser listener that was blocked from autoplaying start on a tap.
  bool hostIsPlaying = false;
  StreamSubscription? _messagesSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _disconnectedSub;
  StreamSubscription<ReconnectionStatus>? _reconnectionSub;
  Timer? _statusTimer;

  /// The in-flight track load (set on welcome/trackChanged/reconnect). A play
  /// or seek that arrives for the same track awaits this instead of racing
  /// the engine — [AudioEngine.loadUrl] replaces the player's source, so a
  /// seek issued against the old source would be silently lost.
  Future<void>? _pendingLoad;

  /// The in-flight welcome handler. A play that arrives right after the
  /// welcome (host already mid-song) awaits this so it can never schedule
  /// against a track that hasn't started loading yet.
  Future<void>? _pendingWelcome;

  /// True while the client is retrying a transient connection drop (WiFi
  /// blip, host briefly backgrounded); the UI shows a "reconnecting" banner.
  @override
  bool isReconnecting = false;

  /// A native-hosted session is a stream with a position unless it's a live
  /// mic broadcast.
  @override
  bool get isLiveSession => currentTrack?.isLive ?? false;

  /// Snapshot of whether we were playing when the drop happened, so playback
  /// can resume (in sync) once the connection is back.
  bool _wasPlayingBeforeDrop = false;

  @override
  String? sessionName;
  String? hostDeviceId;
  @override
  TrackInfo? currentTrack;
  @override
  PlaybackState playbackState = PlaybackState.stopped;
  @override
  Duration position = Duration.zero;
  @override
  int? clockOffsetMs;
  @override
  int? roundTripMs;

  /// This device's own playback volume (0..1). Each listener controls its own
  /// output, so the host's playback isn't a single master volume.
  @override
  double volume = 1.0;

  /// Set once the host ends the session or the connection drops; the UI uses
  /// this to show "host left" and return to discovery.
  @override
  bool hostLeft = false;

  /// Native-hosted streams play through just_audio, which is started from
  /// the scheduled-start timer; there's no separate unlock step.
  @override
  bool get needsAudioUnlock => false;

  @override
  Future<void> unlockAudio() async {}

  /// Songs stream from the host on demand; nothing is copied up front.
  @override
  double? get trackDownloadProgress => null;

  /// Sets this device's local playback volume without affecting other devices.
  @override
  Future<void> setLocalVolume(double value) async {
    volume = value;
    await audioEngine.setVolume(value);
    notifyListeners();
  }

  Future<void> connect({required String hostIp, required int controlPort}) async {
    final client = ControlClient(deviceId: selfDevice.deviceId);
    _client = client;
    await client.connect(hostIp: hostIp, controlPort: controlPort);
    attach(client);
  }

  /// Runs the session over an already-open [link] (used directly for
  /// browser-hosted sessions, whose link is a WebRTC data channel).
  void attach(ControlLink link) {
    final previous = _client;
    if (previous != null && !identical(previous, link)) {
      // A replacement link (the host re-connected us): drop the old one's
      // subscriptions; playback and the loaded track carry over.
      unawaited(_messagesSub?.cancel());
      unawaited(_positionSub?.cancel());
      unawaited(_stateSub?.cancel());
      unawaited(_disconnectedSub?.cancel());
      unawaited(_reconnectionSub?.cancel());
      _statusTimer?.cancel();
      unawaited(previous.dispose());
    }
    final client = link;
    _client = client;
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
    _reconnectionSub = client.reconnectionStatus.listen(_handleReconnectionStatus);
    _statusTimer = Timer.periodic(_statusReportInterval, (_) => _sendStatus());
  }

  void _handleReconnectionStatus(ReconnectionStatus status) {
    switch (status) {
      case ReconnectionStatus.attempting:
        // Remember whether we were mid-playback so we can resume on success
        // (by then the player may already have errored out on the dead stream).
        _wasPlayingBeforeDrop = playbackState == PlaybackState.playing;
        isReconnecting = true;
        notifyListeners();
      case ReconnectionStatus.succeeded:
        isReconnecting = false;
        notifyListeners();
        unawaited(_resyncAfterReconnect());
      case ReconnectionStatus.failed:
        isReconnecting = false;
        notifyListeners();
        // The client emits `disconnected` right after, which surfaces hostLeft.
    }
  }

  /// After a successful reconnect the host won't re-send a welcome for a
  /// deviceId it already knows, so restore playback state locally: reload the
  /// current track (the audio stream dropped with the WiFi), re-arm playback
  /// if it was playing, and resume status reporting.
  Future<void> _resyncAfterReconnect() async {
    // The estimator was reset on disconnect, so re-establish a fresh offset
    // before converting any times — a zero offset here is seconds of lag.
    _client?.syncNow();
    await _waitForFreshSyncSamples();
    await _loadCurrentTrack(preBufferAt: position);
    final track = currentTrack;
    final wasPlaying = _wasPlayingBeforeDrop;
    _wasPlayingBeforeDrop = false;
    if (track != null && wasPlaying && !track.isLive) {
      final startAt = DateTime.now().add(_scheduleLeadTime);
      await audioEngine.scheduleStart(at: startAt, position: position);
    }
    _sendStatus();
  }

  void _handleHostGone() {
    if (hostLeft) return;
    hostLeft = true;
    unawaited(
      audioEngine.pause().catchError((Object e, StackTrace st) {
        reportError(e, st, context: 'pause after host left');
      }),
    );
    notifyListeners();
  }

  void _handleMessage(ControlMessage message) {
    switch (message.type) {
      case ControlMessageType.welcome:
        hostIsPlaying = message.payload['playbackState'] == 'playing';
        _pendingWelcome = _handleWelcome(message);
        unawaited(_pendingWelcome!);
      case ControlMessageType.trackChanged:
        hostIsPlaying = false;
        seekLeadMs = 0; // a different file seeks differently
        _lastCorrectionAt = null;
        currentTrack = TrackInfo.fromJson(message.payload);
        // Pre-buffer the new track from its start (the host loads tracks
        // paused at position 0) so a follow-up play command starts instantly.
        unawaited(_loadCurrentTrack(preBufferAt: Duration.zero));
        notifyListeners();
      case ControlMessageType.prepare:
        unawaited(_handlePrepare(message));
      case ControlMessageType.play:
      case ControlMessageType.seek:
        hostIsPlaying = true;
        unawaited(_handleScheduledStart(message));
      case ControlMessageType.pause:
        hostIsPlaying = false;
        audioEngine.pause();
      case ControlMessageType.positionSync:
        _handlePositionSync(message);
      case ControlMessageType.volume:
        // Volume is per-device: each listener controls its own output via
        // setLocalVolume, so the host's volume changes don't override it here.
        break;
      case ControlMessageType.sessionEnded:
        _handleHostGone();
      case ControlMessageType.calibrate:
        // A time, or no time: a host that can't play the chirp (phone hosts).
        final reply = _calibrationReply;
        if (reply != null && !reply.isCompleted) {
          reply.complete(message.payload['chirpAtHostTimeMs'] as int?);
        }
      case ControlMessageType.ready:
      case ControlMessageType.clockSyncRequest:
      case ControlMessageType.clockSyncResponse:
      case ControlMessageType.listenerStatusUpdate:
        break; // not expected in the listener->UI direction
    }
  }

  /// Part of the host's ready-ack start handshake: pre-buffers at the
  /// position the upcoming play/seek will start from, then tells the host
  /// this device is ready. The host picks its target instant only after
  /// (nearly) every listener has acknowledged, so buffering happens *before*
  /// the audible instant instead of bleeding into it — which is what makes a
  /// slow-buffering device start a second late.
  Future<void> _handlePrepare(ControlMessage message) async {
    try {
      final track = currentTrack;
      if (track == null || track.isLive) return;
      final messageTrackId = message.payload['trackId'] as String?;
      if (messageTrackId == null || messageTrackId != track.trackId) return;
      final positionMs = message.payload['positionMs'] as int? ?? 0;

      // Refresh the clock estimate while buffering (a fresh offset makes the
      // follow-up play's host->local conversion exact), then make sure any
      // in-flight welcome/load has finished so we prepare against the loaded
      // source rather than racing it.
      _client?.syncNow();
      await _waitForFreshSyncSamples();
      final pendingWelcome = _pendingWelcome;
      if (pendingWelcome != null) await pendingWelcome;
      final pending = _pendingLoad;
      if (pending != null) await pending;

      // The track may have changed while awaiting; re-check before preparing.
      final current = currentTrack;
      if (current == null || current.isLive || current.trackId != messageTrackId) {
        return;
      }
      await audioEngine.prepareForStart(Duration(milliseconds: positionMs));
      _client?.send(
        ControlMessage.ready(
          senderId: selfDevice.deviceId,
          trackId: messageTrackId,
          positionMs: positionMs,
        ),
      );
    } catch (e, st) {
      reportError(e, st, context: 'prepareForStart');
    }
  }

  /// Handles the host's welcome message, which may arrive mid-song. Loads the
  /// current track, pre-buffers it at where the host is right now, and — if
  /// the host is already playing — re-arms a scheduled start so this device
  /// joins aligned with the host's playhead instead of sitting silent or
  /// starting late.
  Future<void> _handleWelcome(ControlMessage message) async {
    sessionName = message.payload['sessionName'] as String;
    hostDeviceId = message.payload['hostDeviceId'] as String;
    final trackJson = message.payload['currentTrack'];
    currentTrack = trackJson != null
        ? TrackInfo.fromJson(Map<String, dynamic>.from(trackJson as Map))
        : null;
    final playbackStateJson = message.payload['playbackState'] as String? ?? 'stopped';
    final hostPositionMs = message.payload['positionMs'] as int? ?? 0;
    final hostTimeMs = message.payload['hostTimeMs'] as int? ?? 0;

    final track = currentTrack;
    if (track != null) {
      // Kick a sync burst and wait for fresh samples before converting host
      // time: phone clocks can be seconds apart, and using a zero/stale
      // offset is exactly how a late joiner lands a second off.
      _client?.syncNow();
      await _waitForFreshSyncSamples();
      final joinPosition =
          _estimateHostPositionNow(hostPositionMs, hostTimeMs) +
              Duration(milliseconds: syncNudgeMs);
      await _loadCurrentTrack(preBufferAt: joinPosition);
      if (playbackStateJson == 'playing' && !track.isLive) {
        final startAt = DateTime.now().add(_scheduleLeadTime);
        await audioEngine.scheduleStart(at: startAt, position: joinPosition);
      }
    }
    notifyListeners();
  }

  /// Converts a host-reported (position, hostTimeMs) pair into this device's
  /// playhead position "right now", using the current clock offset estimate
  /// (offset == hostClock - clientClock).
  Duration _estimateHostPositionNow(int hostPositionMs, int hostTimeMs) {
    final offsetMs = _client?.clockEstimate?.offsetMs ?? 0;
    // The same wall instant as [hostTimeMs], expressed on our clock.
    final hostNowOnClientClock = hostTimeMs - offsetMs;
    final elapsed = DateTime.now().millisecondsSinceEpoch - hostNowOnClientClock;
    return Duration(milliseconds: hostPositionMs + (elapsed > 0 ? elapsed : 0));
  }

  /// Waits (bounded by [_freshSyncWait]) until the clock-sync burst has
  /// produced a couple of fresh samples, so host->local time conversions use
  /// a real offset instead of a stale or zero one.
  ///
  /// Short-circuits when the estimator already holds a current sample (the
  /// steady-state sync runs every 2s): a <1s-old offset is accurate to well
  /// under a millisecond on a LAN, and burning the wait anyway would eat the
  /// scheduling lead and turn into audible late starts.
  Future<void> _waitForFreshSyncSamples() async {
    final client = _client;
    if (client == null) return;
    if (client.isSyncFresh()) return;
    final before = client.syncSampleCount;
    final deadline = DateTime.now().add(_freshSyncWait);
    while (DateTime.now().isBefore(deadline)) {
      if (client.syncSampleCount >= before + 2) return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<void> _loadCurrentTrack({Duration preBufferAt = Duration.zero}) {
    final track = currentTrack;
    if (track == null) return Future<void>.value();
    // Track the in-flight load so a play/seek arriving for this track can
    // await it instead of racing the engine.
    final load = _performLoad(track, preBufferAt: preBufferAt);
    _pendingLoad = load;
    return load;
  }

  Future<void> _performLoad(TrackInfo track, {required Duration preBufferAt}) async {
    final resolver = trackResolver;
    if (resolver != null) {
      final Uri? uri;
      try {
        uri = await resolver(track);
      } catch (e, st) {
        reportError(e, st, context: 'resolveTrack');
        return;
      }
      // A newer track may have been announced while this one was arriving.
      if (uri == null || currentTrack?.trackId != track.trackId) return;
      await _loadUri(uri, track, preBufferAt: preBufferAt);
      return;
    }
    final streamUri = Uri.parse(track.streamUrl);
    // LAN-only: refuse to load an audio stream from a non-private host, even
    // if a malicious/buggy host broadcasts a track pointing elsewhere.
    if (!isPrivateNetworkHost(streamUri.host)) {
      reportError(
        StateError('Refusing stream from non-private host ${streamUri.host}'),
        null,
        context: 'loadCurrentTrack',
      );
      return;
    }
    await _loadUri(streamUri, track, preBufferAt: preBufferAt);
  }

  Future<void> _loadUri(Uri streamUri, TrackInfo track, {required Duration preBufferAt}) async {
    try {
      await audioEngine.loadUrl(streamUri, title: track.fileName);
      if (track.isLive) {
        // A live broadcast has no scheduled start instant — it's always "now",
        // so begin playing as soon as it's loaded.
        playbackState = PlaybackState.playing;
        await audioEngine.play();
        notifyListeners();
      } else {
        // Pre-buffer at the position playback will start from so a follow-up
        // play/seek starts producing audio the instant it's told to — the
        // host never waits on listener buffering, so this is what keeps the
        // first audible samples aligned.
        await audioEngine.prepareForStart(preBufferAt);
      }
    } catch (e, st) {
      // A failed load (host HTTP hiccup, engine teardown, ...) must never take
      // the listener down with an unhandled async error.
      reportError(e, st, context: 'loadCurrentTrack');
    }
  }

  Future<void> _handleScheduledStart(ControlMessage message) async {
    try {
      // Fresh clock sync before converting the host's target instant: a stale
      // or zero offset (phone clocks differ by seconds) is exactly the
      // "joined device starts late" failure. The burst completes inside the
      // scheduling lead time.
      _client?.syncNow();
      await _waitForFreshSyncSamples();

      final estimate = _client?.clockEstimate;
      final offsetMs = estimate?.offsetMs ?? 0;
      clockOffsetMs = offsetMs;
      roundTripMs = estimate?.roundTripMs;

      final positionMs = message.payload['positionMs'] as int;
      final startAtHostTimeMs = message.payload['startAtHostTimeMs'] as int;
      _lastHostReference = (positionMs: positionMs, hostTimeMs: startAtHostTimeMs);
      // offsetMs == hostTime - clientTime, so hostTime -> clientTime is
      // startAtHostTimeMs - offsetMs.
      final localTarget = DateTime.fromMillisecondsSinceEpoch(
        startAtHostTimeMs - offsetMs,
      );

      // Ensure any in-flight welcome/load for the current track has finished
      // before scheduling against it (a play right after welcome/trackChanged).
      final pendingWelcome = _pendingWelcome;
      if (pendingWelcome != null) await pendingWelcome;
      final pending = _pendingLoad;
      if (pending != null) await pending;

      await audioEngine.scheduleStart(
        at: localTarget,
        position: Duration(milliseconds: _nudged(positionMs)),
      );
    } catch (e, st) {
      reportError(e, st, context: 'schedulePlayback');
    }
  }

  /// Measures how late this device's speaker sounds compared with the
  /// host's, with this device's mic (see [AcousticCalibration]), and sets the
  /// sync nudge to cancel it. Three runs, median. Returns the new nudge.
  ///
  /// Throws [CalibrationException] with a user-facing reason on failure.
  @override
  Future<int> calibrateWithMic({void Function(int run)? onRun}) async {
    final client = _client;
    if (client == null) throw const CalibrationException('Not connected to the host.');
    final track = currentTrack;
    final wasPlaying = hostIsPlaying && track != null && !track.isLive;
    // The chirp goes through the music's own player (same output delay), so
    // the music on this device pauses for the few seconds this takes.
    await audioEngine.pause();
    try {
      final results = <int>[];
      for (var run = 0; run < 3; run++) {
        onRun?.call(run);
        results.add(await _calibrateOnce(client));
      }
      final nudge = AcousticCalibration.median(results);
      if (nudge.abs() > 600) {
        throw const CalibrationException(
          'The measurement didn’t make sense — try again somewhere quieter.',
        );
      }
      setSyncNudge(nudge);
      return syncNudgeMs;
    } finally {
      // With the new nudge (or the old one if this failed).
      await _resumeAfterCalibration(track, wasPlaying);
    }
  }

  /// Puts the song back in the player and rejoins the host's timeline.
  Future<void> _resumeAfterCalibration(TrackInfo? track, bool wasPlaying) async {
    if (track == null || currentTrack?.trackId != track.trackId) return;
    final ref = _lastHostReference;
    final offset = _client?.clockEstimate?.offsetMs ?? 0;
    int hostPositionNow() {
      if (ref == null) return position.inMilliseconds;
      final elapsed = DateTime.now().millisecondsSinceEpoch - (ref.hostTimeMs - offset);
      return ref.positionMs + (elapsed > 0 ? elapsed : 0);
    }

    await _loadCurrentTrack(
      preBufferAt: Duration(milliseconds: _nudged(hostPositionNow())),
    );
    if (!wasPlaying || !hostIsPlaying) return;
    final startAt = DateTime.now().add(_scheduleLeadTime);
    await audioEngine.scheduleStart(
      at: startAt,
      position: Duration(
        milliseconds: _nudged(hostPositionNow() + _scheduleLeadTime.inMilliseconds),
      ),
    );
  }

  Future<int> _calibrateOnce(ControlLink client) async {
    const rate = CalibrationMic.sampleRate;
    final mic = _micFactory();
    final chirp = ChirpPlayer(audioEngine);
    var recording = false;
    try {
      await mic.start();
      recording = true;
      final reply = _calibrationReply = Completer<int?>();
      client.send(ControlMessage.calibrate(senderId: selfDevice.deviceId));
      final atHost = await reply.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw const CalibrationException(
          'The host didn’t answer — it may need the latest Ampme version.',
        ),
      );
      if (atHost == null) {
        throw const CalibrationException(
          'Mic calibration needs the host to be the web app for now — use the '
          'slider to line this device up by ear.',
        );
      }
      final offset = client.clockEstimate?.offsetMs ?? 0;
      // The host's chirp (A) is due at [hostAt] on our clock; ours (B) 700 ms
      // later, through our own player.
      final hostAt = DateTime.fromMillisecondsSinceEpoch(atHost - offset);
      await chirp.playAt(hostAt.add(const Duration(milliseconds: 700)), host: false);
      await _until(hostAt.add(const Duration(milliseconds: 900)));
      final reportedB = chirp.reportedChirpTime(DateTime.now());
      await _until(hostAt.add(const Duration(milliseconds: 1400)));
      recording = false;
      final rec = await mic.stop();
      if (reportedB == null) {
        throw const CalibrationException('This device couldn’t play its test sound.');
      }
      final heardA = AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: true));
      if (heardA == null) {
        throw const CalibrationException(
          'Couldn’t hear the host’s test sound — turn the host up or move closer.',
        );
      }
      final heardB = AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: false));
      if (heardB == null) {
        throw const CalibrationException('Couldn’t hear this device’s own test sound — turn it up.');
      }
      return AcousticCalibration.nudgeMs(
        heardA: heardA,
        heardB: heardB,
        sampleRate: rate,
        expectedGapMs: reportedB.difference(hostAt).inMicroseconds / 1000,
      );
    } finally {
      _calibrationReply = null;
      if (recording) unawaited(mic.stop().catchError((Object _) => Float32List(0)));
    }
  }

  static Future<void> _until(DateTime t) async {
    final wait = t.difference(DateTime.now());
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// [timelineMs] shifted by this device's nudge (never before the start).
  int _nudged(int timelineMs) {
    final v = timelineMs + syncNudgeMs;
    return v < 0 ? 0 : v;
  }

  /// Re-anchors this device's playhead on a precise reference the host sent
  /// because this device's periodically-reported position had drifted out of
  /// sync.
  void _handlePositionSync(ControlMessage message) {
    final track = currentTrack;
    if (track == null || track.isLive) return;
    final messageTrackId = message.payload['trackId'] as String?;
    if (messageTrackId != track.trackId) return;
    final hostPositionMs = message.payload['positionMs'] as int;
    final hostTimeMs = message.payload['hostTimeMs'] as int;
    _lastHostReference = (positionMs: hostPositionMs, hostTimeMs: hostTimeMs);

    // Only meaningful mid-playback; while buffering or paused a seek is
    // wasted (or would fight an in-flight scheduled start).
    if (playbackState != PlaybackState.playing) return;
    final offsetMs = _client?.clockEstimate?.offsetMs ?? 0;
    // Where the host's playhead is *right now*, on this device's clock.
    final hostNowOnClientClock = hostTimeMs - offsetMs;
    final elapsed = DateTime.now().millisecondsSinceEpoch - hostNowOnClientClock;
    final target = _nudged(hostPositionMs + (elapsed > 0 ? elapsed : 0));

    // Measure against an interpolated position, not the raw getter — the
    // platform only refreshes positions on a coarse grid, and comparing two
    // stale values would make this loop chase up to ~250ms of fake drift.
    final drift = audioEngine.estimatePositionAt(DateTime.now()).inMilliseconds - target;
    // The host re-broadcasts a measured reference every second, so a small
    // correction here is cheap and frequent — chasing down to ~30ms keeps
    // devices audibly locked while staying above the residual clock-estimate
    // noise (a few ms on a LAN). The seek itself is tiny (≤1 frame at 30ms),
    // so it isn't audible.
    if (drift.abs() < 30) return;

    final now = DateTime.now();
    final last = _lastCorrectionAt;
    if (last != null) {
      final since = now.difference(last);
      // Let the previous seek settle (rebuffer, fresh position updates)
      // before judging it or seeking again: back-to-back seeks on a slow
      // device starve the audio output and make the drift worse.
      if (since < _correctionSettleTime) return;
      // Still off after a recent correction: it landed `drift` away from
      // where it aimed. Move the aim 70 % of that way (damped, so noisy
      // readings can't make it oscillate).
      if (since < const Duration(seconds: 8)) {
        seekLeadMs = (seekLeadMs - drift * 0.7).round().clamp(0, 400);
      }
    }
    _lastCorrectionAt = now;
    unawaited(audioEngine.seek(Duration(milliseconds: target + seekLeadMs)));
  }

  void _sendStatus() {
    // Report the current clock estimate, not the one captured at the last
    // start: the host times this report with roundTripMs, and a stale value
    // (e.g. measured while a song was still transferring) skews its drift.
    final estimate = _client?.clockEstimate;
    if (estimate != null) {
      clockOffsetMs = estimate.offsetMs;
      roundTripMs = estimate.roundTripMs;
    }
    _client?.send(
      ControlMessage.listenerStatusUpdate(
        senderId: selfDevice.deviceId,
        deviceName: selfDevice.deviceName,
        playbackState: playbackState.toJsonValue(),
        // Report an interpolated position: the host compares this against its
        // own playhead to detect drift, and a raw polled value would be up to
        // a poll interval old by the time it's compared.
        // Minus the nudge: the host compares against the shared timeline, and
        // a deliberate lead isn't drift.
        positionMs:
            audioEngine.estimatePositionAt(DateTime.now()).inMilliseconds -
                syncNudgeMs,
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
    await _reconnectionSub?.cancel();
    await _client?.dispose();
    _client = null;
    isReconnecting = false;
  }

  @override
  void dispose() {
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    // Release the audio engine promptly so hosting again or re-joining
    // doesn't run two players at once.
    _statusTimer?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await audioEngine.dispose();
    // disconnect() cancels the (now already cancelled) subs again — harmless.
    await disconnect();
  }
}
