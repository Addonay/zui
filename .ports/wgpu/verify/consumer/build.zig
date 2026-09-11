//! Separate consumer of the wgpu package, exactly the way an application
//! outside this repository would use it:
//!
//!     const dep = b.dependency("wgpu", .{ .target = target, .optimize = optimize });
//!     exe.root_module.addImport("wgpu", dep.module("wgpu"));
//!
//! User options belong to the root package in this Zig version, so the
//! consumer declares the wgpu-native options it wants to forward and passes
//! them through `b.dependency`. The package also auto-detects a native library
//! in its own well-known locations (see its README), which is what happens
//! when no option is given.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forwarded to the wgpu package.
    const native_prefix = b.option(
        []const u8,
        "wgpu-native-prefix",
        "Forwarded to the wgpu package: wgpu-native install prefix.",
    );
    const native_lib = b.option(
        []const u8,
        "wgpu-native-lib",
        "Forwarded to the wgpu package: exact path to libwgpu_native.",
    );
    const native_linkage = b.option(
        enum { dynamic, static },
        "wgpu-native-linkage",
        "Forwarded to the wgpu package: dynamic (default) or static linking.",
    );

    const wgpu_dep = b.dependency("wgpu", .{
        .target = target,
        .optimize = optimize,
        .@"wgpu-native-prefix" = native_prefix,
        .@"wgpu-native-lib" = native_lib,
        .@"wgpu-native-linkage" = native_linkage,
    });
    const wgpu_module = wgpu_dep.module("wgpu");

    const exe = b.addExecutable(.{
        .name = "wgpu-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wgpu", .module = wgpu_module }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the consumer smoke test");
    run_step.dependOn(&run.step);
}
