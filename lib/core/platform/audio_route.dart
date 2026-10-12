import 'audio_route_stub.dart' if (dart.library.js_interop) 'audio_route_web.dart' as impl;

/// Where this device's sound comes out: the phone's speaker, wired
/// headphones, a Bluetooth speaker, or (in a browser) the system's default
/// output. Each has its own delay — Bluetooth alone adds 150–300 ms — so
/// sync timing is remembered per route.
class AudioRoute {
  const AudioRoute(this.key, this.label, {this.isBluetooth = false});

  /// Stable id for storage (e.g. `bt:JBL Flip 5`, `speaker`).
  final String key;

  /// For people (e.g. "JBL Flip 5").
  final String label;

  final bool isBluetooth;

  static const fallback = AudioRoute('default', 'This device');

  static AudioRoute fromMap(Map<Object?, Object?> map) => AudioRoute(
        map['key'] as String? ?? fallback.key,
        map['label'] as String? ?? fallback.label,
        isBluetooth: map['bluetooth'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) => other is AudioRoute && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'AudioRoute($key)';
}

/// The current output route, and changes to it (a Bluetooth speaker
/// connecting or dropping, headphones plugged in).
class AudioRoutes {
  AudioRoutes._();

  static Future<AudioRoute> current() => impl.currentAudioRoute();

  /// Fires when the route changes (not on every device-list change).
  static Stream<AudioRoute> get changes => impl.audioRouteChanges();
}
