import 'package:ampme/core/platform/audio_route.dart';
import 'package:ampme/core/session/sync_nudge_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const speaker = AudioRoute('speaker', 'Phone speaker');
const jbl = AudioRoute('bt:JBL Flip 5', 'JBL Flip 5', isBluetooth: true);

void main() {
  test('each output keeps its own timing and calibration', () async {
    SharedPreferences.setMockInitialValues({});
    await SyncNudgeStore.save(speaker, 20, calibrated: true);
    await SyncNudgeStore.save(jbl, 240, calibrated: true);
    expect(await SyncNudgeStore.load(speaker), (ms: 20, calibrated: true));
    expect(await SyncNudgeStore.load(jbl), (ms: 240, calibrated: true));

    // A nudge by ear keeps the route calibrated.
    await SyncNudgeStore.save(jbl, 250);
    expect(await SyncNudgeStore.load(jbl), (ms: 250, calibrated: true));

    // A speaker never seen: neutral, and calibration is suggested.
    const other = AudioRoute('bt:Car', 'Car');
    expect(await SyncNudgeStore.load(other), (ms: 0, calibrated: false));
  });

  test('the old single value moves to the first output seen', () async {
    SharedPreferences.setMockInitialValues({
      'ampme.syncNudgeMs': 180,
      'ampme.calibrated': true,
    });
    expect(await SyncNudgeStore.load(jbl), (ms: 180, calibrated: true));
    expect(await SyncNudgeStore.load(speaker), (ms: 0, calibrated: false));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ampme.syncNudgeMs'), isNull);
    expect(prefs.getBool('ampme.calibrated'), isNull);
  });

  test('saved values are clamped to the allowed range', () async {
    SharedPreferences.setMockInitialValues({
      'ampme.syncNudgeByRoute': '{"speaker":{"ms":9000,"calibrated":true}}',
    });
    expect((await SyncNudgeStore.load(speaker)).ms, maxSyncNudgeMs);
  });

  test('routes compare by key and read from the platform map', () {
    final route = AudioRoute.fromMap({'key': 'bt:JBL Flip 5', 'label': 'JBL', 'bluetooth': true});
    expect(route, jbl);
    expect(route.isBluetooth, isTrue);
    expect(AudioRoute.fromMap(const {}), AudioRoute.fallback);
  });
}
