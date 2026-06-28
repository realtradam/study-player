# raylib-jamstack: Jolt PHYSICS PLAYGROUND — a guided tour of every feature added
# since the ball-pit demo, in one playable scene.  raylib (render) + Jolt (physics).
#
#   ./zig-out/bin/game game/physics_playground.rb     (desktop)
#   (web: preloaded; runnable as /game/physics_playground.rb)
#
# Walk a third-person character around a ring of "stations", each demonstrating
# one feature:
#   1. MOVING PLATFORM  — step on the glider; you RIDE it (character ground velocity)
#   2. HINGE door       — push the swinging door open                 (hinge joint)
#   3. PENDULUM + SENSOR — a ball on a ball-joint swings through a glowing
#                          trigger volume that blinks + counts         (ball joint,
#                                                                       sensor enter/leave)
#   4. ROPE             — a hanging chain of links                    (distance joints)
#   5. SLIDER piston    — a block sliding on a rail between stops      (slider joint)
#   6. TETHERBALL       — a ball swinging inside a cone limit          (cone joint)
#   7. WELD             — two boxes fused rigid; topple them as one    (weld/fixed)
#   8. CCD WALL         — press F to fire a fast bullet at a paper-thin
#                          wall; CCD stops it tunnelling through       (ccd + impulse)
#   9. RAYCAST          — a laser from your crosshair paints the hit point and its
#                          surface NORMAL; shows the body under the crosshair
#                                                              (raycast normal, overlap_point)
#  10. RAGDOLL          — press R to drop a floppy humanoid (max 25; oldest is
#                          recycled past the cap)                       (ragdoll)
#  11. TANDEM WALLS     — two red walls 10 player-widths apart slide left/right in
#                          tandem, bulldozing ragdolls/objects caught between them
#  +   BALL PIT         — a corral of 25 dynamic balls to wade through
#
# Controls:  WASD move   SPACE jump   Mouse look   SHIFT sprint
#            R drop ragdoll   F fire CCD bullet    ESC quit

# ------------------------------------------------------------------ constants --
GRAVITY     = 22.0
MOVE_SPEED  = 6.0
SPRINT_MULT = 1.7
JUMP_SPEED  = 8.0
PLAYER_RADIUS = 0.4
PLAYER_HALFH  = 0.5
PLAYER_FOOT_TO_CENTRE = PLAYER_HALFH + PLAYER_RADIUS
PLAYER_WIDTH  = PLAYER_RADIUS * 2.0   # 0.8 m — used to size the moving walls
MAX_RAGDOLLS  = 25

Rl.init_window(720, 720, "raylib-jamstack: Jolt physics playground")
Rl.target_fps = 60
Rl.disable_cursor

# ---- RmlUi HUD (translucent 3D-angled panels, drawn over the scene) ----
Rml.init
Rml.load_font("game/ui/LatoLatin-Regular.ttf")
Rml.load_font("game/ui/LatoLatin-Bold.ttf")
Rml.load_font("game/ui/MononokiNerdFontMono-Regular.ttf")
ui = Rml::Context.new("main")
hud = ui.load_document("game/ui/hud.rml")
hud.show
hud_left     = hud.element("hud-left")
hud_right    = hud.element("hud-right")
hud_controls = hud.element("hud-controls")
hud_ride     = hud.element("hud-ride")
hud_sensor   = hud.element("hud-sensor")
hud_ray      = hud.element("hud-ray")
hud_counts   = hud.element("hud-counts")
hud_fps      = hud.element("hud-fps")
hud_controls.inner_rml = "WASD move   SPACE jump   SHIFT sprint<br/>R ragdoll   F fire CCD bullet"

hud_angle_x = 0.0
hud_angle_y = 25.0
hud_r = 17; hud_g = 17; hud_b = 27; hud_a = 0.8
hud_font_size = 14

Jamstack::Bridge.set_binding(binding)

world = Jolt::World.new(gravity: [0, -GRAVITY, 0])

# unit cube model, scaled per-draw so we can render ROTATED dynamic boxes
# (draw_cube_v ignores rotation; draw_model_ex takes an axis+angle).
CUBE = Rl.load_model_from_mesh(Rl.gen_mesh_cube(1.0, 1.0, 1.0))

# -------------------------------------------------------------------- helpers --
def clampf(v, lo, hi); v < lo ? lo : (v > hi ? hi : v); end

