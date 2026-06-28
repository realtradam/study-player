# Tribal knowledge: LSP (ruby-lsp + clangd) under Dispatch

ruby-lsp targets **MRI** Ruby, but our game code is **mruby**. The LSP still works
well for navigation + RBS-backed intelligence, with formatter/linters disabled so
they don't false-positive on mruby. **clangd** serves the C/C++ mrbgem bindings
(`mrbgems/*/src/*`, `src/main.c`). This doc captures the non-obvious setup facts.

## Config source: `opencode.json`, NOT `dispatch.toml`

The **installed** Dispatch harness (`/usr/bin/dispatch-server`, the arch-rewrite
build) reads LSP config in this precedence (decompiled from the binary):

1. **`.dispatch/lsp.json`** — `{"servers": {<id>: {...}}}` format. Read FIRST and
   takes precedence. Machine-local (untracked).
2. **`opencode.json`** — `{"lsp": {<id>: {...}}}` format. Read ONLY when
   `.dispatch/lsp.json` yields no servers. **This is the tracked, template config.**
3. built-in TypeScript server (fallback if neither exists).

It does **NOT** read `dispatch.toml`'s `[lsp.*]` block for LSP — that's the *old*
dispatch-source architecture. If you see a `dispatch.toml` with `[lsp]`, it's dead
weight for the installed harness; the canonical config is `opencode.json`.

⚠️ If a broken `.dispatch/lsp.json` exists, it **shadows** the correct
`opencode.json`. Delete/fix `.dispatch/lsp.json` so `opencode.json` takes effect.

### Entry shape (the B6 parser fields)
Both formats use the same parser, which reads these keys (NOT the editor-style
`enabled`/`settings`):
`command` (array), `extensions` (array, with dot), `env` (object), `initialization`
(object), optional `name`, `rootMarkers`. So `opencode.json`'s `lsp.<id>` must
carry `command`+`extensions`+`env`+`initialization`.

## Why the env block is mandatory (two traps)

ruby-lsp composes a private bundle under `.ruby-lsp/Gemfile` (auto-created, gitignored)
and shells out to `bundle` on startup to install its own deps (ruby-lsp + `debug`,
which compiles a native ext). On this Arch box:

1. **`bundle` is not on the default PATH.** It lives in the user gem bin dir
   (`~/.local/share/gem/ruby/3.4.0/bin`); only the `ruby-lsp`/`rbs` *symlinks* are in
   `~/.local/bin`. The `env.PATH` MUST include the gem bin dir or ruby-lsp crashes
   with `Errno::ENOENT - bundle`.
2. **Without `GEM_HOME`, bundler installs into the root-owned system gem dir**
   (`/usr/lib/ruby/gems/3.4.0`) → `Bundler::PermissionError`. Set `GEM_HOME` (and
   `GEM_PATH`) to the user gem dir so installs are writable.

`env` REPLACES the inherited PATH (it merges onto `process.env`), so include the
full desired PATH. First-run does a one-time `bundle install` (compiles `debug`);
subsequent starts do `bundle check` (fast). The 4-hour `bundle update` check is
self-throttling.

## mruby-safe `initialization`

- `formatter: "none"`, `linters: []` — RuboCop/Syntax Tree target MRI and would
  false-positive on mruby. Diagnostics are off via `enabledFeatures.diagnostics`.
- Navigation + RBS intelligence ON: `hover`, `completion`, `definition`,
  `signatureHelp`, `documentSymbols`, etc.
- RBS lives in `sig/*.rbs` (raylib/rmlui/flecs/jolt/jamstack) — hand-written, gives
  hover/completion for the C/C++ mrbgem bindings. ruby-lsp auto-loads them.
- `rubyVersion: "3.4.0"` matches the host MRI (3.4.8) that runs ruby-lsp; mruby is a
  subset so 3.4 parsing won't choke on valid mruby.

## Sticky "broken" state (why a fixed config may still say `error`)

The harness's LSP manager keeps a `broken` set keyed by `<serverId>:<root>`. Once a
spawn fails, that id+root is marked broken for the **process lifetime** and never
retried — even after you fix the config. It only clears on server restart
(`shutdownAll`, on extension unload). So:

