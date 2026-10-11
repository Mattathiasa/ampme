import 'package:ampme/features/join/join_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the calibration message shows every reading', () {
    expect(
      calibrationSummary(62, [58, 62, 65]),
      'Measured: this device sounded 62 ms late — corrected (readings: 58, 62, 65 ms).',
    );
    expect(
      calibrationSummary(-2, [-4, -2, 1]),
      'Measured: this device is in step with the host (readings: -4, -2, 1 ms).',
    );
  });

  test('readings that disagree are flagged', () {
    expect(calibrationSummary(40, [5, 40, 90]), contains('readings disagreed'));
  });
}
