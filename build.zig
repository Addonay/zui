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
    "input",
    "drag_drop",
    "shadow",
    "opacity",
    "svg",
    "image",
    "text",
    "text_wrapper",
    "grid_layout",
    "painting",
    "data_table",
    "uniform_list",
    "list_example",
    "animation",
    "focus_visible",
    "tab_stop",
    "popover",
    "anchor",
    "gif_viewer",
    "image_gallery",
    "image_loading",
    "on_window_close_quit",
    "window_movable",
    "window_shadow",
    "mouse_pressure",
    "set_menus",
    "paths_bench",
    "system_notifications",
    "testing",
    "window",
    "window_positioning",
    "move_entity_between_windows",
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

    // The HTTP client, optimized even in Debug: Debug TLS adds about 0.9 s to each connection.
    const http_native = b.createModule(.{
        .root_source_file = b.path("src/http_native.zig"),
        .target = target,
        .optimize = if (optimize == .debug) .fast else optimize,
        .link_libc = true,
    });
    // `extern "crypt32"` in `std` names its library only for the artifact it is compiled into, and a
    // static library does not pass that on.
    if (target.result.os.tag == .windows) {
        http_native.linkSystemLibrary("crypt32", .{});
        http_native.linkSystemLibrary("ws2_32", .{});
    }
    zui.linkLibrary(b.addLibrary(.{ .name = "zui_http", .linkage = .static, .root_module = http_native }));

    // Vendored C backends: nanosvg (SVG parse + rasterize).
    zui.addIncludePath(b.path("third_party"));
    zui.addCSourceFile(.{ .file = b.path("third_party/images.c"), .flags = &.{"-std=c99"} });

    // Wuffs image decoders (third_party/wuffs), a separate static library optimized even in Debug, so
    // that images decode quickly in a Debug app. Its decoders are memory safe; see src/wuffs.zig.
    const wuffs_native = b.createModule(.{
        .target = target,
        .optimize = if (optimize == .debug) .fast else optimize,
        .link_libc = true,
    });
    wuffs_native.addIncludePath(b.path("third_party/wuffs"));
    wuffs_native.addCSourceFile(.{ .file = b.path("third_party/wuffs/zui_wuffs.c"), .flags = &.{ "-std=c99", "-fno-sanitize=undefined" } });
    zui.linkLibrary(b.addLibrary(.{ .name = "zui_wuffs", .linkage = .static, .root_module = wuffs_native }));

    // Unit tests.
    const tests = b.addTest(.{ .root_module = zui });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Examples: `zig build run-<name>`.
    const check = b.step("check", "Compile everything without running");
    if (target.result.os.tag == .macos) {
        // The tests reach the Metal backend, whose libobjc is not available
        // when cross-linking. Analyze them without linking until macOS is ported.
        check.dependOn(&b.addTest(.{ .root_module = zui, .emit_object = true }).step);
    } else {
        check.dependOn(&tests.step);
    }
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
    // The example tests (examples/testing.zig) run with `zig build test`.
    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/testing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = zui }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

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
