# Tribal knowledge: raylib + raymath bindings (`Rl::`)

## At a glance
- **Key files:** generator `mrbgems/raylib/tools/gen_raylib.rb` (edit this — NOT the
  generated `src/raylib_gen.c`); hand-written entry `src/raylib_bindings.c`; sugar
  `mrblib/raylib.rb`; `mrbgem.rake`; AI-reference generator `tools/gen_ai_reference.rb`.
- **Ruby API:** generated positional surface + sugar (`while_window_open`, block
  Begin/End pairs, symbol keys, kwarg helpers). Full typed API: `docs/AI_REFERENCE.md`;
  spec `docs/API_SPEC.md`.
- **Cross-refs:** rules `dont-edit-generated`, `raylib-platform-objs`; skill `add-binding-fn`.

## How it's built (generated, not hand-written)
`mrbgems/raylib/tools/gen_raylib.rb` reads raylib's official `raylib_api.json`
(and `raymath_api.json`) and emits `mrbgems/raylib/src/raylib_gen.c` at build
time (git-ignored). To change bindings, **edit the generator**, not the output.
`mrbgem.rake` runs the generator (regen only when inputs are newer) before the
gem globs its sources. `raylib_bindings.c` is the small hand-written entry point
(platform detection + the web main-loop seam).

`raymath_api.json` is NOT shipped by raylib; `mrbgem.rake` builds raylib's
`raylib_parser` and generates it from `raymath.h` if missing.

## Naming rules (must match between generator and any docs)
- `PascalCase` → `snake_case`; `IsXxx` → `xxx?` predicate.
- snake_case splits a **digit followed by a Word**: `Vector2Add → vector2_add`,
  but keeps `Mode2D → mode2d` (digit+Upper+end, no split). This rule is subtle;
  if you touch `snake`, re-test both forms.
- String params marshal with `z!` so Ruby `nil` → C `NULL` (e.g.
  `load_shader_from_memory(nil, fs)` uses the default vertex shader).
- Structs marshal by value; a single `T*` param is in/out (pass the struct).
- **Only `Is*` gets the `?` suffix.** Other boolean predicates bind WITHOUT `?`:
  `WindowShouldClose → window_should_close` (not `window_should_close?`). `API_SPEC.md`
  documents the `?` form, so the sugar adds `alias_method :window_should_close?,
  :window_should_close` in `mrblib/raylib.rb`. The desktop seam (`while_window_open`)
  relies on that alias — without it, **desktop** loops crash with NoMethodError while
  web is unaffected (web uses `_run_web_loop`, never the `until` branch).

## ~72 unbound functions
Skipped: callbacks, raw pointer/buffer params, varargs, array/string returns.
Listed in the generated file's header comment and in `docs/AI_REFERENCE.md`.

## Hand-bound exceptions inside the generated TU
`SetShaderValue`/`SetShaderValueV` take a typeless `const void *value` + a
`SHADER_UNIFORM_*` tag, so they're hand-written and **emitted into the generated
.c** (after the struct helpers) so they can reuse the `static rl_ptr_Shader`.
They accept a Numeric or (nested) Array and pack by uniform type.

## Ruby sugar (mrblib/raylib.rb)
Layered over the positional generated API: `while_window_open` (the only loop;
web-safe seam), block-scoped Begin/End pairs (`draw`, `mode_2d`, `shader_mode`,
…, all `ensure`-safe), symbol keys (`Rl.key_down?(:w)`), kwarg helpers
(`draw_text`, `draw_texture_pro`), `Rl.platform`/`web?`/`desktop?`, aliases.

## Verifying changes
`./zig-out/bin/game some_test.rb` (main.c takes the script as argv[1]). For
visual checks, render offscreen to a PNG (see knowledge/testing.md).

## Custom shaders (post-processing / `Jamstack::FX`)
raylib does NOT prepend a `#version` line to user fragment shaders — it compiles
your string as-is (`rlLoadShader`, vendor rlgl.h ~4205). So every fragment source
must begin with the right `#version` for the backend: desktop GL33 → `#version 330`,
web ES3 → `#version 300 es` (both share `in`/`out`/`texture()` syntax, so one
shader body serves both — only the header `#version`+`precision` line differs).

When you pass `vs = nil` to `load_shader_from_memory`, raylib uses its **internal
default vertex shader**, which outputs the varying **`fragTexCoord`** (NOT
`vTexCoord`) and binds the input texture to sampler **`texture0`** — on BOTH
targets (GLSL 330: `in vec2 fragTexCoord`; GLSL 100: `varying vec2 fragTexCoord`;
verified in vendor rlgl.h `rlLoadShaderDefault` ~5000). So a fragment shader
paired with the default vertex must declare `fragTexCoord` and sample `texture0`.

The 330 (desktop) and 300 es (web) dialects share `in`/`out`, `texture()`, and
`out vec4` output — so `Jamstack::FX` (mrblib/fx.rb) uses a **macro shim**: a
per-target `HEADER` (differing only in `#version`+`precision`) defines
`TEXTURE(s,uv)`→`texture()` and `FRAG`→`fragColor`, so ONE shader body serves both
targets. (Pre-upgrade, web was `#version 100` with `varying`/`texture2D()`/
`gl_FragColor` — a separate, more divergent dialect.)

mrblib **load order** pitfall: gem mrblib files are globbed alphabetically, so
`fx.rb` loads BEFORE `raylib.rb`. The `Rl.web?` sugar (defined in raylib.rb) is
NOT yet defined at fx.rb's load time -> `HEADER = Rl.web? ? ...` raises
`NoMethodError: undefined method 'web?'`. Fix: use the underlying C fn
`Rl._is_web` (registered at gem init, always available) OR make the value lazy
(memoized on first `Pass` construction, at game runtime when all sugar is loaded).

Y-flip is mandatory on every `draw_texture_pro` of a `RenderTexture` texture
(OpenGL bottom-left origin): `source = Rectangle.new(0, 0, w, -h)`.
