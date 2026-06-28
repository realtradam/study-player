# raylib-jamstack

A stack for building **raylib gamejam games in Ruby**. Three core parts:

| Part | Role | In Ruby |
|------|------|---------|
| **[raylib](https://github.com/raysan5/raylib)** | graphics / audio / input | `Rl::` |
| **[mruby](https://github.com/mruby/mruby)** | the embedded Ruby that runs your game | — |
| **[RmlUi](https://github.com/mikke89/RmlUi)** | HTML/CSS UI with data binding | `Rml::` |

Write your game in Ruby; it compiles to a native desktop binary **and** to
WebAssembly for the browser, from one codebase.

```ruby
Rl.init_window(800, 450, "my game")
Rl.target_fps = 60

ui = Rml::Context.new("main")
model = ui.data_model("hud") do |m|
  m.bind(:score) { $score }      # Ruby state -> {{score}} in the RML
  m.event(:reset) { $score = 0 } # <button data-event-click="reset()">
end
ui.load_document("game/ui/hud.rml").show

Rl.while_window_open do           # desktop: while loop / web: emscripten main loop
  ui.process_input
  $score += 1
  model.dirty(:score)
  Rl.draw(clear_color: Rl::BLACK) do
    Rl.draw_text(text: "score #{$score}", x: 10, y: 10, font_size: 20, color: Rl::WHITE)
    ui.update
    ui.render                     # UI composited over the game
  end
end
```

## Prerequisites

Install these first (the bootstrap script fetches dependencies, **not** the toolchain):

- **Zig** (tested with 0.16.0) — drives the desktop build / link
- **Ruby + `rake`** (host Ruby, builds mruby) — `gem install rake`
- **A C compiler** (gcc or clang) — compiles mruby + raylib
- **OpenGL / windowing dev libs** — for the desktop GL context (on Linux: X11 and/or Wayland)
- **Emscripten SDK** — only for the web build; point `build_web.sh` at it via `EMSDK_ENV=~/emsdk/emsdk_env.sh`

> **WSL / Linux note:** strip `/mnt/c` from `PATH` first (the Windows toolchain on
> the PATH breaks native builds). See `BUILDING.md` for OS-specific detail
> (Wayland, package names) and `.agents/rules/wsl-toolchain.md`.

## Quick start

`vendor/` is git-ignored, so a fresh `git clone` ships none of the native deps.
`bin/bootstrap.sh` fetches them — it's the one-command setup (clones the 6
pinned vendors into `vendor/` + applies every `patches/*.patch`; idempotent,
safe to re-run). Then build — see **[BUILDING.md](BUILDING.md)** for full steps:

```sh
./bin/bootstrap.sh        # clones the 6 git-ignored vendored deps + applies patches/*

# desktop (raylib + RmlUi + flecs + Jolt + mruby all built and linked by zig)
zig build run                              # runs game/main.rb (RmlUi data-binding HUD)
./zig-out/bin/game game/physics_demo.rb    # 3D Jolt physics demo (SPACE: shoot, R: reset)

# web (needs the Emscripten SDK)
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh
cd build/web && python3 -m http.server 8000   # open http://localhost:8000/game.html
```

## What works

- **Comprehensive raylib + raymath bindings** — ~650 functions, all 34 structs
  (as classes with field accessors + constructors), all enums and color/numeric
  defines as constants. Generated from raylib's official `raylib_api.json` (and
  `raymath.h`) by `mrbgems/raylib/tools/gen_raylib.rb` (`Is*` -> Ruby predicates,
  structs marshal by value, single struct pointers pass inout). Vector/matrix math
  included: `Rl.vector2_add`, `Rl.vector2_normalize`, `Rl.matrix_identity`, etc.
- **Comprehensive RmlUi bindings** — `Rml::Context`, `Rml::Document`,
  `Rml::Element` (attributes, classes, style properties, queries
  `query_selector`/`get_element_by_id`/`elements_by_tag`, traversal, geometry,
  `el.on(:click) { |event| ... }`), `Rml::Event`, and the MVC **data model**
  (`m.bind`/`m.value`/`m.event`, `model.dirty`). Rendered over the game via an
  `rlgl` backend.
- **Flecs (ECS) bindings** — `Flecs::World`, runtime components from a meta
  descriptor (`world.struct("Position", "{float x; float y;}")`) (de)serialized
  to/from Ruby Hashes, entities/tags (`set`/`get`/`add`/`remove`/`has?`),
  cached `world.query(...)`, and `world.system(name, with:) { |id, *comps| ... }`
  driven by `world.progress`. Modeled on flecs' Lua binding; meta works on web too.
- **Jolt 3D physics bindings** — `Jolt::World`, reusable `Jolt::Shape`
  (box/sphere/capsule/cylinder), `Jolt::Body` (motion types, forces/impulses,
  velocities, `set_transform`), and `world.raycast`. Positions/rotations are
  `Rl::Vector3`/`Vector4` for direct use in raylib draw calls. Hand-written over
  the joltc C API; single-threaded `step` works identically on desktop and web
  (~1.1 MB added to the wasm).
- **Web**: the same game cross-compiles to wasm; the `while_window_open` loop
  becomes `emscripten_set_main_loop` transparently.
- **One build command per target**: `zig build` orchestrates the desktop build
  (raylib `make`, RmlUi `cmake`, mruby `rake`, then link); `build_web.sh` does the
  emscripten equivalent.

## How the Ruby API looks

The bindings are idiomatic Ruby, not a 1:1 C mirror: `snake_case`, `?` predicates,
`=` setters, block-scoped `Begin/End` pairs, keyword args for many-arg calls, and
C structs as classes. Full contract in **[docs/API_SPEC.md](docs/API_SPEC.md)**
(raylib), **[docs/API_SPEC_RMLUI.md](docs/API_SPEC_RMLUI.md)** (RmlUi),
**[docs/API_SPEC_FLECS.md](docs/API_SPEC_FLECS.md)** (flecs / ECS), and
**[docs/API_SPEC_JOLT.md](docs/API_SPEC_JOLT.md)** (Jolt / 3D physics).

For a complete listing of every bound call (raylib + raymath + RmlUi + flecs + Jolt)
with typed signatures, all structs / enums / constants, and an explicit list of
*unbound* functions, see **[docs/AI_REFERENCE.md](docs/AI_REFERENCE.md)** — one
self-contained file (handy for feeding to an AI agent), generated from the same
JSON/headers by `mrbgems/raylib/tools/gen_ai_reference.rb`.

## Layout

```
AGENTS.md            AI-agent constitution (read first; CLAUDE.md is a symlink)
.agents/             AI harness: rules/ (safety reflexes) + knowledge/ (tribal docs)
build.zig            desktop build (orchestrates everything)
build_web.sh         web build (emscripten)
build_config.rb      mruby build (+ web CrossBuild) with our mrbgems
src/main.c           host: boots mruby, runs game/main.rb
mrbgems/raylib/      Rl::    bindings (C primitives + mrblib Ruby sugar)
mrbgems/rmlui/       Rml::   bindings (rlgl render backend + data binding, C++)
mrbgems/flecs/       Flecs:: bindings (ECS; runtime meta components, C)
mrbgems/jolt/        Jolt::  bindings (3D physics over the joltc C API)
game/                main.rb, ui/*.rml + *.rcss, assets
web/shell.html       browser canvas shell
docs/                API specs + build-system design
vendor/              raylib, mruby, RmlUi, flecs, joltc + JoltPhysics (fetched separately)
```

This repo carries an **AI harness** (see [AGENTS.md](AGENTS.md)): a short
always-loaded constitution plus `.agents/rules/` (tiny safety reflexes) and
`.agents/knowledge/` (per-area "tribal knowledge" — the toolchain ABI quirks,
WSL/Wayland, premultiplied-alpha rendering, flecs wasm stack, etc. that you can't
infer from the code). Read the relevant files before changing the build or
bindings, and add new gotchas as you find them.

## Status / not yet done

The raylib, raymath, and RmlUi surfaces are comprehensively bound. The ~72 skipped
functions are the ones needing callbacks, raw data buffers, string/array returns,
or varargs (listed in the generated `raylib_gen.c` header); rlgl is not yet
generated. RmlUi input routing forwards mouse (keyboard/text TODO). These are the
natural next steps.

Shader uniforms are hand-bound on top of the generated surface:

```ruby
sh  = Rl.load_shader_from_memory(nil, frag_src)   # nil vs -> default vertex shader
loc = Rl.get_shader_location(sh, "tint")
Rl.set_shader_value(sh, loc, [1.0, 0.5, 0.2, 1.0], Rl::SHADER_UNIFORM_VEC4)
Rl.set_shader_value(sh, Rl.get_shader_location(sh, "gain"), 2.0, Rl::SHADER_UNIFORM_FLOAT)
# arrays of vectors for the *V form:
Rl.set_shader_value_v(sh, loc2, [[1,0,0],[0,1,0]], Rl::SHADER_UNIFORM_VEC3, 2)
```

`set_shader_value` accepts a Numeric or Array (flat or nested) and packs it into
the right C buffer based on the `SHADER_UNIFORM_*` type, raising `ArgumentError`
on component-count mismatch.
