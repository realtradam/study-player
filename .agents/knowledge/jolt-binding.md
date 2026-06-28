# Tribal knowledge: Jolt Physics bindings (`Jolt::`)

3D physics. Hand-written C (`mrbgems/jolt/src/jolt_bindings.c`) + Ruby sugar
(`mrblib/jolt.rb`) over the **joltc** C API (Amer Koleci's C wrapper around
JoltPhysics). Full spec: `docs/API_SPEC_JOLT.md`.

## At a glance
- **Key files:** `mrbgems/jolt/src/jolt_bindings.c`; sugar `mrblib/jolt.rb`;
  `mrbgem.rake`; `vendor/joltc` + `vendor/JoltPhysics` → merged `libjoltphysics.a`.
- **Ruby API:** shapes `Jolt.box/sphere/capsule/...`; `Jolt::World` (`body`, `step`,
  `raycast`, constraints, `character`, `ragdoll`), `Body`/`Character`/`Ragdoll`/`Constraint`.
  Spec `docs/API_SPEC_JOLT.md`.
- **Cross-refs:** rule `lld-no-gcc-lto`; demos `game/ballpit_demo.rb`,
  `ragdoll_demo.rb`, `physics_playground.rb`. (This doc is long for a reason — read it.)

## Vendoring + build (two repos, CMake)
- `vendor/joltc` (the C API) and `vendor/JoltPhysics` (v5.5.0, side-by-side so
  joltc finds it locally — no CMake FetchContent network pull).
- CMake builds `libjoltc.a` + `libJolt.a`, which we **merge into one archive**
  `build/{desktop,web}/libjoltphysics.a` (extract both with `ar x`, re-`ar rcs`).
  The merge matters: `libmruby -> libjoltc -> libJolt` is a 3-archive chain and a
  single merged archive (like libflecs.a) resolves cleanly.
- Build flags: `-DINTERPROCEDURAL_OPTIMIZATION=OFF` (REQUIRED — see below),
  `-DJPH_SAMPLES=OFF -DJPH_TESTS=OFF`, profiler + debug-renderer OFF (smaller).

## THE big gotcha: GCC LTO vs lld (cost ~hours)
Jolt enables `INTERPROCEDURAL_OPTIMIZATION` (GCC `-flto`) by default. zig's lld
**cannot link GCC GIMPLE-LTO objects** → every `JPH_*` symbol shows "undefined"
at link, even though `nm` says they're defined. Tell: `readelf -s joltc.cpp.o`
shows ~5 symbols and `.gnu.lto_*` sections. Fix: `-DINTERPROCEDURAL_OPTIMIZATION=OFF`.
(Captured as `.agents/rules/lld-no-gcc-lto.md`.) GNU `ld` links GCC-LTO fine, which
is why a manual `gcc` link works but `zig build` doesn't — a useful bisection.

## Single-threaded (wasm-safe)
The job system is created with `JobSystemThreadPoolConfig{ ..., numThreads=0 }`
so jobs run inline on the calling thread. There is no single-threaded job-system
symbol in joltc; `numThreads=0` is the way. This is the only mode valid on the
wasm build (no pthreads) and behaves identically on desktop. Don't expose
multithreaded systems.

## Web
Same merge, built with `emcmake`/`emar`. Adds ~1.14 MB to `game.wasm`
(uncompressed; ~300-400 KB gzipped). Uses the existing `-sSTACK_SIZE=4MB`.
LLVM/emcc LTO would be fine here, but we keep IPO OFF for consistency.

## API design notes
- Fixed 2-layer setup: 0=STATIC (non-moving), 1=MOVING. A body's layer is derived
  from its motion type (static -> STATIC, else MOVING). No custom layers exposed.
  The ObjectLayerPairFilter MUST enable STATIC<->MOVING **and MOVING<->MOVING** —
  forgetting MOVING<->MOVING means dynamic bodies fall through each other (they
  still hit static floors). STATIC<->STATIC stays disabled.
- C primitives are numeric; `mrblib/jolt.rb` does Array/`Rl::Vector3` coercion
  (in) and returns `Rl::Vector3`/`Vector4` when raylib is present (lazily checked
  via `const_defined?`, since mruby's `defined?` doesn't parse in endless-method
  form). Positions/rotations cross the boundary as plain float arrays.
