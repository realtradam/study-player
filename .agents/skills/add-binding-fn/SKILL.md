---
name: add-binding-fn
description: Use when adding, changing, or exposing a raylib/raymath function to Ruby (the Rl:: binding). Covers editing the generator (never raylib_gen.c), the snake_case naming rule, typeless/unbound cases, the rebuild order, and regenerating the typed reference.
---

# Add a raylib binding function

The raylib binding is **generated**. You change it by editing the generator, not
the emitted C. Read `.agents/knowledge/raylib-binding.md` first.

## Steps

1. **Strip `/mnt/c` from PATH** (`.agents/rules/wsl-toolchain.md`) — or just use the
   build scripts, which do it.
2. **Find the function** in `vendor/raylib/parser/output/raylib_api.json` (or
   `raymath_api.json`). If it's a callback / raw pointer/buffer / varargs /
   array-or-string return, it's in the ~72 deliberately **unbound** set — binding
   it needs a hand-written case, not the generic path.
3. **Edit the generator** `mrbgems/raylib/tools/gen_raylib.rb`. **Never edit
   `mrbgems/raylib/src/raylib_gen.c`** — it's git-ignored and overwritten
   (`.agents/rules/dont-edit-generated.md`).
   - Naming: PascalCase → snake_case; `IsXxx` → `xxx?`. The **digit-split** rule is
     subtle: `Vector2Add → vector2_add` but `Mode2D → mode2d`. If you touch `snake`,
     re-test BOTH forms.
   - Strings marshal with `z!` (Ruby `nil` → C `NULL`); structs marshal by value; a
     lone `T*` param is in/out (pass the struct).
   - Typeless `void*` value params (like `SetShaderValue`) are **hand-written and
     emitted into the generated TU** after the struct helpers — follow that pattern.
4. **Rebuild:** `./rebuild.sh`. `mrbgem.rake` regenerates `raylib_gen.c` when the
   generator/JSON inputs are newer, then zig links. If you also touch the web
   target, `make clean` between targets (`.agents/rules/raylib-platform-objs.md`).
5. **Regenerate the typed references** (only if the public surface changed): after
   `raylib_gen.c` is rebuilt, run both:
   - `ruby mrbgems/raylib/tools/gen_ai_reference.rb` → `docs/AI_REFERENCE.md`
   - `ruby mrbgems/raylib/tools/gen_rbs.rb` → `sig/raylib.rbs` (RBS signatures for
     ruby-lsp hover/completion/signature-help).
6. **Verify:** write a smoke `.rb`, run `./zig-out/bin/game /tmp/opencode/x.rb`; for
   anything visual, offscreen-render to a PNG (`.agents/knowledge/testing.md`).

## Cross-refs
- Knowledge: `.agents/knowledge/raylib-binding.md`
- Rules: `dont-edit-generated`, `raylib-platform-objs`, `wsl-toolchain`
- Verify: skill `build-and-verify`
