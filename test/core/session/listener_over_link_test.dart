import 'dart:async';

import 'package:ampme/core/audio/audio_engine.dart';
import 'package:ampme/core/network/models/control_message.dart';
import 'package:ampme/core/network/models/device_info.dart';
import 'package:ampme/core/network/models/playback_state.dart';
import 'package:ampme/core/network/models/track_info.dart';
import 'package:ampme/core/network/pipe_control_link.dart';
import 'package:ampme/core/session/listener_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEngine implements AudioEngine {
  final loaded = <Uri>[];
  final scheduled = <({DateTime at, Duration position})>[];
  final prepared = <Duration>[];
  final seeks = <Duration>[];
  Duration Function(DateTime t) estimate = (_) => Duration.zero;
  final _state = StreamController<PlaybackState>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    loaded.add(uri);
    return const Duration(minutes: 3);
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) async => null;
  @override
  Future<void> prepareForStart(Duration position) async => prepared.add(position);
  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async =>
      scheduled.add((at: at, position: position));
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setVolume(double volume) async {}
  final speeds = <double>[];
  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);
  @override
  Duration get currentPosition => Duration.zero;
  @override
  Duration estimatePositionAt(DateTime t) => estimate(t);
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<PlaybackState> get stateStream => _state.stream;
  @override
  Duration? get duration => null;
  @override
  Future<void> dispose() async {}
}

/// A host whose clock runs [hostAheadMs] ahead of ours, answering clock sync
/// over the pipe the way the web host does.
const int hostAheadMs = 4000;