- `mrb_get_args` format must match exactly: `_add_body` is `"offfffffiffb"`
  (shape, 7 floats, **int motion**, 2 floats, bool) — an `i` in the wrong slot
  silently corrupts the motion type (body won't simulate).
- Determinism is available but OFF: add `-DCROSS_PLATFORM_DETERMINISTIC=ON` to the
  CMake configs when you need cross-platform reproducibility (perf cost).

## Contact events
`world.contacts` returns collisions that *began* this step (OnContactAdded only —
not Persisted, so the list stays small). Implementation: flecs-style — a GLOBAL
`JPH_ContactListener_Procs` (set once via `JPH_ContactListener_SetProcs`), plus a
per-world `JPH_ContactListener` whose `userData` is the `jolt_world_t*`, so the
proc routes each event to that world's buffer. Safe to write the buffer from the
proc because Update runs single-threaded (numThreads=0). Buffer is reset at the
start of `_step` and capped at 4096/step. Bridge contacts to game objects via
`body.user_data` (a uint64 — store a flecs entity id).

## Character controller (Jolt::Character)
Wraps `JPH_CharacterVirtual` (kinematic player capsule). `update` calls
`JPH_CharacterVirtual_ExtendedUpdate` (NOT basic `_Update`) — basic Update only
slides; ExtendedUpdate adds stair-stepping + stick-to-floor. There is no
`ExtendedUpdateSettings_Init`, so we fill Jolt's documented defaults by hand
(walkStairsStepUp.y = 0.4 = max step height). Init copies base defaults but we
still set `base.up = (0,1,0)` and `base.supportingVolume = {{0,1,0}, -1e10}`
(accept all contacts geometrically; the slope angle then classifies ground vs
steep). The character holds the `JPH_PhysicsSystem*` for Update; the Ruby wrapper
sets `@world` so the world can't be GC'd out from under it. Gravity is NOT
auto-applied — the game adds it to `velocity` each frame. `mruby/variable.h` is
required for `mrb_iv_set`.

**Pushing dynamic props:** ExtendedUpdate already pushes the dynamic bodies the
character walks into, BUT Jolt's default `maxStrength` (100 N) is far too weak to
move default-density props — bodies have density 1000 kg/m³, so a 0.5 m sphere is
~520 kg and barely budges. To make the player shove balls/crates around, raise
`char.max_strength = ` (exposed via `_set_max_strength` →
`JPH_CharacterVirtual_SetMaxStrength`; getter `max_strength`, plus `mass=` →
`SetMass`). A kinematic body always pushes the character regardless (penetration
recovery), and the character never pushes a kinematic body back — that asymmetry
(player shoves balls, an orbiting kinematic sphere shoves the player) is exactly
how `game/ballpit_demo.rb` is built. There is still no per-body density/mass
override binding, so tune ball *radius* if you need lighter props without code.

## Constraints, sensors, queries (high-value batch)
- **Constraints** (`world.weld/ball_joint/distance_joint/hinge/slider/cone`):
  joltc's `*Constraint_Create` take `JPH_Body*`, not body ids. Get a stable
  pointer with `jolt_body_for(w, id)` — `JPH_PhysicsSystem_GetBodyLockInterfaceNoLock`
  + `LockRead`/`UnlockRead`; the body pointer is stable single-threaded (bodies
  don't move in memory), so lock→get→unlock→use is safe. Settings use
  `JPH_ConstraintSpace_WorldSpace` with `point1==point2==anchor`; hinge/slider need
  a `normalAxis` perpendicular to the axis (`jolt_perp`). The Ruby `Jolt::Constraint`
  keeps its `@world` alive and `RemoveConstraint`+`Destroy` on GC or `.remove`.
- **Sensors** = `sensor: true` body. The SAME contact listener reports sensor
  overlaps, so `world.contacts` (enter) + `world.contacts_ended` (leave) give
  trigger-volume enter/leave with no binding-specific work.
- **Contact-removed**: `OnContactRemoved` gives a `JPH_SubShapeIDPair` (has
  `Body1ID`/`Body2ID`), buffered into `ended` (reset each step like `contacts`).
- **Raycast normal**: `JPH_Body_GetWorldSpaceSurfaceNormal(body, subShapeID, &pos,
  &n)` — needs `jolt_body_for` again. `RayCastResult.subShapeID2` is the sub-shape.
- **Point overlap**: `JPH_NarrowPhaseQuery_CollidePoint` with a float-returning
  collector callback (`return 1e30` = keep collecting), collecting body ids.
- **Body props at creation**: mass via `SetOverrideMassProperties(CalculateInertia)`
  + `MassPropertiesOverride.mass`; damping via `SetLinear/AngularDamping`; CCD via
  `SetMotionQuality(LinearCast)`; sensor via `SetIsSensor`. `_add_body` is now a
  17-arg `"offfffffiffbfffbb"` — keep the format string in lockstep with the call.

## Ragdolls + character platform-riding
- **Ragdoll** (`world.ragdoll(parts:)`): built in ONE C call from a packed array
  (`_ragdoll(packed, user_data)`) — mixed-type per-part arrays (string/shape/floats)
  are parsed with `mrb_ary_ref` + `mrb_as_*`. Needs `#include <mruby/string.h>`
  for `mrb_str_to_cstr` (else implicit-decl error → int→ptr). Build order that
  matters: Skeleton (AddJoint2 parent-first) → CalculateParentJointIndices →
  RagdollSettings SetSkeleton → ResizeParts → per-part Set* + SetPartToParent
  (SwingTwist, WorldSpace, position1==position2==joint) → Stabilize →
  DisableParentChildCollisions(NULL,0) → CalculateBodyIndexToConstraintIndex →
  CreateRagdoll → AddToPhysicsSystem. **Parts must be listed parents-before-children**
  or the skeleton is mis-ordered. Part object layer = motion→L_STATIC/L_MOVING.
- **Refcount lifetime**: Skeleton/RagdollSettings/Ragdoll are all RefCounted;
  joltc `*_Destroy` = Release (decrement), not free. CreateRagdoll makes the
  ragdoll hold refs to settings (which holds the skeleton), so we `Destroy` our
  build-time skeleton+settings refs IMMEDIATELY after CreateRagdoll — the ragdoll
  keeps them alive; ragdoll free does RemoveFromPhysicsSystem + Destroy.
- Ragdoll part bodies are normal bodies: `JPH_Ragdoll_GetBodyID(i)` works with all
  the existing `world._position/_rotation/...` methods. Capsule local axis = Y;
  draw endpoints via `Rl.vector3_rotate_by_quaternion([0,hh,0], rotation)`.
- **Platform riding**: `JPH_CharacterBase_GetGroundVelocity` + `GetGroundBodyId`
  (note joltc spelling `...BodyId`, lowercase d). CharacterVirtual does NOT add
  ground velocity itself — `ch.ride(dt)` adds `ground_velocity` to the character's
  velocity before ExtendedUpdate so kinematic platforms carry the player. Ground
  body id is invalid when airborne; Ruby `ground_body` returns nil unless `supported?`.

## Constraints/ragdolls MUST be retained (GC footgun — fixed in the binding)
- A `Jolt::Constraint`/`Jolt::Ragdoll` finalizer calls `RemoveConstraint`/
  `RemoveFromPhysicsSystem` — so if the Ruby handle is GC'd, the joint silently
  **detaches mid-simulation** (bodies fall apart nondeterministically, whenever a
  GC happens to run). This bit the playground demo: joints created fire-and-forget
  (`world.hinge(...)` with no assignment) broke after a few seconds.
- Fix lives in `mrblib/jolt.rb`: `World` keeps `@joints` / `@ragdolls` arrays and
  every `world.weld/ball_joint/distance_joint/hinge/slider/cone` + `world.ragdoll`
  pushes its result there (`_retain_joint`). `#remove` calls `_forget_joint`/
  `_forget_ragdoll` to drop the ref. So game code never needs to hold joint handles.
- If you add a NEW constraint-returning method, wrap its result in `_retain_joint`
  or it will inherit the original bug. Verify with a LONG run (600+ steps) — the
  bug only shows once a GC cycle fires, not in the first frames.

## Character#ride only inherits NON-dynamic ground (else it launches you)
- `ride(dt)` adds `ground_velocity` to the character before ExtendedUpdate so
  kinematic platforms carry it. But a DYNAMIC ground body (a ball you stand on, a
  constrained/​swinging pendulum) reports its *reaction to your weight* + its own
  motion as `ground_velocity`; inheriting that is a positive-feedback launch
  (repro: standing on a swinging bob shot the character to y≈92, peak vy≈61).
- Fix: `ride` gates on `ground_body.motion_type != Jolt::DYNAMIC` — only
  static/kinematic platforms are inherited; dynamic ground is just stood on.
  `ground_velocity` itself still returns the raw value (don't "fix" it there).

## Finalizer ORDER at shutdown — the "world freed first" crash (fixed)
- `@world`/`@joints` retention fixes *runtime* GC ordering, but **`mrb_close`
  frees every object in arbitrary order, ignoring references**. So at process exit
  a `Ragdoll`/`Constraint` finalizer can run AFTER its `World`'s
  `JPH_PhysicsSystem` is already destroyed. Calling `RemoveFromPhysicsSystem`/
  `RemoveConstraint` then → segfault; calling `JPH_*_Destroy` then → "double free
  or corruption" (the system already freed those bodies/constraints).
- Symptom: a heisenbug — adding `puts`/`$stdout.flush` changed allocation and hid
  it; only a `gdb` backtrace (`...->jolt_ragdoll_free -> RemoveFromPhysicsSystem`
  under `mrb_close -> free_heap`) pinned it. It only shows with enough live
  ragdolls/constraints that the world happens to be freed first.
- Fix: a shared refcounted **liveness token** (`jolt_token_t {alive, refs}`, libc
  malloc/free, independent of the mruby heap). `jolt_world_t` owns one; every
  ragdoll/constraint `jolt_token_acquire`s it. `jolt_world_free` sets `alive = 0`
  before destroying the system. Each dependent's free skips **all** Jolt calls
  when `!alive` (leak is fine — the process is exiting). Last owner frees the token.
- RULE: any future object that calls into the `JPH_PhysicsSystem` from its
  finalizer (vehicles, soft bodies, …) MUST take a token and gate on `alive`.
  Test by building a scene with many such objects and letting it exit (EXIT=0).

## Known limitations / leaks (first cut)
Shapes (`Jolt.box/sphere/...`) are Jolt ref-counted; we don't Release them on GC
(bounded leak; shapes are usually long-lived). The world's layer-filter tables
also aren't freed per world. Not yet exposed: constraints/joints, characters,
mesh/convex-hull shapes, contact callbacks, custom collision layers.