# quaternion -> (axis Vector3, angle degrees) for draw_model_ex
def quat_axis_angle(q)
  w = clampf(q.w, -1.0, 1.0)
  s = Math.sqrt(1.0 - w * w)
  return [Rl::Vector3.new(0, 1, 0), 0.0] if s < 1.0e-4
  [Rl::Vector3.new(q.x / s, q.y / s, q.z / s), 2.0 * Math.acos(w) * 180.0 / Math::PI]
end

# draw a (possibly rotated) box body
def draw_box_body(body, size, color)
  ax, ang = quat_axis_angle(body.rotation)
  Rl.draw_model_ex(CUBE, body.position, ax, ang, Rl::Vector3.new(*size), color)
end

# draw a capsule body (local axis = Y) using its orientation
def draw_capsule_body(body, half_height, radius, color)
  c = body.position
  axis = Rl.vector3_rotate_by_quaternion(Rl::Vector3.new(0, half_height, 0), body.rotation)
  a = Rl::Vector3.new(c.x - axis.x, c.y - axis.y, c.z - axis.z)
  b = Rl::Vector3.new(c.x + axis.x, c.y + axis.y, c.z + axis.z)
  Rl.draw_capsule(a, b, radius, 10, 6, color)
end

static_boxes = []   # [centre, size, color]
def static_box(world, list, c, s, color, friction: 0.9)
  world.body(shape: Jolt.box(s[0], s[1], s[2]), position: c, motion: Jolt::STATIC, friction: friction)
  list << [c, s, color]
end

GROUND_COL = Rl::Color.new(68, 78, 68, 255)
POST_COL   = Rl::Color.new(110, 100, 84, 255)

# ------------------------------------------------------------------- ground ----
static_box(world, static_boxes, [0, -0.5, 0], [70, 1, 70], GROUND_COL)

# === 1. MOVING PLATFORM (ride) ================================================
PLAT_SIZE = [5.0, 0.3, 4.0]
PLAT_SPAN = 8.0
PLAT_SPEED = 3.0
platform = world.body(shape: Jolt.box(*PLAT_SIZE), position: [-PLAT_SPAN, 0.15, -12.0],
                      motion: Jolt::KINEMATIC, friction: 1.0)
plat_t = 0.0

# === 2. HINGE DOOR ============================================================
DOOR_AT = [7.0, 0.0, 11.0]
# frame posts (static) + lintel
static_box(world, static_boxes, [DOOR_AT[0] - 1.1, 1.5, DOOR_AT[2]], [0.3, 3.0, 0.3], POST_COL)
static_box(world, static_boxes, [DOOR_AT[0] + 1.1, 1.5, DOOR_AT[2]], [0.3, 3.0, 0.3], POST_COL)
static_box(world, static_boxes, [DOOR_AT[0], 3.1, DOOR_AT[2]], [2.5, 0.3, 0.3], POST_COL)
door_hinge_x = DOOR_AT[0] - 1.0
door = world.body(shape: Jolt.box(1.8, 2.6, 0.12),
                  position: [door_hinge_x + 0.9, 1.5, DOOR_AT[2]], motion: Jolt::DYNAMIC,
                  mass: 8.0, friction: 0.4)
world.hinge(world.body(shape: Jolt.box(0.1, 0.1, 0.1), position: [door_hinge_x, 1.5, DOOR_AT[2]],
                       motion: Jolt::STATIC),
            door, [door_hinge_x, 1.5, DOOR_AT[2]], [0, 1, 0], min_deg: -100, max_deg: 100)

# === 3. PENDULUM (distance-joint rod) + SENSOR ================================
PEND_AT = [-8.0, 0, 11.0]
pend_top = 4.8
pivot = [PEND_AT[0], pend_top, PEND_AT[2]]
anchor = world.body(shape: Jolt.box(0.3, 0.3, 0.3), position: pivot, motion: Jolt::STATIC)
# released from the side at radius ~2.0 -> swings down through the bottom
bob_start = [PEND_AT[0] + 1.45, pend_top - 1.45, PEND_AT[2]]
bob = world.body(shape: Jolt.sphere(0.45), position: bob_start, motion: Jolt::DYNAMIC, mass: 6.0)
world.distance_joint(anchor, bob, pivot, bob_start, min: 0.0, max: 2.05)   # fixed-length pendulum rod
# a glowing trigger volume at the bottom of the swing (sensor enter/leave)
sensor_c = [PEND_AT[0], pend_top - 2.05, PEND_AT[2]]
sensor = world.body(shape: Jolt.box(1.3, 1.3, 1.3), position: sensor_c,
                    motion: Jolt::STATIC, sensor: true)
