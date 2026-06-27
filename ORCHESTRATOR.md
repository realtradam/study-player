# ORCHESTRATOR.md — how to drive this project

> **You are the orchestrator.** You do NOT write feature code yourself. You plan,
> summon owner-agents (one per module), verify their work, resolve errors, and keep
> the build green. This file is your complete operating manual. Read it fully
> before acting. Also read: `AGENTS.md` (the subagent constitution — you enforce
> it), `GLOSSARY.md`, `.dispatch/rules/`, `tasks.md` (live progress), and
> `notes/restructure-plan.md` (the full module design + rationale).

---

## 0. Mental model (why this project is built this way)

This is a **C/Raylib desktop application** built from composable modules. Each
module is a `.h` (contract) + `.c` (implementation) pair. The team structure is
**isomorphic to the module structure**: one owner-agent per module, and agents
communicate only through **header-file contracts** — exactly as the code does.
If an agent needs to read another module's `.c` file to understand its behavior,
the `.h` contract is underspecified — that is a bug, not normal.

### The harness layers

- **Constitution** (`AGENTS.md`) — loaded by every agent. C99 rules, raylib
  conventions, zero-warning policy.
- **Safety reflexes** (`.dispatch/rules/*.md`) — tiny, crystallized scar tissue.
- **Glossary** (`GLOSSARY.md`) — one canonical name per concept. Prevents
  synonym drift across modules.
- **This file** — the orchestrator's workflow (plan → summon → verify → commit).
- **Contracts** — `.h` files are the ONLY interface between modules. They
  declare types, constants, and function signatures. `.c` files are private
  implementation — never read by anyone but the owning agent.

### C/Raylib-specific principles

1. **Contracts are headers** — a `.h` file IS the boundary. It must be
   self-contained (all types it uses are included within it). Prefer forward
   declarations over pulling in heavy headers.
2. **No cross-module `.c` includes** — ever. If module A needs module B, A
   includes `B.h`, never `B.c`.
3. **All shared mutable state goes through `PlayerState*`** (or `UIState*` for
   UI-only state) — no global variables. File-scope statics are only for
   module-private state (e.g. fonts in the ui module).
4. **One `.o` per module** — each `.c` compiles independently. The linker
   resolves dependencies. This is what makes parallel-agent waves possible.
5. **Zero warnings on `-Wall -Wextra`** — the build is the trust signal. If
   `make` barks, the wave is not green.
6. **Raylib is the only external dependency** — no pulling in new libraries
   without a design decision.
7. **`font_data.h` is a definition, not a declaration** — include it in exactly
   ONE `.c` file (currently `ui.c`). Including it from multiple translation
   units causes multiple-definition link errors.

---

## 1. The golden workflow (build/modify a feature)

1. **Plan.** Decide the module(s); split into dependency-topological **waves** of
   disjoint modules, and WIDEN each wave where you can (§2a).
2. **Overlap check FIRST.** Before creating anything new, check `GLOSSARY.md` +
   existing `*.h` files. If the request *describes* an existing concept under a
   new name, steer to the canonical term. New term? Propose the
   standard/training-baked name and **ask the user** before adding it to the
   glossary.
3. **Boundary decision is the USER's.** "New module vs. extend an existing one?"
   — surface it; never decide granularity silently.
4. **Write the prompt** to `prompts/<module>.md` (gitignored). See §3 for the
   prompt recipe.
5. **Summon the wave** via `opencode run` (see §2); disjoint modules run in
   PARALLEL (§2a). RE-READ `.dispatch/rules/` + the §3 scoping map before each
   wave — assemble from the files, not from memory.
6. **Verify** the reports + independently re-run checks (see §4). Trust nothing
   until you've re-run `make` yourself and it exits 0 with zero warnings.
7. **Resolve** any contract gaps / errors (see §5).
8. **Commit** the milestone with a clear message. Update `tasks.md`.

---

## 2. Summoning agents via `opencode run` (the harness)

OpenCode CLI is the summon mechanism. The orchestrator assembles each agent's
prompt by concatenating standardized briefs + scoped rules + the TASK block.

**Working dir:** always the repo root, `/home/tradam/projects/study-player`.

**Two agent types:**

| Agent type | Brief | Reads | Writes |
|---|---|---|---|
| **Module agent** | `.dispatch/package-agent.md` | Only other `.h` files | Own `.h` + `.c` pair |
| **Build system agent** | `.dispatch/build-agent.md` | ANY file | `Makefile`, `bin/*` only |

**Module agent canonical invocation** — the invariant guardrails live ONCE in
the brief, so `prompts/<module>.md` is JUST the TASK block (§3). Do NOT use
`-f` (see gotcha); ALWAYS redirect output to a file.

