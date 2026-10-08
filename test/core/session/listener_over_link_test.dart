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
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Duration get currentPosition => Duration.zero;
  @override
  Duration estimatePositionAt(DateTime t) => Duration.zero;
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
}
