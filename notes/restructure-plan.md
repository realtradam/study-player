# Restructure plan — single-file → modular C/Raylib project

> **Status:** Pending. This document describes the target architecture and the
> step-by-step plan for splitting `src/main.c` (778 lines) into composable
> modules. The orchestrator will execute this plan.

---

## §1 Design principles

1. **`.h` = contract, `.c` = implementation.** Every module exposes a single
   self-contained header. No other module ever includes a `.c` file.
2. **All shared mutable state through `PlayerState*`.** Defined in `types.h`.
   File-scope statics only for module-private data (fonts, colors in UI).
3. **One `.o` per module.** Each `.c` compiles independently. The linker
   resolves dependencies. This makes parallel agent waves possible.
4. **Zero-copy from current codebase.** Move functions as-is, then improve.
   The first pass preserves all behavior exactly.
5. **Linux native + Windows cross-compile.** Both platforms supported. The
   Makefile handles both targets (platform conditionals in the build, not in
   the source unless needed).
6. **Minimal module count.** Four modules + types header. Don't over-split.

---

## §2 Target module structure

```
src/
  types.h          CONTRACT — shared types, enums, constants
  player.h         CONTRACT — audio playback
  player.c         IMPL
  study.h          CONTRACT — silence detection + study mode
  study.c          IMPL
  ui.h             CONTRACT — rendering + input
  ui.c             IMPL
  main.c           COMPOSITION ROOT — entry point + main loop
```

### §2.1 `src/types.h` — shared types and constants

No `.c` file. Pure definitions.

```c
#pragma once

// ── Platform detection ──
#ifdef PLATFORM_LINUX
  #define _GLFW_X11
#endif

// ── Constants ──
#define SCREEN_W 1920
#define SCREEN_H 1080
#define MAX_SILENCE_REGIONS 4096

// ── Types ──
typedef struct {
    float start;  /* normalized 0..1 */
    float end;    /* normalized 0..1 */
} SilenceRegion;

typedef struct {
    Music music;
    bool loaded;
    bool playing;
    float duration;
    float currentTime;
    char filename[256];
    SilenceRegion silence[MAX_SILENCE_REGIONS];
    int silenceCount;
    bool studyMode;
    bool wasInSilence;
    int  lastSilenceIdx;
    int skipAutoUpdate;
    double lastVPress;
} PlayerState;
```

### §2.2 `src/player.h` — audio playback contract

```c
#pragma once
#include "types.h"

void player_load(PlayerState *s, const char *path);
void player_unload(PlayerState *s);
void player_seek(PlayerState *s, float seconds);
void player_play(PlayerState *s);
void player_pause(PlayerState *s);
void player_update(PlayerState *s);   /* call once per frame */
void format_time(float seconds, char *buf, int bufsize);
const char *basename_from_path(const char *path);
```

**`src/player.c`** implements:
- `player_load()` — load MP3, set up Music stream, start playback, update filename + window title, calls `study_detect_silence()` to populate silence regions
- `player_unload()` — stop + unload music stream
- `player_seek()` — seek music stream to target seconds
- `player_play()` / `player_pause()` — Resume/Pause + update state
- `player_update()` — `UpdateMusicStream()` + `GetMusicTimePlayed()` with skip logic
- `format_time()` — seconds → "MM:SS" or "H:MM:SS" string
- `basename_from_path()` — extract filename from path
- `strcasecmp_ext()` — helper for extension checking (static)

### §2.3 `src/study.h` — study mode contract

```c
#pragma once
#include "types.h"

void study_detect_silence(const char *path, PlayerState *s, float threshold, float minDuration);
int  study_find_silence_at(const PlayerState *s, float pos);
float study_speaking_portion_start(const PlayerState *s, int portion);
int  study_current_portion(const PlayerState *s, float pos);
int  study_total_portions(const PlayerState *s);
float study_segment_seek_target(const PlayerState *s, int portion);
bool study_in_padding_zone(const PlayerState *s, float pos, int portion);
void study_update(PlayerState *s);    /* auto-pause logic for one frame */
```

**`src/study.c`** implements:
- `study_detect_silence()` — Wave analysis, silence region detection with padding (move from current `detect_silence`)
- `study_find_silence_at()` — find silence region at normalized position
- `study_speaking_portion_start()` — get start of speaking portion N
- `study_current_portion()` — get current speaking portion index
- `study_total_portions()` — total speaking portions
- `study_segment_seek_target()` — seek target for a portion (with 2-frame offset)
- `study_in_padding_zone()` — check if position is in padding zone
- `study_update()` — the auto-pause state machine: detect silence entry/exit, auto-pause → seek to next portion

