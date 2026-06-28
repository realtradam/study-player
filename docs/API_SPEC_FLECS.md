# raylib-jamstack — Flecs (ECS) Ruby API Specification (`Flecs::`)

The optional **Entity Component System** layer.
[flecs](https://github.com/SanderMertens/flecs) is a fast C/C++ ECS. These
bindings are hand-written and modeled on flecs' official
[Lua binding](https://github.com/flecs-hub/flecs-lua): both embed flecs' C API in
a dynamically-typed scripting VM, so the same approach applies.

This follows the same design rules as `API_SPEC.md` (snake_case, `?` predicates,
`=` setters, keyword args, blocks). Using the ECS is optional — game architecture
is up to the author.

## Mental model

- **World** (`Flecs::World`) owns everything; one per game (you may have more).
- **Components** are *real C structs* declared at runtime from a **meta
  descriptor** string. Their values are (de)serialized to/from Ruby **Hashes** —
  there is no per-component Ruby class.
- **Entities** are integer ids (wrapped in `Flecs::Entity`) with components/tags.
- **Systems** are Ruby blocks that run over matching entities every `progress`.

The key design choice (from flecs-lua): components use flecs' **meta/reflection
addon**, so `world.struct("Position", "{float x; float y;}")` registers a struct
with a known memory layout, and the binding moves data between that C memory and
Ruby Hashes. This needs no C codegen per component and works identically on
desktop and web.

---

## 1. World

```ruby
world = Flecs::World.new      # wraps an ecs_world_t (freed automatically by GC)
world.progress(dt = 0.0)      # -> Boolean; advance one step, run all systems.
                              #    returns false when the world wants to quit.
```

`progress` is the ECS analogue of a frame tick. Typical integration with the
raylib loop:

```ruby
Rl.while_window_open do
  world.progress(Rl.frame_time)
  Rl.draw(clear_color: Rl::RAYWHITE) { ... }   # systems may also do the drawing
end
```

> **Single-threaded only.** Multithreaded systems (`ecs_set_threads`) are not
> exposed; `progress` runs systems on the calling thread. This is also the only
> mode valid on the wasm/web build, so behaviour is identical across targets.

---

## 2. Components (meta structs)

Declare a component from a C-struct **descriptor string**. Returns a
`Flecs::Component` (usable anywhere an id is expected).

```ruby
pos = world.struct("Position", "{float x; float y;}")
vel = world.struct("Velocity", "{float x; float y;}")
world.component(...)          # alias of struct
```

Supported member types in the descriptor:

| descriptor type            | Ruby value      |
|----------------------------|-----------------|
| `bool`                     | `true`/`false`  |
| `char`, `i8/i16/i32/i64`   | `Integer`       |
| `u8/u16/u32/u64`, `byte`   | `Integer`       |
| `uptr`, `iptr`             | `Integer`       |
| `f32` (`float`), `f64` (`double`) | `Float`  |
| `string` (`char*`)         | `String`        |
| `entity`                   | `Integer` (id)  |
| nested `{...}` struct       | nested `Hash`   |
| inline array `T[N]`         | `Array`         |

```ruby
# nested + arrays
tf = world.struct("Transform", "{ {float x; float y;} pos; float scale; }")
```

A **tag** is a dataless id (no struct):

```ruby
npc = world.tag("Npc")        # -> Flecs::Component (usable with add/remove/has?)
```

---

## 3. Entities

```ruby
e = world.entity("player")    # named (name optional)
e = world.entity              # anonymous
world.lookup("player")        # -> Flecs::Entity | nil
world.entity_for(id)          # wrap a raw id (e.g. from a system block)
```

`Flecs::Entity`:

```ruby
e.id ; e.to_i                 # the integer id
e.name ; e.name = "p2"        # get/set name
e.alive?                      # still alive?
e.delete                      # destroy

# components & tags
e.set(pos, x: 1.0, y: 2.0)    # kwargs ...
e.set(pos, {x: 1, y: 2})      # ... or an explicit Hash
e.get(pos)                    # -> {x: 1.0, y: 2.0} | nil
e.add(npc) ; e.remove(npc)    # tags or components (add with default value)
e.has?(npc)                   # -> Boolean
e.set(pos, x: 0, y: 0).add(npc)   # chainable; returns self
```

> `set`/`get`/`add`/`remove`/`has?` all accept a `Flecs::Component`, a
> `Flecs::Entity`, or a raw integer id (anything responding to `to_i`).

---

## 4. Systems

Register a system that runs every `progress` during a **phase**. The block is
invoked once per matched entity with `|entity_id, *component_hashes|`, where the
component hashes are in the order of `with:`. **Mutations to those hashes are
written back** into component memory after the block returns.

```ruby
world.system("Move", with: [pos, vel]) do |id, p, v|
  p[:x] += v[:x]
  p[:y] += v[:y]
end

world.system("Despawn", with: [pos], phase: Flecs::PRE_UPDATE) do |id, p|
  world.entity_for(id).delete if p[:y] > 1000
end
```

Phases (run in this order each `progress`):

| constant            | flecs phase   |
|---------------------|---------------|
| `Flecs::ON_LOAD`    | `EcsOnLoad`   |
| `Flecs::PRE_UPDATE` | `EcsPreUpdate`|
| `Flecs::ON_UPDATE`  | `EcsOnUpdate` (default) |
| `Flecs::ON_START`   | `EcsOnStart`  |

> The entity is passed as a raw **Integer id** (not a `Flecs::Entity`) to avoid
> allocating a wrapper per entity per frame. Wrap it with `world.entity_for(id)`
> when you need entity methods. Tag terms in `with:` yield `nil` for their slot.

---

## 5. Queries

Ad-hoc, cached queries over a set of components/tags. `Flecs::Query` is
`Enumerable`; `each` has the same `|id, *comps|` + writeback semantics as systems.

```ruby
q = world.query(pos, vel)         # build once, reuse across frames
q.each { |id, p, v| ... }

world.query(pos).each { |id, p| puts "#{id}: #{p}" }
```

---

## 6. Worked example

```ruby
world = Flecs::World.new
pos = world.struct("Position", "{float x; float y;}")
vel = world.struct("Velocity", "{float x; float y;}")

100.times do |i|
  world.entity.set(pos, x: i.to_f, y: 0.0).set(vel, x: 0.0, y: 1.0)
end

world.system("Gravity", with: [vel]) { |id, v| v[:y] += 0.5 }
world.system("Move", with: [pos, vel]) do |id, p, v|
  p[:x] += v[:x]; p[:y] += v[:y]
end

Rl.init_window(800, 600, "ecs")
Rl.while_window_open do
  world.progress(Rl.frame_time)
  Rl.draw(clear_color: Rl::BLACK) do
    world.query(pos).each { |id, p| Rl.draw_circle(p[:x].to_i, p[:y].to_i, 3, Rl::RAYWHITE) }
  end
end
```

---

## 7. Web (wasm)

flecs — including the meta/reflection addon used for components — compiles and
runs under emscripten unchanged. The only build difference is the wasm link uses
`-sSTACK_SIZE=4MB`, because flecs' init/meta needs more than emscripten's 64 KB
default stack (otherwise you get a wasm `memory access out of bounds` trap). The
API and behaviour are identical to desktop.

---

## 8. Limitations / not yet exposed

These are deliberately omitted from the first cut (the underlying C API supports
them; bind them as needed):

- Multithreaded systems / staging (`ecs_set_threads`).
- Relationships / pairs, prefabs, hierarchies (`ChildOf`, `IsA`).
- Observers (event-driven callbacks), query filter operators (`Not`, `Or`,
  optional, `inout` modifiers) — `with:` is plain "must have all" matching.
- The REST/Explorer remote UI.
- Enum/bitmask component members (structs, primitives, nested structs, and inline
  arrays are supported).
