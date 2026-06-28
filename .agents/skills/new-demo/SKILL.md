---
name: new-demo
description: Use when scaffolding a new game scene or demo as a game/*.rb script that runs identically on desktop and web. Covers window init, the mandatory platform-seam loop (never a raw while/loop), input/timing, optional ECS/physics/UI setup, and running it on both targets.
---

# Scaffold a new demo scene

Game code is identical across desktop and web **except** it must go through the
platform seam. Model after `game/main.rb` and the physics demos.

## Steps

1. Create `game/<name>.rb`.
2. **Init (once, before the loop):**
   ```ruby
   Rl.init_window(800, 450, "my demo")
   Rl.target_fps = 60
   # Rml.init  # only if you use UI — MUST be after init_window
   ```
3. **Use the seam — the ONLY loop.** Never write a bare `while`/`loop` (it breaks
   the web target, which drives the body via `emscripten_set_main_loop`):
   ```ruby
   Rl.while_window_open do
     # update...
     Rl.draw(clear_color: Rl::BLACK) do
       # draw...
     end
   end
   ```
4. **Input/timing:** symbol keys `Rl.key_down?(:w)` / `Rl.key_pressed?(:space)`;
   delta time `Rl.frame_time`. Use the exception-safe block pairs (`mode_2d`,
   `mode_3d`, `shader_mode`, …) instead of raw Begin/End.
5. **ECS / physics (optional):** create `Flecs::World` / `Jolt::World` **outside** the
   loop; call `world.progress(Rl.frame_time)` / `world.step(dt)` **inside** it.
   (See skills `add-flecs-system`; features `flecs`, `jolt`.)
6. **Run desktop:** `./zig-out/bin/game game/<name>.rb`.
   **Run web:** set the entry in `web/shell.html` `Module.arguments`, rebuild
   (`build_web.sh`), serve; or `node build/web/game.js /game/<name>.rb` for headless
   logic. (`main.c` takes the script path as `argv[1]`.)
7. Don't commit screenshots — `*.png` is git-ignored for a reason.

## Cross-refs
- Knowledge: `.agents/knowledge/raylib-binding.md`, `web-target.md` · Example: `game/main.rb`
- Verify: skill `build-and-verify`
