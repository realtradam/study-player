# Study Player

A keyboard-driven MP3 player built with [raylib](https://github.com/raysan5/raylib), cross-compiled for Windows from Linux using MinGW.

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
| **Space** | Toggle play/pause (pause rewinds 1s) |
| **Up Arrow** | Play |
| **Down Arrow** | Pause (rewinds 1s) |
| **Left Arrow** | Seek backward 5 seconds |
| **Right Arrow** | Seek forward 5 seconds |
| **0–9** | Jump to 0%–90% of the track |
| **Click progress bar** | Seek to position |

### Project Structure

```
src/main.c        Application source
deps/raylib/      raylib (cloned separately)
deps/raygui/      raygui (cloned separately)
build/            Build output (gitignored)
resources/        Font files (gitignored)
bin/              Build and utility scripts
```
