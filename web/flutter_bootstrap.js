{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: Flutter's own (deprecated) worker would replace
// Ampme's sw.js, registered from index.html, and then unregister itself.
_flutter.loader.load();
