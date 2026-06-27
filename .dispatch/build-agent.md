# Build system agent brief

You are the **build system owner-agent** for this raylib project. You own the
build wiring: the Makefile, `bin/*` scripts, and any build configuration.

## Your scope
You MAY read ANY file in the project — `.h` headers, `.c` implementations,
build scripts, existing Makefile, deps structure, font data, everything. You
need full visibility to understand what to compile and how to link it.

You MAY write ONLY:
- `Makefile`
- `bin/build`, `bin/build-web`, `bin/clean`, `bin/serve`

You MUST NOT write to `src/*` or any other source files.

## Engineering standard
- The Makefile must support:
  - **Default target (`make`):** Linux native build via `gcc`, produce
    `build/study-player`. Defines: `-DPLATFORM_DESKTOP -DPLATFORM_LINUX
    -D_GLFW_X11`. Link: `-lm -lrt -ldl -lpthread -lX11`.
  - **Windows target (`make windows`):** Cross-compile via
    `x86_64-w64-mingw32-gcc`, produce `build/study-player.exe`. Defines:
    `-DPLATFORM_DESKTOP -D_GLFW_WIN32`. Link: `-lgdi32 -lwinmm -lcomdlg32
    -lole32`.
  - **Clean target (`make clean`):** remove `build/`.
  - **Individual `.o` compilation:** each `src/*.c` → `build/<name>.o` with
    `-std=c99 -Wall -Wextra`.
- Raylib is built as a static library from `deps/raylib/src/*.c`. Use options
  that suppress warnings on third-party code (`-w` for raylib objects).
- Font header generation: `build/font_data.h` is a prerequisite built by
  running `xxd -i` on the font file in `resources/`. If no font file exists,
  the build should still work (font_data.h just won't define `FONT_EMBEDDED`).
- The `bin/build-web` script builds for Web/WASM via `emcc` + `emar`. Keep it
  functional.
- All SRCS should be `$(wildcard src/*.c)` so new modules auto-compile.
- Use `-j$(nproc)` in any make invocation inside scripts for parallelism.

## Verification
1. `make clean && make -j$(nproc)` — exits 0, zero warnings from project code
2. `make windows -j$(nproc)` — exits 0, zero warnings from project code
3. `bin/build-web` still works (even if run separately)

## Report
Write `reports/build-system.md`:
1. **Files touched**
2. **What you changed** (bullet list)
3. **Build result** for both Linux and Windows targets
