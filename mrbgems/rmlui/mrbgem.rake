MRuby::Gem::Specification.new('rmlui') do |spec|
  spec.license = 'MIT'
  spec.authors = 'raylib-jamstack'
  spec.summary = 'Ruby (Rml::) bindings for RmlUi, rendered via raylib/rlgl'

  stack_root = ENV['JAMSTACK_ROOT'] || File.expand_path('../../..', __dir__)

  rmlui_inc  = File.join(stack_root, 'vendor', 'rmlui', 'Include')
  raylib_inc = File.join(stack_root, 'vendor', 'raylib', 'src')

  spec.cxx.include_paths << rmlui_inc
  spec.cxx.include_paths << raylib_inc
  spec.cxx.flags << '-std=c++17'

  # RmlUi static lib + its deps (freetype, libstdc++) are linked by build.zig.
end
