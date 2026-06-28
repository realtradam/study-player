# Tribal knowledge: the `.live/` mount (`Jamstack::Live`) — R4 (desktop slice)

> Status: **IMPLEMENTED + verified** (R4 desktop) — `mrbgems/raylib/mrblib/live.rb`.
> The Node WS relay + web side are **deferred** (R4b); this slice is the file-based
> mount the game writes itself — no relay, no WS, no extra runtime.

## At a glance
- **What:** a read-mostly `.live/<token>/` surface a file-based agent uses without
  speaking a socket: `status.json` (heartbeat), `game-console` (NDJSON log), and a
  `.agent/cmd-* → result-*.json` command protocol drained **in-frame** (P6). Plus
  `bin/*` helper scripts. This is the elegant desktop path (no FUSE — see the
  `.live` mechanism in roadmap R4): the native game has `mruby-io`/`mruby-dir`, so it
  writes/polls real files directly.
- **Key files (planned):** `mrbgems/raylib/mrblib/live.rb` (`Jamstack::Live`); seam
  `raylib.rb` (`Live.start` + `Live.poll` per frame); reuses `Bridge.eval_code` (R1)
  and `Jamstack::JSON`/`Log` (R2).
- **Gate:** same `JAMSTACK_BRIDGE=1`. Token via `JAMSTACK_LIVE` (default `dev`), root
  via `JAMSTACK_LIVE_ROOT` (default `.live`) → `.live/dev/`.
- **Cross-refs:** `agent-bridge.md` (R1 eval, shares the queue/drain), `logging.md`
  (game-console), roadmap R4; principle P5 (observe vs the one write path), P7 (dev).

## The protocol (no JSON parser needed)
mruby has **no JSON parser**, so the **command** files carry *raw Ruby*; the id is
the filename. Only the **result** is JSON (written via `Jamstack::JSON`).
```
.live/dev/
  status.json            # heartbeat: connected,target,token,frame,fps,ts (throttled, atomic)
  state.json            # flecs world snapshot (bin/snapshot writes this; atomic)
  game-console           # Log NDJSON file sink (R2)
  .agent/
    cmd-<id>.rb          # AGENT WRITES raw Ruby (atomic: write .tmp then rename)
    result-<id>.json     # GAME WRITES the {id,ok,result,stdout,error,backtrace} envelope
  bin/                   # tiny shell wrappers (run via `sh bin/eval` if not +x)
    eval  tail-log  hot-reload  snapshot  query
```
**Per-frame drain (`Live.poll`, after `Bridge.drain`):** `Dir.entries(.agent)` →
select `cmd-*` → for each: read code, **delete the cmd file**, `Bridge.eval_code`,
write `result-<id>.json` atomically. `status.json` rewritten throttled (~every 30
frames). The only agent-writable path is `.agent/cmd-*` (P5).

## mruby FS constraints (probed)
- **No `Dir.glob`/`Dir[]`** → list with `Dir.entries(dir)` and filter
  (`start_with?("cmd-")`).
- **No `File.write`** class method → `File.open(path,"w") { |f| f.write(s) }`.
- Have: `Dir.mkdir`/`entries`/`foreach`, `File.read`/`rename`/`delete`/`unlink`/
  `exist?`/`directory?`/`basename`/`join`. **Atomic write = temp + `File.rename`**.
- No recursive mkdir → walk path components with `Dir.mkdir` (ignore "exists").
- `.live/` is runtime state → **gitignored**, never committed.

## Acceptance
`sh .live/dev/bin/eval 'Rl.get_fps'` returns the JSON envelope; `bin/tail-log`
streams `game-console`; `status.json` updates while the game runs; the loop
survives. Works against a running desktop game with no relay.

## Web relay (W2 / R4b) — IMPLEMENTED + browser-verified
Confirmed in a real browser tab: `sh .live/web/bin/eval 'Rl.get_fps'` → live fps;
`Rl.platform` → `:web`; multiline+`puts` returns `result` **and** captured `stdout`
(the C fd-redirect works under emscripten MEMFS); `raise` returns a backtrace into
`game/physics_playground.rb`; forwarded browser console (incl. the Ruby `Log` NDJSON)
lands in `game-console`. The desktop `bin/eval` drives a browser game unchanged.
`tools/agent-bridge/server.js` + `web/agent-bridge.js`. **Use it:**
```sh
EMSDK_ENV=/path/to/emsdk_env.sh ./build_web.sh   # if not already built
node tools/agent-bridge/server.js                # serves http://localhost:8080
# open http://localhost:8080 in a browser (the game runs), then from a shell:
sh .live/web/bin/eval 'Rl.get_fps'               # -> JSON envelope from the live tab
sh .live/web/bin/tail-log                        # stream the browser console
```
Verified headlessly with a simulated-browser node poller: `bin/eval` round-trips
(`EVAL[...]`), `status.json` + `game-console` populate, `agent-bridge.js` is injected
into `game.html` and served (200). The real `Module.jamstack` leg is browser-verified
(W1 already proved `eval_json` works on wasm in node).

