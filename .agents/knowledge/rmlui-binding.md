# Tribal knowledge: RmlUi bindings (`Rml::`)

Hand-written C++ (`mrbgems/rmlui/src/rml_bindings.cpp`) + Ruby sugar
(`mrblib/rmlui.rb`), modeled on RmlUi's Lua bindings. RmlUi is the **only** UI
layer (no raygui), rendered over the game through raylib's GL context.

## At a glance
- **Key files:** `mrbgems/rmlui/src/rml_bindings.cpp` (bindings + the rlgl render
  backend); sugar `mrblib/rmlui.rb`; `mrbgem.rake`; documents/styles `game/ui/*.{rml,rcss}`.
- **Ruby API:** `Rml.init`/`load_font`, `Rml::Context` (`data_model`, `load_document`,
  `frame`), `Document`/`Element`/`Event`/`DataModel`. Spec `docs/API_SPEC_RMLUI.md`.
- **Cross-refs:** rules `mruby-rebuild`, `link-order`. Keyboard/text input gap
  CLOSED (see "Known gaps" below) — unblocks the in-game console (roadmap R6).

## Build
`cmake` with target `rmlui_core` ONLY. The `rmlui_debugger` module fails to
compile with GCC 16 (bundled `robin_hood.h`) and we don't need it. Flags:
`-DBUILD_SHARED_LIBS=OFF -DRMLUI_SAMPLES=OFF -DRMLUI_LUA_BINDINGS=OFF
-DRMLUI_FONT_ENGINE=freetype`. Being a C++ gem, it flips mruby to C++-exception
ABI (see rules/mruby-rebuild.md).

## The render backend (rlgl) — three fixes that were painful to find
The RmlUi render interface is implemented against raylib's **rlgl** (so the same
code works on desktop GL and WebGL). Three non-obvious correctness fixes:
1. **`rlSetTexture` must come AFTER `rlBegin(mode)`** — `rlBegin` resets the
   current draw-group texture on a mode change, so setting it before is lost.
2. **Premultiplied alpha** — render with `RL_BLEND_ALPHA_PREMULTIPLY`; RmlUi 6.x
   already premultiplies its font atlas. Using normal alpha gives dark fringes.
3. **Flush the batch per geometry** — call the batch flush for each geometry so
   textures/scissor don't bleed across draws.

## API surface
`Rml::Context`, `Rml::Document < Element`, `Rml::Element` (attributes, classes,
style properties, queries `query_selector`/`get_element_by_id`/`elements_by_tag`,
traversal, geometry, `el.on(:click) { |event| ... }`), `Rml::Event`, and the MVC
**data model** (`m.bind`/`m.value`/`m.event`, `model.dirty`). Init AFTER
`Rl.init_window` (needs the GL context). `ctx.frame { }` does
process_input→(block)→update+render.

## In-game REPL console (`Jamstack::Console`)
- **File:** `mrbgems/rmlui/mrblib/console.rb` (Ruby sugar, compiled into the gem).
- **Assets:** `game/ui/console.rml` + `game/ui/console.rcss`.
- **Usage:** `console = Jamstack::Console.new(ctx, binding: binding)` — pass the
  game script's binding so `eval` sees local variables (`score`, `world`, etc.).
- **Toggle:** backtick (`KEY_GRAVE`, 96). `console.update` (call before
  `ctx.process_input`) checks `IsKeyPressed` and drains both `GetKeyPressed` and
  `GetCharPressed` queues on the toggle frame so the backtick isn't forwarded to
  RmlUi as text input.
- **Enter/Up/Down:** handled via `input.on(:keydown)` — `KI_RETURN` (72) evals,
  `KI_UP` (91)/`KI_DOWN` (93) navigate history. `event.stop_propagation` prevents
  RmlUi's default `LineBreak` on Enter.
- **Scrollback:** `inner_rml=` with HTML-escaped text; `<div id="scroll_end">`
  sentinel + `scroll_into_view(false)` for auto-scroll.
- **Game input gating:** game scripts check `console.open?` to skip WASD/mouse
  input when the console is visible (see `game/console_demo.rb`).

## Rendering RmlUi into a RenderTexture (FBO) — the FX pipeline
The RmlUi render backend (`RaylibRenderInterface` in `rml_bindings.cpp`) draws
through rlgl, so `Rl.texture_mode(target) { ctx.update; ctx.render }` renders a
context into an offscreen FBO (used by the `Jamstack::FX` two-stage pipeline:
in-world UI into the game layer, overlay HUD into the composite layer). Two
non-obvious requirements:

1. **Render-texture size MUST equal the window size.** `SetScissorRegion` computes
   the GL scissor Y as `GetScreenHeight() - (top + h)` — it uses the **window**
   height, not the bound FBO's height. If the FBO differs from the window, every
   RmlUi scissor is misaligned (clips/shifts the element). Keep them equal
   (e.g. 720×720). Verified: a 720×720 context into a 720×720 FBO renders correct.
2. **Use `left:` not `right:` for `position: absolute`.** RmlUi MISCOMPUTES
   `right:` — a panel `right: 60px; width: 240px` in a 720px context resolves to
   `absolute_left = -300` (off-screen) instead of the expected 420. `left:`
   resolves correctly. (Caught live via the eval bridge reading
   `element.absolute_left`.) This is an RmlUi layout-engine quirk, not a
   binding bug.
3. No projection/viewport override: the render interface uses `rlVertex2f`
   against raylib's current 2D ortho (set by `begin_texture_mode`), so RmlUi
   draws in the FBO's coordinate space as long as the context dims match (1).

## Known gaps
~~Input routing forwards mouse only (keyboard/text TODO).~~ **CLOSED.**
`rml_context_process_input` now forwards keyboard + text input:
- **Key map:** `rl_key_to_rml(int raylib_key) -> Input::KeyIdentifier` maps raylib
  keys to RmlUi's KI_* codes (letters, digits, punctuation OEM keys, arrows,
  backspace/enter/tab/escape, F1-F12, modifiers). OEM punctuation (`;'`,./etc.)
  returns `KI_UNKNOWN` — those arrive via the text-input path (the Unicode
  codepoint from `GetCharPressed`), exactly like RmlUi's own GLFW backend.
- **Press/release:** raylib's `GetKeyPressed()` drains a queue of press-edges;
  `IsKeyReleased(k)` is true for one frame on release. We track a `std::set<int>
  g_rml_down_keys` to know which keys to check for release (raylib has no
  "what was released?" queue).
- **Text input:** `GetCharPressed()` polled in a loop; each codepoint ≥32 (and
  ≠127 DEL) forwarded via `ctx->ProcessTextInput((Character)c)`. This already
  respects shift/capslock (raylib applies them to the codepoint).
- **Modifiers:** `rl_key_modifiers()` computes the `KM_CTRL|KM_SHIFT|KM_ALT|KM_META`
  bitmask from `IsKeyDown` on the left/right modifier keys each frame.
- **Verified:** desktop (offscreen render + focus a text `<input>` — no crash,
  pipeline runs). Web compiles cleanly (wasm); interactive typing needs a real
  browser tab (the `glfwInit` "window is not defined" boundary in node is
  expected, not a regression).
