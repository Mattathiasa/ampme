import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../observability/reporting.dart';
import '../platform/audio_route.dart';

/// Earliest/latest a listener can be nudged (ms). Positive plays this device
/// earlier — for a speaker that sounds behind the room (Bluetooth adds
/// 150–300 ms).
const int minSyncNudgeMs = -300;
const int maxSyncNudgeMs = 500;

/// This device's saved timing for one output route.
typedef RouteNudge = ({int ms, bool calibrated});

/// Remembers this device's sync nudge across sessions, per output route:
/// it's a property of the speaker path (Bluetooth adds 150–300 ms), not of a
/// session — so a Bluetooth speaker and the phone's own speaker each keep
/// their own.
class SyncNudgeStore {
  static const _routesKey = 'ampme.syncNudgeByRoute';
  // Before 1.8 there was one value for the whole device.
  static const _legacyKey = 'ampme.syncNudgeMs';
  static const _legacyCalibratedKey = 'ampme.calibrated';

  static Future<Map<String, dynamic>> _routes(SharedPreferences prefs, String routeKey) async {
    final raw = prefs.getString(_routesKey);
    if (raw != null) {
      try {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        return {};
      }
    }
    // First run with routes: the old single value was set on whatever this
    // device is playing through now (most likely).
    final routes = <String, dynamic>{};
    final legacyMs = prefs.getInt(_legacyKey);
    final legacyCalibrated = prefs.getBool(_legacyCalibratedKey) ?? false;
    if (legacyMs != null || legacyCalibrated) {
      routes[routeKey] = {'ms': legacyMs ?? 0, 'calibrated': legacyCalibrated};
    }
    await prefs.setString(_routesKey, jsonEncode(routes));
    await prefs.remove(_legacyKey);
    await prefs.remove(_legacyCalibratedKey);
    return routes;
  }

  /// The timing saved for [route]; 0 and not calibrated if it's new.
  static Future<RouteNudge> load(AudioRoute route) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entry = (await _routes(prefs, route.key))[route.key];
      if (entry is! Map) return (ms: 0, calibrated: false);
      return (
        ms: ((entry['ms'] as num?)?.toInt() ?? 0).clamp(minSyncNudgeMs, maxSyncNudgeMs),
        calibrated: entry['calibrated'] == true,
      );
    } catch (e, st) {
      reportError(e, st, context: 'SyncNudgeStore.load');
      return (ms: 0, calibrated: false);
    }
  }

  /// Saves [ms] for [route]; [calibrated] marks it measured with the mic
  /// (then the app stops suggesting calibration on this route).
  static Future<void> save(AudioRoute route, int ms, {bool calibrated = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final routes = await _routes(prefs, route.key);
      final previous = routes[route.key];
      routes[route.key] = {
        'ms': ms,
        'calibrated': calibrated || (previous is Map && previous['calibrated'] == true),
        'label': route.label,
      };
      await prefs.setString(_routesKey, jsonEncode(routes));
    } catch (e, st) {
      reportError(e, st, context: 'SyncNudgeStore.save');
    }
  }
}

/// Most a start is called early (ms).
const int maxStartLeadMs = 250;

/// Remembers how long this device's player takes to actually start sounding
/// after play (see `ListenerSessionController.startLeadMs`). It's a property
/// of the device and its player, so one value per device.
class StartLeadStore {
  static const _key = 'ampme.startLeadMs';

  static Future<int> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_key) ?? 0).clamp(0, maxStartLeadMs);
    } catch (_) {
      return 0;
    }
  }

  static Future<void> save(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, ms);
    } catch (_) {
      // Not remembered; it's learned again next session.
    }
  }
}
