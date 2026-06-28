# raylib-jamstack: ragdolls + flecs + a rideable platform — raylib + Jolt + flecs.
#
#   ./zig-out/bin/game game/ragdoll_demo.rb                       (desktop)
#   JAMSTACK_BRIDGE=1 ./zig-out/bin/game game/ragdoll_demo.rb     (+ agent bridge)
#   (web: preloaded; runnable as /game/ragdoll_demo.rb; bridge via the relay)
#
# A third-person character on a plane; a KINEMATIC platform glides across a gap you
# can RIDE. Press R to drop a humanoid ragdoll (capsule limbs + sphere head, wired
# with swing-twist joints); F flings the pile away from you.
#
# AGENTIC HOOKS (this is also the mruby<->flecs<->Jolt demo):
#   * a flecs World tracks every ragdoll as an entity; a Flecs::Hot system syncs
#     each Ragdoll{x,y,z} component from its Jolt torso body each frame.
#   * summon a ragdoll AT A POINT OF YOUR CHOOSING from mruby, live over the bridge:
#       sh .live/<token>/bin/eval 'summon_ragdoll(2, 9, 0)'
#   * talk to flecs over the bridge:
#       sh .live/<token>/bin/eval '$flecs.query($rag_comp).count'        # how many
#       sh .live/<token>/bin/eval '$flecs.entity_for(ID).get($rag_comp)' # live pos
#       sh .live/<token>/bin/eval '$flecs.lookup("ragdoll_0").get($rag_comp)'
#   Globals exposed for the bridge: $player $jolt $flecs $rag_comp $ragdolls $rag_by_entity
#   e.g. rain 30 ragdolls on the player:
#     p=$player.position; 30.times{|i| summon_ragdoll(p.x,(p.y+4+i*0.8),p.z)}
#
# Controls:  WASD move (camera-relative)   SPACE jump   Mouse look
#            R drop ragdoll   F fling ragdolls   hold SHIFT sprint   ESC quit

GRAVITY     = 22.0
MOVE_SPEED  = 6.0
SPRINT_MULT = 1.7
JUMP_SPEED  = 8.0
PLAYER_RADIUS = 0.4
PLAYER_HALFH  = 0.5
PLAYER_FOOT_TO_CENTRE = PLAYER_HALFH + PLAYER_RADIUS

Rl.init_window(1024, 600, "raylib-jamstack: ragdolls + moving platform (Jolt)")
Rl.target_fps = 60
Rl.disable_cursor

world = Jolt::World.new(gravity: [0, -GRAVITY, 0])

# --- two ground slabs with a gap the platform bridges ---
boxes = []
def static_box(world, boxes, cx, cy, cz, sx, sy, sz, color, friction: 0.9)
  world.body(shape: Jolt.box(sx, sy, sz), position: [cx, cy, cz], motion: Jolt::STATIC, friction: friction)
  boxes << [[cx, cy, cz], [sx, sy, sz], color]
end
GROUND_COL = Rl::Color.new(70, 80, 70, 255)
GAP_HALF   = 5.0          # half-width of the gap (x) the platform crosses
SLAB       = 14.0         # x-depth of each side slab
static_box(world, boxes, -(GAP_HALF + SLAB / 2.0), -0.5, 0.0, SLAB, 1.0, 30.0, GROUND_COL)
static_box(world, boxes,  (GAP_HALF + SLAB / 2.0), -0.5, 0.0, SLAB, 1.0, 30.0, GROUND_COL)

# --- the moving platform: KINEMATIC, glides across the gap on x ---
PLAT_SIZE  = [4.0, 0.5, 5.0]
PLAT_SPAN  = GAP_HALF + 1.0   # travels +/- this on x
PLAT_SPEED = 3.0              # m/s
plat = world.body(shape: Jolt.box(*PLAT_SIZE), position: [-PLAT_SPAN, 0.0, 0.0],
                  motion: Jolt::KINEMATIC, friction: 1.0)
plat_t = 0.0

