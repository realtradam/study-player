# Study-Player Rewrite — Phase 1 Port Design

This document is the Phase 1 plan for porting the C/raylib `../source/`
study-player application into the `raylib-jamstack` stack
(Ruby/mruby + raylib + RmlUi + flecs + Jolt, Zig desktop / Emscripten web).

The plan covers:

1. How the approved principles (P1–P8) shape the rewrite.
2. A contract-by-contract mapping from the C source to Ruby/flecs/RmlUi.
3. The Flecs component/state model.
4. File/module layout under `game/study_player/`.
5. Audio file loading, including the `argv → study-player view` requirement.
6. RmlUi document/data-model structure.
7. The non-blocking seek design (the `skipAutoUpdate` pattern).
8. Phase boundaries and decisions the later phases must make.
9. Proposed glossary additions.

> Execution rule for this plan: **Phase 1 is design + scaffold + clean build
> only.** No audio playback, no silence detection, no layout editor — those are
> Phases 2–6.

---

## 1. Principles applied

| Principle | How it shows up in this design |
|---|---|
| **P2 — Pure core / imperative shell** | `game/study_player/core.rb` holds side-effect-free math: time formatting, silence-region shrinking, portion navigation, seek-target calculation, and the auto-pause decision function. Systems in the imperative shell call core functions and apply the returned commands to `Rl::Music` streams. |
| **P1 + P7 — Features as extensions** | Each feature is a cohesive module under `game/study_player/`: audio adapter, analysis/navigation, study-mode autopause, UI sync, layout/config. The silence detector requires raw wave samples; that I/O is isolated in a small new mrbgem (`mrbgems/study_audio`) so the rest stays portable Ruby. |
| **P3 — No ambient state** | Runtime scalar state lives in Flecs components on a singleton `study_player` entity. Non-serializable handles (`Rl::Music`) and the silence-region array live in an explicit `StudyPlayer::Runtime` object created in the entry script and passed/closed-over by systems — not a hidden global singleton. |
| **P4 — Earn each pattern** | We do not transliterate C structs into Ruby classes for their own sake. Flecs components are used where owned, queryable, per-frame state solves a concrete problem (input → intent → apply → render). Pure value objects are plain Ruby `Data`/structs. |
| **P5 — Repo is a harness** | We inherit `.agents/rules/`, `.agents/knowledge/`, and `.agents/skills/`. Study-player-specific scar tissue goes into `.agents/knowledge/study-player.md`; the canonical vocabulary is proposed as additions to `GLOSSARY.md`. |
| **P6 — Document only the non-inferable** | All inferable Ruby/raylib mechanics are described only by name; the plan records *study-player-specific* scar tissue (raw wave access, ARGV flow, RmlUi layout quirks, the 0.25s padding rule, non-blocking seek). |
| **P8 — One canonical vocabulary** | We reuse existing template terms (`World`, `Component`, `System`, `phase`, `progress`, `DataModel`, `dirty`) and propose new glossary entries for study-player concepts (§9). |

---

## 2. Source-to-destination mapping

| C module | Key responsibility | Port destination |
|---|---|---|
| `src/types.h` (`PlayerState`, `SilenceRegion`, `UILayout`) | Shape of runtime state | Flecs component descriptors + pure value objects + RCSS layout variables. |
| `src/player.c/h` | Load/unload/play/pause/seek/update/format_time | `StudyPlayer::AudioAdapter` (imperative shell; wraps `Rl::Music` and `StudyAudio`). |
| `src/study.c/h` | Silence detection, portion navigation, auto-pause | `mrbgems/study_audio` (raw I/O scanner) + `StudyPlayer::Core` (pure math + decisions). |
| `src/ui.c/h` | Fonts, colours, drawing, keyboard/mouse input | `game/study_player/ui.rml/rcss` (rendering) + `StudyPlayer::InputAdapter` + Rml event handlers. |
| `src/config.c/h` | Load/save `UILayout` to `study-player.cfg` | `StudyPlayer::Config` (Ruby file I/O) + `StudyPlayer::Layout` (position/size map). |
| `src/layout_editor.c/h` | Drag-to-reposition UI elements | Phase 6: Rml document with drag events mutating layout map. |
| `src/main.c` | Window/audio init, main loop, tabs, drag-drop | Entry script `game/study_player/study_player.rb` + a tiny `src/main.c` patch to expose command-line args to Ruby (§5). |

