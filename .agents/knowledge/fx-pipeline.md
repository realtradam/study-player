# FX pipeline — `Jamstack::FX`

> **At a glance** — a layered, two-stage, runtime-toggleable post-processing
> shader pipeline. Pure Ruby over the bound raylib shader API; **no C**. Each
> effect chooses whether it touches only the game world (+ in-world UI) or the
> whole frame (game + overlay HUD). Toggling never recompiles a shader.
>
> **Key files**
> - `mrbgems/raylib/mrblib/fx.rb` — `Jamstack::FX` module: `header`, `Pass`,
>   `Pipeline`, `Frame`, and the shader-body constants (`SCANLINES`, `VIGNETTE`,
>   `FXAA`, …).
> - `game/fx_demo.rb` — the reference scene: builds the pipeline, wires the
>   overlay-HUD checkboxes/slider to the passes.
> - `game/ui/fx_overlay.rml` / `.rcss` — the overlay HUD (toggles + slider).
>
> **API/spec pointer** — `docs/API_SPEC_RAYLIB.md` (shader fns:
> `load_shader_from_memory`, `get_shader_location`, `set_shader_value`,
> `set_texture_filter`, `load_render_texture`, `texture_mode`, `shader_mode`).
>
> **Cross-refs** — the GLSL/header/macro-shim detail lives in
> `raylib-binding.md` ("Custom shaders"); the WebGL2/ES3 web specifics in
> `web-target.md` ("FX shader pipeline on web"); rendering RmlUi into the FBO
> (context dims, the two contexts) in `rmlui-binding.md` ("Rendering RmlUi into
> a RenderTexture"). This doc holds only the FX-architecture scar tissue that
> lives nowhere else.

## The two-stage model (why it exists)

Three render layers, two shader chains, one screen blit:

```
  GAME LAYER    3D world + in-world RmlUi            -> RenderTexture G
       |
  GAME SHADERS  ping-pong chain on G   (world only; NOT the overlay HUD)
       |
  OVERLAY LAYER processed-game quad + overlay RmlUi HUD -> RenderTexture C
       |
  TOP SHADERS   ping-pong chain on C   (whole frame; over EVERYTHING incl HUD)
       |
     screen
```

**Why two stages:** so a gameplay effect can transform the world without wrecking
the overlay HUD. Warp/scanlines/aberration would smear HUD text into illegibility
→ they belong in the **game** stage (the HUD is composited *after*, so it stays
crisp). Vignette/grayscale/FXAA-of-everything belong in the **top** stage
(intentionally affect the HUD too). The overlay HUD is drawn into `C` *in the same
`texture_mode(C)` block* as the composited game quad, so top shaders filter both.

`Pipeline#w/h` defines the render-target size; `Frame#game_layer` / `#overlay_layer`
are the per-frame builder methods (see the usage block at the top of `fx.rb`).

## Runtime toggle — zero recompilation

`Pass` compiles its shader **once at construction** and caches uniform locations.
`Pass#enabled = false` just removes it from the per-frame chain (`apply_chain`
selects `enabled && !suppress`). Toggling from the eval bridge or the in-game
console is free — never reload/rebuild. An optional `uniform float intensity`
(0..1) lets an effect *fade* rather than snap (bound only if the body declares it).

## `extra_uniforms` — runtime knobs without recompilation

A `Pass` takes `extra_uniforms: {name => value}` (floats). Locations are cached at
construction; values are set per frame in `apply`. Use this for multi-knob shaders
(FXAA's `subpix` / `edgeThreshold` / `edgeThresholdMin`): set the values at runtime
from a slider → the running pass picks them up, **no shader recompilation**. Names
are fixed at construction; values are mutable.

## `Pass#suppress` — in-chain but skipped this frame

A pass can sit in a shader list yet be skipped per-frame via `suppress` (true).
`apply_chain` selects `enabled && !suppress`. Distinct from `enabled`:
- `enabled` = user toggle ("this FX is on/off").
- `suppress` = programmatic skip ("redundant this frame because another pass
  already covers it").

**The use case — two-layer FXAA, no double-blur:** `fx_demo.rb` runs FXAA in *both*
stages (`fxaa_game` world-only, `fxaa_ui` whole-frame). When `fxaa_ui` is on it
already AA's the whole frame *including the world*; letting `fxaa_game` also run
would double-AA the world (extra blur). So `fxaa_game.suppress = fxaa_ui.enabled`:
both-on ⇒ the game pass is suppressed ⇒ exactly the whole-frame behaviour, no
double-blur. (world-on/ui-off ⇒ only the world is AA'd, HUD stays crisp — the mode
that justifies the split.) If you see a pass "not running despite enabled=true,"
check `suppress` first — it is *not* a user-facing toggle.

## FXAA requires BILINEAR on the render textures

`Pipeline` ctor sets `TEXTURE_FILTER_BILINEAR` on **every** render texture. This is
not cosmetic: **FXAA needs sub-pixel bilinear sampling to blend edges.** With the
default point sampling, the FXAA edge-search samples identical texel values →
detects no contrast gradient → applies no AA (looks like a no-op). It is set once on
all RTs (`@g + @c`) because the top stage may run FXAA on any of them; harmless to
the non-FXAA passes. **Any new AA pass that samples neighbours** (SMAA, SSAA
downscale, CAS) inherits this correctly — do not "fix" the bilinear back to point.

## FXAA `GREEN_AS_LUMA` + the missing-luma caveat (open option B)

The FXAA body uses **green as luma** (`FxaaLuma(rgba) = rgba.g`). Reason: our RGBA8
render targets carry **uniform alpha = 1**, so luma-from-alpha would detect no
edges at all. Green is a reasonable perceptual-luma proxy.

**Caveat:** pure red/blue edges with **no green component** get little/no AA (their
luma delta is small). The escape hatch is **option B — a luma-pack pre-pass**: a
cheap pass that computes perceptual luma `(0.299R + 0.587G + 0.114B)` and writes it
into the alpha channel, after which FXAA reads alpha-as-luma and catches every
edge. Cost: one extra full-screen pass. **Not implemented** — green-as-luma is
good enough for the current demo; revisit if red/blue aliasing shows. (This was
previously referenced from `fx.rb` as "roadmap option B" — but the roadmap is a
*harness* roadmap with no FX section, so that pointer was dangling; the option
lives here now.)

## Which shader goes in which stage

- **Game stage** (world + in-world UI; leaves overlay HUD crisp): `WARP`,
  `ABERRATION`/`ABERRATION_CMY`, `SCANLINES`, `CRT` (all-in-one), `fxaa_game`.
  Rule of thumb: *anything that would smear text or warp geometry*.
- **Top stage** (whole frame incl HUD): `VIGNETTE`, `GRAYSCALE`, `COLORGRADE`,
  `fxaa_ui`. Rule of thumb: *gentle, whole-frame tonal/AA effects*.

## Wiring a HUD control to a pass (the demo pattern)

The overlay HUD drives passes via RmlUi. The non-obvious bits (RmlUi-binding has
the context/FBO detail; this is the control-wiring detail):

- **Checkbox:** `<input type="checkbox" id="chk-x" checked/>` →
  `el = doc.element("chk-x"); el.on(:change) { pass.enabled = el["checked"] }`.
  Read `el["checked"]` (truthy/falsy string).
- **Range slider:** `<input type="range" id="rng-q" min="0" max="1" step="0.05" value="0.6"/>`
  → `el.on(:change) { q = el["value"].to_f; pass.extra_uniforms[:knob] = q }`.
  **The value is a String — `.to_f` it.** The `:change` event fires on both
  checkbox toggles and slider drags. Setting an `extra_uniforms` value mutates the
  live pass; no rebuild.
- **Shared control over multiple passes:** just call both in the handler
  (`fxaa_quality(fxaa_game, q); fxaa_quality(fxaa_ui, q)`). Whichever actually runs
  (per `enabled`/`suppress`) uses the latest value.

## SMAA 1x — DONE (alongside FXAA, for A/B testing)

`Jamstack::FX::Smaa` (mrblib/smaa.rb) is a **composite** 3-pass effect (edge
detect → blend weights → neighbourhood blend) that ducks as a `Pass` for
`Pipeline#apply_chain` (responds to `enabled`/`suppress`/`extra_uniforms` +
`apply(src, dst, t, scene)`), running its own internal ping-pong over two
intermediate render textures (`edge_rt`, `blend_rt`). The shaders are the
canonical iryoku/smaa GLSL, preprocessed from `SMAA.hlsl` with `cpp
-DSMAA_GLSL_3 -DSMAA_PRESET_HIGH -DSMAA_DISABLE_DIAG_DETECTION …` (diag compiled
out) — saved at `mrbgems/raylib/tools/smaa_canonical.glsl`. The `fx_demo.rb`
wires two instances (game + ui) + a threshold slider, exactly like FXAA.

Scar tissue (all non-obvious, hard-won):

- **Multi-texture binding needs no rlgl.** SMAA passes 2 & 3 sample several
  textures in one shader (edges+area+search; image+blend). raylib's
  `DrawTexturePro` only auto-binds the *drawn* texture to unit 0 (`texture0`);
  the extra samplers are bound via **`Rl.set_shader_value_texture`** — raylib's
  `rlSetUniformSampler` registers the id + sets the sampler uniform, and the
  actual GL bind is **deferred to the batch flush** (the `DrawTexturePro` draw).
  So call `set_shader_value_texture` for each extra sampler inside `shader_mode`,
  then `draw_texture_pro` the main texture. (No `rlActiveTexture`/`rlEnableTexture`
  is exposed in this binding — and none is needed.)

- **Lookup textures live in C, not Ruby.** The `areaTex` (160×560 RGBA8,
  358 KB) + `searchTex` (64×16, 4 KB) are baked canonical bytes (`src/
  smaa_tex_data.c`, generated by `tools/gen_smaa_tex.rb` from the real
  iryoku/smaa `Scripts/*.py` — ortho region + search R channel byte-exact) and
  exposed to Ruby as Strings via `Rl.smaa_area_bytes` / `Rl.smaa_search_bytes`
  (`mrb_str_new` at runtime), then uploaded with `Rl.update_texture`. They are
  NOT Ruby literals because mruby (a) caps each string literal at
  `MRB_PARSER_TOKBUF_MAX` = **65534** bytes and (b) a ~358 KB string constant
  **hangs the irep loader at boot**. Runtime generation was also ruled out
  (~12 s in mruby for the closed-form area math; even offset-0-only). A C const
  array has none of these limits; `mrb_str_new` at runtime has none either.
  `areaTex` filter = **BILINEAR** (the shader interpolates the area LUT),
  `searchTex` = **POINT** (it's an index — must not interpolate).

- **SMAA 1x samples only offset-row 0.** `subsampleIndices = 0` for 1x (the SMAA
  comment says so), so the areaTex `texcoord.y += SUBTEX_SIZE*offset` stays in the
  first 1/7 block. We bake the full canonical area (all 7 rows) anyway; the diag
  half is zeroed (`SMAA_DISABLE_DIAG_DETECTION` — the shader never reads it).

- **The SMAA PS functions take `sampler2D` args + `float4 offset[3]`.** SMAA's
  own vertex shader computes `offset[3]`; raylib's default VS can't, so each
  pass's `main()` **inlines the VS offset math** from `fragTexCoord` +
  `rtMetrics` (`uniform vec4 rtMetrics; #define SMAA_RT_METRICS rtMetrics`).
  `SMAA_MAX_SEARCH_STEPS` = 16 (PRESET_HIGH) is used only in the blend pass's
  `offset[2]`. The threshold is a `uniform float smaaThreshold` (swapped into
  the preprocessed LumaEdgeDetectionPS via `.sub`, only in the edge pass) so the
  slider tunes it without recompiling.

- **Intermediate RTs are BILINEAR-filtered (NOT POINT).** The chain's color RTs
  are BILINEAR (Pipeline sets that for FXAA); SMAA samples the color input softly
  as a result — acceptable, slightly soft. **`edge_rt`/`blend_rt` SMAA owns MUST
  be BILINEAR too** — this is critical and was previously wrong (POINT). SMAA's
  `SMAAArea` reads the crossing edges `e1`/`e2` via a sub-texel sample of `edge_rt`;
  POINT makes them binary `{0,1}` → `SMAAArea` samples the areaTex's zero corner
  regions → **zero weights → no AA**. BILINEAR blends the sub-texel sample →
  `e1/e2 ∈ {0,0.25,0.75,1.0}` → reads the real area data → AA works (matches
  three.js's LINEAR edgesRT/weightsRT). See `smaa-root-cause.md` for the full
  diagnosis. `areaTex` stays BILINEAR; `searchTex` stays POINT (it's an index).

## Open options (the AA upgrade path)

- **Option B — luma-pack pre-pass** (above): fixes FXAA's red/blue blind spot, ~1 pass.
- **TAA** — temporal: needs motion vectors + a history RT + a resolve with
  neighbourhood clamping. Best on moving cameras; most work. Pair with a *sharpen*
  pass (CAS), not with another spatial AA.
- **SSAA** — render the game pass at 2× and downsample (bilinear, already enabled):
  trivial to add as one Pass; catches everything but costs fill-rate + memory.
- **SMAA diagonal detection** — currently disabled (`SMAA_DISABLE_DIAG_DETECTION`);
  enabling needs the diagonal `areaTex`/`searchTex` (brute-force generated) +
  porting `SMAACalculateDiagWeights`/`SMAASearchDiag*` back in. Ortho-only is the
  LOW/MEDIUM-preset config.

See `roadmap.md` only for harness milestones — FX feature options live here.
