const std = @import("std");

const IconsPreset = enum { lucide, tabler, phosphor, heroicons, hugeicons };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zui_dep = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const zui_mod = zui_dep.module("zui");

    const shadcn_mod = b.createModule(.{
        .root_source_file = b.path("../../.references/shadcn-zui/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_mod }},
    });
    const icons = b.addOptions();
    icons.addOption(IconsPreset, "icons_preset", .lucide);
    shadcn_mod.addOptions("build_options", icons);

    const todo = b.addExecutable(.{
        .name = "daybook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("daybook.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_mod },
                .{ .name = "shadcn-zui", .module = shadcn_mod },
            },
        }),
    });
    b.installArtifact(todo);
    const run_todo = b.addRunArtifact(todo);
    const run_step = b.step("run", "Run the shadcn-zui Daybook example");
    run_step.dependOn(&run_todo.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("daybook_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_mod },
                .{ .name = "shadcn-zui", .module = shadcn_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the Daybook model and accessibility tree");
    test_step.dependOn(&run_tests.step);

    const selftest = b.addRunArtifact(todo);
    selftest.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest.setEnvironmentVariable("ZUI_TODO_DEMO", "1");
    selftest.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_step = b.step("selftest", "Run the Daybook interaction self-test");
    selftest_step.dependOn(&selftest.step);
}
