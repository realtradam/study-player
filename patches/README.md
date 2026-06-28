# Vendor patches

`vendor/` is git-ignored (`.gitignore`), so fixes we carry against vendored
dependencies must live here as tracked files and be re-applied on a fresh clone.
Each `.patch` is a `git diff` against the pinned version; apply from the repo root.

## Applying (after cloning vendors per `BUILDING.md`)

```sh
git -C vendor/raylib apply "$(pwd)/patches/raylib-6.0-web-cursorhidden.patch"
```

(Rebuild after: `make -C vendor/raylib/src clean` then `zig build` / `build_web.sh`,
since raylib shares `.o` files across targets — see
`.agents/rules/raylib-platform-objs.md`.)

## raylib-6.0-web-cursorhidden.patch

**Pinned against:** raylib `6.0` (tag, detached HEAD in `vendor/raylib`).
**File touched:** `vendor/raylib/src/platforms/rcore_web.c`.

**What:** raylib 6.0 regressed `IsCursorHidden()` on the web target. 6.0 split
cursor state in `rcore_web.c` into `cursorHidden` (`HideCursor`) vs `cursorLocked`
(`DisableCursor` / pointer-lock), but `EmscriptenPointerlockCallback` was updated
to set only `cursorLocked` — it stopped setting `cursorHidden` (5.5 set
`cursorHidden` there). `IsCursorHidden()` reads `cursorHidden`, so after
`DisableCursor()` on web it never returns true.

**Symptom (without patch):** mouse-look broke in `game/physics_playground.rb`
after the 6.0 upgrade. `Rl.cursor_hidden?` stayed `false` and
`Rl.get_mouse_delta` returned `0.0` even after clicking; `Rl.get_mouse_x/y`
worked (position tracked, only pointer-lock deltas died). The game gates repeated
`disable_cursor` calls on `!cursor_hidden?`, so with the flag stuck false it
spammed `emscripten_request_pointerlock()` every frame; browsers reject that
(pointer lock must come from a single user gesture) → pointer lock never stably
engages → deltas dead.

**Fix:** the callback now also does `cursorHidden = cursorLocked`, restoring 5.5
semantics. `EmscriptenMouseMoveCallback` already branches on `cursorLocked`, so
deltas flow once lock engages — the patch just makes `IsCursorHidden()` reflect it.

**Upstream:** this is a genuine raylib 6.0 bug (incomplete `cursorHidden`/
`cursorLocked` refactor in the web platform). **Report it upstream** and re-check
on the next raylib pull — if fixed, drop this patch.

Full scar-tissue write-up: `.agents/knowledge/web-target.md` ("raylib 6.0
regression: IsCursorHidden() on web").
