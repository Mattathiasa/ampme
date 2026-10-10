import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../audio/audio_engine.dart';
import '../audio/audio_session_manager.dart';
import '../audio/just_audio_engine.dart';
import '../audio/live_mic_broadcaster.dart';
import '../audio/system_audio_capture.dart';
import '../observability/reporting.dart';
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
import '../sync/report_time.dart';
import '../../utils/id_generator.dart';

/// How far into the future a `play`/`seek` command's target start time is
/// set. Listeners have already confirmed they are buffered and armed (the
/// ready-ack handshake in [_scheduleSynchronizedStart]) before this instant
/// is picked, so the lead only needs to cover control-message delivery +
/// timer precision — not buffering.
const Duration _scheduleLeadTime = Duration(milliseconds: 500);

/// How long the host waits for every connected listener to acknowledge the
/// `prepare` ("I'm buffered at this position") before scheduling the audible
/// start anyway. Bounded so one dead/slow device can never stall the whole
/// room; typical LAN acks arrive in tens of ms.
const Duration _readyAckTimeout = Duration(milliseconds: 1500);  /// Deviation (ms) between a listener's reported playhead and the host's own
  /// beyond which the listener is considered out of sync and is sent a precise
  /// host position reference to re-anchor on. Smaller than this would chase
  /// clock-estimate noise (a correction seek is itself audible). Kept tight
  /// because the host now also broadcasts measured references every second, so
  /// any real drift is caught on the next tick anyway.
  const int _maxDriftMs = 60;

  /// Listeners that acknowledged the in-flight `prepare` (deviceId set).
  /// Only counted while [_awaitingReadyAcks] is true, so a stale ack from a
  /// previous command can never satisfy the current one.
  final Set<String> _readyAcks = {};
  bool _awaitingReadyAcks = false;

/// Orchestrates a hosted session: owns the audio engine (what the host
/// itself hears), the local HTTP server (audio streaming + control
/// WebSocket upgrade), the control server (listener messaging), and the
/// UDP beacon broadcaster (discoverability). `ChangeNotifier` so a
/// `HostViewModel` can listen directly with `provider`.
class HostSessionController extends ChangeNotifier {
  HostSessionController({required this.hostDevice, AudioEngine? audioEngine})
    : audioEngine = audioEngine ?? JustAudioEngine() {
    // Capture can also end outside Dart's control (user stops the system
    // notification / consent is revoked): reset the broadcast state then.
    _systemAudioCapture.onStopped = _handleSystemAudioStopped;
  }

  final DeviceInfo hostDevice;
  final AudioEngine audioEngine;

  final _httpServer = AudioHttpServer();
  final _controlServer = ControlServer();
  final _broadcaster = SessionBroadcaster();
  final _micBroadcaster = LiveMicBroadcaster();
  final _systemAudioCapture = SystemAudioCapture();
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
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

  /// While a file track is playing, ticks once per second and broadcasts the
  /// host's *measured* playhead to every listener — the authoritative
  /// reference listeners re-anchor on. See [AudioEngine.currentPosition].
  Timer? _positionSyncTimer;