---

## 3. Flecs component / state model

We use one singleton entity `study_player` plus a small set of state
tags/components. Components are C structs declared with `world.struct` so the
Flecs binding can serialize/deserialize them as Hashes.

### Singleton components

Declared in `game/study_player/components.rb`:

```ruby
AudioFile     = world.struct("AudioFile",     "{ string path; float duration; }")
PlaybackState = world.struct("PlaybackState", "{ bool loaded; bool playing; float current_time; int skip_auto_update; bool seek_pending; float seek_target; }")
StudyState    = world.struct("StudyState",    "{ bool study_mode; bool was_in_silence; int last_silence_idx; bool smart_play_held; }")
LayoutDirty   = world.struct("LayoutDirty",   "{ bool value; }")   # signals config save on tab switch / exit
```

Tag for load intents:

```ruby
NeedsLoad = world.tag("NeedsLoad")
```

Entity:

```ruby
player_entity = world.entity("study_player")
  .set(AudioFile,     { path: "", duration: 0.0 })
  .set(PlaybackState, { loaded: false, playing: false, current_time: 0.0,
                       skip_auto_update: 0, seek_pending: false, seek_target: 0.0 })
  .set(StudyState,    { study_mode: true, was_in_silence: false,
                       last_silence_idx: -1, smart_play_held: false })
  .set(LayoutDirty,   { value: false })
```

### What is NOT in components

- The `Rl::Music` handle: a Ruby object cannot safely live inside a C struct
  component. It is owned by `StudyPlayer::Runtime#music`.
- The silence-region array: components support scalars and inline arrays, not a
  variable-length list of pairs. Regions live in `StudyPlayer::Runtime#raw_regions`
  and `#silence_regions` (denormalized pure-Ruby value objects).
- UI-specific data model: owned by the `Rml::Context` data model.

### System phase assignments

```
ON_LOAD   : (unused by us; flecs internal)
PRE_UPDATE: input_adapter_system, load_request_system, seek_apply_system
ON_UPDATE : update_system, study_system, ui_sync_system
ON_START  : (unused)
```

The UI is drawn after `world.progress` inside a single `Rl.draw` block, with
`ctx.process_input` called before the progress step.

### Runtime object

Created in the entry script and closed over by systems:

```ruby
Runtime = Struct.new(:world, :player_entity, :music, :raw_regions,
                     :silence_regions, :ctx, :ui_model, :layout) do
  def loaded? = music && !music.nil?
end
```

Systems receive the runtime object via a top-level local/constant captured in
system blocks (Flecs system blocks are Ruby procs). This keeps non-serializable
state explicit and owned by the composition root.

---

## 4. File / module layout

```
game/study_player/
  study_player.rb          # composition root: init, components, runtime, loop
  components.rb            # Flecs component + tag declarations
  core.rb                  # PURE domain logic (no Rl/ECS side effects)
  config.rb                # study-player.cfg load/save
  layout.rb                # layout map and defaults
  audio_adapter.rb         # Rl::Music lifecycle wrapper
  input_adapter.rb         # Rl keyboard + Rml event → component mutations
  ui.rb                    # Rml context, data model, document
  systems/                 # registered from study_player.rb
    load_system.rb         # react to NeedsLoad, call AudioAdapter + Analysis
    update_system.rb       # UpdateMusicStream + current_time management
    seek_system.rb         # apply pending seeks, set skip_auto_update
    study_system.rb        # auto-pause FSM (core decision → apply)
    ui_sync_system.rb      # copy components → Rml data model dirty()
  ui/
    main.rml               # single document for splash + player view
    main.rcss              # positioning, colours, responsive anchors
    fonts/                 # (optional) study-player-specific fonts; otherwise reuse game/ui/*
```

