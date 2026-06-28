#!/usr/bin/env node
/* Jamstack web relay (W2 / R4b) — dependency-free Node HTTP server.
 *
 * Gives a browser game the SAME .live/<token>/ interface as desktop, so the
 * existing bin/eval, snapshot, query, tail-log, hot-reload work against a
 * browser tab:
 *   - serves build/web/ (same-origin -> no CORS, no ws dep) and injects
 *     <script src="/agent-bridge.js"> into game.html on the fly (no rebuild),
 *   - bridges .live/<token>/.agent/cmd-*.rb  <->  the browser:
 *       GET  /jamstack/poll     -> next {id, code} (relay reads+deletes cmd file)
 *       POST /jamstack/result   -> writes result-<id>.json
 *       POST /jamstack/console -> appends a line to game-console
 *       POST /jamstack/status   -> writes status.json
 *       GET  /jamstack/snapshot -> relayEval flecs /world -> state.json + JSON
 *       GET  /jamstack/query    -> relayEval flecs /query?expr=... -> JSON
 *   - writes 5 bin/ scripts (eval, snapshot, query, tail-log, hot-reload)
 *
 * Usage:  node tools/agent-bridge/server.js   (then open http://localhost:8080)
 * Env: JAMSTACK_RELAY_PORT (8080), JAMSTACK_LIVE token (web). Dev-only, localhost.
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT  = path.resolve(__dirname, '..', '..');
const WEB   = path.join(ROOT, 'build', 'web');
const TOKEN = process.env.JAMSTACK_LIVE || 'web';
const PORT  = parseInt(process.env.JAMSTACK_RELAY_PORT || '8080', 10);
const LIVE  = path.join(ROOT, '.live', TOKEN);
const AGENT = path.join(LIVE, '.agent');
const BIN   = path.join(LIVE, 'bin');

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.data': 'application/octet-stream', '.json': 'application/json',
  '.css': 'text/css', '.png': 'image/png', '.ttf': 'font/ttf',
};

function writeAtomic(p, s) { const t = p + '.tmp'; fs.writeFileSync(t, s); fs.renameSync(t, p); }
function writeStatus(o) { writeAtomic(path.join(LIVE, 'status.json'), JSON.stringify(o)); }

function writeBinScripts() {
  const evalSh = '#!/bin/sh\n' +
    '# Run Ruby in the live browser game; prints the JSON result envelope.\n' +
    'ag="$(cd "$(dirname "$0")/.." && pwd)/.agent"\n' +
    'id="p$$_$(date +%s%N 2>/dev/null || date +%s)"\n' +
    'printf \'%s\' "$1" > "$ag/.tmp-$id"\n' +
    'mv "$ag/.tmp-$id" "$ag/cmd-$id.rb"\n' +
    'i=0\n' +
    'while [ $i -lt 250 ]; do\n' +
    '  if [ -f "$ag/result-$id.json" ]; then cat "$ag/result-$id.json"; echo; rm -f "$ag/result-$id.json"; exit 0; fi\n' +
    '  i=$((i + 1)); sleep 0.02\n' +
    'done\n' +
    'echo \'{"ok":false,"error":"timeout (is the tab open + connected to the relay?)"}\' >&2; exit 1\n';
  const tailSh = '#!/bin/sh\n' +
    'd="$(cd "$(dirname "$0")/.." && pwd)"\n' +
    'exec tail -n "${1:-40}" -f "$d/game-console"\n';
  const hotSh = '#!/bin/sh\n' +
    'exec "$(dirname "$0")/eval" "Flecs::Hot.reload_file(\\"$1\\")"\n';
  const snapSh = '#!/bin/sh\n' +
    '# Dump flecs world state to state.json (host filesystem, not MEMFS).\n' +
    'd="$(cd "$(dirname "$0")/.." && pwd)"\n' +
    '"$d/bin/eval" \'Flecs::Hot.world.rest_request("GET","/world","")\' | \\\n' +
    'node -e \'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const e=JSON.parse(d.trim());if(e.ok&&e.result){require("fs").writeFileSync(process.argv[1]+"/state.json",e.result);process.stdout.write(e.result)}else{process.stderr.write("snapshot failed: "+(e.error||"unknown")+"\\n");process.exit(1)}}catch(x){process.stderr.write(x.message+"\\n");process.exit(1)}})\' "$d"\n';  const querySh = '#!/bin/sh\n' +
    '# Query flecs entities; prints REST JSON.\n' +
    'exec "$(dirname "$0")/eval" "Flecs::Hot.world.rest_request(\\"GET\\",\\"/query?expr=$1&values=true\\",\\"\\")"\n';
  const scripts = { 'eval': evalSh, 'tail-log': tailSh, 'hot-reload': hotSh, 'snapshot': snapSh, 'query': querySh };
  for (const [name, content] of Object.entries(scripts)) {
    const p = path.join(BIN, name);
    fs.writeFileSync(p, content);
    fs.chmodSync(p, 0o755);
  }
}

function cleanAgent() {
  try {
    for (const f of fs.readdirSync(AGENT)) {
      if (f.startsWith('cmd-') || f.startsWith('result-') || f.startsWith('.tmp')) {
        try { fs.unlinkSync(path.join(AGENT, f)); } catch (e) {}
      }
    }
  } catch (e) {}
}

fs.mkdirSync(AGENT, { recursive: true });
fs.mkdirSync(BIN, { recursive: true });
writeBinScripts();
cleanAgent();
writeStatus({ connected: false, target: 'web', token: TOKEN, ts: Date.now() / 1000 });

function readBody(req, cb) {
  let b = '';
  req.on('data', (c) => { b += c; if (b.length > 4e6) req.destroy(); });
  req.on('end', () => cb(b));
}

function handlePoll(res) {
  let names = [];
  try { names = fs.readdirSync(AGENT).filter((n) => n.startsWith('cmd-')).sort(); } catch (e) {}
  if (names.length === 0) { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end('{}'); }
  const f = names[0];
  let id = f.slice(4); if (id.endsWith('.rb')) id = id.slice(0, -3);
  let code = '';
  try { code = fs.readFileSync(path.join(AGENT, f), 'utf8'); } catch (e) {}
  try { fs.unlinkSync(path.join(AGENT, f)); } catch (e) {}
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ id: id, code: code }));
}

/* Synchronous eval is NOT possible in the relay (single-threaded Node: a
   busy-wait would block the /jamstack/poll endpoint the browser needs to fetch
   the command). Instead, bin/snapshot pipes bin/eval through node to extract
   the result field and write it to state.json. See writeBinScripts. */

