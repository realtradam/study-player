# RULE: never hand-edit generated files

These are produced at build time and git-ignored — edits are overwritten:

- `mrbgems/raylib/src/raylib_gen.c`  → edit `mrbgems/raylib/tools/gen_raylib.rb`
- `vendor/raylib/parser/output/raymath_api.json` → regenerated from `raymath.h`
- `docs/AI_REFERENCE.md` → edit `mrbgems/raylib/tools/gen_ai_reference.rb`, then rerun it
- anything under `vendor/`, `build/`, `zig-out/`, `.zig-cache/`

To change raylib bindings, change the generator and rebuild.
