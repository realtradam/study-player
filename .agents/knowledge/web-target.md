# Tribal knowledge: web (Emscripten / WASM) target

`build_web.sh` builds raylib (`PLATFORM_WEB`), RmlUi (emcc + freetype port),
flecs (amalgamation), and a wasm mruby cross-build, then `emcc`-links them and
preloads `game/`. Output: `build/web/game.{html,js,wasm,data}`.

## At a glance
- **Key files:** `build_web.sh`; shell `web/shell.html` (entry script in
  `Module.arguments`); the `web` `MRuby::CrossBuild` in `build_config.rb`; web loop
  seam in `mrbgems/raylib/src/raylib_bindings.c` (`_run_web_loop`).
- **Run:** build with `build_web.sh`; serve `cd build/web && python3 -m http.server 8000`;
  headless test `node build/web/game.js /game/script.rb`.
- **Cross-refs:** knowledge `flecs-binding` (the 4 MB stack), `build-system`; deploy
  `docs/DEPLOY_CLOUDFLARE.md`. No dev server / live reload yet (roadmap R4).

## The platform seam
The ONLY thing that differs between desktop and web at the Ruby level is the main
loop: `Rl.while_window_open` uses `emscripten_set_main_loop` on web and a plain
`until window_should_close?` on desktop (implemented in `raylib_bindings.c`).
Game code is identical. `Rl.platform`/`web?`/`desktop?` are available.

