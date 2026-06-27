# tasks.md — live progress checklist

> Updated by the orchestrator after each milestone. One line per completed wave.

---

## WAVE 0 — Orchestrator + build system agent

- [ ] Orchestrator: write `src/types.h` (shared types, constants)
- [ ] Orchestrator: pre-author `src/player.h` (audio playback contract)
- [ ] Orchestrator: pre-author `src/study.h` (study mode contract)
- [ ] Orchestrator: pre-author `src/ui.h` (rendering + input contract)
- [ ] Orchestrator: write TASK prompts in `prompts/`
- [ ] Build agent: update `Makefile` (Linux native + Windows cross-compile targets)
- [ ] Build agent: update `.gitignore` (add `prompts/`, `reports/`)

## WAVE 1 — All `.c` implementations (parallel)

- [ ] Agent A: implement `src/player.c` from `player.h` contract
- [ ] Agent B: implement `src/study.c` from `study.h` contract
- [ ] Agent C: implement `src/ui.c` from `ui.h` contract
- [ ] Agent D: implement `src/main.c` (composition root)

## WAVE 2 — Integration fixes (if needed)

- [ ] Fix any link errors or behavioral regressions

## Post-milestone

- [ ] `make clean && make -j$(nproc)` exits 0, zero warnings (Linux)
- [ ] `make windows -j$(nproc)` exits 0, zero warnings (Windows cross-compile)
- [ ] Functional test: play an MP3, test all keyboard shortcuts, study mode, UI
- [ ] Commit: `refactor: split src/main.c into modular .h/.c files`

---

## Open items (future)

- [ ] `bin/build` and `bin/build-web` scripts can be retired or simplified
- [ ] Test coverage (unit tests for study module?)
- [ ] Volume control
- [ ] Playlist support
- [ ] Config file / persistence
