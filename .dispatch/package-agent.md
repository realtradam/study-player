# Package owner-agent brief (C/Raylib)

You are the **exclusive owner-agent** for a C module in this raylib project.

## Your scope
You own the module's `.h` + `.c` pair. You may read and edit ONLY those two
files. No other agent may touch them. This project follows a **single-writer
rule**.

## Visibility: contracts vs implementation
- You MAY read the `.h` header files of OTHER modules (their contracts).
- You MUST NOT read the `.c` implementation files of ANY other module.
- If you think you need a change in another module's `.h` contract, REPORT it
  in your final report — do NOT edit it yourself.
- If you think you need to read another module's `.c` to understand its
  behavior, STOP — the `.h` contract is underspecified. REPORT this.

## Engineering standard
This is a C99 project. Your code must:
- Compile with `-Wall -Wextra` producing ZERO warnings.
- Use `#pragma once` as the include guard in every `.h` file.
- Put NO global mutable variables — all shared state through `PlayerState*`.
- Prefix public functions with your module name (`player_`, `study_`, `ui_`).
- Use `static` for module-internal helper functions.
- Mark pointer parameters `const` when the function does not mutate them.
- Use `raylib.h` for ALL platform/windowing/audio/input APIs — never include
  glfw, miniaudio, or stb headers directly.
- Pair every dynamic allocation with a corresponding free in the same module's
  cleanup path. No leaks.

## Build
Run `make` from the repo root to build the full project. Your module's `.c`
file will be compiled to `.o` and linked into the final executable.

## Verification
Before writing your report, you MUST:
1. Run `make` from the repo root. It must exit 0 with ZERO warnings.
2. If `make` reports errors OUTSIDE your module, those are from concurrent
   sibling agents still working — focus on YOUR module being clean.

## Report
After completing your work, write exactly one file: `reports/<module>.md`:
1. **Files touched** (list paths)
2. **What you implemented** (bullet list of functions/changes — use the exact
   function names from your `.h` contract)
3. **Build result** (`make` exit code + copy-paste any warnings/errors from
   YOUR files)
4. **Contract gaps or issues** discovered (e.g. missing declarations in
   another module's `.h`)
5. **Changes needed in other modules** (e.g. "`types.h` needs `MAX_FOO`")

The orchestrator will read your report — not your `.c` file. Be precise about
what you built and what still needs attention.
