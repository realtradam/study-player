# raylib-jamstack: 3D physics demo — raylib (render) + Jolt (physics).
#
#   ./zig-out/bin/game game/physics_demo.rb        (desktop)
#   (web: preloaded; runnable as /game/physics_demo.rb)
#
# A ball pit: colourful spheres drop into a box and bounce. SPACE shoots a ball
# from the camera into the pile; R resets. The camera orbits automatically.

Rl.init_window(960, 540, "raylib-jamstack: 3D physics (Jolt)")
Rl.target_fps = 60

# --- camera (auto-orbiting) ---
camera = Rl::Camera3D.new(
  Rl::Vector3.new(18, 14, 18),   # position
  Rl::Vector3.new(0, 3, 0),      # target
  Rl::Vector3.new(0, 1, 0),      # up
  45.0,                          # fovy
  Rl::CAMERA_PERSPECTIVE
)

# --- physics world ---
world = Jolt::World.new(gravity: [0, -18, 0])

GROUND_HALF = 10.0
# A static floor + four low walls to keep the balls in the pit.
world.body(shape: Jolt.box(GROUND_HALF * 2, 1, GROUND_HALF * 2),
           position: [0, -0.5, 0], motion: Jolt::STATIC, friction: 0.6)
[[GROUND_HALF, 0], [-GROUND_HALF, 0], [0, GROUND_HALF], [0, -GROUND_HALF]].each do |wx, wz|
  sx = wz == 0 ? 1.0 : GROUND_HALF * 2
  sz = wz == 0 ? GROUND_HALF * 2 : 1.0
  world.body(shape: Jolt.box(sx, 6, sz), position: [wx, 3, wz],
             motion: Jolt::STATIC, restitution: 0.3)
end

PALETTE = [Rl::RED, Rl::ORANGE, Rl::GOLD, Rl::LIME, Rl::SKYBLUE,
           Rl::BLUE, Rl::VIOLET, Rl::PINK]
MAX_BALLS = 200

# Each ball: [body, radius, color]
balls = []

def spawn_ball(world, balls, pos, radius, velocity = nil)
  body = world.body(shape: Jolt.sphere(radius), position: pos,
                    motion: Jolt::DYNAMIC, restitution: 0.55, friction: 0.4,
                    velocity: velocity)
  balls << [body, radius, PALETTE[rand(PALETTE.length)]]
  # keep the body count bounded — retire the oldest ball
  if balls.length > MAX_BALLS
    old = balls.shift
    old[0].remove
  end
end

def reset!(world, balls)
  balls.each { |b, _| b.remove }
  balls.clear
  # a loose 5x5x3 stack of spheres above the pit
  5.times do |ix|
    3.times do |iy|
      5.times do |iz|
        spawn_ball(world, balls,
                   [ix * 1.2 - 2.4, 4 + iy * 1.3, iz * 1.2 - 2.4], 0.5)
      end
    end
  end
end

reset!(world, balls)
world.optimize_broad_phase

drip = 0

Rl.while_window_open do
  # --- input ---
  Rl.update_camera(camera, Rl::CAMERA_ORBITAL)

  if Rl.key_pressed?(:space)
    # shoot a ball toward what the camera is looking at. The camera sits OUTSIDE
    # the pit walls, so spawn the projectile past the walls (inside the pit) —
    # otherwise it just bounces off the outer face of a wall.
    fwd  = Rl.vector3_normalize(Rl.vector3_subtract(camera.target, camera.position))
    dist = Rl.vector3_length(Rl.vector3_subtract(camera.target, camera.position))
    d = [dist - 8.0, 1.0].max
    speed = 35.0
    spawn_ball(world, balls,
               [camera.position.x + fwd.x * d,
                camera.position.y + fwd.y * d,
                camera.position.z + fwd.z * d], 0.6,
               [fwd.x * speed, fwd.y * speed, fwd.z * speed])
  end
  reset!(world, balls) if Rl.key_pressed?(:r)

  # gentle rain of new balls
  drip += 1
  if drip >= 20
    drip = 0
    spawn_ball(world, balls, [rand * 6 - 3, 12, rand * 6 - 3], 0.4 + rand * 0.3)
  end

  # --- step physics (fixed timestep for stability) ---
  world.step(1.0 / 60.0)

  # --- render ---
  Rl.draw(clear_color: Rl::Color.new(28, 28, 38, 255)) do
    Rl.begin_mode3d(camera)
    Rl.draw_grid(GROUND_HALF.to_i * 2, 1.0)
    balls.each do |body, radius, color|
      Rl.draw_sphere(body.position, radius, color)
    end
    Rl.end_mode3d

    Rl.draw_text(text: "balls: #{balls.length}", x: 12, y: 12, font_size: 22, color: Rl::RAYWHITE)
    Rl.draw_text(text: "SPACE: shoot   R: reset", x: 12, y: 40, font_size: 18, color: Rl::LIGHTGRAY)
    # FPS counter in the top-right corner
    Rl.draw_fps(Rl.screen_width - 95, 12)
  end
end
