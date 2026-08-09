import 'package:flutter/foundation.dart';

/// Short platform identifier ('android', 'ios', 'web', ...) for tagging
/// devices. Uses `kIsWeb` / [defaultTargetPlatform] rather than
/// `dart:io`'s `Platform`, so it compiles on web (where `dart:io` is
/// unavailable).
String currentPlatformName() => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// True on desktop OSes (Windows/macOS/Linux). Desktop builds don't have a
/// mobile-style permission system — OS permissions are either implicit
/// (file pickers, sockets) or handled by the plugin that needs them (e.g.
/// the mic recorder reports its own errors), so permission requests that
/// only exist on Android/iOS are skipped.
bool isDesktopPlatform() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Whether this platform can scan join QR codes. `mobile_scanner` only has
/// camera implementations for Android/iOS/macOS/web — Windows/Linux would
/// throw at runtime, so the scan button is hidden there.
bool supportsQrScanning() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);
