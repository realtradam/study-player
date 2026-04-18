# Phase 2 — Progress Bar & Seeking UI

Visual progress display and mouse-based seeking.

---

## 2.1 Progress bar rendering

- Horizontal bar centered at ~Y=360, width = 80% of window (1024px), height = 20px.
- Background: dark gray rectangle via `DrawRectangleRec()`.
- Fill: accent color rectangle, width proportional to `currentTime / duration`.
- Only drawn when `state.loaded` is true.

## 2.2 Time labels

- Left of bar: current time formatted as `MM:SS` or `HH:MM:SS` (if ≥ 3600s).
- Right of bar: total duration in the same format.
- Helper function: `void format_time(float seconds, char *buf, int bufsize)`.

## 2.3 Click-to-seek

- On `IsMouseButtonPressed(MOUSE_BUTTON_LEFT)`, check if click is within progress bar bounding box.
- Compute target time: `(mouseX - barX) / barWidth * duration`.
- Call `SeekMusicStream()` to that position.
- Works in both playing and paused states.

---

## Acceptance criteria

- Progress bar visually tracks playback position in real time.
- Time labels update every frame and format correctly (MM:SS vs HH:MM:SS).
- Clicking anywhere on the bar seeks to the corresponding position instantly.
- Clicking outside the bar does nothing.
