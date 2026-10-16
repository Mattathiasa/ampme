import 'package:ampme/core/session/device_name_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a name is tidied: spaces collapsed, cut to length, blank means none', () {
    expect(DeviceNameStore.clean('  Kitchen   speaker '), 'Kitchen speaker');
    expect(DeviceNameStore.clean('   '), isNull);
    expect(DeviceNameStore.clean('x' * 100), hasLength(DeviceNameStore.maxLength));
  });

  test('a saved name comes back; saving a blank name goes back to automatic', () async {
    expect(await DeviceNameStore.load(), isNull);
    await DeviceNameStore.save('  Garage ');
    expect(await DeviceNameStore.load(), 'Garage');
    await DeviceNameStore.save('');
    expect(await DeviceNameStore.load(), isNull);
  });
}