function serveStatic(res, p) {
  const rel = (p === '/' ? '/game.html' : p).replace(/\?.*$/, '');
  const full = path.normalize(path.join(WEB, rel));
  if (!full.startsWith(WEB)) { res.writeHead(403); return res.end('forbidden'); }
  fs.readFile(full, (err, data) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(full);
    let body = data;
    if (ext === '.html') {
      body = Buffer.from(data.toString().replace(
        '</body>', '  <script src="/agent-bridge.js"></script>\n</body>'));
    }
    // no-store: the wasm/js are rebuilt often during dev; without this the
    // browser caches game.wasm aggressively (Emscripten's fetch is cached
    // separately from the HTML, so a hard-refresh doesn't bust it) and serves a
    // stale build -- making code changes appear to have "no effect".
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
    });
    res.end(body);
  });
}

const server = http.createServer((req, res) => {
  const p = req.url.replace(/\?.*$/, '');
  if (p === '/jamstack/poll') return handlePoll(res);
  if (p === '/jamstack/result') return readBody(req, (b) => {
    try { const o = JSON.parse(b || '{}'); const r = (o.result == null) ? '{}' : (typeof o.result === 'string' ? o.result : JSON.stringify(o.result));
      writeAtomic(path.join(AGENT, 'result-' + o.id + '.json'), r); } catch (e) {}
    res.writeHead(204); res.end();
  });
  if (p === '/jamstack/console') return readBody(req, (b) => {
    try { const o = JSON.parse(b || '{}'); if (o.line != null) fs.appendFileSync(path.join(LIVE, 'game-console'), String(o.line) + '\n'); } catch (e) {}
    res.writeHead(204); res.end();
  });
  if (p === '/jamstack/status') return readBody(req, (b) => {
    try { const o = JSON.parse(b || '{}'); writeStatus(Object.assign({ connected: true, target: 'web', token: TOKEN }, o)); } catch (e) {}
    res.writeHead(204); res.end();
  });
  if (p === '/agent-bridge.js') {
    return fs.readFile(path.join(ROOT, 'web', 'agent-bridge.js'), (err, data) => {
      if (err) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'Content-Type': 'text/javascript' }); res.end(data);
    });
  }
  return serveStatic(res, p);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('jamstack relay: http://localhost:' + PORT + '  ->  ' + WEB);
  console.log('  .live mount: ' + LIVE);
  console.log('  bin: eval  snapshot  query  tail-log  hot-reload');
  console.log('  open the URL in a browser, then: sh ' + path.join(BIN, 'eval') + " 'Rl.get_fps'");
});
