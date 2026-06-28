#!/bin/sh
# Web (Emscripten/WASM) build: produces build/web/game.{html,js,wasm,data}.
#
# Requires the Emscripten SDK. Point EMSDK_ENV at its emsdk_env.sh, e.g.:
#   EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

# Linux toolchain + user gem rake first (avoid Windows rake on /mnt/c under WSL)
CLEANPATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/c' | paste -sd:)
export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$CLEANPATH"

# Activate Emscripten
. "${EMSDK_ENV:-$HOME/emsdk/emsdk_env.sh}" >/dev/null 2>&1
command -v emcc >/dev/null || { echo "emcc not found; set EMSDK_ENV"; exit 1; }

export JAMSTACK_ROOT="$ROOT"
export JAMSTACK_WEB=1
mkdir -p "$ROOT/build/web"

# Emscripten ports needed by RmlUi (freetype) and raylib fonts.
embuilder build freetype harfbuzz >/dev/null 2>&1 || true

# 1. raylib (wasm) -> build/web/libraylib.web.a
# `make clean` first: raylib shares .o files in src/ across platforms, so clear
# any desktop objects before building the wasm objects.
# raylib 6.0: PLATFORM_WEB emits libraylib.web.a (not libraylib.a).
# GL backend = OpenGL ES 3.0 (WebGL2). GRAPHICS_API_OPENGL_ES3 auto-defines ES2
# (superset), so all ES2 blocks compile too; VAO is core in ES3 so the
# rlDrawRenderBatch VAO branch is always taken (never the client-array else).
# The PLATFORM_WEB Makefile uses `GRAPHICS ?=` so this override wins.
if [ ! -f "$ROOT/build/web/libraylib.web.a" ]; then
  make -C "$ROOT/vendor/raylib/src" clean >/dev/null 2>&1 || true
  emmake make -C "$ROOT/vendor/raylib/src" PLATFORM=PLATFORM_WEB -j4 \
    GRAPHICS=GRAPHICS_API_OPENGL_ES3 \
    RAYLIB_RELEASE_PATH="$ROOT/build/web"
fi

# 2. RmlUi (wasm) -> vendor/rmlui/build-web/librmlui.a
if [ ! -f "$ROOT/vendor/rmlui/build-web/librmlui.a" ]; then
  emcmake cmake -S "$ROOT/vendor/rmlui" -B "$ROOT/vendor/rmlui/build-web" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DRMLUI_SAMPLES=OFF -DRMLUI_LUA_BINDINGS=OFF -DRMLUI_FONT_ENGINE=freetype \
    -DCMAKE_C_FLAGS="-sUSE_FREETYPE=1" -DCMAKE_CXX_FLAGS="-sUSE_FREETYPE=1"
  cmake --build "$ROOT/vendor/rmlui/build-web" --target rmlui_core -j4
fi

# 2b. flecs (wasm) -> build/web/libflecs.a. The full amalgamation (incl. meta,
# needed for runtime component structs) is emscripten-aware; its socket code is
# guarded for wasm, so no addons need disabling.
if [ ! -f "$ROOT/build/web/libflecs.a" ]; then
  emcc -c -O2 -std=gnu99 -DNDEBUG \
    -I "$ROOT/vendor/flecs/distr" "$ROOT/vendor/flecs/distr/flecs.c" \
    -o "$ROOT/build/web/flecs.o"
  emar rcs "$ROOT/build/web/libflecs.a" "$ROOT/build/web/flecs.o"
fi

# 2c. Jolt Physics via joltc (wasm) -> build/web/libjoltphysics.a (joltc + Jolt
# merged into one archive, as for desktop). INTERPROCEDURAL_OPTIMIZATION=OFF and
# single-threaded (no -pthread) so it runs in the browser sandbox.
if [ ! -f "$ROOT/build/web/libjoltphysics.a" ]; then
  if [ ! -f "$ROOT/vendor/joltc/build-web/lib/libjoltc.a" ]; then
    emcmake cmake -S "$ROOT/vendor/joltc" -B "$ROOT/vendor/joltc/build-web" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DJPH_BUILD_SHARED=OFF \
      -DJPH_SAMPLES=OFF -DJPH_TESTS=OFF -DJPH_INSTALL=OFF \
      -DINTERPROCEDURAL_OPTIMIZATION=OFF \
      -DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF -DDEBUG_RENDERER_IN_DISTRIBUTION=OFF \
      -DPROFILER_IN_DEBUG_AND_RELEASE=OFF
    cmake --build "$ROOT/vendor/joltc/build-web" --target joltc -j4
  fi
  rm -rf "$ROOT/build/web/jolt_obj" && mkdir -p "$ROOT/build/web/jolt_obj"
  ( cd "$ROOT/build/web/jolt_obj" && \
    emar x "$ROOT/vendor/joltc/build-web/lib/libjoltc.a" && \
    emar x "$ROOT/vendor/joltc/build-web/lib/libJolt.a" && \
    emar rcs "$ROOT/build/web/libjoltphysics.a" *.o )
  rm -rf "$ROOT/build/web/jolt_obj"
fi

# 3. mruby (wasm, embeds our mrbgems) -> build/web/lib/libmruby.a
export MRUBY_CONFIG="$ROOT/build_config.rb"
( cd "$ROOT/vendor/mruby" && rake "$ROOT/vendor/mruby/build/web/lib/libmruby.a" )

# 4. Link everything into game.html
emcc "$ROOT/src/main.c" \
  "$ROOT/vendor/mruby/build/web/lib/libmruby.a" \
  "$ROOT/build/web/libraylib.web.a" \
  "$ROOT/build/web/libflecs.a" \
  "$ROOT/build/web/libjoltphysics.a" \
  "$ROOT/vendor/rmlui/build-web/librmlui.a" \
  -I "$ROOT/vendor/mruby/include" -I "$ROOT/vendor/raylib/src" \
  -I "$ROOT/vendor/flecs/distr" -I "$ROOT/vendor/joltc/include" \
  -DMRB_INT64 -fexceptions \
  -sUSE_GLFW=3 -sUSE_FREETYPE=1 -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 \
  -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=4MB \
  -sEXPORTED_FUNCTIONS=_main,_malloc,_free,_jamstack_eval,_flecs_explorer_request \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap \
  --preload-file "$ROOT/game"@/game \
  --shell-file "$ROOT/web/shell.html" \
  -o "$ROOT/build/web/game.html"

echo "OK -> build/web/game.html"
