import 'dart:async';
import 'dart:typed_data';

import 'package:ampme/core/audio/audio_engine.dart';
import 'package:ampme/core/network/models/control_message.dart';
import 'package:ampme/core/network/models/device_info.dart';
import 'package:ampme/core/network/models/playback_state.dart';
import 'package:ampme/core/network/models/track_info.dart';
import 'package:ampme/core/network/pipe_control_link.dart';
import 'package:ampme/core/session/listener_session_controller.dart';
import 'package:ampme/core/sync/acoustic_calibration.dart';
import 'package:ampme/core/sync/calibration_mic.dart';
import 'package:ampme/core/sync/chirp_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// A player that starts exactly when scheduled and reports honestly.
class _Engine implements AudioEngine {
  DateTime? startedAt;
  Duration startPos = Duration.zero;
  final scheduled = <({DateTime at, Duration position})>[];
  final loaded = <Uri>[];
  final _state = StreamController<PlaybackState>.broadcast();

  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async {
    scheduled.add((at: at, position: position));
    startedAt = at;
    startPos = position;
  }

  /// Like Android before AudioTrack timestamps arrive: for [startupWindow]
  /// after each start the reported position runs [startupBiasMs] behind the
  /// truth, then it's exact.
  int startupBiasMs = 0;
  Duration startupWindow = const Duration(milliseconds: 800);

  @override
  Duration estimatePositionAt(DateTime t) {
    final s = startedAt;
    if (s == null || t.isBefore(s)) return Duration.zero;
    final truth = startPos + t.difference(s);
    if (t.difference(s) < startupWindow) {
      return truth - Duration(milliseconds: startupBiasMs);
    }
    return truth;
  }

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    loaded.add(uri);
    startedAt = null;
    return const Duration(minutes: 3);
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) async => null;
  @override
  Future<void> prepareForStart(Duration position) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async => startedAt = null;
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Duration get currentPosition => Duration.zero;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<PlaybackState> get stateStream => _state.stream;
  @override
  Duration? get duration => null;
  @override
  Future<void> dispose() async {}
}

/// A room: hears the host's chirp when it was due, and this device's chirp
/// [deviceLateMs] after its player said it played.
class _RoomMic implements CalibrationMic {
  _RoomMic(this.hostChirpAt, this.deviceChirpAt, this.deviceLateMs);

  final DateTime? Function() hostChirpAt;
  final DateTime? Function() deviceChirpAt;
  final int deviceLateMs;
  late DateTime _start;

  @override
  Future<void> start() async => _start = DateTime.now();

  @override
  Future<Float32List> stop() async {
    const rate = CalibrationMic.sampleRate;
    final rec = Float32List(rate * 3);
    void put(Float32List chirp, DateTime at, double gain) {
      final i = at.difference(_start).inMicroseconds * rate ~/ 1000000;
      for (var k = 0; k < chirp.length && i + k < rec.length; k++) {
        if (i + k >= 0) rec[i + k] += chirp[k] * gain;
      }
    }

    put(AcousticCalibration.chirp(rate, up: true), hostChirpAt()!, 0.4);
    put(
      AcousticCalibration.chirp(rate, up: false),
      deviceChirpAt()!.add(Duration(milliseconds: deviceLateMs)),
      1,
    );
    return rec;
  }
}

