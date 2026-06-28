# Generate the full bindings (raylib_gen.c) from raylib's API description BEFORE
# the gem spec globs its source files.
stack_root = ENV['JAMSTACK_ROOT'] || File.expand_path('../../..', __dir__)
raylib_dir = File.join(stack_root, 'vendor', 'raylib')
  gen     = File.join(__dir__, 'tools', 'gen_raylib.rb')
  # raylib 6.0 relocated the API parser: parser/ -> tools/rlparser/, and the
  # source was renamed raylib_parser.c -> rlparser.c. raylib_api.json is shipped
  # (pre-generated) at tools/rlparser/output/; raymath_api.json is NOT shipped
  # and is generated below from src/raymath.h via the parser.
  json    = File.join(raylib_dir, 'tools', 'rlparser', 'output', 'raylib_api.json')
  raymath = File.join(raylib_dir, 'tools', 'rlparser', 'output', 'raymath_api.json')

  parser_src = File.join(raylib_dir, 'tools', 'rlparser', 'rlparser.c')
  parser_bin = File.join(raylib_dir, 'tools', 'rlparser', 'rlparser')
  raymath_h  = File.join(raylib_dir, 'src', 'raymath.h')
  if !File.exist?(raymath) && File.exist?(parser_src) && File.exist?(raymath_h)
    sh "cc -o #{parser_bin} #{parser_src}" unless File.exist?(parser_bin)
    sh "#{parser_bin} -i #{raymath_h} -o #{raymath} -f JSON -d RMAPI"
  end
  genc    = File.join(__dir__, 'src', 'raylib_gen.c')
  inputs  = [gen, json, raymath].select { |f| File.exist?(f) }
  if File.exist?(json) &&
     (!File.exist?(genc) || inputs.any? { |f| File.mtime(f) > File.mtime(genc) })
    sh "ruby #{gen} #{json} #{genc} #{raymath if File.exist?(raymath)}".strip
  end

  # Regenerate the baked SMAA lookup-texture data (src/smaa_tex_data.c) if stale.
  # Ports iryoku/smaa Scripts/AreaTex.py + SearchTex.py to CRuby; output is the
  # canonical 160x560 areaTex + 64x16 searchTex as a C const array (committed is
  # gitignored -- regenerated like raylib_gen.c). Lives in C because mruby caps
  # string literals at 65534 bytes AND a ~358KB string constant hangs its irep
  # loader at boot (see .agents/knowledge/fx-pipeline.md "SMAA 1x").
  smaa_gen = File.join(__dir__, 'tools', 'gen_smaa_tex.rb')
  smaa_c   = File.join(__dir__, 'src', 'smaa_tex_data.c')
  if File.exist?(smaa_gen) && (!File.exist?(smaa_c) || File.mtime(smaa_gen) > File.mtime(smaa_c))
    sh "ruby #{smaa_gen}"
  end

MRuby::Gem::Specification.new('raylib') do |spec|
  spec.license = 'MIT'
  spec.authors = 'raylib-jamstack'
  spec.summary = 'Ruby (Rl::) bindings for raylib (generated from raylib_api.json)'

  raylib_inc = File.join(raylib_dir, 'src')
  spec.cc.include_paths << raylib_inc
  spec.cxx.include_paths << raylib_inc if spec.respond_to?(:cxx)
end
