# Building

**Ruby game code → mruby → `Rl::` / `Rml::` / `Flecs::` bindings → raylib window**,
linked by Zig (desktop) or emscripten (web). raylib, RmlUi, flecs, and the web
target are all wired; see `docs/BUILD_SYSTEM.md` for the design.

## Prerequisites (Linux)

- Zig (tested with 0.16.0)
- Ruby + `rake` (host Ruby, to build mruby) — `gem install rake`
- A C compiler (gcc/clang) for the mruby + raylib builds
- OpenGL / windowing dev libs

## Vendored sources

These are fetched separately (git-ignored). The one-command way:

```sh
./bin/bootstrap.sh     # clones the 6 pinned vendors into vendor/ + applies patches/*
```

`bin/bootstrap.sh` is the single source of truth for the pinned versions — it
clones (skipping any present) and applies every patch in `patches/`. For
reference, the pinned versions are:

```sh
git clone --depth 1 --branch 3.3.0  https://github.com/mruby/mruby           vendor/mruby
git clone --depth 1 --branch 6.0    https://github.com/raysan5/raylib        vendor/raylib
git clone --depth 1 --branch 6.1    https://github.com/mikke89/RmlUi         vendor/rmlui
git clone --depth 1 --branch v4.1.1 https://github.com/SanderMertens/flecs   vendor/flecs
git clone --depth 1                 https://github.com/amerkoleci/joltc      vendor/joltc
git clone --depth 1 --branch v5.5.0 https://github.com/jrouwe/JoltPhysics    vendor/JoltPhysics
```

### Vendor patches

Fixes we carry against vendored deps live in `patches/` (since `vendor/` is
git-ignored). `bin/bootstrap.sh` applies them automatically; to apply by hand:

```sh
git -C vendor/raylib apply "$(pwd)/patches/raylib-6.0-web-cursorhidden.patch"
```

See `patches/README.md` for what each patch fixes. (Rebuild raylib from clean
after applying — `make -C vendor/raylib/src clean`.)

## Build steps

### 1. Build raylib (static lib)

```sh
make -C vendor/raylib/src PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC -j4
```

> **WSL / WSLg note:** the desktop build uses raylib's **SDL2** backend
> (`PLATFORM=PLATFORM_DESKTOP_SDL`), not GLFW. WSLg's X11/GLX path segfaults
> inside Mesa (`dri2GalliumConfigQueryb`), and GLFW 3.4's Wayland drag-and-drop
> crashes (glfw/glfw#2835). SDL is robust on both WSLg and real Wayland (labwc),
> so one backend covers both. It requires SDL2 dev installed system-wide:
> ```sh
> sudo pacman -S sdl2          # Arch (or sdl2-compat)
> # then just:  zig build      # build.zig handles PLATFORM=PLATFORM_DESKTOP_SDL + linking SDL2
> ```
> The web build is separate and still uses Emscripten + GLFW (`build_web.sh`).

### 1b. Build RmlUi (static lib)

```sh
cmake -S vendor/rmlui -B vendor/rmlui/build-static \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DRMLUI_SAMPLES=OFF -DRMLUI_LUA_BINDINGS=OFF -DRMLUI_FONT_ENGINE=freetype
cmake --build vendor/rmlui/build-static --target rmlui_core -j4
# -> vendor/rmlui/build-static/librmlui.a
```

> Build only the `rmlui_core` target. The `rmlui_debugger` module fails to compile
> with GCC 16 (bundled `robin_hood.h`), and we don't need it.

### 1c. Build flecs (static lib)

The single-file amalgamation compiles to one object. `zig build` / `build_web.sh`
do this automatically; manually:

```sh
mkdir -p build/desktop
cc -c -O2 -std=gnu99 -DNDEBUG -I vendor/flecs/distr vendor/flecs/distr/flecs.c \
   -o build/desktop/flecs.o
ar rcs build/desktop/libflecs.a build/desktop/flecs.o
```

### 1d. Build Jolt Physics (static lib)

`zig build` / `build_web.sh` do this automatically via CMake (joltc with a local
side-by-side JoltPhysics), then merge `libjoltc.a` + `libJolt.a` into one
`build/<target>/libjoltphysics.a`. Manually (desktop):

```sh
cmake -S vendor/joltc -B vendor/joltc/build-static \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DJPH_BUILD_SHARED=OFF \
  -DJPH_SAMPLES=OFF -DJPH_TESTS=OFF -DJPH_INSTALL=OFF \
  -DINTERPROCEDURAL_OPTIMIZATION=OFF \
  -DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF -DDEBUG_RENDERER_IN_DISTRIBUTION=OFF \
  -DPROFILER_IN_DEBUG_AND_RELEASE=OFF
cmake --build vendor/joltc/build-static --target joltc -j4
```

> **`-DINTERPROCEDURAL_OPTIMIZATION=OFF` is required.** Jolt defaults to GCC
> `-flto`, whose GIMPLE-bytecode objects zig's **lld cannot link** (every `JPH_*`
> symbol shows "undefined" despite `nm` listing them). See
> `.agents/knowledge/jolt-binding.md`.

