#!/usr/bin/env ruby
# Generates docs/AI_REFERENCE.md — a single, dense, self-contained description of
# the ENTIRE Ruby API (raylib + raymath + RmlUi) for an LLM to consume without
# reading any source. Every call carries argument + return TYPES; every struct,
# enum value, and constant is listed; unbound functions are listed explicitly so
# the model does not invent them.
#
#   ruby gen_ai_reference.rb
require 'json'

ROOT   = File.expand_path('../../..', __dir__)
RAYLIB = File.join(ROOT, 'vendor', 'raylib')
GEN_C  = File.join(__dir__, '..', 'src', 'raylib_gen.c')
OUT    = File.join(ROOT, 'docs', 'AI_REFERENCE.md')

# raylib 6.0 relocated the parser: parser/output/ -> tools/rlparser/output/.
# Load a raylib API json, tolerating a known raylib 6.0 bug: the
# LoadDirectoryFilesEx description contains literal unescaped double-quotes
# ("*.*", "FILES*", "DIRS*") that break strict JSON. Escape + retry. (Kept in
# sync with gen_raylib.rb's load_api.)
def load_api(path)
  raw = File.read(path)
  return JSON.parse(raw) rescue JSON.parse(raw
    .gsub('"*.*"', '\"*.*\"')
    .gsub('"FILES*"', '\"FILES*\"')
    .gsub('"DIRS*"', '\"DIRS*\"'))
end

API    = load_api(File.join(RAYLIB, 'tools/rlparser/output/raylib_api.json'))
RMATH  = load_api(File.join(RAYLIB, 'tools/rlparser/output/raymath_api.json'))

ALIASES = API['aliases'].to_h { |a| [a['name'], a['type']] }
STRUCTS = API['structs'].map { |s| s['name'] }.to_h { |n| [n, true] }

