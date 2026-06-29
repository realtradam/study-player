# Running the desktop app on WSL/Arch-Razer

> Tribal knowledge (P6): the non-inferable facts for running the native Linux
> `build/study-player` on this dev machine — Arch Linux in WSL2 with WSLg, on a
> Razer laptop with an NVIDIA dGPU passthrough. A fresh model cannot derive
> these from the source; they were found by crashing and then bisecting env.

## Environment

- Arch Linux (`ID=arch`) inside WSL2; graphics via **WSLg** (X11 socket at
  `/tmp/.X11-unix/X0`, Wayland socket at `/mnt/wslg/runtime-dir/wayland-0`).
- Mesa GL stack present: `d3d12_dri.so`, `zink_dri.so`, `swrast_dri.so`,
  `virtio_gpu_dri.so` under `/usr/lib/dri/`. NVIDIA passthrough libs under
  `/usr/lib/wsl/lib/` (`libcuda.so`, `libd3d12.so`, …).
- Audio: WSLg PulseAudio at `unix:/mnt/wslg/PulseServer`.
- The WSLg env vars are set by `/etc/profile.d/wslg.sh` — but **only in a login
  shell**. A non-login shell (the default for tool/agent invocations) has
  `DISPLAY` and `WAYLAND_DISPLAY` empty, so the app can't find the display at
  all unless you export them yourself.

## The segfault trap (root cause)

`/etc/profile.d/wslg.sh` exports **`LIBGL_ALWAYS_INDIRECT=1`** ("Helpful for
some GL apps"). For this app + this GPU stack it is the opposite of helpful:
raylib initializes, then `InitWindow` **segfaults (exit 139, core dumped)**
during GLX/GL context creation — log stops right after the module-load banner,
before "DISPLAY: Device initialized".

**Fix: `unset LIBGL_ALWAYS_INDIRECT`.** With it unset, direct rendering works
and the window comes up cleanly (renderer resolves to Mesa `llvmpipe`, the
software rasterizer — fine for this app).

## Required env vars to run

```sh
export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
export PULSE_SERVER=unix:/mnt/wslg/PulseServer
unset LIBGL_ALWAYS_INDIRECT    # critical — the default wslg.sh sets it and it crashes us
```

## Launching (background, detached)

The app is a raylib event loop that runs until the window is closed, so launch
it detached so it doesn't block the caller:

```sh
cd /home/tradam/projects/study-player
setsid nohup ./build/study-player > /tmp/study-player.log 2>&1 < /dev/null &
disown 2>/dev/null || true
```

## Verifying it came up

- Process stays alive (not exit 139). `kill -0 $!` succeeds after ~2–3 s.
- Log contains, in order: `DISPLAY: Device initialized successfully` →
  `PLATFORM: DESKTOP (GLFW - X11): Initialized successfully` →
  `AUDIO: Device initialized successfully` → font-load lines.
  If the log stops at the module banner and the process is dead → you hit the
  `LIBGL_ALWAYS_INDIRECT` trap (see above).
- Harmless warnings in the log: `FONT: [0x007b/0x007d] Glyph height is bigger
  than requested font size` (the `{`/`}` braces in the embedded font). Cosmetic
  only.

## GPU driver options

- **Default (unset everything except the required vars above):** resolves to
  `llvmpipe` (software). Works, slightly more CPU. **This is the recommended
  path.**
- **Force the d3d12 GPU driver:** `export MESA_LOADER_DRIVER_OVERRIDE=d3d12`.
  Also reaches `PLATFORM: Initialized successfully`. Hardware-accel path if you
  want it; not required.
- **Do NOT force Zink:** `MESA_LOADER_DRIVER_OVERRIDE=zink` fails with
  `GLX: No GLXFBConfigs returned` / `DRI3 not available` — window never opens.

## Loading media

No CLI file argument. Drag and drop an `.mp3` onto the window (desktop path in
`main.c`'s `IsFileDropped` handler). Silence detection runs on load.

## Stopping

Close the window, or `pkill -x study-player`.
