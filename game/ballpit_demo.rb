# raylib-jamstack: playable 3D character demo — raylib (render) + Jolt (physics).
#
#   ./zig-out/bin/game game/ballpit_demo.rb        (desktop)
#   (web: preloaded; runnable as /game/ballpit_demo.rb)
#
# A third-person character walks on a big flat plane with a square PIT cut into
# the middle. Inside the pit are dynamic balls the player can shove around (but
# the balls can't push the player back — the player is a kinematic
# CharacterVirtual). A short stair-ramp on one side of the pit lets the player
# climb back out. A big KINEMATIC sphere orbits the pit on the plane and bowls
# the player out of its way (the player can't push it back).
#
# Controls:  WASD move (camera-relative)   SPACE jump   Mouse look
#            hold SHIFT to sprint           ESC quit
#
# Layout (top-down, +x right, +z toward camera-back; y is up):
#   - ground top surface at y = 0
#   - square pit opening of side PIT_SIZE centred at origin, floor at y = -PIT_DEPTH
#   - stairs descend into the pit from the +x edge

# ----------------------------------------------------------------- constants --
GROUND_EXTENT = 24.0        # half-size of the whole plane
PIT_SIZE      = 9.0         # full side length of the square pit opening
PIT_HALF      = PIT_SIZE / 2.0
PIT_DEPTH     = 3.0         # how far below the top surface the pit floor sits
GROUND_THICK  = 1.0         # thickness of the top ground slabs
WALL_THICK    = 0.6

PLAYER_RADIUS = 0.4
PLAYER_HALFH  = 0.5         # capsule cylinder half-height
PLAYER_FOOT_TO_CENTRE = PLAYER_HALFH + PLAYER_RADIUS  # capsule centre above feet

MOVE_SPEED  = 6.0
SPRINT_MULT = 1.7
JUMP_SPEED  = 7.5
GRAVITY     = 22.0

# ----------------------------------------------------------------- window ------
Rl.init_window(1024, 600, "raylib-jamstack: ball pit character (Jolt)")
Rl.target_fps = 60
Rl.disable_cursor   # lock + hide the mouse for FPS-style look

# ----------------------------------------------------------------- physics -----
world = Jolt::World.new(gravity: [0, -GRAVITY, 0])

# Boxes we want to draw later: each entry is [centre(Array), size(Array), color].
boxes = []

def static_box(world, boxes, cx, cy, cz, sx, sy, sz, color, friction: 0.8)
  world.body(shape: Jolt.box(sx, sy, sz), position: [cx, cy, cz],
             motion: Jolt::STATIC, friction: friction)
  boxes << [[cx, cy, cz], [sx, sy, sz], color]
end

GROUND_COL = Rl::Color.new(70, 80, 70, 255)
PIT_COL    = Rl::Color.new(55, 52, 64, 255)
WALL_COL   = Rl::Color.new(90, 86, 70, 255)
STAIR_COL  = Rl::Color.new(120, 100, 70, 255)

# --- top ground built as a FRAME of 4 slabs around the square pit opening ---
# Each slab spans the full width in one axis and fills the margin on the other.
# Top surface sits at y = 0, so slab centre y = -GROUND_THICK/2.
gy   = -GROUND_THICK / 2.0
side = GROUND_EXTENT - PIT_HALF          # depth of each frame slab
off  = PIT_HALF + side / 2.0             # centre offset of each frame slab
full = GROUND_EXTENT * 2.0
# +z and -z slabs (full width in x, "side" deep in z)
static_box(world, boxes, 0.0,  gy,  off, full, GROUND_THICK, side, GROUND_COL)
static_box(world, boxes, 0.0,  gy, -off, full, GROUND_THICK, side, GROUND_COL)
# +x and -x slabs (only the pit width in z so they don't overlap the others)
static_box(world, boxes,  off, gy, 0.0, side, GROUND_THICK, PIT_SIZE, GROUND_COL)
static_box(world, boxes, -off, gy, 0.0, side, GROUND_THICK, PIT_SIZE, GROUND_COL)

