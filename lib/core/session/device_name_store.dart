import 'package:shared_preferences/shared_preferences.dart';

import '../observability/reporting.dart';

/// The name this device shows to a host ("Kitchen speaker"), kept between
/// launches. Without one, a device is `Listener-xxxx`.
class DeviceNameStore {
  static const _key = 'deviceName';

  /// Longest name kept; a host's list is not the place for a paragraph.
  static const maxLength = 24;

  /// [raw] tidied up for use as a name: whitespace collapsed, cut to
  /// [maxLength]. Null when nothing usable is left.
  static String? clean(String raw) {
    final name = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return null;
    return name.length <= maxLength ? name : name.substring(0, maxLength).trimRight();
  }

  /// The saved name, or null if none was set.
  static Future<String?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      return saved == null ? null : clean(saved);
    } catch (e, st) {
      reportError(e, st, context: 'DeviceNameStore.load');
      return null;
    }
  }

  /// Saves [name]; null or blank goes back to the automatic name.
  static Future<void> save(String? name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cleaned = name == null ? null : clean(name);
      if (cleaned == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, cleaned);
      }
    } catch (e, st) {
      reportError(e, st, context: 'DeviceNameStore.save');
    }
  }
}
