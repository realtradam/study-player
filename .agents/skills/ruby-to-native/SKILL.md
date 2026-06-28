# Skill: Ruby → Native C/C++ migration

# Migrate slow Ruby game logic to C/C++ for performance

Use when a Ruby hot loop or per-frame computation is too slow (frame drops,
measurable via `bin/eval` timing or visible jank). The goal is a native
function that's ergonomic from Ruby — the call site should look almost
identical, just faster.

## When to migrate
- A per-frame loop over many entities/pixels/voxels in pure Ruby.
- Math-heavy computation (matrix ops, procedural gen, image processing).
- String/array manipulation in a tight loop that `Array#map!` can't fix.
- Anything where the Ruby overhead (method dispatch, GC) dominates.

## When NOT to migrate
- The code runs once at startup (load time is fine).
- It's I/O bound, not CPU bound.
- The Ruby version is fast enough (measure first — don't guess).
- The logic changes frequently (Ruby is easier to iterate on; keep it Ruby
  until the API stabilizes, then migrate the stable version).

## Steps

### 1. Profile — confirm the bottleneck
```sh
sh .live/web/bin/eval 't = Rl.time; 1000.times { your_hot_code }; Rl.time - t'
```
Or check if frame rate drops when the code runs. If the Ruby version is fast
enough, **stop** — don't migrate.

### 2. Decide where the binding lives
- **Raylib function?** → add to the generator (`gen_raylib.rb`), following the
  `add-binding-fn` skill.
- **New standalone module?** → create a new mrbgem or add to an existing one.
  Put C in `mrbgems/<gem>/src/`, Ruby sugar in `mrbgems/<gem>/mrblib/`.
- **Game-specific native helper?** → create a new mrbgem (e.g. `mrbgems/gameutils/`)
  or add to an existing gem. Keep it separate from the library bindings.

### 3. Write the C function
- Match the mruby calling convention: `mrb_state*, mrb_value self, mrb_value args`.
- Use `mrb_get_args` for parameters; `mrb_float_value`/`mrb_fixnum_value`/
  `mrb_str_new_cstr` for returns.
- For arrays/structs, use the existing wrapping patterns (see `raylib_gen.c`
  for struct wrappers, `rml_bindings.cpp` for class wrapping).
- **GC:** if you allocate mruby objects, use `mrb_malloc` (GC-managed). If you
  hold references across calls, register them with `mrb_gc_register`.

### 4. Write the Ruby sugar (mrblib)
Keep the Ruby API clean. The call site should read naturally:
```ruby
# Before (slow Ruby):
particles.each { |p| p[:x] += p[:vx] * dt; p[:y] += p[:vy] * dt }

# After (fast C, same ergonomics):
ParticleSystem.integrate(particles, dt)
```
The sugar wraps the raw `_fn` call, handles nil defaults, and adds `?` predicates.

### 5. Register the function
In the C init function (`mrb_define_module_function` or
`mrb_define_method`), following the existing patterns in the gem.

### 6. Build
```sh
./rebuild.sh                                     # desktop
EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh   # web (both targets!)
```
If adding a NEW gem: add it to `build_config.rb` (both desktop + web sections),
then `rm -rf vendor/mruby/build` (ABI change).

### 7. Swap the call site
Replace the Ruby hot loop with the native call. This is the only `game/*.rb`
edit — coordinate with the gameplay-ruby agent if needed.

### 8. Verify via the web bridge
```sh
node tools/agent-bridge/server.js
# → open browser, then:
sh .live/web/bin/eval 't = Rl.time; 1000.times { YourModule.fn(...) }; Rl.time - t'
# Compare to the Ruby timing from step 1.
```
Also verify the game looks/plays identically (no visual regression).

### 9. Update types
If you changed the public API surface:
- `ruby mrbgems/raylib/tools/gen_ai_reference.rb` (if raylib)
- `ruby mrbgems/raylib/tools/gen_rbs.rb` (if raylib)
- Hand-edit `sig/*.rbs` for non-raylib gems.

### 10. Crystallize
If the migration revealed a new gotcha or pattern, add it to the relevant
`.agents/knowledge/` doc or this skill.

## Patterns

### Bulk array processing (most common)
Ruby passes an Array of Hashes (flecs components) or an Array of structs. The
C function iterates once, avoiding per-element Ruby method dispatch:
```c
// C: read Array, iterate, mutate in place or return new Array
static mrb_value bulk_integrate(mrb_state *mrb, mrb_value self) {
  mrb_value arr; mrb_float dt;
  mrb_get_args(mrb, "Af", &arr, &dt);
  mrb_int n = RARRAY_LEN(arr);
  for (mrb_int i = 0; i < n; i++) {
    mrb_value h = mrb_ary_ref(mrb, arr, i);
    // read hash fields, compute, write back
    mrb_hash_set(mrb, h, mrb_symbol_value(mrb_intern_lit(mrb,"x")),
                 mrb_float_value(mrb, new_x));
  }
  return arr;
}
```

### Struct batch ops
If the data is in Rl:: structs (Vector2, etc), pass the Array of struct
wrappers and access the C struct pointers directly (see `rl_ptr_Vector2`
pattern in `raylib_gen.c`).

### Keeping Ruby flexibility
Don't over-migrate. Leave high-level game logic in Ruby; only move the
inner loop to C. The Ruby wrapper can still handle edge cases, defaults,
and validation that would be tedious in C.

## Cross-refs
- Skill: `add-binding-fn` (for raylib-specific binding patterns)
- Skill: `build-and-verify` (for the build + verify sequence)
- Knowledge: `build-system.md`, `raylib-binding.md`
- Rules: `mruby-rebuild`, `link-order`, `dont-edit-generated`
