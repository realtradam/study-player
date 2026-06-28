# RULE: vendored C/C++ libs must NOT use GCC LTO

zig's linker is **lld**, which cannot link **GCC `-flto`** objects (GIMPLE
bytecode in `.gnu.lto_*` sections). Symptom: every symbol from the lib is
"undefined" at the final link, even though `nm` shows it as defined `T` (nm uses
the LTO plugin; `readelf -s`/`objdump -t` reveal the object has almost no real
symbols).

When a CMake dependency enables interprocedural optimization, turn it OFF:
`-DINTERPROCEDURAL_OPTIMIZATION=OFF` (Jolt) or `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF`.
(LLVM/emcc LTO is fine for the web build — this is specifically a GCC-LTO + lld
incompatibility.)
