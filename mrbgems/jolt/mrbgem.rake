stack_root = ENV['JAMSTACK_ROOT'] || File.expand_path('../../..', __dir__)
joltc_inc  = File.join(stack_root, 'vendor', 'joltc', 'include')

MRuby::Gem::Specification.new('jolt') do |spec|
  spec.license = 'MIT'
  spec.authors = 'raylib-jamstack'
  spec.summary = 'Ruby (Jolt::) bindings for Jolt Physics via the joltc C API'

  # libjoltc.a + libJolt.a are built separately (CMake) and linked at the final
  # step by build.zig / build_web.sh; here we only need joltc's header.
  spec.cc.include_paths  << joltc_inc
  spec.cxx.include_paths << joltc_inc if spec.respond_to?(:cxx)
end
