const std = @import("std");

const examples = [_][]const u8{
    "hello_world",
    "pattern",
    "tree",
    "text_layout",
    "scrollable",
    "ownership_post",
    "active_state_bug",
    "gradient",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gpu_debug = b.option(bool, "gpu-debug", "Enable the GPU validation layer (default: Debug and ReleaseSafe)");

    const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
    const cozmic = b.dependency("cozmic", .{ .target = target, .optimize = optimize });

    const build_options = b.addOptions();
    build_options.addOption(?bool, "debug", gpu_debug);
    build_options.addOption(bool, "validate_non_fatal", false);

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

    // Shader regeneration: compiles renderer/shaders.glsl for every backend and rewrites the
    // committed renderer/shaders_gen.zig. Everyone else needs no shader compiler.
    if (b.option(bool, "regen-shaders", "Regenerate src/renderer/shaders_gen.zig with sokol-shdc (downloads it)") orelse false) {
        const shdc = b.lazyDependency("sokol_tools_bin", .{}) orelse return;
        const generator = b.addExecutable(.{
            .name = "zui-shdc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/renderer/shdc/main.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        const run = b.addRunArtifact(generator);
        run.addFileArg(shdc.path(shdcPath(b.graph.host.result) orelse @panic("no bundled sokol-shdc for this host")));
        run.addFileArg(b.path("src/renderer/shaders.glsl"));
        const output = run.addOutputFileArg("shaders_gen.zig");
        _ = run.addOutputDirectoryArg("shdc");
        run.addArg("glsl410:glsl300es:hlsl5:metal_macos:metal_ios:metal_sim:wgsl:spirv_vk");
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(output, "src/renderer/shaders_gen.zig");
        b.step("shaders", "Regenerate src/renderer/shaders_gen.zig").dependOn(&update.step);
    }
}

fn shdcPath(target: std.Target) ?[]const u8 {
    return @import("src/renderer/shdc/compiler.zig").bundledPath(target.os.tag, target.cpu.arch);
}
