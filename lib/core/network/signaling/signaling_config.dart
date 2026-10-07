/// Supabase project used as the cloud signaling backend for browser-hosted
/// sessions (`ampme-signaling`). Only Realtime *broadcast* is used — no
/// tables, no auth — so the publishable anon key is all a client needs, and
/// it is safe to ship in the app (that's what anon keys are for).
///
/// Override at build time to point at a different project:
///
/// ```sh
/// flutter run -d chrome \
///   --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=<anon key>
/// ```
///
/// Setting `SUPABASE_URL` to an empty string disables cloud signaling (LAN
/// relay only).
class SignalingConfig {
  const SignalingConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ulhsowyzpqlrpyhegimt.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVsaHNvd3l6cHFscnB5aGVnaW10Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEzOTE1MjAsImV4cCI6MjEwNjk2NzUyMH0.RiSA1Q-fj4usRhyAYxzHdSpgjrLLg7GY3WF34MUez0M',
  );

  /// Whether cloud signaling is configured for this build.
  static bool get cloudEnabled =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// The Realtime WebSocket endpoint (without the `/websocket` suffix, which
  /// the realtime client appends). `https` → `wss`, `http` → `ws` (the
  /// latter only for local test servers).
  static String get realtimeEndpoint {
    final base = supabaseUrl.endsWith('/')
        ? supabaseUrl.substring(0, supabaseUrl.length - 1)
        : supabaseUrl;
    return '${base.replaceFirst(RegExp('^http'), 'ws')}/realtime/v1';
  }
}