# --- flecs: track each ragdoll as an entity. A Flecs::Hot system syncs the
# Ragdoll{x,y,z} component from the Jolt torso body every frame, so the live world
# is queryable over the agent bridge (and the sync system is hot-reloadable).
$jolt          = world
$flecs         = Flecs::World.new
$rag_comp      = $flecs.struct("Ragdoll", "{float x; float y; float z;}")
$ragdolls      = []   # [[ragdoll, [draw,...]], ...]  (for rendering)
$rag_by_entity = {}   # flecs entity id -> Jolt::Ragdoll
$rag_seq       = 0

Flecs::Hot.world = $flecs
Flecs::Hot.define_system("TrackRagdolls", with: ["Ragdoll"]) do |eid, r|
  rd = $rag_by_entity[eid]
  if rd
    p = rd.bodies[0].position
    r[:x] = p.x; r[:y] = p.y; r[:z] = p.z
  end
end

# --- ragdoll factory: a humanoid of capsules + a sphere head ---
SKIN  = Rl::Color.new(214, 170, 130, 255)
SHIRT = Rl::Color.new(70, 120, 210, 255)
PANTS = Rl::Color.new(60, 60, 80, 255)

# Summon a ragdoll at (x, y, z). Spawns the Jolt humanoid AND a flecs entity that
# tracks it. Top-level method, so the agent bridge can call it live:
#   sh .live/<token>/bin/eval 'summon_ragdoll(2, 9, 0)'   -> returns the entity id
def summon_ragdoll(x, y, z)
  th_hh, th_r = 0.22, 0.16     # torso
  hd_r        = 0.16           # head
  ua_hh, ua_r = 0.16, 0.065    # upper arm
  lg_hh, lg_r = 0.20, 0.085    # leg
  parts = [
    { name: :torso, shape: Jolt.capsule(th_hh, th_r), position: [x, y, z], mass: 20.0 },
    { name: :head,  shape: Jolt.sphere(hd_r), position: [x, y + th_hh + 0.22, z], parent: :torso,
      joint: [x, y + th_hh + 0.02, z], twist_axis: [0, 1, 0], plane_axis: [1, 0, 0],
      cone_deg: 25, plane_deg: 25, twist_min_deg: -25, twist_max_deg: 25, mass: 4.0 },
    { name: :larm,  shape: Jolt.capsule(ua_hh, ua_r), position: [x - th_r - ua_r - 0.04, y + 0.06, z],
      rotation: [0, 0, 0.707, 0.707], parent: :torso,                 # rotate capsule to horizontal
      joint: [x - th_r, y + th_hh - 0.02, z], twist_axis: [1, 0, 0], plane_axis: [0, 1, 0],
      cone_deg: 70, plane_deg: 45, twist_min_deg: -20, twist_max_deg: 20, mass: 3.0 },
    { name: :rarm,  shape: Jolt.capsule(ua_hh, ua_r), position: [x + th_r + ua_r + 0.04, y + 0.06, z],
      rotation: [0, 0, 0.707, 0.707], parent: :torso,
      joint: [x + th_r, y + th_hh - 0.02, z], twist_axis: [1, 0, 0], plane_axis: [0, 1, 0],
      cone_deg: 70, plane_deg: 45, twist_min_deg: -20, twist_max_deg: 20, mass: 3.0 },
    { name: :lleg,  shape: Jolt.capsule(lg_hh, lg_r), position: [x - 0.10, y - th_hh - lg_hh - 0.06, z],
      parent: :torso, joint: [x - 0.10, y - th_hh, z], twist_axis: [0, 1, 0], plane_axis: [1, 0, 0],
      cone_deg: 40, plane_deg: 25, twist_min_deg: -10, twist_max_deg: 10, mass: 5.0 },
    { name: :rleg,  shape: Jolt.capsule(lg_hh, lg_r), position: [x + 0.10, y - th_hh - lg_hh - 0.06, z],
      parent: :torso, joint: [x + 0.10, y - th_hh, z], twist_axis: [0, 1, 0], plane_axis: [1, 0, 0],
      cone_deg: 40, plane_deg: 25, twist_min_deg: -10, twist_max_deg: 10, mass: 5.0 },
  ]
  draw = [
    [:capsule, th_hh, th_r, SHIRT], [:sphere, hd_r, SKIN],
    [:capsule, ua_hh, ua_r, SKIN], [:capsule, ua_hh, ua_r, SKIN],
    [:capsule, lg_hh, lg_r, PANTS], [:capsule, lg_hh, lg_r, PANTS],
  ]
  rd = $jolt.ragdoll(parts: parts)
  $ragdolls << [rd, draw]
  ent = $flecs.entity("ragdoll_#{$rag_seq}")
  $rag_seq += 1
  ent.set($rag_comp, x: x, y: y, z: z)
  $rag_by_entity[ent.id] = rd
  ent.id