- If the *old* (broken, no-GEM_HOME) config poisoned `ruby-lsp:<root>`, fixing the
  config alone won't clear it in the running server — the lsp tool keeps reporting
  `state: error` ("Previously failed to start").
- **To verify a config fix in an already-running session without restarting**,
  temporarily add a server entry with a *different id* (e.g. `ruby-lsp-verify`); a
  fresh id → fresh key → clean spawn. Remove it once confirmed. The canonical id
  (`ruby-lsp`) recovers on the next server launch.

## How the harness drives ruby-lsp (verification cheatsheet)

- The harness sends `languageId: "unknown"` on didOpen — ruby-lsp maps that to
  `:ruby` (its `else` branch), so that's fine.
- The harness does **not** send `initializationOptions` in `initialize`; it pushes
  config via `workspace/didChangeConfiguration` + answers `workspace/configuration`.
  ruby-lsp's `enabledFeatures` then fall back to **all-enabled** defaults (fine).
- `documentSymbol` works immediately (pure parse). `hover` needs the index warm
  (loading the 72KB `sig/raylib.rbs` takes a few seconds after first spawn) — a
  fresh-spawn hover may return null until indexing settles; retry.
- Hover on stdlib (`Array#each`) resolves to `rbs` core + `vendor/mruby/mrblib/`;
  hover on the `Rl` module resolves to `mrbgems/raylib/mrblib/raylib.rb` + its docs.

## clangd for C/C++ (the mrbgem bindings)

`clangd` is at **`/usr/lib/llvm21/bin/clangd`** (not on PATH — use the absolute
path in `opencode.json`). The `opencode.json` `clangd` entry uses
`--background-index` (persistent cross-file index for definition/refs across the
6 C/C++ units) and `--log=error`. `--clang-tidy` is intentionally OFF (it would
flag the macro-heavy vendored code).

### compile_commands.json is REQUIRED (a `.clangd` alone is not enough)

clangd needs to know the include roots + `-DMRB_INT64`. The build is
Zig-orchestrated (`build.zig`) + mruby rake (`build_config.rb`) — neither emits
`compile_commands.json`. A `.clangd` `CompileFlags.Add` with relative `-Ivendor/...`
paths does **NOT** work: clangd resolves them against the compile working dir,
which for the no-compile-db fallback is the **file's own directory** (e.g. `src/`),
so `<mruby.h>` isn't found. (clangd does not resolve `.clangd` Add paths relative to
the config file in this version.)

Fix: **`tools/gen_compile_commands.rb`** emits `compile_commands.json` with
`directory` = the project root (absolute), so the relative `-I` resolve correctly.
One entry per source; C files `-std=c11`, the one C++ file (`rml_bindings.cpp`)
`-std=c++17`; all get `-DMRB_INT64` + the 5 include roots:
`vendor/{mruby/include, raylib/src, rmlui/Include, flecs/distr, joltc/include}`.
It also indexes the generated `raylib_gen.c` (for definition nav into the binding
surface — never hand-edit it).

- `compile_commands.json` is **gitignored** (it holds the absolute project root).
- **`rebuild.sh` regenerates it** after the build (so it picks up `raylib_gen.c`,
  which the mruby build generates). After a fresh clone, run `./rebuild.sh` (or
  `ruby tools/gen_compile_commands.rb`) once before opening C/C++ files.
- `.clangd` holds only `Index: StandardLibrary: No` (skip indexing the C++ stdlib
  to stay lean) + docs.
- Targets the **desktop** build. Web-only headers (`<emscripten.h>`) are guarded
  by `#ifdef __EMSCRIPTEN__` (not defined here), so clangd skips them.

### clangd does NOT suffer the sticky-broken issue here
clangd is a fresh server id (`clangd:<root>`), never poisoned by an old broken
config, so it connects immediately on first `.c`/`.cpp` open. Verified end-to-end
through the harness: `diagnostics` (0 errors), `hover` (`mrb_state` typedef),
`definition` (jumps to `vendor/mruby/include/mruby.h`), `documentSymbol` (full fn/var tree).
