const std = @import("std");

// ---------------------------------------------------------------------------
// Pinned upstream versions.
//
// Keep these in sync with README.md, tools/fetch-reference.sh and
// tools/fetch-release.sh. The vendored headers in include/ must be
// byte-for-byte copies of the pinned revision; tools/sync-headers.sh does that.
// ---------------------------------------------------------------------------
pub const wgpu_native = struct {
    pub const tag = "v29.0.1.1";
    pub const commit = "6aed50955d934ac36049ba8d002034841633ae02";
    pub const webgpu_headers_commit = "673658bc2bd70ec39fc55ebe6bb0173cf6d0a603";
    pub const webgpu_headers_repo = "https://github.com/webgpu-native/webgpu-headers";
    pub const repo = "https://github.com/gfx-rs/wgpu-native";
    pub const tested_zig = "0.17.0-dev.2085+5e36170b5";
    pub const rust_toolchain = "1.93";
};

const NativeLinkage = enum {
    dynamic,
    static,
};

/// How the native wgpu-native library was located for a given build.
const Native = struct {
    /// Human readable description for build output.
    description: []const u8,
    /// Extra include prefix to propagate to consumers (upstream headers).
    include: ?std.Build.LazyPath = null,
    /// Directory containing the library; used for -L and rpath.
    lib_dir: ?std.Build.LazyPath = null,
    /// Exact library file; when set the linker uses this file directly.
    lib_file: ?std.Build.LazyPath = null,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----------------------------------------------------------------- options
    const native_prefix = b.option(
        []const u8,
        "wgpu-native-prefix",
        "Prefix of a wgpu-native installation (expects <prefix>/lib and optionally <prefix>/include). " ++
            "Absolute, or relative to the directory `zig build` runs in.",
    );
    const native_lib = b.option(
        []const u8,
        "wgpu-native-lib",
        "Exact path to libwgpu_native (shared library or static archive). Overrides -Dwgpu-native-prefix.",
    );
    const native_include = b.option(
        []const u8,
        "wgpu-native-include",
        "Extra include directory for matching upstream headers (propagated to consumers).",
    );
    const linkage = b.option(
        NativeLinkage,
        "wgpu-native-linkage",
        "Link the native library dynamically (default) or statically.",
    ) orelse .dynamic;
    const do_link = b.option(
        bool,
        "wgpu-native-link",
        "Link wgpu-native into consumers of the `wgpu` module. Set false if you link it yourself.",
    ) orelse true;
    const native_ref = b.option(
        []const u8,
        "wgpu-native-reference",
        "Path to the pinned wgpu-native source checkout used by `zig build native`.",
    ) orelse ".reference/wgpu-native";
    const cargo_jobs = b.option(
        u32,
        "wgpu-native-jobs",
        "Pass CARGO_BUILD_JOBS to the `zig build native` source build.",
    );

    // ------------------------------------------------------- translated C API
    // `zig translate-c` runs at build time, for the consumer's target, with the
    // consumer's C flags. This is the replacement for @cImport in this Zig
    // version (it was removed in 0.17). All C declarations live in this single
    // translation unit so there is exactly one identity for every C type.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("include/bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (native_include) |inc| translate.addIncludePath(cwdOrAbsolute(b, inc));
    if (native_prefix) |prefix| {
        translate.addIncludePath(cwdOrAbsolute(b, b.pathJoin(&.{ prefix, "include" })));
    }
    translate.addIncludePath(b.path("include"));
    const c_module = translate.createModule();

    // -------------------------------------------------------------- Zig module
    const wgpu_module = b.addModule("wgpu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // The translated API is a private module; consumers see it through
        // `wgpu.c` and never need to know its import name.
        .imports = &.{.{ .name = "c", .module = c_module }},
        .link_libc = true,
    });
    // Propagate the upstream include directory so consumers can use the same
    // C headers for their own C sources.
    if (native_include) |inc| wgpu_module.addIncludePath(cwdOrAbsolute(b, inc));
    if (native_prefix) |prefix| {
        wgpu_module.addIncludePath(cwdOrAbsolute(b, b.pathJoin(&.{ prefix, "include" })));
    }

    // ------------------------------------------------- native library linking
    const native: ?Native = if (do_link)
        resolveNative(b, target, linkage, .{
            .prefix = native_prefix,
            .lib = native_lib,
            .include = native_include,
        })
    else
        null;

    if (native) |n| {
        std.debug.print("wgpu: native library: {s}\n", .{n.description});
        if (n.include) |inc| wgpu_module.addIncludePath(inc);
        if (n.lib_file) |file| {
            wgpu_module.addObjectFile(file);
            if (linkage == .dynamic) {
                if (n.lib_dir) |dir| wgpu_module.addRPath(dir);
            }
        } else if (n.lib_dir) |dir| {
            wgpu_module.addLibraryPath(dir);
            wgpu_module.linkSystemLibrary("wgpu_native", .{
                .use_pkg_config = .no,
                .preferred_link_mode = if (linkage == .static) .static else .dynamic,
            });
            // Runtime discovery for the shared library: bake an rpath into
            // consumers so the dynamic loader can find libwgpu_native.so even
            // when it is not installed system-wide.
            if (linkage == .dynamic) wgpu_module.addRPath(dir);
        } else {
            wgpu_module.linkSystemLibrary("wgpu_native", .{ .use_pkg_config = .no });
        }
        if (linkage == .static) linkStaticDependencies(wgpu_module, target);
    } else if (do_link) {
        // Nothing found in the usual locations: fall back to letting the
        // linker search its default paths. This works when wgpu-native is
        // installed system-wide (for example /usr/local/lib).
        wgpu_module.linkSystemLibrary("wgpu_native", .{ .use_pkg_config = .no });
        if (linkage == .static) linkStaticDependencies(wgpu_module, target);
    }

    // ---------------------------------------------------------------- examples
    const Example = struct {
        name: []const u8,
        source: []const u8,
        description: []const u8,
    };
    const examples = [_]Example{
        .{
            .name = "compute",
            .source = "examples/compute.zig",
            .description = "WGSL compute shader with GPU readback and asserted output",
        },
        .{
            .name = "offscreen",
            .source = "examples/offscreen.zig",
            .description = "offscreen render to texture with pixel checks",
        },
    };

    const check_step = b.step("check", "Build and run the compute and offscreen verification examples");
    const check_failure_step = b.step("check-failure", "Verify cleanup after an initialization failure (forced adapter request failure)");
    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = "wgpu-example-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "wgpu", .module = wgpu_module }},
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        const run_step = b.step("run-" ++ example.name, example.description);
        run_step.dependOn(&run.step);
        check_step.dependOn(&run.step);

        // The compute example supports a forced adapter failure so the
        // early-return cleanup path is actually executed. The process must
        // exit with an error (1) and still release every handle.
        if (std.mem.eql(u8, example.name, "compute")) {
            const failure_run = b.addRunArtifact(exe);
            failure_run.addArg("--force-adapter-failure");
            failure_run.expectExitCode(1);
            check_failure_step.dependOn(&failure_run.step);
            check_step.dependOn(&failure_run.step);
        }
    }

    // -------------------------------------------------------------------- test
    const unit_tests = b.addTest(.{ .root_module = wgpu_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run binding unit tests (requires the native library unless -Dwgpu-native-link=false)");
    test_step.dependOn(&run_unit_tests.step);

    // ------------------------------------------------- cross-target translation
    // The bindings are translated per target at build time. These compile-only
    // checks prove the pinned headers and generated declarations work for
    // foreign targets as well; nothing is linked for them.
    const cross_step = b.step("check-cross", "Compile the bindings for foreign targets (compile only)");
    const queries = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    };
    for (queries, 0..) |query, i| {
        const resolved = b.resolveTargetQuery(query);
        const cross_translate = b.addTranslateC(.{
            .root_source_file = b.path("include/bindings.h"),
            .target = resolved,
            .optimize = .Debug,
            .link_libc = true,
        });
        cross_translate.addIncludePath(b.path("include"));
        const cross_c = cross_translate.createModule();
        const obj = b.addObject(.{
            .name = b.fmt("wgpu-cross-check-{d}", .{i}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = resolved,
                .optimize = .Debug,
                .imports = &.{.{ .name = "c", .module = cross_c }},
                .link_libc = true,
            }),
        });
        cross_step.dependOn(&obj.step);
    }

    // ------------------------------------------------- pinned native source build
    // `zig build native` builds the pinned revision from .reference/wgpu-native
    // with cargo and installs the resulting shared library into the prefix.
    const native_step = b.step("native", "Build the pinned wgpu-native from the reference checkout with Cargo and install it");
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked" });
    cargo.setCwd(pkgOrCwdPath(b, native_ref));
    cargo.has_side_effects = true;
    if (cargo_jobs) |jobs| {
        cargo.setEnvironmentVariable("CARGO_BUILD_JOBS", b.fmt("{d}", .{jobs}));
    }
    const cargo_lib_rel = b.pathJoin(&.{ native_ref, "target", "release", libraryFileName(target, .dynamic) });
    const install_native = b.addInstallLibFile(
        pkgOrCwdPath(b, cargo_lib_rel),
        libraryFileName(target, .dynamic),
    );
    install_native.step.dependOn(&cargo.step);
    native_step.dependOn(&install_native.step);

    // -------------------------------------------------- header helper checks
    // `zig build check-headers` verifies that include/wgpu_init.h matches the
    // vendored headers. The script path is package-relative, so this also works
    // when the package is built as a dependency.
    const check_headers = b.addSystemCommand(&.{"python3"});
    check_headers.addFileArg(b.path("tools/gen_init_shims.py"));
    check_headers.addArg("--check");
    const check_headers_step = b.step("check-headers", "Verify generated include/wgpu_init.h is up to date");
    check_headers_step.dependOn(&check_headers.step);
}

