# raylib-jamstack — Ruby API Specification

A stack for building raylib gamejam games in Ruby (mruby).

**Core parts**

1. **Raylib** — graphics / audio / input, exposed to Ruby as `Rl::`
2. **MRuby** — the embedded Ruby interpreter that runs the game code
3. **RmlUi** — HTML/CSS-based UI layer, exposed to Ruby as `Rml::`, with Ruby data binding

This document specifies *how the bindings look in Ruby*. It is the contract the C
binding layer must satisfy. Implementation uses **modern raylib + modern mruby**;
the `orc-arena-of-time` project is referenced only for *how the API feels*, not for
how its (old) bindings were implemented.

---

## 0. Design principles

These are distilled from the reference game and extended. Every binding decision
should be checkable against these rules.

1. **snake_case** everything. `InitWindow` -> `Rl.init_window`.
2. **Predicates end in `?`** and return `true`/`false`. `IsKeyDown` -> `Rl.key_down?`.
3. **Setters use `=`.** `SetTargetFPS(60)` -> `Rl.target_fps = 60`.
4. **Begin/End pairs are blocks.** Anything that comes as `BeginX`/`EndX` in C is a
   method that takes a block and guarantees the `EndX` runs (even on exception/return).
5. **Many-arg functions take keyword args with sensible defaults.** 2–3 obvious
   positional args may stay positional (`init_window(w, h, title)`).
6. **C structs become classes** under `Rl::`. Constructors that load a resource
   (`LoadTexture`) are `ClassName.new(path)`. Plain data structs (`Color`,
   `Vector2`, `Rectangle`) are `ClassName.new(fields...)` with mutable accessors.
7. **Struct-first methods become instance methods.** `DrawRectangleRec(rec, c)` ->
   `rec.draw(color: c)`; `CheckCollisionRecs(a, b)` -> `a.collide_with_rec?(b)`.
8. **Resources free themselves** via mruby GC finalizers, with an explicit
   `#unload` escape hatch (see §6).

---

## 1. Module-level: `Rl` (raylib core)

### 1.1 Window & lifecycle

```ruby
Rl.init_window(900, 675, "Orc: Arena of Time")   # InitWindow
Rl.close_window                                   # CloseWindow (auto on exit)
Rl.window_should_close?                           # WindowShouldClose
Rl.window_open?                                    # !WindowShouldClose (convenience)

# The main loop. Runs the block each frame until the window should close.
# On web (emscripten) this is wired to emscripten_set_main_loop instead of a
# real `while`, transparently. THIS IS WHY IT IS A BLOCK, NOT A RAW LOOP.
Rl.while_window_open do
  # update + draw
end
```

> **Improvement over reference:** the reference used a `while` loop that does not
> map cleanly to emscripten's callback-driven loop. Keeping `while_window_open` as
> the *only* sanctioned loop lets the binding swap in `emscripten_set_main_loop`
> for web with zero game-code changes.

### 1.2 Timing

```ruby
Rl.target_fps = 60     # SetTargetFPS
Rl.frame_time          # GetFrameTime  (delta, seconds)  -> Float
Rl.time                # GetTime       (since init)      -> Float
Rl.fps                 # GetFPS                          -> Integer
```

### 1.3 Drawing scope (block-based Begin/End)

```ruby
Rl.draw(clear_color: Rl::BLACK) do      # BeginDrawing + ClearBackground + EndDrawing
  ...
end

Rl.scissor_mode(x:, y:, width:, height:) do   # Begin/EndScissorMode
  ...
end

Rl.mode_2d(camera) do ... end           # Begin/EndMode2D
Rl.texture_mode(render_texture) do ... end  # Begin/EndTextureMode
Rl.blend_mode(Rl::BLEND_ADDITIVE) do ... end # Begin/EndBlendMode
```