void main() {
  test('a browser-hosted session schedules the start on the host timeline', () async {
    final toListener = StreamController<String>();
    final fromListener = <ControlMessage>[];
    final receivedAt = <ControlMessage, int>{};
    void hostReceives(String frame) {
      final m = ControlMessage.decode(frame);
      receivedAt[m] = DateTime.now().millisecondsSinceEpoch;
      if (m.type == ControlMessageType.clockSyncRequest) {
        scheduleMicrotask(() => toListener.add(
              ControlMessage.clockSyncResponse(
                senderId: 'host',
                clientSendTimeMs: m.payload['clientSendTimeMs'] as int,
                hostTimeMs: DateTime.now().millisecondsSinceEpoch + hostAheadMs,
              ).encode(),
            ));
      } else {
        fromListener.add(m);
      }
    }

    final file = Completer<Uri>();
    final resolved = <String>[];
    final engine = _FakeEngine();
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'phone', deviceName: 'Phone', platform: 'android'),
      audioEngine: engine,
      trackResolver: (track) {
        resolved.add(track.trackId);
        return file.future;
      },
    );
    final link = PipeControlLink(
      deviceId: 'phone',
      incoming: toListener.stream,
      sendFrame: hostReceives,
    );
    session.attach(link);

    const track = TrackInfo(trackId: 'song1', fileName: 'song.mp3', streamUrl: '', durationMs: 180000);
    toListener.add(
      ControlMessage.welcome(
        senderId: 'host',
        sessionId: 'AMP-TEST',
        sessionName: 'Party',
        hostDeviceId: 'host',
        currentTrack: track,
        playbackState: 'stopped',
        positionMs: 0,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch + hostAheadMs,
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(session.sessionName, 'Party');
    expect(resolved, ['song1']);
    expect(engine.loaded, isEmpty, reason: 'waits for the song bytes');

    file.complete(Uri.parse('blob:song1'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(engine.loaded, [Uri.parse('blob:song1')]);

    toListener.add(ControlMessage.prepare(senderId: 'host', trackId: 'song1', positionMs: 0).encode());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fromListener.where((m) => m.type == ControlMessageType.ready), hasLength(1));

    final startAtHost = DateTime.now().millisecondsSinceEpoch + hostAheadMs + 800;
    toListener.add(
      ControlMessage.play(
        senderId: 'host',
        trackId: 'song1',
        positionMs: 0,
        startAtHostTimeMs: startAtHost,
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final start = engine.scheduled.single;
    // Converted to our clock: the host's instant minus its 4 s lead.
    expect(
      start.at.millisecondsSinceEpoch,
      closeTo(startAtHost - hostAheadMs, 15),
    );
    expect(session.hostIsPlaying, isTrue);

    // Status reports carry the instant they were measured, on the host's
    // clock, so the host compares at that instant whatever the delivery delay.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    final status = fromListener.lastWhere((m) => m.type == ControlMessageType.listenerStatusUpdate);
    expect(
      status.payload['sentAtHostMs'] as int,
      closeTo(receivedAt[status]! + hostAheadMs, 30),
    );

    session.dispose();
  });

  test('drift corrections learn how late their seeks land', () async {
    final toListener = StreamController<String>();
    final engine = _FakeEngine();
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'web'),
      audioEngine: engine,
      trackResolver: (_) async => Uri.parse('blob:x'),
    );
    session.attach(PipeControlLink(deviceId: 'p', incoming: toListener.stream, sendFrame: (_) {}));
    const track = TrackInfo(trackId: 't', fileName: 'clip.webm', streamUrl: '', durationMs: 60000);
    toListener.add(ControlMessage.trackChanged(senderId: 'host', track: track).encode());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine._state.add(PlaybackState.playing);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Every seek lands 150 ms later than it aims (decoder restart), so the
    // device plays at `aim - 150`, where aim = target + the learned lead.
    final start = DateTime.now();
    int hostPos(DateTime t) => 10000 + t.difference(start).inMilliseconds;
    engine.estimate = (t) => Duration(milliseconds: hostPos(t) - 150 + session.seekLeadMs);
    void reference() => toListener.add(
          ControlMessage.positionSync(
            senderId: 'host',
            trackId: 't',
            positionMs: hostPos(DateTime.now()),
            hostTimeMs: DateTime.now().millisecondsSinceEpoch,
          ).encode(),
        );

    reference();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.seekLeadMs, 0);
    expect(engine.seeks, hasLength(1));

    // Too soon after a seek: no new correction, no learning.
    reference();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.seeks, hasLength(1));
    expect(session.seekLeadMs, 0);

    // Once it has settled: learn 70 % of the error and aim further ahead.
    session.debugAgeLastCorrection(const Duration(seconds: 3));
    reference();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.seeks, hasLength(2));
    expect(session.seekLeadMs, closeTo(105, 10));
    // Now ~45 ms behind: small enough to trim with the playback rate rather
    // than another (imprecise) seek.
    session.debugAgeLastCorrection(const Duration(seconds: 3));
    reference();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.seeks, hasLength(2));
    expect(session.seekLeadMs, closeTo(105, 10));
    expect(engine.speeds.last, greaterThan(1.0));
    expect(engine.speeds.last, lessThanOrEqualTo(1.03));
    session.dispose();
  });

  test('small drift is trimmed with the rate, never by hunting with seeks', () async {
    final toListener = StreamController<String>();
    final engine = _FakeEngine();
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
      audioEngine: engine,
      trackResolver: (_) async => Uri.parse('blob:x'),
    );
    session.attach(PipeControlLink(deviceId: 'p', incoming: toListener.stream, sendFrame: (_) {}));
    const track = TrackInfo(trackId: 't', fileName: 'a.mp3', streamUrl: '', durationMs: 60000);
    toListener.add(ControlMessage.trackChanged(senderId: 'host', track: track).encode());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine._state.add(PlaybackState.playing);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    var offBy = 0;
    engine.estimate = (_) => Duration(milliseconds: 20000 + offBy);
    Future<void> reference() async {
      toListener.add(ControlMessage.positionSync(
        senderId: 'host',
        trackId: 't',
        positionMs: 20000,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch,
      ).encode());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // The readings that made the emulator hunt: 98, -71, 46, 133 ms...
    for (final d in [98, -71, 46, -60, 90]) {
      offBy = d;
      await reference();
    }
    expect(engine.seeks, isEmpty, reason: 'all within the trim range');
    // Ahead -> slower, behind -> faster, bounded to ±3 %.
    expect(engine.speeds, [
      for (final d in [98, -71, 46, -60, 90]) closeTo((1 - d / 2000).clamp(0.97, 1.03), 0.002),
    ]);

    // Back in sync: normal speed again.
    offBy = 4;
    await reference();
    expect(engine.speeds.last, 1.0);

    // Big jump: seek, at normal speed.
    offBy = -400;
    await reference();
    expect(engine.seeks, hasLength(1));
    expect(engine.speeds.last, 1.0);
    session.dispose();
  });

  test('a sync nudge plays this device that much ahead of the timeline', () async {
    final toListener = StreamController<String>();
    final sent = <ControlMessage>[];
    final engine = _FakeEngine();
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
      audioEngine: engine,
      trackResolver: (_) async => Uri.parse('blob:x'),
    );
    session.attach(PipeControlLink(
      deviceId: 'p',
      incoming: toListener.stream,
      sendFrame: (f) => sent.add(ControlMessage.decode(f)),
    ));
    session.setSyncNudge(200);
    expect(session.syncNudgeMs, 200);
    session.setSyncNudge(9000);
    expect(session.syncNudgeMs, 500, reason: 'clamped');
    session.setSyncNudge(200);

    const track = TrackInfo(trackId: 't', fileName: 'a.mp3', streamUrl: '', durationMs: 60000);
    toListener.add(ControlMessage.trackChanged(senderId: 'host', track: track).encode());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Scheduled start: 200 ms further into the song.
    toListener.add(ControlMessage.play(
      senderId: 'host',
      trackId: 't',
      positionMs: 1000,
      startAtHostTimeMs: DateTime.now().millisecondsSinceEpoch + 800,
    ).encode());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(engine.scheduled.single.position, const Duration(milliseconds: 1200));

    // Drift loop: a device exactly on the timeline is 200 ms "late" against
    // its nudged target, so it seeks ahead to timeline + 200.
    engine._state.add(PlaybackState.playing);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine.estimate = (_) => const Duration(milliseconds: 5000);
    toListener.add(ControlMessage.positionSync(
      senderId: 'host',
      trackId: 't',
      positionMs: 5000,
      hostTimeMs: DateTime.now().millisecondsSinceEpoch,
    ).encode());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.seeks.single.inMilliseconds, closeTo(5200, 15));

    // Once there, it's in sync: no further seek, and the host sees ~0 drift.
    engine.estimate = (_) => const Duration(milliseconds: 5200);
    session.debugAgeLastCorrection(const Duration(seconds: 3));
    toListener.add(ControlMessage.positionSync(
      senderId: 'host',
      trackId: 't',
      positionMs: 5000,
      hostTimeMs: DateTime.now().millisecondsSinceEpoch,
    ).encode());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.seeks, hasLength(1));
    session.dispose();
  });
}
