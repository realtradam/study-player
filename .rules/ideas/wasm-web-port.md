# WASM / Web Port

## Overview

Port the audio engine and study mode logic to WASM, exposing a JavaScript API so a web frontend can drive it.

Raylib has built-in Emscripten support, so two approaches are possible:

1. **Full raylib WASM port** — keep the raylib-rendered UI, compile everything to WASM with Emscripten.
2. **Headless WASM module + JS frontend** — strip rendering, export a C API, build a custom HTML/CSS/JS UI.

## What ports easily

- **Silence detection** — pure C math on WAV sample data, no platform dependencies.
- **Study mode state machine** — segment navigation, auto-pause logic, padding zones.
- **Raylib rendering** — built-in `emscripten_set_main_loop` support.

## What needs adaptation

### File loading
No native drag-and-drop. Options:
- JavaScript `FileReader` API → pass bytes into WASM memory via `EM_ASM` or exported function.
- Fetch from URL → Emscripten's async file fetching.
- Requires ~50-100 lines of JS↔C glue.

### Main loop
Replace `while (!WindowShouldClose())` with `emscripten_set_main_loop(update_frame, 0, 1)`. Extract the loop body into a single `update_frame()` function.

### JavaScript API (if using custom web frontend)
Export functions via `EMSCRIPTEN_KEEPALIVE`:
- `load_track(uint8_t *data, int len)` — load audio from buffer
- `play()`, `pause()`, `resume()`
- `seek(float seconds)`
- `get_progress()` — returns current time
- `get_duration()`
- `get_segment_count()`
- `get_current_segment()`
- `get_segments()` — returns silence region data
- `set_study_mode(bool enabled)`
- `is_playing()`

~10-15 wrapper functions total.

## Effort estimates

| Task | Effort |
|------|--------|
| Emscripten build setup (Makefile target, flags) | ~1 day |
| Main loop adaptation (`emscripten_set_main_loop`) | ~2 hours |
| File loading JS↔C bridge | ~half day |
| C API exports for JS | ~half day |
| Full raylib-rendered WASM port (approach 1) | **~2 days total** |
| Custom JS/HTML/CSS frontend (approach 2) | **~4-5 days total** |

## Notes

- The core audio logic (silence detection, segment navigation, study mode) requires zero changes.
- Raylib's audio uses miniaudio internally, which has Emscripten support via Web Audio API.
- Consider using Emscripten's `-s ALLOW_MEMORY_GROWTH=1` since audio files can be large.
- File size limit may be a concern — browsers typically handle files up to a few hundred MB.
