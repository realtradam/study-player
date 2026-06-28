#!/bin/sh
# bin/bootstrap — clone the vendored dependencies + apply vendor patches.
#
# `vendor/` is git-ignored, so a fresh `git clone` of this repo has none of the
# native libs the build needs. This script fetches each pinned dependency into
# `vendor/<name>` (skipping ones already present) and applies every patch in
# `patches/` that targets a vendored repo. Run once after cloning this repo:
#
#   git clone <this-repo> raylib-jamstack
#   cd raylib-jamstack
#   ./bin/bootstrap.sh
#   zig build                 # desktop  (or: ./build_web.sh for web)
#
# This is the single source of truth for the pinned vendor versions — BUILDING.md
# points here. It does NOT install the toolchain: you still need Zig, Ruby+rake,
# a C compiler, and (for web) the Emscripten SDK — see BUILDING.md "Prerequisites".
#
# Idempotent: safe to re-run. Existing vendor dirs are left untouched; patches
# already applied are skipped.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# <name> <git-url> <branch-or-tag-or-''(for default)>
clone_dep() {
    name="$1"; url="$2"; ref="$3"
    dest="vendor/$name"
    if [ -d "$dest/.git" ]; then
        echo "  [skip] $dest already present"
    else
        mkdir -p vendor
        if [ -n "$ref" ]; then
            echo "  [clone] $name @ $ref -> $dest"
            git clone --depth 1 --branch "$ref" "$url" "$dest"
        else
            echo "  [clone] $name @ default -> $dest"
            git clone --depth 1 "$url" "$dest"
        fi
    fi
}

echo "==> cloning vendored dependencies into vendor/ (skipping any present)"
# Pinned versions — keep in sync with BUILDING.md.
clone_dep mruby     https://github.com/mruby/mruby           3.3.0
clone_dep raylib     https://github.com/raysan5/raylib        6.0
clone_dep rmlui      https://github.com/mikke89/RmlUi         6.1
clone_dep flecs      https://github.com/SanderMertens/flecs   v4.1.1
clone_dep joltc      https://github.com/amerkoleci/joltc      ""    # no pinned tag (main)
clone_dep JoltPhysics https://github.com/jrouwe/JoltPhysics   v5.5.0
echo

# Apply every vendor patch in patches/. Each .patch is a `git diff` whose paths
# are relative to the relevant vendor dir (e.g. src/platforms/rcore_web.c is
# relative to vendor/raylib). We detect which vendor a patch targets from its
# first hunk path, and apply from that vendor dir so paths resolve.
echo "==> applying vendor patches from patches/ (skipping any already applied)"
applied=0; skipped=0; failed=0
for patch in patches/*.patch; do
    [ -e "$patch" ] || continue
    patch_abs="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"
    # Find the vendor the patch targets: first "--- a/<path>" line -> first path segment.
    first_path=$(sed -n 's|^--- a/||p' "$patch" | head -1)
    if [ -z "$first_path" ]; then
        echo "  [WARN] $patch: no '--- a/' path found, cannot determine target vendor; skipping"
        failed=$((failed + 1)); continue
    fi
    # The patch path is relative to the vendor root (e.g. src/platforms/...).
    # We try each vendor dir until `git apply --check` (forward or reverse) matches.
    target=""
    for v in vendor/*; do
        [ -d "$v/.git" ] || continue
        # reverse-check: patch already applied?
        if git -C "$v" apply --check --reverse "$patch_abs" >/dev/null 2>&1; then
            target="$v"
            echo "  [skip] $patch — already applied to $target"
            skipped=$((skipped + 1)); break
        fi
        # forward-check: applies cleanly to current tree?
        if git -C "$v" apply --check "$patch_abs" >/dev/null 2>&1; then
            target="$v"
            git -C "$v" apply "$patch_abs"
            echo "  [apply] $patch -> $target"
            applied=$((applied + 1)); break
        fi
    done
    if [ -z "$target" ]; then
        echo "  [FAIL] $patch: does not apply (forward or reverse) to any vendor/*"
        failed=$((failed + 1))
    fi
done
echo "  patches: $applied applied, $skipped already-applied, $failed failed"
echo

if [ "$failed" -ne 0 ]; then
    echo "==> bootstrap finished with $failed patch failure(s) — see above"
    exit 1
fi

echo "==> bootstrap done. Next:"
echo "    zig build                       # desktop build (or: ./zig-out/bin/game game/main.rb)"
echo "    EMSDK_ENV=~/emsdk/emsdk_env.sh ./build_web.sh   # web build"
