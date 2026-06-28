stack_root = ENV['JAMSTACK_ROOT'] || File.expand_path('../../..', __dir__)
flecs_inc  = File.join(stack_root, 'vendor', 'flecs', 'distr')

MRuby::Gem::Specification.new('flecs') do |spec|
  spec.license = 'MIT'
  spec.authors = 'raylib-jamstack'
  spec.summary = 'Ruby (Flecs::) bindings for the flecs ECS'

  # The flecs amalgamation (vendor/flecs/distr/flecs.c) is compiled separately
  # into a static lib by build.zig / build_web.sh and linked at the final step;
  # here we only need its header on the include path.
  spec.cc.include_paths  << flecs_inc
  spec.cxx.include_paths << flecs_inc if spec.respond_to?(:cxx)
end
