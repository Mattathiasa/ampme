import 'package:ampme/core/network/webrtc/opus_sdp.dart';
import 'package:flutter_test/flutter_test.dart';

const _answer = 'v=0\r\n'
    'o=- 1 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 9\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
    'a=rtpmap:63 red/48000/2\r\n'
    'a=fmtp:63 111/111\r\n'
    'a=rtpmap:9 G722/8000\r\n';

void main() {
  test('adds stereo + music bitrate to the Opus fmtp, keeping its params', () {
    final out = withMusicOpusParams(_answer);
    expect(
      out,
      contains(
        'a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1;'
        'maxaveragebitrate=128000\r\n',
      ),
    );
  });

  test('leaves other codecs and line endings alone', () {
    final out = withMusicOpusParams(_answer);
    expect(out, contains('a=fmtp:63 111/111\r\n'));
    expect(out, contains('a=rtpmap:9 G722/8000\r\n'));
    expect(out.split('\r\n').length, _answer.split('\r\n').length);
  });

  test('is idempotent and overrides existing values', () {
    final once = withMusicOpusParams(
      _answer.replaceFirst('useinbandfec=1', 'useinbandfec=1;stereo=0'),
    );
    expect(withMusicOpusParams(once), once);
    expect(once, contains('stereo=1'));
    expect(once, isNot(contains('stereo=0')));
  });

  test('adds an fmtp line when Opus has none', () {
    const sdp = 'm=audio 9 RTP/SAVPF 96\na=rtpmap:96 opus/48000/2\na=sendrecv\n';
    expect(
      withMusicOpusParams(sdp),
      'm=audio 9 RTP/SAVPF 96\na=rtpmap:96 opus/48000/2\n'
      'a=fmtp:96 stereo=1;sprop-stereo=1;maxaveragebitrate=128000\n'
      'a=sendrecv\n',
    );
  });

  test('SDP without Opus is returned unchanged', () {
    const sdp = 'm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n';
    expect(withMusicOpusParams(sdp), sdp);
  });
}