sensor_inside = 0
sensor_total  = 0

# === 3b. BALL JOINT (hanging sign: free swing + twist) ========================
SIGN_AT = [2.5, 0, 12.0]
sign_top = 4.3
sign_anchor = world.body(shape: Jolt.box(0.3, 0.3, 0.3), position: [SIGN_AT[0], sign_top, SIGN_AT[2]],
                         motion: Jolt::STATIC)
sign = world.body(shape: Jolt.box(1.5, 1.0, 0.12), position: [SIGN_AT[0], sign_top - 0.5, SIGN_AT[2]],
                  motion: Jolt::DYNAMIC, mass: 4.0)
# pivot is the sign's own TOP-CENTRE -> a real ball-and-socket (point coincident)
world.ball_joint(sign_anchor, sign, [SIGN_AT[0], sign_top, SIGN_AT[2]])
sign.linear_velocity = [2.0, 0, 1.5]   # nudge so it swings AND twists

# === 4. ROPE (chain of distance joints) =======================================
ROPE_AT = [-3.0, 0, 12.0]
rope_top = 4.8
rope_links = []     # [body, radius]
rope_prev = world.body(shape: Jolt.box(0.2, 0.2, 0.2), position: [ROPE_AT[0], rope_top, ROPE_AT[2]],
                       motion: Jolt::STATIC)
prev_pos = [ROPE_AT[0], rope_top, ROPE_AT[2]]
LINK = 0.45
6.times do |i|
  pos = [ROPE_AT[0], rope_top - LINK * (i + 1), ROPE_AT[2]]
  last = (i == 5)
  link = world.body(shape: Jolt.sphere(last ? 0.32 : 0.13), position: pos,
                    motion: Jolt::DYNAMIC, mass: last ? 8.0 : 1.0, linear_damping: 0.2)
  world.distance_joint(rope_prev, link, prev_pos, pos, min: 0.0, max: LINK)
  rope_links << [link, last ? 0.32 : 0.13]
  rope_prev = link
  prev_pos = pos
end

# === 5. SLIDER PISTON =========================================================
SLIDE_AT = [11.0, 0.7, 2.0]
slide_anchor = world.body(shape: Jolt.box(0.2, 0.2, 0.2), position: SLIDE_AT, motion: Jolt::STATIC)
slider_block = world.body(shape: Jolt.box(0.9, 0.9, 0.9), position: SLIDE_AT,
                          motion: Jolt::DYNAMIC, mass: 4.0)
slider_block.gravity_factor = 0.0   # ride the rail level instead of sagging to a stop
world.slider(slide_anchor, slider_block, SLIDE_AT, [0, 0, 1], min: -2.5, max: 2.5)
slider_block.linear_velocity = [0, 0, 4.0]   # bounces between the stops

# === 6. CONE LIMB (swing limited to a cone) ===================================
# A limb pinned at its TOP via a cone joint: it hangs, and a nudge swings it —
# but only up to half_angle_deg from vertical, then the cone stops it.
TETHER_AT = [11.0, 0, -3.0]
tether_top = 4.3
TETHER_HH  = 0.5
TETHER_R   = 0.16
tether_pole = world.body(shape: Jolt.box(0.25, 0.25, 0.25),
                         position: [TETHER_AT[0], tether_top, TETHER_AT[2]], motion: Jolt::STATIC)
# capsule centre placed so its top sits at the pivot (pin at the limb's top)
tether_ball = world.body(shape: Jolt.capsule(TETHER_HH, TETHER_R),
                         position: [TETHER_AT[0], tether_top - (TETHER_HH + TETHER_R), TETHER_AT[2]],
                         motion: Jolt::DYNAMIC, mass: 4.0)
world.cone(tether_pole, tether_ball, [TETHER_AT[0], tether_top, TETHER_AT[2]], [0, 1, 0],
           half_angle_deg: 40.0)
tether_ball.linear_velocity = [3.5, 0, 2.5]   # swing within the cone

# === 7. WELD =================================================================
WELD_AT = [-11.0, 0, 0.0]
weld_a = world.body(shape: Jolt.box(1.4, 0.6, 1.4), position: [WELD_AT[0], 0.6, WELD_AT[2]],
                    motion: Jolt::DYNAMIC, mass: 6.0)
