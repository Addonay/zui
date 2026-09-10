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
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/todo/main.zig"), .target = target, .optimize = optimize, .imports = &.{.{
            .name = "zui",
            .module = mod,
        }}, .strip = true }),
        .use_llvm = use_llvm,
    });
    const run_todo = b.addRunArtifact(todo);

    const run_todo_step = b.step("run-todo", "Run the todo example");
    run_todo_step.dependOn(&run_todo.step);

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
}
