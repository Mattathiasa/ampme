import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// What a reloaded host page needs to pick its session back up.
class ResumeInfo {
  const ResumeInfo({
    required this.code,
    required this.name,
    required this.joinCode,
    this.joinLink,
    this.trackId,
    this.fileName,
    this.playing = false,
    this.positionMs = 0,
    this.wallMs = 0,
  });

  final String code;
  final String name;
  final String joinCode;
  final String? joinLink;
  final String? trackId;
  final String? fileName;
  final bool playing;
  final int positionMs;
  final int wallMs;
}

/// Saves a web-hosted session in this browser so a reload (or a crashed tab)
/// doesn't end it: the session in localStorage, the song in Cache Storage.
/// Cloud sessions only — a LAN relay drops the session with the host.
class SessionResumeStore {
  SessionResumeStore._();

  static const _key = 'ampme.hostSession';
  static const _cacheName = 'ampme-host';
  static const _trackPath = 'resume-track';

  /// Resume is offered for this long after the page went away.
  static const maxAge = Duration(minutes: 15);

  /// Larger songs/videos aren't kept (storage quota).
  static const maxTrackBytes = 500 * 1024 * 1024;

  static Map<String, dynamic>? _read() {
    try {
      final raw = web.window.localStorage.getItem(_key);
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static void _write(Map<String, dynamic> data) {
    try {
      web.window.localStorage.setItem(_key, jsonEncode(data));
    } catch (_) {
      // Storage blocked (private mode): resume just isn't offered.
    }
  }

  static void saveSession({
    required String code,
    required String name,
    required String joinCode,
    String? joinLink,
  }) {
    final previous = _read();
    // The same session resumed: its saved song is still the one playing.
    final sameSession = previous != null && previous['code'] == code;
    _write({
      if (sameSession) 'trackId': previous['trackId'],
      if (sameSession) 'fileName': previous['fileName'],
      'code': code,
      'name': name,
      'joinCode': joinCode,
      'joinLink': joinLink,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Where the timeline is (call often, and when the page hides).
  static void saveTimeline({required bool playing, required int positionMs}) {
    final data = _read();
    if (data == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _write({...data, 'playing': playing, 'positionMs': positionMs, 'wallMs': now, 'savedAt': now});
  }

  static Future<void> saveTrack({
    required String trackId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final data = _read();
    if (data == null) return;
    data
      ..remove('trackId')
      ..remove('fileName');
    _write(data);
    if (bytes.length > maxTrackBytes || !web.window.has('caches')) return;
    try {
      final cache = await web.window.caches.open(_cacheName).toDart;
      await cache
          .put(_trackPath.toJS, web.Response(web.Blob([bytes.toJS].toJS)))
          .toDart;
      _write({..._read() ?? data, 'trackId': trackId, 'fileName': fileName});
    } catch (_) {
      // Over quota or blocked: resume without the song.
    }
  }

  static ResumeInfo? load() {
    final data = _read();
    if (data == null) return null;
    final savedAt = data['savedAt'] as int? ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - savedAt;
    if (age > maxAge.inMilliseconds) {
      clear();
      return null;
    }
    final code = data['code'] as String?;
    if (code == null) return null;
    return ResumeInfo(
      code: code,
      name: data['name'] as String? ?? 'Ampme session',
      joinCode: data['joinCode'] as String? ?? code,
      joinLink: data['joinLink'] as String?,
      trackId: data['trackId'] as String?,
      fileName: data['fileName'] as String?,
      playing: data['playing'] as bool? ?? false,
      positionMs: data['positionMs'] as int? ?? 0,
      wallMs: data['wallMs'] as int? ?? savedAt,
    );
  }

  static Future<Uint8List?> loadTrackBytes() async {
    if (!web.window.has('caches')) return null;
    try {
      final cache = await web.window.caches.open(_cacheName).toDart;
      final match = await cache.match(_trackPath.toJS).toDart;
      if (match == null) return null;
      final buffer = await match.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static void clear() {
    try {
      web.window.localStorage.removeItem(_key);
    } catch (_) {}
    if (web.window.has('caches')) {
      web.window.caches.delete(_cacheName).toDart.ignore();
    }
  }
}
