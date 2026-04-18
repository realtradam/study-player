# Study Player

A keyboard-driven MP3 player built with [raylib](https://github.com/raysan5/raylib), cross-compiled for Windows from Linux using MinGW.

### Dependencies

Clone the following repositories into the `deps/` directory:

```bash
mkdir -p deps
git clone https://github.com/raysan5/raylib.git deps/raylib
git clone https://github.com/raysan5/raygui.git deps/raygui
```

You also need the MinGW cross-compiler installed:

```bash
# Debian/Ubuntu
sudo apt install mingw-w64
```

### Building

```bash
make
```

The output binary is `build/study-player.exe`.

### Usage

Run the `.exe` on Windows (or under Wine). The controls are:

| Key | Action |
|---|---|
| **Drag & drop** | Drop an `.mp3` file onto the window to load and play it |
| **Space** | Pause (rewinds 1 second) / Resume |
| **Left Arrow** | Seek backward 5 seconds |
| **Right Arrow** | Seek forward 5 seconds |

### Project Structure

```
src/main.c        Application source
deps/raylib/      raylib (cloned separately)
deps/raygui/      raygui (cloned separately)
build/            Build output (gitignored)
resources/        Runtime resources (gitignored)
```
