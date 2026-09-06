const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const layout_mod = b.addModule("layout", .{
        .root_source_file = b.path("src/layout_module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mod = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
        },
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

    // Layout benchmarks (reproducible, ReleaseFast). Writes table to stdout;
    // copy into BENCHMARKS.md after verifying on your machine.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/layout/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
        },
    });
    const bench = b.addExecutable(.{
        .name = "layout-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench-layout", "Run layout benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Optional cross-check against the vendored Taffy 0.14 reference. It is
    // intentionally a separate step because Cargo may need network access to
    // fetch Criterion's transitive dependencies.
    const taffy_compare = b.addSystemCommand(&.{
        "cargo",
        "run",
        "--release",
        "--manifest-path",
        "src/layout/bench/Cargo.toml",
    });
    const taffy_step = b.step("bench-taffy", "Run the Taffy release comparison benchmark");
    taffy_step.dependOn(&taffy_compare.step);

    const todo = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/todo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zui",
                .module = mod,
            }},
        }),
    });
    const run_todo = b.addRunArtifact(todo);

    const run_todo_step = b.step("run-todo", "Run the todo example");
    run_todo_step.dependOn(&run_todo.step);
}
