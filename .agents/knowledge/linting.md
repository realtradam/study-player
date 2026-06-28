# Tribal knowledge: linting (RuboCop + clang-format + clang-tidy)

Style linting is **manual** (`bin/lint`), not automatic. This is deliberate:
syntax errors are caught at **build time** (mruby-compiler gem — `rake` fails on
parse errors); type errors by **Steep** per-edit (RBS type checker, see
`opencode.json`); linting is a separate, end-of-implementation-pass step that
catches style inconsistencies and potential bugs without flooding the editor.

## At a glance
- **Run:** `bin/lint` (report) / `bin/lint --fix` (safe autocorrect) / `bin/lint --ruby` / `bin/lint --c`
- **Ruby config:** `.rubocop.yml` — `DisabledByDefault: true` + Layout + Lint departments + safe Style cops
- **C/C++ config:** `.clang-format` (Allman, 2-space, 100-col, return-type-on-own-line)
- **C/C++ analysis:** clang-tidy with `bugprone-*,cert-*,clang-analyzer-*` (report only, never auto-fixed)
- **Excludes:** `vendor/**`, `mrbgems/raylib/src/raylib_gen.c` (generated), `build/**`, `zig-out/**`, `.live/**`
- **Cross-refs:** `.agents/knowledge/ruby-lsp.md` (LSP setup), `opencode.json` (LSP config)

## Why RuboCop works for mruby (the non-obvious part)

The existing `opencode.json` comment says ruby-lsp's `linters: []` because they'd
"false-positive on mruby." This is true for ruby-lsp's *live* diagnostics, but
**RuboCop itself works fine** — and the upstream **mruby repo uses it** (via
pre-commit, `.github/linters/.rubocop.yml`).

The key facts (from RuboCop's compat docs + mruby's own config):
1. RuboCop **runs ON MRI** (we have 3.4.8) but **analyzes code targeting any
   Ruby version** — `TargetRubyVersion` controls what *syntax* the parser
   accepts, not the runtime.
2. The false-positive risk is **narrow**: only cops that suggest MRI-only stdlib
   methods (e.g. "use `Array#sum`") would break on mruby. **Layout/Lint cops
   are pure syntax** — no runtime assumptions, safe for mruby.
3. mruby upstream uses `DisabledByDefault: true` + only 3 layout cops. We enable
   more (whole Layout + Lint departments + safe Style subset) but the principle
   is identical: **opt-in, never the full default set**.

### TargetRubyVersion: 3.4 (critical — without it, 70+ false syntax errors)

Without `TargetRubyVersion: 3.4`, RuboCop defaults to the **Ruby 2.7 parser**,
which doesn't understand **endless method definitions** (`def foo = expr`,
Ruby 3.0+ syntax). This repo uses them extensively (raylib.rb, jolt.rb, rmlui.rb,
bridge.rb). The 2.7 parser emits `Lint/Syntax: unexpected token tEQL` and
spurious "class definition in method body" / "dynamic constant assignment"
errors — ~70 false positives that disappear with `TargetRubyVersion: 3.4`.

mruby 3.3's `MRUBY_RUBY_VERSION` is "3.3", but mruby upstream targets 3.4 in
their own RuboCop config (matches the host MRI running RuboCop). We do the same.

### The "too many lines" cops (explicitly disabled)

`Metrics/MethodLength`, `Metrics/BlockLength`, `Metrics/ModuleLength`,
`Metrics/ClassLength` complain about methods/blocks/modules/classes being too
long. Game code + mrbgem sugar intentionally has long methods and large files.
These are explicitly `Enabled: false` (DisabledByDefault already leaves them off,
but explicit means they stay off even if that flag is flipped).

Note: `Metrics/FileLength` does **not exist** in RuboCop 1.88 (it was removed) —
don't add it (RuboCop errors on unrecognized cops).

### Lint/RescueException (intentionally disabled)

The game loop and bridge intentionally `rescue Exception` (not `StandardError`)
to keep the game running / log exceptions instead of crashing. This is a
deliberate pattern across `mrbgems/*/mrblib/` (raylib.rb `while_window_open`,
live.rb, hot.rb). `Lint/RescueException` is `Enabled: false`.

## Why clang-format needs a config (and what it codifies)

There was **no `.clang-format`** before. The hand-written C/C++ follows a
dominant style I reverse-engineered (Allman braces, 2-space indent, ~100-col,
return type on its own line for top-level defs). With this config,
`raylib_bindings.c` produces **zero diff** — it's the most consistent file.
Other files have **real inconsistencies** (single-line function defs, semicolon-
chained statements, comment alignment) that `clang-format -i` will normalize.

Key settings and *why*:
- `SortIncludes: Never` — the code groups includes with comments
  (`#include <string.h>  /* memcpy... */`); LLVM's default sort would destroy
  these. `ReflowComments: false` for the same reason.
- `AlwaysBreakAfterReturnType: TopLevelDefinitions` +
  `AlwaysBreakAfterDefinitionReturnType: TopLevel` — return type on its own
  line. ⚠️ Note the enum values differ between the two options:
  `AlwaysBreakAfterReturnType` takes `TopLevelDefinitions`; the *Definition*
  variant takes `TopLevel` (NOT `TopLevelDefinitions` — clang-format errors).
- `BreakBeforeBraces: Allman` — `{` on its own line.
- `PointerAlignment: Right` — `mrb_state *mrb` (not `mrb_state* mrb`).

## Why clang-tidy is report-only (and scoped)

clangd's `--clang-tidy` is **OFF** in `opencode.json` (intentionally — it would
flag macro-heavy vendored code live). The manual `bin/lint` path runs clang-tidy
with `--header-filter='^mrbgems/.*/src/.*|^src/.*'` so only **our** headers'
diagnostics are displayed (vendored mruby/raylib/rmlui/flecs/joltc diagnostics
are suppressed — there are ~106,000 of them). Currently produces **zero findings**
in hand-written code.

clang-tidy is **never auto-fixed** (`bin/lint --fix` only touches RuboCop + clang-
format). clang-tidy's `-fix` can introduce subtle behavior changes; manual review
only.

## How the pieces fit together (the three layers)

| Layer | Tool | When | What it catches |
|-------|------|------|-----------------|
| **Syntax** | mruby-compiler gem | build time (`rake`) | parse errors |
| **Types** | Steep (RBS) | per-edit (LSP) | wrong arg type/arity to typed bindings |
| **Style/best-practice** | RuboCop + clang-format + clang-tidy | manual (`bin/lint`) | style inconsistencies, lint bugs |

## Adding/removing cops

- **Ruby:** edit `.rubocop.yml`. With `DisabledByDefault: true`, add
  `CopName: Enabled: true` to opt in. Verify with `rubocop --show-cops CopName`
  that the cop exists in your version (cop names drift across RuboCop versions —
  listing ~300 individual cops is fragile, which is why we use department-level
  `Layout: Enabled: true` / `Lint: Enabled: true` instead).
- **C/C++:** edit `.clang-format` (formatting) or the `--checks` list in
  `bin/lint` (clang-tidy). Verify clang-format with `clang-format --dump-config`.