  /// Whether the host paused because of an audio interruption (phone call,
  /// navigation, another media app) so it can resume when the interruption ends.
  bool _pausedForInterruption = false;

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
      // Feed the drift-correction loop: while we're audibly playing a file,
      // every listener gets a fresh measured reference once a second.
      if (state == PlaybackState.playing) {
        _startPositionSyncTimer();
      } else {
        _stopPositionSyncTimer();
      }
      notifyListeners();
    });
    _interruptionSub = AudioSessionManager.instance.interruptionEvents.listen(
      _handleInterruption,
    );

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

  /// Whether the host is currently broadcasting the device's system audio
  /// (audio other apps are playing).
  bool get isSystemAudioBroadcasting => _systemAudioCapture.isCapturing;

  /// Whether the current platform can capture other apps' audio (Android
  /// 10+); the host UI hides the "Broadcast device audio" control otherwise.
  Future<bool> isSystemAudioSupported() => _systemAudioCapture.isSupported();

  /// The picked video's path when the current track is a video: the host
  /// shows it, while [loadTrack]'s file (its sound) is what every device
  /// plays.
  String? videoPath;

  /// Loads [file] as the session's track. For a video, [file] is its sound
  /// (or the video itself if the sound couldn't be extracted) and
  /// [videoPath] the original video, shown on the host.
  Future<void> loadTrack(File file, {required String fileName, String? videoPath}) async {
    // A file and a live broadcast are mutually exclusive sources.
    if (_micBroadcaster.isBroadcasting) await stopLiveBroadcast();
    if (_systemAudioCapture.isCapturing) await stopSystemAudioBroadcast();

    final trackId = generateId();
    _httpServer.setCurrentTrack(trackId: trackId, file: file);
    final duration = await audioEngine.loadLocalFile(file.path, title: fileName);
    position = Duration.zero;

    final ip = localIp ?? await getLocalWifiIp();
    final streamUrl = 'http://$ip:${_httpServer.port}/stream/$trackId';
    this.videoPath = videoPath;
    currentTrack = TrackInfo(
      trackId: trackId,
      fileName: fileName,
      streamUrl: streamUrl,
      durationMs: duration?.inMilliseconds ?? 0,
      hasVideo: videoPath != null,
    );

    _controlServer.broadcast(
      ControlMessage.trackChanged(senderId: hostDevice.deviceId, track: currentTrack!),
    );
    notifyListeners();
  }

  Future<void> play() async {
    final track = currentTrack;
    if (track == null) return;
    // During the scheduling lead the engine is paused, so the state listener
    // already stopped the reference timer — cancel again to be certain a
    // stale reference never fires mid-transition.
    _stopPositionSyncTimer();
    await _scheduleSynchronizedStart(track: track, position: position);
  }

  Future<void> pause() async {
    _stopPositionSyncTimer();
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
    _stopPositionSyncTimer();
    await _scheduleSynchronizedStart(track: track, position: target, asSeek: true);
  }

