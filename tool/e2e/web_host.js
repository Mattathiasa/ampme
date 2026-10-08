// Hosts an Ampme session from the web app in headless Chromium and keeps it
// playing, so another device — e.g. an Android emulator running the APK —
// can join it in an end-to-end test.
//
// Env:
//   BASE         web app URL (e.g. http://127.0.0.1:8080/web/)
//   TONE         audio or video file to play (make_tone.py / make_video.sh)
//   CODE_FILE    where to write the session code once the session is up
//   RESULT_FILE  where to write the JSON result when done
//   STOP_FILE    finish when this file appears (or after TIMEOUT_S)
//   OUT          directory for screenshots
//   TIMEOUT_S    overall limit (default 900)
//
// Passes (exit 0) when a listener joined, received the whole song over the
// file data channel (the host shows it "Ready"), and — once playing — its
// reported playhead stayed within 50 ms of the host's timeline (the host
// shows "In sync (N ms)"). The final state doesn't matter: the listener
// device may already be gone when the host is told to stop.
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
    const r = { states: [], channels: {} };
    for (const pc of window.__pcs || []) {
      r.states.push(pc.connectionState);
      const s = await pc.getStats();
      s.forEach((x) => {
        if (x.type === 'data-channel') {
          r.channels[x.label] = { state: x.state, bytesSent: x.bytesSent, bytesReceived: x.bytesReceived };
        }
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
  const ctx = await browser.newContext({ locale: 'en-US', viewport: { width: 420, height: 1800 } });
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
    log('listener joined; sending the song');
    await waitForText(page, /\bReady\b/, 180000);
    result.songDelivered = true;
    log('listener has the song', JSON.stringify(await stats(page)));
    await page.mouse.move(5, 880);
    await page.getByRole('button', { name: 'Play' }).first().click({ force: true });
    log('playing');

    result.drifts = [];
    let last = null;
    while (!fs.existsSync(STOP_FILE) && Date.now() - started < TIMEOUT_MS) {
      await page.waitForTimeout(2000);
      last = await stats(page);
      const text = await semantics(page);
      const m = text.match(/(In sync|Catching up) \(([-+]?\d+) ms\)/);
      if (m) result.drifts.push(Number(m[2]));
      log('stats', JSON.stringify(last), 'listener status', m ? m[0] : '(none)');
    }
    await page.screenshot({ path: path.join(OUT, 'web-host.png') });
    result.last = last;
    // Judge the settled readings (the first ones cover start-up).
    const settled = result.drifts.slice(2);
    result.pass = Boolean(
      result.songDelivered && settled.length >= 3 &&
      settled.slice(-3).every((d) => Math.abs(d) <= 50),
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
