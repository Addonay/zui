const std = @import("std");

const examples = [_][]const u8{
    "hello_world",
    "scrollable",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
    const cozmic = b.dependency("cozmic", .{ .target = target, .optimize = optimize });

    const zui = b.addModule("zui", .{
        .root_source_file = b.path("src/zui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zafi", .module = zafi.module("zafi") },
            .{ .name = "cozmic", .module = cozmic.module("cozmic") },
        },
    });

    // Vendored C backends: nanosvg (SVG parse + rasterize) and stb_image (decode).
    zui.addIncludePath(b.path("third_party"));
    zui.addCSourceFile(.{ .file = b.path("third_party/images.c"), .flags = &.{"-std=c99"} });

    // Unit tests.
    const tests = b.addTest(.{ .root_module = zui });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Examples: `zig build run-<name>`.
    const check = b.step("check", "Compile everything without running");
    check.dependOn(&tests.step);
    inline for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zui", .module = zui }},
            }),
        });
        b.installArtifact(exe);
        check.dependOn(&exe.step);
        const run = b.addRunArtifact(exe);
        b.step("run-" ++ name, "Run the " ++ name ++ " example").dependOn(&run.step);
    }
}
