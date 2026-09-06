const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const layout_mod = b.addModule("layout", .{
        .root_source_file = b.path("src/layout/root.zig"),
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

    const test_step = b.step("test", "Run zui unit tests");
    test_step.dependOn(&run_mod_tests.step);

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
