# GLOSSARY — raylib-jamstack

One canonical vocabulary for this repo (harness principle P4). Every doc, skill,
rule, comment, and commit message should use the **Term** column and avoid the
**Aliases to avoid** column — synonym drift is what makes an ECS + multi-binding
codebase confusing to humans and agents alike.

Terms marked **(planned)** are the agreed vocabulary for Part B of `roadmap.md`
(the agentic runtime); use them when writing that code so the names land
consistent on the first try. Everything else describes code that exists today.

## ECS (Flecs)

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **World** | `Flecs::World`; owns all entities/components/systems. One per game (more allowed). | the ECS, registry, scene, container |
| **Entity** | An integer id, wrapped in `Flecs::Entity`. Systems/queries yield the **raw Integer id** for speed; `world.entity_for(id)` wraps it. | object, actor, node, "game object" (that's a higher-level gameplay concept, not the ECS id) |
| **Component** | A real C struct declared at runtime via the meta addon; values (de)serialized to/from a Ruby **Hash**. There is no per-component Ruby class. | struct (ambiguous — see *meta descriptor* and `world.struct`), class, model, data class |
| **tag** | A dataless entity used as an id for `add`/`remove`/`has?`. | flag, marker, label, boolean component |
| **meta descriptor** | The C-struct string passed to `world.struct`, e.g. `"{float x; float y;}"`. | schema, type string, layout string |
| **System** | A Ruby block registered with `world.system(name, with:, phase:)`, run once per matched entity every `progress`. Lowercase "system" means the same thing. | callback (reserve for the C function), update fn, behaviour, script |
| **phase** | When a system runs within one `progress`: `Flecs::ON_LOAD` → `PRE_UPDATE` → `ON_UPDATE` (default) → `ON_START`. | stage (that's flecs *staging*/deferred — different), tick, step, pipeline slot |
| **query** | `world.query(*components)` — cached, `Enumerable`, `|id, *comps|` with writeback. | filter (a flecs filter is the *uncached* variant), search, view |
| **progress** | `world.progress(dt)` — advance one step, run all systems on the calling thread. | tick, step, update (fine colloquially, but the method is `progress`) |
| **writeback** | Mutating a yielded component Hash writes back into component memory after the block returns. | sync, flush, commit |
| **pair / relationship** | flecs relationship `(Relation, Target)`. **Not exposed yet.** | edge, link, parent ref |

## Bindings & build

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **binding** | The mruby-exposed API for a native lib: `Rl::`, `Rml::`, `Flecs::`, `Jolt::`. | wrapper, shim, API (too vague) |
| **mrbgem** | A packaging unit under `mrbgems/<name>/` (C/C++ in `src/`, Ruby sugar in `mrblib/`). The four are raylib, rmlui, flecs, jolt. | gem (ambiguous with RubyGems), plugin, module, library |
| **generator** | `mrbgems/raylib/tools/gen_raylib.rb`; emits `raylib_gen.c` from `raylib_api.json`. **Edit the generator, never `raylib_gen.c`.** | codegen, the script, the parser (`rlparser` is a *different* tool) |
| **amalgamation** | flecs' single-file source `vendor/flecs/distr/flecs.{c,h}` compiled to `libflecs.a`. | the flecs source, the bundle |
| **meta addon** | flecs' reflection feature enabling runtime struct declaration (powers Components). | reflection lib, RTTI |
| **gembox** | mruby's `conf.gembox 'default'` set of stock gems (gives us `mruby-eval`/`-socket`/`-io`). | gem set, bundle |
| **presym** | mruby preallocated symbols; we `disable_presym` so new binding method names don't need a regen. | symbol table |
| **libmruby.a** | The archive holding mruby **plus** all four mrbgems' objects; must link **before** the native libs. | the mruby lib (it also contains our bindings) |
| **platform seam** / **the seam** | `Rl.while_window_open` — the ONE place desktop (`until window_should_close?`) and web (`emscripten_set_main_loop`) differ. | main-loop wrapper, game loop (that's the *body* you pass it) |
| **joltc** | Amer Koleci's C wrapper around JoltPhysics that `Jolt::` binds (not JoltPhysics' C++ API directly). | jolt C API, the C++ API |
| **GCC LTO** | GIMPLE-bytecode objects that zig's **lld cannot link** (turn IPO off). Distinct from **LLVM/emcc LTO**, which is fine on web. | LTO (always say which — GCC vs LLVM) |

## Code boundaries (game vs engine)

The split is by **location + lifecycle**, NOT by language — there is engine Ruby
too. This boundary governs who-edits-what and how a change takes effect.

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **game code** | Everything under `game/**` — Ruby scripts **and** `*.rml`/`*.rcss`/assets. Loaded at runtime; **hot-reloadable** (or at worst a **reload**). Where gameplay work lives. | "the Ruby" (mrblib is Ruby too), scripts, content |
| **engine code** | The bindings (`mrbgems/**` — C/C++ **and** `mrblib/*.rb`), `src/`, the build (`build.zig`, `build_config.rb`, `build_web.sh`), `vendor/**`. Compiled into the binary; a change needs a **rebuild**. | "the C code" (it includes mrblib Ruby), the bindings (that's only a subset) |
| **mrblib** | The Ruby **sugar inside a mrbgem** (`mrbgems/*/mrblib/*.rb`). It is **engine code** — compiled into `libmruby.a`, so changing it needs a **rebuild**; it does **not** hot-reload. | game code, runtime Ruby |

## Targets

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **desktop** | The Zig-linked native build (`zig build` → `zig-out/bin/game`). | native, host (host = mruby's build name, not the target) |
| **web** / **wasm** | The emscripten build (`build_web.sh` → `build/web/game.{html,js,wasm,data}`). | emscripten target (fine), browser build |

## Change application (how an edit takes effect)

Three levels, lightest → heaviest. Use the lightest that actually applies — making
the lighter levels reach more changes is the whole point of the runtime work.
**Don't say "reboot"** — it's ambiguous; say **reload** (no compile) or **rebuild**
(compile).

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **hot-reload** | Swap **game code** behaviour on the running game — replace a System's Ruby proc, or add systems/components **additively** — with entity/component state **preserved**. No restart, no compile. **(planned — Part B R3.)** | reload, rebuild, reboot, restart |
| **reload** | Restart the **process** (desktop re-exec) / reload the **page** (web): game code re-runs from scratch, **runtime state is lost**, but **nothing is recompiled**. The fallback when a game change isn't hot-reloadable (e.g. a component **layout** change, or a non-idempotent file). | reboot, restart (be specific), hot-reload, rebuild |
| **rebuild** | Recompile + relink the **engine** (`libmruby.a` + the native libs), then reload to pick it up. Required for any **engine code** change (C/C++, the generator, build flags, **mrblib** sugar). | reboot, recompile-only (it's compile+link+reload), hot-reload, reload |

## Harness layers

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **rule** | A tiny always-read safety reflex in `.agents/rules/`. | guideline, convention doc |
| **knowledge doc** | The **single** per-area tribal doc in `.agents/knowledge/` (one per area). Opens with an **"At a glance"** orientation header (key files + API/spec pointer + cross-refs), then the deep "why it broke" detail. Read when touching that area; it doubles as the Plan-Mode brief. | feature doc (retired — folded into here), guide, README, wiki page, `docs/API_SPEC*` (that's the full spec) |
| **skill** | A codified, on-demand workflow under `.agents/skills/<name>/SKILL.md`. | macro, recipe, command (a *command* is a different tool concept) |
| **subagent** | A scoped agent (model pin + tool allowlist + brief) used to constrain risky work. | bot, worker, role |
| **the symlink trick** | `.claude → .agents` (and `CLAUDE.md → AGENTS.md`) so the harness is tool-agnostic with one source of truth. | mirror, copy |

## Agentic runtime (planned — Part B of `roadmap.md`)

| Term | Meaning | Aliases to avoid |
|---|---|---|
| **command queue** | The frame-polled queue; every agent/console/bridge command is enqueued off-frame and **drained on the main thread** before `world.progress` (P6). | task queue, event loop, message bus, job queue |
| **eval-in** / **`jamstack_eval`** | The C surface that runs queued Ruby on the **persistent** `mrb_state` and returns `{ok,result,stdout,error,backtrace}` JSON. | REPL, exec, run-string |
| **the bridge** | The dev-only eval channel (WS on web / TCP-or-WS on desktop) that the agent and console speak. | the server, the socket, the API |
| **the relay** | The Bun/Node WS hub (`tools/agent-bridge/server.js`) routing eval between the runtime and clients, and maintaining the live mount. | proxy, broker, gateway |
| **runtime** vs **client** | Over the bridge: the running game connects as the **runtime**; agents/CLI/console connect as **clients**. | host/peer, master/slave |
| **the live mount** / **`.live/`** | The read-mostly observation surface: `status.json`, `console`, `state.json`, `.agent/cmd-*/result-*`, `bin/*`. | the state dir, the API dir, the output dir |
| **NDJSON** | Newline-delimited JSON — one JSON object per line — the log/stream format (greppable, tailable). | JSON Lines (use NDJSON here), "log format" |
| **ring buffer** | In-memory last-N log entries, queryable via eval (`Log.tail`, `Log.grep`). | log cache, history buffer |
| **mutate vs observe** | P5: agents **mutate** behaviour by editing Ruby / hot-reloading (write path); they **observe** state via `.live/` + logs (read path). Keep the two paths distinct. | "read/write the game" (be specific which path) |

## Study Player (planned)

| Term | Definition | Aliases to avoid |
|---|---|---|
| **study mode** | Boolean toggle (`StudyState.study_mode`). When ON, auto-pause logic runs while playback is inside silence boundaries. | auto-pause mode, learning mode |
| **speaking portion** | A contiguous segment of meaningful audio between two silence regions; numbered 0-based. | section, segment, clip, part |
| **silence region** | A detected gap in the audio where amplitude stays below threshold for at least `min_duration`. Stored normalized (0–1). | gap, pause, quiet zone |
| **raw silence gap** | A silence interval returned by `StudyAudio.raw_silence_regions`, before the 0.25s padding is applied. | raw gap, un-shrunk silence |
| **padding zone** | The first 0.25s of a speaking portion, treated as safe headroom so auto-pause does not trigger during normal pauses. | grace period, buffer zone |
| **auto-pause** | The study-mode mechanism that pauses playback when entering or exiting a silence boundary. | auto-stop, silence break |
| **smart play** | Hold-to-override button/input that suppresses auto-pause while held. | hold play, override button |
| **section counter** | UI label showing current speaking portion and total, e.g. `"12/70"`. | portion label, counter |
| **non-blocking seek** | The `skip_auto_update` pattern: after a seek, skip N frames of current-time sampling so the audio engine catches up. | seek delay, seek cooldown |
| **seek cooldown** | The integer `PlaybackState.skip_auto_update` counter that implements non-blocking seek. | skip frames, seek settle |
