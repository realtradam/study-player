# AGENTS.md — raylib-jamstack

Ruby (mruby) game stack: **raylib + raymath + RmlUi + flecs + Jolt**, one binary,
desktop (Zig) or web (Emscripten). Game code is Ruby; the bindings are mrbgems.

## First steps for a new session
1. **Skim `.agents/rules/*`** (7 tiny files) — they prevent expensive mistakes.
2. **Check if the relay is running:** `curl -s http://localhost:8080/game.html | head -1`
   — if it fails, start it: `node tools/agent-bridge/server.js`
3. **Check if a browser is connected:** `sh .live/web/bin/eval 'Rl.platform'`
   — if it times out, no browser tab is open. Open `http://<hostname>:8080`.
4. **Which game is running?** Check `web/shell.html` → `Module.arguments`.
5. **Read the knowledge doc** for the area you're touching (table below).

## READ THE TRIBAL KNOWLEDGE FIRST

This repo has a lot of non-obvious, hard-won knowledge that you CANNOT infer from
the code (toolchain ABI quirks, WSL/Wayland, premultiplied-alpha rendering, flecs
wasm stack, generator naming rules). It lives in layered docs under `.agents/`
(`.claude/` is a symlink to it) — **read them before making changes, not after
something breaks**:

- **`.agents/rules/`** — short safety reflexes. Skim ALL of them every session;
  they prevent the most expensive mistakes (build-breakers, data/ABI traps).
- **`.agents/knowledge/`** — the single per-area tribal doc set (one per area). Each
  opens with an "At a glance" orientation header (key files + API/spec pointer +
  cross-refs), then the deep "why it broke" detail — so it's both the Plan-Mode brief
  and the scar tissue. Read the one(s) for the area you're touching; read all for
  cross-cutting changes.
- **`.agents/skills/`** — codified workflows; load the matching `SKILL.md` when you
  start that task (adding a binding fn, a flecs system, a demo, build-and-verify,
  ruby-to-native migration…).

| File | Read when |
|------|-----------|
| `.agents/rules/*` | always (7 tiny files) |
| `.agents/skills/<task>/SKILL.md` | doing that recurring task |
| `.agents/knowledge/build-system.md` | any build/link/mruby change |
| `.agents/knowledge/environment.md` | running anything (WSL/Wayland/PATH) |
| `.agents/knowledge/raylib-binding.md` | touching `Rl::` / the generator |
| `.agents/knowledge/rmlui-binding.md` | touching `Rml::` / UI rendering |
| `.agents/knowledge/fx-pipeline.md`   | touching `Jamstack::FX` / post-processing shaders |
| `.agents/knowledge/console.md` | touching `Jamstack::Console` / the REPL |
| `.agents/knowledge/agent-bridge.md` | using the eval bridge / `.live/` |
| `.agents/knowledge/hot-reload.md` | reloading flecs systems at runtime |
| `.agents/knowledge/logging.md` | the `Log` ring buffer / structured logs |
| `.agents/knowledge/flecs-binding.md` | touching `Flecs::` / ECS |
| `.agents/knowledge/jolt-binding.md`  | touching `Jolt::` / 3D physics |
| `.agents/knowledge/web-target.md`    | anything web/wasm |
| `.agents/knowledge/ruby-lsp.md`     | Ruby LSP config / `opencode.json` / hover-diagnostics |
| `.agents/knowledge/linting.md`     | linting / `bin/lint` / RuboCop / clang-format |
| `.agents/knowledge/steep.md`       | the RBS type checker / `tools/check-types.sh` / `Steepfile` (lenient) / the Steep LSP |
| `.agents/knowledge/testing.md`       | verifying any change |

