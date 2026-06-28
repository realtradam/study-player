# Roadmap — raylib-jamstack: AI Harness + First-Class Agentic Development

This roadmap has **two intertwined goals**:

1. **Build out the AI harness** — finish the layered context system this repo
   started (`.agents/rules/`, `.agents/knowledge/`), borrowing the proven shape
   from `../dispatch/arch-rewrite` (5-layer harness + orchestrator + NDJSON
   observability) and `../roblox` (`.live/` state mount + cmd/result protocol +
   in-game console), adapted to **mruby + Flecs**.
2. **Make agentic development first-class at runtime** — a running game (desktop
   *or* browser) that an AI agent can introspect, hot-patch, and debug live:
   editable Flecs systems on the fly, a WebSocket eval bridge, full game-state
   read/write, Flecs's own debugging/logging surfaced to the agent, structured
   logging, and an in-game Ruby console.

> Reference reading: the AI-harness article
> (`dev.to/louaiboumediene/the-ai-harness`), `../dispatch/arch-rewrite`
> (`AGENTS.md`, `ORCHESTRATOR.md`, `.dispatch/`, `notes/observability-design.md`),
> `../roblox` (`AGENTS.md` §15, `.live/`, `.opencode/`).

---

## Status — what's shipped (implemented + verified)

- **Part A harness:** H0–H3 + plan-first/session-hygiene done. H4 (subagents)
  deferred; H5/H6 partial/deferred.
- **Part B runtime — desktop AND web, all verified:**
  - **R1** eval bridge — TCP + `.live/bin/eval`; web `jamstack_eval` C export. ✅
  - **R2** structured `Jamstack::Log` — NDJSON ring buffer + sinks, queryable over the bridge. ✅
  - **R3** hot-reloadable Flecs systems (`Flecs::Hot`) — same system id, state survives;
    verified live, **including in a browser tab**. ✅
  - **R4** `.live/` file mount (desktop, `Jamstack::Live`) + **W2** dependency-free Node
    relay (`tools/agent-bridge/server.js`) so the SAME `.live/bin/*` drive a browser tab. ✅
  - **R5** flecs REST/Explorer + stats (`world.enable_rest`/`enable_stats`, desktop);
    **R5a** wasm `ecs_rest_server_init` + flecs's `flecs_explorer_request` wired. ✅
  - **Demo:** `game/ragdoll_demo.rb` — flecs-tracked, bridge-summonable ragdolls
    (mruby↔flecs↔Jolt). Verified live (desktop + browser): `summon_ragdoll(x,y,z)`,
    `$flecs.query`/`lookup` live position sync, and a live `Flecs::Hot` reload.

- **Known issues / immediate next:**
  - ~~**🔴 flecs entity DELETE leak**~~ — **FIXED.** Root cause: 32-bit `mrb_int` on
    wasm32 truncated the generation bits (high 32) of `ecs_entity_t` when ids
    round-tripped through `fl_yield_iter`/`fl_w_delete`/`fl_w_alive`. Fix: force
    `-DMRB_INT64` in `build_config.rb` (both builds) + on `src/main.c` compilation
    (`build.zig`/`build_web.sh`) so the full 64-bit entity id round-trips on every
    target. Verified with a summon/delete/summon recycle test on desktop + web.
  - ~~**ballpit_demo.rb yaw fix**~~ — **FIXED.** Same `cam_yaw += md.x` → `-=` as
    the ragdoll demo.
  - ~~**bin/snapshot / bin/query**~~ — **DONE.** Added `Flecs::World#rest_request`
    (in-process `ecs_http_server_request`, no socket — works on desktop AND web).
    `bin/snapshot` → `/world` → writes `.live/<token>/state.json`; `bin/query <expr>`
    → `/query?expr=<expr>&values=true`. Verified on desktop (running game) + web
    (node headless).
  - **R6 — in-game RmlUi console** — keyboard-input gap now CLOSED:
    `rml_context_process_input` forwards keys (raylib→RmlUi KI_* map), text input
    (`GetCharPressed`→`ProcessTextInput`), and modifiers. Unblocks R6; the console
    itself is the next build on top of it.
  - **H6** (LSP/RBS generator): **DONE for Rl/Rml.** `gen_rbs.rb` generates
    `sig/raylib.rbs` from `raylib_api.json` (650 functions, 34 structs, 331
    constants). Hand-written `sig/rmlui.rbs`, `sig/flecs.rbs`, `sig/jolt.rbs`,
    `sig/jamstack.rbs`. `opencode.json` enables `ruby-lsp` with RBS auto-discovery.
    `sig/jolt.rbs` and `sig/flecs.rbs` are fully typed (public API + the `_` C
    primitives + the `Flecs::Hot` sugar, from the `API_SPEC_*.md` + binding
    sources). Only the genuinely dynamic part is left loose: Flecs component
    *values* are `Hash[Symbol, untyped]` (runtime meta structs ↔ Ruby Hashes,
    no per-component class) — the static surface (lifecycle, phases, system/query
    registration, REST, Hot) is precise, with a `term` alias for the
    Component|Entity|Integer id union.

