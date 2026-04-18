# Study Player

A keyboard-driven MP3 player built with [raylib](https://github.com/raysan5/raylib), cross-compiled for Windows from Linux using MinGW.

<img width="1923" height="1125" alt="image" src="https://github.com/user-attachments/assets/a2e2363e-cc0a-4936-8b04-0f32886ff9d8" />

### Dependencies

Clone the following repositories into the `deps/` directory:

```bash
mkdir -p deps
git clone https://github.com/raysan5/raylib.git deps/raylib
git clone https://github.com/raysan5/raygui.git deps/raygui
```

You also need the MinGW cross-compiler and `xxd` installed:

```bash
# Arch
sudo pacman -S mingw-w64-gcc vim  # xxd is part of vim
```

### Custom Fonts

Place a `.otf` or `.ttf` font file in the `resources/` directory. The build script automatically finds the first font file and embeds it into the executable — no external font files are needed at runtime.

```bash
mkdir -p resources
cp /path/to/your/font.otf resources/
```

If no font file is present, the app falls back to the built-in raylib default font.

### Building

```bash
bin/build
```

The output binary is `build/study-player.exe`.

### Usage

Run the `.exe` on Windows (or under Wine). Drag an `.mp3` file onto the window to load it.

| Key | Action |
|---|---|
| **Drag & drop** | Load and play an `.mp3` file |
| **C** | Pause (does nothing if already paused) |
| **N** | Play from start of current section (does nothing if already playing) |
| **Space (hold)** | Resume/override study mode auto-pause (never pauses) |
| **Up Arrow** | Play |
| **Down Arrow** | Pause (rewinds 1s) |
| **Left Arrow** | Seek backward 5 seconds |
| **Right Arrow** | Seek forward 5 seconds |
| **V** | Jump to start of current section (if in padding/silence, jumps to previous) |
| **B** | Jump to start of next section |
| **0–9** | Jump to 0%–90% of the track |
| **Click progress bar** | Seek to position |

### Study Mode

Study Mode is designed for audiobooks and language learning. It is **enabled by default** and can be toggled with the checkbox in the bottom-right corner.

When the audio is loaded, the app analyzes it to detect silence gaps between spoken sections. A section counter (e.g. "5/70") shows which speaking section you're in.

**How it works:**

The app detects silence gaps in the audio and adds a 0.25-second padding zone between silence and speech. Each speaking section is separated by these gaps.

- **Auto-pause at silence entry** — When playback crosses from the padding zone into a silence gap, it automatically pauses and jumps the playhead forward to the start of the next speaking section (just inside the padding).
- **Auto-pause at silence exit** — If audio plays through a silence gap (e.g. via Space override), it auto-pauses when exiting the silence into the next padding/speech zone.
- **C** — Pauses playback at the current position. Does nothing if already paused.
- **N** — Seeks to the start of the current speaking section and resumes playback. Does nothing if already playing.
- **Space (hold)** — Overrides study mode auto-pauses while held. If paused, pressing Space resumes playback. Space never pauses — it only resumes/overrides.
- **V** — Jumps to the start of the current speaking section. If the playhead is in the padding zone or in silence, jumps to the previous section instead.
- **B** — Jumps to the start of the next speaking section.

Section navigation buttons (◀ ▶) are also available next to the section counter.

**Visual indicators:**

- The "PLAYING"/"PAUSED" text and play button turn a darker red during silence sections.
- The section counter below the buttons shows your current position (e.g. "12/70").

When Study Mode is **off**, C pauses and N resumes without any section-seeking behavior. Space still only resumes (never pauses).

### Project Structure

```
src/main.c        Application source
deps/raylib/      raylib (cloned separately)
deps/raygui/      raygui (cloned separately)
build/            Build output (gitignored)
resources/        Font files (gitignored)
bin/              Build and utility scripts
```
