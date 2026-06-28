#!/usr/bin/env bash
# Type-check gate for raylib-jamstack: RBS signature consistency + Steep type check.
#
#   rbs validate  — sig/*.rbs are internally consistent (catches duplicate
#                   methods, bad types, broken aliases). HARD FAIL.
#   steep check   — the Steep project loads cleanly + no :error-level issues.
#
# Under the Steepfile's `D::Ruby.lenient` config, game-code type typos are
# :information — visible in the editor (live LSP) and via
# `steep check --severity-level=information`, but NOT a CI failure here. So this
# gate fails only on real signature/structural breakage and is GREEN on correct
# code. (Editor = live type guidance; this script = sig/structural integrity.)
#
# Self-contained: sets the gem env (rbs + steep live in the user gem dir, like
# opencode.json's ruby-lsp/steep env). Run from the repo root.
set -euo pipefail

GEM_BIN="${GEM_BIN:-$HOME/.local/share/gem/ruby/3.4.0/bin}"
export PATH="$GEM_BIN:$PATH"
command -v rbs   >/dev/null 2>&1 || { echo "rbs not found — install: gem install rbs" >&2; exit 1; }
command -v steep >/dev/null 2>&1 || { echo "steep not found — install: gem install steep" >&2; exit 1; }

echo "== rbs validate =="
rbs validate
echo "== steep check =="
steep check
echo "OK: signatures valid + steep project loads clean."