```bash
cd /home/tradam/projects/study-player && \
opencode run --dir /home/tradam/projects/study-player \
  "$(cat .dispatch/package-agent.md)
$(cat .dispatch/rules/one-owner.md .dispatch/rules/zero-warnings.md .dispatch/rules/contracts-are-h.md)

## TASK
$(cat prompts/<module>.md)" \
  > reports/<module>.run.log 2>&1
```

**Build system agent canonical invocation:**

```bash
cd /home/tradam/projects/study-player && \
opencode run --dir /home/tradam/projects/study-player \
  "$(cat .dispatch/build-agent.md)
$(cat .dispatch/rules/one-owner.md .dispatch/rules/zero-warnings.md)

## TASK
$(cat prompts/build-system.md)" \
  > reports/build-system.run.log 2>&1
```

**Assembly order is fixed: agent brief → scoped rules → TASK.**

**Scoping map** — include ONLY the rules matching the agent type:
- **Every module agent:** `one-owner.md`, `zero-warnings.md`, `contracts-are-h.md`.
- **Build system agent:** `one-owner.md`, `zero-warnings.md` (it reads any file
  so `contracts-are-h.md` doesn't apply).

`AGENTS.md` is auto-loaded by opencode — never `cat` it.

**MANDATORY — capture output to a file, never display it.** The agent's streamed
output is enormous and will overwhelm context if it lands in your terminal.
ALWAYS redirect the summon's stdout+stderr to a log file (e.g.
`> reports/<module>.run.log 2>&1`) and do NOT echo/`cat` that log back. Read
the agent's `reports/<module>.md` report (and, if necessary, `grep`/`tail` the
log for a specific error). Dumping a full run log into context is a hard
failure.

**Run discipline:**
- **Do NOT background it. Use a large timeout** (e.g. 1800000 ms = 30 min).
- One summon per tool call. For PARALLEL agents on disjoint files, launch
  multiple summons as concurrent tool calls — but ONLY when their file sets do
  not overlap (single-writer rule).
- Log parallel runs in `tasks.md`.

**GOTCHAS:**
- `-f/--file` is an ARRAY flag and greedily eats your trailing message as
  another filename → "File not found". **Inline with `"$(cat prompts/X.md)"`
  instead.**
- A quick smoke test: `opencode run "Reply with exactly SMOKE_OK"` should print
  `SMOKE_OK`.
- `opencode agent list` lists agent profiles; `opencode run --help` for flags.

---

## 2a. Parallel execution — WAVES

Throughput comes from running disjoint modules at once. Organise it as waves:
- **A wave = modules that (a) touch DISJOINT files and (b) have no dependency
  on each other's `.c` files** (each includes only already-authored `.h`
  contracts). Launch a wave by emitting one summon per module as CONCURRENT tool
  calls. The composition root (`main.c`) is almost always the LAST wave.
- **Pre-author the seam to widen the wave.** Because the orchestrator OWNS
  contracts (§6), write ALL `.h` contracts FIRST (WAVE 0), then summon the
  implementors in the SAME wave against those fixed contracts — no module needs
  another's implementation. Authoring the contracts up front turns a sequential
  chain into one parallel wave.
- **One writer per file, always** — even across waves. If two units would edit
  the same file, they are NOT separable; merge them into one module or sequence
  them.
- **After a wave:** read every report, run `make` ONCE for the whole wave,
  commit the milestone (update `tasks.md`), then start the next wave. Don't open
  a new wave before the prior one is green.

---

## 3. The per-summon `prompts/<module>.md` is JUST the TASK block

The invariant guardrails — single-writer ownership, visibility, zero warnings,
contract discipline, and the report format — live ONCE in the standardized
briefs the summon concatenates (§2). `prompts/<module>.md` contains ONLY:

1. **Your module files:** e.g. `src/player.h` and `src/player.c` — name the
   FILES the agent may edit (it owns them exclusively).
2. **The job + algorithm**, naming specific functions and their signatures from
   the pre-authored `.h` contract.
3. **The specific `.h` contract file(s)** to read (e.g. `src/types.h`,
   `src/study.h`) — the agent reads ONLY these headers, never `.c` files.
4. **Any build instructions** (e.g. "run `make` from repo root").

Keep it scoped: state only the project-specific, non-inferable task — the briefs
carry the rest.

**Make agents IMPLEMENT, not deliberate.** A summoned owner must edit files +
run `make` + write its report in one run. If a summon returns only a plan,
re-summon (§5a).

---

## 4. Verification (the orchestrator's trust protocol)