# --- pit floor (lowered) ---
pit_floor_y = -PIT_DEPTH - GROUND_THICK / 2.0
static_box(world, boxes, 0.0, pit_floor_y, 0.0, PIT_SIZE, GROUND_THICK, PIT_SIZE, PIT_COL, friction: 0.9)

# --- pit walls (vertical slabs lining the inside of the opening) ---
# The +x wall is split into two short segments leaving a gap where the staircase
# joins the pit, so the player can walk straight off the bottom step.
wall_h    = PIT_DEPTH
wall_cy   = -PIT_DEPTH / 2.0
STAIR_W   = 3.4                       # width (z-span) of the staircase strip
gap_half  = STAIR_W / 2.0
seg_len   = (PIT_SIZE - STAIR_W) / 2.0
seg_off   = gap_half + seg_len / 2.0
# -z and +z walls (run along x), full width
static_box(world, boxes, 0.0, wall_cy,  PIT_HALF, PIT_SIZE, wall_h, WALL_THICK, WALL_COL)
static_box(world, boxes, 0.0, wall_cy, -PIT_HALF, PIT_SIZE, wall_h, WALL_THICK, WALL_COL)
# -x wall (run along z), full inner width
static_box(world, boxes, -PIT_HALF, wall_cy, 0.0, WALL_THICK, wall_h, PIT_SIZE - 2 * WALL_THICK, WALL_COL)
# +x wall split around the staircase gap
static_box(world, boxes, PIT_HALF, wall_cy,  seg_off, WALL_THICK, wall_h, seg_len, WALL_COL)
static_box(world, boxes, PIT_HALF, wall_cy, -seg_off, WALL_THICK, wall_h, seg_len, WALL_COL)

# --- staircase on the +x side: a compact flight from pit floor up to the surface ---
# Steps are axis-aligned boxes with rise <= 0.4 m, which the CharacterVirtual
# climbs via stair-stepping (walkStairsStepUp = 0.4 m). Each step is a box from
# the pit floor up to its top surface; they march in +x and only span STAIR_W in
# z, so the rest of the pit floor stays open for the balls.
STEP_RISE  = 0.375
STEP_RUN   = 0.55
n_steps    = (PIT_DEPTH / STEP_RISE).ceil    # enough steps to reach the surface
floor_top  = pit_floor_y + GROUND_THICK / 2.0
n_steps.times do |i|
  top_y   = -PIT_DEPTH + (i + 1) * STEP_RISE          # this step's top surface
  top_y   = 0.0 if top_y > 0.0
  height  = top_y - floor_top                          # from pit floor up to step top
  cy      = floor_top + height / 2.0
  # innermost (lowest) step nearest the pit centre; flight climbs toward +x edge
  cx      = (PIT_HALF - STEP_RUN / 2.0) - (n_steps - 1 - i) * STEP_RUN
  static_box(world, boxes, cx, cy, 0.0, STEP_RUN, height, STAIR_W, STAIR_COL, friction: 0.95)
end

# ----------------------------------------------------------------- balls --------
PALETTE = [Rl::RED, Rl::ORANGE, Rl::GOLD, Rl::LIME, Rl::SKYBLUE,
           Rl::BLUE, Rl::VIOLET, Rl::PINK]
balls = []   # each: [body, radius, color]
def spawn_ball(world, balls, pos, radius, color)
  b = world.body(shape: Jolt.sphere(radius), position: pos,
                 motion: Jolt::DYNAMIC, restitution: 0.25, friction: 0.5)
  balls << [b, radius, color]
end

# A loose grid of balls resting on the -x half of the pit floor, clear of the
# staircase (which occupies the +x half).
ci = 0
ball_top = pit_floor_y + GROUND_THICK / 2.0
[-3.4, -2.4, -1.4, -0.4].each do |bx|
  [-3.0, -1.5, 0.0, 1.5, 3.0].each do |bz|
    r = 0.45
    spawn_ball(world, balls, [bx, ball_top + r + 0.05, bz], r, PALETTE[ci % PALETTE.length])
    ci += 1
  end
end

