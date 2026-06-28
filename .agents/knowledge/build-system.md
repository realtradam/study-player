# Tribal knowledge: build system

## At a glance
- **Key files:** `build.zig` (desktop orchestrator), `build_config.rb` (mruby + the
  4 mrbgems), `rebuild.sh` (incremental), `build_web.sh` (web), each `mrbgems/*/mrbgem.rake`.
- **Commands:** `zig build` / `zig build run`; `./rebuild.sh`;
  `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh`; run `./zig-out/bin/game path.rb`.
- **Cross-refs:** rules `link-order`, `mruby-rebuild`, `lld-no-gcc-lto`,
  `raylib-platform-objs`, `wsl-toolchain`; design `docs/BUILD_SYSTEM.md`; human steps
  `BUILDING.md`; skill `build-and-verify`.

## Topology
`Ruby game code → mruby VM → Rl::/Rml::/Flecs:: bindings → raylib/RmlUi/flecs`,
linked by **Zig** (desktop) or **emscripten** (web). `src/main.c` boots mruby and
runs a script (`argv[1]`, default `game/main.rb`).

Four native libs are built separately and linked at the end:
- `build/desktop/libraylib.a` — raylib via `make` (guarded; built once).
- `vendor/rmlui/build-static/librmlui.a` — RmlUi via `cmake`, target `rmlui_core` ONLY.
- `build/desktop/libflecs.a` — flecs amalgamation, one `cc` object.
- `vendor/mruby/build/host/lib/libmruby.a` — mruby + our 3 mrbgems via `rake`
  (rebuilt every `zig build`; rake is incremental).

## Commands
- Desktop: `zig build` / `zig build run` (orchestrates all of the above).
- Incremental binding work: `./rebuild.sh` (rake libmruby + zig link).
- Web: `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh` → `build/web/game.{html,js,wasm,data}`.
- Always export the cleaned PATH first (see rules/wsl-toolchain.md).

## Why zig links GNU libstdc++ directly (build.zig)
zig 0.16's `linkSystemLibrary("stdc++")` hijacks to its own LLVM **libc++**, which
lacks the GNU libstdc++ ABI symbols RmlUi needs. So we `addObjectFile`
`/usr/lib/libstdc++.so` and `/usr/lib/libgcc_s.so.1` (the latter for
`_Unwind_Resume`: mruby is built with `MRB_USE_CXX_EXCEPTION` because a C++
mrbgem, rmlui, is present).

## mruby config (build_config.rb)
- `conf.disable_presym` — lets us add new binding method names without
  regenerating the presym table (avoids stale-symbol errors on rebuild).
- One `MRuby::Build` (host) + one `MRuby::CrossBuild('web')` guarded by
  `JAMSTACK_WEB`. Both list the same 3 gems (raylib, rmlui, flecs).
- `JAMSTACK_ROOT` is exported by the build scripts so mrbgem.rake/build_config
  resolve paths.

## Per-target raylib objects
raylib shares `.o` in `vendor/raylib/src` across platforms → see
rules/raylib-platform-objs.md. Output dirs are `build/desktop` and `build/web`.

## Gotcha index (when something breaks)
- "multiple definition" at link → stale mruby objects: `rm -rf vendor/mruby/build`.
- "undefined reference" to ecs_/Rml/raylib syms → link order or a missing native lib.
- rake tries to build `mruby`/`mirb` and fails → you ran plain `rake`; target the
  `libmruby.a` path instead.
- raylib symbols are wasm/desktop-mismatched → forgot `make clean` between targets.
