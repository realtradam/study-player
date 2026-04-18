# Study Player — Implementation Plan

## Overview

A single-file C application using Raylib that plays MP3 audiobooks with minimal UI focused on keyboard-driven study workflow.

---

## Build

- **Build system:** Single `Makefile` at project root with cross-platform support.
- **Linux:** Compile with gcc, link against raylib, `-lm -lpthread -ldl -lrt -lX11`.
- **Windows:** Cross-compile with `x86_64-w64-mingw32-gcc`, link against raylib, `-lgdi32 -lwinmm`. Alternatively native MSVC or MinGW on Windows.
- **Makefile targets:** `make` (Linux default), `make PLATFORM=WINDOWS` (cross-compile for Windows).
- **Dependencies:** `deps/raylib` (already present), `deps/raygui` (already present — optional).
- **Source:** `src/main.c` (single file).
- **Output:** `build/study-player` (Linux), `build/study-player.exe` (Windows).
- **Compile raylib as static library** first (`deps/raylib/src/`), then link.
- **bin/build:** Shell script wrapping `make`.
- **bin/run:** Shell script wrapping `make && ./build/study-player`.

---

## Application State

```c
typedef struct {
    Music music;           // Raylib Music stream (MP3)
    bool loaded;           // Whether a file is loaded
    bool playing;          // Whether audio is currently playing
    char filepath[512];    // Path of loaded file
    char filename[256];    // Display name (basename)
    float duration;        // Total length in seconds
} AppState;
```

No persistence. All state is in-memory only.

---

## Window

- **Size:** 1920×1080, not resizable.
- **Title:** "Study Player" (update to include filename when loaded).
- **Target FPS:** 60.
- **Background:** Dark solid color.

---

## Audio Approach — Instant Seek

Raylib's `Music` type is a streaming audio type. Key functions:

- `LoadMusicStream(path)` — load MP3.
- `PlayMusicStream(music)` / `PauseMusicStream(music)` / `ResumeMusicStream(music)`.
- `SeekMusicStream(music, positionInSeconds)` — instant seek.
- `GetMusicTimePlayed(music)` — current position.
- `GetMusicTimeLength(music)` — total duration.
- `UpdateMusicStream(music)` — **must be called every frame** to feed audio buffer.

These provide instant play/pause/seek with no delay.

---

## UI Layout (1920×1080)

```
+--------------------------------------------------+
|                                                  |
|           "Study Player"  (title)                |
|                                                  |
|         [filename or "Drop an MP3 file"]         |
|                                                  |
|                                                  |
|    03:42 [=======>-----------------] 58:31       |
|           ^ progress bar (clickable)             |
|                                                  |
|          PLAYING  /  PAUSED  /  (empty)          |
|                                                  |
|     Space: play/pause  ←→: seek 5s              |
|                                                  |
+--------------------------------------------------+
```

---

## Scaffolding (before phases)

Set up before any feature work:

1. **Makefile** — cross-platform (Linux + Windows cross-compile). Compile raylib as static lib, compile+link `src/main.c`.
2. **bin/build, bin/run** — convenience shell scripts.
3. **src/main.c skeleton** — `InitWindow`, `InitAudioDevice`, empty main loop with `ClearBackground`, `CloseWindow`. Confirms build pipeline works.
4. **build/ in .gitignore**.

---

## Phases

Implementation is split into three phases, each in its own file:

- **[Phase 1 — Audio Playback & Controls](phase1.md):** Drag-and-drop loading, play/pause with 1s rewind, arrow key seeking.
- **[Phase 2 — Progress Bar & Seeking UI](phase2.md):** Progress bar rendering, time labels, click-to-seek.
- **[Phase 3 — Polish & Status Display](phase3.md):** Title, filename, status text, help text, window title, visual refinements.

---

## File Structure

```
study-player/
├── .rules/plan/
│   ├── plan.md               # This file (overview + shared context)
│   ├── phase1.md             # Audio playback & controls
│   ├── phase2.md             # Progress bar & seeking UI
│   └── phase3.md             # Polish & status display
├── deps/
│   ├── raylib/               # Already present
│   └── raygui/               # Already present (optional use)
├── src/
│   └── main.c                # All application code
├── Makefile                   # Build raylib + application (Linux & Windows)
├── bin/
│   ├── build                 # make
│   └── run                   # make && ./build/study-player
└── build/                    # Build artifacts (gitignored)
```

---

## Constraints

- MP3 only.
- No playlist / queue — one file at a time.
- No persistence — position lost on close.
- No volume control (system volume is sufficient).
- Window fixed at 1920×1080.
- Must build for Windows (cross-compile from Linux with MinGW, or native MinGW on Windows).