end

# --- player ---
player = world.character(shape: Jolt.capsule(PLAYER_HALFH, PLAYER_RADIUS),
                         position: [-(GAP_HALF + 4.0), PLAYER_FOOT_TO_CENTRE + 0.2, 0.0],
                         max_slope_deg: 50.0, mass: 80.0)
player.max_strength = 4000.0
$player = player        # exposed so the bridge can summon "on me" (at $player.position)
world.optimize_broad_phase

# --- camera ---
cam = Rl::Camera3D.new(Rl::Vector3.new(0, 6, 12), Rl::Vector3.new(0, 1, 0),
                       Rl::Vector3.new(0, 1, 0), 55.0, Rl::CAMERA_PERSPECTIVE)
cam_yaw = 0.0
cam_pitch = -0.3
CAM_DIST = 7.5
MOUSE_SENS = 0.0032
def clampf(v, lo, hi); v < lo ? lo : (v > hi ? hi : v); end

# draw a capsule body using its position + orientation (local axis = Y)
def draw_capsule_body(body, half_height, radius, color)
  c = body.position
  q = body.rotation
  axis = Rl.vector3_rotate_by_quaternion(Rl::Vector3.new(0, half_height, 0), q)
  a = Rl::Vector3.new(c.x - axis.x, c.y - axis.y, c.z - axis.z)
  b = Rl::Vector3.new(c.x + axis.x, c.y + axis.y, c.z + axis.z)
  Rl.draw_capsule(a, b, radius, 10, 6, color)
end

