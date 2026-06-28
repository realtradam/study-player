# Tribal knowledge: in-game REPL console (`Jamstack::Console`)

## At a glance
- **What:** a user-facing RmlUi panel that evaluates Ruby in the game script's
  binding — full access to local variables and game state. Toggle with backslash
  (`\`, `KEY_BACKSLASH` = 92; JIS-friendly). Enter to eval, Up/Down for history,
  Tab for completion.
- **Key files:** `mrbgems/rmlui/mrblib/console.rb` (the class, compiled into the
  gem); `game/ui/console.rml` + `console.rcss` (markup/styles);
  `mrbgems/rmlui/src/rml_bindings.cpp` (C++: `rml_el_select`,
  `rml_el_set_selection_range` for caret control); `game/console_demo.rb`
  (usage example).
- **API:** `Jamstack::Console.new(ctx, binding: binding)` — pass the game
  script's binding so eval sees local variables. `console.update` (before
  `ctx.process_input`) handles the toggle key. `console.open?` lets the game
  skip gameplay input when the console is visible.
- **Cross-refs:** `rmlui-binding.md` (keyboard input, element API), `agent-bridge.md`
  (the eval queue — the console is a UI front-end for the same eval),
  roadmap R6.

## How it works

### Toggle key
`console.update` is called **before** `ctx.process_input` each frame. It checks
`Rl.key_pressed?(KEY_BACKSLASH)`. When the toggle fires, it drains both
`GetKeyPressed()` and `GetCharPressed()` queues in Ruby so the backslash isn't
forwarded to RmlUi as text input. Then `show`/`hide` toggles the document.

### Variable assignment propagation (mruby gotcha)
mruby's `eval` creates a **new local variable scope** — assignments like
`player_color = Rl::RED` do NOT write back to the game loop's closure. The
`eval_line` method detects simple `var = expr` assignments (without Regexp —
mruby has no `Regexp` class) and uses `binding.local_variable_set` which writes
to the binding's env (shared with the closure). Compound assignments (`+=`, etc.)
and non-identifier LHS fall through to plain `eval`.

**Only variables that existed before the binding was captured can be modified
this way.** New variables created in the console are only visible to subsequent
`eval` calls, not to the game loop's closure.

### Tab completion
- **No separator** → local vars (`binding.local_variables`) + methods
  (`binding.receiver.public_methods`) + `Object.constants`
- **After `.`** → `receiver.public_methods`
- **After `::`** → `receiver.constants`
- Single match: completes inline. Multiple: completes common prefix + lists
  candidates in scrollback. `KI_TAB` `stop_propagation` prevents RmlUi's default
  focus navigation.

### Caret control
After tab completion and history navigation, `@input.caret_end` moves the caret
to the end of the text. This calls `SetSelectionRange(len, len)` via the C++
binding (`dynamic_cast<ElementFormControlInput*>`).

### Key identifiers (RmlUi)
The keydown event carries `key_identifier` as an int parameter. The Ruby
`Event#[]` accessor reads it as a float (via `GetParameter<float>`), so call
`.to_i` to compare: `KI_RETURN` = 72, `KI_TAB` = 70, `KI_UP` = 91, `KI_DOWN` =
93. See `vendor/rmlui/Include/RmlUi/Core/Input.h` for the full enum.

### HTML escaping in scrollback
`inner_rml=` parses the string as RML, so `<`, `>`, `&` must be escaped. The
`escape_html` helper also converts `\n` → `<br/>` for multi-line output. A
sentinel `<div id="scroll_end"></div>` + `scroll_into_view(false)` provides
auto-scroll.
