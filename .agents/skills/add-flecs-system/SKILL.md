---
name: add-flecs-system
description: Use when adding or editing a Flecs ECS component or system in game Ruby code. Covers declaring components as runtime meta structs, registering systems with the right phase, the raw-id/writeback semantics, what survives a hot-reload, and (once Part B R3 lands) the hot-reloadable system registry and live-mount verification.
---

# Add a Flecs component / system

Read `.agents/knowledge/flecs-binding.md` first. Components are **real C structs
declared at runtime** via the meta addon; values cross as Ruby Hashes.

## Steps

1. **Declare components** as meta structs:
   `pos = world.struct("Position", "{float x; float y;}")`.
   - Adding a **new** component is additive and **hot-reload safe**.
   - Changing an **existing** component's struct **layout** needs a **reboot**
     (existing entities hold the old layout) — see the hot-reload table (R3).
2. **Register a system:**
   ```ruby
   world.system("Move", with: [pos, vel], phase: Flecs::ON_UPDATE) do |id, p, v|
     p[:x] += v[:x]; p[:y] += v[:y]      # mutations to p/v are written back
   end
   ```
   - The yielded entity is a **raw Integer id** (no per-entity wrapper alloc); use
     `world.entity_for(id)` when you need entity methods. A `tag` term yields `nil`.
3. **Pick a phase** (run order per `progress`):
   `ON_LOAD → PRE_UPDATE → ON_UPDATE` (default) `→ ON_START`.
4. **Queries** for ad-hoc iteration: `world.query(pos).each { |id, p| … }` (cached,
   `Enumerable`, same writeback semantics). Build once, reuse across frames.
5. **(Part B / R3 — planned)** Define systems through the **hot-reload registry**
   (`define_system(name, with:, phase:, &blk)`) so re-running the file **swaps the
   proc** in place — same system id, same matched tables, entity/component state
   preserved. Organize reloadable units as `game/components.rb`,
   `game/systems/*.rb` re-runnable top-to-bottom.
6. **Verify:** `./zig-out/bin/game game/<scene>.rb`; confirm the same script under
   `node build/web/game.js /game/<scene>.rb` (flecs logic is identical across
   targets — validate desktop first, it's faster). (Part B) inspect entity/component
   state via the live mount.

## Cross-refs
- Knowledge: `.agents/knowledge/flecs-binding.md` · Spec: `docs/API_SPEC_FLECS.md`
- Glossary: World/Entity/Component/tag/System/phase/query
- Roadmap R3 (hot-reload) for the registry mechanism.
