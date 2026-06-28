# Steepfile — type-check the mruby game code (game/**) against the binding RBS
# signatures (sig/*.rbs), so real type errors (wrong arg type/arity to a typed
# Rl::/Rml::/Flecs::/Jolt:: call, calling a nonexistent method) get caught at
# dev time — without the editor noise ruby-lsp would make (ruby-lsp targets MRI
# and is not a type checker; Steep is the RBS type checker).
#
# The dynamic component values (Flecs structs <-> Ruby Hashes) are intentionally
# typed `untyped` in sig/flecs.rbs, so they flow without errors — only real
# mismatches against the typed binding surface are reported.
#
# Run:  steep check

target :game do
  # Our binding signatures (raylib.rbs generated; rmlui/flecs/jolt/jamstack.rbs
  # hand-written). RBS core (stdlib) is provided automatically by the rbs gem.
  signature "sig"

  # Type-check the game Ruby. Game code is un-annotated mruby *scripts* (top-level
  # constants/helpers/globals) — like test code. `lenient` downgrades the noise
  # that's inherent to un-annotated scripts + mruby's loose numeric tower
  # (UnknownConstant, NoMethod on top-level helpers, int-vs-Float, splats) to
  # :information/:hint so `steep check` is GREEN on correct code, while REAL
  # binding misuse still surfaces (as information/warning, non-failing). The
  # dynamic Flecs component values are `untyped` in sig/flecs.rbs, so they never
  # error. (default/strict would flood: every script constant/global/helper def is
  # an error.) Tighten to D::Ruby.default once game code gains RBS.
  configure_code_diagnostics(Steep::Diagnostic::Ruby.lenient)

  check "game"
end