### Module namespace

All code lives in the `StudyPlayer` Ruby namespace.

```ruby
module StudyPlayer
  module Core; end
  module Config; end
  class AudioAdapter; end
  class InputAdapter; end
  class UI; end
  class Runtime; end
end
```

---

## 5. Audio loading from argv

### Current gap

`src/main.c` only passes `argv[1]` (the script) to mruby. The rest of `argv` is
lost, so a Ruby script cannot read the audio file path from the command line.

```c
const char *script = (argc > 1) ? argv[1] : "game/main.rb";
```

### Required patch (Phase 2)

Expose a Ruby `ARGV` constant containing `argv[2..]`.

```c
mrb_value argv_ary = mrb_ary_new(mrb);
for (int i = 2; i < argc; i++) {
  mrb_ary_push(mrb, argv_ary, mrb_str_new_cstr(mrb, argv[i]));
}
mrb_define_const(mrb, mrb->object_class, "ARGV", argv_ary);
```

This is a tiny engine change to `src/main.c`; it is necessary because the
bindings do not provide process args. Web builds use the same code path via
`Module.arguments` in `web/shell.html`.

### Entry-point behaviour

```ruby
script = __FILE__
audio_arg = defined?(ARGV) && ARGV[0] ? ARGV[0] : nil

# If an audio file was given, create a NeedsLoad entity immediately.
if audio_arg
  player_entity
    .set(AudioFile, { path: audio_arg, duration: 0.0 })
    .add(NeedsLoad)
else
  # No arg: show the "drop a file here"/"use Load MP3" splash.
  ui.show_splash
end
```

### Drag-and-drop fallback

```ruby
world.system("CheckFileDrop", with: [], phase: Flecs::PRE_UPDATE) do
  if Rl.is_file_dropped?      # bound as predicate in generated API
    files = Rl.load_dropped_files
    if files.count > 0
      player_entity
        .set(AudioFile, { path: files.paths[0], duration: 0.0 })
        .add(NeedsLoad)
    end
    Rl.unload_dropped_files(files)
  end
end
```

`Rl.load_dropped_files` returns an `Rl::FilePathList` object; its `.paths`
accessor is provided by the generated struct wrapper. Only the first file is
used, matching the original.

### Web build entry

In `web/shell.html`, change `Module.arguments` to:

```js
arguments: ['game/study_player/study_player.rb', '/path/to/audio.mp3'],
```

for the default web demo; for end-users the second arg is supplied at build or
upload-time. Document that web file upload is not a Phase 1 goal; Phase 2
implements the argv path.

---

## 6. RmlUi UI structure

### One document, two visibility modes

We use a single `main.rml` document. Two top-level `<div>`s are toggled with
`display: none` / `block` classes:

- `#splash` — shown when no file is loaded.
- `#player` — shown when `AudioFile.loaded` is true.

A checkbox for study mode and a help line are always visible.

### Data model variables

Bound in `StudyPlayer::UI#build_model`:

| Variable | Direction | Purpose |
|---|---|---|
| `loaded` | computed | toggles `#player` / `#splash` visibility |
| `file_name` | computed | basename of the loaded audio file |
| `elapsed_str` | computed | `"H:MM:SS"` or `"M:SS"` from current time |
| `total_str` | computed | formatted total duration |
| `remain_str` | computed | remaining time |
| `progress_pct` | computed | integer 0..100 for the `%` label |
| `progress_ratio` | computed | float 0..1 for the fill bar width |
| `status_text` | computed | `"PLAYING"` / `"PAUSED"` |
| `status_alert` | computed | true when playing inside a silence region |
| `portion_label` | computed | `"N / total"` speaking portions |
| `study_mode` | two-way | checkbox state |
| `smart_play_held` | computed | smart-play button highlight state |
| `help_text` | value | keyboard help line |

Values are mutable through `.value(...)`. Computed ones use `.bind { ... }`.

### Controller events

