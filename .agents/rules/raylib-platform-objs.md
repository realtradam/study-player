# RULE: raylib shares .o files across platforms

raylib compiles its objects in-place under `vendor/raylib/src/`, so desktop and
web builds collide. Each target's lib lives in its own dir
(`build/desktop/libraylib.a`, `build/web/libraylib.a`) and `make clean` MUST run
when switching targets. `build.zig` and `build_web.sh` already do this — don't
build raylib by hand in `vendor/raylib/src` without cleaning between targets.