# ----------------------------------------------------------------- orbiter ------
# A big KINEMATIC sphere circling on the flat plane around the pit. It pushes the
# player (kinematic vs character penetration recovery) but the player can't push
# it. We drive it by setting linear_velocity to the circle tangent each frame.
ORBIT_RADIUS = GROUND_EXTENT - 6.0
ORBIT_SPEED  = 5.0          # m/s along the circle
ORBIT_R      = 1.6          # sphere radius
orbit_y      = ORBIT_R - 0.1   # rolls along on the top surface (y=0)
orbit_angle  = 0.0
orbiter = world.body(shape: Jolt.sphere(ORBIT_R),
                     position: [ORBIT_RADIUS, orbit_y, 0.0],
                     motion: Jolt::KINEMATIC, friction: 0.3)

# ----------------------------------------------------------------- player -------
player = world.character(shape: Jolt.capsule(PLAYER_HALFH, PLAYER_RADIUS),
                         position: [0.0, PLAYER_FOOT_TO_CENTRE + 0.2, GROUND_EXTENT - 5.0],
                         max_slope_deg: 50.0, mass: 80.0)
player.max_strength = 6000.0   # strong enough to shove the heavy default-density balls

world.optimize_broad_phase

# ----------------------------------------------------------------- camera -------
cam = Rl::Camera3D.new(
  Rl::Vector3.new(0, 6, 12),
  Rl::Vector3.new(0, 1, 0),
  Rl::Vector3.new(0, 1, 0),
  55.0,
  Rl::CAMERA_PERSPECTIVE
)
cam_yaw   = Math::PI            # look toward -z initially (toward the pit)
cam_pitch = -0.35
CAM_DIST  = 7.5
MOUSE_SENS = 0.0032
PITCH_MIN = -1.3
PITCH_MAX =  0.4

# ----------------------------------------------------------------- helpers ------
def clampf(v, lo, hi); v < lo ? lo : (v > hi ? hi : v); end

