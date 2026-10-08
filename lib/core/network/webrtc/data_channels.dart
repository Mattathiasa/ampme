/// Labels of the WebRTC data channels a web host opens to each listener.
library;

/// Sync protocol ([ControlMessage] JSON text frames), both directions.
const String controlChannelLabel = 'ampme-control';

/// Song bytes, host -> listener (see `file_transfer.dart`).
const String fileChannelLabel = 'ampme-file';
