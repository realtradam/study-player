# Phase 1 — Audio Playback & Controls

Core audio functionality. After this phase the app is usable as a keyboard-driven player with no visual progress display.

---

## 1.1 Drag & drop file loading

- Use `IsFileDropped()` / `LoadDroppedFiles()` / `UnloadDroppedFiles()`.
- Validate file extension is `.mp3` (case-insensitive).
- Unload previous `MusicStream` if one is already loaded.
- `LoadMusicStream()`, `PlayMusicStream()`, set `state.loaded = true`, `state.playing = true`.
- Store duration via `GetMusicTimeLength()`.
- Extract basename from path for `state.filename`.

## 1.2 Play/pause with rewind

- `Space` toggles play/pause.
- On pause: capture current position via `GetMusicTimePlayed()`, call `PauseMusicStream()`, then `SeekMusicStream()` back 1 second (clamped to 0).
- On resume: `ResumeMusicStream()`.

## 1.3 Arrow key seeking

- `Left Arrow`: seek backward 5 seconds (clamped to 0).
- `Right Arrow`: seek forward 5 seconds (clamped to duration).
- Works in both playing and paused states.

## 1.4 Music stream update

- Call `UpdateMusicStream()` every frame when `state.loaded` is true.
- This is required for Raylib's streaming audio to function.

---

## Acceptance criteria

- Can drag an MP3 onto the window and hear it play immediately.
- Space pauses (with 1s rewind) and resumes.
- Arrow keys seek ±5s with no audible delay.
- Dropping a new file replaces the current one cleanly (no audio glitches).
