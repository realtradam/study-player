---
name: add-knowledge
description: Use right after discovering a new gotcha, ABI trap, naming rule, or repeatable workflow in this repo, to decide WHERE to crystallize it (rule vs knowledge doc vs glossary vs skill) so the scar tissue is captured, not lost. Invoke whenever you think "I should write this down."
---

# Crystallize new tribal knowledge

The harness only stays valuable if discoveries get written down in the right
layer. Pick the destination by what kind of thing you learned.

## Where it goes

- **A short, always-true safety reflex** that prevents an expensive mistake
  (build-breaker, data/ABI corruption, lost work) → a tiny new file in
  `.agents/rules/<name>.md`. Rules are skimmed **every session**, so keep them to a
  few lines: the rule, the symptom, the fix.
- **Anything about ONE area — what it is and its key files/API surface, OR the deep
  "why X breaks" detail** → the matching `.agents/knowledge/<area>.md` (build-system,
  environment, raylib/rmlui/flecs/jolt-binding, web-target, testing). It is the
  **single** per-area home: an "At a glance" orientation header up top, the tribal
  gotchas below. If the area has no doc yet, write it **first** — it doubles as the
  Plan-Mode brief. Loaded only when touching that area.
- **A new term, or a synonym that keeps drifting** → add a row to `GLOSSARY.md`
  (Term | Meaning | Aliases to avoid).
- **A repeatable multi-step procedure** you'll forget → a new
  `.agents/skills/<name>/SKILL.md`.

## Rules of thumb

- **Document only the non-inferable (P2).** If a frontier model could infer it from
  the code, leave it out. Tribal traps are gold; generic advice is noise.
- Keep entries **short and THIS-repo-specific**. Cross-link between layers; never
  duplicate (a doc points to the spec/rule, it doesn't copy it).
- Prefer the smallest always-loaded layer that fits: a one-line rule beats a buried
  paragraph for anything that breaks builds.

## Cross-refs
- `AGENTS.md` ("READ THE TRIBAL KNOWLEDGE FIRST") · `roadmap.md` (principles P1–P7)
- Layer definitions: glossary section "Harness layers"
