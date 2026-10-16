// Progressive-start E2E: a listener must start playing a song while it is
// still arriving (MODE=fresh joins first and the host plays as soon as the
// listener has enough; MODE=late joins mid-song), stay in sync, and not cut
// when the transfer ends. EXPECT_STREAM=0 for formats that must NOT stream.
const {
  chromium, path, BASE, OUT, SONG, log, enableSemantics, semanticsText, waitForText,
  instrument, phase, samplePhases,
} = require('./common');

(async () => {
  const browser = await chromium.launch({
    args: ['--autoplay-policy=no-user-gesture-required', '--disable-features=WebRtcHideLocalIpsWithMdns'],
  });
  const mk = async (skew) => {
    const ctx = await browser.newContext({ viewport: { width: 420, height: 1800 }, locale: 'en-US' });
    await ctx.addInitScript(instrument, skew);
    return ctx;
  };
  const hostCtx = await mk(0);
  await hostCtx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(BASE).origin });
  const host = await hostCtx.newPage();
  const l1 = await (await mk(2000)).newPage();
  globalThis.__pages = { host, l1 };
  globalThis.__sync = {};
  for (const [name, p] of Object.entries(globalThis.__pages)) {
    p.on('pageerror', (e) => console.log(name, 'PAGEERROR', (e.stack || e.message).slice(0, 700)));
    p.on('console', (m) => { if (m.text().includes('[sync]')) (globalThis.__sync[name] ||= []).push(m.text()); });
  }
  // Slow transfers so the listener can be watched starting mid-transfer.
  await host.goto(`${BASE}?testChunkDelayMs=${process.env.CHUNK_DELAY_MS || 15}`);
  await enableSemantics(host);
  await host.getByRole('button', { name: 'Host a Session' }).click();
  await host.waitForTimeout(800);
  await host.getByRole('button', { name: 'Start Session' }).click();
  await waitForText(host, /Copy code/, 20000);
  await host.getByRole('button', { name: 'Copy code' }).click();
  await host.waitForTimeout(300);
  const code = (await host.evaluate(() => navigator.clipboard.readText())).trim();
  log('code', code);
  const MODE = process.env.MODE || 'late';
  const join = async () => {
    await l1.goto(`${BASE}?join=${encodeURIComponent(code)}`);
    log('listener SW controller:', await l1.evaluate(async () => {
      for (let i = 0; i < 50 && !navigator.serviceWorker.controller; i++) await new Promise((r) => setTimeout(r, 100));
      return !!navigator.serviceWorker.controller;
    }));
    await enableSemantics(l1);
  };
  if (MODE === 'fresh') {
    await join();
    await waitForText(host, /Ready|Connecting/, 30000);
    await host.waitForTimeout(1500);
  }
  const [chooser] = await Promise.all([
    host.waitForEvent('filechooser'),
    host.getByRole('button', { name: /Choose a song/ }).click(),
  ]);
  await chooser.setFiles(SONG);
  await host.getByRole('button', { name: 'Play' }).waitFor({ timeout: 60000 });
  await host.mouse.move(5, 880);
  if (MODE === 'fresh') {
    // Play as soon as the listener can start (host shows its song share).
    for (let i = 0; i < 200; i++) {
      if (/Getting the song… ([1-9]\d*)%/.test(await semanticsText(host))) break;
      await host.waitForTimeout(100);
    }
  }
  await host.getByRole('button', { name: 'Play' }).first().click({ force: true });
  log('host playing; mode', MODE);
  if (MODE === 'late') {
    await host.waitForTimeout(3000);
    await join();
  }
  // Watch: did the <audio> play while the song was still arriving?
  const t0 = Date.now();
  let playedWhileReceiving = null, firstPlayMs = null, receivedMs = null, lastPct = null;
  while (Date.now() - t0 < 60000) {
    const sem = await semanticsText(l1);
    const m = sem.match(/(\d+)%/);
    const hostSem = await semanticsText(host);
    const receiving = /Getting the song/i.test(sem) || /· song \d+%/.test(hostSem);
    const playing = await l1.evaluate(() => [...window.__media].some((x) => !x.paused && x.readyState >= 2));
    if (playing && firstPlayMs == null) { firstPlayMs = Date.now() - t0; playedWhileReceiving = receiving; lastPct = m && m[1]; }
    if (!receiving && receivedMs == null && firstPlayMs != null) receivedMs = Date.now() - t0;
    if (firstPlayMs != null && receivedMs != null) break;
    await l1.waitForTimeout(50);
  }
  log('listener first played after', firstPlayMs, 'ms; still receiving then:', playedWhileReceiving, '(' + lastPct + '%)', '| transfer done after', receivedMs, 'ms');
  const src = await l1.evaluate(() => [...window.__media].map((m) => m.src));
  log('listener src:', JSON.stringify(src));
  await l1.evaluate(() => {
    window.__cuts = [];
    for (const m of window.__media) for (const t of ['pause', 'emptied', 'loadstart']) m.addEventListener(t, () => window.__cuts.push(t));
  });
  await host.waitForTimeout(8000);
  await host.evaluate(() => { window.__AUDIBLE = true; });
  const ph = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener']]);
  const d = ph.l1 == null || ph.host == null ? null : Math.round(ph.l1 - ph.host);
  const cuts = await l1.evaluate(() => window.__cuts);
  log('listener minus host (ms):', d, '| cuts after start:', JSON.stringify(cuts));
  log('host UI:', (await semanticsText(host)).match(/(In sync|Catching up|Getting the song)[^|]*/g));
  log('LISTENER', '\n  ' + (globalThis.__sync.l1 || []).slice(0, 40).join('\n  '));
  const expectStream = process.env.EXPECT_STREAM !== '0';
  const ok = (expectStream ? playedWhileReceiving === true && src.some((s) => s.includes('ampme-stream')) : true) && d != null && Math.abs(d) <= 60 && cuts.length === 0;
  await browser.close();
  log(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
  process.exit(ok ? 0 : 1);
})().catch(async (e) => {
  console.error('E2E ERROR', e.message.split('\n')[0]);
  for (const [n, p] of Object.entries(globalThis.__pages || {})) {
    try { await p.screenshot({ path: path.join(OUT, `fail-${n}.png`) }); console.error(n, 'semantics:', (await semanticsText(p)).slice(0, 600)); } catch (_) {}
  }
  process.exit(2);
});
