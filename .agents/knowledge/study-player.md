# Tribal knowledge: study-player rewrite (`StudyPlayer::`)

Study-feature scar tissue for the rewrite of `../source/` into the
raylib-jamstack template.

## At a glance
- **Key files:** `game/study_player/study_player.rb` (composition root),
  `game/study_player/core.rb` (pure logic), `game/study_player/audio_adapter.rb`,
  `game/study_player/ui.rb` + `game/study_player/ui/main.{rml,rcss}`.
- **Native helper:** `mrbgems/study_audio` (planned Phase 3) exposes raw silence
  gaps because raylib `Wave` sample data is not accessible from Ruby.
- **Engine touch:** `src/main.c` needs a small patch to expose command-line args
  as `ARGV` (Phase 2); otherwise the `argv → study-player view` requirement is
  unreachable from Ruby.
- **Cross-refs:** rules `mruby-rebuild`, `dont-edit-generated`, `wsl-toolchain`;
  knowledge `rmlui-binding`, `raylib-binding`, `flecs-binding`, `build-system`;
  `notes/study-player-rewrite-plan.md`.

## Why a native silence scanner is needed

The generated raylib bindings expose `Rl.load_wave` and `Rl.wave_format`, but
`Wave.data` is a raw `void*` buffer that the generator intentionally skips.
There is no Ruby-visible `Wave#samples`. Ported silence detection therefore needs
a tiny C helper (`mrbgems/study_audio`) that does the I/O and returns a plain
Ruby array of `[start_seconds, end_seconds]` gaps.

The **decision logic** (threshold comparison, 10 ms chunking, padding shrink,
portion math, auto-pause FSM) stays in pure Ruby under `StudyPlayer::Core`.
The native helper only solves the *data access* problem.

##ARGV flow

`src/main.c` currently only uses `argv[1]` as the script path. To satisfy
"audio file arg → study-player view", pass `argv[2..]` into the mruby VM as a
constant named `ARGV`:

```c
mrb_value argv_ary = mrb_ary_new(mrb);
for (int i = 2; i < argc; i++) {
  mrb_ary_push(mrb, argv_ary, mrb_str_new_cstr(mrb, argv[i]));
}
mrb_define_const(mrb, mrb->object_class, "ARGV", argv_ary);
```

Web builds inherit this because `Module.arguments` is mapped to `argc/argv` in
emscripten's generated `main()`.

## Non-blocking seek (`skip_auto_update`)

After `Rl.seek_music_stream`, `Rl.get_music_time_played` can briefly report the
old position. The original used `skipAutoUpdate = 3` frames to let the audio
engine settle. We model this as a Flecs component field:

```ruby
PlaybackState = world.struct("PlaybackState", "{ ... int skip_auto_update; }")
```

A system applies the seek and sets the counter to 3; the update system skips
`get_music_time_played` while the counter is positive.

## RmlUi layout quirks

- Use `left:` / `top:` for absolute elements. RmlUi miscomputes `right:` in this
  backend, so a panel `right: 60px; width: 240px` can render off-screen.
- For progress-bar clicks, use the event's `mouse_x` minus the element's
  `absolute_left`, divided by `client_width`.
- Checkboxes in RmlUi read/write the `checked` attribute, not just the value.
- The RmlUi context should be initialized **after** `Rl.init_window` and fonts
  must be loaded before the document.

## Adding `mrbgems/study_audio`

Because the RmlUi gem already forces `MRB_USE_CXX_EXCEPTION`, adding any gem is
an ABI toggle. Follow rule `mruby-rebuild`:

```sh
rm -rf vendor/mruby/build
./rebuild.sh
```

## Constants to preserve

- Silence threshold: **0.015**.
- Minimum silence duration: **0.75 seconds**.
- Padding zone: **0.25 seconds** on each side of a silence region.
- Default seek lead-in: **2 render frames** = `2.0 / 60.0` seconds
  (ported from original; may tune later).
- Default `skip_auto_update`: **3 frames** at target 60 FPS.
