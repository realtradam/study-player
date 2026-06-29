# Tribal knowledge: environment (WSL / WSLg)

This repo is developed under **WSL** (Linux on Windows). Two hard-won facts:

## PATH: Windows shadows Linux
A Windows Ruby/rake on `/mnt/c/...` appears first in PATH and shadows the Linux
toolchain, producing baffling failures. Strip it before every build / ruby /
rake / generator invocation (see rules/wsl-toolchain.md). The build scripts
(`rebuild.sh`, `build_web.sh`) already do this and also prepend the user gem bin
(`$(ruby -e 'puts Gem.user_dir')/bin`) so the Linux `rake` gem resolves.

## Graphics backend: raylib's SDL2 backend (not GLFW)
The desktop build uses raylib's **SDL2** backend (`build.zig` builds raylib with
`PLATFORM=PLATFORM_DESKTOP_SDL`; the binary links `SDL2`). This replaces the
earlier GLFW backend for two reasons, both WSLg/Wayland-related:

- WSLg's **X11/GLX** path segfaults inside Mesa (`dri2GalliumConfigQueryb`). GLFW
  was therefore forced to its **Wayland** backend (`GLFW_LINUX_ENABLE_WAYLAND=TRUE
  GLFW_LINUX_ENABLE_X11=FALSE`), which links the wayland-* libs.
- GLFW 3.4 (vendored in raylib 6.0) has **broken drag-and-drop on Wayland**: its
  `wl_data_offer_listener` leaves the `source_actions`/`action` handlers NULL, so
  libwayland `wl_abort()`s when a compositor sends them during a drag → the app
  crashes the moment a file is dragged over the window (glfw/glfw#2835). A
  backport patch was tried and **did not** fix it on the real target (labwc), so
  the whole GLFW path was abandoned.

SDL's own window/EGL/drag-drop code is mature on **both** real Wayland (labwc)
and WSLg — one backend covers both targets, no vendor patches, no X11/Wayland
special-casing. It requires **SDL2 dev installed system-wide** (`pacman -S sdl2`
or `sdl2-compat`); the binary won't link otherwise. The web build is unaffected
(still Emscripten + GLFW; `build_web.sh` unchanged). The RmlUi binding is
backend-agnostic (renders via `rlgl`, reads input via raylib's `IsKeyDown` — no
`glfw*` calls), so the swap is transparent to it.

Expect harmless Mesa/llvmpipe messages on stderr in WSLg (software GL); not errors.

## Toolchain versions (pinned)
raylib 5.5, mruby 3.3.0, RmlUi 6.1, flecs v4.1.1, Zig 0.16.0, emcc 6.0.0 (emsdk).
