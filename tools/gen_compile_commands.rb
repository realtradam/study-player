#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"

# Generate compile_commands.json for clangd.
#
# The raylib-jamstack build is Zig-orchestrated (build.zig) + mruby rake
# (build_config.rb), neither of which emits compile_commands.json. clangd needs
# it (or it falls back to the file's own dir as the compile directory, which
# breaks the relative `-Ivendor/...` include roots — they'd resolve against the
# file's dir instead of the project root). This generator emits one entry per
# C/C++ source with `directory` = the project root, so the relative include
# paths resolve correctly.
#
# Run after a fresh clone / when source files are added:
#   ruby tools/gen_compile_commands.rb
# (rebuild.sh regenerates it automatically; see .agents/knowledge/ruby-lsp.md.)
#
# Output (compile_commands.json, gitignored — it holds absolute paths) targets
# the DESKTOP (gcc/clang) build. Web-only headers (<emscripten.h>) are guarded
# by #ifdef __EMSCRIPTEN__, which we do NOT define here, so clangd skips them.

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)

INCLUDES = %w[
  vendor/mruby/include
  vendor/raylib/src
  vendor/rmlui/Include
  vendor/flecs/distr
  vendor/joltc/include
].freeze

SOURCES = Dir.glob(["mrbgems/*/src/*.{c,cpp}", "src/*.{c,cpp}"]).
  # Skip the generated raylib bindings only if you don't want to index them;
  # we DO index raylib_gen.c so definition jumps into the generated surface work.
  sort

entries = SOURCES.map do |src|
  cpp = src.end_with?(".cpp")
  args = [
    cpp ? "clang++" : "clang",
    cpp ? "-std=c++17" : "-std=c11",
    "-DMRB_INT64",            # forced by build_config.rb on every target
    "-fsyntax-only",
    *INCLUDES.flat_map { |i| ["-I", i] },
    src,
  ]
  {
    "directory" => ROOT,
    "file" => src,
    "arguments" => args,
  }
end

out = File.join(ROOT, "compile_commands.json")
File.write(out, JSON.pretty_generate(entries) + "\n")
puts "wrote #{out} (#{entries.size} entries)"