weld_b = world.body(shape: Jolt.box(0.6, 2.0, 0.6), position: [WELD_AT[0] + 0.4, 1.9, WELD_AT[2]],
                    motion: Jolt::DYNAMIC, mass: 3.0)
world.weld(weld_a, weld_b)   # the two move as one rigid L-shape

# === 7b. BALL PIT =============================================================
# A square corral of low static walls holding 25 dynamic balls to wade through.
PIT_HALF   = 3.0
# nudged +z (away from the static CCD wall at z=-16) by 25% of the pit's size
PIT_AT     = [0.0, 0.0, -8.0 + 0.25 * (2 * PIT_HALF)]   # -> z = -6.5
PIT_WALL_H = 1.2
PIT_WALL_T = 0.4
PIT_COL    = Rl::Color.new(60, 70, 92, 255)
pwy = PIT_WALL_H / 2.0
span = 2 * PIT_HALF + PIT_WALL_T
static_box(world, static_boxes, [PIT_AT[0] - PIT_HALF, pwy, PIT_AT[2]], [PIT_WALL_T, PIT_WALL_H, span], PIT_COL)
static_box(world, static_boxes, [PIT_AT[0] + PIT_HALF, pwy, PIT_AT[2]], [PIT_WALL_T, PIT_WALL_H, span], PIT_COL)
static_box(world, static_boxes, [PIT_AT[0], pwy, PIT_AT[2] - PIT_HALF], [span, PIT_WALL_H, PIT_WALL_T], PIT_COL)
static_box(world, static_boxes, [PIT_AT[0], pwy, PIT_AT[2] + PIT_HALF], [span, PIT_WALL_H, PIT_WALL_T], PIT_COL)
BALL_PALETTE = [Rl::RED, Rl::ORANGE, Rl::GOLD, Rl::LIME, Rl::SKYBLUE, Rl::BLUE, Rl::VIOLET, Rl::PINK]
balls = []
bi = 0
[-2.0, -1.0, 0.0, 1.0, 2.0].each do |bx|
  [-2.0, -1.0, 0.0, 1.0, 2.0].each do |bz|
    r = 0.35
    bb = world.body(shape: Jolt.sphere(r),
                    position: [PIT_AT[0] + bx, 0.6 + (bi % 3) * 0.12, PIT_AT[2] + bz],
                    motion: Jolt::DYNAMIC, restitution: 0.4, friction: 0.4, mass: 1.0)
    balls << [bb, r, BALL_PALETTE[bi % BALL_PALETTE.length]]
    bi += 1
  end
end

# === 11. TANDEM MOVING WALLS ==================================================
# Two walls facing each other across X, 10 player-widths apart, gliding left/right
# IN TANDEM (same offset, constant gap) so they bulldoze whatever — ragdolls you
# spawn, stray balls — is caught between them. Sweep spans ~30 player-widths.
WALL_GAP_HALF = (10 * PLAYER_WIDTH) / 2.0     # 4.0  -> walls 8 m (10 widths) apart
WALL_SEP      = 2 * WALL_GAP_HALF              # 8.0  -> one wall-separation length
WALL_CENTRE_X = -WALL_SEP                       # shifted one separation to the LEFT
WALL_SWEEP    = (30 * PLAYER_WIDTH) / 2.0     # 12.0 -> 24 m (30 widths) peak-to-peak
WALL_Z        = 6.0                            # a clear lane in front of the perimeter stations
WALL_SIZE     = [0.5, 3.0, 6.0]
WALL_Y        = WALL_SIZE[1] / 2.0
WALL_OMEGA    = 0.6
wall_l = world.body(shape: Jolt.box(*WALL_SIZE), position: [WALL_CENTRE_X - WALL_GAP_HALF, WALL_Y, WALL_Z],
                    motion: Jolt::KINEMATIC, friction: 0.6)
wall_r = world.body(shape: Jolt.box(*WALL_SIZE), position: [WALL_CENTRE_X + WALL_GAP_HALF, WALL_Y, WALL_Z],
                    motion: Jolt::KINEMATIC, friction: 0.6)
wall_t = 0.0

# === 8. CCD WALL ==============================================================
CCD_WALL_AT = [0.0, 1.6, -16.0]
static_box(world, static_boxes, CCD_WALL_AT, [6.0, 3.2, 0.05], Rl::Color.new(150, 90, 90, 255))
bullets = []   # [body, radius, born_frame]