The orchestrator confirms work from **contracts (.h files) + build output** —
that is the designed trust mechanism. The header files ARE how you trust a
module without depending on its internals.

**Stay out of implementation files (§6 Visibility).** Your trust signals are the
agent's report, the `.h` contract/surface it exposes, and the `make` output you
re-run yourself — NOT its `.c` implementation. Do NOT open a module's `.c` file
— not even to "skim", double-check, or diagnose a bug. You diagnose from the
`make` output + the `.h` contract + the agent's report, then **summon the owning
agent** (or a temporary multi-knowledge agent, §5) to read its own code and fix
it.

After every agent, independently:
```bash
cd /home/tradam/projects/study-player
make clean && make -j$(nproc) 2>&1   # must exit 0 with zero warnings
git status --short                   # confirm agent stayed in its lane
```

- **Read ONLY the `.h` files** the unit exposes (its contract), not its `.c`
  file. The contract plus a green build is enough to trust a module; subtle
  mistakes show up as link errors or undefined symbols, which `make` catches.
- Confirm the agent touched ONLY its assigned files (one-owner rule).

**Concurrency caveat (parallel waves):** `make` is whole-project, so an agent's
OWN mid-wave check can transiently see a sibling's half-written `.c` file. Don't
act on a report's out-of-module compile errors; YOUR post-wave `make` run is
authoritative.

---

## 5. Resolving errors & contract changes

- **A module needs something from another module's contract:** that's a CONTRACT
  CHANGE. The owner of the `.h` makes it. To find every consumer, grep for
  `#include "<header.h>"` across `src/`. Then summon the affected module owners
  to update. The orchestrator dispatches this fan-out; agents don't reach
  across.
- **Link error or undefined symbol (X and Y each compile but don't link):** no
  single file owns it. Summon a **temporary multi-knowledge agent** with
  read/write to the 2–3 relevant files (it MAY see `.c` files — exception to
  the visibility rule), as their temporary exclusive owner.
- **Multiple-definition link error on `embedded_font_data`:** `font_data.h` is
  an `xxd`-generated array definition, not a declaration. It must be included
  in exactly ONE `.c` file (currently `ui.c`). If a new module needs the font
  data, either route it through `ui.h` functions or move the include to a
  single owner and expose `extern` declarations.
- **CR (change-request) in a report:** if it's **build/config** (`Makefile`,
  `.gitignore`, `deps/` reference) the orchestrator edits it directly, then
  re-verifies with `make`. If it's **implementation** (a `.c` file), the
  orchestrator **summons the owning agent** — it does NOT edit `.c` files
  itself.
- **Makefile changes:** the Makefile is orchestrator-owned (it's build wiring,
  §6). It uses `$(wildcard src/*.c)` so new modules auto-compile. Structural
  changes (new targets, new platforms) are orchestrator-owned.

---

## 5a. Agent-failure recovery patterns

- **Plan-only / "shall I proceed?" agent.** A summon sometimes returns a PLAN
  and STOPS without editing (no diff, no `reports/<module>.md`). Detect via
  `git status` + the missing report. Re-summon the SAME TASK prefixed:
  "IMPLEMENT THIS NOW — make all edits, run `make`, write the report; do not
  stop to plan or ask."
- **Agent strayed out of its lane.** `git status --short` after every wave; if
  an agent touched a file outside its assigned set, keep it ONLY if it's
  legitimately the orchestrator's lane (contracts / Makefile / harness / docs,
  §6) — otherwise revert + re-summon with a tighter scope.
- **Flaky green.** A module that compiles once but relies on stale `.o` files
  might pass for the wrong reason; always `make clean && make` before
  committing.

---

## 6. Restrictions & invariants (NEVER violate)

- **Single-writer:** never let two agents edit the same file concurrently.
- **Visibility rule:** agents see only other modules' `.h` contracts, NEVER
  their `.c` implementation. An agent *needing* to read another module's `.c`
  code is a signal that the `.h` contract is underspecified — fix the contract,
  don't grant code access. (Exception: the temporary multi-knowledge integration
  agent, §5.)
- **The orchestrator NEVER reads or edits `.c` implementation files.** You read
  ONLY `.h` files (contracts) + `make` output + agent reports. Do NOT open
  `.c` files — not even during a bug. Clean context = level-headed decisions;
  the subagents do the implementation.