A **dependency-free Node HTTP relay** (`tools/agent-bridge/server.js`) gives the
browser tab the *same* `.live/<token>/` interface as desktop, so `bin/eval` etc.
work identically against a browser game:
- The relay **serves `build/web/`** (same-origin → no CORS, no `ws` dep) and injects
  `<script src="/agent-bridge.js">` into `game.html` on the fly (no rebuild).
- It owns `.live/<token>/` (default token `web`): `.agent/`, `bin/*`, `game-console`,
  `status.json`. It **bridges files ↔ browser**:
  - `GET /jamstack/poll` → relay scans `.agent/` for the oldest `cmd-*.rb`, reads +
    deletes it, returns `{id, code}` (or `{}`).
  - browser runs `Module.jamstack(code)` → `POST /jamstack/result {id, result}` →
    relay writes `result-<id>.json`. `bin/eval` (unchanged) round-trips.
  - browser `POST /jamstack/console` (forwarded `console.*`, incl. the Ruby `Log`
    stream) → appended to `game-console`; `POST /jamstack/status` → `status.json`.
- `web/agent-bridge.js`: ~poll client; waits for `Module.jamstack`, forwards
  console, heartbeats status; **no-ops quietly if no relay** (e.g. page served by
  `python3 -m http.server`).
- **Verification:** relay routing + `.live` bridging are verified headlessly with a
  simulated-browser node poller; the real `Module.jamstack` leg is browser-verified.

## Still deferred
- (none currently — `bin/snapshot`/`query` shipped, see below)

## Scar tissue (verified desktop)
- **Round-trips:** `sh .live/dev/bin/eval 'Rl.get_fps'` returned the JSON envelope
  (`result:"600"`); a live hot-reload through the same channel swapped Move (id
  stayed 544) and added Tagger, taking the entity `{x:79} → {x:2081, y:42}` (state
  continued). `status.json` heartbeat advanced (frame 60→90); `game-console` is clean
  NDJSON.
- **Run via `sh bin/<name>`** — `File.chmod(0755, …)` is attempted but not relied on;
  the scripts work invoked through `sh` regardless.
- **log-during-eval lands in captured stdout:** a `.live` eval that emits `Log`
  lines (e.g. `define_system` logs "system swap") sees them in the result's `stdout`
  field, because the log sink writes to the fd being captured. They are still
  recorded in the ring buffer + `game-console`. Same interaction as the TCP path
  (`agent-bridge.md`); harmless.
- **`clean_agent` on start** deletes stale `cmd-`/`result-`/`.tmp` so a new run
  doesn't replay a previous session's commands.
- **Atomic everywhere:** `status.json` and `result-*.json` are written to `*.tmp`
  then `File.rename`d; a `cmd-*` file is `File.read` then immediately deleted
  (consumed once). Writers (`bin/*`, raw agents) must `mv` the cmd into place too.
- **mruby FS:** no `Dir.glob` (used `Dir.entries` + `start_with?`); no `File.write`
  (used `File.open(…,'w')`); recursive mkdir hand-rolled.
- **`bin/snapshot` + `bin/query`** (wire flecs REST JSON through the bridge): these
  call `Flecs::World#rest_request` (an in-process `ecs_http_server_request` — no
  socket, works on desktop AND web). `bin/snapshot` → `/world` endpoint → writes
  `.live/<token>/state.json` + prints JSON; `bin/query <expr>` →
  `/query?expr=<expr>&values=true` → prints JSON. Both require `enable_rest` on the
  flecs world in game code (and `Flecs::Hot.world = world` so the bin scripts can
  find the world). The REST handle is a C static `fl_rest_server` set by
  `_enable_rest` on both targets; on desktop the HTTP listener (for the hosted
  Explorer) is a separate server object started by `ecs_set(EcsWorld, EcsRest)`.
  **Web:** `bin/snapshot` uses a relay route (`GET /jamstack/snapshot`) that calls
  `relayEval` (writes `cmd-*.rb` → polls for `result-*.json`) and writes `state.json`
  to the HOST filesystem (not MEMFS). `bin/query` uses `bin/eval` directly (the REST
  JSON is in the result envelope's `result` field). Both work identically on desktop
  and web — all 5 `bin/*` scripts are now available on both targets.