# === 10. RAGDOLL (factory) ====================================================
SKIN  = Rl::Color.new(214, 170, 130, 255)
SHIRT = Rl::Color.new(70, 120, 210, 255)
PANTS = Rl::Color.new(55, 55, 75, 255)
ragdolls = []   # [ragdoll, [draw,...]]
def spawn_ragdoll(world, ragdolls, x, y, z)
  th_hh, th_r = 0.22, 0.16
  parts = [
    { name: :torso, shape: Jolt.capsule(th_hh, th_r), position: [x, y, z], mass: 20.0 },
    { name: :head,  shape: Jolt.sphere(0.16), position: [x, y + th_hh + 0.22, z], parent: :torso,
      joint: [x, y + th_hh + 0.02, z], cone_deg: 25, twist_min_deg: -25, twist_max_deg: 25, mass: 4.0 },
    { name: :larm, shape: Jolt.capsule(0.16, 0.065), position: [x - th_r - 0.1, y + 0.06, z],
      rotation: [0, 0, 0.707, 0.707], parent: :torso, joint: [x - th_r, y + th_hh - 0.02, z],
      twist_axis: [1, 0, 0], plane_axis: [0, 1, 0], cone_deg: 70, mass: 3.0 },
    { name: :rarm, shape: Jolt.capsule(0.16, 0.065), position: [x + th_r + 0.1, y + 0.06, z],
      rotation: [0, 0, 0.707, 0.707], parent: :torso, joint: [x + th_r, y + th_hh - 0.02, z],
      twist_axis: [1, 0, 0], plane_axis: [0, 1, 0], cone_deg: 70, mass: 3.0 },
    { name: :lleg, shape: Jolt.capsule(0.2, 0.085), position: [x - 0.1, y - th_hh - 0.26, z],
      parent: :torso, joint: [x - 0.1, y - th_hh, z], cone_deg: 40, mass: 5.0 },
    { name: :rleg, shape: Jolt.capsule(0.2, 0.085), position: [x + 0.1, y - th_hh - 0.26, z],
      parent: :torso, joint: [x + 0.1, y - th_hh, z], cone_deg: 40, mass: 5.0 },
  ]
  draw = [[:capsule, th_hh, th_r, SHIRT], [:sphere, 0.16, SKIN],
          [:capsule, 0.16, 0.065, SKIN], [:capsule, 0.16, 0.065, SKIN],
          [:capsule, 0.2, 0.085, PANTS], [:capsule, 0.2, 0.085, PANTS]]
  ragdolls << [world.ragdoll(parts: parts), draw]
end

# -------------------------------------------------------------------- player ---
player = world.character(shape: Jolt.capsule(PLAYER_HALFH, PLAYER_RADIUS),
                         position: [0, PLAYER_FOOT_TO_CENTRE + 0.2, 4.0],
                         max_slope_deg: 50.0, mass: 90.0)
player.max_strength = 5000.0
world.optimize_broad_phase

# -------------------------------------------------------------------- camera ---
cam = Rl::Camera3D.new(Rl::Vector3.new(0, 6, 12), Rl::Vector3.new(0, 1, 0),
                       Rl::Vector3.new(0, 1, 0), 60.0, Rl::CAMERA_PERSPECTIVE)
cam_yaw = Math::PI
cam_pitch = -0.25
CAM_DIST = 8.0
MOUSE_SENS = 0.0032

frame = 0

