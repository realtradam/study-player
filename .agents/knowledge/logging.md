# Tribal knowledge: structured logging (`Jamstack::Log`) — the game-console

## At a glance
- **What:** leveled, structured (NDJSON) logging with a monotonic frame counter, an
  in-memory **ring buffer** the agent queries over the bridge, and stdout + optional
  file sinks. This is the **game-console** stream (Ruby/engine intent); the
  browser-console (web platform console) is **deferred** (roadmap R2/R4).
- **Key files:** `mrbgems/raylib/mrblib/log.rb` (the `Log` module);
  `mrbgems/raylib/mrblib/jamstack_json.rb` (shared `Jamstack::JSON.generate`, used by
  Log AND the bridge); seam `raylib.rb` `while_window_open` (calls `Log.setup` +
  `Log.tick!` per frame, and logs loop exceptions).
- **Env:** `JAMSTACK_LOG=<path>` (append NDJSON file sink), `JAMSTACK_LOG_LEVEL=`
  `debug|info|warn|error` (min level). Read once via C `Jamstack.getenv` at setup.
- **Cross-refs:** `agent-bridge.md` (the eval channel that exposes `Log.tail/grep`);
  roadmap R2; principle P5 (observe vs mutate).

## API
```ruby
Jamstack::Log.info("spawned", tag: "spawn", entity: id)   # msg + structured fields
Jamstack::Log.warn("low hp", entity: id, hp: 2)
Jamstack::Log.error("bad state", entity: id)
Jamstack::Log.exception(e, tag: "physics")                # class + message + backtrace
# agent query surface (over the bridge):
Jamstack::Log.tail(50)         # last N records (Array<Hash>)
Jamstack::Log.grep("physics")  # SUBSTRING match (no Regexp here), returns records
Jamstack::Log.tail_ndjson(50)  # last N as an NDJSON string
```
Each record carries `ts` (epoch float), `frame`, `level`, optional `msg`, then any
structured fields. The "what errored in the last 5s and on which entity" query is
just `tail(50).select { |r| r["level"]=="error" && Time.now.to_f-r["ts"]<5 }`.

## Scar tissue (mruby ≠ CRuby; verified)
- **No `Regexp`** in this gembox → `Log.grep` is **substring**, not regex. (Adding
  mruby-regexp-pcre is a rebuild-class change; not done.)
- **NaN/Infinity are invalid JSON.** Float math yields them (`0.0/0.0`→NaN,
  `1.0/0.0`→Infinity); `Jamstack::JSON` emits `null` for non-finite floats. Don't
  "fix" by printing them raw — it produces unparseable lines.
- **`Time.now.to_f`** is available (mruby-time) — used for `ts`.
- **No `**kwargs` reliance:** the API takes an explicit trailing `fields = {}` Hash
  (callers still write `tag: "x", entity: id` — Ruby collects the trailing pairs).
- **stdout-during-eval interaction:** the stdout sink writes to C fd 1. If a log is
  emitted *while* a bridge eval is capturing (fd 1 redirected to a tmpfile), that
  line lands in the eval's captured stdout instead of the console. The **ring buffer
  still records it** (the canonical query path), and the bridge logs eval errors
  *after* `__cap_end` to avoid this. See `agent-bridge.md`.

## Frame counter & loop exceptions
`while_window_open` calls `Log.tick!` once per frame and wraps the game block: an
uncaught exception is `Log.exception`'d (tag `loop`) then **re-raised** (preserves
the existing crash/`mrb_print_error` behavior — just adds a log line). A
"log-and-continue" resilience mode is a possible future opt-in, not the default.

## Deferred (not yet wired)
- **Flecs log funnel:** `ecs_log_set_level` + an OS-API log callback to interleave
  flecs's own tracing into this pipeline (roadmap R2). It's C work in the flecs
  mrbgem and no game uses flecs yet — do it when the first flecs game lands.
- **`.live/console` path + browser-console:** R4 (relay) / deferred.

## Verify
`JAMSTACK_BRIDGE=1 JAMSTACK_LOG=/tmp/x.ndjson ./zig-out/bin/game game/loop.rb`,
then over the bridge eval `Jamstack::Log.tail(5)`, `grep(...)`, and the
errored-in-last-5s query; confirm `/tmp/x.ndjson` is one valid JSON object per line.