- **Agentic-runtime tip:** reach live *objects* via `ObjectSpace.each_object` (e.g. the
  player `Jolt::Character`) instead of rebuilding to expose a global — eval is live; a
  top-level *local* isn't reachable from an eval binding, but the object is.

---

## Guiding principles (adapted to this repo)

Borrowed from the article and `../dispatch` (P1–P8), trimmed to what matters here:

- **P1 — The repo is a harness, not just code.** Agent-facing meta-info (rules,
  knowledge, features, skills, glossary) is a first-class deliverable, maintained
  with the same care as the bindings.
- **P2 — Document only the non-inferable.** If a frontier model could infer it
  from the code, leave it out. Tribal knowledge (ABI traps, WSL, premultiplied
  alpha, flecs wasm stack, generator naming) is gold; generic advice is noise.
- **P3 — Tiny files always loaded; big files on demand.** Rules + AGENTS.md every
  session (~tens of lines); knowledge docs only when touching that area;
  skills only when invoked.
- **P4 — One canonical vocabulary.** A `GLOSSARY.md` with an "aliases to avoid"
  column prevents synonym drift (System vs system vs phase-callback, Component vs
  struct vs tag, mrbgem vs binding vs gem).
- **P5 — Separate code-mutation from runtime-observation** (the `../roblox`
  lesson). The agent **mutates** behavior by editing Ruby files / hot-reloading;
  it **observes** state through a read-mostly `.live/` surface + logs. Keep the
  write path and the read path distinct and obvious.
- **P6 — Single-threaded safety.** mruby is **not** thread-safe and Flecs mutation
  must happen on the main thread. Every agent/console/bridge command is funneled
  through a **frame-polled command queue drained on the main thread**. No command
  ever runs on a socket/JS callback thread directly.
- **P7 — Dev-only by construction.** The eval bridge executes arbitrary Ruby. It
  binds to localhost, is gated behind a build flag / env var, and never ships in a
  release web build.

---

## Where we are today (baseline)

**Harness (partial):**
- `AGENTS.md` (constitution, 62 lines) + `CLAUDE.md` (currently a *duplicate*, not
  a symlink) + `docs/AI_REFERENCE.md` (generated typed API).
- `.agents/rules/` — 6 safety reflexes (toolchain, link order, LTO, mruby rebuild,
  raylib platform objs, generated files).
- `.agents/knowledge/` — 8 per-area docs (build-system, environment, raylib-,
  rmlui-, flecs-, jolt-binding, web-target, testing).
- **Missing harness layers:** `GLOSSARY.md`, per-area orientation (folded into the
  existing `.agents/knowledge/` docs — one tribal-knowledge location, no separate
  `features/` tree), `.agents/skills/` (codified workflows), subagents, the symlink
  trick, an orchestrator/plan-mode workflow.

**Runtime (nothing agentic yet):**
- `src/main.c` boots one `mrb_state`, runs `argv[1]` as **plain-text** Ruby
  (default `game/main.rb`), no REPL/eval-in/hot-reload.
- Platform seam: `Rl.while_window_open` (`mrbgems/raylib/mrblib/raylib.rb`) —
  desktop `until window_should_close?` vs web `emscripten_set_main_loop`.
- Flecs binding exists (`Flecs::World`, systems, queries) but **no game uses it
  yet**; the amalgamation is compiled **with** REST/HTTP but **no Ruby way to
  start it**; no flecs logging exposed.
- `mruby-eval`, `mruby-socket`, `mruby-io` are **already compiled in** (via the
  `default` gembox). `mirb` is intentionally not linked.
- Web: `web/shell.html` (hardcoded entry script, `Module.print → console.log`),
  served by `python3 -m http.server`. No dev server / live reload / WS.

This baseline is good news: the eval primitive (`mruby-eval`) and the I/O
(`mruby-socket`/`mruby-io`) we need already exist; the work is wiring, not new
toolchain plumbing.

---

## Target architecture (the runtime loop)

