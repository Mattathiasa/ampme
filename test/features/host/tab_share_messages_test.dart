import 'package:ampme/features/host/tab_share_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a window or screen gets told to pick a tab', () {
    expect(noTabSoundMessage('window'), contains('Chrome Tab'));
    expect(noTabSoundMessage('monitor'), contains('Chrome Tab'));
  });

  test('a tab without sound gets told to keep tab audio on', () {
    expect(noTabSoundMessage('browser'), contains('Also share tab audio'));
    expect(noTabSoundMessage(null), contains('Also share tab audio'));
  });
}