Rl.while_window_open do
  frame += 1
  dt = Rl.frame_time
  dt = 1.0 / 60.0 if dt <= 0.0 || dt > 0.1

  # ---- mouse look ----
  Rl.disable_cursor if Rl.mouse_button_pressed?(Rl::MOUSE_BUTTON_LEFT) && !Rl.cursor_hidden?
  if Rl.cursor_hidden?
    md = Rl.get_mouse_delta
    cam_yaw   -= md.x * MOUSE_SENS   # mouse-right looks right
    cam_pitch  = clampf(cam_pitch - md.y * MOUSE_SENS, -1.2, 0.5)
  end
  fwd_x = Math.sin(cam_yaw); fwd_z = Math.cos(cam_yaw)
  right_x = -Math.cos(cam_yaw); right_z = Math.sin(cam_yaw)

  # ---- movement intent (each key gates BOTH axes; trailing-if guards last stmt only) ----
  mx = 0.0; mz = 0.0
  if Rl.key_down?(:w) then mx += fwd_x;   mz += fwd_z;   end
  if Rl.key_down?(:s) then mx -= fwd_x;   mz -= fwd_z;   end
  if Rl.key_down?(:a) then mx -= right_x; mz -= right_z; end
  if Rl.key_down?(:d) then mx += right_x; mz += right_z; end
  len = Math.sqrt(mx * mx + mz * mz)
  if len > 0.0001 then mx /= len; mz /= len; end
  speed = MOVE_SPEED * (Rl.key_down?(:left_shift) ? SPRINT_MULT : 1.0)

  # ---- spawn ragdoll (FIFO: drop the oldest past the cap) / fire CCD bullet ----
  if Rl.key_pressed?(:r)
    if ragdolls.length >= MAX_RAGDOLLS
      old_rd, = ragdolls.shift
      old_rd.remove
    end
    spawn_ragdoll(world, ragdolls, player.position.x + fwd_x * 2, 4.0, player.position.z + fwd_z * 2)
  end
  if Rl.key_pressed?(:f)
    eye = cam.position
    look = [cam.target.x - eye.x, cam.target.y - eye.y, cam.target.z - eye.z]
    ll = Math.sqrt(look[0]**2 + look[1]**2 + look[2]**2); ll = 1.0 if ll < 1e-4
    dir = [look[0] / ll, look[1] / ll, look[2] / ll]
    # Spawn the bullet just PAST the player capsule along the aim, not at the
    # camera (which sits behind the player). Spawning at the camera made the
    # bullet's path cross the player, and the fast CCD hit shoved the character
    # forward — worst when looking up, where the follow-camera dips near/below the
    # ground and the bullet rises up through the capsule. `clr` clears the capsule
    # in any aim direction (Y-aligned capsule support = halfH*|dir.y| + radius).
    pp = player.position
    clr = PLAYER_HALFH * dir[1].abs + PLAYER_RADIUS + 0.12 + 0.2
    b = world.body(shape: Jolt.sphere(0.12),
                   position: [pp.x + dir[0] * clr, pp.y + dir[1] * clr, pp.z + dir[2] * clr],
                   motion: Jolt::DYNAMIC, mass: 2.0, ccd: true, restitution: 0.2)
    b.linear_velocity = [dir[0] * 90, dir[1] * 90, dir[2] * 90]   # fast: needs CCD to not tunnel
    bullets << [b, 0.12, frame]
  end

  # ---- vertical velocity, then RIDE (inherits platform velocity) ----
  v = player.velocity
  vy = player.on_ground? ? (Rl.key_pressed?(:space) ? JUMP_SPEED : 0.0) : v.y - GRAVITY * dt
  player.velocity = [mx * speed, vy, mz * speed]
  player.ride(dt)

  # ---- drive kinematic stations ----
  plat_t += dt
  platform.linear_velocity = [Math.cos(plat_t * PLAT_SPEED / PLAT_SPAN) * PLAT_SPEED, 0, 0]
  # tandem moving walls: same velocity, constant gap, so they shove what's between
  wall_t += dt
  wall_vx = Math.cos(wall_t * WALL_OMEGA) * WALL_SWEEP * WALL_OMEGA
  wall_xo = Math.sin(wall_t * WALL_OMEGA) * WALL_SWEEP
  wall_l.linear_velocity = [wall_vx, 0, 0]
  wall_r.linear_velocity = [wall_vx, 0, 0]

  world.step(dt)

  platform.set_transform(position: [Math.sin(plat_t * PLAT_SPEED / PLAT_SPAN) * PLAT_SPAN, 0.15, -12.0])
  wall_l.set_transform(position: [WALL_CENTRE_X + wall_xo - WALL_GAP_HALF, WALL_Y, WALL_Z])
  wall_r.set_transform(position: [WALL_CENTRE_X + wall_xo + WALL_GAP_HALF, WALL_Y, WALL_Z])

  # ---- sensor enter/leave bookkeeping (trigger volume) ----
  world.contacts.each do |c|
    next unless c.involves?(sensor)
    sensor_inside += 1; sensor_total += 1
  end
  world.contacts_ended.each { |c| sensor_inside -= 1 if c.involves?(sensor) }
  sensor_inside = 0 if sensor_inside < 0

  # ---- retire old bullets ----
  bullets.reject! do |bd, _, born|
    dead = frame - born > 600
    bd.remove if dead
    dead
  end

  # ---- third-person follow camera ----
  p = player.position
  cp = Math.cos(cam_pitch)
  cam.position = Rl::Vector3.new(p.x - fwd_x * CAM_DIST * cp, p.y + 2.4 - Math.sin(cam_pitch) * CAM_DIST,
                                 p.z - fwd_z * CAM_DIST * cp)
  cam.target = Rl::Vector3.new(p.x, p.y + 1.0, p.z)

  # ---- raycast from the crosshair: hit point + surface NORMAL + body under it ----
  eye = cam.position
  look = [cam.target.x - eye.x, cam.target.y - eye.y, cam.target.z - eye.z]
  ll = Math.sqrt(look[0]**2 + look[1]**2 + look[2]**2); ll = 1.0 if ll < 1e-4
  rdir = [look[0] / ll * 40.0, look[1] / ll * 40.0, look[2] / ll * 40.0]
  hit = world.raycast([eye.x, eye.y, eye.z], rdir)
  overlap_n = hit ? world.overlap_point([hit.point.x, hit.point.y, hit.point.z]).length : 0

  # ------------------------------------------------------------------ render ---
  Rl.draw(clear_color: Rl::Color.new(140, 165, 195, 255)) do
    Rl.begin_mode3d(cam)
    Rl.draw_grid(70, 1)

    # static geometry (axis-aligned: cube_v is fine)
    static_boxes.each do |c, s, color|
      Rl.draw_cube_v(Rl::Vector3.new(*c), Rl::Vector3.new(*s), color)
      Rl.draw_cube_wires_v(Rl::Vector3.new(*c), Rl::Vector3.new(*s), Rl::Color.new(25, 25, 25, 110))
    end

    # 1. moving platform
    draw_box_body(platform, PLAT_SIZE, Rl::Color.new(150, 110, 70, 255))
    # 11. tandem moving walls
    [wall_l, wall_r].each do |wl|
      Rl.draw_cube_v(wl.position, Rl::Vector3.new(*WALL_SIZE), Rl::Color.new(190, 70, 70, 255))
      Rl.draw_cube_wires_v(wl.position, Rl::Vector3.new(*WALL_SIZE), Rl::Color.new(20, 20, 20, 200))
    end
    # 7b. ball pit
    balls.each { |bb, br, bc| Rl.draw_sphere(bb.position, br, bc) }
    # 2. hinge door
    draw_box_body(door, [1.8, 2.6, 0.12], Rl::Color.new(160, 120, 90, 255))
    # 3. pendulum + sensor (sensor glows brighter while occupied)
    Rl.draw_sphere(bob.position, 0.45, Rl::Color.new(220, 80, 80, 255))
    Rl.draw_line3d(Rl::Vector3.new(*pivot), bob.position, Rl::DARKGRAY)
    sa = sensor_inside > 0 ? 150 : 55
    sc = sensor_inside > 0 ? Rl::Color.new(120, 255, 140, sa) : Rl::Color.new(120, 220, 255, sa)
    Rl.draw_cube_v(Rl::Vector3.new(*sensor_c), Rl::Vector3.new(1.3, 1.3, 1.3), sc)
    Rl.draw_cube_wires_v(Rl::Vector3.new(*sensor_c), Rl::Vector3.new(1.3, 1.3, 1.3), Rl::GREEN)
    # 3b. ball-joint sign
    Rl.draw_line3d(Rl::Vector3.new(SIGN_AT[0], sign_top, SIGN_AT[2]), sign.position, Rl::DARKGRAY)
    draw_box_body(sign, [1.5, 1.0, 0.12], Rl::Color.new(230, 180, 60, 255))
    # 4. rope
    rprev = Rl::Vector3.new(ROPE_AT[0], rope_top, ROPE_AT[2])
    rope_links.each do |lb, lr|
      Rl.draw_line3d(rprev, lb.position, Rl::DARKBROWN)
      Rl.draw_sphere(lb.position, lr, Rl::Color.new(180, 140, 90, 255))
      rprev = lb.position
    end
    # 5. slider
    draw_box_body(slider_block, [0.9, 0.9, 0.9], Rl::Color.new(90, 200, 160, 255))
    Rl.draw_line3d(Rl::Vector3.new(SLIDE_AT[0], SLIDE_AT[1], SLIDE_AT[2] - 2.5),
                   Rl::Vector3.new(SLIDE_AT[0], SLIDE_AT[1], SLIDE_AT[2] + 2.5), Rl::DARKGRAY)
    # 6. cone limb
    Rl.draw_line3d(Rl::Vector3.new(TETHER_AT[0], tether_top, TETHER_AT[2]), tether_ball.position, Rl::DARKGRAY)
    draw_capsule_body(tether_ball, TETHER_HH, TETHER_R, Rl::Color.new(240, 200, 70, 255))
    # 7. weld (two boxes, one rigid body)
    draw_box_body(weld_a, [1.4, 0.6, 1.4], Rl::Color.new(200, 120, 160, 255))
    draw_box_body(weld_b, [0.6, 2.0, 0.6], Rl::Color.new(160, 90, 200, 255))
    # 8. bullets
    bullets.each { |bd, br, _| Rl.draw_sphere(bd.position, br, Rl::Color.new(40, 40, 40, 255)) }
    # 10. ragdolls
    ragdolls.each do |rd, draw|
      rd.bodies.each_with_index do |bp, i|
        d = draw[i]
        d[0] == :sphere ? Rl.draw_sphere(bp.position, d[1], d[2]) : draw_capsule_body(bp, d[1], d[2], d[3])
      end
    end

    # 9. raycast hit marker + surface normal line
    if hit
      hp = hit.point
      Rl.draw_sphere(hp, 0.12, Rl::RED)
      n = hit.normal
      Rl.draw_line3d(hp, Rl::Vector3.new(hp.x + n.x * 1.2, hp.y + n.y * 1.2, hp.z + n.z * 1.2), Rl::YELLOW)
    end

    # player capsule
    pc = player.position
    pcol = player.on_ground? ? Rl::Color.new(60, 200, 240, 255) : Rl::Color.new(240, 200, 60, 255)
    Rl.draw_capsule(Rl::Vector3.new(pc.x, pc.y - PLAYER_HALFH, pc.z),
                    Rl::Vector3.new(pc.x, pc.y + PLAYER_HALFH, pc.z), PLAYER_RADIUS, 12, 8, pcol)
    Rl.end_mode3d

    # crosshair
    Rl.draw_circle(Rl.screen_width / 2, Rl.screen_height / 2, 3, Rl::Color.new(255, 255, 255, 200))

    # ------------------------------------------------------------------- HUD (RmlUi) --
    hud_left.set_property("font-size", "#{hud_font_size}px")
    hud_right.set_property("font-size", "#{hud_font_size}px")
    hud_left.set_property("transform",
      "perspective(1500px) rotate3d(1,0,0,#{hud_angle_x}deg) rotate3d(0,1,0,#{hud_angle_y}deg)")
    hud_right.set_property("transform",
      "perspective(1500px) rotate3d(1,0,0,#{hud_angle_x}deg) rotate3d(0,1,0,#{-hud_angle_y}deg)")
    hud_left.set_property("background-color", "rgba(#{hud_r},#{hud_g},#{hud_b},#{hud_a})")
    hud_right.set_property("background-color", "rgba(#{hud_r},#{hud_g},#{hud_b},#{hud_a})")

    riding = player.ground_body && player.ground_body.id == platform.id
    hud_ride.inner_rml = riding ? "RIDING PLATFORM" : "find the moving platform ->"
    hud_ride.set_property("color", riding ? "#a6e3a1" : "#bac2de")
    hud_sensor.inner_rml = "sensor: #{sensor_inside > 0 ? 'OCCUPIED' : 'clear'}  (passes: #{sensor_total})"
    hud_sensor.set_property("color", sensor_inside > 0 ? "#a6e3a1" : "#bac2de")
    if hit
      n = hit.normal
      hud_ray.inner_rml = format("raycast: body %d  normal (%.2f, %.2f, %.2f)  overlap=%d",
                                  hit.body_id, n.x, n.y, n.z, overlap_n)
      hud_ray.set_property("color", "#f9e2af")
    else
      hud_ray.inner_rml = ""
    end
    hud_counts.inner_rml = "ragdolls: #{ragdolls.length}/#{MAX_RAGDOLLS}   bullets: #{bullets.length}"
    hud_fps.inner_rml = "FPS: #{Rl.get_fps}"
    ui.update
    ui.render

    unless Rl.cursor_hidden?
      Rl.draw_text(text: "Click to look around", x: Rl.screen_width / 2 - 120,
                   y: Rl.screen_height / 2 + 30, font_size: 26, color: Rl::RAYWHITE)
    end
  end
end