### §2.4 `src/ui.h` — rendering + input contract

```c
#pragma once
#include "types.h"

void ui_init(void);
void ui_destroy(void);
void ui_render_frame(PlayerState *s);
```

**`src/ui.c`** implements:
- **File-scope statics:** fonts (`fontSmall`, `font`, `fontMed`, `fontLarge`, `fontHelp`), sizes, colors, layout constants, button positions
- `ui_init()` — load fonts, set colors, compute layout
- `ui_destroy()` — unload embedded fonts
- `ui_render_frame()` — one complete frame:
  - Handle drag-drop file loading (desktop) → calls `player_load()`
  - Handle keyboard input (C, N, Space, V, B, Arrows, 0–9, Up/Down) → calls `player_seek()`, `player_play()`, `player_pause()`
  - Handle mouse input (click-to-seek, play/pause button, section nav buttons, study mode checkbox)
  - Call `player_update()` for music stream update
  - Call `study_update()` for study mode auto-pause logic
  - Call `BeginDrawing()` / `EndDrawing()` with all rendering (title, progress bar, time labels, percentage, buttons, checkboxes, help text)
- `draw_text_centered()` — static helper
- `draw_play_icon()`, `draw_pause_icon()`, `draw_seek_back_icon()`, `draw_seek_fwd_icon()` — static helpers
- `button_hit()` — static helper

### §2.5 `src/main.c` — composition root

No `.h` file. Entry point only.

```c
#include "raylib.h"
#include "player.h"
#include "study.h"
#include "ui.h"
#include "font_data.h"
#ifdef PLATFORM_WEB
#include <emscripten/emscripten.h>
#endif

/* File-scope PlayerState (needed for emscripten main loop callback) */
static PlayerState state = { 0 };

#ifdef PLATFORM_WEB
EMSCRIPTEN_KEEPALIVE
void load_file_web(const char *path) {
    player_load(&state, path);
}
#endif

static void update_frame(void) {
    ui_render_frame(&state);
}

int main(void) {
    InitWindow(SCREEN_W, SCREEN_H, "Study Player");
    InitAudioDevice();
    SetTargetFPS(60);
    ui_init();

    memset(&state, 0, sizeof(state));
    state.studyMode = true;
    state.lastSilenceIdx = -1;

#ifdef PLATFORM_WEB
    emscripten_set_main_loop(update_frame, 0, 1);
#else
    while (!WindowShouldClose()) {
        update_frame();
    }
#endif

    player_unload(&state);
    ui_destroy();
    CloseAudioDevice();
    CloseWindow();
    return 0;
}
```

---

## §3 Dependency graph

```
types.h  ← player.h  ← ui.h
         ← study.h   ← ui.h
                     ← player.c  (player depends on study for silence detection)
                     ← main.c

player.h ← player.c  (includes: types.h)
study.h  ← study.c   (includes: types.h)
ui.h     ← ui.c      (includes: types.h, player.h, study.h)
```

- `types.h` — no dependencies (pure definitions)
- `player.h` — depends on `types.h` (PlayerState, Music type via raylib)
- `study.h` — depends on `types.h` (PlayerState, SilenceRegion)
- `ui.h` — depends on `types.h` (PlayerState)
- `player.c` — depends on `types.h`, `player.h` (its own contract), `study.h` (calls `study_detect_silence` in `player_load`), `raylib.h`
- `study.c` — depends on `types.h`, `study.h` (its own contract), `raylib.h`
- `ui.c` — depends on `types.h`, `player.h`, `study.h`, `ui.h`, `raylib.h`, `font_data.h`
- `main.c` — depends on all `.h` files, `raylib.h`, `font_data.h`, `emscripten.h` (web only)

All modules compile to `.o` independently — zero `.c` includes another `.c`.

---

## §4 Wave plan

### WAVE 0 — Orchestrator + build system agent (sequentially)

**Orchestrator (direct work):**
1. Write `src/types.h` with all shared types and constants
2. Pre-author `src/player.h`, `src/study.h`, `src/ui.h` — define every public
   function signature so module agents have fixed contracts to implement
   against
3. Write TASK prompts to `prompts/build-system.md`, `prompts/player.md`,
   `prompts/study.md`, `prompts/ui.md`, `prompts/main.md`