/// The in-flight synchronized start, used to serialize rapid play/seek
  /// commands: a second command awaits the first handshake instead of
  /// overlapping it (which would interleave `prepare` broadcasts and ack
  /// windows).
  Future<void>? _inFlightStart;

  /// The heart of synchronized starting: asks every connected listener to
  /// pre-buffer at [position] (`prepare`), waits (bounded) until they all
  /// acknowledge (`ready`), and only then picks the target wall-clock
  /// instant and broadcasts the actual play/seek. Because listeners were
  /// already buffered and armed before [startAtHostTimeMs] was chosen, no
  /// device has to buffer *after* the scheduled instant — the dominant cause
  /// of the "one device starts a second late" failure. Falls back to a plain
  /// schedule (plus the catch-up logic in the engine) when a listener never
  /// acks, so one slow device can't stall the room.
  Future<void> _scheduleSynchronizedStart({
    required TrackInfo track,
    required Duration position,
    bool asSeek = false,
  }) async {
    // Serialize: if a previous play/seek handshake is still in flight, wait
    // for it to finish before starting this one so prepare broadcasts, ack
    // windows and scheduled timers can never interleave.
    while (_inFlightStart != null) {
      await _inFlightStart;
    }
    final run = _doScheduledStart(
      track: track,
      position: position,
      asSeek: asSeek,
    );
    _inFlightStart = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightStart, run)) _inFlightStart = null;
    }
  }

  Future<void> _doScheduledStart({
    required TrackInfo track,
    required Duration position,
    required bool asSeek,
  }) async {
    final listeners = _controlServer.connectedDeviceIds.toList();
    if (listeners.isNotEmpty && !track.isLive) {
      _readyAcks.clear();
      _awaitingReadyAcks = true;
      try {
        _controlServer.broadcast(
          ControlMessage.prepare(
            senderId: hostDevice.deviceId,
            trackId: track.trackId,
            positionMs: position.inMilliseconds,
          ),
        );
        await _waitForReadyAcks(listeners);
      } finally {
        // A broadcast/socket error must never leave the ack window open,
        // or a later stray `ready` would be counted against a new handshake.
        _awaitingReadyAcks = false;
      }
    }

    final startAt = DateTime.now().add(_scheduleLeadTime);
    await audioEngine.scheduleStart(at: startAt, position: position);
    _controlServer.broadcast(
      asSeek
          ? ControlMessage.seek(
              senderId: hostDevice.deviceId,
              trackId: track.trackId,
              positionMs: position.inMilliseconds,
              startAtHostTimeMs: startAt.millisecondsSinceEpoch,
            )
          : ControlMessage.play(
              senderId: hostDevice.deviceId,
              trackId: track.trackId,
              positionMs: position.inMilliseconds,
              startAtHostTimeMs: startAt.millisecondsSinceEpoch,
            ),
    );
  }

  /// Polls until every listener in [listeners] has sent `ready`, or
  /// [_readyAckTimeout] elapses (proceed anyway — the engine's catch-up
  /// path covers unacknowledged devices). Listeners that disconnect
  /// mid-handshake stop counting, so a dropped device can't stall the room.
  Future<void> _waitForReadyAcks(List<String> listeners) async {
    final deadline = DateTime.now().add(_readyAckTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final connected = _controlServer.connectedDeviceIds;
      final allReady = listeners.every(
        (id) => _readyAcks.contains(id) || !connected.contains(id),
      );
      if (allReady) return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
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
    if (_systemAudioCapture.isCapturing) await stopSystemAudioBroadcast();

    // Stop any file playback so the two sources don't overlap.
    await audioEngine.pause();
    await _micBroadcaster.start();
    await _startLiveSource(
      pcm: _micBroadcaster.pcmStream,
      sampleRate: LiveMicBroadcaster.sampleRate,
      channels: LiveMicBroadcaster.channels,
      label: 'Live audio',
    );
  }

  /// Ends the live broadcast, tells listeners to stop, and returns the
  /// session to "no track selected".
  Future<void> stopLiveBroadcast() async {
    if (!_micBroadcaster.isBroadcasting) return;
    await _micBroadcaster.stop();
    await _stopLiveSource();
  }

  /// Starts broadcasting the device's **system audio** — whatever other apps
  /// are playing — to every listener. Shows the system consent dialog; throws
  /// a `PlatformException` (code `CAPTURE_DENIED`) if the user denies it.
  ///
  /// Like the mic broadcast, the host itself doesn't hear the captured audio
  /// (playing it back would feed back into the capture); listeners hear
  /// exactly what the host device's speakers are playing.
  Future<void> startSystemAudioBroadcast() async {
    if (_systemAudioCapture.isCapturing) return;
    if (_micBroadcaster.isBroadcasting) await stopLiveBroadcast();

    // Start capture first (it can be denied by the consent dialog, in which
    // case a playing file must be left untouched), then pause file playback
    // so the two sources don't overlap.
    await _systemAudioCapture.start();
    await audioEngine.pause();
    await _startLiveSource(
      pcm: _systemAudioCapture.pcmStream,
      sampleRate: SystemAudioCapture.sampleRate,
      channels: SystemAudioCapture.channels,
      label: 'Device audio',
    );
  }

  /// Ends the device-audio broadcast, tells listeners to stop, and returns
  /// the session to "no track selected".
  Future<void> stopSystemAudioBroadcast() async {
    if (!_systemAudioCapture.isCapturing) return;
    await _systemAudioCapture.stop();
    await _stopLiveSource();
  }

  /// Points the HTTP server's live route at [pcm] and announces the new live
  /// track to every listener. Shared by the mic and system-audio broadcasts.
  Future<void> _startLiveSource({
    required Stream<List<int>> pcm,
    required int sampleRate,
    required int channels,
    required String label,
  }) async {
    final trackId = generateId();
    _httpServer.setLiveSource(
      trackId: trackId,
      pcm: pcm,
      sampleRate: sampleRate,
      channels: channels,
    );

    final ip = localIp ?? await getLocalWifiIp();
    final streamUrl = 'http://$ip:${_httpServer.port}/live/$trackId';
    currentTrack = TrackInfo(
      trackId: trackId,
      fileName: label,
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

  /// Tears down the current live source: clears the server's live route,
  /// tells listeners to stop, and returns to "no track selected".
  Future<void> _stopLiveSource() async {
    final endedTrack = currentTrack;
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

  /// The user stopped the capture from the system notification (or consent
  /// was revoked): the audio stream has ended, so reset the broadcast state
  /// the same way an explicit stop would. Note [_systemAudioCapture] has
  /// already reset its own `isCapturing` by the time this runs, so the
  /// teardown below must not depend on it.
  Future<void> _handleSystemAudioStopped() async {
    await _stopLiveSource();
  }

  void _handleIncoming(IncomingControlMessage incoming) {
    try {
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
          final status = ListenerStatus(
            deviceId: incoming.deviceId,
            deviceName: message.payload['deviceName'] as String,
            playbackState: PlaybackStateJson.fromJsonValue(message.payload['playbackState'] as String),
            positionMs: message.payload['positionMs'] as int,
            syncOffsetMs: message.payload['syncOffsetMs'] as int,
            roundTripMs: message.payload['roundTripMs'] as int,
          );
          _listenerStatuses[incoming.deviceId] = status;
          // Keep the listener locked to the host's playhead: listeners report
          // their position every 2s, so if theirs has drifted we can send a
          // precise reference right now instead of waiting for a user action.
          _maybeCorrectListenerDrift(
            incoming.deviceId,
            status.positionMs,
            reportTimeMs(
              status.roundTripMs,
              DateTime.now().millisecondsSinceEpoch,
              message.payload['sentAtHostMs'] as int?,
            ),
          );
          notifyListeners();
        case ControlMessageType.ready:
          // Counted only while a prepare handshake is in flight, so stale
          // acks from a previous command can't satisfy the current wait.
          if (_awaitingReadyAcks) _readyAcks.add(incoming.deviceId);
        case ControlMessageType.calibrate:
          // A phone host doesn't mix a chirp into the music yet; answer
          // with no time so the listener says so.
          _controlServer.sendTo(
            incoming.deviceId,
            ControlMessage.calibrate(senderId: hostDevice.deviceId),
          );
        default:
          break;
      }
    } catch (e, st) {
      // A malformed frame from the network must never take the host down.
      reportError(e, st, context: 'handleIncoming');
    }
  }

  /// A phone call / navigation prompt / other app took audio focus: pause and
  /// tell listeners (their own players are not interrupted, so without this
  /// broadcast they'd keep playing out of sync). A temporary interruption
  /// re-arms playback in sync when it ends.
  Future<void> _handleInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      if (playbackState == PlaybackState.playing) {
        _pausedForInterruption = true;
        await audioEngine.pause();
        final track = currentTrack;
        if (track != null) {
          _controlServer.broadcast(
            ControlMessage.pause(
              senderId: hostDevice.deviceId,
              trackId: track.trackId,
              positionMs: position.inMilliseconds,
              hostTimeMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      }
    } else if (_pausedForInterruption) {
      _pausedForInterruption = false;
      final track = currentTrack;
      if (track != null) {
        // Re-arm in sync: listeners receive a fresh scheduled start instant.
        await _scheduleSynchronizedStart(track: track, position: position);
      }
    }
  }

  /// Broadcasts the host's current *measured* playhead to every listener so
  /// each one can re-anchor on it (listeners correct tiny drift locally; the
  /// per-listener targeted path in [_maybeCorrectListenerDrift] is a backstop
  /// for listeners that went quiet). Only while playing a file track — live
  /// broadcasts have no position to correct to.
  void _broadcastPositionReference() {
    try {
      final track = currentTrack;
      if (track == null || track.isLive) return;
      if (playbackState != PlaybackState.playing) return;
      // The position is extrapolated to *now* so the (position, hostTime)
      // pair is self-consistent — a raw polled position would lag the
      // timestamp by up to a poll interval and listeners would chase it.
      final now = DateTime.now();
      _controlServer.broadcast(
        ControlMessage.positionSync(
          senderId: hostDevice.deviceId,
          trackId: track.trackId,
          positionMs: audioEngine.estimatePositionAt(now).inMilliseconds,
          hostTimeMs: now.millisecondsSinceEpoch,
        ),
      );
    } catch (e, st) {
      // A reference tick must never take the host down (e.g. a socket
      // closing mid-broadcast during teardown).
      reportError(e, st, context: 'broadcastPositionReference');
    }
  }

  void _startPositionSyncTimer() {
    _positionSyncTimer?.cancel();
    _positionSyncTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcastPositionReference(),
    );
  }

  void _stopPositionSyncTimer() {
    _positionSyncTimer?.cancel();
    _positionSyncTimer = null;
  }

  /// Sends a drifted listener a fresh host playhead reference so it can
  /// re-anchor. Only meaningful while the host is playing a file track (live
  /// broadcasts have no position to correct to) and only when the deviation
  /// is real, so we don't chase per-sample jitter.
  void _maybeCorrectListenerDrift(String deviceId, int listenerPositionMs, int reportedAtMs) {
    if (playbackState != PlaybackState.playing) return;
    final track = currentTrack;
    if (track == null || track.isLive) return;

    // Interpolate to now on both sides: the listener's report is up to a
    // poll interval old, and our own getter would be too — comparing two
    // stale values is what makes drift detection chase quantization noise.
    final now = DateTime.now();
    final hostPositionMs = audioEngine.estimatePositionAt(now).inMilliseconds;
    // Compare against where we were when the listener measured its position,
    // not now: the report took a while to arrive.
    final drift = listenerPositionMs -
        (hostPositionMs - (now.millisecondsSinceEpoch - reportedAtMs));
    if (drift.abs() < _maxDriftMs) return;

    _controlServer.sendTo(
      deviceId,
      ControlMessage.positionSync(
        senderId: hostDevice.deviceId,
        trackId: track.trackId,
        positionMs: hostPositionMs,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _sendWelcome(String deviceId) {
    // A late joiner converts (positionMs, hostTimeMs) into its own join
    // position, so the pair must be self-consistent — extrapolate the
    // playhead to the same instant hostTimeMs is stamped.
    final now = DateTime.now();
    _controlServer.sendTo(
      deviceId,
      ControlMessage.welcome(
        senderId: hostDevice.deviceId,
        sessionId: sessionId,
        sessionName: sessionName,
        hostDeviceId: hostDevice.deviceId,
        currentTrack: currentTrack,
        playbackState: playbackState.toJsonValue(),
        positionMs: audioEngine.estimatePositionAt(now).inMilliseconds,
        hostTimeMs: now.millisecondsSinceEpoch,
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
    await _interruptionSub?.cancel();
    _stopPositionSyncTimer();
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
    // Release the audio engine promptly so a follow-up screen (e.g. joining a
    // session right after leaving host) doesn't run two players at once.
    _stopPositionSyncTimer();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await audioEngine.dispose();
    await _micBroadcaster.dispose();
    await _systemAudioCapture.dispose();
    // stop() also cancels the (now already cancelled) subs again — harmless.
    await stop();
  }
}
