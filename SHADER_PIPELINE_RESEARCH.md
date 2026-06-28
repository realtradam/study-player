# Research: Dynamic Shader Pipeline for raylib-jamstack (web-first)

**Goal:** a realtime-toggleable post-processing effect chain. Effects can be
turned on/off at runtime. Web (Emscripten/WebGL) is the highest-priority target;
desktop (Zig/OpenGL 3.3) must keep working.

> ### ⚠ Critical requirements (non-negotiable — read before any design tradeoff)
> 1. **Web is the primary target, not desktop.** The pipeline MUST build and run on
>    the web build (`build_web.sh` → `game.html`). A design that only works on desktop
>    is rejected. Desktop must keep working too (no regression), but web is the bar.
> 2. **Runtime toggling MUST work on web** — every effect, in **both** the GAME stage
>    (`fx.game_shaders`) and the TOP stage (`fx.top_shaders`), toggles on/off at
>    runtime on the web build, with zero shader recompilation. Verified vector: the
>    eval bridge (`sh .live/web/bin/eval 'fx.game_shaders[0].enabled = false'`), which
>    is **browser-verified** on web today (it already returns live `Rl.get_fps`). The
>    in-game console (`\`) uses the same main-thread eval path and should toggle too
>    (verify in the browser — see Verification plan).
> 3. No C/binding changes that risk the web build. The pipeline is pure Ruby over
>    the already-bound shader API; the only web build-system change is the optional
>    ES3/WebGL2 upgrade (blocker-analyzed separately, no hard blockers).

**Status:** research complete, no code written. Recommendation at the bottom.

---

## TL;DR / Recommendation

1. **Build the pipeline as a layered, two-stage Ruby ping-pong stack** — a GAME
   stage (gameplay FX affecting the game world + in-world UI, but NOT the overlay
   HUD) and a TOP stage (complete FX affecting everything, including the HUD),
   with two RmlUi contexts (in-world UI rendered into the game layer; overlay HUD
   composited between the stages). Flow: `game+game-rmlui → game shaders → top-rmlui →
   top shaders → screen`. **No C/binding changes needed** — every required function is
   already bound (`load_shader_from_memory`, `load_render_texture`, `texture_mode`/
   `shader_mode` blocks, `set_shader_value*`, `get_shader_location`, `draw_texture_pro`,
   blend modes). Details in "Recommended architecture (Ruby)".

2. **Upgrade the web build to WebGL2 (ES3).** You said you're open to it, and it is
   the right call: it unlocks HDR/float textures (proper bloom), `#version 300 es`
   (cleaner shaders, integer/uint, loops without limits), and matches the desktop
   `#version 330` dialect closely — so a **single shader source** can serve both
   targets with only the `#version` line differing. Cost is small: recompile raylib
   with `GRAPHICS=GRAPHICS_API_OPENGL_ES3` + add `-sMAX_WEBGL_VERSION=2` to the link.
   WebGL2 is ~98% of browsers (caniuse), so dropping WebGL1 is low-risk.

3. **Toggle = skip the pass.** An effect toggled off is simply removed from (or
   short-circuited in) the per-frame chain. No shader recompilation, no GPU state
   churn beyond an FBO bind swap. Optional: a `lerp`/`mix` uniform lets an effect
   *fade* in/out rather than snap.

---

## Blockers analysis: is the WebGL2/ES3 upgrade safe for raylib?

I dug into the one known scary issue and traced it through the **local vendor
source** (raylib 5.5.0). Short answer: **no hard blockers; the upgrade is safe.**
One important flag pitfall to avoid (already flagged above) and a couple of
soft caveats.

### The known scary issue: raylib #4330 — RESOLVED, not a blocker for us
[Issue #4330](https://github.com/raysan5/raylib/issues/4330): `glVertexAttribPointer()
error client-side with WebGL 2.0 (OpenGL ES 3.0)`. Reported Sep 2024; people hit
`Cannot set properties of undefined (setting 'clientside')` and, after removing
`FULL_ES*`, `WebGL: INVALID_VALUE: vertexAttribPointer: index out of range`.

**Root cause (traced in vendor `vendor/raylib/src/rlgl.h`):** the failure is in
`rlDrawRenderBatch()` (6.0: VAO bind ~line 2992, client-array `else` ~line 3090):
```c
if (RLGL.State.ExtSupported.vao) glBindVertexArray(...);   // GOOD path
else { /* client-side glVertexAttribPointer, NO bound VAO */ } // BROKEN on WebGL w/o FULL_ES*
```
On **WebGL1/ES2 without the `GL_OES_vertex_array_object` extension**, raylib falls
to the `else` branch — client-side vertex arrays, which WebGL forbids unless
`-sFULL_ES2=1`/`-sFULL_ES3=1` (the emulation flag) is on. That branch is what
throws. **This is exactly the `FULL_ES*` trap**, not an ES3 bug.

**Why ES3 is immune:** under `GRAPHICS_API_OPENGL_ES3`, raylib sets
`RLGL.ExtSupported.vao = true` unconditionally (vendor rlgl.h, 6.0 ~line 2438,
"OpenGL ES 3.0 extensions supported by default (or it should be)") — VAO is core
in ES3/WebGL2, no extension needed. So the code **always takes the `glBindVertexArray`
branch**, never the client-array `else`. That is why the maintainer (raysan5)
**could not reproduce** when compiling raylib with `PLATFORM_WEB` +
`GRAPHICS_API_OPENGL_ES_30` and linking `-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2`
(**no** `FULL_ES*`). He closed the issue and committed
`22c77d1 "REVIEWED: WebGL2 (OpenGL ES 3.0) backend flags (PLATFORM_WEB)"`
(Oct 25 2024). That commit predates **raylib 5.5 (Nov 18 2024)** — our vendor
version — so **the fix is present**. [Source: raylib #4330 + release dates]

### "But ES3 has only 17 code paths vs 118 ES2" — not a problem
Counting `#if defined(...)` guards in the vendor rlgl.h: ES3=17, ES2=118, GL33=131.
Looks thin, but it's the correct superset pattern:
```c
// vendor rlgl.h lines 191-192 (6.0; was 188-191 in 5.5):
// OpenGL ES 3.0 uses OpenGL ES 2.0 functionality (and more)
#if defined(GRAPHICS_API_OPENGL_ES3)
    #define GRAPHICS_API_OPENGL_ES2      // <-- ES3 auto-defines ES2
#endif
```
So building with `GRAPHICS=GRAPHICS_API_OPENGL_ES3` compiles **all 118 ES2 blocks
PLUS the 17 ES3 enhancements** (float textures, MRT/blit, `<GLES3/gl3.h>`). No
function becomes a no-op. (I checked the scariest one — `rlEnableShader` is gated
`GL33 || ES2`; since ES3→ES2, it compiles fine.)

**Exact define name is `GRAPHICS_API_OPENGL_ES3`** (vendor Makefile line 260). The
issue #4330 thread references `GRAPHICS_API_OPENGL_ES_30` — that's a typo/shorthand
in the discussion; the real symbol is `GRAPHICS_API_OPENGL_ES3`. Our
`build_web.sh` override must use the latter.

### RmlUi is NOT a blocker (important — this project uses RmlUi)
The project's RmlUi render interface is `class RaylibRlgl` in
`mrbgems/rmlui/src/rml_bindings.cpp`, implemented **entirely against rlgl**
(`rlBegin(RL_TRIANGLES)` / `rlVertex2f` / `rlColor4ub` / `rlSetTexture` / `rlEnd` —
confirmed in the source). It does **not** use raw GL or its own shaders. Therefore:
- It draws through raylib's **default shader**, which is correctly `#version`'d per
  backend (verified: rlgl.h 6.0 lines 5012/5021/5029).
- It goes through `rlDrawRenderBatch` → the **VAO branch** under ES3 (not the
  client-array `else` that breaks).

So RmlUi is fully insulated from the ES2→ES3 switch. No RmlUi-side shader changes,
no separate `#version` handling for the HUD. This also means **the HUD will render
correctly under WebGL2 with no extra work** — it's the post-processing *fragment
shaders we write* that must carry their own `#version 300 es` (see the
"you must supply the `#version` line" section).

### HDR bloom is genuinely available (bonus confirmation)
Under ES3 the vendor sets `texFloat32 = true` and `texFloat16 = true`
(rlgl.h 6.0 ~lines 2441–2442), and `rlGetGlTextureFormats()` was adapted for ES3
float formats (per PR #3107 "Continuation of support for ES3/WebGL2"). So
`RGBA16F`/`RGBA32F` render targets work → real HDR bloom (bright-pass can exceed
1.0). This is the main capability win over WebGL1, and it's real, not theoretical.

### Soft caveats (not blockers; things to watch during verification)
1. **"Has not been widely tested"** — the maintainer said this verbatim about the
   ES3 backend in issue #4330 (Sep 2024). It's newer and less exercised than ES2/GL33.
   Two `// TODO` markers remain in the vendor (rlgl.h ~line 2411 "Check for
   additional OpenGL ES 3.0 supported extensions" and ~line 2424 "Support GLAD
   loader for OpenGL ES 3.0") — both about extension-checking/loader plumbing, not
   core rendering. Implication: **verify on the browser early** (see verification
   plan) rather than assuming desktop behavior carries over.
2. **Shader `#version` still your responsibility** — unchanged by the upgrade.
   raylib does not inject `#version` into user fragment shaders (rlgl.h
   `rlLoadShaderProgram` ~line 4265, which calls `rlLoadShader` ~4205 to compile your
   string as-is). Under WebGL2 you must
   write `#version 300 es\nprecision mediump float;\n`. Under desktop `#version 330`.
   (The post-pro fragment shaders we author, NOT the default shader RmlUi uses.)
3. **Don't keep `-sFULL_ES2=1`** on the upgraded link line. It's currently in
   `build_web.sh` (line 87). With ES3 it's unnecessary and, combined with confusion,
   is the exact footgun that broke #4330. Replace with `-sMIN_WEBGL_VERSION=2
   -sMAX_WEBGL_VERSION=2`. (Verify nothing in rmlui/raylib relies on client-side
   vertex arrays — unlikely, since the project uses VAO-capable paths, but check
   the first web build's console for GL errors.)
4. **Stale `libraylib.a`** — switching ES2→ES3 changes the GL backend, so
   `build/web/libraylib.a` is invalid. Delete it and let `build_web.sh` rebuild
   (its existing `make clean` guard handles the in-place `.o` collision per repo
   rule `.agents/rules/raylib-platform-objs.md`).

### Verdict
**No hard blockers.** The only way to hit #4330 is to use `-sFULL_ES3=1` (which we
won't) or to run ES2 *without* VAO support *without* `FULL_ES2` (which we're leaving
behind). The correct flag combination — `GRAPHICS=GRAPHICS_API_OPENGL_ES3` raylib +
`-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2` link, no `FULL_ES*` — is the
maintainer-blessed path and is verified present in our vendor (5.5). RmlUi rides
along for free. Recommend proceeding, with an early browser smoke test to honor the
"not widely tested" caveat.

---

## What the codebase looks like today

- **No shaders, no `RenderTexture`, no post-pro anywhere.** Confirmed by searching
  all `game/*.rb` and `mrblib/*.rb`. Every demo renders directly to the screen
  inside `Rl.draw(clear_color:) { ... }` (see `game/main.rb`, `game/physics_playground.rb`).
- **raylib 5.5.0** (vendor), built via its Makefile.
- **Desktop GL backend:** `GRAPHICS_API_OPENGL_33` → GLSL `#version 330`
  (`vendor/raylib/src/Makefile` line 237: `GRAPHICS ?= GRAPHICS_API_OPENGL_33`).
- **Web GL backend (current):** `GRAPHICS_API_OPENGL_ES2` → GLSL `#version 100`
  → **WebGL 1** (`vendor/raylib/src/Makefile` lines 257–260).
  The ES3 line is right there, commented out:
  ```
  ifeq ($(TARGET_PLATFORM),PLATFORM_WEB)
      GRAPHICS = GRAPHICS_API_OPENGL_ES2
      #GRAPHICS = GRAPHICS_API_OPENGL_ES3   # <-- opt-in for WebGL2
  endif
  ```
- **Current web link flags** (`build_web.sh` line 87): `-sFULL_ES2=1` (the ES2
  client-array *emulation* flag, not the WebGL-version selector). No `-sMAX_WEBGL_VERSION`.
- **Render loop seam:** `Rl.while_window_open do ... Rl.draw(clear_color:) { ...game
  drawing... ui.update; ui.render } end` (`game/main.rb`). The RmlUi HUD is drawn
  *inside* `Rl.draw`, after game content. (See "HUD ordering" below.)

### The shader API already exposed by the bindings (from `docs/AI_REFERENCE.md`)

| Need | Ruby call | Notes |
|------|-----------|-------|
| Load fragment shader (default vertex) | `Rl.load_shader_from_memory(nil, fs)` | `nil` vs → raylib's internal default vertex shader (correct `#version` per backend) |
| Load from file | `Rl.load_shader(vs_file, fs_file)` | files preloaded via `--preload-file game@/game` on web |
| Create framebuffer | `Rl.load_render_texture(w, h)` → `Rl::RenderTexture` | |
| Render to texture | `Rl.texture_mode(target) { ... }` | block, `ensure`-safe (mrblib) |
| Apply shader | `Rl.shader_mode(shader) { ... }` | block, `ensure`-safe (mrblib) |
| Uniform location | `Rl.get_shader_location(shader, "name")` → int | |
| Set uniform | `Rl.set_shader_value(shader, loc, value, TYPE)` | `value` = Numeric or Array; packed by `SHADER_UNIFORM_*` |
| Set sampler | `Rl.set_shader_value_texture(shader, loc, texture)` | |
| Set matrix | `Rl.set_shader_value_matrix(shader, loc, mat)` | |
| Draw textured quad | `Rl.draw_texture_pro(texture:, source:, dest:, ...)` | negative `source.height` = y-flip |
| Blend | `Rl.blend_mode(Rl::BLEND_*) { ... }` | `BLEND_ADDITIVE`, `BLEND_ALPHA_PREMULTIPLY`, etc. |
| Constants | `SHADER_UNIFORM_FLOAT/VEC2/...`, `SHADER_LOC_*`, `BLEND_*` | all in `AI_REFERENCE.md` |

**Bottom line: the entire pipeline can be implemented in Ruby (mrblib sugar + game
code). No generator edit, no C, no `rm -rf vendor/mruby/build`.**

---

## Critical raylib behavior: you must supply the `#version` line

Verified in the vendor source (`vendor/raylib/src/rlgl.h`, **raylib 6.0**). PR #5631
renamed the rlgl shader-loading functions in 6.0 (`rlLoadShaderCode`→
`rlLoadShaderProgram`, `rlCompileShader`→`rlLoadShader`) — the high-level
`raylib.h` API (`LoadShader`/`LoadShaderFromMemory`/`UnloadShader`, which our
bindings use) is **unchanged**.

- `vsCode == NULL` → `rlLoadShaderProgram()` (6.0, ~line 4265) uses raylib's
  **internal default vertex shader**, which is pre-`#version`'d for the active
  backend (`#version 330` / `#version 300 es` / `#version 100`; 6.0 lines
  5012 / 5021 / 5029).
- `fsCode != NULL` → `rlLoadShader(fsCode, GL_FRAGMENT_SHADER)` (6.0, ~line 4205)
  does `glShaderSource(id,1,&code,NULL); glCompileShader(id)` — compiles **your
  string as-is**. **raylib does NOT prepend a `#version` line** to user fragment
  shaders.

**Implication:** every fragment shader source must begin with a `#version` matching
the running backend. The Ruby loader must select the right source per target:

```ruby
GLSL_VS = Rl.web? ? "#version 300 es\n" : "#version 330\n"   # after a WebGL2 upgrade
# (current web would be "#version 100\n")
```

This is exactly why the official raylib `shaders_postprocessing.c` example keeps
parallel `glsl100/` and `glsl330/` shader folders and picks one at compile time.

---

## Update: raylib upgraded 5.5 → 6.0 (done)

The repo is now on **raylib 6.0** (vendor checkout + build fixes verified on both
desktop and web). This *strengthens* the WebGL2/ES3 recommendation above:

- **The high-level shader API is unchanged.** `LoadShader` /
  `LoadShaderFromMemory` / `SetShaderValue`(+`V`,`Matrix`,`Texture`) /
  `GetShaderLocation` / `UnloadShader` all survived the 6.0 "REDESIGNED shader
  loading API" (#5631) — that refactor was `rlgl`-internal (`rl*` functions)
  only. Bindings regenerated clean (671/746 fns bound, 75 unbound). So the
  pipeline plan needs no change for 6.0.
- **6.0 ships the WebGL2/ES3 bug fixes we wanted.** The changelog lands:
  `[rlgl] REVIEWED: rlActiveDrawBuffers, fix for OpenGL ES 3.0 (#4605)` (MRT on
  ES3) and `[rlgl] REVIEWED: rlLoadTextureDepth(), address inconsistencies with
  WebGL 2.0 for sized depth formats (#5500)` (depth textures on WebGL2). These
  make the ES3/WebGL2 upgrade in the "WebGL1 vs WebGL2" section **more robust**
  than it would have been on 5.5. The 5.5 `RLGL_RENDER_TEXTURES_HINT` define is
  also gone (FBOs always-on now) — one less thing to set.
- **`GRAPHICS_API_OPENGL_ES3` + `GRAPHICS_API_OPENGL_ES2` superset still holds.**
  6.0's `rlgl.h` still does `#if defined(ES3) #define ES2 #endif`, so defining
  `GRAPHICS=GRAPHICS_API_OPENGL_ES3` still compiles all ES2 blocks + the ES3
  extras (float textures, MRT/blit). The PLATFORM_WEB `GRAPHICS` Makefile line is
  now `?=` (conditional) — the ES3 override is even cleaner than 5.5's `=`.

Upgrade scar tissue (what broke + how we fixed it) is in
`.agents/knowledge/web-target.md` ("raylib 6.0 upgrade"). Short version: three
build-code fixes (parser relocated `parser/`→`tools/rlparser/`; `libraylib.a`→
`libraylib.web.a`; tolerant loader for 6.0's malformed shipped `raylib_api.json`)
plus one vendored patch for a 6.0 web regression (`IsCursorHidden()` stopped
reflecting pointer-lock — broke mouse-look). None of these affect the shader
pipeline; they're build/input-layer only.

---

## The canonical pattern: ping-pong render-to-texture

From the official raylib `examples/shaders/shaders_postprocessing.c` (single-effect
variant) and the Meatcorps/nCine write-ups (multi-effect stack variant):

**Single pass (raylib official):**
```
BeginTextureMode(target);      // render scene → RenderTexture
  ClearBackground(...); BeginMode3D(cam); <draw scene>; EndMode3D();
EndTextureMode();
BeginDrawing();
  BeginShaderMode(shaders[current]);
    DrawTextureRec(target.texture, {0,0,w,-h}, {0,0}, WHITE);  // NOTE the -h: y-flip
  EndShaderMode();
  <draw HUD/text>;
EndDrawing();
```

**Multi-pass stack (toggleable chain) — the architecture we want:**
1. Render the **scene** into `targetA` (`BeginTextureMode(targetA) ... EndTextureMode`).
2. For each **enabled** effect shader `E_i` (in order):
   - `BeginTextureMode(targetB)`; `BeginShaderMode(E_i)`;
     set E_i's uniforms (resolution, time, intensity, the *previous* texture as
     `texture0`, the *original* scene texture if E_i needs it — e.g. bloom composite);
     `DrawTextureRec(prev.texture, {0,0,w,-h}, {0,0}, WHITE)`;
     `EndShaderMode`; `EndTextureMode`.
   - Swap `targetA ↔ targetB`; `prev = targetB`.
3. Draw `prev.texture` to the **screen** (y-flipped) — the final composited image.
4. Draw the HUD (RmlUi) **on top**, un-post-processed.

Key facts confirmed across sources:
- **Y-flip is mandatory** on every `DrawTextureRec`/`draw_texture_pro` of a
  `RenderTexture` (OpenGL bottom-left origin). Use negative `source.height`
  (`{0, 0, w, -h}`). [Source: raylib official example + Meatcorps]
- **Two `RenderTexture`s are enough** for any-length chain (ping-pong). Allocate
  once; do NOT create/destroy per frame. [Source: Meatcorps `PostProcessingRenderer`]
- **Some effects need the original scene** (not just the current ping-pong
  result) — e.g. bloom *composite* blends blurred-bright over the original image.
  Meatcorps models this with an `INeedsCurrentViewTexture` interface. In Ruby this
  is just "pass the original `scene` texture as a second sampler". [Source: Meatcorps]
- **Resolution:** render targets should match the window/internal resolution.
  For a pixel-perfect/retro look, render to a fixed small target (e.g. 640×360)
  and upscale — Meatcorps recommends this. [Source: Meatcorps]

---

## WebGL1 vs WebGL2 — the decision

### Current state (WebGL1 / ES2 / GLSL `#version 100`)
What WebGL1 gives you: the basics. `texture2D`, `varying`/`attribute`, `gl_FragColor`,
no `in`/`out`, limited loop bounds, **no float render targets** (no `EXT_color_buffer_float`;
half-float is patchy), **no MRT** (no deferred shading / multi-output G-buffer), no
3D textures, no transform feedback. raylib's default-webgl target.

What that means for the pipeline: a toggleable FX chain **works fine** on WebGL1.
Grayscale, scanlines, blur, CRT, fisheye, posterize, sobel — all run on `#version 100`
(raylib ships `glsl100/` versions of all of them). The one notable casualty is
**true HDR bloom**: WebGL1 can't render to a float/half-float buffer, so bright-pass
accumulation clamps to [0,1] — bloom still *looks* okay but can't exceed white.

### Upgraded state (WebGL2 / ES3 / GLSL `#version 300 es`)
What WebGL2 adds that matters for shaders:
- **Float/half-float render targets** (`RGBA16F`/`RGBA32F` color-buffer-float is core) →
  real HDR pipeline, bloom that can exceed 1.0. **This is the main win.**
- **Multiple Render Targets (MRT)** (`glDrawBuffers`, up to 4) → deferred rendering
  G-buffer possible. Not needed for a post-pro *stack*, but nice if you ever want
  deferred lights.
- **GLSL ES 3.00**: `in`/`out`, `texture()`/`textureGrad()`, integers, uint, uniform
  blocks, `flat`/`smooth` interpolation, **loop bounds are not limited** (WebGL1
  requires constant-foldable loop bounds). Syntax is a near-subset of desktop GLSL 330.
- **3D textures**, instancing, transform feedback (compute-via-SSBO still needs
  WebGL2 *compute*, which is separate; raylib has a `rlgl_compute` example but it's
  GL4.3-only, not web).

WebGL2 browser support: ~98% globally (caniuse "webgl2"). Dropping WebGL1 is low-risk
in 2026. The main exception is very old mobile Safari (<15) and some legacy enterprise
edge cases.

### The honest engineering call
- A toggleable post-pro stack is **not blocked** by WebGL1. You can ship it today.
- But since you're open to the upgrade and care about "capable shaders": **WebGL2 is
  worth it** for HDR bloom alone, and it makes the desktop/web shader dialect
  gap smaller (`300 es` vs `330` differ mainly in the `#version` line + `precision`
  qualifier). One near-shared source per effect instead of a `glsl100`↔`glsl330` chasm.

### Exactly how to upgrade the web build (verified)
Two changes, both in `build_web.sh`:

**1. Recompile raylib for ES3** — override `GRAPHICS` on the raylib `make` line
(raylib's Makefile uses a simple `=` assignment for `PLATFORM_WEB`, so a make
command-line var overrides it):
```sh
emmake make -C "$ROOT/vendor/raylib/src" PLATFORM=PLATFORM_WEB \
  GRAPHICS=GRAPHICS_API_OPENGL_ES3 \
  RAYLIB_RELEASE_PATH="$ROOT/build/web"
```
**You MUST `make clean` first** — raylib shares `.o` across platforms
(repo rule `.agents/rules/raylib-platform-objs.md`; the existing `build_web.sh`
already does `make clean` before the first web build). Because the GL backend
changed, the cached `libraylib.a` is invalid: delete `build/web/libraylib.a`
and let it rebuild.

**2. Link for WebGL2** — replace `-sFULL_ES2=1` with the WebGL-version selectors.
raylib's own `examples/Makefile.Web` uses (for `BUILD_WEB_WEBGL2=TRUE`):
```sh
-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2
```
(`-sMAX_WEBGL_VERSION=2` alone = allow WebGL2 but fall back to WebGL1;
 both = WebGL2-only, smaller code, no fallback.)

**DO NOT use `-sFULL_ES3=1`.** That flag enables Emscripten's *client-side array
emulation* for ES3 — an orthogonal feature to the WebGL version. Mixing
`-sFULL_ES3=1` with a raylib that isn't ES3-compiled leaves the GL context
uninitialized at draw time (confirmed by Wavedash's raylib guide). The
WebGL-friendly subset (no `FULL_ES*` flags) is what Emscripten recommends and
what raylib expects.

### Where this intersects repo rules
- `.agents/rules/raylib-platform-objs.md`: `make clean` between desktop/web already
  happens; after switching ES2→ES3 you must also delete the stale `build/web/libraylib.a`.
- `.agents/knowledge/web-target.md`: the `-sFULL_ES2=1` line is documented there as a
  current emcc flag — that knowledge doc will need updating post-upgrade.
- Desktop is unaffected: it stays `GRAPHICS_API_OPENGL_33` (`#version 330`).

---

## Recommended architecture (Ruby) — layered, two-stage pipeline

A small `Jamstack::FX` module in `mrblib/` (pure Ruby, no C) plus a `game/shaders/`
folder of `.fs` sources.

### The layering model (the key design decision)

The pipeline is **two shader stages over three render layers**, so you can choose
*per effect* whether it touches only the game world or the whole frame (game + UI):

```
  ┌─ GAME LAYER ──────────────────────────────────────────────┐
  │  3D world  +  in-world RmlUi (3D / CSS-3D panels)          │   → RenderTexture G
  └───────────────────────────┬──────────────────────────────┘
                              ▼
   ◆ GAME SHADERS  (gameplay FX — bloom/CRT/scanlines…)         ◆ affects game +
   ping-pong chain on G                                        ◆ in-world UI, NOT the overlay
                              ▼
  ┌─ OVERLAY LAYER ───────────────────────────────────────────┐
  │  processed-game quad  +  overlay RmlUi HUD (screen-space)  │   → RenderTexture C
  └───────────────────────────┬──────────────────────────────┘
                              ▼
   ◆ TOP SHADERS   (complete FX — final color grade, vignette, ◆ affects EVERYTHING
   ping-pong chain on C                film grain, letterbox…)  ◆ (game + all UI)
                              ▼
                            screen
```

This is exactly the flow requested: `game + game-rmlui → game shader → top-rmlui → top shaders`.
- **Game shaders** = "gameplay" effects that must NOT touch the overlay HUD (e.g. a
  bloom you only want on the world; a CRT/scanline effect that would wreck HUD text).
  They run on the game layer *before* the overlay is composited.
- **Top shaders** = "complete" effects that affect both game and UI (e.g. a final
  color grade, vignette, film grain, or letterbox you want over the whole frame
  including HUD). They run *after* the overlay is composited.
- Assign each effect to a stage: `fx.game_shaders << …` vs `fx.top_shaders << …`.

> Supersedes the earlier simpler "scene → one chain → screen, HUD on top unfiltered"
> sketch. That's now just the degenerate case (no game shaders, no top shaders, HUD in
> the overlay layer). Degenerate cases are handled: no game shaders ⇒ game layer
> composites straight through; no top shaders ⇒ composite blits straight to screen.

### Render targets & FBO flow (per frame, all allocated once)
Four `RenderTexture`s: `G_a`/`G_b` (game-stage ping-pong) and `C_a`/`C_b`
(composite/top-stage ping-pong). `G_a` needs a depth attachment (3D world uses
depth); `load_render_texture` creates color+depth by default, so that's automatic.

```
 1. GAME RENDER     → texture_mode(G_a){ clear; begin_mode3d(cam){world} end;
                                       game_ui.update; game_ui.render }   # in-world UI INTO G_a
 2. GAME SHADERS    → ping-pong enabled game_shaders over G_a↔G_b → G_final
 3. COMPOSITE       → texture_mode(C_a){ clear; draw_texture_pro(G_final, y-flip);
                                       top_ui.update; top_ui.render }    # overlay HUD INTO C_a
 4. TOP SHADERS     → ping-pong enabled top_shaders over C_a↔C_b → C_final
 5. SCREEN BLIT     → draw{ draw_texture_pro(C_final, y-flip) }
```

Step 3 is the load-bearing one: the overlay HUD is rendered **into the same FBO as
the processed-game quad** (one `texture_mode` block — draw the game quad first, then
the HUD on top, in screen-space 2D) so the top shaders can filter both together.

### Two RmlUi contexts (in-world UI vs overlay)
RmlUi supports multiple named contexts, so model the two UI layers directly:
```ruby
game_ui = Rml::Context.new("game")     # in-world UI → rendered into the GAME layer (G)
top_ui  = Rml::Context.new("overlay")  # screen-space HUD → rendered into the OVERLAY layer (C)
```
- **In-world UI (`game_ui`)** is part of the GAME layer, so it catches game shaders.
  Two sub-cases the pipeline must allow (the `game_layer` block is just "draw into
  `G_a`", so the game code picks):
  - *CSS-3D panels* (the existing `physics_playground` style: `transform: perspective()
    rotate3d()` on RmlUi elements) — render `game_ui` straight into `G_a` after the 3D pass.
  - *True world-space UI* — render `game_ui` to its own offscreen texture, then draw that
    texture on a 3D quad inside `begin_mode3d(cam)`. The pipeline doesn't special-case
    this; the game code does it inside the `game_layer` block.
- **Overlay UI (`top_ui`)** is screen-space, composited in step 3, catches only top shaders.
- **Input routing** (which context gets mouse/keys) is a game concern, not the pipeline's
  — typically route to `top_ui` first (topmost), then `game_ui`. The pipeline only owns
  *where each context renders*, not input.

### API sketch (block idiom, matches the codebase's `Rl.draw { }` / `Rl.texture_mode { }`)
```ruby
module Jamstack
  module FX
    class Pass                          # unchanged: name + frag src + enabled/intensity/uniforms
      attr_accessor :enabled, :intensity
      def initialize(name, frag_src); ...; end   # load_shader_from_memory(nil, HDR+frag_src)
      def apply(src_tex, dst_tex, t); end         # texture_mode(dst){ shader_mode(self){ set uniforms;
                                                   #   draw_texture_pro(src_tex, y-flip) } }
    end

    class Pipeline
      attr_reader :game_shaders, :top_shaders
      def initialize(w, h)
        @w,@h = w,h
        @g = [Rl.load_render_texture(w,h), Rl.load_render_texture(w,h)]   # game ping-pong
        @c = [Rl.load_render_texture(w,h), Rl.load_render_texture(w,h)]   # composite ping-pong
        @game_shaders, @top_shaders = [], []
      end
      def frame(t)
        yield Frame.new(self, t)    # user fills game_layer{ } + overlay_layer{ }
        blit_to_screen              # top stage result → screen, y-flipped
      end
    end

    class Frame                        # a per-frame builder the block receives
      def game_layer                   # → render 3D world + in-world UI here
        Rl.texture_mode(@p.g[0]) { yield }            # user draws game+game_rmlui into G_a
        @g_final = apply_chain(@p.game_shaders, @p.g)  # ping-pong → G_final
        # composite G_final into C_a, ready for the overlay:
        Rl.begin_texture_mode(@p.c[0])
        Rl.clear_background(Rl::BLACK)
        Rl.draw_texture_pro(texture: @g_final.texture,
          source: Rl::Rectangle.new(0,0,@p.w,-@p.h), dest: FULLSCREEN, tint: Rl::WHITE)
      end
      def overlay_layer                # → render overlay HUD here (G_final already composited)
        yield                          # top_ui.update; top_ui.render  (still inside texture_mode(C_a))
        Rl.end_texture_mode
        @c_final = apply_chain(@p.top_shaders, @p.c)   # ping-pong → C_final
      end
    end

    # shared: run enabled passes ping-pong over a [a,b] pair, return the last-written target
    def self.apply_chain(passes, pair)
      prev = pair[0]
      cur  = pair[1]
      done = passes.select(&:enabled)
      return prev if done.empty?          # no enabled passes: pass-through (no copy)
      done.each do |p|
        p.apply(prev.texture, cur, @t)
        prev, cur = cur, prev             # swap
      end
      prev                                # last target written
    end
  end
end
```

Usage in a game:
```ruby
fx = Jamstack::FX::Pipeline.new(720, 720)
fx.game_shaders << Jamstack::FX::Pass.new("bloom",  BLOOM_FRAG)    # gameplay: game+in-world UI only
fx.game_shaders << Jamstack::FX::Pass.new("crt",    CRT_FRAG)
fx.top_shaders  << Jamstack::FX::Pass.new("grade",   GRADE_FRAG)   # complete: over everything
fx.top_shaders  << Jamstack::FX::Pass.new("vignette",VIGNETTE_FRAG)

Rl.while_window_open do
  # ... update (route input to top_ui then game_ui) ...
  fx.frame(Rl.time) do |f|
    f.game_layer do
      Rl.clear_background(Rl::BLACK)
      Rl.begin_mode3d(cam) { <draw world> }
      Rl.end_mode3d
      game_ui.update; game_ui.render          # in-world UI → into the game layer (catches game FX)
    end
    f.overlay_layer do
      top_ui.update; top_ui.render           # overlay HUD → catches only top FX
    end
  end
end
```

(Toggle per effect at runtime: `fx.game_shaders[0].enabled = !…` or `fx.top_shaders[1].enabled`
from the in-game console (`\`) / eval bridge; animate `intensity` 0↔1 for a fade.)

### Possible extension (not in the requested diagram)
A third, *world-only* stage (shaders that affect the 3D world but NOT the in-world UI —
e.g. blur the world but keep UI text crisp) would need an extra target: render world →
world-shaders → then composite in-world UI on top → game-shaders. Adds one render-texture
pair + one chain. Deliberately NOT in the design above (the requested flow groups
`game+game-rmlui` before `game shader`); add it only if a concrete effect needs it.

### Shader source strategy (one of)
- **A. Per-target version folders** (`game/shaders/glsl330/`, `glsl300es/`) like
  raylib; pick at load time via `Rl.web?`. Most explicit, most duplicated.
- **B. One source + a tiny version shim**: store the *body* (no `#version`/`precision`)
  and prepend the right header in Ruby:
  ```ruby
  HDR = Rl.web? ? "#version 300 es\nprecision mediump float;\n" : "#version 330\n"
  shader = Rl.load_shader_from_memory(nil, HDR + BODY)
  ```
  After a WebGL2 upgrade, `300 es` and `330` share enough syntax (both `in`/`out`,
  `texture()`, integers) that **one BODY** usually serves both. This is the
  lowest-maintenance option and pairs naturally with inline shader strings (no
  file I/O, trivially hot-reloadable).
- **C. Inline strings** (no files at all) — simplest for a dynamic toggleable system,
  works on web without `--preload-file` changes, easy to reload via the bridge.

**Recommend B + C combined**: keep effect bodies as Ruby heredoc constants, prepend
the version header per target. Keeps the pipeline in one language, no new asset
pipeline.

### Layer & HUD ordering (important, easy to get wrong)
The layering model above replaces the old "HUD on top, unfiltered" rule. With two
stages you now choose, per effect, where the HUD sits relative to it:
- **In-world UI** renders into the **game layer** (`G_a`, inside `game_layer`), so it
  is composited *before* game shaders and catches them. (The existing `physics_playground`
  CSS-3D HUD panels become this layer.)
- **Overlay HUD** renders into the **overlay layer** (`C_a`, inside `overlay_layer`),
  composited *after* game shaders but *before* top shaders — so it's shielded from
  game shaders (text stays crisp through bloom/CRT) but still catches top shaders
  (color grade/vignette apply over it).
- The single FBO invariant for compositing: draw the processed-game quad into `C_a`
  **first**, then the overlay HUD on top, in the same `texture_mode(C_a)` block —
  top shaders can then filter both together. Do NOT render the HUD to the screen
  directly (it would bypass the top-shader stage).
- RmlUi renders via rlgl into whatever FBO is bound, so `texture_mode { rmlui.render }`
  works in both layers — but the RmlUi **context dimensions must equal the render-texture
  size** (viewport/scissor are set from them), and a 3D-world target needs the
  depth attachment `load_render_texture` provides by default.

### Performance notes (web)
- Allocate the four `RenderTexture`s (`G_a/G_b`, `C_a/C_b`) **once**; never in the
  loop (FBO creation is expensive and leaks). [Emscripten WebGL best practices:
  "prefer multiple immutable/static FBOs"]
- Minimize `glBindFramebuffer` switches — each ping-pong pass is one bind; the
  composite is one extra. [Emscripten]
- `SetTextureFilter(target.texture, TEXTURE_FILTER_BILINEAR)` if you upscale a
  small internal-res target to a bigger window.
- Render-target format: `RGBA8` for LDR; `RGBA16F` (WebGL2 only) for HDR bloom.
- Each pass is one fullscreen textured quad → one draw call. A 4–6 effect chain is
  cheap; the cost is the extra texture samples (blur is the heaviest).
- Cost of the two-stage split vs one chain: one extra fullscreen draw (the composite
  quad) + one extra FBO pair. Negligible next to the shader passes themselves.
- `BeginShaderMode`/`EndShaderMode` set shader uniform state each pass — cache
  `get_shader_location` results at load time (the `Pass` ctor), don't query per frame.

---

## Verification plan (how to prove it works) — web is the bar
> The critical requirements (top of doc) gate this: the pipeline + runtime
> toggling MUST run on the web build. Verify web explicitly, not just desktop.

1. **Desktop first** (fastest iteration, `#version 330`):
   `./rebuild.sh && ./zig-out/bin/game game/fx_demo.rb`. Proves the layered
   two-stage flow + both shader stages render. (Desktop is a sanity proxy; it
   does NOT satisfy the web requirement.)
2. **Offscreen PNG** render of a post-pro'd frame (per `.agents/knowledge/testing.md`)
   to diff before/after an effect — useful for the GAME vs TOP stage split.
3. **Web build (the critical path):** `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh`,
   serve, open in a browser. Confirm:
   - `Rl.platform == :web`, and `#version 300 es` fragment shaders compile (after the
     ES3 upgrade) — check the browser console for GLSL errors; raylib logs
     "SHADER: Failed to load custom shader code, using default shader" on failure
     (`rlgl.h` ~line 4310 in 6.0).
   - The GAME stage affects the game world + in-world UI but **not** the overlay HUD;
     the TOP stage affects everything. (Visual diff: toggle a game shader — HUD must
     stay crisp; toggle a top shader — HUD must change.)
4. **Runtime toggling on web (critical):** with the game running in the browser, flip
   effects live via the eval bridge and confirm each change lands next frame:
   ```sh
   sh .live/web/bin/eval 'fx.game_shaders[0].enabled = false'   # game FX off — HUD unaffected
   sh .live/web/bin/eval 'fx.top_shaders[1].enabled = true'    # top FX on — whole frame incl. HUD
   sh .live/web/bin/eval 'fx.game_shaders.map { |p| p.enabled }'  # read back state
   ```
   The eval bridge is browser-verified on web today (`sh .live/web/bin/eval 'Rl.get_fps'`
   returns live fps). Also toggle via the in-game console (`\`) — same main-thread eval
   path — and confirm it works in the browser (verify; not yet browser-confirmed).

---

## Source list

| # | Source | Type | Used for |
|---|--------|------|----------|
| 1 | [raylib `shaders_postprocessing.c` (official example)](https://github.com/raysan5/raylib/blob/master/examples/shaders/shaders_postprocessing.c) | official | canonical single-pass pattern, y-flip, `GLSL_VERSION` per-platform |
| 2 | [raylib `examples/Makefile.Web`](https://github.com/raysan5/raylib/blob/master/examples/Makefile.Web) | official | exact WebGL2 link flags `-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2`, "Requires raylib compiled with GRAPHICS_API_OPENGL_ES3" |
| 3 | [Emscripten: OpenGL support](https://emscripten.org/docs/porting/multimedia_and_graphics/OpenGL-support.html) | official | `-sMAX_WEBGL_VERSION=2` selects WebGL2; `-sFULL_ES3` is client-array *emulation*, orthogonal; WebGL-friendly subset recommended |
| 4 | [Wavedash: raylib](https://docs.wavedash.com/engines/raylib) | third-party guide | "Don't add `-s FULL_ES3=1` — raylib's CMake Web build defaults to OpenGL ES 2, and mixing ES3 client-array emulation with an ES2 library leaves the GL context uninitialized at draw time" |
| 5 | [Meatcorps: Post-processing stack in Raylib-cs](https://docs.meatcorps.nl/raylibcs/postprocessing/) | third-party guide | ping-pong multi-pass stack, `BaseShader`/`PostProcessingRenderer`, y-flip, `INeedsCurrentViewTexture` (original-scene access), fixed-internal-res upscaling |
| 6 | [nCine 14-year presentation](https://encelo.github.io/nCine_14Years_Presentation/) | third-party | "Can be chained together for multi-pass techniques... ping-pong technique" |
| 7 | [shadergif: WebGL2 vs WebGL1 for Shaders (GLSL 3.00)](https://shadergif.com/guides/webgl2-glsl-300-es/) | third-party | GLSL ES 3.00 syntax changes vs 1.00 |
| 8 | [Unity Graphics Emulation docs](https://docs.unity3d.com/550/Documentation/Manual/GraphicsEmulation.html) | official | WebGL1 caps: max 4 render targets, max 16 textures/shader, max tex 4096 |
| 9 | [Emscripten: Optimizing WebGL](https://emscripten.org/docs/optimizing/OptimizingWebGL.html) | official | "use multiple FBOs... switching render targets only requires a single glBindFramebuffer()... avoid mutating FBO state" |
| 10 | vendor `vendor/raylib/src/rlgl.h` (6.0: `rlLoadShaderProgram` ~4265 + `rlLoadShader` ~4205; `rlLoadShaderDefault` ~4995) | local source | raylib does NOT prepend `#version` to user shaders; default vertex shader per backend |
| 11 | vendor `vendor/raylib/src/Makefile` (lines 234–265) | local source | desktop=GL33, web=ES2 (ES3 commented), `GRAPHICS` var overridable |
| 12 | vendor `vendor/raylib/src/rcore.c` (`LoadShader` 1295, `LoadShaderFromMemory` 1314) | local source | NULL vertex → default shader; user fs compiled as-is |

## Verbatim quotes
- "To target WebGL 2, pass the linker flag `-sMAX_WEBGL_VERSION=2`." — [Emscripten OpenGL support](https://emscripten.org/docs/porting/multimedia_and_graphics/OpenGL-support.html)
- "Don't add `-s FULL_ES3=1` — raylib's CMake Web build defaults to OpenGL ES 2, and mixing ES3 client-array emulation with an ES2 library leaves the GL context uninitialized at draw time." — [Wavedash raylib](https://docs.wavedash.com/engines/raylib)
- "You render your game content into a RenderTexture. You apply shaders to that texture. You ping-pong between render textures so each shader pass can write to a new target. You render the final result to the screen buffer." — [Meatcorps](https://docs.meatcorps.nl/raylibcs/postprocessing/)
- "NOTE: Render texture must be y-flipped due to default OpenGL coordinates (left-bottom) DrawTextureRec(target.texture, (Rectangle){ 0, 0, w, (float)-target.texture.height } ...)" — [raylib shaders_postprocessing.c](https://github.com/raysan5/raylib/blob/master/examples/shaders/shaders_postprocessing.c)
- "# NOTE: Flags required for WebGL 2.0 (OpenGL ES 3.0) # WARNING: Requires raylib compiled with GRAPHICS_API_OPENGL_ES3 ... LDFLAGS += -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2" — [raylib Makefile.Web](https://github.com/raysan5/raylib/blob/master/examples/Makefile.Web)
- "When rendering to offscreen render targets, use multiple FBOs so that switching render targets only requires a single glBindFramebuffer() call... prefer to set up multiple immutable/static FBOs, which do not change state." — [Emscripten Optimizing WebGL](https://emscripten.org/docs/optimizing/OptimizingWebGL.html)

## Source quality flags
- Meatcorps (#5): a personal blog/tutorial, but technically detailed, code-backed, and
  corroborated by the official raylib example (#1) and nCine (#6). Treat the
  *pattern* as reliable; the specific C# class names are illustrative only.
- shadergif (#7), Unity (#8): used only for the WebGL1-vs-2 capability diff; both
  consistent with the Emscripten/Khronos specs.

## Confidence: high
The pipeline pattern (ping-pong render-to-texture) is the documented raylib
canonical approach and is corroborated by 3 independent sources. The WebGL2 upgrade
mechanism is confirmed by raylib's own Makefile + Emscripten's official docs + a
third-party warning. The `#version`-not-injected behavior is verified in the local
vendor source. The only soft spot is the exact Ruby swap-aliasing ergonomics in the
sketch, which is an implementation detail to nail down during the build-and-verify
step, not a research gap.

## Gaps / open questions (to resolve during implementation, not blocking)
- Whether to keep a WebGL1 fallback (`-sMAX_WEBGL_VERSION=2` only, no `MIN`) vs
  go WebGL2-only (`-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2`). Recommend
  WebGL2-only for simplicity unless a target device list says otherwise.
- Whether the existing `-sFULL_ES2=1` can be fully dropped on upgrade (yes — it's
  the client-array emulation; the WebGL-friendly subset doesn't need it; but verify
  nothing in rmlui/raylib relies on client-side arrays, which would be unusual).
  NOTE (post-6.0): the ES3 path sets `ExtSupported.vao=true` unconditionally, so
  the VAO branch is always taken (never the client-array `else` that needs
  `FULL_ES*`). Dropping `-sFULL_ES2=1` is safe on ES3.
- Exact shader-source sharing ratio between `300 es` and `330`: most post-pro
  fragment shaders (blur, grayscale, CRT) are identical modulo the header; confirm
  per-effect during implementation.
- The earlier "ES3 not widely tested" caveat (raylib #4330) is now substantially
  mitigated on **6.0**: the MRT (`rlActiveDrawBuffers` #4605) and depth-texture
  (`rlLoadTextureDepth` #5500) WebGL2 fixes landed. Still: verify on the browser
  early (desktop GL behavior does not always carry over to the ES3 path).
  per-effect during implementation.
