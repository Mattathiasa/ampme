/// Opus parameters a *receiver* advertises in its SDP to get music-grade
/// audio instead of WebRTC's voice defaults (mono, ~32 kbps): per RFC 7587,
/// `stereo=1` asks the sender to encode stereo and `maxaveragebitrate` caps
/// what it may send — browsers raise their encoder bitrate to match.
const Map<String, String> musicOpusParams = {
  'stereo': '1',
  'sprop-stereo': '1',
  'maxaveragebitrate': '128000',
};

/// Returns [sdp] with [musicOpusParams] set on every Opus payload type's
/// `a=fmtp` line (adding the line if it's missing). Other codecs, and SDP
/// without Opus, are returned unchanged. Line endings are preserved.
String withMusicOpusParams(String sdp) {
  final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(eol);
  final opusTypes = <String>{
    for (final line in lines)
      if (RegExp(r'^a=rtpmap:(\d+) opus/', caseSensitive: false).firstMatch(line)
          case final m?)
        m.group(1)!,
  };
  if (opusTypes.isEmpty) return sdp;

  final out = <String>[];
  final withFmtp = <String>{};
  for (final line in lines) {
    final fmtp = RegExp(r'^a=fmtp:(\d+) (.*)$').firstMatch(line);
    if (fmtp != null && opusTypes.contains(fmtp.group(1))) {
      withFmtp.add(fmtp.group(1)!);
      out.add('a=fmtp:${fmtp.group(1)} ${_mergeParams(fmtp.group(2)!)}');
      continue;
    }
    out.add(line);
  }
  // Opus payload types with no fmtp line get one right after their rtpmap.
  for (final pt in opusTypes.difference(withFmtp)) {
    final i = out.indexWhere((l) => l.startsWith('a=rtpmap:$pt '));
    out.insert(i + 1, 'a=fmtp:$pt ${_mergeParams('')}');
  }
  return out.join(eol);
}

String _mergeParams(String existing) {
  final params = <String, String>{};
  for (final part in existing.split(';')) {
    final kv = part.trim();
    if (kv.isEmpty) continue;
    final eq = kv.indexOf('=');
    if (eq < 0) {
      params[kv] = '';
    } else {
      params[kv.substring(0, eq)] = kv.substring(eq + 1);
    }
  }
  params.addAll(musicOpusParams);
  return params.entries
      .map((e) => e.value.isEmpty ? e.key : '${e.key}=${e.value}')
      .join(';');
}
