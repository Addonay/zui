const std = @import("std");

const examples = [_][]const u8{
    "hello_world",
    "pattern",
    "tree",
    "text_layout",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gpu = b.option(bool, "gpu", "Build the zicr GPU renderer and its tests (default: false)") orelse false;

    const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
    const cozmic = b.dependency("cozmic", .{ .target = target, .optimize = optimize });

    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu", gpu);

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
    zui.addImport("build_options", build_options.createModule());

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

    // GPU renderer on zicr (`-Dgpu=true`). Lazy: the zicr dependency and its shader
    // compiler are fetched only in this configuration.
    if (gpu) {
        const zicr_dep = b.lazyDependency("zicr", .{ .target = target, .optimize = optimize }) orelse return;
        const zicr_build = b.lazyImport(@This(), "zicr") orelse return;
        const zicr = zicr_dep.module("zicr");
        const shaders = zicr_build.addShaderModule(b, zicr_dep, .{
            .input = b.path("src/renderer/shaders.glsl"),
            .zicr = zicr,
        }) orelse return;

        const gpu_mod = b.createModule(.{
            .root_source_file = b.path("src/renderer/gpu.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zicr", .module = zicr },
                .{ .name = "zui_shaders", .module = shaders },
            },
        });

        const gpu_test_mod = b.createModule(.{
            .root_source_file = b.path("src/renderer/gpu_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zicr", .module = zicr },
                .{ .name = "zui_gpu", .module = gpu_mod },
                .{ .name = "zui_shaders", .module = shaders },
            },
        });
        const gpu_tests = b.addTest(.{ .root_module = gpu_test_mod });
        const run_gpu_tests = b.addRunArtifact(gpu_tests);
        const gpu_test_step = b.step("gpu-test", "Compare the GPU renderer with the CPU renderer (needs -Dgpu=true)");
        gpu_test_step.dependOn(&run_gpu_tests.step);
    }
}
