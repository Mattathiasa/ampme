import 'dart:collection';

import 'package:package_info_plus/package_info_plus.dart';

import 'scrub.dart';

/// One reading of how far this device is from the host's timeline.
typedef SyncReading = ({
  DateTime at,
  int drift,
  int target,
  int estimate,
  int offset,
  int? rtt,
  int seekLead,
  int startLead,
  int nudge,
  String action,
});

/// What went wrong and how sync has been going, kept in memory so a person
/// can copy it from the app and send it — a bad-sync report no longer needs
/// a cable and `adb logcat`. Bounded; nothing leaves the device unless the
/// person copies it, and session codes and IP addresses are removed.
class Diagnostics {
  Diagnostics._();

  static const int _maxErrors = 30;
  static const int _maxReadings = 240;

  static final ListQueue<({DateTime at, String text})> _errors = ListQueue();
  static final ListQueue<SyncReading> _readings = ListQueue();

  static void error(String context, Object error) {
    var text = scrubSensitive('$context: $error');
    if (text.length > 300) text = '${text.substring(0, 300)}…';
    if (_errors.length >= _maxErrors) _errors.removeFirst();
    _errors.add((at: DateTime.now(), text: text));
  }

  static void sync(SyncReading reading) {
    if (_readings.length >= _maxReadings) _readings.removeFirst();
    _readings.add(reading);
  }

  static void clear() {
    _errors.clear();
    _readings.clear();
  }

  /// The report: [state] (what the app knows about this session right now)
  /// then the recent errors, then the recent sync readings, newest last.
  static Future<String> report({Map<String, String> state = const {}}) async {
    String version;
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      version = 'unknown';
    }
    return format(version: version, state: state);
  }

  /// [report] with the version already known (and testable without a platform).
  static String format({required String version, Map<String, String> state = const {}}) {
    final b = StringBuffer()
      ..writeln('Ampme diagnostics')
      ..writeln('version: $version')
      ..writeln('time: ${DateTime.now().toUtc().toIso8601String()}');
    state.forEach((k, v) => b.writeln('$k: ${scrubSensitive(v)}'));
    b
      ..writeln()
      ..writeln('-- recent errors (${_errors.length}) --');
    for (final e in _errors) {
      b.writeln('${_clock(e.at)} ${e.text}');
    }
    b
      ..writeln()
      ..writeln('-- sync readings, newest last (${_readings.length}) --')
      ..writeln('time  drift  target  est  offset  rtt  seekLead  startLead  nudge  action');
    for (final r in _readings) {
      b.writeln(
        '${_clock(r.at)}  ${r.drift}  ${r.target}  ${r.estimate}  ${r.offset}  '
        '${r.rtt ?? '-'}  ${r.seekLead}  ${r.startLead}  ${r.nudge}  ${r.action}',
      );
    }
    return b.toString();
  }

  static String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