```
                 ┌────────────────────── one mrb_state (main thread) ─────────────────────┐
                 │                                                                          │
  AI agent ──┐   │   Rl.while_window_open do                                               │
  console  ──┤   │     Bridge.drain_queue   # eval queued Ruby cmds here (main thread)     │
  (RmlUi)  ──┼──▶│     Hot.progress(dt)     # flecs world.progress; systems dispatch via   │
             │   │                          #   registry → current Ruby proc (swappable)   │
  WS / JS ───┘   │     draw...                                                              │
   bridge        │   end                                                                    │
                 │        ▲                         │                                        │
                 │        │ enqueue                 ▼ emit                                   │
                 │   command queue            Log pipeline (NDJSON ring buffer)             │
                 └────────┼─────────────────────────┼──────────────────────────────────────┘
                          │                          │
        desktop: in-proc non-blocking TCP/WS poll    ├─▶ stdout (→ console.log on web)
        web:     JS calls exported jamstack_eval()    ├─▶ .live/{game,browser}-console
                                                       └─▶ flecs logs (ecs_log_set_level)
                          │
                  Relay (tools/agent-bridge, Bun/Node WS hub)
                          │
                   .live/<token>/  (status.json, state.json, game-console, browser-console, .agent/cmd-*/result-*, bin/*)
```

**Why a queue, not direct calls:** sockets (desktop) and JS WS callbacks (web) run
outside the frame; mruby/Flecs aren't safe to touch there. Everything is enqueued
and drained at one well-defined point each frame (P6). This single design works
identically on both targets — it *is* the new platform seam, sitting right next to
`Rl.while_window_open`.

---

# Part A — Complete the AI Harness

Cheap, high-leverage, mostly docs. Do this first; it makes every later phase
faster because Plan Mode gets grounded context.

## Phase H0 — Harness plumbing & dedupe
- **Symlink trick** (article Layer 6): make the harness tool-agnostic. `.agents/`
  is the single source of truth; symlink `.claude/ → .agents` (and add others as
  tools appear). Replace the duplicated `CLAUDE.md` with a symlink to `AGENTS.md`
  (or a one-line pointer) so the constitution lives in exactly one place.
- Add `.claude/settings.json` (or equivalent): permission allowlist for the build
  commands (`zig build`, `./rebuild.sh`, `build_web.sh`, run scripts) and the
  WebFetch domains we actually use (raylib, flecs.dev, RmlUi, emscripten docs).
- **Acceptance:** editing a rule in `.agents/` is visible from every tool dir; no
  duplicated constitution.

## Phase H1 — Glossary (canonical vocabulary)
- New `GLOSSARY.md` (table: Term | Meaning | Aliases to avoid). Seed with the
  terms that drift in an ECS + bindings repo:
  - `World`, `Entity`, `Component` (runtime struct via meta addon) vs **tag** vs
    **pair**, `System` vs **phase callback**, `query`, `phase` (`ON_UPDATE`...),
    `binding`/`mrbgem` (avoid "gem"/"plugin"), `generator` (`gen_raylib.rb`),
    `platform seam`, `command queue`, `hot-reload` vs **reboot**, `the bridge`,
    `the live mount`.
- **Acceptance:** every new doc/skill uses glossary terms; "aliases to avoid"
  catches the obvious synonyms.

## Phase H2 — Per-module orientation (folded into `.agents/knowledge/`)
**Decision:** keep ONE tribal-knowledge location. Each per-area knowledge doc opens
with an "At a glance" header (Summary / Key files / API+spec pointer / Cross-refs)
above its deep tribal detail — no separate `.agents/features/` tree (a 2nd per-area
location just drifts). Covers the modules that exist; add agentic ones as built
(Part B):
- `raylib-`, `rmlui-`, `flecs-`, `jolt-binding.md`, `build-system.md`, `web-target.md`.
- Later (after Part B): `agent-bridge.md`, `hot-reload.md`, `logging.md`,
  `flecs-observability.md`, `console.md` (all in `.agents/knowledge/`).
- **Rule of thumb:** write the knowledge doc *first* when you start work in an area
  that lacks one — it doubles as the Plan-Mode brief and pays for itself.

## Phase H3 — Skills (`.agents/skills/`, codified workflows)
Each skill is a short SKILL.md procedure for a thing we always forget the steps
of. Initial set, all THIS-repo-specific:
- `/add-binding-fn` — add a raylib fn: edit the **generator**, never `raylib_gen.c`;
  regen; `make clean` if switching target; rebuild order.
- `/add-flecs-system` — define a component (meta struct), register a system via
  the **hot-reloadable** registry (Phase R3), verify with the live mount.
- `/new-demo` — scaffold a `game/*.rb` scene against the platform seam.
- `/build-and-verify` — PATH strip → `./rebuild.sh` (desktop) → offscreen
  render→PNG → web build → node smoke test (mirrors `.agents/knowledge/testing.md`).
