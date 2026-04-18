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
| **Space** | Play/pause (see Study Mode below) |
| **Up Arrow** | Play |
| **Down Arrow** | Pause (rewinds 1s) |
| **Left Arrow** | Seek backward 5 seconds |
| **Right Arrow** | Seek forward 5 seconds |
| **V** | Jump to start of current section (press again for previous) |
| **B** | Jump to start of next section |
| **0–9** | Jump to 0%–90% of the track |
| **Click progress bar** | Seek to position |

### Study Mode

Study Mode is designed for audiobooks and language learning. It is **enabled by default** and can be toggled with the checkbox in the bottom-right corner.

When the audio is loaded, the app analyzes it to detect silence gaps between spoken sections. A section counter (e.g. "5/70") shows which speaking section you're in.

**How it works:**

- **Auto-pause at silence** — Playback automatically pauses when a silence gap is reached, giving you time to process what was said.
- **Space (when paused at silence)** — Skips past the silence and resumes at the next speaking section.
- **Hold Space** — Prevents auto-pause; playback continues straight through silence gaps.
- **Space (while playing)** — Pauses and jumps back to the start of the current speaking section, so you can re-listen.
- **V** — Jump to the start of the current speaking section. Press again to go to the previous section. Auto-resumes playback.
- **B** — Jump to the start of the next speaking section. Auto-resumes playback.

**Visual indicators:**

- The "PLAYING"/"PAUSED" text and play button turn a darker red during silence sections.
- The section counter below the buttons shows your current position (e.g. "12/70").

When Study Mode is **off**, Space simply toggles play/pause with a 1-second rewind on pause.

### Project Structure

```
src/main.c        Application source
deps/raylib/      raylib (cloned separately)
deps/raygui/      raygui (cloned separately)
build/            Build output (gitignored)
resources/        Font files (gitignored)
bin/              Build and utility scripts
```