def snake(n)
  n.gsub(/(\d)([A-Z][a-z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
   .gsub(/([a-z])([A-Z])/, '\1_\2').downcase
end
def ruby_method(n) = n =~ /\AIs([A-Z].*)\z/ ? snake($1) + '?' : snake(n)
def base_struct(t)
  b = t.gsub('const', '').gsub('*', '').strip
  b = ALIASES[b] || b
  STRUCTS[b] ? b : nil
end
# Ruby type label for a C type, or nil if void / unsupported.
def rtype(t)
  s = t.strip
  return nil       if s == 'void'
  return 'Boolean' if s == 'bool'
  return 'Float'   if s == 'float' || s == 'double'
  return 'String'  if s == 'const char *' || s == 'char *'
  if (b = base_struct(s)) then return "Rl::#{b}" end
  return 'Integer' unless s.include?('*')
  nil
end

# --- bound vs unbound (parse skip list from generated raylib_gen.c) ---
skip_reason = {}
if File.exist?(GEN_C) && File.read(GEN_C, 4096) =~ /Skipped \(\d+\):\s*(.*?)\*\//m
  $1.split(';').each do |e|
    e = e.strip
    if e =~ /\A([A-Za-z_]\w*)\s*\((.*)\)/ then skip_reason[$1] = $2 end
  end
end
skip_reason.delete('SetShaderValue'); skip_reason.delete('SetShaderValueV') # hand-bound

# Fully-typed signatures we write by hand (generic marshaller can't express them)
SPECIAL = {
  'SetShaderValue'  => 'Rl.set_shader_value(shader:Rl::Shader, loc_index:Integer, value:Numeric|Array, uniform_type:Integer)  # value packed per SHADER_UNIFORM_* type',
  'SetShaderValueV' => 'Rl.set_shader_value_v(shader:Rl::Shader, loc_index:Integer, value:Array, uniform_type:Integer, count:Integer)',
}

def sig(fn)
  return SPECIAL[fn['name']] if SPECIAL[fn['name']]
  args = (fn['params'] || []).map { |p| "#{snake(p['name'])}:#{rtype(p['type']) || p['type']}" }
  s = +"Rl.#{ruby_method(fn['name'])}"
  s << "(#{args.join(', ')})" unless args.empty?
  r = rtype(fn['returnType']); s << " -> #{r}" if r
  d = fn['description'].to_s.strip
  d.empty? ? s : "#{s}  # #{d}"
end

# module grouping from (Module: xxx) tags in raylib.h
MOD_ALIAS = { 'rgestures' => 'core', 'rcamera' => 'core' }
def sections(path, macro, re, default)
  map = {}; mod = default
  File.foreach(path) do |raw|
    l = raw.chomp
    if l =~ re
      cap = $1; next if cap =~ /\ANOTE\b/i
      mod = (cap =~ /\(Module:\s*([a-z]+)\)/) ? (MOD_ALIAS[$1] || $1) : mod
    elsif l =~ /\A#{macro}\b.*?\s\*?([A-Za-z_]\w*)\s*\(/
      map[$1] = mod
    end
  end
  map
end
RL_MOD = sections(File.join(RAYLIB, 'src/raylib.h'), 'RLAPI', %r{\A//\s*(.*?functions.*)\z}i, 'core')

# ---------------------------------------------------------------------------
o = +""
o << <<~HEAD
  # raylib-jamstack — complete API reference (for AI agents)

  Single-file description of the **entire** Ruby (mruby) API of this stack:
  raylib 6.0 + raymath + RmlUi 6.x + flecs 4 (ECS) + Jolt 5 (3D physics). Everything an agent needs to write correct
  game code without reading the bindings source. Auto-generated from
  `raylib_api.json` / `raymath_api.json` by `mrbgems/raylib/tools/gen_ai_reference.rb`.

  ## Conventions (read first)
  - C `PascalCase` -> Ruby `snake_case`. `IsXxx(...)` -> `xxx?` predicate.
  - All raylib structs are classes under `Rl::` with a **positional** constructor
    in field order and `obj.field` / `obj.field=` accessors (see Structs).
  - Enum values and color/numeric `#define`s are constants under `Rl::`
    (e.g. `Rl::KEY_SPACE`, `Rl::MOUSE_BUTTON_LEFT`, `Rl::GOLD`, `Rl::PI`).
  - Signatures below are `Rl.name(arg:Type, ...) -> ReturnType`. **No `-> ` means
    the call returns `nil`.** `Boolean` = true/false. Struct types are `Rl::X`.
  - A struct passed where C takes a single `T*` is **in/out**: pass an `Rl::T`
    instance; the call may mutate it.
  - String args accept `nil` (becomes C `NULL`), e.g.
    `Rl.load_shader_from_memory(nil, fs)` for the default vertex shader.
  - Symbol keys work anywhere a keycode is expected via the input predicates:
    `:a`..`:z`, `:0`..`:9`, `:space :enter :escape :tab :backspace :up :down
    :left :right :left_shift :left_control` — or use `Rl::KEY_*` ints.
  - There is no global state you must thread; raylib is a global singleton.

  ## Idiomatic helpers (defined in Ruby, not 1:1 C)
  ```ruby
  Rl.while_window_open { ... }          # the ONLY main loop. web-safe (emscripten
                                        # main loop on web; `until close?` on desktop,
                                        # auto-calls close_window on desktop exit).
  Rl.draw(clear_color: Rl::RAYWHITE) { ... }   # begin_drawing+clear+end_drawing (ensure)
  Rl.mode_2d(camera) { ... }            # begin/end_mode2d            (exception-safe)
  Rl.mode_3d(camera) { ... }            # begin/end_mode3d
  Rl.texture_mode(render_texture) { ... }
  Rl.blend_mode(mode) { ... }           # mode = Rl::BLEND_*
  Rl.shader_mode(shader) { ... }
  Rl.scissor_mode(x:, y:, width:, height:) { ... }
  Rl.draw_text(text:, x:, y:, font_size:, color:)               # kwarg form
  Rl.draw_texture_pro(texture:, source:, dest:, origin: Rl::Vector2.new(0,0),
                      rotation: 0, tint: Rl::WHITE)              # kwarg form
  Rl.platform  # :web|:desktop ;  Rl.web? ;  Rl.desktop?
  # aliases: Rl.target_fps= , Rl.master_volume= , Rl.frame_time, Rl.time, Rl.fps,
  #          Rl.screen_width, Rl.screen_height, Rl.mouse_x, Rl.mouse_y,
  #          Rl.mouse_position, Rl.mouse_wheel
  ```
  NOTE: `draw_text` and `draw_texture_pro` are the keyword forms above (they
  override the positional generated versions). All other calls are positional.

  ## Minimal program
  ```ruby
  Rl.init_window(800, 450, "demo")
  Rl.target_fps = 60
  Rl.while_window_open do
    Rl.draw(clear_color: Rl::RAYWHITE) do
      Rl.draw_text(text: "hello", x: 20, y: 20, font_size: 20, color: Rl::DARKGRAY)
      Rl.draw_circle_v(Rl.mouse_position, 16, Rl::RED) if Rl.mouse_button_down?(Rl::MOUSE_BUTTON_LEFT)
    end
  end
  ```
HEAD

# --- functions by module ---
o << "\n## raylib functions (by module)\n"
%w[core shapes textures text models audio].each do |mod|
  fns = API['functions'].reject { |f| skip_reason[f['name']] }
                        .select { |f| (RL_MOD[f['name']] || 'core') == mod }
  next if fns.empty?
  o << "\n### #{mod}\n```ruby\n"
  fns.each { |f| o << sig(f) << "\n" }
  o << "```\n"
end

o << "\n## raymath functions\n```ruby\n"
RMATH['functions'].reject { |f| skip_reason[f['name']] }.each { |f| o << sig(f) << "\n" }
o << "```\n"

# --- structs (typed constructor + accessors) ---
o << "\n## Structs\n"
o << "Constructor args are positional in the order shown; every listed field has\n"
o << "`obj.field` (read) and `obj.field=` (write). Pointer/array fields (if any)\n"
o << "are omitted (not accessible).\n```ruby\n"
API['structs'].each do |st|
  fields = st['fields'].map { |f| [f['name'], rtype(f['type'])] }.select { |_, t| t }
  args = fields.map { |n, t| "#{n}:#{t}" }.join(', ')
  o << "Rl::#{st['name']}.new(#{args})".ljust(0) << "  # #{st['description']}\n"
end
o << "```\n"
o << "Aliases (same class): " << API['aliases'].map { |a| "#{a['name'].to_s.sub(/\A\*/, '')}=#{a['type']}" }.join(', ') << "\n"

# --- enums ---
o << "\n## Enums (constants under Rl::)\n```\n"
API['enums'].each do |e|
  vals = e['values'].map { |v| "#{v['name']}=#{v['value']}" }.join(' ')
  o << "# #{e['name']}: #{e['description']}\n#{vals}\n"
end
o << "```\n"

# --- defines / constants ---
colors = []; ints = []; floats = []; strings = []
API['defines'].each do |d|
  case d['type']
  when 'COLOR'  then colors << d['name']
  when 'INT'    then ints   << "#{d['name']}=#{d['value']}"
  when 'FLOAT'  then floats << "#{d['name']}=#{d['value']}"
  when 'STRING' then strings << "#{d['name']}=#{d['value'].inspect}"
  end
end
o << "\n## Other constants under Rl::\n```\n"
o << "# Colors (Rl::Color constants)\n#{colors.join(' ')}\n"
o << "# Numeric\n#{(ints + floats).join(' ')}\n" unless (ints + floats).empty?
o << "# String\n#{strings.join(' ')}\n" unless strings.empty?
o << "```\n"

# --- RmlUi (hand-maintained, typed) ---
o << <<~RML

  ## RmlUi (HTML/CSS UI; call Rml.init AFTER Rl.init_window)
  ```ruby
  # setup / lifecycle
  Rml.init                                   # -> nil   (inits RmlUi + rlgl backend)
  Rml.load_font(path:String, fallback:false) # register .ttf
  Rml.shutdown
  ctx = Rml::Context.new(name:String, width:Integer=screen_w, height:Integer=screen_h)
  ctx.resize(width:Integer, height:Integer)
  ctx.dimensions = Rl::Vector2

  # per-frame: process_input before block, update+render after (exception-safe)
  ctx.frame { ...mutate ui... }
  ctx.process_input ; ctx.update ; ctx.render   # manual equivalent

  # documents
  doc = ctx.load_document(path:String) { |doc| ... }  # -> Rml::Document
  ctx.document(id:String)        # -> Rml::Element (already-loaded lookup) | nil
  ctx.num_documents              # -> Integer
  doc.show ; doc.hide ; doc.close ; doc.pull_to_front ; doc.push_to_back
  doc.title ; doc.title = String

  # Rml::Element (Document is a subclass)
  el[name]            # get attribute -> String|nil ;  el[name] = value
  el.attribute(name) ; el.set_attribute(name, v) ; el.has_attribute?(name) ; el.remove_attribute(name)
  el.id ; el.id = v ; el.tag_name
  el.inner_rml ; el.inner_rml = html ; el.text ; el.text = s
  el.add_class(c) ; el.remove_class(c) ; el.set_class(c, bool) ; el.class_set?(c)
  el.set_property("color","red") ; el.property(name) ; el.remove_property(name)
  el.focus ; el.blur ; el.click ; el.scroll_into_view(align_top=true) ; el.visible?
  el.element(id)              # alias get_element_by_id -> Element|nil
  el.query_selector(sel) ; el.query_selector_all(sel) ; el.elements_by_tag(tag)
  el.parent ; el.child_count ; el.child(i) ; el.children ; el.owner_document
  el.client_width ; el.client_height ; el.offset_left ; el.offset_top ; el.absolute_left ; el.absolute_top
  el.on(:click) { |event| ... }     # event types: click, mouseover, change, submit, ...

  # Rml::Event (passed to el.on)
  ev.type ; ev.target ; ev.current ; ev.stop_propagation ; ev.stop_immediate_propagation
  ev[key] -> Float ; ev.param(key) -> Float ; ev.param_str(key) -> String ; ev.mouse_x ; ev.mouse_y

  # MVC data model (binds Ruby to {{vars}} / data-* in RML). Create BEFORE load_document.
  m = ctx.data_model(name:String) do |m|
    m.bind(:score) { game.score }   # one-way computed (read each frame)
    m.value(:hp, 100)               # two-way scalar
    m.event(:reset) { game.reset! } # controller: rml `data-event-click="reset()"`
  end                               # block form finishes it automatically
  m[:hp] ; m[:hp] = 80              # read / write+dirty
  m.dirty(:score, ...) ; m.dirty_all   # re-evaluate bound vars after state changes
  ```
RML

# --- Flecs (ECS), hand-maintained ---
o << <<~FLECS

  ## Flecs (ECS, module `Flecs::`)
  Entity Component System. Components are real C structs declared at runtime from
  a meta descriptor string and (de)serialized to/from Ruby Hashes. Works
  identically on desktop and web. Entities/components are integer ids wrapped in
  Flecs::Entity / Flecs::Component (use them anywhere an id is expected).
  ```ruby
  world = Flecs::World.new                       # owns the ecs_world_t (freed by GC)

  # Components: a meta struct descriptor (C type syntax). Returns Flecs::Component.
  pos = world.struct("Position", "{float x; float y;}")
  vel = world.struct("Velocity", "{float x; float y;}")
  # supported member types: bool, char, [iu]8/16/32/64, f32/f64, uptr/iptr,
  # string (char*), entity, nested structs, inline arrays.
  npc = world.tag("Npc")                          # dataless id -> Flecs::Component

  # Entities (Flecs::Entity)
  e = world.entity("player")                      # name optional
  e = world.entity                                # anonymous
  world.lookup("player")                          # -> Flecs::Entity | nil
  e.id ; e.to_i ; e.name ; e.name = "p2" ; e.alive? ; e.delete

  # Components on entities (Hash <-> struct)
  e.set(pos, x: 1.0, y: 2.0)                       # kwargs or e.set(pos, {x:1,y:2})
  e.get(pos)            # -> {x: 1.0, y: 2.0} | nil
  e.add(npc) ; e.remove(npc) ; e.has?(npc)        # tags or components
  e.set(pos, x: 0, y: 0).add(npc)                 # chainable

  # Systems: run each progress() during a phase. Block gets |entity_id, *comp_hashes|
  # in the order of `with:`; mutations to the component Hashes are written back.
  world.system("Move", with: [pos, vel]) do |id, p, v|
    p[:x] += v[:x]; p[:y] += v[:y]
  end
  world.progress(dt = 0.0)   # -> Boolean (false = quit); runs all systems once

  # Ad-hoc queries (cached) -> Flecs::Query (Enumerable)
  q = world.query(pos, vel)
  q.each { |id, p, v| ... }                        # same writeback semantics

  # phases: Flecs::ON_LOAD, Flecs::PRE_UPDATE, Flecs::ON_UPDATE (default), Flecs::ON_START
  ```
  NOTE: the system/query block receives the entity as an **Integer id** (not a
  Flecs::Entity) for speed; wrap with `world.entity_for(id)` if you need methods —
  or just use ids. Component data is delivered as Hashes; mutate them in place.
  Multithreaded systems are NOT exposed (single-threaded `progress` only; this is
  also the only mode that works on the wasm/web build).
FLECS

# --- Jolt Physics (3D), hand-maintained ---
o << <<~JOLT

  ## Jolt Physics (3D, module `Jolt::`)
  Rigid-body 3D physics via the joltc C API. Vectors accept Arrays or Rl::Vector3
  and are returned as Rl::Vector3/Vector4. Single-threaded `step` (identical on
  desktop and web). Full spec: docs/API_SPEC_JOLT.md.
  ```ruby
  world = Jolt::World.new(gravity: [0, -9.81, 0], max_bodies: 10240)
  world.gravity = [0, -20, 0]
  world.step(dt = 1.0/60.0, collision_steps: 1)   # advance; alias: update
  world.optimize_broad_phase                       # once after bulk-adding bodies

  # shapes (reusable) -> Jolt::Shape
  Jolt.box(width, height, depth)        # FULL dimensions (not half-extents)
  Jolt.sphere(radius)
  Jolt.capsule(half_height, radius)     # half-height of cylinder section
  Jolt.cylinder(half_height, radius)
  Jolt.convex_hull(points)              # Array of [x,y,z]
  Jolt.mesh(vertices)                   # triangle soup (3 verts/tri); STATIC bodies only

  # bodies -> Jolt::Body. motion: Jolt::STATIC | KINEMATIC | DYNAMIC
  b = world.body(shape: Jolt.sphere(0.5), position: [0,10,0], rotation: [0,0,0,1],
                 motion: Jolt::DYNAMIC, restitution: 0.0, friction: 0.2, activate: true,
                 velocity: nil, user_data: nil, mass: nil, linear_damping: 0.05,
                 angular_damping: 0.05, ccd: false, sensor: false)  # alias: add_body
  b.sensor = true ; b.ccd = true   # also settable at runtime
  b.id ; b.position -> Rl::Vector3 ; b.center_of_mass ; b.rotation -> Rl::Vector4
  b.position = [x,y,z]
  b.set_transform(position:, rotation: nil, activate: true)
  b.linear_velocity ; b.linear_velocity = [x,y,z]
  b.angular_velocity ; b.angular_velocity = [x,y,z]
  b.apply_force(v) ; b.apply_impulse(v) ; b.apply_torque(v)   # chainable
  b.active? ; b.activate ; b.deactivate ; b.remove
  b.user_data ; b.user_data = entity_id        # 64-bit tag (map collisions -> game objs)
  b.motion_type ; b.motion_type = Jolt::KINEMATIC ; b.set_motion_type(mt, activate: true)
  b.friction = 0.8 ; b.restitution = 0.9 ; b.gravity_factor = 0.0

  # queries
  hit = world.raycast([0,10,0], [0,-20,0])     # -> Jolt::RayHit | nil
  hit.body_id ; hit.body ; hit.fraction ; hit.point -> Rl::Vector3 ; hit.normal -> Rl::Vector3
  world.overlap_point([x,y,z]) -> Array<Jolt::Body>   # bodies containing a point

  # collision events (began this step) -> Array<Jolt::Contact>; ended -> ContactEnd
  world.contacts.each do |c|
    c.body_a_id ; c.body_b_id ; c.body_a ; c.body_b
    c.point -> Rl::Vector3 ; c.normal -> Rl::Vector3
    c.involves?(b) ; other = c.other(b)        # the other body in the contact
  end
  world.contacts_ended.each { |c| c.involves?(zone) ; c.other(zone) }  # stopped touching
  # sensor bodies (sensor: true) + contacts/contacts_ended = trigger volumes (enter/leave)

  # constraints / joints (return Jolt::Constraint; joint.remove to detach).
  # The WORLD retains constraints + ragdolls, so a dropped handle still stays
  # alive (a GC'd Constraint/Ragdoll would otherwise detach itself). Use .remove.
  world.weld(a, b)                                   # rigid weld
  world.ball_joint(a, b, point)                      # point-to-point
  world.distance_joint(a, b, pa, pb, min: 0, max: 2) # rope/rod
  world.hinge(a, b, point, axis, min_deg: -90, max_deg: 90)  # door
  world.slider(a, b, point, axis, min: -2, max: 2)   # piston
  world.cone(a, b, point, axis, half_angle_deg: 30)  # swing/twist limit

  # character controller (kinematic capsule; stair-step + slope) -> Jolt::Character
  ch = world.character(shape: Jolt.capsule(0.6, 0.3), position: [0,2,0],
                       max_slope_deg: 45, mass: 70)
  # per frame: set velocity (apply gravity/jump yourself), then update + step
  v = ch.velocity
  vy = ch.on_ground? ? (jump ? 6.0 : 0.0) : v.y - 20.0 * dt
  ch.velocity = [input_x * 5, vy, input_z * 5]
  ch.update(dt) ; world.step(dt)
  ch.position -> Rl::Vector3 ; ch.position = [x,y,z] ; ch.on_ground?
  ch.ground_state # :on_ground|:on_steep|:not_supported|:in_air ; ch.ground_normal ; ch.supported?
  ch.max_strength = 6000 ; ch.mass = 70   # push force vs dynamic bodies / collision mass
  # ride moving platforms: a KINEMATIC body whose velocity the character inherits
  ch.ground_velocity -> Rl::Vector3   # velocity of the surface underfoot (0 if airborne)
  ch.ground_body -> Jolt::Body | nil  # the body it stands on
  ch.ride(dt)                         # = update(dt) + inherit a STATIC/KINEMATIC
                                      # platform's velocity (DYNAMIC ground ignored,
                                      # else its reaction to your weight flings you)

  # ragdoll: tree of dynamic bodies + swing-twist joints. Parts PARENTS-FIRST.
  rd = world.ragdoll(parts: [
    { name: :torso, shape: Jolt.capsule(0.22,0.16), position: [0,4,0], mass: 20 },
    { name: :head,  shape: Jolt.sphere(0.16), position: [0,4.45,0], parent: :torso,
      joint: [0,4.24,0], twist_axis: [0,1,0], plane_axis: [1,0,0],
      cone_deg: 25, plane_deg: 25, twist_min_deg: -25, twist_max_deg: 25 },
  ], user_data: 0)
  rd.body_count ; rd.bodies -> Array<Jolt::Body> ; rd[0] ; rd.activate
  rd.bodies.each { |b| b.apply_impulse([fx,fy,fz]) } ; rd.remove
  # capsule parts: local axis = Y; draw via
  #   Rl.vector3_rotate_by_quaternion([0, half_height, 0], body.rotation)
  ```
  NOTE: STATIC = never moves (floors/walls), KINEMATIC = you move it (infinite
  mass), DYNAMIC = simulated; collision layer is derived from motion type.
  Use body.user_data to bridge contacts back to game objects (e.g. flecs entity
  ids). Not exposed: shape-cast queries, height-field/compound shapes, vehicles,
  soft bodies, ragdoll pose/motor driving, custom layers, multithreading.
  Determinism is OFF.
JOLT

# --- unbound functions (do NOT call these) ---
o << "\n## NOT bound (do not call — no Ruby method exists)\n"
o << "These raylib/raymath functions are intentionally unbound (callbacks, raw\n"
o << "pointers/buffers, varargs, or array/string returns). Use Ruby equivalents\n"
o << "(`File`, `format`, arrays, `puts`) or avoid.\n```\n"
o << skip_reason.keys.sort.each_slice(4).map { |s| s.join(', ') }.join(",\n") << "\n```\n"

File.write(OUT, o)
nfn = API['functions'].reject { |f| skip_reason[f['name']] }.size +
      RMATH['functions'].reject { |f| skip_reason[f['name']] }.size
warn "wrote #{OUT}: #{nfn} functions, #{API['structs'].size} structs, " \
     "#{API['enums'].size} enums, #{skip_reason.size} unbound (#{o.lines.size} lines)"