```ruby
model.event(:toggle_play)   { runtime.toggle_play }
model.event(:prev_section)  { runtime.seek_to_portion(:prev) }
model.event(:next_section)  { runtime.seek_to_portion(:next) }
model.event(:smart_down)     { runtime.set_smart_play(true) }
model.event(:smart_up)       { runtime.set_smart_play(false) }
model.event(:seek_bar)       { |ev| runtime.seek_to_ratio(seek_ratio_from_event(ev)) }
```

`seek_bar` computes ratio from the event's absolute mouse position and the
clicked element's geometry:

```ruby
def seek_ratio_from_event(ev)
  el = ev.current_element   # or ev.target
  x = ev.mouse_x - el.absolute_left
  ratio = x.to_f / el.client_width
  ratio.clamp(0.0, 1.0)
end
```

### RCSS layout strategy

- The document is sized to the window (`width: 100%; height: 100%`).
- All interactive elements are `position: absolute` with `left:` and `top:` in
  pixels. Use `left:`, **not** `right:`, because RmlUi miscomputes `right:`
  positioning in the raylib backend (see `.agents/knowledge/rmlui-binding.md`).
- Default positions duplicate the original `UILayout` defaults.
- Layout overrides from `study-player.cfg` are applied after the document loads
  by calling `Element#set_property` on each identified element.

### Visual parity checklist (for Phase 5)

- Background: deep slate (`#1a1a2e`).
- Title filename in muted grey, centered.
- Progress bar with rounded ends, accent fill.
- Elapsed / remaining times flanking the bar.
- Play/pause circle button with hover highlight.
- Section counter with prev/next circular buttons.
- Smart-play rounded rectangle with held state.
- Study-mode checkbox, bottom-right.
- Status text (`PLAYING` / `PAUSED`) turns darker red when inside a silence
  region while playing.
- Window starts at the original 1920×1080 default.

---

## 7. Non-blocking seek design

### Problem

After `Rl.seek_music_stream`, `Rl.get_music_time_played` may briefly report the
old position. If the UI reads current time every frame, the playhead visibly
flickers backwards. The C source solves this with `skipAutoUpdate`.

### Design

We model the seek as an **intent component** plus a **cooldown counter**.

1. Input or UI sets `PlaybackState.seek_target` to the destination seconds and
   `seek_pending = true`.
2. `seek_apply_system` (PRE_UPDATE) sees `seek_pending`, calls
   `Rl.seek_music_stream(music, seek_target)`, sets `current_time = seek_target`,
   sets `skip_auto_update = 3`, and clears the pending flag.
3. `update_system` (ON_UPDATE), while `skip_auto_update > 0`, only decrements it
   and **does not** call `Rl.get_music_time_played`. It still calls
   `Rl.update_music_stream` every frame.
4. Once the counter reaches 0, current time is sampled from the audio engine as
   usual.

```ruby
# seek_apply_system (PRE_UPDATE)
if pb[:seek_pending]
  Rl.seek_music_stream(runtime.music, pb[:seek_target])
  pb[:current_time]    = pb[:seek_target]
  pb[:skip_auto_update] = 3
  pb[:seek_pending]    = false
end

# update_system (ON_UPDATE)
if pb[:loaded] && runtime.music
  Rl.update_music_stream(runtime.music)
  if pb[:playing]
    if pb[:skip_auto_update] > 0
      pb[:skip_auto_update] -= 1
    else
      pb[:current_time] = Rl.get_music_time_played(runtime.music)
    end
  end
end
```

### Relation to study auto-pause

The original auto-pause also pauses and seeks at silence boundaries. Those
operations also set `skip_auto_update = 3`. The study system therefore produces
a `SeekPause` decision; `seek_apply_system` performs the seek and cooldown,
and a subsequent system or the same decision handler pauses playback. Separating
**decision** from **application** keeps `Core` pure and the shell predictable.

### Frame count rationale

`3` frames at 60 fps is ~50 ms — enough for raylib's miniaudio music stream to
flush and report a stable time. This is carried over from the C source; Phase 2
will verify and tune if necessary.

---

## 8. Pure core API sketch

`game/study_player/core.rb` exports side-effect-free functions. Exact names may
be refined in Phase 3; the contracts below are the ones the rest of the app
expects.

