# Tribal knowledge: hot-reloadable Flecs systems (`Flecs::Hot`) — R3

> Status: **IMPLEMENTED + verified** (R3) — `mrbgems/flecs/mrblib/hot.rb`. Verified
> desktop, both inline and live over the bridge.

## At a glance
- **Goal (the core ask):** edit a system's logic — and add new systems — on the
  **running** game without resetting; entities and component data survive, only
  behavior swaps. Drives the agentic dev loop (with R1 eval + R2 logs).
- **Key files:** `mrbgems/flecs/mrblib/hot.rb` (the registry; **new**), built on the
  existing `Flecs::World#system` (`flecs_bindings.c` `fl_w_system`/`fl_system_cb`).
- **Cross-refs:** `flecs-binding.md` (system dispatch), `agent-bridge.md` (reload
  driven live over the bridge), roadmap R3; principle P5 (mutate via reload).

## The design decision: pure-Ruby system registry (NO C change)
The flecs binding stores the Ruby block in the system's `callback_ctx`
(`fl_cb_t.blk`) and `fl_system_cb` yields the iterator to it. The block is baked in
at `ecs_system_init` time. **So instead of re-registering on reload** (which would
lose the system id and re-match tables), we register **once** with a *stable
dispatcher* block that looks up the *current* proc by name, and on reload we just
**replace the proc** in a Ruby Hash. The C system never changes — no trampoline,
no binding edit.

```
define_system("Move", with:, phase:, &blk)
  first call : @systems["Move"] = {id, with, phase, proc: blk}
               world.system("Move", with:, phase:) { |e,*c| @systems["Move"][:proc].call(e,*c) }
  reload     : @systems["Move"][:proc] = blk          # same id, same tables, same state
```

## Reload semantics
- **Same name + same `with:` + same `phase:`** → **swap the proc** (the hot path):
  identical system id, matched tables, and all entity/component data untouched.
- **`with:`/`phase:` changed** → delete the old system entity (`world._delete`) and
  re-register (new id). **Entity state still survives** — systems don't own entity
  data, so even this path keeps positions/components.
- `define_system` is **idempotent**, so re-running a `game/systems/*.rb` file
  top-to-bottom just swaps procs.

## API (planned)
```ruby
Flecs::Hot.world = world                       # once, after creating the world
Flecs::Hot.define_system("Move", with: ["Position","Velocity"]) { |e,p,v| ... }
Flecs::Hot.reload_file("game/systems/move.rb") # re-eval -> swaps procs
Flecs::Hot.reload_string(code)                 # for the bridge
Flecs::Hot.id_for("Move"); Flecs::Hot.systems  # introspection
```
`with:` accepts component ids OR string names (resolved via `world.lookup`, so reload
doesn't need to re-create components).

## What survives vs what needs a reboot
| Change | Hot-reload? | Why |
|---|---|---|
| Edit a system body / add / remove a system | ✅ swap proc | state untouched |
| Add a **new** component (new meta struct) + entities | ✅ additive | new id, no layout change |
| Change an existing component's struct **layout** | ⚠️ reboot (or migrate) | existing entities hold old layout |
| Change a system's `with:`/`phase:` | ✅ delete+recreate that system | cheap; entity data survives |
| Change C/C++ binding, generator, build flags | ❌ reboot | native ABI / relink |
| raylib/native resource re-init (window, GPU) | ❌ reboot | native lifetime |

## Acceptance
With a running world: change a movement system's speed AND add a brand-new system,
while entities keep their positions (state continues, not reset); the same works
driven live over the bridge (`Flecs::Hot.reload_string`).

## Scar tissue (verified desktop — inline + live over the bridge)
- **Same system id across a swap** — `id_for("Move")` stayed `544` before and after a
  live reload. The dispatcher block (held in flecs `callback_ctx`, kept alive by
  `mrb_gc_register` in `fl_w_system`) never changes; only the registry proc does, so
  matched tables and all entity data are untouched.
- **State continues, not reset** — live x went `80 → 6442` after swapping Move to
  `+=100/frame` (continued from 80, not 0), and a freshly-added `Tagger` set `y=42`
  on the same live entities; the loop survived.
- **Swap vs re-register** keys on `name + with + phase`. Changing `with:`/`phase:`
  deletes the old system entity and registers a new one (new id) — entity data still
  survives because systems don't own it.
- **Driving reload:** over the bridge, call `define_system` directly (it's just Ruby
  on the main thread); `reload_string`/`reload_file` are for re-evaling a whole
  systems unit. Component **names** in `with:` resolve via `world.lookup` at each
  (re)register, so reload needn't re-create components.
- **Timing:** a `define_system` sent over the bridge swaps the proc during the
  frame's drain, which runs *before* `world.progress` — so it takes effect from the
  next progress onward (same frame).
- **No C change** to the flecs binding was required — the whole point of the design.
