import 'package:ampme/core/network/models/control_message.dart';
import 'package:ampme/core/network/models/track_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ControlMessage JSON round trip', () {
    const track = TrackInfo(
      trackId: 'track-1',
      fileName: 'song.mp3',
      streamUrl: 'http://192.168.1.5:8080/stream/track-1',
      durationMs: 180000,
    );

    void expectRoundTrip(ControlMessage message) {
      final decoded = ControlMessage.decode(message.encode());
      expect(decoded.type, message.type);
      expect(decoded.senderId, message.senderId);
      expect(decoded.payload, message.payload);
    }

    test('welcome with a current track', () {
      expectRoundTrip(
        ControlMessage.welcome(
          senderId: 'host-1',
          sessionId: 'session-1',
          sessionName: 'Party',
          hostDeviceId: 'host-1',
          currentTrack: track,
          playbackState: 'playing',
          positionMs: 5000,
          hostTimeMs: 1700000000000,
        ),
      );
    });

    test('welcome with no current track', () {
      expectRoundTrip(
        ControlMessage.welcome(
          senderId: 'host-1',
          sessionId: 'session-1',
          sessionName: 'Party',
          hostDeviceId: 'host-1',
          currentTrack: null,
          playbackState: 'stopped',
          positionMs: 0,
          hostTimeMs: 1700000000000,
        ),
      );
    });

    test('trackChanged', () {
      expectRoundTrip(ControlMessage.trackChanged(senderId: 'host-1', track: track));
    });

    test('play', () {
      expectRoundTrip(
        ControlMessage.play(
          senderId: 'host-1',
          trackId: 'track-1',
          positionMs: 1000,
          startAtHostTimeMs: 1700000001000,
        ),
      );
    });

    test('prepare (ready-ack handshake)', () {
      expectRoundTrip(
        ControlMessage.prepare(
          senderId: 'host-1',
          trackId: 'track-1',
          positionMs: 1000,
        ),
      );
    });

    test('ready (ready-ack handshake)', () {
      expectRoundTrip(
        ControlMessage.ready(
          senderId: 'listener-1',
          trackId: 'track-1',
          positionMs: 1000,
        ),
      );
    });

    test('pause', () {
      expectRoundTrip(
        ControlMessage.pause(
          senderId: 'host-1',
          trackId: 'track-1',
          positionMs: 1000,
          hostTimeMs: 1700000001000,
        ),
      );
    });

    test('seek', () {
      expectRoundTrip(
        ControlMessage.seek(
          senderId: 'host-1',
          trackId: 'track-1',
          positionMs: 30000,
          startAtHostTimeMs: 1700000002000,
        ),
      );
    });

    test('volume', () {
      expectRoundTrip(ControlMessage.volume(senderId: 'host-1', volume: 0.75));
    });

    test('positionSync', () {
      expectRoundTrip(
        ControlMessage.positionSync(
          senderId: 'host-1',
          trackId: 'track-1',
          positionMs: 45000,
          hostTimeMs: 1700000002000,
        ),
      );
    });

    test('clockSyncRequest', () {
      expectRoundTrip(
        ControlMessage.clockSyncRequest(senderId: 'listener-1', clientSendTimeMs: 1700000000500),
      );
    });

    test('clockSyncResponse', () {
      expectRoundTrip(
        ControlMessage.clockSyncResponse(
          senderId: 'host-1',
          clientSendTimeMs: 1700000000500,
          hostTimeMs: 1700000000600,
        ),
      );
    });

    test('listenerStatusUpdate', () {
      expectRoundTrip(
        ControlMessage.listenerStatusUpdate(
          senderId: 'listener-1',
          deviceName: 'Pixel',
          playbackState: 'playing',
          positionMs: 12000,
          syncOffsetMs: 15,
          roundTripMs: 40,
        ),
      );
    });

    test('sessionEnded', () {
      expectRoundTrip(ControlMessage.sessionEnded(senderId: 'host-1'));
    });

    test('decode throws for an unknown message type rather than silently accepting it', () {
      expect(
        () => ControlMessage.decode('{"type":"bogus","senderId":"x","payload":{}}'),
        throwsFormatException,
      );
    });

    test('decode throws for malformed JSON', () {
      expect(() => ControlMessage.decode('not json'), throwsFormatException);
    });
  });
}