void main() {
  test(
    'mic calibration measures a 120 ms late speaker and resumes the song',
    () async {
      final toListener = StreamController<String>();
      final engine = _Engine();
      DateTime? hostChirp;
      DateTime? deviceChirp;
      late ListenerSessionController session;
      session = ListenerSessionController(
        selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
        audioEngine: engine,
        trackResolver: (_) async => Uri.parse('blob:song'),
        micFactory: () => _RoomMic(
          () => hostChirp,
          // The chirp player starts [ChirpPlayer.leadMs] of silence before the chirp.
          () => deviceChirp = engine.startedAt!.add(const Duration(milliseconds: ChirpPlayer.leadMs)),
          120,
        ),
      );
      session.attach(
        PipeControlLink(
          deviceId: 'p',
          incoming: toListener.stream,
          sendFrame: (frame) {
            final m = ControlMessage.decode(frame);
            if (m.type == ControlMessageType.calibrate) {
              final at = DateTime.now().add(const Duration(milliseconds: 2000));
              hostChirp = at;
              scheduleMicrotask(
                () => toListener.add(
                  ControlMessage.calibrate(
                    senderId: 'host',
                    chirpAtHostTimeMs: at.millisecondsSinceEpoch,
                  ).encode(),
                ),
              );
            }
          },
        ),
      );
      const track = TrackInfo(trackId: 't', fileName: 'a.mp3', streamUrl: '', durationMs: 180000);
      toListener.add(ControlMessage.trackChanged(senderId: 'host', track: track).encode());
      final songStart = DateTime.now();
      toListener.add(
        ControlMessage.play(
          senderId: 'host',
          trackId: 't',
          positionMs: 30000,
          startAtHostTimeMs: songStart.millisecondsSinceEpoch,
        ).encode(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(session.hostIsPlaying, isTrue);

      final nudge = await session.calibrateWithMic();
      expect(deviceChirp, isNotNull);
      expect(nudge, closeTo(120, 3));
      expect(session.syncNudgeMs, nudge);

      // The song is back in the player and rescheduled ~120 ms ahead of the host.
      expect(engine.loaded.last, Uri.parse('blob:song'));
      final resume = engine.scheduled.last;
      final hostAtResume = 30000 + resume.at.difference(songStart).inMilliseconds;
      expect(resume.position.inMilliseconds - nudge, closeTo(hostAtResume, 50));
      session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('an older host that cannot play the chirp says so', () async {
    final toListener = StreamController<String>();
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
      audioEngine: _Engine(),
      micFactory: () => _RoomMic(() => null, () => null, 0),
    );
    session.attach(
      PipeControlLink(
        deviceId: 'p',
        incoming: toListener.stream,
        sendFrame: (frame) {
          if (ControlMessage.decode(frame).type == ControlMessageType.calibrate) {
            scheduleMicrotask(
              () => toListener.add(ControlMessage.calibrate(senderId: 'host').encode()),
            );
          }
        },
      ),
    );
    await expectLater(
      session.calibrateWithMic(),
      throwsA(isA<CalibrationException>().having((e) => e.message, 'message', contains('older Ampme'))),
    );
    session.dispose();
  });

  test('a phone host plans its chirp ahead, then reports when it really sounded', () async {
    final engine = _Engine();
    final before = DateTime.now().millisecondsSinceEpoch;
    final chirp = ChirpPlayer(engine).startHostChirp();
    expect(chirp.plannedMs - before, inInclusiveRange(1990, 2100));
    // The player starts [leadMs] early so the chirp lands on the plan.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      engine.scheduled.single.at.millisecondsSinceEpoch,
      chirp.plannedMs - ChirpPlayer.leadMs,
    );
    // This fake starts exactly when scheduled, so the measured time matches.
    expect(await chirp.actualMs, closeTo(chirp.plannedMs, 5));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a late-starting phone host chirp is corrected by its follow-up', () async {
    // The host planned its chirp for T but its player only got going 120 ms
    // later; it says so. Without the follow-up this device would look 120 ms
    // early.
    final toListener = StreamController<String>();
    final engine = _Engine();
    DateTime? hostChirp;
    final session = ListenerSessionController(
      selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
      audioEngine: engine,
      micFactory: () => _RoomMic(
        () => hostChirp,
        () => engine.startedAt!.add(const Duration(milliseconds: ChirpPlayer.leadMs)),
        40,
      ),
    );
    session.attach(
      PipeControlLink(
        deviceId: 'p',
        incoming: toListener.stream,
        sendFrame: (frame) {
          if (ControlMessage.decode(frame).type != ControlMessageType.calibrate) return;
          final planned = DateTime.now().add(const Duration(milliseconds: 2000));
          final actual = planned.add(const Duration(milliseconds: 120));
          hostChirp = actual;
          scheduleMicrotask(() => toListener.add(ControlMessage.calibrate(
                senderId: 'host',
                chirpAtHostTimeMs: planned.millisecondsSinceEpoch,
              ).encode()));
          Timer(const Duration(milliseconds: 2400), () => toListener.add(ControlMessage.calibrate(
                senderId: 'host',
                chirpAtHostTimeMs: actual.millisecondsSinceEpoch,
                measured: true,
              ).encode()));
        },
      ),
    );
    expect(await session.calibrateWithMic(), closeTo(40, 5));
    session.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test(
    'a player whose position is rough right after starting still measures true',
    () async {
      // The user's case: a phone 60 ms late, whose player under-reports its
      // position by 60 ms for its first 800 ms. Judged in that window, the
      // chirp looked on time and calibration said 0 ms.
      final toListener = StreamController<String>();
      final engine = _Engine()..startupBiasMs = 60;
      DateTime? hostChirp;
      final session = ListenerSessionController(
        selfDevice: const DeviceInfo(deviceId: 'p', deviceName: 'P', platform: 'android'),
        audioEngine: engine,
        micFactory: () => _RoomMic(
          () => hostChirp,
          () => engine.startedAt!.add(const Duration(milliseconds: ChirpPlayer.leadMs)),
          60,
        ),
      );
      session.attach(
        PipeControlLink(
          deviceId: 'p',
          incoming: toListener.stream,
          sendFrame: (frame) {
            if (ControlMessage.decode(frame).type == ControlMessageType.calibrate) {
              final at = DateTime.now().add(const Duration(milliseconds: 2000));
              hostChirp = at;
              scheduleMicrotask(
                () => toListener.add(
                  ControlMessage.calibrate(
                    senderId: 'host',
                    chirpAtHostTimeMs: at.millisecondsSinceEpoch,
                  ).encode(),
                ),
              );
            }
          },
        ),
      );
      final nudge = await session.calibrateWithMic();
      expect(nudge, closeTo(60, 5));
      session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
