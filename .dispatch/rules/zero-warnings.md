# Zero warnings

- Your code must compile with `-Wall -Wextra` producing EXACTLY ZERO warnings.
- No `-w` suppression. No `(void)` casts to silence legitimate warnings unless
  you have a real reason (e.g. an unused parameter that must exist for a
  callback signature).
- The orchestrator will re-run `make` after you and will REJECT any warning —
  even ones from other files your code includes. If `raylib.h` or a system
  header triggers a warning, isolate it with platform guards.
- Run `make` yourself before reporting. The exit code must be 0.
- The build output is your trust signal. A clean build = a clean module.
