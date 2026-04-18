# Phase 3 — Polish & Status Display

Final UI elements and visual polish.

---

## 3.1 Title text

- Draw "Study Player" centered near top of window (large font size, ~30px).

## 3.2 Filename display

- Below title: show loaded filename, or "Drag an MP3 file here" when nothing is loaded.
- Centered horizontally.

## 3.3 Playback status

- Below progress bar: display "PLAYING" or "PAUSED" centered.
- Show nothing when no file is loaded.

## 3.4 Help text

- Bottom area of window: "Space: play/pause   ←/→: seek 5s   Click bar: seek".
- Smaller font, muted color.

## 3.5 Window title update

- Call `SetWindowTitle()` to include the filename when a file is loaded (e.g., "Study Player - chapter1.mp3").
- Reset to "Study Player" if relevant.

## 3.6 Visual refinements

- Consistent font sizes and vertical spacing across all text elements.
- Color scheme: dark background (#1a1a2e or similar), light text (#eaeaea), accent color for progress fill (#e94560 or similar).
- Ensure all text is readable and well-positioned at 1280×720.

---

## Acceptance criteria

- All text elements are visible and properly centered.
- Status reflects actual playback state and updates immediately on play/pause.
- Window title bar shows the current filename.
- The app looks clean and intentional — no overlapping elements, no clipping.
