#!/bin/sh
# Incremental rebuild: mruby (libmruby.a, picks up mrbgem changes) + zig link.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
CLEANPATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/c' | paste -sd:)
export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$CLEANPATH"
export JAMSTACK_ROOT="$ROOT"
export MRUBY_CONFIG="$ROOT/build_config.rb"

LIB="$ROOT/vendor/mruby/build/host/lib/libmruby.a"
# Target the lib path specifically so rake doesn't try to build mruby's CLI tools
# (which fail to link without raylib/rmlui). This exits 0 on success.
( cd "$ROOT/vendor/mruby" && rake "$LIB" )
( cd "$ROOT" && zig build )
# Regenerate clangd's compile database (picks up new sources / the generated
# raylib_gen.c). See .agents/knowledge/ruby-lsp.md — clangd needs this so the
# relative -Ivendor/... include roots resolve against the project root.
ruby "$ROOT/tools/gen_compile_commands.rb" >/dev/null 2>&1 || \
  echo "warn: compile_commands.json not regenerated ($?)"
echo "OK -> $ROOT/zig-out/bin/game"
