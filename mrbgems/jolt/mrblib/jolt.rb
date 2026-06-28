# Idiomatic Ruby surface for Jolt Physics (3D), layered on the low-level
# Jolt::World#_* primitives (see src/jolt_bindings.c). Vectors accept Arrays or
# Rl::Vector3/Vector4 and are returned as Rl::Vector3/Vector4 when raylib is
# present (else plain Arrays).
#
#   world = Jolt::World.new(gravity: [0, -9.81, 0])
#   floor = world.body(shape: Jolt.box(100, 1, 100), position: [0, -0.5, 0], motion: Jolt::STATIC)
#   ball  = world.body(shape: Jolt.sphere(0.5), position: [0, 10, 0], velocity: [0, 0, 0])
#   loop { world.step(1.0/60); puts ball.position.y }

module Jolt
  class << self
    # --- shape factories ---
    def box(width, height, depth)        # full dimensions (converted to half-extents)
      _box(width * 0.5, height * 0.5, depth * 0.5)
    end
    def sphere(radius)                    = _sphere(radius)
    def capsule(half_height, radius)      = _capsule(half_height, radius) # cylinder half-height
    def cylinder(half_height, radius)     = _cylinder(half_height, radius)
    # convex hull from points (Array of [x,y,z] or a flat float Array)
    def convex_hull(points) = _convex_hull(points.first.is_a?(Array) ? points.flatten : points)
    # triangle mesh for STATIC bodies (Array of [x,y,z] triples, or flat; 3 verts/tri)
    def mesh(vertices)      = _mesh(vertices.first.is_a?(Array) ? vertices.flatten : vertices)

    # --- vector coercion (Array | Rl::Vector3/4 -> [floats]); out -> Rl type ---
    def v3(v) = v.is_a?(Array) ? [v[0].to_f, v[1].to_f, v[2].to_f] : [v.x.to_f, v.y.to_f, v.z.to_f]
    def v4(v) = v.is_a?(Array) ? [v[0].to_f, v[1].to_f, v[2].to_f, v[3].to_f] : [v.x.to_f, v.y.to_f, v.z.to_f, v.w.to_f]
    # Return Rl::Vector3/4 when raylib is present, else a plain Array. The check
    # is memoized lazily so gem load order doesn't matter.
    def rl?
      @rl = (Object.const_defined?(:Rl) && Rl.const_defined?(:Vector3)) if @rl.nil?
      @rl
    end
    def out3(a) = rl? ? Rl::Vector3.new(a[0], a[1], a[2]) : a
    def out4(a) = rl? ? Rl::Vector4.new(a[0], a[1], a[2], a[3]) : a
  end

  class World
    def initialize(gravity: [0.0, -9.81, 0.0], max_bodies: 10240)
      g = Jolt.v3(gravity)
      # The world OWNS its constraints/ragdolls: keep Ruby refs so they aren't
      # garbage-collected (a Constraint/Ragdoll finalizer detaches it from the
      # simulation, so a dropped handle would silently break the joint). They are
      # released on #remove or when the world itself is collected.
      @joints   = []
      @ragdolls = []
      _setup(g[0], g[1], g[2], max_bodies)
    end

    def _retain_joint(c);   @joints   << c; c; end   # internal
    def _forget_joint(c);   @joints.delete(c);  end   # internal (called by #remove)
    def _forget_ragdoll(r); @ragdolls.delete(r); end  # internal

    def gravity=(v); g = Jolt.v3(v); _set_gravity(g[0], g[1], g[2]); v; end
    def step(dt = 1.0 / 60.0, collision_steps: 1); _step(dt, collision_steps); self; end
    alias update step
    def optimize_broad_phase; _optimize; self; end

    # Create + add a body. shape: a Jolt::Shape; motion: Jolt::STATIC/DYNAMIC/KINEMATIC.
    def body(shape:, position: [0, 0, 0], rotation: [0, 0, 0, 1], motion: Jolt::DYNAMIC,
             restitution: 0.0, friction: 0.2, activate: true, velocity: nil, user_data: nil,
             linear_damping: 0.05, angular_damping: 0.05, mass: nil, ccd: false, sensor: false)
      p = Jolt.v3(position); q = Jolt.v4(rotation)
      id = _add_body(shape, p[0], p[1], p[2], q[0], q[1], q[2], q[3],
                     motion.to_i, restitution.to_f, friction.to_f, activate,
                     linear_damping.to_f, angular_damping.to_f, (mass || 0.0).to_f,
                     ccd ? true : false, sensor ? true : false)
      b = Body.new(self, id)
      b.user_data = user_data if user_data
      b.linear_velocity = velocity if velocity
      b
    end
    alias add_body body

    # Bodies whose shape contains `point` -> Array<Jolt::Body> (overlap query).
    def overlap_point(point)
      p = Jolt.v3(point)
      _overlap_point(p[0], p[1], p[2]).map { |id| Body.new(self, id) }
    end

    # Contacts that ENDED (stopped touching) this step -> Array<Jolt::ContactEnd>.
    # Pair with sensor bodies for trigger enter (contacts) / leave (contacts_ended).
    def contacts_ended
      _contacts_ended.map { |a, b| ContactEnd.new(self, a, b) }
    end

    # --- constraints / joints (return Jolt::Constraint; call #remove to delete) ---
    # The world retains each one (see initialize) so it survives GC; #remove drops it.
    # weld two bodies rigidly at their current relative transform
    def weld(a, b) = _retain_joint(_fixed(a.to_i, b.to_i))
    # ball / point joint at a world-space point (free rotation, fixed point)
    def ball_joint(a, b, point)
      p = Jolt.v3(point); _retain_joint(_point(a.to_i, b.to_i, p[0], p[1], p[2]))
    end
    # keep two world-space attach points within [min, max] metres (rope/rod)
    def distance_joint(a, b, point_a, point_b, min: 0.0, max: nil)
      pa = Jolt.v3(point_a); pb = Jolt.v3(point_b)
      d = max || Math.sqrt((pa[0]-pb[0])**2 + (pa[1]-pb[1])**2 + (pa[2]-pb[2])**2)
      _retain_joint(_distance(a.to_i, b.to_i, pa[0], pa[1], pa[2], pb[0], pb[1], pb[2], min.to_f, d.to_f))
    end
    # hinge (door) about `axis` through world `point`; angle limits in DEGREES
    def hinge(a, b, point, axis, min_deg: -180.0, max_deg: 180.0)
      p = Jolt.v3(point); ax = Jolt.v3(axis)
      _retain_joint(_hinge(a.to_i, b.to_i, p[0], p[1], p[2], ax[0], ax[1], ax[2],
             min_deg * Math::PI / 180.0, max_deg * Math::PI / 180.0))
    end
    # slider (piston) along `axis` through world `point`; limits in METRES
    def slider(a, b, point, axis, min: -1.0e10, max: 1.0e10)
      p = Jolt.v3(point); ax = Jolt.v3(axis)
      _retain_joint(_slider(a.to_i, b.to_i, p[0], p[1], p[2], ax[0], ax[1], ax[2], min.to_f, max.to_f))
    end
    # cone / swing limit about `axis` through world `point`; half-angle in DEGREES
    def cone(a, b, point, axis, half_angle_deg: 45.0)
      p = Jolt.v3(point); ax = Jolt.v3(axis)
      _retain_joint(_cone(a.to_i, b.to_i, p[0], p[1], p[2], ax[0], ax[1], ax[2],
            half_angle_deg * Math::PI / 180.0))
    end

    # Contacts that BEGAN during the last step -> Array<Jolt::Contact>.
    # (Use a body's user_data to map ids back to your game objects.)
    def contacts
      _contacts.map do |a, b, px, py, pz, nx, ny, nz|
        Contact.new(self, a, b, Jolt.out3([px, py, pz]), Jolt.out3([nx, ny, nz]))
      end
    end

    # Create a kinematic character controller (player capsule with stair/slope
    # handling) -> Jolt::Character. `shape` is typically a Jolt.capsule.
    def character(shape:, position: [0, 0, 0], max_slope_deg: 45.0, mass: 70.0)
      p = Jolt.v3(position)
      _character(shape, p[0], p[1], p[2], max_slope_deg.to_f, mass.to_f)
    end

    # Build a ragdoll: a tree of dynamic bodies joined by swing-twist (cone +
    # twist) constraints -> Jolt::Ragdoll. `parts` is an Array of Hashes, listed
    # PARENTS BEFORE CHILDREN (skeleton order). Each part:
    #   name:        unique String/Symbol (referenced by children's :parent)
    #   shape:       a Jolt.capsule/box/sphere
    #   position:, rotation:  world transform of the body (rotation default identity)
    #   parent:      name of the parent part (omit/nil for the single root)
    #   joint:       world-space pivot connecting to the parent (default: position)
    #   twist_axis:  bone axis (default [0,1,0]); plane_axis: perpendicular ([1,0,0])
    #   cone_deg:, plane_deg:  swing limits; twist_min_deg:, twist_max_deg:  twist range
    #   mass:        kg (default: derived from shape); motion: (default DYNAMIC)
    def ragdoll(parts:, user_data: 0)
      names = parts.map { |p| (p[:name] || p["name"]).to_s }
      packed = parts.map do |p|
        pname  = (p[:name] || p["name"]).to_s
        parent = p[:parent] ? names.index(p[:parent].to_s) : -1
        raise ArgumentError, "ragdoll part #{pname.inspect} has unknown parent #{p[:parent].inspect}" \
          if p[:parent] && parent.nil?
        pos   = Jolt.v3(p[:position] || [0, 0, 0])
        rot   = Jolt.v4(p[:rotation] || [0, 0, 0, 1])
        joint = Jolt.v3(p[:joint] || p[:position] || [0, 0, 0])
        twist = Jolt.v3(p[:twist_axis] || [0, 1, 0])
        plane = Jolt.v3(p[:plane_axis] || [1, 0, 0])
        [pname, parent.to_i, p[:shape],
         pos[0], pos[1], pos[2], rot[0], rot[1], rot[2], rot[3],
         (p[:motion] || Jolt::DYNAMIC).to_i, (p[:mass] || 0.0).to_f,
         joint[0], joint[1], joint[2], twist[0], twist[1], twist[2], plane[0], plane[1], plane[2],
         (p[:cone_deg]  || 45.0) * Math::PI / 180.0, (p[:plane_deg] || 45.0) * Math::PI / 180.0,
         (p[:twist_min_deg] || -45.0) * Math::PI / 180.0, (p[:twist_max_deg] || 45.0) * Math::PI / 180.0]
      end
      r = _ragdoll(packed, user_data.to_i)
      @ragdolls << r   # retain so it isn't GC'd out of the world (see initialize)
      r
    end

    # Cast a ray (direction is the full ray vector). -> Jolt::RayHit | nil.
    def raycast(origin, direction)
      o = Jolt.v3(origin); d = Jolt.v3(direction)
      r = _raycast(o[0], o[1], o[2], d[0], d[1], d[2])
      r && RayHit.new(self, r[0], r[1], Jolt.out3(r[2..4]), Jolt.out3(r[5..7]))
    end
  end

  # A rigid body: a body id bound to its world.
  class Body
    attr_reader :id, :world
    def initialize(world, id); @world = world; @id = id; end
    def to_i; @id; end
    def to_int; @id; end

    def position;        Jolt.out3(@world._position(@id)); end
    def center_of_mass;  Jolt.out3(@world._com_position(@id)); end
    def rotation;        Jolt.out4(@world._rotation(@id)); end
    def position=(v); set_transform(position: v); v; end

    def set_transform(position:, rotation: nil, activate: true)
      p = Jolt.v3(position)
      q = rotation ? Jolt.v4(rotation) : @world._rotation(@id)
      @world._set_transform(@id, p[0], p[1], p[2], q[0], q[1], q[2], q[3], activate); self
    end

    def linear_velocity;  Jolt.out3(@world._linear_velocity(@id)); end
    def angular_velocity; Jolt.out3(@world._angular_velocity(@id)); end
    def linear_velocity=(v);  a = Jolt.v3(v); @world._set_linear_velocity(@id, a[0], a[1], a[2]); v; end
    def angular_velocity=(v); a = Jolt.v3(v); @world._set_angular_velocity(@id, a[0], a[1], a[2]); v; end

    def apply_force(v);   a = Jolt.v3(v); @world._add_force(@id, a[0], a[1], a[2]); self; end
    def apply_impulse(v); a = Jolt.v3(v); @world._add_impulse(@id, a[0], a[1], a[2]); self; end
    def apply_torque(v);  a = Jolt.v3(v); @world._add_torque(@id, a[0], a[1], a[2]); self; end

    def active?;     @world._active?(@id); end
    def activate;    @world._activate(@id); self; end
    def deactivate;  @world._deactivate(@id); self; end
    def remove;      @world._remove_body(@id); end

    # arbitrary 64-bit tag (e.g. a flecs entity id or object id) for collision lookup
    def user_data;     @world._user_data(@id); end
    def user_data=(v); @world._set_user_data(@id, v.to_i); v; end

    def motion_type;     @world._motion_type(@id); end
    def motion_type=(mt); @world._set_motion_type(@id, mt.to_i, true); mt; end
    def set_motion_type(mt, activate: true); @world._set_motion_type(@id, mt.to_i, activate); self; end

    def friction;        @world._friction(@id); end
    def friction=(v);    @world._set_friction(@id, v.to_f); v; end
    def restitution;     @world._restitution(@id); end
    def restitution=(v); @world._set_restitution(@id, v.to_f); v; end
    def gravity_factor;     @world._gravity_factor(@id); end
    def gravity_factor=(v); @world._set_gravity_factor(@id, v.to_f); v; end
    # sensor: detects overlaps (contacts/contacts_ended) without a physical response
    def sensor=(v); @world._set_sensor(@id, v ? true : false); v; end
    # continuous collision detection (linear cast) — for fast bodies vs thin walls
    def ccd=(v);    @world._set_ccd(@id, v ? true : false); v; end

    def ==(other); other.respond_to?(:to_i) && other.to_i == @id; end
    def inspect; "#<Jolt::Body #{@id}>"; end
  end

  # Result of World#raycast.
  class RayHit
    attr_reader :body_id, :fraction, :point, :normal
    def initialize(world, body_id, fraction, point, normal = nil)
      @world = world; @body_id = body_id; @fraction = fraction
      @point = point; @normal = normal
    end
    def body; Body.new(@world, @body_id); end
  end

  # A constraint/joint (World#weld/ball_joint/distance_joint/hinge/slider/cone).
  # The world retains it; you don't need to hold the handle to keep the joint alive.
  class Constraint
    def remove                       # detach + destroy now (also done on GC)
      _remove
      w = instance_variable_get(:@world)
      w._forget_joint(self) if w
      self
    end
  end

  # A collision that ENDED this step (from World#contacts_ended). No point/normal.
  class ContactEnd
    attr_reader :body_a_id, :body_b_id
    def initialize(world, a, b); @world = world; @body_a_id = a; @body_b_id = b; end
    def body_a; Body.new(@world, @body_a_id); end
    def body_b; Body.new(@world, @body_b_id); end
    def involves?(x); i = x.to_i; @body_a_id == i || @body_b_id == i; end
    def other(x); i = x.to_i; @body_a_id == i ? body_b : body_a; end
  end

  # Kinematic character controller (Jolt CharacterVirtual). You set its velocity
  # each frame (applying gravity/jump yourself) and call update(dt); it moves and
  # slides along the world, stepping stairs and handling slopes.
  #
  #   ch = world.character(shape: Jolt.capsule(0.6, 0.3), position: [0, 2, 0])
  #   loop do
  #     v = ch.velocity
  #     vy = ch.on_ground? ? (jump? ? 6.0 : 0.0) : v.y - 20.0 * dt
  #     ch.velocity = [input_x * 5, vy, input_z * 5]
  #     ch.update(dt)
  #     world.step(dt)
  #   end
  class Character
    GROUND = { 0 => :on_ground, 1 => :on_steep, 2 => :not_supported, 3 => :in_air }.freeze

    def update(dt = 1.0 / 60.0); _update(dt); self; end
    def position;     Jolt.out3(_position); end
    def position=(v); a = Jolt.v3(v); _set_position(a[0], a[1], a[2]); v; end
    def velocity;     Jolt.out3(_velocity); end
    def velocity=(v); a = Jolt.v3(v); _set_velocity(a[0], a[1], a[2]); v; end

    def ground_state;  GROUND[_ground_state]; end   # :on_ground|:on_steep|:not_supported|:in_air
    def on_ground?;    _ground_state == 0; end
    def supported?;    _supported?; end
    def ground_normal; Jolt.out3(_ground_normal); end

    # Velocity of the surface under the character (moving platform / elevator);
    # zero when airborne. Add it to your movement so the character rides along.
    def ground_velocity; Jolt.out3(_ground_velocity); end
    # The body the character is standing on, or nil when airborne.
    def ground_body
      return nil unless supported?
      Body.new(@world, _ground_body_id)
    end

    # Move with the platform under your feet, then update. Pass your own desired
    # horizontal/vertical velocity (gravity/jump applied by you); the platform's
    # velocity is added on top so the character isn't left behind.
    #   ch.velocity = [input_x*5, vy, input_z*5]
    #   ch.ride(dt)
    #
    # Only a STATIC/KINEMATIC platform's velocity is inherited. A DYNAMIC ground
    # body (a ball you stand on, a constrained pendulum) reports its REACTION to
    # your own weight (and its own bouncing/swinging) as ground_velocity —
    # inheriting that launches the character — so dynamic ground is ignored here
    # and you just stand/collide on it normally.
    def ride(dt = 1.0 / 60.0)
      gb = ground_body
      if gb && gb.motion_type != Jolt::DYNAMIC
        v = velocity; gv = ground_velocity
        self.velocity = [v.x + gv.x, v.y + gv.y, v.z + gv.z]
      end
      _update(dt)
      self
    end

    # Max force (N) the character exerts on dynamic bodies it walks into. Raise
    # it above the Jolt default (100 N) to push heavier props around.
    def max_strength;      _max_strength; end
    def max_strength=(v);  _set_max_strength(v.to_f); v; end
    # Effective mass when dynamic bodies collide with the character (still
    # kinematic to gravity); higher = harder for props to shove the player.
    def mass=(v);          _set_mass(v.to_f); v; end
  end

  # A ragdoll: a tree of dynamic bodies wired with swing-twist joints (from
  # World#ragdoll). Each body is a normal Jolt::Body — read position/rotation to
  # render, apply impulses to fling it around.
  #
  #   rd = world.ragdoll(parts: [
  #     { name: :torso, shape: Jolt.capsule(0.25, 0.18), position: [0, 4.0, 0] },
  #     { name: :head,  shape: Jolt.sphere(0.16), position: [0, 4.5, 0], parent: :torso,
  #       joint: [0, 4.32, 0], twist_axis: [0,1,0], cone_deg: 25, twist_min_deg: -20, twist_max_deg: 20 },
  #   ])
  #   rd.bodies.each { |b| draw_capsule(b.position, b.rotation) }
  class Ragdoll
    # Array<Jolt::Body>, one per part, in skeleton order (memoized).
    def bodies; @bodies ||= (0...body_count).map { |i| Body.new(@world, _body_id(i)) }; end
    def body_count; _body_count; end
    def [](i); bodies[i]; end
    def activate; _activate; self; end   # wake all parts
    def remove                           # take out of the world (also on GC)
      _remove
      w = instance_variable_get(:@world)
      w._forget_ragdoll(self) if w
      self
    end
  end

  # A collision that began this step (from World#contacts).
  class Contact
    attr_reader :body_a_id, :body_b_id, :point, :normal
    def initialize(world, a, b, point, normal)
      @world = world; @body_a_id = a; @body_b_id = b; @point = point; @normal = normal
    end
    def body_a; Body.new(@world, @body_a_id); end
    def body_b; Body.new(@world, @body_b_id); end
    def involves?(x); i = x.to_i; @body_a_id == i || @body_b_id == i; end
    def other(x); i = x.to_i; @body_a_id == i ? body_b : body_a; end
  end
end
