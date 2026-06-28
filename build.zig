const std = @import("std");

// Unified build: `zig build` orchestrates the whole desktop stack.
//   1. raylib  -> vendor/raylib/src/libraylib.a            (make, once)
//   2. RmlUi   -> vendor/rmlui/build-static/librmlui.a      (cmake, once)
//   3. mruby   -> vendor/mruby/build/host/lib/libmruby.a    (rake, every build:
//                 embeds our Rl::/Rml:: bindings, so it tracks binding changes)
//   4. compile src/main.c and link everything.
//
// The vendored libs (1,2) are guarded so they only build when missing; mruby (3)
// runs every time (rake is itself incremental). See BUILDING.md.
//
// Wayland backend is used because WSLg's X11/GLX path segfaults in Mesa; for a
// normal X11 desktop, swap the wayland-* libs for "X11" and rebuild raylib
// without the GLFW_LINUX_ENABLE_WAYLAND flags.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- dependency build steps (system commands) ------------------------------
    // Desktop raylib -> build/desktop/libraylib.a. raylib shares .o files in src/
    // across platforms, so `make clean` first to avoid picking up wasm objects
    // from a prior web build. Guarded on the desktop lib so it only builds once.
    const raylib_lib = b.addSystemCommand(&.{
        "sh", "-c",
        "r=\"$PWD\"; mkdir -p \"$r/build/desktop\"; " ++
            "[ -f \"$r/build/desktop/libraylib.a\" ] || (" ++
            "cd vendor/raylib/src && make clean >/dev/null 2>&1; " ++
            "make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC " ++
            "GLFW_LINUX_ENABLE_WAYLAND=TRUE GLFW_LINUX_ENABLE_X11=FALSE -j4 " ++
            "RAYLIB_RELEASE_PATH=\"$r/build/desktop\")",
    });

    // flecs (ECS): compile the single-file amalgamation to a static lib once.
    const flecs_lib = b.addSystemCommand(&.{
        "sh", "-c",
        "r=\"$PWD\"; mkdir -p \"$r/build/desktop\"; " ++
            "[ -f \"$r/build/desktop/libflecs.a\" ] || (" ++
            "cc -c -O2 -std=gnu99 -DNDEBUG -I vendor/flecs/distr " ++
            "vendor/flecs/distr/flecs.c -o build/desktop/flecs.o && " ++
            "ar rcs build/desktop/libflecs.a build/desktop/flecs.o)",
    });

    // Jolt Physics via joltc (C API). CMake builds libjoltc.a + libJolt.a, which
    // we then MERGE into a single build/desktop/libjoltphysics.a. The merge is
    // important: libmruby (Jolt:: bindings) -> libjoltc -> libJolt is a 3-archive
    // chain that lld's single pass won't resolve; one combined archive (like
    // libflecs.a) resolves all cross-references. Jolt v5.5.0 is taken locally from
    // vendor/JoltPhysics; profiler/debug-renderer are disabled to stay lean.
    const jolt_lib = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p build/desktop; [ -f build/desktop/libjoltphysics.a ] || (" ++
            "[ -f vendor/joltc/build-static/lib/libjoltc.a ] || (" ++
            "cmake -S vendor/joltc -B vendor/joltc/build-static " ++
            "-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DJPH_BUILD_SHARED=OFF " ++
            "-DJPH_SAMPLES=OFF -DJPH_TESTS=OFF -DJPH_INSTALL=OFF " ++
            // LTO OFF: Jolt defaults to GCC -flto, whose GIMPLE-bytecode objects
            // lld (zig's linker) cannot link. OFF produces native objects.
            "-DINTERPROCEDURAL_OPTIMIZATION=OFF " ++
            "-DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF -DDEBUG_RENDERER_IN_DISTRIBUTION=OFF " ++
            "-DPROFILER_IN_DEBUG_AND_RELEASE=OFF && " ++
            "cmake --build vendor/joltc/build-static --target joltc -j4); " ++
            "rm -rf build/desktop/jolt_obj && mkdir -p build/desktop/jolt_obj && " ++
            "(cd build/desktop/jolt_obj && " ++
            "ar x ../../../vendor/joltc/build-static/lib/libjoltc.a && " ++
            "ar x ../../../vendor/joltc/build-static/lib/libJolt.a && " ++
            "ar rcs ../libjoltphysics.a *.o) && rm -rf build/desktop/jolt_obj)",
    });

    const rmlui_lib = b.addSystemCommand(&.{
        "sh", "-c",
        "[ -f vendor/rmlui/build-static/librmlui.a ] || (" ++
            "cmake -S vendor/rmlui -B vendor/rmlui/build-static " ++
            "-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF " ++
            "-DRMLUI_SAMPLES=OFF -DRMLUI_LUA_BINDINGS=OFF -DRMLUI_FONT_ENGINE=freetype && " ++
            "cmake --build vendor/rmlui/build-static --target rmlui_core -j4)",
    });

    // mruby (with our mrbgems). Prepend the user gem bin so `rake` resolves to the
    // Linux gem (not a Windows rake on /mnt/c under WSL). Target the .a path so
    // mruby's own CLI tools (which don't link raylib) aren't built.
    const mruby_lib = b.addSystemCommand(&.{
        "sh", "-c",
        "export PATH=\"$(ruby -e 'puts Gem.user_dir')/bin:$PATH\"; " ++
            "export JAMSTACK_ROOT=\"$PWD\"; " ++
            "export MRUBY_CONFIG=\"$PWD/build_config.rb\"; " ++
            "cd vendor/mruby && rake \"$JAMSTACK_ROOT/vendor/mruby/build/host/lib/libmruby.a\"",
    });

    // --- the game executable ---------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-DMRB_INT64" },
    });

    // mruby headers + static lib (embeds the Rl::/Rml:: bindings mrbgems)
    exe.root_module.addIncludePath(b.path("vendor/mruby/include"));
    exe.root_module.addObjectFile(b.path("vendor/mruby/build/host/lib/libmruby.a"));

    // raylib static lib (desktop)
    exe.root_module.addIncludePath(b.path("vendor/raylib/src"));
    exe.root_module.addObjectFile(b.path("build/desktop/libraylib.a"));

    // flecs static lib (desktop). libmruby.a holds the Flecs:: bindings that
    // reference these symbols, so it must precede this in link order (it does).
    exe.root_module.addIncludePath(b.path("vendor/flecs/distr"));
    exe.root_module.addObjectFile(b.path("build/desktop/libflecs.a"));

    // Jolt Physics (C++): single merged archive (joltc C API + Jolt impl).
    exe.root_module.addIncludePath(b.path("vendor/joltc/include"));
    exe.root_module.addObjectFile(b.path("build/desktop/libjoltphysics.a"));

    // RmlUi static lib (C++) + its deps. libmruby.a (above) holds the Rml::
    // bindings that reference these symbols, so it must precede this in link order.
    exe.root_module.addObjectFile(b.path("vendor/rmlui/build-static/librmlui.a"));
    exe.root_module.linkSystemLibrary("freetype", .{});
    // RmlUi is built with GNU libstdc++; link it directly. (Do NOT use
    // linkSystemLibrary("stdc++") — zig 0.16 substitutes its own LLVM libc++,
    // which lacks the libstdc++ ABI symbols RmlUi needs.)
    exe.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/libstdc++.so" });
    // GCC unwinder (_Unwind_Resume) — mruby is built with C++ exceptions enabled
    // (MRB_USE_CXX_EXCEPTION) because a C++ mrbgem (rmlui) is present.
    exe.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/libgcc_s.so.1" });

    // system libraries needed by raylib (desktop GLFW/Wayland) and mruby
    exe.root_module.linkSystemLibrary("GL", .{});
    exe.root_module.linkSystemLibrary("EGL", .{});
    exe.root_module.linkSystemLibrary("m", .{});
    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("dl", .{});
    exe.root_module.linkSystemLibrary("rt", .{});
    // Wayland backend (WSLg-friendly; avoids the broken Mesa GLX path)
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("wayland-cursor", .{});
    exe.root_module.linkSystemLibrary("wayland-egl", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});

    // link only after the dependency libs are built
    exe.step.dependOn(&raylib_lib.step);
    exe.step.dependOn(&flecs_lib.step);
    exe.step.dependOn(&jolt_lib.step);
    exe.step.dependOn(&rmlui_lib.step);
    exe.step.dependOn(&mruby_lib.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setCwd(b.path(".")); // so game/main.rb resolves
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the game");
    run_step.dependOn(&run_cmd.step);
}
