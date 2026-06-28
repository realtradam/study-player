# RULE: link order — libmruby.a first

`libmruby.a` contains the `Rl::`/`Rml::`/`Flecs::` binding objects, which
reference symbols in libraylib.a, librmlui.a, and libflecs.a. So libmruby.a must
come **before** those native libs on the link line (it does, in `build.zig` and
`build_web.sh`). Getting this wrong = "undefined reference" at final link.

C++/unwinder note: link `/usr/lib/libstdc++.so` and `/usr/lib/libgcc_s.so.1`
directly. Do NOT use `linkSystemLibrary("stdc++")` — zig 0.16 substitutes its own
LLVM libc++ (wrong ABI; RmlUi/mruby-cxx-exceptions need GNU libstdc++).
