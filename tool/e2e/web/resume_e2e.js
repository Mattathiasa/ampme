// Resume E2E: the host page is reloaded twice mid-song and resumes; the
// listener must keep playing without a cut and stay in sync.
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
  const l1 = await (await mk(3000)).newPage();
  globalThis.__pages = { host, l1 };
  globalThis.__sync = {};
  for (const [name, p] of Object.entries(globalThis.__pages)) {
    p.on('pageerror', (e) => console.log(name, 'PAGEERROR', (e.stack || e.message).slice(0, 700)));
    p.on('console', (m) => { if (m.text().includes('[sync]')) (globalThis.__sync[name] ||= []).push(m.text()); });
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
  log('code', code);
  const [chooser] = await Promise.all([
    host.waitForEvent('filechooser'),
    host.getByRole('button', { name: /Choose a song/ }).click(),
  ]);
  await chooser.setFiles(SONG);
  await host.getByRole('button', { name: 'Play' }).waitFor({ timeout: 20000 });
  await l1.goto(`${BASE}?join=${encodeURIComponent(code)}`);
  await enableSemantics(l1);
  await waitForText(host, /Ready/, 30000);
  const tap = l1.getByRole('button', { name: 'Tap to start audio' });
  if (await tap.count()) await tap.first().click({ force: true });
  await host.mouse.move(5, 880);
  await host.getByRole('button', { name: 'Play' }).first().click({ force: true });
  await host.waitForTimeout(4000);
  await host.evaluate(() => { window.__AUDIBLE = true; });
  const before = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener']]);
  log('before reload', before);
  // Watch the listener's element for any interruption from here on.
  await l1.evaluate(() => {
    window.__cuts = [];
    for (const m of window.__media) {
      for (const t of ['pause', 'emptied', 'loadstart', 'seeking']) m.addEventListener(t, () => window.__cuts.push(t + '@' + Math.round(m.currentTime * 1000)));
    }
    window.__srcs = [...window.__media].map((m) => m.src.slice(0, 40));
    window.__pauses = [];
    const op = HTMLMediaElement.prototype.pause;
    HTMLMediaElement.prototype.pause = function () { if (!this.paused) window.__pauses.push(new Error().stack.split('\n').slice(1, 9).join(' <- ')); return op.call(this); };
  });

  let after, l1Away = true;
  for (let round = 1; round <= 2; round++) {
  log('host: RELOAD');
  await host.reload();
  await enableSemantics(host);
  await host.getByRole('button', { name: 'Host a Session' }).click().catch(() => {});
  
  await waitForText(host, /Resume session/, 20000);
  log('host offers resume:', (await semanticsText(host)).match(/PICK UP[^|]*\|[^|]*\|[^|]*/)?.[0]);
  await host.waitForTimeout(3000);
  l1Away = l1Away &&  await l1.evaluate(() => [...window.__media].some((m) => !m.paused));
  log('listener still playing while host away:', l1Away, '| listener UI:', (await semanticsText(l1)).slice(0, 160));
  log('MEDIA before resume', JSON.stringify(await l1.evaluate(() => [...window.__media].map((m) => ({ tag: m.tagName, conn: m.isConnected, src: (m.src || '').slice(0, 30), paused: m.paused, rs: m.readyState, t: Math.round(m.currentTime * 1000), rate: m.playbackRate })))));
  const t0 = Date.now();
  await host.getByRole('button', { name: 'Resume session' }).click({ force: true });
  await waitForText(host, /Ready/, 30000);
  log('host sees l1 Ready again after', Date.now() - t0, 'ms');
  await host.waitForTimeout(6000);
  await host.evaluate(() => { window.__AUDIBLE = true; });
  after = await samplePhases([['host', host, 'host'], ['l1', l1, 'listener']]);
  log('after resume', after);
  }
  const cuts = await l1.evaluate(() => window.__cuts);
  const srcSame = await l1.evaluate(() => JSON.stringify([...window.__media].map((m) => m.src.slice(0, 40))) === JSON.stringify(window.__srcs));
  log('PAUSE STACKS', JSON.stringify(await l1.evaluate(() => window.__pauses), null, 1));
  log('listener interruptions:', JSON.stringify(cuts), 'same src:', srcSame);
  log('host UI:', (await semanticsText(host)).slice(0, 300));
  log('LISTENER', '\n  ' + (globalThis.__sync.l1 || []).slice(-14).join('\n  '));
  const d = after.l1 == null || after.host == null ? null : Math.round(after.l1 - after.host);
  log('listener minus host after resume (ms):', d);
  const ok = l1Away && d != null && Math.abs(d) <= 60 && srcSame && !cuts.some((c) => /pause|emptied|loadstart/.test(c));
  await host.screenshot({ path: path.join(OUT, 'resume-host.png') });
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
