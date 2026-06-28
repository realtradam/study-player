---
name: build-and-verify
description: Use to build and verify a change end-to-end. The canonical sequence for this repo — PATH strip, incremental desktop build (with the mruby-rebuild caveat), smoke test, offscreen-render visual check, web build, and node headless smoke test. There is no unit-test harness; verification is by running scripts.
---

# Build and verify a change

Mirrors `.agents/knowledge/testing.md`. There is no unit-test harness — you verify
by running `.rb` scripts through the built binary (`main.c` runs `argv[1]`).

## Steps

1. **PATH:** strip `/mnt/c` (`.agents/rules/wsl-toolchain.md`). The build scripts
   already do this; if you call `ruby`/`rake` directly, do it yourself.
2. **Type check (Ruby/sig changes):** `./tools/check-types.sh` — runs `rbs
   validate` (sig consistency) + `steep check` (Steep project loads clean, no
   :error). Cheap, needs no build. Green on correct code; hard-fails on a broken
   `sig/*.rbs` or a Steep project-load error. (Game-code type *typos* surface as
   :information in the editor / `steep check --severity-level=information`, not
   here — see `.agents/knowledge/steep.md`.) Skip if you only touched C/C++.
3. **Desktop build:** `./rebuild.sh` (rake `libmruby.a` → `zig build`). Full build:
   `zig build`. **After adding/removing an mrbgem or flipping the C/C++ ABI:**
   `rm -rf vendor/mruby/build` first (`.agents/rules/mruby-rebuild.md`), else
   "multiple definition" link errors.
4. **Smoke test:** write a small `.rb` that `puts` results to
   `/tmp/opencode/smoke.rb`, run `./zig-out/bin/game /tmp/opencode/smoke.rb`, and
   filter the banner: pipe through `grep -vE '^(INFO|WARNING|MESA|libEGL)'`. Diff
   output against expected.
5. **Visual check (offscreen):** set `Rl::FLAG_WINDOW_HIDDEN`, draw one frame, read
   pixels back (`load_image_from_screen` / `get_image_color`, or `export_image` /
   `take_screenshot`) and assert on values (e.g. a tint × 255). Delete the PNG
   after — `*.png` is git-ignored, don't commit it.
6. **Web build:** `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh`. Switching
   desktop↔web rebuilds raylib and `make clean`s its shared `.o` files; if you ever
   build raylib by hand, clean between targets (`.agents/rules/raylib-platform-objs.md`).
7. **Web smoke:** `node build/web/game.js /game/script.rb` (windowless logic). A
   **windowed** script stopping at `glfwInit` ("window is not defined") is the
   expected browser-only boundary, not a failure. Validate flecs/logic on desktop
   first (fast), then confirm on wasm to catch stack/alignment issues.

## Cross-refs
- Knowledge: `.agents/knowledge/testing.md`, `build-system.md`, `environment.md`, `web-target.md`
- Rules: all of `.agents/rules/`
