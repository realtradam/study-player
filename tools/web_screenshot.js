#!/usr/bin/env node
/* tools/web_screenshot.js — capture a frame of the web game via headless Chromium.
 *
 * Used by bin/screenshot --target=web as the headless-browser capture path (no
 * system chrome needed: puppeteer downloads a Chromium into the project cache).
 *
 * Usage:
 *   node tools/web_screenshot.js <url> <out.png> [waitMs] [width] [height]
 *
 * Loads <url> in headless Chromium at <width>x<height>, waits <waitMs> (default
 * 2500ms) for the wasm boot + WebGL + a couple of shader frames, then captures a
 * full-page PNG to <out.png>. Prints the output path on success, exits non-zero
 * on failure.
 *
 * The page needs a moment: emscripten boots mruby -> game/fx_demo.rb runs the FX
 * pipeline (SMAA/FXAA/CRT shaders) -> at least one frame composites. 2.5s is a
 * safe floor; raise via the 3rd arg for heavier scenes.
 *
 * Chromium in headless mode needs --no-sandbox under many CI/root contexts, and
 * --use-gl=swiftshader / --enable-unsafe-swiftshader so WebGL renders without a
 * GPU (WSL/headless). Without software GL the canvas stays blank (no GPU).
 */
'use strict';

const url   = process.argv[2];
const out   = process.argv[3];
const wait  = parseInt(process.argv[4] || '2500', 10);
const width  = parseInt(process.argv[5] || '1280', 10);
const height = parseInt(process.argv[6] || '720', 10);

if (!url || !out) {
  console.error('usage: node tools/web_screenshot.js <url> <out.png> [waitMs] [w] [h]');
  process.exit(2);
}

(async () => {
  let browser;
  try {
    const puppeteer = require('puppeteer');
    browser = await puppeteer.launch({
      headless: 'new',
      args: [
        `--window-size=${width},${height}`,
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--use-gl=angle',
        '--use-angle=swiftshader',
        '--enable-unsafe-swiftshader',
        '--ignore-gpu-blocklist',
        '--disable-gpu-sandbox',
      ],
    });
    const page = await browser.newPage();
    await page.setViewport({ width, height, deviceScaleFactor: 1 });
    // Capture console + pageerrors for diagnostics (routed to stderr only).
    // Diagnostics -> stderr. The relay's agent-bridge.js polls /jamstack/console
    // and /jamstack/status every frame; those requests get ERR_ABORTED when the
    // page tears down at screenshot time and are NOT errors -> filtered out.
    // favicon.ico 404 is also expected (the relay serves none) -> filtered.
    const noise = (u) =>
      /\/jamstack\/(console|status|poll)/.test(u) || /favicon\.ico/.test(u);
    page.on('pageerror', e => console.error('[pageerror]', e.message));
    page.on('response', r => { if (r.status() >= 400 && !noise(r.url())) console.error('[http]', r.status(), r.url()); });
    page.on('requestfailed', r => { if (!noise(r.url())) console.error('[reqfail]', r.url(), r.failure()?.errorText); });

    // CRITICAL: disable the browser HTTP cache. Puppeteer/headless Chromium will
    // otherwise serve a STALE game.wasm/game.js/game.data across rebuilds, which
    // makes two captures of DIFFERENT builds come out byte-identical (looks like a
    // code change had no effect — a dangerous false negative when A/B-testing
    // shader edits). The relay already sends Cache-Control: no-store, but
    // puppeteer may still cache — disable explicitly + cache-bust the entry URL.
    await page.setCacheEnabled(false);
    const bust = url.includes('?') ? `&cb=${Date.now()}` : `?cb=${Date.now()}`;
    // NOTE: waitUntil 'load' (not 'networkidle0') — the relay's /jamstack/poll
    // long-poll keeps a connection alive, so networkidle never settles.
    await page.goto(url + bust, { waitUntil: 'load', timeout: 30000 });
    // Extra settle time so shaders composite (load fires before first rendered
    // frame). Wait for the canvas to have non-zero size + a beat.
    await page.waitForFunction(
      () => { const c = document.querySelector('canvas'); return c && c.width > 0 && c.height > 0; },
      { timeout: 15000 }
    ).catch(() => {});
    await new Promise(r => setTimeout(r, wait));

    await page.screenshot({ path: out, type: 'png' });
    console.log(out);
    await browser.close();
    process.exit(0);
  } catch (e) {
    console.error('web_screenshot failed:', e.message);
    try { await browser.close(); } catch (_) {}
    process.exit(1);
  }
})();
