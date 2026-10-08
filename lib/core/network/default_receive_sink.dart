import 'receive_sink.dart';
import 'default_receive_sink_native.dart'
    if (dart.library.js_interop) 'default_receive_sink_web.dart' as impl;

/// Disk on native (big videos), memory in the browser.
ReceiveSinkFactory get defaultReceiveSinkFactory => impl.defaultReceiveSinkFactory;