When you discover a new gotcha, **write it down** in the right file — that's how
this harness stays valuable (the article calls these files "crystallized scar
tissue"). Keep entries short and specific to THIS repo; omit generic advice.

## Architecture (the non-obvious parts)
- Bindings are **mrbgems** under `mrbgems/{raylib,rmlui,flecs,jolt}/` (C/C++ in
  `src/`, Ruby sugar in `mrblib/`); all 4 are listed in `build_config.rb` and compiled
  into `libmruby.a`, then linked against the native libs by `build.zig` /
  `build_web.sh`. `src/main.c` boots mruby and runs `argv[1]` (default
  `game/main.rb`).
- raylib bindings are **generated** from `raylib_api.json` by
  `mrbgems/raylib/tools/gen_raylib.rb`. Edit the generator, never `raylib_gen.c`.
- The single platform seam is `Rl.while_window_open` (desktop `while` vs web
  `emscripten_set_main_loop`); game code is otherwise identical across targets.

## Commands
- `zig build` / `zig build run` — desktop build (orchestrates everything).
- `./rebuild.sh` — fast incremental: rake `libmruby.a` + zig link.
- `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh` — web build.
- Run a script: `./zig-out/bin/game path/to.rb`.
- `bin/lint` / `bin/lint --fix` — manual style linting (RuboCop + clang-format + clang-tidy; see `.agents/knowledge/linting.md`).
- `./tools/check-types.sh` — type-check gate: `rbs validate` (sig/*.rbs consistency) + `steep check` (Steep project loads clean, no `:error`). Cheap, build-free; green on correct code. Game-code type typos are `:information` (live in the Steep LSP / `steep check --severity-level=information`), not a gate failure — see `.agents/knowledge/steep.md`.
- **Always** strip `/mnt/c` from PATH first (see `.agents/rules/wsl-toolchain.md`).

## Rules with teeth (full text in `.agents/rules/`)
- Never hand-edit generated/vendored files (`raylib_gen.c`, `vendor/`, `build/`,
  `sig/raylib.rbs`, `docs/AI_REFERENCE.md`).
- `rm -rf vendor/mruby/build` after adding/removing a gem or flipping C/C++ ABI.
- raylib shares `.o` across platforms → `make clean` when switching desktop/web.
- Link order: `libmruby.a` before the native libs; GNU libstdc++ linked directly.
- Don't commit build artifacts or `*.png` screenshots.
- All eval/console/bridge commands run on the main thread (see `.agents/rules/main-thread-eval.md`).

## Subagents
Scoped subagents live in `.opencode/agent/`. Load them via the task tool:
- **`backend-engineer`** — C/C++ native features, bindings, generators, build
  system, and **performance migrations** (Ruby → C when Ruby is too slow).
- **`gameplay-ruby`** — `game/**` Ruby + `mrblib/*.rb` sugar. Uses the live web
  bridge to test. Never touches C/C++ or generators.
- **`reviewer`** — read-only; checks against rules + glossary + API specs.

When Ruby game logic is too slow, follow the **ruby-to-native** skill
(`.agents/skills/ruby-to-native/SKILL.md`): profile → write C → swap call site →
verify via the web bridge.

## Agentic dev loop (web-first)

**Web is the primary development target.** The game runs in a browser, served by
the relay. Use the bridge to eval Ruby in the live game from the shell.

### Changing which game runs in the browser
The web entry script is set in `web/shell.html` → `Module.arguments`. To switch:
```sh
# Edit web/shell.html:  arguments: ['game/ragdoll_demo.rb']
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh   # rebuild (shell.html is baked in)
```
After rebuilding, restart the relay and refresh the browser.

### Starting a dev session
```sh
# 1. Build web (first time or after C/C++ changes):
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh

# 2. Start the relay (serves the game + creates .live/web/bin/ scripts):
node tools/agent-bridge/server.js
# → open http://<hostname>:8080 in a browser

# 3. Now bin/eval works (it polls the browser via the relay):
sh .live/web/bin/eval 'Rl.get_fps'
```
**Note:** `.live/` is gitignored — it's created at runtime by the relay (web)
or by `Jamstack::Live` (desktop with `JAMSTACK_BRIDGE=1`). The `bin/*` scripts
don't exist until the relay starts. `bin/eval` will timeout with "timeout (is
the tab open + connected to the relay?)" if the relay isn't running or no
browser tab is open.

### Iterating
- **`game/*.rb` edits** → just refresh the browser. No rebuild needed.
- **`mrblib/*.rb` edits** → `./rebuild.sh` then `./build_web.sh`, then refresh.
- **C/C++ edits** → `./rebuild.sh` then `./build_web.sh`, then refresh.

### Debugging the live game from the shell
```sh
sh .live/web/bin/eval 'Rl.get_fps'                     # eval any Ruby
sh .live/web/bin/eval 'Rl.platform'                     # → :web
sh .live/web/bin/tail-log 20                            # recent log lines
sh .live/web/bin/snapshot                                # flecs state.json
sh .live/web/bin/query 'Position'                       # flecs query
sh .live/web/bin/hot-reload game/systems/move.rb        # hot-reload
```

### Reaching live game objects
Bridge eval runs in `Jamstack::Bridge`'s context — game locals are NOT
directly accessible. Use `ObjectSpace` to find live objects:
```ruby
c = nil; ObjectSpace.each_object(Jamstack::Console) { |o| c = o }
c.show; c.input["value"] = "player_color = Rl::RED"; c.send(:submit); c.hide
```

### In-game console (user-facing)
Press `\` (backslash) in the game to toggle the REPL. It has tab completion,
history, and variable propagation. The console's binding IS the game's binding
— it can read/write local variables directly (unlike the bridge eval).

### Other live-dev tools
- **Agent bridge** (`JAMSTACK_BRIDGE=1`, desktop): TCP eval — same `bin/*` scripts.
- **`.live/` mount**: `Jamstack::Live` writes state to `.live/<token>/`.
- **Hot-reload**: `Flecs::Hot` reloads ECS systems at runtime.

## How we work here (plan-first + session hygiene)
- **Plan before code.** Non-trivial work: write a one-paragraph brief → Plan Mode
  (review the *plan*, not the code) → execute via the matching skill. Fixing a wrong
  plan is cheap; fixing wrong code is not.
- **Stop correction spirals.** Corrected on the same thing twice? Don't go for a
  third — clear the session, fold the lesson into the prompt (or a rule/knowledge
  doc), and restart. Correction loops poison context; compact long sessions.
- **The metric:** corrections-per-feature trending down — not "one prompt".
- **Hot-reload caveat (Part B):** a correction spiral *while hot-reloading* also
  leaves the running game dirty — restart the loop AND reload the game when unsure.

## Docs
- Canonical vocabulary: `GLOSSARY.md` (use these terms; avoid the listed aliases).
- Full typed API for agents: `docs/AI_REFERENCE.md` (generated; one file).
- Per-library specs: `docs/API_SPEC*.md`. Build design: `docs/BUILD_SYSTEM.md`.
- Human build steps: `BUILDING.md`.
