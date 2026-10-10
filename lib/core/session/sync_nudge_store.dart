import 'package:shared_preferences/shared_preferences.dart';

import '../observability/reporting.dart';

/// Earliest/latest a listener can be nudged (ms). Positive plays this device
/// earlier — for a speaker that sounds behind the room (Bluetooth adds
/// 150–300 ms).
const int minSyncNudgeMs = -300;
const int maxSyncNudgeMs = 500;

/// Remembers this device's sync nudge across sessions: it's a property of the
/// device's speaker path, not of a session.
class SyncNudgeStore {
  static const _key = 'ampme.syncNudgeMs';

  static Future<int> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_key) ?? 0).clamp(minSyncNudgeMs, maxSyncNudgeMs);
    } catch (e, st) {
      reportError(e, st, context: 'SyncNudgeStore.load');
      return 0;
    }
  }

  static Future<void> save(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, ms);
    } catch (e, st) {
      reportError(e, st, context: 'SyncNudgeStore.save');
    }
  }
}
