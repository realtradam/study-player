# RULE: rebuilding mruby + the bindings

- Drive rake at the **specific lib path**, never plain `rake` (plain rake also
  builds mruby's CLI tools `mruby`/`mirb`/`mrdb`, which fail to link without
  raylib/rmlui/flecs):
  `rake "$JAMSTACK_ROOT/vendor/mruby/build/host/lib/libmruby.a"` — or just run
  `./rebuild.sh`.
- After **adding/removing a gem** in `build_config.rb`, or any change that flips
  the C/C++ ABI, `rm -rf vendor/mruby/build` first — otherwise stale objects
  cause "multiple definition" link errors. The rmlui gem is C++ and holds mruby
  in `MRB_USE_CXX_EXCEPTION` mode for the whole VM.