// ---------------------------------------------------------------------------
// Native library resolution
// ---------------------------------------------------------------------------

const NativeOptions = struct {
    prefix: ?[]const u8 = null,
    lib: ?[]const u8 = null,
    include: ?[]const u8 = null,
};

fn resolveNative(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: NativeLinkage,
    options: NativeOptions,
) ?Native {
    const lib_name = libraryFileName(target, linkage);

    // 1. Exact file requested by the user.
    if (options.lib) |lib_path| {
        const dir = std.fs.path.dirname(lib_path) orelse ".";
        return .{
            .description = b.fmt("explicit library {s}", .{lib_path}),
            .lib_file = cwdOrAbsolute(b, lib_path),
            .lib_dir = cwdOrAbsolute(b, dir),
            .include = if (options.include) |inc| cwdOrAbsolute(b, inc) else null,
        };
    }

    // 2. User supplied prefix. Check the conventional subdirectories on the
    // host; non-existent -L/-rpath entries would be harmless, but picking the
    // existing one gives better diagnostics.
    if (options.prefix) |prefix| {
        const lib_dirs = [_][]const u8{ "lib", "lib64", "bin", "" };
        var selected: ?[]const u8 = null;
        for (lib_dirs) |sub| {
            const rel = if (sub.len == 0) prefix else b.pathJoin(&.{ prefix, sub });
            if (hostFileExists(b, b.pathJoin(&.{ rel, lib_name }))) {
                selected = rel;
                break;
            }
        }
        const rel = selected orelse b.pathJoin(&.{ prefix, "lib" });
        return .{
            .description = b.fmt("prefix {s}", .{prefix}),
            .lib_dir = cwdOrAbsolute(b, rel),
            .include = if (options.include) |inc| cwdOrAbsolute(b, inc) else cwdOrAbsolute(b, b.pathJoin(&.{ prefix, "include" })),
        };
    }

    // 3. Well-known locations inside this package. These make the package
    // self-contained for the checked-in dev environment while remaining
    // optional: ordinary consumers supply -Dwgpu-native-prefix instead.
    if (target.query.isNative()) {
        const candidates = [_][]const u8{
            ".reference/artifacts/prebuilt/lib",
            ".reference/wgpu-native/target/release",
            "zig-out/lib",
        };
        for (candidates) |dir| {
            if (hostFileExists(b, b.pathJoin(&.{ dir, lib_name }))) {
                return .{
                    .description = b.fmt("{s}/{s}", .{ dir, lib_name }),
                    .lib_dir = b.path(dir),
                };
            }
        }
    }

    return null;
}

