import 'package:ampme/core/network/models/session_beacon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionBeacon', () {
    const beacon = SessionBeacon(
      sessionName: "Friday Party",
      hostDeviceId: 'host-abc',
      hostIp: '192.168.1.10',
      controlPort: 51234,
      streamPort: 51234,
      appVersion: '1.0.0',
    );

    test('round-trips through toJsonString/tryParse', () {
      final parsed = SessionBeacon.tryParse(beacon.toJsonString());

      expect(parsed, isNotNull);
      expect(parsed!.sessionName, beacon.sessionName);
      expect(parsed.hostDeviceId, beacon.hostDeviceId);
      expect(parsed.hostIp, beacon.hostIp);
      expect(parsed.controlPort, beacon.controlPort);
      expect(parsed.streamPort, beacon.streamPort);
      expect(parsed.appVersion, beacon.appVersion);
    });

    test('tryParse returns null for malformed JSON instead of throwing', () {
      expect(SessionBeacon.tryParse('not json at all'), isNull);
    });

    test('tryParse returns null for valid JSON missing required fields', () {
      expect(SessionBeacon.tryParse('{"sessionName":"x"}'), isNull);
    });

    test('tryParse returns null for a JSON array (not an object)', () {
      expect(SessionBeacon.tryParse('[1,2,3]'), isNull);
    });

    test('tryParse returns null for a foreign/unrelated JSON packet on the wire', () {
      expect(SessionBeacon.tryParse('{"unrelated":"packet","from":"another app"}'), isNull);
    });
  });
}
