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

  @override
  Duration estimatePositionAt(DateTime t) {
    final s = startedAt;
    if (s == null || t.isBefore(s)) return Duration.zero;
    return startPos + t.difference(s);
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
          // The chirp player starts 300 ms of lead-in before the chirp.
          () => deviceChirp = engine.startedAt!.add(const Duration(milliseconds: 300)),
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
              final at = DateTime.now().add(const Duration(milliseconds: 300));
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

  test('a phone host says it cannot play the chirp', () async {
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
      throwsA(isA<CalibrationException>().having((e) => e.message, 'message', contains('web app'))),
    );
    session.dispose();
  });
}
