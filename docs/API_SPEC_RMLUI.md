# raylib-jamstack — RmlUi Ruby API Specification (`Rml::`)

The UI layer. [RmlUi](https://github.com/mikke89/RmlUi) is an HTML/CSS-derived UI
library with a model-view-controller **data binding** system. In this stack it is
the *only* UI layer (no raygui), rendered on top of raylib through raylib's GL
context, and driven from Ruby.

This follows the same design rules as `API_SPEC.md` (snake_case, `?` predicates,
`=` setters, Begin/End → blocks, keyword args, structs → classes, block-safety).

The mental model mirrors RmlUi's own MVC:

- **Model** = a Ruby object / hash whose fields are bound to the UI.
- **View** = `.rml` (markup) + `.rcss` (stylesheet) files.
- **Controller** = Ruby callbacks invoked from `data-event-*` attributes in the RML.

---

## 1. Initialization & the raylib bridge

RmlUi needs a render backend and a system interface (timing, input). In this stack
those are implemented in C against raylib (GL + `Rl.time` + raylib input), so the
Ruby author never sees them — they just call `Rml.init`.

```ruby
Rml.init                       # wires RmlUi to raylib's GL context + system clock
Rml.load_font("ui/LatoLatin-Regular.ttf")
Rml.load_font("ui/font.ttf", fallback: true)
Rml.shutdown                   # auto on Rl.close_window
```

> `Rml.init` must be called **after** `Rl.init_window` (it needs the GL context).
> The binding asserts this and raises a clear Ruby error otherwise.

---

## 2. `Rml::Context`

A context owns documents and dispatches input. Most games need exactly one.

```ruby
ctx = Rml::Context.new("main", width: 900, height: 675)
# width/height default to the current window size (Rl) when omitted:
ctx = Rml::Context.new("main")

ctx.dimensions = Rl::Vector2.new(1280, 720)   # on window resize
ctx.update         # process data-model changes + layout   (Context::Update)
ctx.render         # draw the UI                            (Context::Render)
ctx.process_input  # feed raylib mouse/keyboard/text into RmlUi this frame
```

### Where it goes in the frame

`process_input` runs at the top of the frame (before game update). `update` +
`render` run *inside* the `Rl.draw` block so the UI composits over the game:

```ruby
Rl.while_window_open do
  ctx.process_input
  # ... game update ...
  Rl.draw(clear_color: Rl::BLACK) do
    # ... game render ...
    ctx.update
    ctx.render        # UI on top
  end
end
```

> **Block-form convenience.** `ctx.frame { ... }` wraps `process_input` (pre) and
> `update`+`render` (post) around the block, enforcing correct ordering:
> ```ruby
> Rl.while_window_open do
>   ctx.frame do
>     Rl.draw(clear_color: Rl::BLACK) { game.render }
>   end
> end
> ```

---

## 3. Documents — `Rml::Document`

```ruby
doc = ctx.load_document("ui/hud.rml")    # LoadDocument
doc.show                                  # ElementDocument::Show
doc.hide
doc.close
doc.visible?
doc.title                                 # from <title> in the RML
doc.reload                                # hot-reload markup+styles (dev convenience)
```

> **Improvement / jam-friendly:** `ctx.load_document` accepts a block that auto-shows
> and yields the document:
> ```ruby
> ctx.load_document("ui/menu.rml") { |d| d.show }
> ```

---

## 4. Data binding — the core feature

This is the reason to use RmlUi over raygui. A **data model** binds Ruby state to
named variables referenced in the RML via `data-*` attributes.

### 4.1 Defining a model

```ruby
model = ctx.data_model("hud") do |m|
  # one-way (view): a getter lambda, re-read whenever the model is updated
  m.bind(:hp)        { player.hp }
  m.bind(:max_hp)    { player.max_hp }
  m.bind(:score)     { game.score }

  # two-way: bind a plain mutable value; UI inputs write back into Ruby
  m.value(:volume, 0.5)            # <input type="range" data-value="volume"/>
  m.value(:player_name, "Orc")

  # arrays / lists (RmlUi data-for)
  m.bind(:invaders)  { game.invaders }   # each element exposes its own fields

  # controller callbacks: invoked from data-event-* in the RML
  m.event(:reset)            { game.reset }
  m.event(:launch) { |ev|    game.launch(ev["mouse_x"], ev["mouse_y"]) }
end
```

Corresponding RML:

```html
<div>HP: {{hp}} / {{max_hp}}</div>
<div>Score: {{score}}</div>
<input type="range" min="0" max="1" step="0.05" data-value="volume"/>
<button data-event-click="reset()">Reset</button>
<ul>
  <li data-for="inv : invaders">{{inv.name}} — {{inv.danger}}</li>
</ul>
```

### 4.2 Notifying the UI of changes (`DirtyVariable`)

RmlUi does not poll Ruby every frame; you tell it what changed.

```ruby
model.dirty(:hp)          # DataModelHandle::DirtyVariable("hp")
model.dirty(:hp, :score)  # several at once
model.dirty_all           # DataModelHandle::DirtyAllVariables
```

> **Improvement over raw RmlUi ergonomics:** `model.dirty(:hp)` returns the model
> so calls chain, and `ctx.update` is what actually flushes them to the view.
> One-way `bind` getters are only re-invoked for variables marked dirty (or after
> `dirty_all`), so binding to expensive getters is cheap.

### 4.3 Reading back two-way values

```ruby
model[:volume]            # => current Float, reflecting any UI edits
model[:volume] = 0.8      # set from Ruby; auto-marks dirty
```

### 4.4 Mapping Ruby types to RmlUi variants

| Ruby            | RmlUi data variable |
|-----------------|---------------------|
| `Integer`/`Float` | numeric scalar    |
| `String`/`Symbol` | string scalar     |
| `true`/`false`  | bool scalar         |
| `Array`         | data array (`data-for`) |
| `Hash` / object responding to readers | struct (`x.field`) |
| `Proc`/lambda (in `bind`) | computed one-way scalar |

For `Hash`/object structs, the binding exposes keys / public reader methods as
`{{inv.field}}`. Nested arrays/structs are supported.

---

## 5. Events from RML → Ruby

Two ways UI interaction reaches Ruby:

1. **Data events** (preferred, MVC): `data-event-click="reset()"` → the `:reset`
   callback registered with `m.event`. The callback receives an event object:
   ```ruby
   m.event(:launch) do |ev|
     ev.type            # => "click"
     ev["mouse_x"]      # event parameters (GetParameter)
     ev.target          # => Rml::Element that fired it
   end
   ```
2. **Direct element listeners** (escape hatch):
   ```ruby
   btn = doc.element("#start")     # GetElementById
   btn.on(:click) { game.start }
   ```

---

## 6. Elements — `Rml::Element` (escape hatch)

Most UI is declarative, but direct manipulation is available:

```ruby
el = doc.element("#hp_bar")       # by id  (GetElementById)
els = doc.elements(".enemy")      # by selector (GetElementsByTagName/QSA)

el.text = "Game Over"             # inner RML/text
el.set_attribute("class", "dead")
el.get_attribute("class")
el.add_class("hidden"); el.remove_class("hidden")
el.style["width"] = "200px"       # inline style property
el.visible = false
el.on(:click) { ... }             # AddEventListener
```

---

## 7. Input routing detail

`ctx.process_input` translates raylib input into RmlUi each frame:

- `Rl.mouse_position` → `Context::ProcessMouseMove`
- mouse buttons → `ProcessMouseButtonDown/Up`
- `Rl.mouse_wheel` → `ProcessMouseWheel`
- key events + Unicode text → `ProcessKeyDown/Up` + `ProcessTextInput`

```ruby
ctx.input_enabled = false   # let the game swallow input (e.g. gameplay vs menu)
ctx.hovered?                # true if pointer is over a non-transparent UI element
```

> **`ctx.hovered?` is the key jam helper:** gate gameplay clicks behind
> `next if ui.hovered?` so clicking a button doesn't also fire in the game world.

---

## 8. Canonical UI shape (full example)

```ruby
Rl.init_window(900, 675, "Orc")
Rml.init
Rml.load_font("ui/Lato-Regular.ttf")

ui    = Rml::Context.new("main")
model = ui.data_model("hud") do |m|
  m.bind(:hp)    { Player.hp }
  m.value(:volume, 0.5)
  m.event(:reset) { Game.reset }
end
hud = ui.load_document("ui/hud.rml")
hud.show

Rl.while_window_open do
  ui.process_input
  Game.update unless ui.hovered?
  Rl.set_master_volume(model[:volume])
  model.dirty(:hp)

  Rl.draw(clear_color: Rl::BLACK) do
    Game.render
    ui.update
    ui.render
  end
end
```

---

## 9. Block-safety & lifetime (consistent with core spec)

- `ctx.frame`, `ctx.data_model`, `ctx.load_document {…}` are block forms and honor
  the §5 block-safety contract from `API_SPEC.md`.
- `Rml::Context`, `Rml::Document`, fonts hold native handles; they are GC-finalized
  and also expose explicit teardown (`ctx.close`, `doc.close`). `Rml.shutdown` runs
  automatically at `Rl.close_window`.

---

## 10. Settled decisions

- RmlUi is the **sole** UI layer (no raygui).
- The render/system backend is C-against-raylib and hidden from Ruby.
- Data binding (MVC) is the primary interaction model; direct element access is the
  documented escape hatch.

## 11. Open implementation notes (not Ruby-facing)

- RmlUi's GL2/GL3 sample backend can be adapted, but raylib owns the GL context, so
  the render interface must use `rlgl` (raylib's GL abstraction) to stay compatible
  with both desktop GL and WebGL under emscripten. Flagged here for the build phase.
