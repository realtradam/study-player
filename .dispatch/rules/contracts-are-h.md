# Contracts are header files

- The `.h` file IS the contract between modules. Other agents read ONLY your
  `.h` — never your `.c`.
- Every `.h` must be **self-contained**: it includes all types it references.
  A consumer should be able to `#include "your_module.h"` and nothing else.
- Prefer **forward declarations** over full includes when only a pointer is
  needed. Example: `typedef struct PlayerState PlayerState;` avoids including
  `types.h`.
- A `.h` file must NOT include any `.c` file. Ever.
- If you expose a function, its full signature (return type, name, parameter
  types and names) must be in the `.h`. The documentation of what it DOES
  (preconditions, postconditions, side effects) goes in a comment in the `.h`
  — that is the contract's behavioral specification, not just its type
  signature.
- If an agent NEEDS to read your `.c` to understand what your module does,
  your `.h` contract is UNDESPECIFIED. Report this as a contract gap.