**Build system agent:** (reads ANY file, writes only Makefile + bin/*)
1. Update `Makefile`:
   - Linux native target (default): `gcc -o build/study-player src/*.c ...`
   - Windows target (`make windows`): cross-compile via MinGW
   - Font header generation as a make prerequisite
   - `SRCS = $(wildcard src/*.c)`, `OBJS = $(SRCS:.c=.o)`
   - Raylib `.o` compilation with `-w` (third-party warnings suppressed)
2. Update `.gitignore` (add `prompts/`, `reports/`)

**Verification:** Module `.h` files compile cleanly (no syntax errors).
`make` will fail on missing `.c` implementations — that's expected, WAVE 1
resolves it.

### WAVE 1 — All `.c` implementations in parallel (disjoint files)

Four module agents, launched as concurrent tool calls. Each owns its `.h` +
`.c` pair, reads only other `.h` files, writes only its own files:

| Agent | Files it owns | .h files it reads |
|---|---|---|
| Agent A: player | `src/player.h`, `src/player.c` | `src/types.h` |
| Agent B: study | `src/study.h`, `src/study.c` | `src/types.h` |
| Agent C: ui | `src/ui.h`, `src/ui.c` | `src/types.h`, `src/player.h`, `src/study.h` |
| Agent D: main | `src/main.c` (no .h) | all `.h` files |

File sets are DISJOINT. No compile-time dependency between `.c` files — each
compiles to `.o` independently. All `.h` contracts were fixed in WAVE 0.

**Verification:** `make clean && make -j$(nproc)` — exit 0, zero warnings
(Linux). Then `make windows -j$(nproc)` — exit 0, zero warnings (Windows).

### WAVE 2 (if needed) — Integration fixes

Any link errors, behavioral regressions, or contract gaps discovered during
WAVE 1 verification. Summon affected agents to fix.

---

## §5 Function migration map

Every function in the current `src/main.c` moves to exactly one target file:

| Current function | → Target file | New name |
|---|---|---|
| `SilenceRegion` struct | `types.h` | (unchanged) |
| `PlayerState` struct | `types.h` | (unchanged) |
| `#define` constants | `types.h` | (unchanged) |
| `strcasecmp_ext()` | `player.c` | static (no prefix) |
| `detect_silence()` | `study.c` | `study_detect_silence()` |
| `basename_from_path()` | `player.c` | (unchanged, public) |
| `seek_to()` | `player.c` | `player_seek()` |
| `format_time()` | `player.c` | (unchanged, public) |
| `find_silence_at()` | `study.c` | `study_find_silence_at()` |
| `speaking_portion_start()` | `study.c` | `study_speaking_portion_start()` |
| `current_speaking_portion()` | `study.c` | `study_current_portion()` |
| `total_speaking_portions()` | `study.c` | `study_total_portions()` |
| `segment_seek_target()` | `study.c` | `study_segment_seek_target()` |
| `in_padding_zone()` | `study.c` | `study_in_padding_zone()` |
| `draw_text_centered()` | `ui.c` | static (no prefix) |
| `draw_play_icon()` | `ui.c` | static (no prefix) |
| `draw_pause_icon()` | `ui.c` | static (no prefix) |
| `draw_seek_back_icon()` | `ui.c` | static (no prefix) |
| `draw_seek_fwd_icon()` | `ui.c` | static (no prefix) |
| `button_hit()` | `ui.c` | static (no prefix) |
| `load_audio_file()` | `player.c` | `player_load()` |
| `load_file_web()` (emscripten) | `main.c` | (unchanged) |
| `update_frame()` | `main.c` | (simplified — just calls `ui_render_frame()`) |
| `main()` | `main.c` | (unchanged, simplified) |
| File-scope statics (state, fonts, colors, layout) | `main.c` (`state`), `ui.c` (rest) | — |

**Auto-pause logic** currently inlined in `update_frame()` (lines 533–562)
moves into `study_update()` in `study.c`. The UI module calls
`study_update(&state)` after `player_update(&state)`.

---

## §6 Current code as-is invariants (must preserve)

During the split, preserve every existing behavior:
1. Drag-and-drop MP3 loading (desktop)
2. All keyboard shortcuts: C, N, Space, V, B, Arrows, Up, Down, 0–9
3. Click-to-seek on progress bar
4. Study mode auto-pause at silence boundaries
5. Study mode checkbox toggle
6. Play/pause button and section navigation buttons
7. Progress bar rendering with elapsed/remaining time labels
8. Percentage display above progress bar
9. "PLAYING"/"PAUSED" status text
10. Help text at bottom
11. Dark theme colors
12. Embeddable font support (`FONT_EMBEDDED`)
13. Web platform support (`PLATFORM_WEB`, emscripten main loop, file upload)
14. Linux native build + Windows cross-compile both work
