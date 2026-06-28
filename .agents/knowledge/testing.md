# Tribal knowledge: testing / verifying changes

There is no unit-test harness; verification is by running scripts through the
built binary. `src/main.c` runs `argv[1]` (default `game/main.rb`), so:

```sh
./zig-out/bin/game /tmp/opencode/smoke.rb     # desktop
node build/web/game.js /game/smoke.rb         # web (windowless scripts; see web-target.md)
```

## Smoke tests
Write a small `.rb` that exercises the change and `puts` results, then diff the
output against expected. Filter the noisy raylib/Mesa banner with
`grep -vE '^(INFO|WARNING|MESA|libEGL)'`.

## Visual verification (offscreen render → PNG)
To check rendering without a visible window, use the hidden-window + screenshot
pattern: set `Rl::FLAG_WINDOW_HIDDEN`, draw one frame, then read pixels back
(`load_image_from_screen` / `get_image_color`, or `export_image`/`take_screenshot`
to a PNG) and assert on pixel values. This is how the rlgl/shader fixes were
verified (e.g. a vec4 tint on a white quad must read back as the tint × 255).
Clean up the PNG afterward (don't commit it; `*.png` is git-ignored).

## When verifying flecs
The binding logic is identical on desktop and web, so validate on desktop first
(fast), then confirm the same script in node against the wasm to catch
wasm-specific issues (stack, alignment).

## Type checking (Ruby / RBS)
`./tools/check-types.sh` runs `rbs validate` (sig/*.rbs consistency) + `steep
check` (Steep project loads clean). It's a cheap, build-free gate that
hard-fails on a broken signature or a Steep project-load error and is green on
correct code. Game-code type *typos* (wrong arg type/arity to a typed `Rl::` /
`Jolt::` / `Flecs::` / `Rml::` call) are `:information` under the Steepfile's
`lenient` config — they show up live in the editor (the Steep LSP) and via
`steep check --severity-level=information`, not as a `check-types.sh` failure.
See `.agents/knowledge/steep.md` for the setup + rationale.
