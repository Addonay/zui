const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options for the text engine: the deterministic vendored corpus
    // path the tests derive their font directory from. There is no engine
    // switch any more: text is always cozmic.
    const build_options = b.addOptions();

    // AccessKit accessibility bridge (gap report §5C / §7): vendored C-ABI
    // library built from third_party/accesskit with cargo. Default OFF so
    // plain `zig build` never requires a Rust toolchain; enable with
    // -Daccesskit=true (see docs/A11Y_PLAN.md for the runtime story).
    const enable_accesskit = b.option(bool, "accesskit", "Enable the AccessKit accessibility bridge (builds the vendored library with cargo)") orelse false;
    build_options.addOption(bool, "accesskit", enable_accesskit);

    // Standalone layout-engine package, fetched from
    // https://github.com/Addonay/zlay (pinned by commit in build.zig.zon).
    // The `zlay` module is aliased to `layout` so every existing
    // `@import("layout")` call site and the package-boundary test below stay
    // unchanged. `-Dserde=true` is forwarded to the package, which owns its
    // optional serde dependency; run the package's own gates with:
    //   cd ../zlay && zig build test [ -Dserde=true ]
    const enable_serde = b.option(bool, "serde", "Enable Taffy-compatible JSON serde in the layout package") orelse false;
    const zlay_dep = b.dependency("zlay", .{
        .target = target,
        .optimize = optimize,
        .serde = enable_serde,
    });
    const layout_mod = zlay_dep.module("zlay");

    // Cozmic text engine (published package: https://github.com/Addonay/cozmic,
    // pinned in build.zig.zon). The `layout` module deliberately keeps no
    // cozmic dependency.
    const cozmic_dep = b.dependency("cozmic", .{
        .target = target,
        .optimize = optimize,
    });
    // Deterministic test corpus shipped inside the fetched package. Passing a
    // file from it (directories cannot be hashed by the options step) lets the
    // tests derive the corpus directory, so no `.ports/cozmic` checkout is
    // required at runtime.
    build_options.addOptionPath("cozmic_corpus_font", cozmic_dep.path("tests/fonts/Inter-Regular.ttf"));

    // Vello-derived 2D renderer (published package:
    // https://github.com/Addonay/vellz, pinned in build.zig.zon). CPU-first
    // rendering library; its GPU backend and the wgpu dependency are lazy and
    // are never resolved by zui's CPU build.
    const vellz_dep = b.dependency("vellz", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "zlay", .module = layout_mod },
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
            .{ .name = "vellz", .module = vellz_dep.module("vellz") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // Vendored C image backends (nanosvg + stb_image, zero deps).
    mod.addIncludePath(b.path("third_party"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/images.c"),
        .flags = &.{ "-O2", "-std=c99", "-fno-sanitize=all" },
    });

    // AccessKit: the vendored C-ABI library is built with cargo from
    // third_party/accesskit (Rust crate `accesskit-c`, static + shared);
    // the header is translated to the `accesskit_c` import. Artifacts land
    // under third_party/accesskit/target/release (gitignored). Only the
    // `zui` module links it; consumers get it transitively.
    if (enable_accesskit) {
        const ak_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("third_party/accesskit/include/accesskit.h"),
            .target = target,
            .optimize = optimize,
        });
        const ak_lib = b.addSystemCommand(&.{ "cargo", "build", "--release" });
        ak_lib.setCwd(b.path("third_party/accesskit"));
        mod.addImport("accesskit_c", ak_translate_c.createModule());
        mod.addLibraryPath(b.path("third_party/accesskit/target/release"));
        mod.linkSystemLibrary("accesskit", .{ .needed = false });
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const adapter_tests = b.addTest(.{ .root_module = mod, .filters = &.{"adapter"} });
    const run_adapter_tests = b.addRunArtifact(adapter_tests);
    const adapter_test_step = b.step("test-zlay", "Run focused adapter agreement and grid regression tests");
    adapter_test_step.dependOn(&run_adapter_tests.step);

    // Compile the layout module as its own root as well. This catches
    // accidental dependencies on the wider ZUI surface and documents the
    // supported `@import("layout")` package boundary.
    const layout_tests = b.addTest(.{
        .root_module = layout_mod,
    });
    const run_layout_tests = b.addRunArtifact(layout_tests);

    const test_step = b.step("test", "Run zui unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_layout_tests.step);

    const use_llvm = b.option(bool, "use-llvm", "use llvm for compilation");

    const todo = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/todo/daybook.zig"), .target = target, .optimize = optimize, .imports = &.{.{
            .name = "zui",
            .module = mod,
        }}, .strip = true }),
        .use_llvm = use_llvm,
    });
    const run_todo = b.addRunArtifact(todo);

    const run_todo_step = b.step("run-todo", "Run the todo example");
    run_todo_step.dependOn(&run_todo.step);

    // Embedded unit tests in the todo example (pure-model tests). Without
    // this, `zig build test` silently skips them.
    const todo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/todo/daybook.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = mod }},
        }),
    });
    const run_todo_tests = b.addRunArtifact(todo_tests);
    test_step.dependOn(&run_todo_tests.step);

    // Headless integration: drive the real event queue -> App -> Window ->
    // hit-test -> listener path with synthetic input (plan M0). Needs the
    // demo seed for its 3-todo fixture.
    const selftest_todo = b.addRunArtifact(todo);
    selftest_todo.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest_todo.setEnvironmentVariable("ZUI_TODO_DEMO", "1");
    selftest_todo.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_step = b.step("selftest-todo", "Run the todo headless integration selftest");
    selftest_step.dependOn(&selftest_todo.step);
    test_step.dependOn(&selftest_todo.step);

    const images_demo = b.addExecutable(.{
        .name = "images-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/images/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zui",
                .module = mod,
            }},
        }),
    });
    const run_images = b.addRunArtifact(images_demo);

    const run_images_step = b.step("run-images", "Render the images demo to a PPM snapshot");
    run_images_step.dependOn(&run_images.step);

    const dash = b.addExecutable(.{
        .name = "dash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dash/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zui",
                .module = mod,
            }},
            .strip = true,
        }),
        .use_llvm = use_llvm,
    });
    const run_dash = b.addRunArtifact(dash);

    const run_dash_step = b.step("run-dash", "Run the dashboard example");
    run_dash_step.dependOn(&run_dash.step);

    // Headless integration: synthetic clicks through the real event queue ->
    // App -> Window -> hit-test -> listener path, asserting dashboard state.
    const selftest_dash = b.addRunArtifact(dash);
    selftest_dash.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest_dash.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_dash_step = b.step("selftest-dash", "Run the dashboard headless integration selftest");
    selftest_dash_step.dependOn(&selftest_dash.step);
    test_step.dependOn(&selftest_dash.step);

    // Opt-in migration gate uses the real mounted trees; default tests above
    // intentionally retain legacy layout until geometry parity is broader.
    const zlay_todo = b.addRunArtifact(todo);
    zlay_todo.setEnvironmentVariable("ZUI_LAYOUT", "zlay");
    zlay_todo.setEnvironmentVariable("ZUI_BACKEND", "null");
    zlay_todo.setEnvironmentVariable("ZUI_TODO_DEMO", "1");
    zlay_todo.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const zlay_dash = b.addRunArtifact(dash);
    zlay_dash.setEnvironmentVariable("ZUI_LAYOUT", "zlay");
    zlay_dash.setEnvironmentVariable("ZUI_BACKEND", "null");
    zlay_dash.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const zlay_step = b.step("selftest-zlay", "Run real todo/dashboard trees through experimental Zlay layout");
    zlay_step.dependOn(&zlay_todo.step);
    zlay_step.dependOn(&zlay_dash.step);

    // The Rust + gpui-kit take on the same dashboard lives in
    // `examples/dash-gpui`. Cargo owns that build; this step just forwards to
    // it, so it requires a Rust toolchain on PATH.
    //
    // Release, not debug: GPUI frameworks are unusably slow without
    // optimizations (layout, painting and wgpu are all affected), and the
    // first release build can take a few minutes.
    //   zig build run-dash-kit
    const run_dash_kit = b.addSystemCommand(&.{
        "cargo",
        "run",
        "--release",
        "--manifest-path",
        "examples/dash-gpui/Cargo.toml",
    });
    const run_dash_kit_step = b.step("run-dash-kit", "Run the Rust gpui-kit dashboard example");
    run_dash_kit_step.dependOn(&run_dash_kit.step);

    // Headless text-frame benchmark (no window, no `ZUI_BACKEND` selection):
    // drives the real `elements.layout` + `elements.painter` path over frames
    // of N text nodes on the cozmic engine.
    //   zig build bench-text
    // Extra harness flags go after `--`: `zig build bench-text -- --format json`.
    const bench_text_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_text.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = mod },
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
        },
    });
    const bench_text_exe = b.addExecutable(.{ .name = "bench-text", .root_module = bench_text_mod });
    const run_bench_text = b.addRunArtifact(bench_text_exe);
    // The corpus dirs (`corpus_dirs`) resolve against the package root, not
    // the invocation cwd, so every row reads the same vendored fonts.
    run_bench_text.setCwd(b.path("."));
    run_bench_text.addPassthruArgs();
    const bench_text_step = b.step("bench-text", "Benchmark the text element frame path (headless, no window)");
    bench_text_step.dependOn(&run_bench_text.step);

    // Compile-only gate: builds every test root and example binary without
    // executing anything. `zig build test` cannot run on foreign targets
    // (RunArtifact would exec a foreign binary), so CI cross-target jobs
    // use `zig build check -Dtarget=<triple>` instead.
    const check_step = b.step("check", "Compile all tests and examples without running them");
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&layout_tests.step);
    check_step.dependOn(&todo_tests.step);
    check_step.dependOn(&todo.step);
    check_step.dependOn(&dash.step);
    check_step.dependOn(&images_demo.step);
    check_step.dependOn(&bench_text_exe.step);

    // External-consumer smoke test: builds the minimal out-of-tree package
    // in tools/smoke_consumer against this checkout via a path dependency.
    // Manual equivalent: `cd tools/smoke_consumer && zig build`.
    const smoke = b.addSystemCommand(&.{ "zig", "build", "--summary", "all" });
    smoke.setCwd(b.path("tools/smoke_consumer"));
    const smoke_step = b.step("smoke", "Build the external path-dependency consumer package");
    smoke_step.dependOn(&smoke.step);
}
