import 'package:sentry_flutter/sentry_flutter.dart';

import 'scrub.dart';

/// [event] with session codes and IP addresses removed from everything that
/// can carry them: the error text, the message, breadcrumbs, and (in a
/// browser) the page address, which holds the join code of a link people
/// opened. Edits the event in place and returns it.
SentryEvent scrubEvent(SentryEvent event) {
  String? clean(String? s) => s == null ? null : scrubSensitive(s);

  for (final e in event.exceptions ?? const <SentryException>[]) {
    e.value = clean(e.value);
  }
  final message = event.message;
  if (message != null) {
    message.formatted = scrubSensitive(message.formatted);
    message.template = clean(message.template);
    message.params = message.params?.map((p) => p is String ? scrubSensitive(p) : p).toList();
  }
  for (final crumb in event.breadcrumbs ?? const <Breadcrumb>[]) {
    scrubBreadcrumb(crumb);
  }
  final request = event.request;
  if (request != null) {
    request.url = clean(request.url);
    request.queryString = clean(request.queryString);
    request.fragment = clean(request.fragment);
    request.headers = {
      for (final h in request.headers.entries) h.key: scrubSensitive(h.value),
    };
  }
  return event;
}

/// [crumb] scrubbed in place.
Breadcrumb scrubBreadcrumb(Breadcrumb crumb) {
  crumb.message = crumb.message == null ? null : scrubSensitive(crumb.message!);
  final data = crumb.data;
  if (data != null) {
    crumb.data = data.map((k, v) => MapEntry(k, v is String ? scrubSensitive(v) : v));
  }
  return crumb;
}
