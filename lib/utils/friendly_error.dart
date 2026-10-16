import 'dart:async';

import 'package:flutter/services.dart';

import '../core/network/file_transfer.dart' show FileTransferException;
import '../core/network/signaling/signaling_channel.dart' show SignalingException;

/// [error] as a sentence a person can act on: `'Couldn’t join the session.
/// ${friendlyError(e)}'`.
///
/// The technical detail is never shown here; it goes to the diagnostics and
/// crash reports (`reportError`), where it can be read.
String friendlyError(Object error) {
  if (error is FileTransferException) return error.message;
  if (error is SignalingException) return error.message;
  if (error is TimeoutException) {
    return 'It took too long. Check the connection and try again.';
  }
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return 'A permission is needed. Allow it in the device’s settings and try again.';
    }
  }
  if (error is FormatException) {
    return 'That file or code isn’t in a form Ampme understands.';
  }
  // dart:io isn't available in the browser build, so match by type name.
  final type = error.runtimeType.toString();
  if (type.contains('Socket') || type.contains('Http') || type.contains('WebSocket')) {
    return 'Can’t reach the other device. Make sure you’re on the same Wi-Fi and try again.';
  }
  if (type.contains('FileSystem') || type.contains('PathNotFound')) {
    return 'The file couldn’t be read. Pick it again.';
  }
  return 'Something went wrong. Try again; if it keeps happening, tap “Copy diagnostics”.';
}