fn libraryFileName(target: std.Build.ResolvedTarget, linkage: NativeLinkage) []const u8 {
    return switch (target.result.os.tag) {
        .windows => if (linkage == .static) "wgpu_native.lib" else "wgpu_native.dll",
        .macos, .ios, .tvos, .watchos => if (linkage == .static) "libwgpu_native.a" else "libwgpu_native.dylib",
        else => if (linkage == .static) "libwgpu_native.a" else "libwgpu_native.so",
    };
}

/// Extra system libraries required by the Rust staticlib on top of libc.
fn linkStaticDependencies(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => {
            // Rust's panic=unwind runtime references the system unwinder.
            mod.linkSystemLibrary("gcc_s", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("m", .{});
        },
        else => {},
    }
}

/// A path relative to the package root, or an absolute path as-is.
fn pkgOrCwdPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) cwdOrAbsolute(b, path) else b.path(path);
}

/// A user supplied path: absolute stays absolute, relative is resolved by the
/// build runner relative to its working directory.
fn cwdOrAbsolute(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return b.graph.cwdRelativePath(path);
}

/// Checks whether `path` (absolute, or relative to this package root) exists on
/// the host. Used only for optional auto-detection.
fn hostFileExists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    var dir = b.root.openDir(io, std.fs.path.dirname(path) orelse ".", .{}) catch return false;
    defer dir.close(io);
    dir.access(io, std.fs.path.basename(path), .{}) catch return false;
    return true;
}

test "pinned version is recorded" {
    try std.testing.expectEqualStrings("v29.0.1.1", wgpu_native.tag);
}
