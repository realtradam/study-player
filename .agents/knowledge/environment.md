# Tribal knowledge: environment (WSL / WSLg)

This repo is developed under **WSL** (Linux on Windows). Two hard-won facts:

## PATH: Windows shadows Linux
A Windows Ruby/rake on `/mnt/c/...` appears first in PATH and shadows the Linux
toolchain, producing baffling failures. Strip it before every build / ruby /
rake / generator invocation (see rules/wsl-toolchain.md). The build scripts
(`rebuild.sh`, `build_web.sh`) already do this and also prepend the user gem bin
(`$(ruby -e 'puts Gem.user_dir')/bin`) so the Linux `rake` gem resolves.

## Graphics: use Wayland, not X11 (WSLg)
WSLg's X11/GLX path **segfaults inside Mesa** (`dri2GalliumConfigQueryb`). raylib
is therefore built with the **Wayland** GLFW backend:
`make ... GLFW_LINUX_ENABLE_WAYLAND=TRUE GLFW_LINUX_ENABLE_X11=FALSE`, and
`build.zig` links the wayland-* libs (`wayland-client/cursor/egl`, `xkbcommon`)
plus `EGL`. For a normal X11 desktop, swap those back to `X11` in both places.

Expect harmless Mesa/EGL/zink warnings on stderr in this environment
(`libEGL warning: ... zink ...`, `Wayland: The platform does not provide the
window position`); they are not errors.

## Wayland drag-and-drop crashes on GLFW 3.4 (patched)
raylib 6.0 vendors **GLFW 3.4** (release). Its Wayland `wl_data_offer_listener`
(`vendor/raylib/src/external/glfw/src/wl_window.c`) only sets the `offer`
(opcode 0) handler; `source_actions` (opcode 1) and `action` (opcode 2) are
NULL (`wl_data_offer` is v3; those events were added in v3). Modern compositors
(labwc, GNOME, KDE) emit source_actions/action *during a drag*, and
libwayland-client then `wl_abort("listener function for opcode N of
wl_data_offer is NULL")` — **the app crashes the moment a file is dragged over
the window**, before any drop registers (glfw/glfw#2835, #2562). This is why
drag-and-drop was "unreliable" in the rewrite but reliable in the original
`../source` app, which uses the X11/Xdnd backend (`-D_GLFW_X11`) — a separate
code path with none of these bugs.

Fix: `patches/glfw-wayland-dnd-crash.patch` backports the upstream GLFW-master
fix (no-op source_actions/action handlers + two NULL-deref guards in the
data-device path). `build.zig` applies it **idempotently** before `make`
(marker = `dataOfferHandleAction` in the file; when newly applied it deletes the
stale `libraylib.a` so `make` actually rebuilds). The vendored file is
gitignored, so the patch file + the build.zig step ARE the committed fix — a
fresh checkout reproduces it. **Drop the patch once raylib vendors a GLFW
release containing the upstream fix.**

Do NOT "fix" this by re-enabling X11 (`GLFW_LINUX_ENABLE_X11=TRUE`): on a real
Wayland session GLFW 3.4 still picks Wayland (so it wouldn't help), and forcing
X11 reintroduces the WSLg GLX segfault above.

## Toolchain versions (pinned)
raylib 5.5, mruby 3.3.0, RmlUi 6.1, flecs v4.1.1, Zig 0.16.0, emcc 6.0.0 (emsdk).
