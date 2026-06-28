# Tribal knowledge: agent bridge (`Jamstack::Bridge`) — eval-in-the-live-game

## At a glance
- **What:** run Ruby in the **running** game (desktop now; web in R4), on the main
  thread, via a frame-polled command queue. The substrate for hot-reload (R3),
  logging (R2), `.live`/WS (R4), and the in-game console (R6).
- **Key files:** `src/main.c` (C: `js_cap_begin`/`js_cap_end` stdout capture,
  `js_getenv`, `jamstack_bridge_init`); `mrbgems/raylib/mrblib/bridge.rb` (the
  Bridge: TCP poll, queue, `eval_code`, JSON envelope); seam
  `mrbgems/raylib/mrblib/raylib.rb` `while_window_open` (drains once per frame
  before the game block).
- **Gate / transport:** env `JAMSTACK_BRIDGE=1` (localhost only, P7);
  `JAMSTACK_BRIDGE_PORT` overrides the default **7621**. Desktop = TCP.
- **Cross-refs:** roadmap R1/R4, principles P6 (single-thread/frame-drain) & P7
  (dev-only); GLOSSARY "command queue", "the bridge".

## How it works
`mrb_state` from `main.c` stays alive for the whole run. `while_window_open` calls
`Jamstack::Bridge.start` (if enabled) then `Bridge.drain` each frame **before** the
game block — so every command runs on the main thread (P6), never on a socket
callback. `drain` accepts new clients (`accept_nonblock`), reads pending data
(`recv_nonblock`), parses complete lines, and runs up to `MAX_PER_FRAME` (16) evals
to bound frame time.

## Wire protocol (R1; R4 unifies to JSON both ways via the relay)
- **request:** one line `"<id> <code>"`. `<code>` is escaped: `\` → `\\`, newline →
  `\n`, tab → `\t`. `<id>` is a space-free token. (Asymmetric on purpose — there is
  no JSON *parser* in mruby, so the request side avoids needing one.)
- **response:** one line of JSON
  `{"id","ok","result","stdout","error","backtrace"}`. `result` is the value's
  `inspect`; `error` is `"Class: message"`; `backtrace` is an array or null.

## Scar tissue (mruby ≠ CRuby; verified on this binary)
- **stdout capture must be done in C.** mruby's `puts`/`print`/`p` write straight
  to C **fd 1** — NOT through `$stdout`. There is no `StringIO`, no `__printstr__`,
  and overriding `STDOUT#write` does nothing. The ONLY working capture is the C
  fd-redirect bracket: `js_cap_begin` (`dup`+`dup2` fd 1 → `tmpfile()`),
  `js_cap_end` (restore, read back). `eval_code` wraps the eval in it.
- **No `JSON`, no `require`, no `ENV`** in the default gembox. → JSON response is
  hand-encoded (byte-wise; bytes ≥0x20 pass through, so UTF-8 survives); the gate is
  read via C `Jamstack.getenv` (not `ENV`).
- **`recv_nonblock`:** returns a String with data, raises `Errno::EAGAIN` when
  empty, returns `""` on peer close (that's how we reap dead clients).
- **`-std=c11` hides POSIX** `fileno`/`dup`/`dup2`. `main.c` must
  `#define _POSIX_C_SOURCE 200809L` before the includes.
- **eval context:** `eval(code)` runs with `self == Jamstack::Bridge`. Constants
  (`Rl`, `Flecs`, …) and globals resolve fine; top-level **local** variables of the
  game's `main.rb` are NOT visible. R3/R6 may want a dedicated top-level binding.
- **`window_should_close?`** is a sugar alias, not a generated binding — see
  `raylib-binding.md`. The desktop seam needs it.
- **Reach live objects via `ObjectSpace`, don't rebuild for a global.** eval is *live*
  but a top-level **local** (e.g. `player = world.character(...)`) isn't reachable from
  an eval binding. Find the live object instead — `ObjectSpace.each_object(Jolt::Character){|c| ...}`
  (`mruby-objectspace` is compiled in) — rather than editing the game to expose a global
  and rebuilding. Game state already in globals (`$jolt`, `$flecs`, …) is directly
  evaluable.

## Run / verify
```sh
JAMSTACK_BRIDGE=1 ./zig-out/bin/game game/some_loop.rb   # game must call while_window_open
# then, from another process, connect TCP 127.0.0.1:7621 and send "<id> <code>\n"
```
A throwaway Python client lives in the R1 verification notes; sending `Rl.get_fps`,
a multi-line script, and a deliberate `raise` returns value / captured stdout / a
clean error+backtrace while the loop keeps running.

## Not yet (later phases)
- ~~**Web** path (`EMSCRIPTEN_KEEPALIVE jamstack_eval` + `Module.ccall`): R4.~~ — **DONE.**
  The web relay (`tools/agent-bridge/server.js`) bridges the browser game to the
  host filesystem via a file-based poll loop. Same `bin/*` scripts (eval, snapshot,
  query, tail-log, hot-reload) work on both targets. See `.agents/knowledge/live-mount.md`.
- ~~**`.live/` files, WS relay, line-JSON both ways:** R4.~~ — **DONE.**
- **Result routing to the log pipeline / NDJSON:** R2 — done (Log ring buffer).