## emcc link flags that matter
`-sUSE_GLFW=3 -sUSE_FREETYPE=1 -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2
-sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=4MB --preload-file game@/game --shell-file
web/shell.html`.
- **WebGL2 / OpenGL ES 3.0** (upgraded from WebGL1/ES2). raylib is built with
  `GRAPHICS=GRAPHICS_API_OPENGL_ES3` (the PLATFORM_WEB Makefile uses `GRAPHICS ?=`
  so the `build_web.sh` make-line override wins). `GRAPHICS_API_OPENGL_ES3` auto-
  defines `GRAPHICS_API_OPENGL_ES2` (superset), so all ES2 blocks compile too;
  VAO is core in ES3 so `rlDrawRenderBatch` always takes the VAO branch (never
  the client-array `else` that needed `-sFULL_ES2=1`, which was DROPPED).
  `-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2` = WebGL2-only (no fallback).
  Do NOT use `-sFULL_ES3=1` (client-array emulation — orthogonca, breaks the
  context; see research doc / raylib #4330).
- `-sSTACK_SIZE=4MB` is REQUIRED since flecs (see flecs-binding.md); without it
  the wasm traps with "memory access out of bounds".
- Emscripten freetype/harfbuzz ports are prebuilt via `embuilder`.
- **raylib 6.0:** PLATFORM_WEB emits `libraylib.web.a` (NOT `libraylib.a`).
  `build_web.sh` references `build/web/libraylib.web.a` (both the guard and the
  emcc link line). Desktop still produces `libraylib.a` (unchanged).
- **Switching the GL backend (ES2<->ES3) invalidates `libraylib.web.a`** —
  delete it and let `build_web.sh` rebuild (its `make clean` guard clears the
  shared in-place `.o` per rules/raylib-platform-objs).

## raylib 6.0 upgrade (5.5 -> 6.0) — what changed on our side
Upgrading the vendored raylib (`vendor/raylib` is a full git clone on a detached
tag) required THREE fixes in our build code (NOT vendor edits) + one vendored
patch for an upstream regression:

1. **API parser relocated.** 6.0 moved `parser/` -> `tools/rlparser/` and renamed
   the source `raylib_parser.c` -> `rlparser.c`. `mrbgem.rake` points at
   `tools/rlparser/output/{raylib,raymath}_api.json` and builds
   `tools/rlparser/rlparser.c`. (`raymath_api.json` is still generated from
   `src/raymath.h` via the parser; `raylib_api.json` is shipped pre-generated but
   is malformed — see #3.)
2. **Malformed `raylib_api.json` (upstream bug).** The shipped 6.0
   `tools/rlparser/output/raylib_api.json` has invalid JSON: the
   `LoadDirectoryFilesEx` description contains literal unescaped double-quotes
   (`"*.*"`, `"FILES*"`, `"DIRS*"`), copied verbatim from `raylib.h`. Both Ruby
   and Python reject it. Regenerating from `raylib.h` reproduces the same
   malformation (same source). Fix: `gen_raylib.rb` (and `gen_ai_reference.rb`)
   have a `load_api` helper that tries strict parse, then escapes those three
   tokens and retries. Safe on already-valid json (the escaped form doesn't
   contain the unescaped substring). Do NOT regenerate `raylib_api.json` from
   `raylib.h` with `-d RMAPI` — raylib.h uses the `RLAPI` decorator (raymath uses
   `RMAPI`); `-d RLAPI` is correct but still yields the malformed quotes, so the
   tolerant loader is the real fix.
3. The high-level shader API (`LoadShader`/`SetShaderValue*`/`GetShaderLocation`/
   `UnloadShader`) is **unchanged** in 6.0. The "REDESIGNED shader loading API"
   (#5631) was `rlgl`-internal only (`rl*` functions), not `raylib.h`. Bindings
   regenerated clean: 671/746 functions, 75 unbound (was 72 on 5.5).

To rebuild raylib after switching the tag: `make -C vendor/raylib/src clean`
(raylib shares `.o` in `src/` across targets — see rules/raylib-platform-objs),
delete the stale `build/{desktop,web}/lib*raylib*.a`, then `zig build` / `build_web.sh`.

## raylib 6.0 regression: IsCursorHidden() on web (pointer lock)
**Symptom:** after the 6.0 upgrade, mouse-look broke in `game/physics_playground.rb`
(uses `disable_cursor` + `get_mouse_delta`). `cursor_hidden?` stayed `false` and
`get_mouse_delta` returned `0.0` even after clicking; `get_mouse_x/y` worked fine.
**Cause:** 6.0 refactored cursor state in `vendor/raylib/src/platforms/rcore_web.c`
into `cursorHidden` (HideCursor) vs `cursorLocked` (DisableCursor/pointer-lock),
but `EmscriptenPointerlockCallback` now sets ONLY `cursorLocked` — it stopped
setting `cursorHidden` (5.5 set `cursorHidden` there). `IsCursorHidden()` reads
`cursorHidden`, so it never returns true on web after `DisableCursor()`. Games
that gate repeated `disable_cursor` calls on `!cursor_hidden?` (like
physics_playground) then spam `emscripten_request_pointerlock` every frame; the
browser rejects that (pointer lock must come from a single user gesture) → pointer
lock never stably engages → `get_mouse_delta` dead.
**Fix (vendored patch, documented inline):** `EmscriptenPointerlockCallback` now
also does `cursorHidden = cursorLocked` (restoring 5.5 semantics). This is a
genuine upstream regression — report it / re-check on the next raylib pull.
`EmscriptenMouseMoveCallback` already branches on `cursorLocked` (so deltas flow
once lock engages); the patch just makes `IsCursorHidden()` reflect it.

## Testing the wasm without a browser
`node build/web/game.js [/game/script.rb]` boots the wasm and runs mruby. A
script that opens a window stops at `glfwInit` with `window is not defined` —
that's the expected browser-only boundary, not a failure. To actually exercise
logic (e.g. flecs) on wasm, run a **windowless** script: drop it in `game/`,
relink (`build_web.sh` is incremental once libs exist), and
`node game.js /game/yourscript.rb`. main.c takes the script path as argv[1].

## Serving
Browsers won't run `file://` wasm. To view the game: `cd build/web && python3 -m
http.server 8000` (static files only — no eval bridge). For the eval bridge +
`.live/web/bin/*` scripts, use the relay instead (see "Starting the relay"
below). `web/shell.html` is a responsive canvas shell (viewport-fit,
aspect-ratio, touch-action).

## FX shader pipeline on web (WebGL2/ES3) — DONE + browser-verified
`Jamstack::FX` (mrblib/fx.rb) is a two-stage post-processing pipeline that runs
on WebGL2/ES3 (`#version 300 es` fragment shaders — upgraded from WebGL1). All
6 effects (warp, aberration RGB, aberration CMY, scanlines = game stage;
vignette, grayscale = top stage) compile + run in the browser under GLSL ES 3.00,
and every effect in BOTH stages toggles on/off at runtime via the eval bridge
(`fx.game_shaders[0].enabled = false`) or the overlay-HUD checkboxes, with zero
recompilation. (WebGL1's NPOT warning is gone under WebGL2.) To switch which
demo the browser runs, edit `web/shell.html` -> `Module.arguments` then rebuild
(shell.html is baked in). See `raylib-binding.md` "Custom shaders".

**Web game-file edit requires a rebuild:** on WEB the game files are packaged
into `game.data` at build time (MEMFS), so ANY game/*.rb or game/ui/*.{rml,rcss}
change needs `./build_web.sh` then a hard-refresh (bypass cache). The relay
serves `build/web/` statically; it does NOT live-serve the repo `game/` dir.

## Agentic runtime on web (R1–R5 web) — DONE + browser-verified
W1 verified on wasm via `node game.js /game/<windowless>.rb` (`eval_json`, `Log`,
`Flecs::Hot`, R5a `enable_rest`), and the JS→C path **browser-verified** through the
W2 relay: `sh .live/web/bin/eval 'Rl.get_fps'` → live fps, `Rl.platform` → `:web`,
multiline+`puts` returns result **and** captured stdout (C fd-redirect works under
emscripten MEMFS), `raise` returns a backtrace into the running game, and the
forwarded browser console (incl. the Ruby `Log` NDJSON) lands in `game-console`.
`_jamstack_eval`/`_flecs_explorer_request` are exported; `shell.html` exposes
`Module.jamstack`/`Module.flecsRequest`. W2 (`tools/agent-bridge/server.js`) is the
host relay that lets the **desktop `bin/eval` drive a browser tab** — see
`live-mount.md`. (Still TODO: exercise `Module.flecsRequest`/the Explorer against a
flecs web game; ship `bin/snapshot` from that JSON.)

### Starting the relay (and stopping it safely)
The regular way — just run it (this serves `build/web/` and writes the
`.live/web/bin/*` scripts):
```sh
node tools/agent-bridge/server.js          # foreground; Ctrl-C to stop
```
From a non-interactive agent shell, background it and save the PID:
```sh
nohup node tools/agent-bridge/server.js > /tmp/relay.log 2>&1 & echo $! > /tmp/relay.pid
kill "$(cat /tmp/relay.pid)"               # stop it later
```
Then open `http://localhost:8080` in a browser. Poll `.live/web/status.json`
for `"connected":true` (set once a tab is open) before running `bin/eval`.

**Gotcha — don't `pkill -f` to stop it.** `pkill -f 'agent-bridge/server.js'`
matches the agent's *own* shell command line (it contains that string) and kills
the shell → "no output, hung till timeout". Stop by PID
(`kill "$(cat /tmp/relay.pid)"`) or `Ctrl-C` the foreground process — never by
`-f` self-matching. (For just viewing the game with no eval bridge, a plain
`cd build/web && python3 -m http.server` also works — `agent-bridge.js` no-ops
quietly when there's no relay.)

The desktop bridge uses TCP, which the browser can't do; the web channel is **JS→C**:
- **Eval:** `jamstack_eval(code) -> char* json` (`EMSCRIPTEN_KEEPALIVE`, in `main.c`)
  calls `Jamstack::Bridge.eval_json` on the persistent `g_mrb`. Safe to call directly
  from JS between frames (wasm is single-threaded; no queue needed). `main` never
  returns on web (`set_main_loop` unwinds), so `g_mrb` stays alive past `main.c`'s
  `mrb_close`.
- **Loop:** the web seam (`_run_web_loop`) now also `Log.tick!`s and logs loop
  exceptions, matching desktop. The TCP `Bridge.start` fails gracefully on web (no
  sockets) → `Bridge.drain` is a no-op; eval arrives via `jamstack_eval`.
- **flecs REST (R5a):** `world.enable_rest` on web does `flecs_wasm_rest_server =
  ecs_rest_server_init(world, NULL)` (socketless); flecs's own
  `flecs_explorer_request(method,req,body)` (already `EMSCRIPTEN_KEEPALIVE`) serves
  the JSON — ship it over the JS channel.
- **Link flags:** `-sEXPORTED_FUNCTIONS=_main,_jamstack_eval,_flecs_explorer_request`
  + `-sEXPORTED_RUNTIME_METHODS=ccall,cwrap`.
- **shell.html:** exposes `Module.jamstack(code)` and tees `console`.
- **Relay (W2 / R4b):** a host WS relay so a *file-based* agent reaches the browser
  tab — separate slice (assessed after W1).
- **Verification limits:** `node game.js /game/x.rb` exercises **windowless** runtime
  logic on wasm (eval_code, Log, Flecs::Hot, flecs); the JS→C eval + the Explorer
  need a **browser** (the window keeps `mrb` alive), so those are browser-verified.
