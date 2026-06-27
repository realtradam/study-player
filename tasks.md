# tasks.md — live progress checklist

> Updated by the orchestrator after each milestone. One line per completed wave.

---

## Module split (COMPLETE)

The single-file `src/main.c` (778 lines) has been decomposed into 7 modules
with separate headers for code isolation and parallel agent development.

- [x] WAVE 0 — Orchestrator: pre-author all `.h` contracts
  - [x] `src/types.h` — PlayerState, SilenceRegion, UILayout, constants
  - [x] `src/player.h` — audio playback contract
  - [x] `src/study.h` — study mode contract
  - [x] `src/ui.h` — rendering + input contract (UIState)
  - [x] `src/config.h` — updated to include types.h (UILayout moved)
- [x] WAVE 1 — All `.c` implementations
  - [x] `src/player.c` — load/play/pause/seek/update/format_time
  - [x] `src/study.c` — detect_silence, portion nav, auto-pause check
  - [x] `src/ui.c` — fonts, colors, drawing, icons, input, smart play
  - [x] `src/main.c` — thin composition root (main loop, tabs, drag-drop)
- [x] WAVE 2 — Integration fixes
  - [x] Fixed multiple-definition link error (font_data.h single-include rule)
- [x] Post-milestone verification
  - [x] `make clean && make -j$(nproc)` exits 0, zero warnings (Linux)
  - [x] Makefile auto-discovers new `.c` files via `$(wildcard src/*.c)`
  - [x] All state passed by pointer — no global mutable variables
  - [x] `font_data.h` included in exactly one `.c` file (ui.c)

## Branch structure

- **V1** branch — preserves the pre-refactor state (single-file main.c)
- **dev** branch — the refactored modular codebase (current)

---

## Open items (future)

- [ ] `make windows -j$(nproc)` cross-compile verification (needs MinGW)
- [ ] `bin/build-web` web build verification (needs emscripten)
- [ ] Unit tests for study module (portion navigation edge cases)
- [ ] Volume control
- [ ] Playlist support
