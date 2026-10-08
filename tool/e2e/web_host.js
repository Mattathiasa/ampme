// Hosts an Ampme session from the web app in headless Chromium and keeps it
// streaming, so another device — e.g. an Android emulator running the APK —
// can join it in an end-to-end test.
//
// Env:
//   BASE         web app URL (e.g. http://127.0.0.1:8080/web/)
//   TONE         audio file to stream (see make_tone.py)
//   CODE_FILE    where to write the session code once the session is up
//   RESULT_FILE  where to write the JSON result when done
//   STOP_FILE    finish when this file appears (or after TIMEOUT_S)
//   OUT          directory for screenshots
//   TIMEOUT_S    overall limit (default 900)
//
// Passes (exit 0) when a listener joined and, while the peer connection was
// `connected`, audio bytes flowed and the listener sent RTCP receiver reports
// (proof it is actually receiving). The final state doesn't matter: the
// listener device may already be gone when the host is told to stop. The
// listener must also have reported its measured playout latency (the host's
// sync card shows "trail by ~N ms"), which drives the host's speaker delay.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const env = (k, d) => process.env[k] || d;
const BASE = env('BASE', 'http://127.0.0.1:8080/web/');
const TONE = env('TONE', '/tmp/tone.wav');
const CODE_FILE = env('CODE_FILE', '/tmp/ampme-code.txt');
const RESULT_FILE = env('RESULT_FILE', '/tmp/host-result.json');
const STOP_FILE = env('STOP_FILE', '/tmp/host-stop');
const OUT = env('OUT', '.');
const TIMEOUT_MS = Number(env('TIMEOUT_S', '900')) * 1000;
const started = Date.now();

const log = (...a) => console.log(`[host +${((Date.now() - started) / 1000).toFixed(1)}s]`, ...a);

async function semantics(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics-host *')]
      .map((e) => e.getAttribute('aria-label') || (e.childElementCount ? '' : e.textContent))
      .filter(Boolean)
      .join(' | '));
}

async function waitForText(page, re, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (re.test(await semantics(page))) return;
    await page.waitForTimeout(500);
  }
  throw new Error(`Timed out waiting for ${re}`);
}

async function stats(page) {
  return page.evaluate(async () => {
    const r = { states: [], bytesSent: 0, remoteInbound: null, fmtp: [] };
    for (const pc of window.__pcs || []) {
      r.states.push(pc.connectionState);
      const s = await pc.getStats();
      s.forEach((x) => {
        if (x.type === 'outbound-rtp' && x.kind === 'audio') r.bytesSent += x.bytesSent;
        if (x.type === 'remote-inbound-rtp' && x.kind === 'audio') {
          r.remoteInbound = { packetsLost: x.packetsLost, jitter: x.jitter, roundTripTime: x.roundTripTime };
        }
        if (x.type === 'codec' && /opus/i.test(x.mimeType)) r.fmtp.push(x.sdpFmtpLine);
      });
    }
    return r;
  });
}

(async () => {
  const browser = await chromium.launch({
    args: [
      '--autoplay-policy=no-user-gesture-required',
      // Chrome normally hides LAN addresses behind mDNS (.local) names. A
      // phone on the same WiFi still connects (its own raw candidates are
      // enough), but an emulator behind QEMU's NAT can't — expose the raw
      // host address for the test.
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      '--enable-unsafe-swiftshader',
    ],
  });
  const ctx = await browser.newContext({ locale: 'en-US', viewport: { width: 420, height: 900 } });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(BASE).origin });
  await ctx.addInitScript(() => {
    window.__pcs = [];
    const Orig = window.RTCPeerConnection;
    const Patched = function (...args) { const pc = new Orig(...args); window.__pcs.push(pc); return pc; };
    Patched.prototype = Orig.prototype;
    Object.setPrototypeOf(Patched, Orig);
    window.RTCPeerConnection = Patched;
  });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => log('PAGEERROR', e.message));
  page.on('console', (m) => { if (m.type() === 'error') log('console error:', m.text().slice(0, 300)); });

  const result = { pass: false };
  try {
    log('open', BASE);
    await page.goto(BASE);
    await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
    await waitForText(page, /Host a Session/, 30000);
    await page.getByRole('button', { name: 'Host a Session' }).click();
    await waitForText(page, /Start Session/, 15000);
    await page.getByRole('button', { name: 'Start Session' }).click();
    await waitForText(page, /Invite listeners|Couldn.t start/, 30000);
    const text = await semantics(page);
    if (!/Invite listeners/.test(text)) throw new Error('Session did not start: ' + text);

    await page.getByRole('button', { name: 'Copy code' }).click();
    await page.waitForTimeout(300);
    const code = (await page.evaluate(() => navigator.clipboard.readText())).trim();
    if (!/^AMP-[A-Z0-9]{6}$/.test(code)) throw new Error('Unexpected code: ' + code);
    result.code = code;
    log('session code', code);

    const [chooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      page.getByRole('button', { name: /Choose a song/ }).click(),
    ]);
    await chooser.setFiles(TONE);
    await waitForText(page, /\| Play/, 30000);
    fs.writeFileSync(CODE_FILE, code + '\n');
    log('track loaded; waiting for a listener');

    await waitForText(page, /Listener-/, TIMEOUT_MS - (Date.now() - started));
    result.listenerSeen = true;
    log('listener joined');
    await page.mouse.move(5, 880);
    await page.getByRole('button', { name: 'Play' }).first().click({ force: true });
    log('playing');

    let first = null;
    let last = null;
    let receiving = null; // latest sample: connected + receiver reports
    while (!fs.existsSync(STOP_FILE) && Date.now() - started < TIMEOUT_MS) {
      await page.waitForTimeout(2000);
      last = await stats(page);
      if (!first && last.bytesSent > 0) first = last;
      if (last.states.includes('connected') && last.remoteInbound) receiving = last;
      const reported = (await semantics(page)).match(/trail by ~(\d+) ms/);
      if (reported) result.reportedLatencyMs = Number(reported[1]);
      log('stats', JSON.stringify(last), 'reportedLatencyMs', result.reportedLatencyMs);
    }
    await page.screenshot({ path: path.join(OUT, 'web-host.png') });
    result.first = first;
    result.receiving = receiving;
    result.last = last;
    result.pass = Boolean(
      first && receiving && receiving.bytesSent - first.bytesSent > 20000 &&
      result.reportedLatencyMs != null,
    );
  } catch (e) {
    result.error = e.message;
    log('ERROR', e.message);
    await page.screenshot({ path: path.join(OUT, 'web-host-error.png') }).catch(() => {});
  }
  fs.writeFileSync(RESULT_FILE, JSON.stringify(result, null, 2));
  log(result.pass ? 'PASS' : 'FAIL', JSON.stringify(result));
  await browser.close();
  process.exit(result.pass ? 0 : 1);
})();
