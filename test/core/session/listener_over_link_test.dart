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
    void hostReceives(String frame) {
      final m = ControlMessage.decode(frame);
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

    // The listener always plays 150 ms behind whatever it was told.
    final start = DateTime.now();
    int hostPos(DateTime t) => 10000 + t.difference(start).inMilliseconds;
    engine.estimate = (t) => Duration(milliseconds: hostPos(t) - 150);
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
    reference();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.seekLeadMs, closeTo(150, 10));
    final first = engine.seeks[0].inMilliseconds - hostPos(DateTime.now());
    final second = engine.seeks[1].inMilliseconds - hostPos(DateTime.now());
    expect(second - first, closeTo(150, 30));
    session.dispose();
  });
}
