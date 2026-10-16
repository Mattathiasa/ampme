# ProGuard/R8 keep rules for Ampme's release builds.
# Plugins (just_audio/ExoPlayer, mobile_scanner, record, permission_handler)
# ship their own consumer rules and need no entries here.

# --- Sentry (sentry_flutter) ---
# Without the Sentry Gradle plugin, R8 needs explicit keeps so events can be
# serialized/reflected in release builds.
-keepattributes LineNumberTable,SourceFile
-keep class io.sentry.** { *; }