### 2. Build mruby + the `Rl::`/`Rml::`/`Flecs::`/`Jolt::` bindings mrbgems (-> libmruby.a)

> All three mrbgems (`mrbgems/raylib`, `mrbgems/rmlui`, `mrbgems/flecs`) are listed
> in `build_config.rb`. The rmlui gem is C++, which flips mruby into C++-exception
> ABI mode — if you ever switch gems in/out, `rm -rf vendor/mruby/build` first to
> avoid stale-object "multiple definition" errors. (The flecs gem is plain C and
> only needs `vendor/flecs/distr` on its include path; `libflecs.a` is linked at
> the final step.)

```sh
cd vendor/mruby
JAMSTACK_ROOT="$(cd ../.. && pwd)" \
MRUBY_CONFIG="$(cd ../.. && pwd)/build_config.rb" \
rake "$(cd ../.. && pwd)/vendor/mruby/build/host/lib/libmruby.a"
```

> Target the `libmruby.a` file specifically. Running plain `rake` also tries to
> build mruby's own CLI tools (`mruby`, `mirb`, `mrdb`), which fail to link because
> they don't pull in raylib — we don't need them.

### 3. Build + link the game with Zig

```sh
zig build          # produces zig-out/bin/game
zig build run      # build and run (loads game/main.rb)
```

## Run

```sh
./zig-out/bin/game            # runs game/main.rb
./zig-out/bin/game some.rb    # run a different script (handy for smoke tests)
```

## Web build (Emscripten / WASM)

Requires the Emscripten SDK. Point `EMSDK_ENV` at its `emsdk_env.sh`:

```sh
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh
# -> build/web/game.{html,js,wasm,data}
```

`build_web.sh` builds raylib (`PLATFORM_WEB`), RmlUi (emscripten + the freetype
port), flecs (the amalgamation, emscripten-aware), and a wasm mruby cross-build
(`MRuby::CrossBuild('web')` in `build_config.rb`), then links them with `emcc`
and preloads `game/`.

> **flecs on web:** the meta/reflection addon (used for runtime component
> structs) compiles and runs fine under emscripten. The web link uses
> `-sSTACK_SIZE=4MB` because flecs' init/meta needs more than emscripten's 64 KB
> default stack (a too-small stack shows up as a wasm "memory access out of
> bounds" trap). Multithreaded systems are not used (single-threaded `progress`).

Serve it (browsers won't run `file://` wasm):

```sh
cd build/web && python3 -m http.server 8000   # then open http://localhost:8000/game.html
```

Notes:
- Desktop and web raylib builds share `.o` files in `vendor/raylib/src`, so each
  target's lib lives in its own dir (`build/desktop`, `build/web`) and `make clean`
  runs when (re)building a target. Switching targets recompiles raylib.
- The `Rl.while_window_open` loop is the platform seam: a `while` on desktop, and
  `emscripten_set_main_loop` on web (same game code). See `mrbgems/raylib`.

## WSL gotchas encountered

- A Windows Ruby on `/mnt/c/...` shadows the Linux `ruby`/`rake`. Strip `/mnt/c`
  entries from `PATH` when building so the Linux toolchain is used.
- `vendor/mruby/minirake` is just `exec "rake", *ARGV` — you need a real `rake`
  gem installed for the Linux Ruby.
