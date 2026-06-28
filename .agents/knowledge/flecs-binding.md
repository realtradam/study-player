# Tribal knowledge: flecs / ECS bindings (`Flecs::`)

Hand-written C (`mrbgems/flecs/src/flecs_bindings.c`) + Ruby sugar
(`mrblib/flecs.rb`), modeled on flecs' Lua binding. Full spec:
`docs/API_SPEC_FLECS.md`.

## At a glance
- **Key files:** `mrbgems/flecs/src/flecs_bindings.c`; sugar `mrblib/flecs.rb`;
  `mrbgem.rake`; amalgamation `vendor/flecs/distr/flecs.{c,h}` → `libflecs.a`.
- **Ruby API:** `Flecs::World` (`entity`/`struct`/`tag`/`query`/`system`/`progress`),
  `Entity`/`Component`/`Query`. Phases `ON_LOAD → PRE_UPDATE → ON_UPDATE → ON_START`.
  Spec `docs/API_SPEC_FLECS.md`.
- **Cross-refs:** skill `add-flecs-system`; the substrate for the agentic runtime
  (roadmap Part B). No game uses it yet; REST is compiled in but not startable from
  Ruby (R5).

## Component model (the key design)
Components are real C structs declared at runtime via the **meta/reflection
addon**: `world.struct("Position", "{float x; float y;}")`. Values are
(de)serialized between the C memory and Ruby **Hashes**. We use flecs' **public**
meta API only — `ecs_meta_cursor` for writes, `EcsStruct`/`EcsPrimitive`
reflection (direct offset reads) for reads — deliberately NOT the semi-private
serialized-ops the Lua binding uses (forward-compat).

## flecs v4 API specifics (bit me during binding)
- `ecs_ensure_id(world, e, id, size)` — v4 added the trailing `size` arg (pass the
  component's `EcsComponent.size`).
- `ecs_entity_desc_t.add` is a **0-terminated `ecs_id_t*` array**, not inline.
- `ecs_ctx_free_t` is `void(*)(void*)` (no world arg); `callback_ctx`/
  `callback_ctx_free` are the per-callback slots on systems and `ecs_iter_t`.
- Field indices are **0-based** in v4 (`ecs_field_w_size(it, size, 0)`).

## Web (wasm) — the one real gotcha
The full amalgamation (incl. meta) is emscripten-aware and links cleanly. BUT
flecs' init/meta uses more stack than emscripten's 64 KB default → a too-small
stack shows up as a wasm **"memory access out of bounds"** trap. The web link
uses `-sSTACK_SIZE=4MB`. Don't try `-DFLECS_NO_HTTP/REST` — REST depends on HTTP
and it `#error`s; just build the whole amalgamation.

## API shape / limits
`Flecs::World` (entity/struct/tag/lookup/query/system/progress), `Flecs::Entity`
(set/get/add/remove/has?/...), `Flecs::Component`, `Flecs::Query` (Enumerable).
Systems/queries yield `|entity_id, *component_hashes|` (raw Integer id for speed;
`world.entity_for(id)` to wrap); mutations to the hashes are written back.
Single-threaded `progress` only (also the only mode valid on wasm). Not exposed:
relationships/pairs, prefabs, observers, query operators, multithreading.

## Entity delete leak (FIXED)
**Symptom (was):** after summon→delete→summon cycles, `world.query(comp)` yielded
entity ids whose `world.entity_for(id).alive?` was false, and `entity_for(id).delete`
did NOT reduce the query count. First-ever (generation-0) entities deleted fine —
only recycled ones leaked.

**Root cause:** flecs recycles entity ids with a bumped **generation** in the high 32
bits of the 64-bit `ecs_entity_t` (`ECS_ENTITY_MASK` is `0xFFFFFFFF`; generation lives
above it). On the **web/wasm32** build, `mrbconf.h` auto-detected `MRB_32BIT` (because
`SIZE_MAX` is 32-bit on wasm32) → `MRB_INT32` → `mrb_int` is `int32_t`, which truncated
the generation bits when ids round-tripped through `fl_yield_iter`/`fl_w_delete`/
`fl_w_alive` via `mrb_get_args("i",...)` / `mrb_int_value`. `ecs_delete`/`ecs_is_alive`
then saw a stale generation (0) and no-op'd. Desktop (x86-64) auto-detected `MRB_INT64`
so it was unaffected, but the same binding code would break on any 32-bit target.

**Fix:** force `-DMRB_INT64` in both mruby build configs (`build_config.rb`) AND on
`src/main.c` compilation (`build.zig` flags + `build_web.sh` emcc line) so `mrb_int` is
`int64_t` on **every** target — the full 64-bit entity id (generation + index) now
round-trips through the mruby boundary unchanged. This is an ABI change: `rm -rf
vendor/mruby/build` is required when first applying it (stale 32-bit objects cause
"multiple definition" / signature-mismatch link errors). Verified with a
summon/delete/summon recycle test on desktop + web (node headless).

## Build wiring
Amalgamation `vendor/flecs/distr/flecs.{c,h}` → `libflecs.a` (`cc` desktop /
`emcc` web). The gem only needs `vendor/flecs/distr` on its include path; the lib
links at the final step.
