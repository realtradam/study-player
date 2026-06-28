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

## Toolchain versions (pinned)
raylib 5.5, mruby 3.3.0, RmlUi 6.1, flecs v4.1.1, Zig 0.16.0, emcc 6.0.0 (emsdk).