> `draw`, `scissor_mode`, `mode_2d`, `texture_mode`, `blend_mode` all follow the
> same block rule (#4). `clear_color:` defaults to `Rl::RAYWHITE`.

### 1.4 Text

```ruby
Rl.draw_text(text: "fps: #{Rl.fps}", x: 10, y: 10, font_size: 30, color: Rl::WHITE)
Rl.draw_text(text:, x:, y:, font_size:, color:, font: Rl::Font.default, spacing: 1.0)
Rl.measure_text(text:, font_size:, font: Rl::Font.default) # -> Rl::Vector2
```

### 1.5 Textures / images

```ruby
Rl.draw_texture_pro(
  texture:,
  source: src_rec,                 # NOTE: renamed from reference's source_rec
  dest:   dst_rec,                 # NOTE: renamed from reference's dest_rec
  origin: Rl::Vector2.new(0, 0),
  rotation: 0,
  tint: Rl::WHITE
)
Rl.draw_texture(texture:, x:, y:, tint: Rl::WHITE)
Rl.draw_texture_v(texture:, position:, tint: Rl::WHITE)
```

> **Naming decision needed (see §9):** the reference is inconsistent — it uses
> `source_rec:`/`dest_rec:` in calls but `source:`/`dest:` in a commented
> signature, and `Rl::Vector` vs `Rl::Vector2`. This spec standardizes on
> raylib's own names `source:`/`dest:` and the class name `Rl::Vector2`.

### 1.6 Input — keyboard

```ruby
Rl.key_down?(Rl::KEY_W)        # IsKeyDown
Rl.key_down?(:w)               # symbol alias
Rl.key_pressed?(Rl::KEY_R)     # IsKeyPressed
Rl.key_released?(key)          # IsKeyReleased
Rl.key_up?(key)                # IsKeyUp
```

> **Improvement over reference:** the reference used magic numbers
> (`Rl.key_down? 87` for W). This spec uses `Rl::KEY_*` constants and also accepts
> symbols: `Rl.key_down?(:w)`. (Clean break — raw magic numbers are not a
> supported style.)

### 1.7 Input — mouse

```ruby
Rl.mouse_button_pressed?(Rl::MOUSE_BUTTON_LEFT)
Rl.mouse_button_down?(Rl::MOUSE_BUTTON_LEFT)
Rl.mouse_button_up?(Rl::MOUSE_BUTTON_LEFT)   # 0/1/2 ok
Rl.mouse_button_released?(button)
Rl.mouse_position     # GetMousePosition -> Rl::Vector2
Rl.mouse_x            # GetMouseX        -> Integer
Rl.mouse_y            # GetMouseY        -> Integer
Rl.mouse_wheel        # GetMouseWheelMove -> Float
```

### 1.8 Audio

```ruby
Rl.init_audio_device          # InitAudioDevice
Rl.audio_device_ready?        # IsAudioDeviceReady
Rl.set_master_volume(0.5)     # SetMasterVolume   (also: Rl.master_volume = 0.5)
```

### 1.9 Platform helper (custom, not in raylib)

```ruby
Rl.platform   # => :web | :desktop   (reference used the strings 'web'/'desktop')
Rl.web?       # convenience
Rl.desktop?   # convenience
```

> **Improvement:** return symbols and add predicates; the reference compared
> against the string `'web'` everywhere, which is error-prone.

---

## 2. Data structs as classes

### 2.1 `Rl::Color`

```ruby
c = Rl::Color.new(255, 255, 255, 255)   # r, g, b, a
c.r; c.g; c.b; c.a                       # readers
c.a = 150                                # writers (mutable — reference relies on this)
```

Built-in constants (no more hand-defining WHITE/BLACK): `Rl::WHITE`, `Rl::BLACK`,
`Rl::BLANK`, `Rl::RAYWHITE`, `Rl::RED`, `Rl::GREEN`, `Rl::BLUE`, `Rl::YELLOW`,
`Rl::GRAY`, `Rl::DARKGRAY`, ... (full raylib palette).

### 2.2 `Rl::Vector2`

```ruby
v = Rl::Vector2.new(x, y)
v.x; v.y; v.x = ...; v.y = ...
```

> **Improvement (raymath):** operators + helpers so games stop hand-rolling
> `Math.sqrt(x**2 + y**2)` (the reference does this dozens of times):
> ```ruby
> a + b   a - b   a * scalar   a / scalar
> v.length        v.length_sqr      v.normalize
> v.dot(other)    v.distance(other) v.lerp(other, t)
> ```

### 2.3 `Rl::Rectangle`

```ruby
r = Rl::Rectangle.new(x, y, width, height)
r.x; r.y; r.width; r.height    # all mutable

r.draw(color:)                              # DrawRectangleRec
r.draw_lines(line_thick:, color:)           # DrawRectangleLinesEx
r.collide_with_point?(vec2)                 # CheckCollisionPointRec
r.collide_with_rec?(other)                  # CheckCollisionRecs
r.collision_rec(other)        -> Rectangle  # GetCollisionRec
# additions:
r.center                      -> Vector2
r.contains?(vec2)             # alias of collide_with_point?
```

### 2.4 `Rl::Texture`

```ruby
tex = Rl::Texture.new("./assets/orc.png")   # LoadTexture
tex.width; tex.height
tex.unload                                   # UnloadTexture (also GC-finalized)
```

> **Improvement:** add `Rl::Texture.load("path")` that **caches** by path. The
> reference loads the same file repeatedly (e.g. on each level construct), leaking
> GPU memory. `Texture.new` = always fresh; `Texture.load` = cached.

### 2.5 `Rl::Image` (CPU-side) vs `Rl::Texture` (GPU-side)

```ruby
img = Rl::Image.new("./assets/orc.png")   # LoadImage (stays in RAM, CPU editable)
tex = img.to_texture                       # LoadTextureFromImage
img.unload
```

### 2.6 `Rl::Sound` / `Rl::Music`

```ruby
snd = Rl::Sound.new("./assets/hurt.wav")   # LoadSound
snd.play           # PlaySound
snd.stop
snd.playing?       # IsSoundPlaying
snd.volume = 0.45  # SetSoundVolume

mus = Rl::Music.new("./assets/music.ogg")  # LoadMusicStream
mus.play; mus.playing?; mus.volume = 0.09
mus.update         # UpdateMusicStream (call each frame for streaming)
```

> **Note:** the reference loaded `music.ogg` as a `Sound`; long tracks should be
> `Music` (streamed). Both are provided.

### 2.7 `Rl::Camera2D`, `Rl::RenderTexture`, `Rl::Font`

```ruby
cam = Rl::Camera2D.new(target: Rl::Vector2.new(0,0),
                       offset: Rl::Vector2.new(0,0),
                       rotation: 0, zoom: 1.0)

rt = Rl::RenderTexture.new(width, height)   # LoadRenderTexture
font = Rl::Font.new("./assets/font.ttf", size: 32)
```

---

## 3. The canonical game shape

Putting the idioms together (this should read like the reference game, cleaned up):

```ruby
Rl.init_window(900, 675, "Orc: Arena of Time")
Rl.target_fps = 60

player = Rl::Texture.load("./assets/orc.png")
src    = Rl::Rectangle.new(0, 0, 24, 24)
dest   = Rl::Rectangle.new(100, 100, 48, 48)

Rl.while_window_open do
  dest.x += 100 * Rl.frame_time if Rl.key_down?(:d)

  Rl.draw(clear_color: Rl::BLACK) do
    Rl.draw_texture_pro(texture: player, source: src, dest: dest)
    Rl.draw_text(text: "fps: #{Rl.fps}", x: 10, y: 10, font_size: 20, color: Rl::WHITE)
  end
end
```

---

## 4. RmlUi: `Rml::` (specified in detail in API_SPEC_RMLUI.md)

Summary of the surface (full spec to follow as the next deliverable):

```ruby
Rml.init(width: 900, height: 675)        # backend wired to raylib's GL context
ctx = Rml::Context.new("main", 900, 675)

# Data binding (MVC) — bind a Ruby object to a named data model
model = ctx.data_model("hud") do |m|
  m.bind(:hp, -> { player.hp })          # one-way view
  m.bind(:score, score)                  # two-way for plain values
  m.event(:reset) { reset_game }         # rml: data-event-click="reset()"
end

doc = ctx.load_document("ui/hud.rml")
doc.show

Rl.while_window_open do
  Rl.draw(clear_color: Rl::BLACK) do
    # game render ...
    ctx.update      # process data model changes
    ctx.render      # draw UI on top via raylib
  end
  ctx.process_input # feed raylib mouse/keyboard into RmlUi
end

model.dirty(:hp)   # notify UI that a bound variable changed (DataModelHandle::DirtyVariable)
```

This mirrors RmlUi's `DataModelHandle` MVC model: Ruby objects are the model,
`.rml`/`.rcss` files are the view, and `m.event` callbacks are controllers.

---

## 5. Block-safety contract

Every block-form method (`while_window_open`, `draw`, `scissor_mode`, `mode_2d`,
`texture_mode`, `blend_mode`, `data_model`) MUST run its matching `EndX` even if the
block raises or returns early. In C-binding terms: wrap the `mrb_yield` and always
emit the `EndX` call, re-raising any pending exception afterward.

---

## 6. Resource lifetime

- Resource classes (`Texture`, `Image`, `Sound`, `Music`, `Font`, `RenderTexture`,
  `Camera`-no) hold a native handle and register an mruby **finalizer** that calls
  the corresponding `UnloadX` when garbage-collected.
- All expose an explicit `#unload` for deterministic freeing (important on web,
  where GC timing is unpredictable). Double-unload is a no-op.
- `Texture.load(path)` / `Image.load(path)` use a per-path cache; cached resources
  are unloaded at `Rl.close_window` or via `Rl::Texture.clear_cache`.

---

## 7. Constants

- Keys: `Rl::KEY_A` .. `Rl::KEY_Z`, `Rl::KEY_SPACE`, `Rl::KEY_ENTER`, arrows, etc.
  Symbol aliases accepted by all key predicates (`:w`, `:space`, `:enter`).
- Mouse: `Rl::MOUSE_BUTTON_LEFT/RIGHT/MIDDLE` (integers `0/1/2` still accepted).
- Colors: full raylib palette (§2.1).
- Blend modes, config flags, etc. as `Rl::*` integer constants.

---

## 8. What changed vs. the orc-arena-of-time reference (summary)

| Area | Reference | This spec |
|------|-----------|-----------|
| Loop | `Rl.while_window_open` (raw while) | same, but defined as the emscripten-safe seam |
| Keys | magic numbers (`87`) | `Rl::KEY_W` + symbols (`:w`), numbers still ok |
| Mouse btn | magic numbers (`0`) | `Rl::MOUSE_BUTTON_LEFT` (int `0/1/2` ok) |
| Colors | hand-defined WHITE/BLACK | built-in `Rl::WHITE`/`Rl::BLACK`/full palette |
| Vector math | manual `Math.sqrt(...)` | `Vector2` operators + raymath helpers |
| Texture args | `source_rec:` / `dest_rec:` | `source:` / `dest:` (matches raylib) |
| Vector class | mixed `Vector`/`Vector2` | always `Rl::Vector2` |
| Long audio | `Sound` for music | `Music` (streamed) + `Sound` (one-shot) |
| Texture reuse | reloaded each level (leak) | `Texture.load` path cache + `#unload` |
| Platform | string `'web'` | `Rl.platform` symbol + `Rl.web?`/`desktop?` |
| UI | (none / hand-drawn) | RmlUi `Rml::` with Ruby data binding |

> The orc-arena-of-time project is a **style reference only**. This stack makes a
> clean break — there is no goal of running existing orc game code unmodified.

---

## 9. Settled decisions

- **Clean break** — no backward-compat with orc game code.
- **Symbol keys enabled** — `Rl.key_down?(:w)` alongside `Rl::KEY_W`.
- **ECS via flecs** — the stack ships optional `Flecs::` bindings (ECS) modeled on
  flecs' Lua binding; see [API_SPEC_FLECS.md](API_SPEC_FLECS.md). Using it is
  optional — game architecture is still up to the author.
  (Originally the stack shipped no ECS; this was reversed when flecs was added.)
- **No raygui** — RmlUi is the sole UI layer.
