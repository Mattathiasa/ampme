import 'dart:async';
import 'dart:io';

import 'package:ampme/core/network/file_transfer.dart' show FileTransferException;
import 'package:ampme/core/network/signaling/signaling_channel.dart' show SignalingException;
import 'package:ampme/utils/friendly_error.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('errors with a message of their own keep it', () {
    expect(friendlyError(const FileTransferException('The song stopped arriving')), 'The song stopped arriving');
    expect(friendlyError(const SignalingException('Session not found.')), 'Session not found.');
  });

  test('network, timeout, permission and format problems become plain advice', () {
    expect(friendlyError(const SocketException('Connection refused')), contains('same Wi-Fi'));
    expect(friendlyError(TimeoutException('slow')), contains('too long'));
    expect(friendlyError(PlatformException(code: 'permission_denied')), contains('permission'));
    expect(friendlyError(const FormatException('bad')), contains('isn’t in a form'));
    expect(friendlyError(const FileSystemException('gone')), contains('couldn’t be read'));
  });

  test('anything else never leaks the technical text', () {
    final message = friendlyError(StateError('LateInitializationError: _sink at 0x7f'));
    expect(message, isNot(contains('Late')));
    expect(message, contains('Copy diagnostics'));
  });
}
