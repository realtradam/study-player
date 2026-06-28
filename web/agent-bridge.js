/* Jamstack web agent bridge (W2): injected into game.html by the relay
 * (tools/agent-bridge/server.js). Polls the relay for Ruby commands, runs them in
 * the live game via the wasm export (Module.jamstack), and posts results back, so
 * the desktop .live/bin/eval interface works against this browser tab. Forwards
 * console output to the relay's game-console. No-ops quietly if no relay is present
 * (e.g. the page is served by a plain static server). Dev-only. */
(function () {
  'use strict';

  function ready() { return window.Module && typeof window.Module.jamstack === 'function'; }

  function post(url, obj) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(obj),
    }).catch(function () {});
  }

  // Tee console.* to the relay (this also carries the Ruby Log stream, since
  // Log -> puts -> Module.print -> console.log on web).
  ['log', 'info', 'warn', 'error'].forEach(function (lvl) {
    var orig = console[lvl] ? console[lvl].bind(console) : function () {};
    console[lvl] = function () {
      orig.apply(null, arguments);
      try {
        var line = Array.prototype.map.call(arguments, String).join(' ');
        post('/jamstack/console', { line: line });
      } catch (e) {}
    };
  });

  var relayUp = false;

  function loop() {
    if (!ready()) { setTimeout(loop, 100); return; }
    fetch('/jamstack/poll').then(function (r) {
      if (!r.ok) throw new Error('relay ' + r.status);
      relayUp = true;
      return r.json();
    }).then(function (cmd) {
      var had = cmd && cmd.code != null && cmd.code !== '';
      if (had) {
        var out;
        try { out = window.Module.jamstack(cmd.code); }
        catch (e) { out = JSON.stringify({ ok: false, error: 'jamstack: ' + String(e) }); }
        post('/jamstack/result', { id: cmd.id, result: out });
      }
      setTimeout(loop, had ? 0 : 50);
    }).catch(function () {
      relayUp = false;          // no relay (static server) -> back off quietly
      setTimeout(loop, 1000);
    });
  }

  setInterval(function () {
    if (relayUp && ready()) post('/jamstack/status', { connected: true, ts: Date.now() / 1000 });
  }, 1000);

  loop();
})();
