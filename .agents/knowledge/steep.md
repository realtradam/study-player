# Tribal knowledge: Steep — the RBS type checker

[Steep](https://github.com/soutaro/steep) is the **RBS type checker** (ruby-lsp is
NOT — it consumes RBS for hover/completion only; type *checking* is Steep's job).
It type-checks `game/**` against `sig/*.rbs` so real binding misuse (wrong arg
type/arity to a typed `Rl::`/`Rml::`/`Flecs::`/`Jolt::` call, calling a nonexistent
method) gets caught at dev time. Compatible with the installed `rbs` 4.0.3
(`steep 2.0.0` requires `rbs ~> 4.0`).

## At a glance
- **Key files:** `Steepfile` (project + `lenient` config); `opencode.json` `lsp.steep`
  (the LSP wiring); `sig/*.rbs` (the signatures); `tools/check-types.sh` (the gate);
  `mrbgems/raylib/tools/gen_rbs.rb` (generates `sig/raylib.rbs`).
- **Commands:** `./tools/check-types.sh` (gate: `rbs validate` + `steep check`);
  `steep check --severity-level=information` (see the info-level typos).
- **Cross-refs:** `.agents/knowledge/ruby-lsp.md` (shares the gem env + LSP
  harness), `testing.md`, `build-and-verify` skill, `HANDOFF-per-edit-diagnostics.md`.

## Install
`gem install steep` (into the user gem dir `~/.local/share/gem/ruby/3.4.0`, where
`rbs` 4.0.3 already lives). No Arch package; pure-Ruby deps, no native ext. The
`steep` binary shebang is `#!/usr/bin/ruby`, so it needs `GEM_HOME`/`GEM_PATH` set
to the user gem dir to load `steep` + `rbs` — `tools/check-types.sh` and the
`opencode.json` env both set this.

## Why `lenient` (the Steepfile config)
Game code is un-annotated mruby *scripts* (top-level constants/helpers/globals) +
mruby's auto-coercing numerics vs RBS's strict numeric tower. Under
`D::Ruby.default`/`strict`, EVERY script constant/global/helper-def is an error
(first run: 442 diagnostics, 78 errors — all false positives; the code is correct).
`configure_code_diagnostics(Steep::Diagnostic::Ruby.lenient)` downgrades that noise
to `:information`/`:hint` so `steep check` is **GREEN (exit 0)** on correct code,
while real binding misuse still surfaces as `:information`/`:warning` (visible,
non-failing). The dynamic Flecs component values are `untyped` in `sig/flecs.rbs`,
so they never error. Tighten to `D::Ruby.default` once game code gains its own RBS.

## Editor vs gate (the split)
- **Editor (live):** Steep is wired as a 3rd LSP (`opencode.json` `lsp.steep`,
  `steep langserver --steepfile=<abs>`). On a `.rb` edit, `publishDiagnostics`
  (PUSH model — Steep does NOT implement `diagnosticProvider`/pull) surfaces real
  typos live, tagged `[steep]`. ruby-lsp (`diagnostics:false`) gives
  hover/completion; Steep gives type diagnostics. The harness must **aggregate
  `publishDiagnostics` across all matching servers** (ruby-lsp + steep both claim
  `.rb`) — see `HANDOFF-per-edit-diagnostics.md`.
- **Gate (`tools/check-types.sh`):** `rbs validate` (sig consistency, HARD FAIL) +
  `steep check` (project loads clean, no `:error`). It is GREEN on correct code and
  does NOT hard-fail on game-code typos (those are `:information`, editor-visible) —
  so it catches signature/structural breakage, not gameplay typos.

## The numeric-type wart (decision)
`gen_rbs.rb` maps C `float`/`double` *inputs* (params, struct fields) → `Float | Integer`
(returns stay `Float`). Why: mruby's `f` (`mrb_float`) format auto-converts
`Integer`→`Float`, so `Vector3.new(18,14,18)` is idiomatic and fine; `Float` alone
would reject int literals. Alternatives considered: `Numeric` (breaks arithmetic —
RBS core `Numeric` doesn't declare `*`/`/`/`**`); `Float` (rejects int literals).
**Wart:** RBS's numeric tower widens `**`/some `/` and camera-math (`Math.sin` → …)
to `Complex`, which then won't fit `Float | Integer` params — surfacing as
`:information` `ArgumentTypeMismatch` (17 on the current game code, non-failing under
lenient). mruby's auto-coercing numerics don't map cleanly to RBS's strict tower;
`Float | Integer` is the best fit and the wart is accepted (documented in
`gen_rbs.rb`'s `rtype` comment).

## `.rbs` signature files get no live diagnostics
Steep's langserver only `publishDiagnostics` for files in the `check` target
(`.rb` under `game/`), NOT for signature files — editing `sig/*.rbs` shows nothing
live (sigs are type-environment inputs, not checked documents). Catch sig errors via
`rbs validate` / `steep check` (CLI) instead. (CLI `steep check`/`rbs validate` DO
report sig errors — e.g. the duplicate `key_pressed?` below was found that way.)

## Scar tissue (bugs found + fixed while setting this up)
- **Duplicate `key_pressed?` in the generated `sig/raylib.rbs`** (`RBS::DuplicatedMethodDefinition`):
  the JSON emitted `IsKeyPressed`→`key_pressed?` `(Integer key)` AND the hand-written
  sugar emitted `key_pressed?` `(untyped key)`. The sugar is correct (mrblib's
  `resolve_key` accepts Symbol keys). Fix: added `IsKeyDown/IsKeyPressed/
  IsKeyReleased/IsKeyUp` to `SUGAR_OVERRIDE` in `gen_rbs.rb` so only the sugar survives.
  (`rbs validate` did NOT catch this; `steep check` did — Steep is stricter on dups.)
- **`ModuleSelfTypeError` in `sig/flecs.rbs`** from `include Enumerable[untyped]`:
  `Query#each` yields `(entity_id, *component_hashes)` — a multi-arg yield that can't
  satisfy Enumerable's single-`Elem` contract. Fix: removed `include Enumerable`
  from the RBS (the Ruby class still mixes it in at runtime; only `each` is documented).
- **Warm-up latency:** the first `lsp diagnostics`/edit after a fresh spawn is slow
  while Steep indexes `sig/*.rbs` (incl. the 1328-line `raylib.rbs`) and forks its ~10
  worker processes. Subsequent calls are faster. Don't report "no diagnostics"
  prematurely on a fresh spawn — it may still be indexing.

## Verify
`./tools/check-types.sh` — green on correct code. To SEE the info-level typos:
`steep check --severity-level=information` (note: that flag makes steep exit 1
because info-noise always exists on un-annotated scripts — it's for visibility, not a gate).
