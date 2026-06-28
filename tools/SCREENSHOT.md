# Screenshot capture (`bin/screenshot`)

Capture a game frame to a PNG for visual debugging — shader bugs, rendering
glitches, layout, AA quality. Generic and parameterized: any game script + any
output path. Two capture targets:

- **`--target web`** (default) — headless Chromium screenshots the relay-served
  web game. **The working path under WSL** (no display needed). The web build runs
  the SAME shaders (SMAA/FXAA/CRT) as desktop.
- **`--target desktop`** — raylib's own `TakeScreenshot` framebuffer capture of
  the desktop binary. Pixel-exact and noise-free, but needs a driven display
  (see [WSLg limitation](#wslg-limitation-desktop-target) below).

## Quick start (web — works here)

```sh
# 0) one-time setup: install puppeteer (downloads ~180MB headless Chromium)
npm install

# 1) ensure the web build exists + the relay is serving it
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh        # only after C/C++/mrblib edits
node tools/agent-bridge/server.js &                  # serves http://localhost:8080
# (the game running is whatever web/shell.html → Module.arguments points at,
#  e.g. game/fx_demo.rb — the --target=web game-script arg is just a label)

# 2) capture
bin/screenshot game/fx_demo.rb /tmp/shot.png
# → ✓ captured: /tmp/shot.png  (PNG image data, 1280 x 720, 8-bit/color RGB)
```

Put outputs in `/tmp/` or `.live/` (gitignored). **Do not commit PNGs** — the repo
`.gitignore` enforces `*.png`.

## Usage

```
bin/screenshot <game-script.rb> <output.png> [options]
```

| Option | Default | Notes |
|--------|---------|-------|
| `--target web\|desktop` | `web` | capture target |
| `--frames N` | `3000` (web, ms) / `30` (desktop, frames) | settle time before capture |
| `--win WxH` | `1280x720` web / `720x720` desktop | viewport size |
| `--timeout SECS` | `30` | hard kill timeout |
| `--url URL` | `http://localhost:8080/game.html` | web: relay URL |
| `--browser chrome\|puppeteer` | auto (chrome if present, else puppeteer) | web: capture backend |
| `--delay SECS` | `0` | desktop: extra wall-clock wait before capture |
| `--keep-running` | off | desktop: don't exit the game after capture |
| `--game-bin PATH` | `zig-out/bin/game` | desktop: game binary |
| `--ffmpeg` | off | desktop: force the `ffmpeg -f x11grab` fallback |

Exit 0 + prints the absolute PNG path on success. The PNG is validated
(`file(1)` checks the PNG signature + dimensions); a blank/invalid capture is a
non-zero exit.

### Examples

```sh
# web, give shaders longer to settle (heavy SMAA/FXAA scene)
bin/screenshot game/fx_demo.rb /tmp/fx.png --frames 5000

# web, larger viewport
bin/screenshot game/fx_demo.rb /tmp/fx.png --win 1920x1080

# use a system google-chrome/chromium if installed (no puppeteer needed)
bin/screenshot game/fx_demo.rb /tmp/fx.png --browser chrome

# desktop, raylib framebuffer capture (needs a real display)
bin/screenshot game/fx_demo.rb /tmp/fx.png --target desktop --frames 45

# a different relay port
bin/screenshot game/main.rb /tmp/main.png --url http://localhost:8090/game.html
```

## How each target works

### `--target web` (default)

`bin/screenshot` opens `http://localhost:8080/game.html` in a **headless
Chromium**, waits for the emscripten boot → mruby → game script → WebGL first
frame to composite (default 3000ms; raise `--frames` for heavier scenes), then
screenshots the viewport to a PNG.

Two backends, tried in order unless `--browser` pins one:

1. **system chrome** — `google-chrome`/`chromium --headless=new --screenshot`,
   with `--virtual-time-budget` + `--run-all-compositor-stages-before-draw` so
   the WebGL canvas renders before the shot. Use if a system Chrome is installed
   (no download needed).
2. **puppeteer** (the default here, no system Chrome) — `tools/web_screenshot.js`
   drives a project-local headless Chromium. Software GL via SwiftShader
   (`--use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader`) so it
   renders without a GPU. Page-console errors, real resource 404s, and
   request failures are echoed to stderr (the relay's `/jamstack/*` poll noise
   and `favicon.ico` 404 are filtered — they're expected).

**Prerequisites:** the relay must be serving the page (`curl -s localhost:8080/game.html
| head -1` should return HTML) and puppeteer installed once (`npm install`).

### `--target desktop`

Runs `zig-out/bin/game <game-script>` with the `JAMSTACK_SCREENSHOT` env hook
(below). After `JAMSTACK_SCREENSHOT_FRAMES` frames the game calls
`Rl.take_screenshot(path)` and exits cleanly. This is **pixel-exact** (reads the
framebuffer, no desktop chrome) — best for shader debugging. Fallback:
`ffmpeg -f x11grab` grabs the X root window (includes desktop chrome) if the
raylib path produces no PNG, or with `--ffmpeg`.

**The env hook** lives in `mrbgems/raylib/mrblib/raylib.rb` → `Rl.while_window_open`
(the single platform seam), desktop branch only. It makes **any** game script
screenshot-capable with zero per-script changes:

| Env var | Default | Meaning |
|---------|---------|---------|
| `JAMSTACK_SCREENSHOT=<path>` | unset | enables screenshot mode; PNG written to `<path>` |
| `JAMSTACK_SCREENSHOT_FRAMES=<n>` | `30` | frames to render before capture (let shaders/physics settle) |
| `JAMSTACK_SCREENSHOT_DELAY=<secs>` | `0` | extra wall-clock wait before capture (async/asset settle) |
| `JAMSTACK_SCREENSHOT_ONCE=<0\|1>` | `1` | `1` exit after capture; `0` keep running (--keep-running) |

The capture fires right after the game block returns (the frame is fully drawn
and swapped), then `break`s the loop + `close_window` for a clean exit.

You can also drive it directly (no `bin/screenshot`):
```sh
JAMSTACK_SCREENSHOT=/tmp/shot.png JAMSTACK_SCREENSHOT_FRAMES=40 \
  DISPLAY=:0 ./zig-out/bin/game game/fx_demo.rb
```

For **manual** capture at a specific game state (not "frame N"), see
`tools/screenshot_mode.rb` — `Jamstack::Screenshot.capture(path)` (gated by
`JAMSTACK_SCREENSHOT_MANUAL=1`, so committed calls stay inert).

## WSLg limitation (`--target desktop`)

The desktop target needs a **driven display** — a real, interactive window. In
this WSL2/WSLg dev environment, running the desktop binary from a non-interactive
shell **stalls** (verified):

- raylib is built **Wayland-only** (`GLFW_LINUX_ENABLE_WAYLAND=TRUE
  GLFW_LINUX_ENABLE_X11=FALSE`; WSLg's X11/GLX path segfaults inside Mesa — see
  `.agents/knowledge/environment.md`). With `XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir
  WAYLAND_DISPLAY=wayland-0`, `InitWindow` connects to Wayland then **blocks in
  `do_sys_poll`** (0% CPU, state `S`) — the compositor doesn't drive a
  non-interactive window, so the framebuffer never renders and no PNG is produced.
- The X11 path (`DISPLAY=:0`) initializes but **segfaults at GL/FBO setup**
  (the known Mesa `dri2GalliumConfigQueryb` crash); software GL (`LIBGL_ALWAYS_SOFTWARE`)
  doesn't help because the X11 backend isn't compiled in.

So `--target desktop` here will hit its 30s timeout and fall back to `ffmpeg`
(which also can't grab an unrendered window). **Use `--target web` in this
environment.** The desktop path is correct and works on a machine with a real
interactive display (or an interactive WSLg session where the window is
foregrounded); it's left in for that case and for CI on real GPUs.

## Files

- `bin/screenshot` — the wrapper (both targets).
- `tools/web_screenshot.js` — puppeteer headless-Chromium capture (web backend).
- `mrbgems/raylib/mrblib/raylib.rb` — the `JAMSTACK_SCREENSHOT` env hook in
  `Rl.while_window_open` (desktop backend).
- `tools/screenshot_mode.rb` — optional in-script manual capture helper.
- `package.json` — declares `puppeteer` as a devDependency (one-time `npm install`).