# ----------------------------------------------------------------- main loop ----
Rl.while_window_open do
  dt = Rl.frame_time
  dt = 1.0 / 60.0 if dt <= 0.0 || dt > 0.1   # clamp for stability / first frame

  # --- mouse look ---
  # Browsers only grant pointer lock from a user gesture, so (re)lock on click;
  # on desktop disable_cursor at startup already locked it. Only rotate the
  # camera while actually locked, so the view doesn't jump before the first click
  # or after ESC releases the lock.
  Rl.disable_cursor if Rl.mouse_button_pressed?(Rl::MOUSE_BUTTON_LEFT) && !Rl.cursor_hidden?
  if Rl.cursor_hidden?
    md = Rl.get_mouse_delta
    cam_yaw   -= md.x * MOUSE_SENS   # mouse-right looks right
    cam_pitch  = clampf(cam_pitch - md.y * MOUSE_SENS, PITCH_MIN, PITCH_MAX)
  end

  # camera-relative ground basis from yaw. right = cross(forward, up), matching
  # raylib's own camera-right convention so D strafes screen-right.
  fwd_x   =  Math.sin(cam_yaw)
  fwd_z   =  Math.cos(cam_yaw)
  right_x = -Math.cos(cam_yaw)
  right_z =  Math.sin(cam_yaw)

  # --- WASD movement intent (camera-relative, on the ground plane) ---
  # NOTE: a trailing `if` only guards the LAST statement on the line, so each key
  # must gate BOTH axis components explicitly (else the X component never applies).
  mx = 0.0
  mz = 0.0
  if Rl.key_down?(:w) then mx += fwd_x;   mz += fwd_z;   end
  if Rl.key_down?(:s) then mx -= fwd_x;   mz -= fwd_z;   end
  if Rl.key_down?(:a) then mx -= right_x; mz -= right_z; end
  if Rl.key_down?(:d) then mx += right_x; mz += right_z; end
  len = Math.sqrt(mx * mx + mz * mz)
  if len > 0.0001
    mx /= len
    mz /= len
  end
  speed = MOVE_SPEED * (Rl.key_down?(:left_shift) ? SPRINT_MULT : 1.0)

  # --- vertical velocity: jump if grounded, else integrate gravity ---
  v  = player.velocity
  vy = if player.on_ground?
         Rl.key_pressed?(:space) ? JUMP_SPEED : 0.0
       else
         v.y - GRAVITY * dt
       end
  player.velocity = [mx * speed, vy, mz * speed]
  player.update(dt)

  # --- drive the orbiting kinematic sphere along its circle (tangent velocity) ---
  orbit_angle += (ORBIT_SPEED / ORBIT_RADIUS) * dt
  tang_x = -Math.sin(orbit_angle)
  tang_z =  Math.cos(orbit_angle)
  orbiter.linear_velocity = [tang_x * ORBIT_SPEED, 0.0, tang_z * ORBIT_SPEED]

  # --- advance physics ---
  world.step(dt)

  # keep the orbiter pinned to its circle + height (kinematic drift correction)
  oa = orbit_angle
  orbiter.set_transform(position: [Math.cos(oa) * ORBIT_RADIUS, orbit_y,
                                   Math.sin(oa) * ORBIT_RADIUS])

  # --- third-person follow camera ---
  p = player.position
  cp = Math.cos(cam_pitch)
  eye_x = p.x - fwd_x * CAM_DIST * cp
  eye_z = p.z - fwd_z * CAM_DIST * cp
  eye_y = p.y + 2.2 - Math.sin(cam_pitch) * CAM_DIST
  cam.position = Rl::Vector3.new(eye_x, eye_y, eye_z)
  cam.target   = Rl::Vector3.new(p.x, p.y + 1.0, p.z)

  # --- render ---
  Rl.draw(clear_color: Rl::Color.new(135, 160, 190, 255)) do
    Rl.begin_mode3d(cam)

    # static level geometry (frame, pit, walls, stairs)
    boxes.each do |centre, size, color|
      Rl.draw_cube_v(Rl::Vector3.new(centre[0], centre[1], centre[2]),
                     Rl::Vector3.new(size[0], size[1], size[2]), color)
      Rl.draw_cube_wires_v(Rl::Vector3.new(centre[0], centre[1], centre[2]),
                           Rl::Vector3.new(size[0], size[1], size[2]),
                           Rl::Color.new(30, 30, 30, 120))
    end

    # balls
    balls.each do |body, radius, color|
      Rl.draw_sphere(body.position, radius, color)
    end

    # orbiting sphere
    Rl.draw_sphere(orbiter.position, ORBIT_R, Rl::Color.new(220, 60, 60, 255))
    Rl.draw_sphere_wires(orbiter.position, ORBIT_R, 10, 10, Rl::Color.new(60, 0, 0, 180))

    # player capsule (feet at position - PLAYER_FOOT_TO_CENTRE..., caps offset by radius)
    pc = player.position
    bottom = Rl::Vector3.new(pc.x, pc.y - PLAYER_HALFH, pc.z)
    top    = Rl::Vector3.new(pc.x, pc.y + PLAYER_HALFH, pc.z)
    pcol = player.on_ground? ? Rl::Color.new(60, 200, 240, 255) : Rl::Color.new(240, 200, 60, 255)
    Rl.draw_capsule(bottom, top, PLAYER_RADIUS, 12, 8, pcol)
    Rl.draw_capsule_wires(bottom, top, PLAYER_RADIUS, 12, 8, Rl::Color.new(20, 40, 50, 200))

    Rl.end_mode3d

    # --- HUD ---
    Rl.draw_text(text: "WASD move   SPACE jump   SHIFT sprint   Mouse look",
                 x: 12, y: 12, font_size: 20, color: Rl::RAYWHITE)
    Rl.draw_text(text: "Push the balls in the pit. Dodge the rolling sphere. Use the stairs to climb out.",
                 x: 12, y: 38, font_size: 16, color: Rl::Color.new(230, 230, 230, 255))
    gs = player.ground_state.to_s
    Rl.draw_text(text: "ground: #{gs}", x: 12, y: 62, font_size: 16, color: Rl::LIGHTGRAY)
    Rl.draw_fps(Rl.screen_width - 95, 12)

    # prompt to engage pointer lock (mainly for the browser, which needs a click)
    unless Rl.cursor_hidden?
      Rl.draw_text(text: "Click to look around", x: Rl.screen_width / 2 - 120,
                   y: Rl.screen_height / 2, font_size: 26, color: Rl::RAYWHITE)
    end
  end
end