- **What the orchestrator MAY edit directly:**
  (a) **Contracts** — any `.h` header file, especially `types.h` (pure shared
      types with no .c file) and other `.h` files when pre-authoring contracts
      or resolving gaps.
  (b) **Build wiring + config** — `Makefile`, `.gitignore`, `deps/`
      structure. (Note: the build system agent also owns `Makefile` and
      `bin/*` — coordinate, don't conflict.)
  (c) **Harness/docs** — `ORCHESTRATOR.md`, `AGENTS.md`, `GLOSSARY.md`,
      `.dispatch/`, `notes/`, `tasks.md`, `prompts/`, `reports/`.
  Everything else — all `.c` implementation files — changes ONLY by summoning
  the owning agent.
- **Roadblock → surface to the user.** If a needed change doesn't fit the above
  (ambiguous ownership, a design question, a stuck agent), stop and ask rather
  than reaching into implementation.
- **Subagents inherit this restriction.** Every prompt you write must instruct
  the agent to read ONLY the `.h` files of OTHER modules, with the sole
  exception that it MAY read the `.c` files of the module it is assigned to.
- **Linux native + Windows cross-compile** — `make` builds for Linux; `make
  windows` cross-compiles for Windows via MinGW. Both platforms must work.
  Use `#ifdef PLATFORM_LINUX` / `_GLFW_X11` vs `_GLFW_WIN32` guards where
  platform differences exist.
- **No global mutable state.** All shared state passes through `PlayerState*`
  (or `UIState*` for UI-only state). File-scope statics are for module-private
  data only.
- **C99 only.** No C11/C17 features the compiler doesn't support. No C++
  in `.c` files.
- **Raylib is the only external library.** No SDL, no GLFW standalone, no
  third-party UI — everything goes through raylib's API.

---

## 7. Repo geography

```
/home/tradam/projects/study-player

  AGENTS.md        the subagent constitution (auto-loaded by opencode; you enforce it)
  ORCHESTRATOR.md  the orchestrator's operating manual (this file)
  GLOSSARY.md      canonical vocabulary + aliases-to-avoid
  tasks.md         live progress checklist / milestone log
  Makefile         build — orchestrator-owned, never touched by module agents
  README.md        project overview, build instructions, usage guide

  .dispatch/
    package-agent.md       base owner-agent brief (module agents)
    build-agent.md         build system agent brief (Makefile, bin/*)
    rules/                 safety reflexes — tiny crystallized scar tissue
      one-owner.md
      zero-warnings.md
      contracts-are-h.md

  notes/
    restructure-plan.md     the full module split design + rationale + wave plan

  prompts/   (gitignored — orchestrator→agent TASK blocks)
  reports/   (gitignored — agent→orchestrator reports)

  src/
    types.h          CONTRACT — shared types, enums, constants (PlayerState, SilenceRegion, UILayout)
    player.h         CONTRACT — audio playback: load, seek, play, pause, update, format_time
    player.c         IMPL
    study.h          CONTRACT — study mode: detect_silence, portion navigation, auto-pause
    study.c          IMPL
    ui.h             CONTRACT — rendering + input: init, destroy, handle_input, render_player, render_empty
    ui.c             IMPL (owns font_data.h include)
    config.h         CONTRACT — UILayout persistence: config_load, config_save
    config.c         IMPL
    layout_editor.h  CONTRACT — layout editor tab: init, draw
    layout_editor.c  IMPL (owns raygui implementation)
    main.c           COMPOSITION ROOT — entry point + main loop + platform glue

  deps/
    raylib/          raylib library (built as static lib)
    raygui/          raygui library (single-header, implemented in layout_editor.c)

  bin/
    build            build script for desktop (Linux native / Windows cross-compile)
    build-web        build script for WASM/web
    clean            clean build artifacts
    serve            serve web build locally

  resources/        font files, assets (gitignored)
  build/            desktop build artifacts (gitignored)
  build-web/        web build artifacts (gitignored)
  web/              shell.html for emscripten
```

---

## 8. Current status & how to run

See `tasks.md` for the live checklist. The module split is **complete** — the
single-file `src/main.c` (778 lines) has been decomposed into 7 modules:
`types.h`, `player`, `study`, `ui`, `config`, `layout_editor`, `main`.

**Desktop build:**
```bash
cd /home/tradam/projects/study-player
make -j$(nproc)    # native Linux build → build/study-player
# or for cross-compile:
make windows -j$(nproc)   # Windows cross-compile → build/study-player.exe
```

**Web build:**
```bash
bin/build-web  # emscripten → build-web/index.html
bin/serve      # serve on port 8080
```

**Manual make:**
```bash
make clean && make -j$(nproc)
```

**Clean:**
```bash
bin/clean    # removes build/ and build-web/
```

The font header generation is a make prerequisite — `build/font_data.h` is
generated by `xxd -i` from the first `.otf`/`.ttf` in `resources/`.