```ruby
module StudyPlayer::Core
  # Time → formatted string, matching player_format_time semantics.
  def format_time(seconds); end   # => "M:SS" or "H:MM:SS"

  # Given raw silence gaps (sec/sec), shrink by padding and drop collapsed regions.
  def analyze_silence(duration, raw_regions, padding: 0.25); end
    # => [SilenceRegion(start_norm, end_norm), ...]

  # Portion math (0-based speaking portions).
  def speaking_portion_start(silence_regions, portion); end     # => normalized
  def current_speaking_portion(silence_regions, position); end # => Integer
  def total_speaking_portions(silence_regions); end            # => Integer
  def find_silence(silence_regions, position); end              # => index or nil
  def in_padding_zone?(duration, silence_regions, position, portion, padding: 0.25); end

  # Where to land when jumping to the start of portion N.
  def portion_seek_target(duration, silence_regions, portion,
                          padding: 0.25, lead_frames: 3, fps: 60); end   # => seconds

  # Auto-pause FSM. Returns one of:
  #   nil, { action: :pause_seek, target: seconds, was_in_silence: bool, last_silence_idx: int }
  def auto_pause_decide(duration, silence_regions, current_time, playing, study_mode,
                        smart_play_held, space_held, was_in_silence, last_silence_idx); end
end
```

Tests can call these with synthetic arrays without touching raylib or ECS.

### Native helper for raw gaps

`mrbgems/study_audio/` is a new C mrbgem that exposes:

```ruby
StudyAudio.raw_silence_regions(path, threshold: 0.015, min_duration: 0.75)
# => [[start_seconds, end_seconds], ...]
```

It uses raylib's `LoadWave`, `WaveFormat(..., 32, 1)`, scans 10 ms chunks for
peak amplitude, and returns the raw gaps (no padding). Added in Phase 3 before
the pure analysis module; because adding a gem flips the mruby ABI, we must run
`rm -rf vendor/mruby/build` once (rule `mruby-rebuild`).

---

## 9. Layout persistence (config)

`StudyPlayer::Config` reads/writes `study-player.cfg` from the current working
directory (the directory from which the binary is run), keeping the original
`exeDir` semantics where possible without `/proc/self/exe`.

Layout keys mirror the original `UILayout` names so conversion is trivial:

```ini
title_x=960.00
title_y=60.00
bar_x=336.00
bar_y=460.00
bar_width=1248.00
bar_height=50.00
button_center_x=960.00
button_y=645.00
...
```

At runtime, after loading `main.rml`, `StudyPlayer::Layout.apply(ctx, layout_hash)`
walks a mapping from layout keys to element IDs/styles and calls
`Element#set_property`. Dragging in the layout editor (Phase 6) mutates the same
hash and flags `LayoutDirty`; on app exit the config is saved.

---

## 10. Build / test / verification strategy

- Desktop: `./rebuild.sh` after any engine or mruby-gem change; `zig build run --
  game/study_player/study_player.rb [audio.mp3]` for end-to-end checks.
- Web: `EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh`, then the relay/agent
  bridge for eval/snapshot verification.
- Type check: `./tools/check-types.sh` runs `rbs validate` + `steep check`. Game
  code type errors are `:information`, not gate failures, but we keep signatures
  clean.
- Visual verification: `JAMSTACK_SCREENSHOT=study-player.png ./zig-out/bin/game
  game/study_player/study_player.rb audio.mp3` for an offscreen/dumped PNG.

Because `$PATH` may include a Windows Ruby on `/mnt/c`, all build commands
strip `/mnt/c` first (rule `wsl-toolchain.md`). `rebuild.sh` already does this.

---

## 11. Phase boundaries

