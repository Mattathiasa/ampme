// Sync E2E: a host page and two listener pages (one with its clock 3 s off,
// one joining mid-song). Measures each page's playhead against the shared
// machine clock and reports how far apart they are. Also pause/play, seek.
const {
  chromium, path, BASE, OUT, SONG, log, enableSemantics, semanticsText, waitForText,
  instrument, phase, samplePhases,
} = require('./common');

(async () => {
  const browser = await chromium.launch({
    args: [
      '--autoplay-policy=no-user-gesture-required',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      '--enable-unsafe-swiftshader',
    ],
  });
  const mk = async (skew) => {
    const ctx = await browser.newContext({ viewport: { width: 420, height: 1800 }, locale: 'en-US' });
    await ctx.addInitScript(instrument, skew);
    return ctx;
  };
  const hostCtx = await mk(0);
  await hostCtx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(BASE).origin });
  const host = await hostCtx.newPage();
  const l1 = await (await mk(3000)).newPage();   // clock 3 s fast
  const l2 = await (await mk(-1700)).newPage();  // clock 1.7 s slow, joins late
  globalThis.__pages = { host, l1, l2 };
  globalThis.__sync = {};
  const errors = [];
  for (const [name, p] of Object.entries(globalThis.__pages)) {
    p.on('pageerror', (e) => { errors.push(`${name}: ${e.message}`); console.log(name, 'PAGEERROR', (e.stack || e.message).slice(0, 700)); });
    p.on('console', (m) => {
      if (m.type() === 'error') errors.push(`${name}: ${m.text()}`);
      if (m.text().includes('[sync]')) (globalThis.__sync[name] ||= []).push(m.text());
    });
  }

  await host.goto(BASE);
  await enableSemantics(host);
  await host.getByRole('button', { name: 'Host a Session' }).click();
  await host.waitForTimeout(800);
  await host.getByRole('button', { name: 'Start Session' }).click();
  await waitForText(host, /Copy code/, 20000);
  await host.getByRole('button', { name: 'Copy code' }).click();
  await host.waitForTimeout(300);
  const code = (await host.evaluate(() => navigator.clipboard.readText())).trim();
  await host.mouse.move(5, 880);
  log('code', code);

  const [chooser] = await Promise.all([
    host.waitForEvent('filechooser'),
    host.getByRole('button', { name: /Choose a song/ }).click(),
  ]);
  await chooser.setFiles(SONG);
  await host.getByRole('button', { name: 'Play' }).waitFor({ timeout: 20000 });
  log('host: song loaded');

  const joinUrl = `${BASE}?join=${encodeURIComponent(code)}`;
  await l1.goto(joinUrl);
  await enableSemantics(l1);
  await waitForText(l1, /song\b|clicks/i, 30000);
  log('l1 joined:', (await semanticsText(l1)).slice(0, 200));
  await waitForText(host, /Ready/, 30000);
  log('host sees l1 Ready');
  const tap = l1.getByRole('button', { name: 'Tap to start audio' });
  if (await tap.count()) { await tap.first().click({ force: true }); log('l1 tapped start audio'); }

  await host.mouse.move(5, 880);
  await host.getByRole('button', { name: 'Play' }).first().click({ force: true });
  log('host: play');
  await host.waitForTimeout(3000);
  const a = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener']]);
  log('phases after start', a);

  // Late joiner.
  await l2.goto(joinUrl);
  await enableSemantics(l2);
  const tap2 = l2.getByRole('button', { name: 'Tap to start audio' });
  try { await tap2.first().waitFor({ timeout: 15000 }); await tap2.first().click({ force: true }); log('l2 tapped'); } catch (_) {}
  await host.waitForTimeout(6000);
  const b = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener'], ['l2', l2, 'listener']]);
  log('phases with late joiner', b);

  // Seek.
  log('host semantics', (await semanticsText(host)).slice(0, 500));
  await host.waitForTimeout(4000);
  const c = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener'], ['l2', l2, 'listener']]);
  log('phases later', c);
  for (const [n, pg] of [['host', host], ['l1', l1]]) {
    log('WAKELOCK', n, await pg.evaluate(() => 'wakeLock' in navigator), /keep it awake/.test(await semanticsText(pg)) ? 'banner shown' : 'no banner');
  }
  await host.evaluate(() => { window.__AUDIBLE = true; });
  const d = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener'], ['l2', l2, 'listener']]);
  log('phases (host audible clock)', d, await host.evaluate(() => window.__lat));
  for (let i = 0; i < 6; i++) {
    const t = await semanticsText(host);
    log('HOST-REPORTED', JSON.stringify(t.match(/(In sync|Catching up) \([-+]?\d+ ms\)/g)));
    await host.waitForTimeout(1000);
  }
  for (const [n, arr] of Object.entries(globalThis.__sync)) log('LISTENER', n, '\n  ' + arr.slice(-8).join('\n  '));
  if (process.env.SONG && /\.(webm|mp4)$/.test(process.env.SONG)) {
    const v = await samplePhases([['host', host, 'host'], ['video', host, 'video']]);
    log('host picture minus host sound (ms):', v.video == null || v.host == null ? null : Math.round(v.video - v.host));
    const got = await l1.evaluate(async () => {
      const el = [...window.__media].find((m) => m.src && m.src.startsWith('blob:'));
      if (!el) return null;
      const b = new Uint8Array(await (await fetch(el.src)).arrayBuffer());
      return { size: b.length, magic: String.fromCharCode(...b.slice(0, 4)) };
    });
    log('listener received:', JSON.stringify(got));
    globalThis.__received = got;
    await host.screenshot({ path: path.join(OUT, 'sync-host-video.png') });
  }
  await host.screenshot({ path: path.join(OUT, 'sync-host.png') });
  await l1.screenshot({ path: path.join(OUT, 'diag-l1.png'), fullPage: true });
  await l1.screenshot({ path: path.join(OUT, 'sync-l1.png') });

  // Pause -> every listener stops; play -> all resume together.
  await host.mouse.move(5, 880);
  await host.getByRole('button', { name: 'Pause' }).first().click({ force: true });
  await host.waitForTimeout(1500);
  const playing = async (p) => p.evaluate(() => [...window.__media].some((m) => !m.paused));
  const pausedOk = !(await playing(l1)) && !(await playing(l2));
  log('after pause, listeners paused:', pausedOk);
  await host.getByRole('button', { name: 'Play' }).first().click({ force: true });
  await host.waitForTimeout(4000);
  const e0 = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener'], ['l2', l2, 'listener']], 5);
  log('phases right after resume', e0);
  await host.waitForTimeout(3000);
  const e = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener'], ['l2', l2, 'listener']]);
  log('phases after resume', e);
  for (const [n, pg] of [['l1', l1], ['l2', l2]]) {
    log('MEDIA', n, JSON.stringify(await pg.evaluate(() => [...window.__media].map((m) => ({ src: (m.src || '').slice(0, 20), paused: m.paused, rs: m.readyState, t: Math.round(m.currentTime * 1000), rate: m.playbackRate, err: m.error && m.error.code })))));
    log('SEM', n, (await semanticsText(pg)).slice(0, 300));
    log('SYNC', n, (globalThis.__sync[n] || []).slice(-4).join(' | '));
  }

  const diffs = (r) => Object.fromEntries(Object.entries(r).filter(([k]) => k !== 'host').map(([k, v]) => [k, v == null || r.host == null ? null : Math.round(v - r.host)]));
  const result = { afterStart: diffs(a), lateJoin: diffs(b), later: diffs(c), audible: diffs(d), resumed: diffs(e) };
  log('listener minus host (ms):', JSON.stringify(result));
  // Host measured at its audible output; listeners at their <audio> clock.
  const au = result.audible;
  const videoOk = !(process.env.SONG && /\.(webm|mp4)$/.test(process.env.SONG)) ||
    (globalThis.__received && globalThis.__received.magic === 'OggS');
  const ok = videoOk && au.l1 != null && au.l2 != null && Math.abs(au.l1) <= 60 && Math.abs(au.l2) <= 60 && Math.abs(au.l1 - au.l2) <= 40 && pausedOk &&
    result.resumed.l1 != null && result.resumed.l2 != null && Math.abs(result.resumed.l1 - result.resumed.l2) <= 40;
  const relevant = errors.filter((e) => !/favicon|stun|ICE|Failed to load resource/i.test(e));
  if (relevant.length) log('errors', relevant.slice(0, 8));
  await browser.close();
  log(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
  process.exit(ok ? 0 : 1);
})().catch(async (e) => {
  console.error('E2E ERROR', e.message.split('\n')[0]);
  for (const [n, p] of Object.entries(globalThis.__pages || {})) {
    try {
      await p.screenshot({ path: path.join(OUT, `fail-${n}.png`) });
      console.error(n, 'semantics:', (await semanticsText(p)).slice(0, 600));
    } catch (_) {}
  }
  process.exit(2);
});
