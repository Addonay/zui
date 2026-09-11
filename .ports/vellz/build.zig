const std = @import("std");

/// Pinned upstream baseline. Keep in sync with tools/pin.env, plan.md and
/// README.md. The GPU shaders and renderer are ported from this revision.
pub const pins = struct {
    pub const vello_rev = "1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7";
    pub const vello_describe = "v0.10.0-51-g1e63b4a4";
    pub const vello_date = "2026-09-11";
    pub const vello_common_version = "0.2.0";
    pub const vello_cpu_version = "0.2.0";
    pub const vello_gpu_version = "0.2.0";
    pub const vello_gpu_shaders_version = "0.2.0";
    pub const glifo_version = "0.3.0";
    pub const tested_zig = "0.17.0-dev.2085+5e36170b5";
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------- options
    //
    // The GPU backend is opt-in. A CPU-only configuration must not resolve,
    // download, build, or link the sibling wgpu package or wgpu-native. The
    // `wgpu` dependency in build.zig.zon is marked lazy, and this build script
    // only touches it when `-Dgpu=true` is passed.
    const gpu_enabled = b.option(
        bool,
        "gpu",
        "Build the optional GPU backend through the sibling ../wgpu package",
    ) orelse false;

    // ------------------------------------------------------- build options
    const options = b.addOptions();
    options.addOption(bool, "gpu", gpu_enabled);
    const options_module = options.createModule();

    // ------------------------------------------------------------- module
    // The probe reference is a fixture (raw bytes), imported so that
    // `@embedFile("probe_reference")` in `src/common/probe.zig` can read it:
    // `@embedFile` paths must stay inside the module's package path.
    const probe_reference_module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/upstream/probe.rgba"),
    });

    var import_buf: [3]std.Build.Module.Import = undefined;
    var import_count: usize = 0;
    import_buf[import_count] = .{ .name = "build_options", .module = options_module };
    import_count += 1;
    import_buf[import_count] = .{ .name = "probe_reference", .module = probe_reference_module };
    import_count += 1;

    if (gpu_enabled) {
        const native_prefix = b.option(
            []const u8,
            "wgpu-native-prefix",
            "wgpu-native install prefix forwarded to the sibling wgpu package",
        );
        const native_lib = b.option(
            []const u8,
            "wgpu-native-lib",
            "exact libwgpu_native path forwarded to the sibling wgpu package",
        );
        const native_linkage = b.option(
            []const u8,
            "wgpu-native-linkage",
            "dynamic or static linking forwarded to the sibling wgpu package",
        );
        const native_link = b.option(
            bool,
            "wgpu-native-link",
            "forwarded to the sibling wgpu package (set false to link yourself)",
        );

        if (b.lazyDependency("wgpu", .{
            .target = target,
            .optimize = optimize,
            .@"wgpu-native-prefix" = native_prefix,
            .@"wgpu-native-lib" = native_lib,
            .@"wgpu-native-linkage" = native_linkage,
            .@"wgpu-native-link" = native_link,
        })) |dep| {
            import_buf[import_count] = .{ .name = "wgpu", .module = dep.module("wgpu") };
            import_count += 1;
        } else {
            // With a local path dependency this cannot happen; it would mean the
            // dependency is disabled by the Zig package manager. Fail loudly
            // instead of silently producing a CPU-only build.
            std.debug.print(
                "vellz: -Dgpu=true was passed but the `wgpu` dependency could not be resolved\n",
                .{},
            );
            std.process.exit(1);
        }
    }

    const mod = b.addModule("vellz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = import_buf[0..import_count],
    });

    // ------------------------------------------------------------- CLI tool
    // Development tool: renders a shared-corpus scene to raw premultiplied
    // RGBA8 for differential comparison against the pinned oracle. It is not
    // part of the default install step, so an in-progress tool never blocks
    // `zig build test`; build it explicitly with `zig build vellz-cli`.
    const cli = b.addExecutable(.{
        .name = "vellz-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/vellz_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vellz", .module = mod }},
        }),
    });
    const cli_step = b.step("vellz-cli", "Build the corpus renderer CLI into zig-out/bin");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    // --------------------------------------------------------------- example
    const cpu_example = b.addExecutable(.{
        .name = "vellz-cpu-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cpu_basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vellz", .module = mod }},
        }),
    });
    const example_step = b.step("run-cpu-example", "Run the CPU rendering example (writes cpu_example.ppm)");
    const run_example = b.addRunArtifact(cpu_example);
    run_example.addPassthruArgs();
    example_step.dependOn(&run_example.step);

    // ------------------------------------------------------- corpus oracle gate
    // Renders tests/scenes with the CLI and byte-compares against the pinned
    // upstream fixtures in tests/fixtures/oracle.
    const corpus = b.addSystemCommand(&.{"tools/compare_corpus.sh"});
    corpus.step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    const corpus_step = b.step("corpus", "Run the oracle corpus gate (G1)");
    corpus_step.dependOn(&corpus.step);

    // ---------------------------------------------------------- probe gate
    // Renders the ported upstream probe scene (src/common/probe.zig) at the
    // settings that generated the pinned upstream reference and compares the
    // un-premultiplied RGBA8 output. The same comparison also runs inside
    // `zig build test` through the embedded fixture.
    const probe = b.addSystemCommand(&.{"tools/check_probe.sh"});
    probe.step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    const probe_step = b.step(
        "probe",
        "Render the upstream probe fixture and compare against the pinned reference",
    );
    probe_step.dependOn(&probe.step);

    // ---------------------------------------------------------------- tests
    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // The shared scene corpus parser is tooling, not part of the library
    // module, but its tests guard the input format both implementations use.
    const scene_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scene.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_scene_tests = b.addRunArtifact(scene_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_scene_tests.step);

    // ---------------------------------------------------------------- check
    // Compile everything in the default configuration without running it.
    const check_step = b.step("check", "Compile the library and all buildable examples");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&scene_tests.step);
}

test "pinned revision is recorded and matches the plan" {
    try std.testing.expectEqual(@as(usize, 40), pins.vello_rev.len);
    try std.testing.expectEqualStrings("v0.10.0-51-g1e63b4a4", pins.vello_describe);
}
