# raylib-jamstack — Jolt Physics Ruby API Specification (`Jolt::`)

The optional **3D rigid-body physics** layer.
[Jolt Physics](https://github.com/jrouwe/JoltPhysics) is a fast, modern engine
(used in AAA titles). These bindings are hand-written over the
[joltc](https://github.com/amerkoleci/joltc) C API and follow the same design
rules as the other specs (snake_case, `?` predicates, `=` setters, keyword args).

Vectors accept `Array`s or `Rl::Vector3`/`Vector4` and are returned as
`Rl::Vector3`/`Vector4` (so results drop straight into raylib draw calls). Runs
**single-threaded** `step` only — identical on desktop and the wasm/web build.

## Mental model
- A `Jolt::World` owns the simulation (gravity, bodies). Step it each frame.
- A `Jolt::Shape` is a reusable collision volume (box, sphere, capsule, cylinder).
- A `Jolt::Body` is a rigid body (a body id bound to its world) with a shape,
  a motion type (static / kinematic / dynamic), a transform, and velocities.

---

## 1. World
```ruby
world = Jolt::World.new(gravity: [0, -9.81, 0], max_bodies: 10240)
world.gravity = [0, -20, 0]
world.step(dt = 1.0/60.0, collision_steps: 1)   # advance the simulation
world.update(dt)                                 # alias of step
world.optimize_broad_phase                       # call once after bulk-adding bodies
```
Integrate with the raylib loop:
```ruby
Rl.while_window_open do
  world.step(Rl.frame_time)
  Rl.draw(clear_color: Rl::RAYWHITE) do
    Rl.begin_mode3d(camera)
    world.query ... # your own draw using body.position / body.rotation
  end
end
```
> Single-threaded only (no `set_threads`); `step` runs on the calling thread.
> This is also the only mode valid on wasm, so behaviour matches across targets.

## 2. Shapes
```ruby
Jolt.box(width, height, depth)        # full dimensions (not half-extents)
Jolt.sphere(radius)
Jolt.capsule(half_height, radius)     # half-height of the cylindrical section
Jolt.cylinder(half_height, radius)
```
Shapes are reusable across many bodies.

## 3. Bodies
```ruby
body = world.body(
  shape:       Jolt.sphere(0.5),
  position:    [0, 10, 0],            # Array or Rl::Vector3
  rotation:    [0, 0, 0, 1],          # quaternion x,y,z,w (or Rl::Vector4)
  motion:      Jolt::DYNAMIC,         # Jolt::STATIC | KINEMATIC | DYNAMIC
  restitution: 0.0,                   # bounciness 0..1
  friction:    0.2,
  activate:    true,
  velocity:    [0, 0, 0],             # optional initial linear velocity
  mass:        nil,                   # kg; nil = derive from shape volume (density)
  linear_damping:  0.05,              # drag (slows linear motion)
  angular_damping: 0.05,              # drag (slows spin)
  ccd:    false,                      # continuous collision (fast bodies vs thin walls)
  sensor: false)                      # trigger volume: detect overlap, no physical response
world.add_body(...)                   # alias of body
body.sensor = true ; body.ccd = true  # also settable at runtime
```
Shapes also include `Jolt.convex_hull(points)` (an `Array` of `[x,y,z]`) and
`Jolt.mesh(vertices)` (triangle soup, 3 verts per triangle — **static bodies
only**, for level geometry).

`Jolt::Body`:
```ruby
body.id ; body.to_i
body.position        # -> Rl::Vector3   ; body.position = [x,y,z]
body.center_of_mass  # -> Rl::Vector3
body.rotation        # -> Rl::Vector4 (quaternion x,y,z,w)
body.set_transform(position:, rotation: nil, activate: true)
body.linear_velocity  ; body.linear_velocity = [x,y,z]
body.angular_velocity ; body.angular_velocity = [x,y,z]
body.apply_force(v)   ; body.apply_impulse(v) ; body.apply_torque(v)   # chainable
body.active? ; body.activate ; body.deactivate     # sleeping bodies are inactive
body.remove                                         # remove + destroy
# tunable properties (get + set)
body.user_data ; body.user_data = entity_id        # 64-bit tag for collision lookup
body.motion_type ; body.motion_type = Jolt::KINEMATIC ; body.set_motion_type(mt, activate: true)
body.friction = 0.8 ; body.restitution = 0.9 ; body.gravity_factor = 0.0
```
> Motion types: `STATIC` (never moves — floors/walls), `KINEMATIC` (moved by you
> via velocity/transform, infinite mass), `DYNAMIC` (simulated). A body's
> collision layer is derived automatically from its motion type.
> `user_data` is the bridge to your game: store a flecs entity id (or any 64-bit
> tag) so collision events can be mapped back to game objects.

## 3a. Collision events
`world.contacts` returns the collisions that **began** during the last `step` as
`Jolt::Contact`s. Pair this with `body.user_data` to react in gameplay:
```ruby
world.step(dt)
world.contacts.each do |c|
  c.body_a_id ; c.body_b_id          # the two bodies' ids
  c.body_a    ; c.body_b             # -> Jolt::Body
  c.point     # -> Rl::Vector3 (world-space)   ;   c.normal -> Rl::Vector3
  c.involves?(player)                # is a given body/id in this contact?
  hit = c.other(player)              # the *other* body in the contact
  damage!(hit.user_data) if c.involves?(player)
end
```
> Only contacts that newly begin are reported (not every step they persist), so
> the list stays small. The buffer is capped (4096/step); excess is dropped.

**Contacts that ENDED** this step (stopped touching) come from `world.contacts_ended`
(`Jolt::ContactEnd`: `body_a_id`/`body_b_id`/`body_a`/`body_b`/`involves?`/`other`,
no point/normal). Combine with a **sensor** body (`sensor: true`) for trigger
volumes — `contacts` = "entered the zone", `contacts_ended` = "left the zone":
```ruby
zone = world.body(shape: Jolt.box(4,4,4), position: [0,2,0], motion: Jolt::STATIC, sensor: true)
world.step(dt)
world.contacts.each       { |c| on_enter(c.other(zone)) if c.involves?(zone) }
world.contacts_ended.each { |c| on_leave(c.other(zone)) if c.involves?(zone) }
```

## 3c. Constraints / joints
Connect two bodies (one may be `STATIC` to anchor to the world). Each returns a
`Jolt::Constraint`; call `joint.remove` to detach (also done on GC).
```ruby
world.weld(a, b)                       # fixed: rigid weld at current relative pose
world.ball_joint(a, b, point)          # point-to-point (free rotation about a world point)
world.distance_joint(a, b, pa, pb, min: 0, max: 2.0)   # rope/rod between two world points
world.hinge(a, b, point, axis, min_deg: -90, max_deg: 90)  # door (rotate about axis)
world.slider(a, b, point, axis, min: -2, max: 2)       # piston (slide along axis)
world.cone(a, b, point, axis, half_angle_deg: 30)      # swing/twist limit about axis
```
`point`/`axis` are world-space (`Array` or `Rl::Vector3`); hinge limits in degrees,
slider limits in metres.
> The **world retains** every constraint it creates, so a joint stays alive even
> if you don't keep the returned handle — call `joint.remove` to delete it (which
> also drops the world's reference). Likewise for ragdolls (§4b).

## 3b. Character controller
A `Jolt::Character` is a kinematic capsule (Jolt `CharacterVirtual`) for players:
precise control, **stair-stepping** (up to ~0.4 m), slope handling, and ground
detection. It is not a rigid body — you set its velocity each frame (applying
gravity/jump yourself) and call `update`, which moves and slides it along the world.
```ruby
char = world.character(shape: Jolt.capsule(0.6, 0.3), position: [0, 2, 0],
                       max_slope_deg: 45, mass: 70)

# canonical per-frame loop
dt = Rl.frame_time
v  = char.velocity
vy = char.on_ground? ? (jump? ? 6.0 : 0.0) : v.y - 20.0 * dt   # gravity / jump
char.velocity = [input_x * speed, vy, input_z * speed]
char.update(dt)         # moves + collides + steps stairs + sticks to floor
world.step(dt)

char.position        # -> Rl::Vector3      ; char.position = [x,y,z]
char.velocity        # -> Rl::Vector3
char.on_ground?      # standing on walkable ground?
char.ground_state    # :on_ground | :on_steep | :not_supported | :in_air
char.ground_normal   # -> Rl::Vector3
char.supported?      # touching anything that supports it?
char.max_strength    # max force (N) it exerts on dynamic bodies it walks into
char.max_strength = 6000   # raise above the 100 N default to push heavy props
char.mass = 200            # effective mass vs. dynamic bodies (still kinematic to gravity)

# --- riding moving platforms ---
char.ground_velocity # -> Rl::Vector3: velocity of the surface underfoot (0 if airborne)
char.ground_body     # -> Jolt::Body the character stands on, or nil when airborne
char.ride(dt)        # like update(dt), but first ADDS ground_velocity to your own
                     # velocity, so a KINEMATIC platform/elevator carries the player
```
> `ride` only inherits the velocity of a **STATIC/KINEMATIC** ground body. A
> DYNAMIC ground body (a ball you stand on, a constrained pendulum) reports its
> *reaction to your weight* (and its own bounce/swing) as `ground_velocity` —
> inheriting that would fling the character — so dynamic ground is ignored and you
> simply stand/collide on it. (`ground_velocity` itself still returns the raw value.)
A moving platform is just a `KINEMATIC` body you drive each frame; `ride` makes
the character inherit its motion instead of being left behind:
```ruby
plat = world.body(shape: Jolt.box(4, 0.5, 4), position: [0,0,0], motion: Jolt::KINEMATIC)
# each frame:
plat.linear_velocity = [vx, 0, 0]            # feeds the character's ground_velocity
char.velocity = [input_x*5, vy, input_z*5]   # your own movement + gravity/jump
char.ride(dt)                                # inherits the platform's velocity
world.step(dt)
plat.set_transform(position: next_xyz)       # pin the kinematic body (anti-drift)
```
> By default the character can push the dynamic bodies it walks into, but the Jolt
> default `maxStrength` (100 N) is too weak to shove default-density props
> (density 1000 kg/m³ — a 0.5 m sphere is ~520 kg). Raise `max_strength` when you
> want the player to bowl props around; raise `mass` to make props shove the
> player less.
> The character keeps its `world` alive (GC) for its lifetime. `update` uses
> Jolt's `ExtendedUpdate` (stair-step height 0.4 m, stick-to-floor). It collides
> with static + dynamic bodies but is itself kinematic (infinite mass): it stops
> at obstacles rather than being pushed.

## 4. Queries
```ruby
hit = world.raycast(origin, direction)   # direction is the full ray vector
if hit
  hit.body_id      # the hit body's id      ;  hit.body -> Jolt::Body
  hit.fraction     # 0..1 along the ray
  hit.point        # -> Rl::Vector3 (world-space hit point)
  hit.normal       # -> Rl::Vector3 (world-space surface normal at the hit)
end

# which bodies contain a point? (overlap test) -> Array<Jolt::Body>
world.overlap_point([x, y, z]).each { |b| ... }
```

## 4b. Ragdolls
A ragdoll is a tree of dynamic bodies (one per skeleton joint) wired with
**swing-twist** constraints (a cone swing limit + a twist range), so a humanoid
collapses believably. Build it from an Array of part Hashes, **parents before
children** (skeleton order). Each part's body is a normal `Jolt::Body`.
```ruby
rd = world.ragdoll(parts: [
  # the single root has no :parent
  { name: :torso, shape: Jolt.capsule(0.22, 0.16), position: [0, 4.0, 0], mass: 20 },
  { name: :head,  shape: Jolt.sphere(0.16), position: [0, 4.45, 0], parent: :torso,
    joint: [0, 4.24, 0],            # world-space pivot connecting to the parent
    twist_axis: [0,1,0], plane_axis: [1,0,0],  # bone axis + a perpendicular
    cone_deg: 25, plane_deg: 25,    # swing limits (normal/plane half-cone)
    twist_min_deg: -25, twist_max_deg: 25 },
  { name: :lleg,  shape: Jolt.capsule(0.20, 0.085), position: [-0.1, 3.4, 0], parent: :torso,
    joint: [-0.1, 3.78, 0], cone_deg: 40, twist_min_deg: -10, twist_max_deg: 10, mass: 5 },
], user_data: 0)

rd.body_count        # number of parts
rd.bodies            # -> Array<Jolt::Body> in part order (read .position/.rotation to draw)
rd[0]                # bodies[0] (the root)
rd.activate          # wake all parts (e.g. before applying an impulse)
rd.bodies.each { |b| b.apply_impulse([fx, fy, fz]) }   # fling it
rd.remove            # take it out of the world (also done on GC)
```
Per part — required: `name:`, `shape:`, `position:`. Optional: `rotation:`
(quaternion, default identity), `mass:` (kg, else shape-derived), `motion:`
(default `DYNAMIC`), and for non-root parts the joint to the parent: `parent:`,
`joint:` (default = `position`), `twist_axis:` (default `[0,1,0]`), `plane_axis:`
(default `[1,0,0]`), `cone_deg:`/`plane_deg:` (default 45), `twist_min_deg:`/
`twist_max_deg:` (default ±45).
> Adjacent parts don't collide with each other (Jolt
> `DisableParentChildCollisions`); the ragdoll collides with the rest of the
> world on the `MOVING` layer. The ragdoll keeps its `world` alive (GC).
> Capsule parts: their local axis is **Y** — render the two endpoints with
> `Rl.vector3_rotate_by_quaternion([0, half_height, 0], body.rotation)`.

## 5. Worked example (bouncing balls over raylib)
```ruby
world = Jolt::World.new(gravity: [0, -9.81, 0])
ground = world.body(shape: Jolt.box(50, 1, 50), position: [0, -0.5, 0],
                    motion: Jolt::STATIC)
balls = (0...20).map do |i|
  world.body(shape: Jolt.sphere(0.5), position: [i - 10, 8, 0], restitution: 0.6)
end
world.optimize_broad_phase

Rl.init_window(960, 540, "physics")
cam = Rl::Camera3D.new(Rl::Vector3.new(0, 8, 20), Rl::Vector3.new(0, 2, 0),
                       Rl::Vector3.new(0, 1, 0), 45, Rl::CAMERA_PERSPECTIVE)
Rl.while_window_open do
  world.step(Rl.frame_time)
  Rl.draw(clear_color: Rl::RAYWHITE) do
    Rl.begin_mode3d(cam)
    balls.each { |b| p = b.position; Rl.draw_sphere(p, 0.5, Rl::RED) }
    Rl.draw_grid(20, 1)
    Rl.end_mode3d
  end
end
```

---

## 6. Determinism
Off by default. Jolt is deterministic given the same binary + inputs; for
*cross-platform* determinism (replays/netcode) rebuild the joltc/Jolt CMake with
`-DCROSS_PLATFORM_DETERMINISTIC=ON` (small perf cost). No API change.

## 7. Build / web
joltc + Jolt (v5.5.0) are vendored and compiled to a single merged
`libjoltphysics.a` (CMake; `-DINTERPROCEDURAL_OPTIMIZATION=OFF` because zig's lld
can't link GCC-LTO objects — see `.agents/knowledge/jolt-binding.md`). Adds
~1.14 MB to `game.wasm` (~300-400 KB gzipped). Single-threaded, so wasm works
unchanged.

## 8. Not yet exposed
Shape-cast / shape-overlap queries (sweep/overlap an arbitrary shape),
height-field & compound shapes, vehicles, soft bodies, ragdoll pose/motor driving
(animated → physical blending; the bodies + joints are exposed, but not
`DriveToPose`), custom collision layers, multithreading. The joltc C API supports
all of these — bind as needed. Also a first-cut leak: shapes and per-world
layer-filter tables aren't freed (bounded; both are long-lived).
