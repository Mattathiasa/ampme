// Ampme service worker.
//
// 1. Makes the web app installable and usable offline: every same-origin
//    GET goes to the network first (so a new release shows up at once) and
//    falls back to the copy cached from the last visit.
// 2. Streams a song that is still arriving from the host, so a browser
//    listener starts on the first ~20 s instead of after the whole file:
//    the <audio> element asks for `ampme-stream/<trackId>`, and this worker
//    answers its range requests with bytes it asks the page for (the page
//    holds the song; this worker keeps nothing, since the browser may stop
//    it whenever it's idle).

const SHELL = 'ampme-shell-v1';
const STREAM_PATH = '/ampme-stream/';
const BLOCK = 256 * 1024;

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== SHELL) await caches.delete(key);
    }
    // Control open pages now: a listener on its first visit can stream.
    await self.clients.claim();
  })());
});

// ---- Talking to the page that holds the song ----

const pending = new Map(); // id -> { resolve, reject, timer }
let seq = 0;

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'ampme-reply') {
    const waiting = pending.get(data.id);
    if (waiting) {
      pending.delete(data.id);
      clearTimeout(waiting.timer);
      waiting.resolve(data);
    }
  }
  // 'ampme-ping' needs no answer: receiving it keeps this worker alive
  // while a song streams.
});

// Asks the page; resolves with its reply. Returns { promise, cancel }: the
// player closing a stream (a seek, a stop) cancels what it was waiting for.
function ask(client, message, timeoutMs) {
  const id = ++seq;
  let cancel = () => {};
  const promise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (pending.delete(id)) reject(new Error('no answer'));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    cancel = () => {
      const waiting = pending.get(id);
      if (!waiting) return;
      pending.delete(id);
      clearTimeout(waiting.timer);
      reject(new Error('cancelled'));
    };
    client.postMessage({ ...message, id });
  });
  return { promise, cancel };
}

async function findSong(event, trackId) {
  const candidates = [];
  if (event.clientId) {
    const own = await self.clients.get(event.clientId);
    if (own) candidates.push(own);
  }
  for (const c of await self.clients.matchAll({ type: 'window' })) {
    if (!candidates.includes(c)) candidates.push(c);
  }
  for (const client of candidates) {
    try {
      const meta = await ask(client, { type: 'ampme-meta', trackId }, 5000).promise;
      if (!meta.error) return { client, meta };
    } catch (_) {
      // That page doesn't answer; try the next.
    }
  }
  return null;
}

async function serveStream(event, trackId) {
  const found = await findSong(event, trackId);
  if (!found) return new Response('', { status: 404 });
  const { client, meta } = found;
  const total = meta.size;
  let start = 0;
  let end = total - 1;
  let status = 200;
  const range = event.request.headers.get('range');
  const m = range && /bytes=(\d*)-(\d*)/.exec(range);
  if (m) {
    if (m[1] === '') {
      start = Math.max(0, total - Number(m[2] || 0));
    } else {
      start = Number(m[1]);
      if (m[2] !== '') end = Math.min(Number(m[2]), total - 1);
    }
    if (start >= total || start > end) {
      return new Response('', { status: 416, headers: { 'Content-Range': `bytes */${total}` } });
    }
    status = 206;
  }
  let at = start;
  let inFlight = null;
  const body = new ReadableStream({
    async pull(controller) {
      if (at > end) {
        controller.close();
        return;
      }
      const to = Math.min(end + 1, at + BLOCK);
      try {
        // Waits (page side) for bytes that haven't arrived yet.
        inFlight = ask(client, { type: 'ampme-read', trackId, start: at, end: to }, 180000);
        const reply = await inFlight.promise;
        inFlight = null;
        const bytes = reply.bytes;
        if (reply.error || !bytes || bytes.byteLength === 0) {
          controller.error(new Error('song gone'));
          return;
        }
        controller.enqueue(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
        at += bytes.byteLength;
      } catch (e) {
        controller.error(e);
      }
    },
    cancel() {
      if (inFlight) inFlight.cancel();
    },
  }, { highWaterMark: 0 });
  const headers = {
    'Content-Type': meta.mime || 'application/octet-stream',
    'Content-Length': String(end - start + 1),
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
  };
  if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${total}`;
  return new Response(body, { status, headers });
}

// ---- Fetch routing ----

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  const i = url.pathname.indexOf(STREAM_PATH);
  if (i >= 0) {
    const trackId = decodeURIComponent(url.pathname.slice(i + STREAM_PATH.length).split('/')[0]);
    event.respondWith(serveStream(event, trackId));
    return;
  }
  if (request.headers.has('range')) return; // media: the browser handles it
  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response.ok && response.type === 'basic') {
        const copy = response.clone();
        event.waitUntil(caches.open(SHELL).then((cache) => cache.put(request, copy)));
      }
      return response;
    } catch (e) {
      const cached = await caches.match(request);
      if (cached) return cached;
      throw e;
    }
  })());
});
