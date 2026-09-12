const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options for the text engine: the deterministic vendored corpus
    // path the tests derive their font directory from. There is no engine
    // switch any more: text is always cozmic.
    const build_options = b.addOptions();

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

    const mod = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // Vendored C image backends (nanosvg + stb_image, zero deps).
    mod.addIncludePath(b.path("third_party"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/images.c"),
        .flags = &.{ "-O2", "-std=c99", "-fno-sanitize=all" },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

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
}
