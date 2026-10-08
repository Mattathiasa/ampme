import 'user_activation_stub.dart'
    if (dart.library.js_interop) 'user_activation_web.dart' as impl;

/// Whether the page has had a user gesture, which browsers require before
/// audio may start on its own. Always true outside the browser.
bool get pageHasUserActivation => impl.pageHasUserActivation;