| Phase | What it owns | What Phase 1 leaves behind |
|---|---|---|
| **Phase 1** | This plan, scaffold script, clean build. | Component declarations, UI layout map, Runtime shape, pure-core contracts. |
| **Phase 2** | Patch `src/main.c` for `ARGV`; `AudioAdapter`; `load_system`; `update_system`; `seek_system`; entry-point wiring. | A working music player with load/play/pause/seek/time display from argv. |
| **Phase 3** | Add `mrbgems/study_audio`; `StudyPlayer::Core` (silence + navigation); apply analysis on load; section counter. | Player that detects speaking portions and navigates V/B. |
| **Phase 4** | `StudyPlayer::Core.auto_pause_decide`; `study_system`; smart-play hold; space override. | Auto-pause at silence boundaries. |
| **Phase 5** | `game/study_player/ui.rml/rcss`; `StudyPlayer::UI`; data model; event wiring; visual parity screenshot. | Complete playable UI. |
| **Phase 6** | `StudyPlayer::Config`; layout editor; final end-to-end + screenshot. | Polished, persistent layout, production-equivalent build. |

---

## 12. Open decisions the later phases need to confirm

1. **Native helper granularity.** Whether `StudyAudio.raw_silence_regions` returns
   seconds or normalized values, and whether it returns the file duration too.
2. **String component safety.** The `AudioFile.path` string field in a Flecs
   component: if copying long paths is problematic, switch to a Ruby-level
   `runtime.path` variable and keep only a boolean/duration in the component.
3. **RmlUi audio file picker on web.** Web builds need a file `<input>` because
   drag-and-drop inside the canvas is more complex. Decide in Phase 2 whether to
   add a small HTML overlay or defer to argv/upload.
4. **Layout editor scope.** Phase 6 has a simplified drag editor per the brief.
   Decide which elements are draggable and whether disabling/enabling edit mode
   is via a tab (like original) or a key toggle.
5. **Font embedding.** Reuse `game/ui/LatoLatin-Regular.ttf` for now; decide
   later whether to embed a study-player-specific font.

---

## 13. Proposed glossary additions

These entries should be added to the repo `GLOSSARY.md` under a new
"Study Player" section as **planned** terms so later phases use them from the
start:

| Term | Definition | Avoid calling it... |
|---|---|---|
| **study mode** | Boolean toggle (`StudyState.study_mode`). When ON, auto-pause logic runs while playback is inside silence boundaries. | auto-pause mode, learning mode |
| **speaking portion** | A contiguous segment of meaningful audio between two silence regions; numbered 0-based. | section, segment, clip, part |
| **silence region** | A detected gap in the audio where amplitude stays below threshold for at least `min_duration`. Stored normalized (0–1). | gap, pause, quiet zone |
| **raw silence gap** | A silence interval returned by `StudyAudio.raw_silence_regions`, before the 0.25s padding is applied. | raw gap, un-shrunk silence |
| **padding zone** | The first 0.25s of a speaking portion, treated as safe headroom so auto-pause does not trigger during normal pauses. | grace period, buffer zone |
| **auto-pause** | The study-mode mechanism that pauses playback when entering or exiting a silence boundary. | auto-stop, silence break |
| **smart play** | Hold-to-override button/input that suppresses auto-pause while held. | hold play, override button |
| **section counter** | UI label showing current speaking portion and total, e.g. `"12/70"`. | portion label, counter |
| **non-blocking seek** | The `skip_auto_update` pattern: after a seek, skip N frames of current-time sampling so the audio engine catches up. | seek delay, seek cooldown |
| **seek cooldown** | The integer `PlaybackState.skip_auto_update` counter that implements non-blocking seek. | skip frames, seek settle |

---

## 14. Notes on the current template build

The existing `./rebuild.sh` succeeded at the start of Phase 1, producing
`zig-out/bin/game`. No generated/vendor files were edited. Phase 1 will add only:

- `notes/study-player-rewrite-plan.md`
- `game/study_player/study_player.rb` (minimal scaffold)
- `game/study_player/ui/` (placeholder)
- `.agents/knowledge/study-player.md` (scar-tissue companion)
- These entries also drive the proposed `GLOSSARY.md` update.

Adding the `mrbgems/study_audio` mrbgem is a Phase 3 concern and requires
`rm -rf vendor/mruby/build` once, per rule `mruby-rebuild.md`.
