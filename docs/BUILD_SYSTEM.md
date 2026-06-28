# raylib-jamstack — Build System Design

Goal: **one command per target**, desktop + web, orchestrated by a single
`build.zig`, with mruby running the game code and raylib + RmlUi linked in.

```
zig build run                         # build + run native desktop
zig build -Dtarget=wasm32-emscripten  # build web (html/js/wasm)
zig build serve                       # build web + local http server
```

---

## 1. Can Zig do this? (the user's question)

**Yes, for orchestration — with one caveat for web.**

- **Native desktop:** Zig fully self-hosts. `zig cc` compiles all C/C++ (raylib,
  RmlUi, mruby, the bindings) and `zig build-exe` links the final executable. No
  external toolchain needed beyond Zig itself. Cross-compiling desktop↔desktop
  (linux/win/mac) is free.
- **Web (wasm):** Zig can target `wasm32-emscripten`, **but it still needs the
  Emscripten SDK present.** Zig does *not* reimplement emscripten's libc, the GL→
  WebGL shim, asyncify, or the HTML/JS shell. What Zig does is **drive `emcc`** for
  the final link step. raylib's ecosystem already provides this glue: raylib-zig
  exposes an `emsdk` module (`emccStep`, `emccDefaultFlags`, `emccDefaultSettings`)
  that the `build.zig` calls. So the build is "unified under Zig," but EMSDK is a
  build dependency on the web path.

**Conclusion:** target a single `build.zig` as the entry point for both. Desktop is
pure Zig; web is Zig-orchestrated-emscripten.

> **Version pinning is mandatory.** Zig pre-1.0 breaks `build.zig` APIs between
> minors, and the working emscripten version is coupled to the raylib/zig combo
> (community reports: emsdk ~3.1.7x with zig 0.14.x). Pin Zig and emsdk versions in
> the repo and CI. Treat a known-good triple (zig, emsdk, raylib) as one unit.

---

## 2. Component build strategy

Several C/C++ bodies of code must end up in one binary, plus the Ruby game code.

| Component | Language | How it's built | Native | Web |
|-----------|----------|----------------|--------|-----|
| **raylib** | C | `make` (Wayland desktop / `PLATFORM_WEB`) | static lib | static lib, emcc-linked |
| **RmlUi**  | C++ | `cmake` (`rmlui_core`); render backend via `rlgl` | static lib | static lib (emcc) |
| **flecs**  | C | the single-file amalgamation, one `cc`/`emcc` object | `libflecs.a` | `libflecs.a` (emcc) |
| **Jolt**   | C++ | `cmake` (joltc + JoltPhysics), merged into one archive | `libjoltphysics.a` | `libjoltphysics.a` (emcc) |
| **mruby**  | C | its own `rake` + `build_config.rb` | `libmruby.a` | `libmruby.a` (emcc) |
| **bindings** (`Rl::`, `Rml::`, `Flecs::`, `Jolt::`) | C/C++ | compiled inside libmruby as mrbgems | objects | objects |
| **game**   | Ruby | loaded as source by `src/main.c` (bytecode for release) | preloaded | preloaded |

