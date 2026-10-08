import 'package:flutter/services.dart';

import '../observability/reporting.dart';

const MethodChannel _channel = MethodChannel('com.ampme/media');

/// Copies the sound track of the video at [path] into an audio-only file
/// (Android, no re-encoding) and returns its path. Returns null when that
/// isn't possible (no sound, unsupported codec, other platforms): the caller
/// then serves the original file.
Future<String?> extractAudioTrack(String path) async {
  try {
    return await _channel.invokeMethod<String>('extractAudio', {'path': path});
  } on MissingPluginException {
    return null;
  } catch (e, st) {
    reportError(e, st, context: 'extractAudioTrack');
    return null;
  }
}