- `/add-knowledge` — where a newly-discovered gotcha goes (rule vs knowledge vs
  feature) so scar tissue gets crystallized, not lost.
- Later: `/agent-eval`, `/hot-reload-system`, `/inspect-state`, `/debug-with-logs`.

## Phase H4 — Subagents (scoped) — **DONE**
Scoped subagents in `.opencode/agent/`:
- **`backend-engineer`** — generalized C/C++ developer: new native features
  ("backend"), binding fixes/additions, generators, build system, and
  **performance migrations** (Ruby → C). Three job types, one agent.
- **`gameplay-ruby`** — `game/**` Ruby + `mrblib/*.rb` sugar. Uses the live web
  bridge (`bin/eval`, `bin/snapshot`, `bin/query`, ObjectSpace) to test. Never
  touches C/C++ or generators.
- **`reviewer`** — read-only; checks against rules + glossary + API specs.
  Permission: edit deny, bash ask.

New skill: `.agents/skills/ruby-to-native/SKILL.md` — the performance migration
workflow: profile via `bin/eval` → write C → swap call site → verify via web
bridge → update types. Covers bulk array processing, struct batch ops, and
keeping Ruby flexibility (don't over-migrate).

`AGENTS.md` updated with web-first workflow + subagent section.

## Phase H5 — Orchestration & cadence (lightweight)
Adopt the lighter half of `../dispatch`'s workflow:
- A short **plan-first** note in `AGENTS.md`: write a brief → Plan Mode → review
  the *plan* not the code → execute via a skill.
- `tasks.md` (live milestone log) + a `HANDOFF.md` convention for cross-session
  continuity. Skip the full prompts/​reports orchestrator unless multi-agent waves
  become routine.
- **Acceptance:** a feature can be driven from a one-paragraph brief + a skill,
  with ≤2–3 corrections.

## Phase H6 — LSP & editor intelligence (mruby + bindings)
Give the agent (and humans) language-server feedback over Ruby game code — made
*accurate* for mruby and our C-defined bindings.

**The catch (why this isn't just `lsp: true`):** opencode ships `ruby-lsp`, but it
assumes **CRuby**. Pointed at `game/**` it flags `Rl`/`Rml`/`Flecs`/`Jolt` as
*undefined constants* (they're C-defined — no Ruby source to index) and offers
CRuby-stdlib completions mruby lacks. opencode's own docs warn LSP "is not always a
net positive"; raw-enabled here it mostly emits **misleading** diagnostics.

**The leverage:** `gen_ai_reference.rb` already parses `raylib_api.json` /
`raymath_api.json` and has the exact machinery — a C→Ruby type map (`rtype`),
method naming (`ruby_method`), and fully-typed signatures (`sig`). The typed data
to teach an LSP our bindings already exists in machine form.

**Steps:**
- **Generate RBS** (`sig/*.rbs`, **generated — never hand-edit**, like
  `AI_REFERENCE.md`/`raylib_gen.c`): extend `gen_ai_reference.rb` (or a sibling
  `gen_rbs.rb`) to emit signatures for `Rl`/`Rml` reusing the existing type map;
  regenerate in the same step as AI_REFERENCE. `ruby-lsp` consumes RBS natively →
  completion / hover / signature-help / go-to-def on the bindings, and the
  undefined-constant noise disappears. Flecs/Jolt RBS comes later (their API lives
  in `API_SPEC_FLECS.md` etc., not `raylib_api.json`) — hand-write or add an emit.
- **`opencode.json` `lsp` block:** enable `ruby-lsp` for `.rb`; pick a rubocop
  noise policy (disable style cops or scope them); wire it to the `sig/` dir (RBS
  auto-discovery / `rbs_collection`).
- **mruby-core accuracy (deferred):** a slim hand-maintained RBS of mruby's actual
  core subset would kill the residual CRuby-stdlib false positives — high upkeep,
  low ROI; defer until the noise actually bites.
- **C/C++ side (bonus, separate):** opencode auto-installs `clangd` for the binding
  sources, but it needs a `compile_commands.json` we don't emit (zig/emscripten).
  Optional until we can emit one; not part of the mruby ask.

**Sequencing:** enabling `ruby-lsp` is only clearly net-positive *after* the RBS
stubs exist — before that it mainly adds noise. Land the generator with the config,
or gate the config behind it.

**Acceptance:** hover on `Rl.draw_text` in a `game/*.rb` shows the typed signature;
`Flecs::World` resolves; no false "undefined `Rl`" diagnostics; the agent can use
LSP nav on bindings.

---

# Part B — First-Class Agentic Runtime

This is the substance of the request: hot-reloadable Ruby in the browser, a WS
eval bridge, full state read/write, Flecs debugging/logging, structured logging,
and an in-game console. Built bottom-up; each phase is independently useful.

## Phase R1 — Eval-in + frame-polled command queue (foundation)
The primitive everything else rides on.
- Keep the `mrb_state` from `src/main.c` alive after boot (already is) and expose a
  re-entrant eval that runs **on the main thread only**.
- **C surface:** `jamstack_eval(const char *code) -> char *json` that does
  `mrb_load_string_cxt` on the persistent state and returns
  `{ ok, result (inspect), stdout, error, backtrace }` as JSON. Capture
  `mrb->exc`, format the backtrace, reset the exception so the loop survives a bad
  eval. On web, export via `EMSCRIPTEN_KEEPALIVE` + `cwrap`/`ccall`.
- **Ruby surface:** a `Bridge` (or `Console`) module with a thread-safe-by-frame
  command queue: producers `enqueue(code, id)`; `Bridge.drain` runs each queued
  command via eval inside `while_window_open`, before `world.progress`, and routes
  results back. Cap per-frame drain to bound frame time.
- **Desktop input path:** non-blocking TCP poll (`mruby-socket`, accept+recv with
  no blocking) each frame → enqueue. (WS upgrade comes in R4; raw TCP/line-JSON is
  fine to start.)
- **Web input path:** JS pushes into the queue via the exported C function (R4
  wires the actual WS; here just prove `jamstack_eval` works from `Module.ccall`).
- **Acceptance:** with the game running, send `Rl.get_fps` and a multi-line script;
  get the value, stdout, and a clean error+backtrace for a deliberate exception —
  the loop keeps running.

## Phase R2 — Structured logging pipeline (for AI debugging)
- Ruby `Log` module: levels (`debug/info/warn/error`), structured fields, tags,
  monotonic frame counter. Emits **NDJSON** (one JSON object per line) — the
  format `../dispatch/notes/observability-design.md` standardizes on and that
  agents can grep/tail trivially.
- **Ring buffer** in memory (last N entries) queryable via eval
  (`Log.tail(50)`, `Log.grep(/.../)`) so an agent can pull recent context without
  a file.
- **Two console streams (P5 — keep them distinct, not merged):**
  - **`game-console`** — the structured `Log` NDJSON above (game + engine
    *intent*): mruby exceptions, flecs logs, gameplay events. All targets. Flows
    *through* the runtime/bridge.
  - **`browser-console`** — the **actual platform console**: every line the
    browser would print to DevTools (JS exceptions, unhandled rejections,
    Emscripten `printErr`, and **wasm aborts** — OOM/stack-overflow/asserts).
    Web only; desktop analog is process stdout/stderr (raylib `TraceLog`, flecs,
    C `fprintf(stderr)`, uncaught mruby).
  - **Critical — runtime independence:** the lines worth most (aborts) are the
    ones that *kill* mruby, so a Ruby-side sink would miss them. Capture
    browser-console in **pure JS** (R4), buffer, and flush to the relay over WS
    regardless of module health. Both streams normalize to NDJSON, `source`-tagged;
    `bin/tail-log [--game|--browser]` can merge them by timestamp.
  - **Scope (deferred):** `browser-console` only exists on **web**, so it rides with
    R4 — and the capture work (in-page JS shim, and *especially* a browser
    extension) is **deferred until a real need appears** (judged low-odds). **R2
    delivers `game-console`:** the Ruby `Log` NDJSON plus tee-ing desktop process
    stdout/stderr (raylib/flecs/uncaught mruby) into the same stream.
- **Capture mruby exceptions** from the loop and from eval into game-console with
  backtraces.
- **Flecs logs:** call `ecs_log_set_level(n)` (bind it) and install a flecs
  OS-API log callback that funnels flecs's own tracing into this same pipeline, so
  ECS internals and game logs interleave with timestamps.
- **Acceptance:** an agent can answer "what errored in the last 5s and on which
  entity" purely from the NDJSON stream.

## Phase R3 — Hot-reloadable Flecs systems & features (the core ask)
Goal: **edit systems and add/modify features on a running browser game without
resetting** — entities and component data survive; only behavior swaps.

**Mechanism (the key design):** don't re-register Flecs systems on reload (that
loses identity and forces component re-lookup). Instead:
- A **system registry** keyed by name. `define_system(name, with:, phase:, &blk)`:
  - First call: registers a Flecs system whose C callback dispatches to a **stable
    Ruby dispatcher** that looks up the *current* proc by name in the registry.
  - Subsequent calls (reload): just **replace the proc** in the registry. Same
    system id, same matched tables, same entity/component state → new logic.
- `Hot.reload_string(code)` / `Hot.reload_file(path)`: re-`eval` a Ruby module of
  systems; `define_system` is **idempotent** so re-running a file just swaps procs.
- Convention so reload is clean: game code is organized into reloadable units —
  `game/components.rb`, `game/systems/*.rb`, `game/features/*.rb` — each
  re-runnable top-to-bottom without side effects beyond (re)registration.

**What survives vs what needs a reboot — document this table in `hot-reload.md`:**

| Change | Hot-reload? | Why |
|---|---|---|
| Edit a system's body / add/remove a system | ✅ swap proc | state untouched |
| Add a **new** component (new meta struct) + entities | ✅ additive | new id, no layout change |
| Change an existing component's struct layout | ⚠️ reboot (or migrate) | existing entities hold old layout |
| Add/rename a query, change phases | ✅ re-register that system | cheap |
| Change C/C++ binding, generator, build flags | ❌ reboot | native ABI / relink |
| raylib/native resource re-init (window, GPU) | ❌ reboot | native lifetime |

- **Web reboot path:** since C/C++ changes need a reboot anyway, the web flow is
  "rebuild wasm + reload page". Ruby-only changes never reboot — that's the win.
- **Acceptance:** in the browser, change a movement system's speed and add a brand
  new system while entities keep their positions; verify via the live mount that
  state persisted and behavior changed.

## Phase R4 — Agent bridge (WebSocket) + `.live/` mount
Turn R1's queue into the channel the AI and console actually use. Mirrors
`../dispatch` (WS transport + collector) and `../roblox` (`.live/` + cmd/result).

- **Web side — `web/agent-bridge.js`** (loaded by `shell.html`, dev builds only):
  - `cwrap` `jamstack_eval`; expose a WS client that connects out to the relay.
  - On `{id, code}` → push into the wasm command queue → return
    `{id, ok, result, stdout, error}`.
  - **Browser-console capture (runtime-independent; the shim is installed *first*
    in `shell.html`, before the Emscripten module script, so early `.wasm`/`.data`
    load failures are caught):** tee `console.*`, `window.onerror`,
    `unhandledrejection`, `Module.print`/`printErr`, and `Module.onAbort` → buffer
    → forward over WS as `{type:"browser-log"}`. Two completeness tiers:
    - **A (baseline, always on):** the in-page JS shim above. Catches everything
      routed through JS incl. all wasm aborts; misses a few browser-internal lines
      (some WebGL/CSP/deprecation). Works in any tab, no install; also the only
      tier that captures pre-attach / early-boot errors.
    - **B (exact) — Chrome extension via `chrome.debugger`: DEFERRED / unlikely.**
      It would attach CDP to the human's *real* tab for the literal, complete
      DevTools console (incl. the browser-internal lines A misses), but it's a lot
      of work (MV3 service worker, the "being debugged" banner, one-debugger-per-tab,
      Chrome-only) for a payoff we probably never need. Revisit only if A proves
      insufficient in practice.
    Even tier A is built only once a web console is actually wanted; until then the
    browser stream is out of scope (desktop uses process stdout/stderr).
- **Desktop side:** promote R1's raw TCP to a minimal WS server in-process
  (`mruby-socket`, non-blocking, framed), or just keep line-delimited JSON over TCP
  if simpler — same queue, same protocol shape.
- **Relay — `tools/agent-bridge/server.js`** (Bun/Node WS hub):
  - The running game connects as the **runtime**; agents/CLI and the human console
    connect as **clients**. Routes eval requests to the runtime, broadcasts logs +
    state snapshots to clients.
  - Maintains the `.live/` surface so **file-based agents** work without speaking
    WS (the `../roblox` pattern):
    Per-instance, keyed by play token (`.live/<token>/`) so parallel games don't
    collide; all writes atomic (temp + `rename`) so agents never read a half file:
    - `status.json` — connected?, target, frame, fps, entity count, token,
      uptime (cheap heartbeat).
    - `game-console` — structured `Log` NDJSON (R2): mruby/flecs/gameplay.
    - `browser-console` — the real browser DevTools stream (R2 capture); web only.
    - `state.json` — throttled world snapshot (Flecs REST JSON, Phase R5).
    - `.agent/cmd-<id>.json` → `result-<id>.json` — write-a-command,
      poll-for-result (the **only** agent-writable path).
    - `bin/*` — helper scripts: `eval`, `query <entity>`, `snapshot`,
      `tail-log [--game|--browser]`, `hot-reload <path>` (wrap the cmd/result
      protocol so an agent just runs a command).
- **`.live/` mechanism (no FUSE — unlike `../roblox`):** real files, because here a
  host-side writer always exists. **Desktop:** the game has `mruby-io`, so it writes
  `.live/` directly and scans `.agent/` for new `cmd-*` inside the R1 frame drain —
  no relay needed for file-based agents (verify `mruby-dir` for `readdir`, else add
  it or route through the relay). **Web:** the tab can't touch host disk, so the
  relay is the writer/bridge. FUSE was a `../roblox` workaround for a *sandboxed*
  runtime with no host helper; that constraint doesn't exist here, and FUSE is a
  poor fit for our WSL environment besides.
- **Security (P7):** localhost only; bridge + relay enabled by a build flag/env
  (`JAMSTACK_BRIDGE=1`); never included in a release web build.
- **Acceptance:** from a shell, `.live/bin/eval 'world.count(Position)'` returns a
  number; `.live/bin/tail-log` streams live errors; the same works against a
  browser tab.

## Phase R5 — Flecs observability (REST / Explorer / stats)
Surface Flecs's built-in debugging so the agent (and a human) get a full ECS view.
- **Bind it:** `Flecs::World#enable_rest(port: 27750)` → sets the `EcsRest`
  singleton; enable `FLECS_STATS`/`FLECS_MONITOR` for per-system timing and world
  stats; bind `ecs_log_set_level`.
- **Desktop:** `EcsRest` starts the HTTP server on `:27750` (separate thread,
  handled by flecs). Connect the **hosted Flecs Explorer** in *remote* mode
  (`flecs.dev/explorer?remote=true&host=localhost:27750`) for a full entity /
  query / stats UI — zero UI code on our side.
- **Web spike (R5a — research, do early):** flecs's `ecs_http` uses POSIX sockets
  and **cannot bind a listening port in the browser**, so the desktop REST path
  won't work in wasm. Plan: call `ecs_http_server_request()` (feed a synthetic
  request string, get the JSON reply, **no socket**) from a bound Ruby/C function,
  and ship those JSON replies over the **R4 WebSocket**. The relay re-exposes them
  on a local HTTP port so the hosted Explorer can connect to the browser game
  too. Validate that the REST module's request handler is reachable without the
  socket server thread.
- **Feed `.live/state.json`** from the same REST JSON (entities, components,
  stats) so file-based agents see structured world state.
- **Acceptance:** desktop game inspectable in the Explorer; browser game's world
  queryable as JSON through the bridge; per-system timing visible.

## Phase R6 — In-game Ruby console (RmlUi) — **DONE**
A user-facing REPL console with the same powers as the agent bridge (it shares
the `mrb_state`, so "full game state access" is free).
- ~~RmlUi panel (`game/ui/console.rml` + `.rcss`): scrollback + input, toggle key
  (e.g. backtick `` ` ``).~~ **DONE.** `Jamstack::Console` (in
  `mrbgems/rmlui/mrblib/console.rb`) manages the panel: toggle with backtick,
  Enter to eval, Up/Down for command history, auto-scroll, error backtraces.
- ~~Executes any Ruby via `Bridge`/`Console.eval`~~ — **DONE.** Uses `eval(code,
  binding)` with the game script's binding; full access to local variables and
  game state. Pretty-prints results via `inspect`, errors with class + message +
  backtrace.
- Works on desktop and web (it's just Ruby + RmlUi). **Verified on desktop**
  (eval, results, errors, history, toggle all pass). Web build compiles cleanly.
- ~~Note the **RmlUi keyboard-input gap**~~ — **CLOSED.** `rml_context_process_input`
  now forwards keys (raylib→RmlUi KI_* map), text input (`GetCharPressed`→
  `ProcessTextInput`), and modifiers. See `.agents/knowledge/rmlui-binding.md`.
- **Acceptance:** open console in the browser, type `world.each(Position){|e,p| ...}`
  and a hot-reload command; see results inline; close and keep playing.

## Phase R7 — Crystallize the new tribal knowledge — **DONE**
The runtime work generates exactly the kind of scar tissue the harness exists to
hold. Close the loop:
- ~~Knowledge docs: `agent-bridge.md`, `hot-reload.md`, `logging.md`,
  `flecs-observability.md`, `console.md`.~~ — **DONE.** All exist; `console.md`
  created with the R6 REPL console details (toggle, variable propagation,
  tab completion, caret control, key identifiers, HTML escaping).
- ~~New rules: "all eval/console/bridge commands run on the main thread"~~ —
  **DONE.** `.agents/rules/main-thread-eval.md`.
- Skills: `/agent-eval`, `/hot-reload-system`, `/inspect-state`,
  `/debug-with-logs` — deferred (low ROI; the knowledge docs cover the workflows).
- ~~Update `AGENTS.md` with "Agentic dev loop" section.~~ — **DONE.** Also
  updated the rules count (6→7) and the knowledge file table (added `console.md`).

---

## Dependency / sequencing summary

```
Part A (H0→H5)  ── can proceed in parallel with Part B; do H0–H3 first for leverage
Part B:
  R1 eval+queue ─┬─▶ R2 logging
                 ├─▶ R3 hot-reload  (needs R1)
                 └─▶ R4 bridge+.live (needs R1; consumes R2 logs)
  R5 flecs obs ──▶ feeds R4 (.live/state.json);  R5a wasm spike research early
  R6 console ────▶ needs R1 (+ RmlUi keyboard fix);  reuses R2
  R7 docs ───────▶ after each of R1–R6 lands (continuous)
```

**Suggested order:** H0–H3 → R1 → R2 → R3 → R4 → R5 + R5a → web W1 + W2 →
~~FIX flecs delete leak~~ ✅ → ~~bin-snapshot~~ ✅ → ~~ballpit yaw fix~~ ✅ →
~~H6 RBS generator~~ ✅ → ~~R7 tribal knowledge~~ ✅ → ~~H4 subagents~~ ✅ →
H5 remaining.
Next: H5 (tasks.md / HANDOFF.md cross-session convention).

## Open research questions / spikes
- **R5a (highest risk):** confirm `ecs_http_server_request()` works without the
  socket server thread in the emscripten build, and that the hosted Explorer can
  drive it through the relay. Fallback: ship raw REST JSON to the agent only (no
  Explorer UI on web).
- **WS in mruby on desktop:** is an in-process non-blocking WS server via
  `mruby-socket` worth it, or keep line-JSON over TCP and let the relay speak WS to
  clients? (Lower risk: latter.)
- **Component-layout migration:** is a "migrate on reload" path worth building, or
  is reboot-on-layout-change an acceptable permanent constraint? (Default: reboot.)
- ~~**RmlUi keyboard input** (R6 dependency)~~ — **DONE.** Gap scoped + closed:
  `rml_context_process_input` forwards keys, text input, and modifiers. See
  `.agents/knowledge/rmlui-binding.md`.
- **Snapshot cost:** how often can `.live/state.json` be regenerated from REST JSON
  without hurting frame time on large worlds? (Make it on-demand + throttled.)
- **Subagent granularity (H4):** one **game-code** subagent (summoned for any
  `game/**` edit) vs a finer split (`gameplay-ruby`, …). **Deferred** — lean toward a
  single game subagent first; revisit only if context bloat or coordination
  problems appear. The **game/engine boundary** (GLOSSARY "Code boundaries") holds
  either way, so this is just how many agents share the game side.
- **Parallel sessions vs ONE running game (R4):** the harness article's git-worktree
  parallelism assumes stateless file editing + independent test runs. Our hot-reload
  model is a **single process / single `mrb_state`** (P6). Two agents hot-reloading
  into the same game stomp each other. Plan: parallel worktrees must each spawn their
  **own** game instance (own process/port/bridge, own `.live/` dir keyed by the play
  token). Decide the per-instance `.live/` layout before R4.
- **Browser-console capture: DEFERRED.** Only matters on web; the in-page shim (A)
  is built if/when a web console is actually wanted, and the Chrome extension (B) is
  judged unlikely to be worth the effort (Playwright also rejected as too heavy).
  Until then, "console" means desktop process stdout/stderr + the Ruby `game-console`.
- **Flecs entity-delete leak (🔴 urgent):** the full 64-bit `ecs_entity_t` carries
  generation bits that flecs bumps on entity recycling; if `mrb_as_int` truncates or
  the binding strips them, `alive?`/`delete` operate on a stale id. Fix needs
  inspection of `fl_yield_iter`'s id yield, `fl_w_delete`, and `fl_w_alive` in
  `flecs_bindings.c`. (Observed: delete of 30 entities after a re-summon left 30/30
  in the query with `alive?`=false before any mruby-side delete call.)
- **Expose the bridge as an MCP server (R4):** wrap `jamstack_eval` / `query_state` /
  `tail_log` / `load_level` / `hot_reload` as MCP tools so any MCP-capable client gets
  first-class runtime access — the runtime analog of the symlink trick's
  tool-agnosticism — alongside the file-based `.live/bin/*`. Evaluate vs. raw WS.

## Non-goals (for now)
- No multi-threaded eval or background system execution (P6).
- No shipping the eval bridge in production web builds (P7).
- No hot-reload of C/C++/generator/build changes — those reboot, by design.
- No full `../dispatch` prompts/​reports orchestrator until multi-agent waves are
  routine (H5 keeps it light).