> **flecs** is the easiest dependency: the `vendor/flecs/distr/flecs.c`
> amalgamation compiles to a single object (`cc` desktop / `emcc` web) and is
> linked at the final step. The whole amalgamation (incl. the meta/reflection
> addon used for runtime components) is emscripten-aware. The web link needs
> `-sSTACK_SIZE=4MB` (flecs init/meta exceeds emscripten's 64 KB default stack).

### 2.1 mruby is the awkward one

mruby builds via its own Rake-driven `build_config.rb`, not Zig. Two integration
options:

- **(A) Drive mruby's rake from a `build.zig` system-command step.** The
  `build_config.rb` sets the compiler:
  ```ruby
  # desktop cross-build using zig as the C compiler
  MRuby::Build.new do |conf|
    conf.cc.command = "zig cc"          # (+ -target for cross)
    conf.linker.command = "zig cc"
    conf.gembox "default"
    # our mrbgems: raylib bindings, rmlui bindings
    conf.gem File.expand_path("../mrbgems/raylib", __dir__)
    conf.gem File.expand_path("../mrbgems/rmlui", __dir__)
  end

  # web build using emscripten's compiler
  MRuby::CrossBuild.new("web") do |conf|
    conf.cc.command = "emcc"
    conf.linker.command = "emcc"
    conf.host_target = nil
    # ...same gems...
  end
  ```
  `build.zig` invokes `rake` to produce `libmruby.a`, then links it.
- **(B) Vendor mruby and feed its source list to `zig build` directly.** More work
  (mruby's build generates C from Ruby/`mrbgem` rakefiles first), but removes the
  Ruby/rake dependency from the build. **Recommend (A) for the jam** — it's the
  documented path and mrbgems are how bindings get registered.

### 2.2 Bindings as mrbgems

The `Rl::`, `Rml::`, and `Flecs::` bindings are packaged as **mrbgems**
(`mrbgem.rake` + `src/*.c` + optional `mrblib/*.rb` for the Ruby-side sugar). This
is the standard mruby extension mechanism and keeps native + Ruby halves of each
binding together.

```
mrbgems/
  raylib/
    mrbgem.rake
    tools/gen_raylib.rb         # generates src/raylib_gen.c from raylib_api.json
    src/raylib_bindings.c       # hand-written entry (platform/web-loop seam)
    mrblib/raylib.rb            # Ruby: while_window_open, key sym map, blocks
  rmlui/
    mrbgem.rake
    src/rml_bindings.cpp        # C++: context/element/event/data-model + rlgl backend
    mrblib/rmlui.rb
  flecs/
    mrbgem.rake                 # just puts vendor/flecs/distr on the include path
    src/flecs_bindings.c        # C: World/Entity/Query, meta (de)serialization
    mrblib/flecs.rb             # Ruby: World/Entity/Component/Query sugar
  jolt/
    mrbgem.rake                 # puts vendor/joltc/include on the include path
    src/jolt_bindings.c         # C over the joltc C API: World/Body/Shape/raycast
    mrblib/jolt.rb              # Ruby: World/Body/Shape sugar (Rl::Vector3 in/out)
```

> **flecs and Jolt as static libs:** both are built outside mruby and linked at
> the final step (flecs = one amalgamation object; Jolt = joltc + JoltPhysics via
> CMake, **merged into one `libjoltphysics.a`** because lld won't resolve the
> `libmruby -> libjoltc -> libJolt` 3-archive chain). Jolt must be built with
> `-DINTERPROCEDURAL_OPTIMIZATION=OFF` — its default GCC `-flto` objects are
> GIMPLE bytecode that zig's lld cannot link.

> Pure-Ruby sugar (block-form `draw`/`scissor_mode`, `:w`→keycode, `Vector2#+`,
> `Texture.load` cache) lives in `mrblib/` so it's written in Ruby, not C — far less
> binding code to maintain.

---

## 3. Directory layout

```
raylib-jamstack/
  build.zig              # single entry point (native + web)
  build.zig.zon          # pins: zig deps incl. raylib(-zig), emsdk version
  build_config.rb        # mruby Build + CrossBuild("web")
  docs/
    API_SPEC.md
    API_SPEC_RMLUI.md
    API_SPEC_FLECS.md
    AI_REFERENCE.md      # whole API in one file (generated)
    BUILD_SYSTEM.md
  mrbgems/
    raylib/  rmlui/  flecs/
  vendor/                # raylib, RmlUi, flecs, mruby (git-ignored clones)
  game/
    main.rb              # entry point run by mruby
    ui/                  # .rml / .rcss / fonts
    assets/              # textures, audio
  build/
    desktop/  web/
```

---

## 4. Asset & game-code packaging

- **Desktop:** assets shipped alongside the binary (or embedded). `main.rb` is
  compiled to bytecode with `mrbc` and either embedded in the exe or loaded at start.
- **Web:** emscripten `--preload-file game/assets@assets` packs assets into the
  `.data` file; the mruby bytecode is embedded in the wasm. The HTML shell is a
  customizable template (itch.io-ready, fixed canvas, no default emscripten UI).

---

## 5. The web main-loop seam

emscripten cannot use a blocking `while`. This is why `Rl.while_window_open` (and
`ctx.frame`) are **blocks** (API_SPEC §1.1): the binding registers the block as the
emscripten main-loop callback via `emscripten_set_main_loop_arg`, while on desktop
it's a plain `while`. Game code is identical across targets. Audio on web also needs
a user gesture before `InitAudioDevice` — surface that via `Rl.audio_device_ready?`
rather than a custom platform hack.

---

## 6. RmlUi rendering under emscripten

RmlUi ships GL2/GL3 sample backends, but **raylib owns the GL context**, and on web
that context is WebGL. The render interface must be implemented against **`rlgl`**
(raylib's GL abstraction) instead of raw GL calls, so the same backend code works on
desktop GL and WebGL. This is the main bespoke C++ in the stack and the biggest
build-phase risk; prototype it early.

---

## 7. Recommended build order (implementation phase)

1. `build.zig` that compiles + links **raylib + mruby + a hello-window** (`Rl`
   only), desktop. Proves the mruby↔zig↔raylib spine.
2. Add the **web target** (emsdk via raylib-zig's `emccStep`); get the same hello
   window in a browser. Locks the hardest part (toolchain triple) early.
3. Flesh out `Rl::` mrbgem to cover API_SPEC.
4. Add **RmlUi** + the `rlgl` render backend; get a static `.rml` rendering over the
   game on both targets.
5. `Rml::` data binding + input routing.
6. Asset packaging, itch.io HTML shell, `zig build serve`.
7. Add **flecs** (`Flecs::`) — vendor the amalgamation, link `libflecs.a`,
   runtime meta components; verify on desktop + web.
8. Add **Jolt** (`Jolt::`) — vendor joltc + JoltPhysics, build/merge
   `libjoltphysics.a` (LTO off), 3D rigid bodies; verify on desktop + web.

---

## 7a. Status: web target builds and boots ✅

The Emscripten/WASM target is implemented (`build_web.sh` + `MRuby::CrossBuild('web')`):

- raylib `PLATFORM_WEB`, RmlUi (emscripten + freetype port), and a wasm mruby
  cross-build (embedding our mrbgems) link via `emcc` into
  `build/web/game.{html,js,wasm,data}` (~3.9 MB wasm), with `game/` preloaded.
- Verified under node: the wasm loads, mruby boots, runs `game/main.rb`, calls the
  `Rl` bindings, and raylib reports `Platform backend: WEB (HTML5)` with all modules
  loaded — stopping only at `glfwInit` (`window is not defined`), the browser-only
  boundary. Visual confirmation requires an actual browser (`python3 -m http.server`).
- The main-loop seam works: `Rl.while_window_open` uses `emscripten_set_main_loop`
  on web vs. a `while` on desktop, with identical game code.

Remaining web polish: a custom itch.io shell exists (`web/shell.html`); audio needs
a user-gesture before `InitAudioDevice` (surface via `Rl.audio_device_ready?`).

## 7b. Status: spine is built and runs ✅

The minimal vertical slice (steps 1–3 above, minus web/RmlUi) is implemented and
verified end-to-end:

- `zig build` links `src/main.c` + `libmruby.a` (with the `Rl::` bindings mrbgem)
  + `libraylib.a` + system GL.
- `game/main.rb` opens a window via `Rl.init_window`, runs `Rl.while_window_open`,
  draws text, and reads `Rl.key_down?(:a/:d)` — all the implemented API spec surface.
- Confirmed: mruby boots, C bindings register, raylib reports
  `PLATFORM: DESKTOP (GLFW - Wayland): Initialized successfully` at 60 fps.

See `BUILDING.md` for exact commands.

**RmlUi render-interface findings (rlgl):** getting RmlUi's indexed-triangle
geometry to render correctly through rlgl required three non-obvious fixes:

1. **Texture must be set AFTER `rlBegin`.** `rlBegin(mode)` resets the draw group's
   `textureId` to the default texture whenever the draw mode changes. Calling
   `rlSetTexture()` before `rlBegin(RL_TRIANGLES)` (the natural order, and what
   raylib's own `DrawTexture*` uses) gets wiped on the first mode switch → glyphs
   sampled the 1×1 white texture and rendered as **solid squares**. Order must be
   `rlBegin` → `rlSetTexture` → vertices → `rlEnd`.
2. **Premultiplied alpha.** RmlUi 6.x emits premultiplied-alpha vertex colours and
   textures; render with `RL_BLEND_ALPHA_PREMULTIPLY`. Do NOT premultiply the
   atlas yourself — `GenerateTexture` already supplies premultiplied RGBA.
3. **Flush per geometry.** rlgl's batch is quad-centric and pads `RL_TRIANGLES`
   runs for quad-index alignment; letting multiple glyph runs (different textures)
   accumulate corrupts geometry across draw groups (garbled/overlapping text,
   diagonal streaks). Call `rlDrawRenderBatchActive()` after each `RenderGeometry`.

A retained-mode VAO/VBO/EBO per compiled geometry would avoid #3 entirely and is
the better long-term path, but per-geometry flushing is correct and fine for a HUD.

**WSLg finding:** raylib's default **X11** GLFW backend segfaults inside Mesa's GLX
driver (`dri2GalliumConfigQueryb`) under WSLg. The fix is the **Wayland** backend
(`-D_GLFW_WAYLAND`), which initializes cleanly (llvmpipe GL 4.6). This is purely an
environment quirk; the binding chain itself was correct from the first build.

## 8. Risks / unknowns to validate

- **Zig+emsdk version drift** — pin and CI both targets (§1).
- **RmlUi-on-rlgl for WebGL** — unproven glue, prototype first (§6).
- **mruby rake invoked from build.zig** — cache `libmruby.a` so it doesn't rebuild
  every `zig build`; make it a tracked artifact with proper deps.
- **C++ (RmlUi) + emscripten exceptions/RTTI** — RmlUi may need `-fexceptions`/
  `-frtti` flags carried into the emcc link; confirm against current RmlUi.
