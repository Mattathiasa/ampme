import 'package:flutter/foundation.dart';

/// Short platform identifier ('android', 'ios', 'web', ...) for tagging
/// devices. Uses `kIsWeb` / [defaultTargetPlatform] rather than
/// `dart:io`'s `Platform`, so it compiles on web (where `dart:io` is
/// unavailable).
String currentPlatformName() => kIsWeb ? 'web' : defaultTargetPlatform.name;