Rl.while_window_open do
  dt = Rl.frame_time
  dt = 1.0 / 60.0 if dt <= 0.0 || dt > 0.1

  Rl.disable_cursor if Rl.mouse_button_pressed?(Rl::MOUSE_BUTTON_LEFT) && !Rl.cursor_hidden?
  if Rl.cursor_hidden?
    md = Rl.get_mouse_delta
    cam_yaw   -= md.x * MOUSE_SENS   # mouse-right looks right
    cam_pitch  = clampf(cam_pitch - md.y * MOUSE_SENS, -1.3, 0.4)
  end

  fwd_x = Math.sin(cam_yaw);  fwd_z = Math.cos(cam_yaw)
  right_x = -Math.cos(cam_yaw); right_z = Math.sin(cam_yaw)

  mx = 0.0; mz = 0.0
  if Rl.key_down?(:w) then mx += fwd_x;   mz += fwd_z;   end
  if Rl.key_down?(:s) then mx -= fwd_x;   mz -= fwd_z;   end
  if Rl.key_down?(:a) then mx -= right_x; mz -= right_z; end
  if Rl.key_down?(:d) then mx += right_x; mz += right_z; end
  len = Math.sqrt(mx * mx + mz * mz)
  if len > 0.0001 then mx /= len; mz /= len; end
  speed = MOVE_SPEED * (Rl.key_down?(:left_shift) ? SPRINT_MULT : 1.0)

  # spawn / fling ragdolls (R drops above the origin; the bridge can summon anywhere)
  summon_ragdoll(0.0, 6.0, 0.0) if Rl.key_pressed?(:r) && $ragdolls.length < 40
  if Rl.key_pressed?(:f)
    pp = player.position
    $ragdolls.each do |rd, _|
      t = rd.bodies[0]
      d = t.position
      dx = d.x - pp.x; dz = d.z - pp.z
      n = Math.sqrt(dx * dx + dz * dz); n = 1.0 if n < 0.001
      rd.activate
      rd.bodies.each { |bp| bp.apply_impulse([dx / n * 40.0, 60.0, dz / n * 40.0]) }
    end
  end

  # vertical velocity (jump/gravity); ride() then adds the platform velocity
  v = player.velocity
  vy = player.on_ground? ? (Rl.key_pressed?(:space) ? JUMP_SPEED : 0.0) : v.y - GRAVITY * dt
  player.velocity = [mx * speed, vy, mz * speed]
  player.ride(dt)   # <-- moving-platform support: inherit ground velocity

  # drive the kinematic platform back and forth across the gap
  plat_t += dt
  plat_x = Math.sin(plat_t * PLAT_SPEED / PLAT_SPAN) * PLAT_SPAN
  plat_vx = Math.cos(plat_t * PLAT_SPEED / PLAT_SPAN) * PLAT_SPEED
  plat.linear_velocity = [plat_vx, 0, 0]   # velocity feeds character ground_velocity

  world.step(dt)
  plat.set_transform(position: [plat_x, 0.0, 0.0])   # pin against kinematic drift
  $flecs.progress(dt)   # run TrackRagdolls: sync each Ragdoll{x,y,z} from its torso

  # third-person follow camera
  p = player.position
  cp = Math.cos(cam_pitch)
  cam.position = Rl::Vector3.new(p.x - fwd_x * CAM_DIST * cp, p.y + 2.2 - Math.sin(cam_pitch) * CAM_DIST,
                                 p.z - fwd_z * CAM_DIST * cp)
  cam.target = Rl::Vector3.new(p.x, p.y + 1.0, p.z)

  Rl.draw(clear_color: Rl::Color.new(135, 160, 190, 255)) do
    Rl.begin_mode3d(cam)
    boxes.each do |centre, size, color|
      Rl.draw_cube_v(Rl::Vector3.new(*centre), Rl::Vector3.new(*size), color)
      Rl.draw_cube_wires_v(Rl::Vector3.new(*centre), Rl::Vector3.new(*size), Rl::Color.new(30, 30, 30, 120))
    end
    # platform
    pcv = plat.position
    Rl.draw_cube_v(pcv, Rl::Vector3.new(*PLAT_SIZE), Rl::Color.new(150, 110, 70, 255))
    Rl.draw_cube_wires_v(pcv, Rl::Vector3.new(*PLAT_SIZE), Rl::Color.new(40, 30, 20, 200))

    # ragdolls
    $ragdolls.each do |rd, draw|
      rd.bodies.each_with_index do |bp, i|
        d = draw[i]
        if d[0] == :sphere
          Rl.draw_sphere(bp.position, d[1], d[2])
        else
          draw_capsule_body(bp, d[1], d[2], d[3])
        end
      end
    end

    # player
    pc = player.position
    bottom = Rl::Vector3.new(pc.x, pc.y - PLAYER_HALFH, pc.z)
    top    = Rl::Vector3.new(pc.x, pc.y + PLAYER_HALFH, pc.z)
    pcol = player.on_ground? ? Rl::Color.new(60, 200, 240, 255) : Rl::Color.new(240, 200, 60, 255)
    Rl.draw_capsule(bottom, top, PLAYER_RADIUS, 12, 8, pcol)
    Rl.end_mode3d

    Rl.draw_text(text: "WASD move   SPACE jump   R drop ragdoll   F fling   SHIFT sprint",
                 x: 12, y: 12, font_size: 19, color: Rl::RAYWHITE)
    Rl.draw_text(text: "flecs tracks each ragdoll. Bridge: summon_ragdoll(x,y,z) / $flecs.query($rag_comp).count",
                 x: 12, y: 36, font_size: 15, color: Rl::Color.new(230, 230, 230, 255))
    riding = player.ground_body && player.ground_body.id == plat.id
    Rl.draw_text(text: "ragdolls: #{$ragdolls.length}/40   flecs entities: #{$rag_by_entity.size}   #{riding ? 'RIDING' : ''}",
                 x: 12, y: 60, font_size: 16, color: riding ? Rl::LIME : Rl::LIGHTGRAY)
    Rl.draw_fps(Rl.screen_width - 95, 12)
    unless Rl.cursor_hidden?
      Rl.draw_text(text: "Click to look around", x: Rl.screen_width / 2 - 120,
                   y: Rl.screen_height / 2, font_size: 26, color: Rl::RAYWHITE)
    end
  end
end
