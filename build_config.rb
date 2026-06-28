# mruby build configuration for raylib-jamstack.
#
# Produces vendor/mruby/build/host/lib/libmruby.a containing the default gembox
# plus our raylib + rmlui bindings mrbgems. The final link (raylib + RmlUi +
# system GL) is done by build.zig.
#
# build.zig invokes rake with JAMSTACK_ROOT set to the project root.
STACK_ROOT = ENV['JAMSTACK_ROOT'] || File.expand_path('..', __dir__)

MRuby::Build.new do |conf|
  toolchain :gcc

  conf.enable_debug
  # Disable preallocated symbols: lets us add new binding method names without
  # regenerating the presym table (avoids stale-symbol build errors on rebuild).
  conf.disable_presym
  # Force 64-bit mrb_int on ALL targets. flecs entity ids (ecs_entity_t) carry a
  # generation in the high 32 bits; with the default 32-bit mrb_int (wasm32), the
  # generation is truncated across the mruby boundary and recycled entities leak
  # (ecs_is_alive/ecs_delete see a stale generation). See .agents/knowledge/flecs-binding.md.
  conf.cc.defines  << 'MRB_INT64'
  conf.cxx.defines << 'MRB_INT64'
  conf.gembox 'default'

  # Our raylib bindings (C + mrblib Ruby sugar).
  conf.gem File.join(STACK_ROOT, 'mrbgems', 'raylib')
  # Our RmlUi bindings (C++ + mrblib Ruby sugar).
  conf.gem File.join(STACK_ROOT, 'mrbgems', 'rmlui')
  # Our flecs (ECS) bindings (C + mrblib Ruby sugar).
  conf.gem File.join(STACK_ROOT, 'mrbgems', 'flecs')
  # Our Jolt (3D physics) bindings (C over the joltc C API + mrblib Ruby sugar).
  conf.gem File.join(STACK_ROOT, 'mrbgems', 'jolt')
  # Study-audio native helper: extracts raw float samples from audio files
  # via raylib's Wave API for the pure-Ruby silence detector.
  conf.gem File.join(STACK_ROOT, 'mrbgems', 'study_audio')

  conf.enable_test if ENV['JAMSTACK_TEST']
end

# Web (Emscripten/WASM) cross build. Defined only when JAMSTACK_WEB is set so the
# desktop build doesn't require emcc. Produces build/web/lib/libmruby.a (wasm),
# linked by build_web.sh with the wasm raylib + RmlUi.
if ENV['JAMSTACK_WEB']
  MRuby::CrossBuild.new('web') do |conf|
    toolchain :clang

    conf.cc.command      = 'emcc'
    conf.cxx.command     = 'em++'
    conf.linker.command  = 'emcc'
    conf.archiver.command = 'emar'

    # C++ exceptions: mruby is built with MRB_USE_CXX_EXCEPTION (a C++ mrbgem is
    # present), and RmlUi uses exceptions; enable them for the wasm target.
    conf.cc.flags  << '-fexceptions'
    conf.cxx.flags << '-fexceptions'

    conf.enable_debug
    conf.disable_presym
    conf.cc.defines  << 'MRB_INT64'
    conf.cxx.defines << 'MRB_INT64'
    conf.gembox 'default'

    conf.gem File.join(STACK_ROOT, 'mrbgems', 'raylib')
    conf.gem File.join(STACK_ROOT, 'mrbgems', 'rmlui')
    conf.gem File.join(STACK_ROOT, 'mrbgems', 'flecs')
    conf.gem File.join(STACK_ROOT, 'mrbgems', 'jolt')
    conf.gem File.join(STACK_ROOT, 'mrbgems', 'study_audio')
  end
end
