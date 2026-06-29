# Tribal knowledge: Study Player (rewrite)

## At a glance
- **Key files:** `game/study_player/study_player.rb` (monolithic entry point),
  `src/main.c` (ARGV patch), `mrbgems/raylib/src/raylib_bindings.c`
  (FilePathList#path_at).
- **Run:** `./zig-out/bin/game game/study_player/study_player.rb [audio.mp3]`
- **Cross-refs:** plan `notes/study-player-rewrite-plan.md`, template rules
  `.agents/rules/*`, build `.agents/knowledge/build-system.md`.
- **mrbgems/study_audio:** C-level Wave scanner (scan_silence) + load_wave_samples.
  See §"Phase 3 scar tissue" below.

## Phase 3 scar tissue

### Ruby array size limit → C scanner
Building a Ruby `Array` of millions of floats from raw audio samples causes
`ArgumentError: array size too big` in mruby. A 1.5MB MP3 decodes to ~4M float
frames. **Fix:** `StudyAudio.scan_silence(path, threshold, min_duration)` runs
the peak-scanning loop in C and returns only the silence region pairs (max 4096).
The pure-Ruby `Core.detect_silence(samples, ...)` is retained for testing with
synthetic data; the runtime path uses the C scanner.

### mrbgem naming: `mrb_<dirname>_gem_init` (NOT `mrb_mruby_...`)
The mruby build system generates a `gem_init.c` that calls
`GENERATED_TMP_mrb_study_audio_gem_init`, which in turn calls
`mrb_study_audio_gem_init()`. The function name must match the gem directory
name exactly: `mrb_<gemname>_gem_init` where gemname is the directory basename
with hyphens → underscores. `mrb_mruby_study_audio_gem_init` → undefined symbol.

### Native helper include path
The `study_audio` C file includes `"raylib.h"` — the mrbgem.rake must add
`vendor/raylib/src` to `spec.cc.include_paths` so the mruby build can find it.
The raylib symbols are resolved at the final link step (libraylib.a after
libmruby.a in build.zig).

### Music files have zero silences
The silence detector (threshold 0.015, min 0.75s) finds 0 regions in music
files — expected. The algorithm targets speech/audiobook content with clear
pauses between sentences. Verification with synthetic data (CRuby smoke test)
confirmed the algorithm works; testing with real speech files is deferred.

### No screenshot tooling on WSLg/Wayland
WSLg renders via Wayland; `ffmpeg -f x11grab` captures only X11 windows (black
screen). `grim` (Wayland screenshot) is not installed. Visual verification is
manual (user looks at the WSLg window). A future improvement could add a
`TakeScreenshot` binding or use `pipewire` for Wayland capture.

## mruby compatibility discoveries (Phase 2 scar tissue)

### No require/require_relative/load in default gembox
The mruby default gembox (`conf.gembox 'default'`) does NOT include file
loading. `require`, `require_relative`, and `load` are all undefined. The
template's existing game scripts (ragdoll_demo.rb, etc.) are monolithic
single-file scripts for this reason.

**Fix for Phase 2:** Inlined all modules into `game/study_player/study_player.rb`
(single ~440-line script). Individual module files (`components.rb`, `core.rb`,
etc.) are retained on disk as design documentation plus a `systems/` directory;
they are NOT loaded at runtime.

**Future:** Adding `conf.gem 'mruby-require'` to `build_config.rb` would enable
multi-file loading. This triggers the `rm -rf vendor/mruby/build` rebuild rule
and is deferred to Phase 3 (plan §8 mentions `mrbgems/study_audio` which already
requires a full rebuild).

### Flecs struct descriptor: `int` is invalid → use `int32_t`
Flecs meta descriptor parser does NOT recognise `int` as a type name. Valid
primitive type names in the descriptor string are:
- `int8_t`, `int16_t`, `int32_t`, `int64_t` (signed integers)
- `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t` (unsigned)
- `float`, `double`
- `bool`
- `string`
- `char`, `byte`

`int` → `int32_t` was required in `PlaybackState` and `StudyState` descriptors.

### Struct.new keyword_init not supported
mruby's `Struct` does not support `keyword_init: true`. Use a plain class with
`attr_accessor` + `initialize` instead (see `StudyPlayer::Runtime`).

### TOPLEVEL_BINDING not available
CRuby's `TOPLEVEL_BINDING` constant does not exist in mruby.

### defined? not reliable as a guard
`defined?(ARGV)` is not available; use `begin/rescue` or just reference `ARGV`
directly (it is always set by the `src/main.c` patch).

## Drag-drop: FilePathList#path_at hand-written method
The generated raylib bindings only expose `FilePathList#count`/`count=`. The
`paths` member is `char**` — a raw pointer the generator skips. A small
hand-written method `path_at(index)` was added to
`mrbgems/raylib/src/raylib_bindings.c` to enable indexed path access for
drag-and-drop. This method is registered on `Rl::FilePathList` after the
generated registrar runs.

The Ruby `CheckFileDrop` system (`game/study_player/study_player.rb`) is correct
and identical in pattern to the original C app. If drag-and-drop is unreliable,
the cause is NOT the Ruby — it is the GLFW/Wayland backend: see
`.agents/knowledge/environment.md` § "Wayland drag-and-drop crashes on GLFW 3.4"
(the `wl_data_offer` NULL-listener crash + the `patches/glfw-wayland-dnd-crash.patch`
fix). The X11 `../source` app never hits it.

## Non-blocking seek (skip_auto_update)
After `Rl.seek_music_stream`, raylib's miniaudio stream may briefly report the
old position. The `skip_auto_update` counter (set to 3 frames = ~50ms at 60fps)
skips `Rl.get_music_time_played` sampling while decrementing each frame. The
`UpdateSystem` (ON_UPDATE) handles this cooldown; `SeekSystem` (PRE_UPDATE)
applies the seek and sets the counter. This mirrors the original C source's
`skipAutoUpdate` pattern.

## ARGV patch (src/main.c)
Added `#include <mruby/array.h>` and a block in `main()` that builds an
`mrb_value` array from `argv[2..]` and defines it as `ARGV` constant. This
is the only way Ruby game code can access command-line arguments in this
architecture (there is no `ENV` for process args in the default gembox).

## Wayland/WSLg screenshot path quirk
`JAMSTACK_SCREENSHOT=...` with a path starting with `/` resolves relative to
CWD, not as an absolute filesystem path. Use a bare filename (e.g.
`JAMSTACK_SCREENSHOT=output.png`) to write in the project root, or use a full
path without a leading `/` quirk. This is a raylib/Wayland interaction, not
a study-player-specific issue, but it surfaces during verification.
