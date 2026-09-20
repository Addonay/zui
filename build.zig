const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options for the text engine: the deterministic vendored corpus
    // path the tests derive their font directory from. There is no engine
    // switch any more: text is always cozmic.
    const build_options = b.addOptions();

    // AccessKit accessibility bridge (gap report §5C / §7): vendored C-ABI
    // library built from third_party/accesskit with cargo. Default OFF so
    // plain `zig build` never requires a Rust toolchain; enable with
    // -Daccesskit=true (see docs/A11Y_PLAN.md for the runtime story).
    const enable_accesskit = b.option(bool, "accesskit", "Enable the AccessKit accessibility bridge (builds the vendored library with cargo)") orelse false;
    build_options.addOption(bool, "accesskit", enable_accesskit);

    // Optional Vellz/WGPU backend compilation. Default CPU builds never
    // resolve wgpu-native; the GPU steps are explicit source/link and native
    // Wayland-surface gates for the partial bridge.
    const enable_gpu = b.option(bool, "gpu", "Compile the optional Vellz/WGPU backend") orelse false;
    build_options.addOption(bool, "gpu", enable_gpu);
    const gpu_native_prefix = b.option(
        []const u8,
        "wgpu-native-prefix",
        "Prefix containing the matching wgpu-native include/ and lib/ directories",
    );
    const gpu_native_lib = b.option(
        []const u8,
        "wgpu-native-lib",
        "Exact path to the matching wgpu-native library",
    );
    const gpu_native_linkage = b.option(
        []const u8,
        "wgpu-native-linkage",
        "Link wgpu-native dynamically or statically",
    );
    const gpu_native_link = b.option(
        bool,
        "wgpu-native-link",
        "Link wgpu-native through the optional GPU dependency",
    );

    // Standalone layout-engine package, fetched from
    // https://github.com/Addonay/zlay (pinned by commit in build.zig.zon).
    // The `zlay` module is aliased to `layout` so every existing
    // `@import("layout")` call site and the package-boundary test below stay
    // unchanged. `-Dserde=true` is forwarded to the package, which owns its
    // optional serde dependency; run the package's own gates with:
    //   cd ../zlay && zig build test [ -Dserde=true ]
    const enable_serde = b.option(bool, "serde", "Enable Taffy-compatible JSON serde in the layout package") orelse false;
    const zlay_dep = b.dependency("zlay", .{
        .target = target,
        .optimize = optimize,
        .serde = enable_serde,
    });
    const layout_mod = zlay_dep.module("zlay");

    // Cozmic text engine (published package: https://github.com/Addonay/cozmic,
    // pinned in build.zig.zon). The `layout` module deliberately keeps no
    // cozmic dependency.
    const cozmic_dep = b.dependency("cozmic", .{
        .target = target,
        .optimize = optimize,
    });
    // Deterministic test corpus shipped inside the fetched package. Passing a
    // file from it (directories cannot be hashed by the options step) lets the
    // tests derive the corpus directory, so no `.ports/cozmic` checkout is
    // required at runtime.
    build_options.addOptionPath("cozmic_corpus_font", cozmic_dep.path("tests/fonts/Inter-Regular.ttf"));

    // Vello-derived 2D renderer (published package:
    // https://github.com/Addonay/vellz, pinned in build.zig.zon). CPU-first
    // rendering library; its GPU backend and the wgpu dependency are lazy and
    // are never resolved by zui's CPU build.
    const vellz_dep = b.dependency("vellz", .{
        .target = target,
        .optimize = optimize,
        .gpu = enable_gpu,
        .@"wgpu-native-prefix" = gpu_native_prefix,
        .@"wgpu-native-lib" = gpu_native_lib,
        .@"wgpu-native-linkage" = gpu_native_linkage,
        .@"wgpu-native-link" = gpu_native_link,
    });

    var wgpu_mod: ?*std.Build.Module = null;
    if (enable_gpu) {
        if (b.lazyDependency("wgpu", .{
            .target = target,
            .optimize = optimize,
            .@"wgpu-native-prefix" = gpu_native_prefix,
            .@"wgpu-native-lib" = gpu_native_lib,
            .@"wgpu-native-linkage" = gpu_native_linkage,
            .@"wgpu-native-link" = gpu_native_link,
        })) |dep| {
            wgpu_mod = dep.module("wgpu");
        }
    }

    const mod = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "zlay", .module = layout_mod },
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
            .{ .name = "vellz", .module = vellz_dep.module("vellz") },
            .{ .name = "wgpu", .module = wgpu_mod orelse layout_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // shadcn-zui component layer used by the native examples. The checkout is
    // fetched from Addonay/shadcn-zui into the ignored `.references` area;
    // loading its source module directly lets it share this worktree's newer
    // zui API while the upstream package's development path is repaired.
    const shadcn_mod = b.createModule(.{
        .root_source_file = b.path(".references/shadcn-zui/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = mod }},
    });
    const ShadcnIconsPreset = enum { lucide, tabler, phosphor, heroicons, hugeicons };
    const shadcn_options = b.addOptions();
    shadcn_options.addOption(ShadcnIconsPreset, "icons_preset", .lucide);
    shadcn_mod.addOptions("build_options", shadcn_options);

    if (enable_gpu) {
        const gpu_probe = b.addExecutable(.{
            .name = "zui-gpu-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gpu_probe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "vellz", .module = vellz_dep.module("vellz") }},
            }),
        });
        const gpu_compile = b.step("gpu-compile", "Compile the real Vellz/WGPU backend boundary");
        gpu_compile.dependOn(&gpu_probe.step);
        const run_gpu_probe = b.addRunArtifact(gpu_probe);
        const gpu_check = b.step("gpu-check", "Acquire a real WGPU adapter and device through Vellz");
        gpu_check.dependOn(&run_gpu_probe.step);

        const gpu_offscreen_diff = b.addExecutable(.{
            .name = "zui-gpu-offscreen-diff",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gpu_offscreen_diff.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zui", .module = mod },
                    .{ .name = "vellz", .module = vellz_dep.module("vellz") },
                    .{ .name = "wgpu", .module = wgpu_mod.? },
                },
            }),
        });
        const run_gpu_offscreen_diff = b.addRunArtifact(gpu_offscreen_diff);
        const gpu_offscreen_diff_step = b.step("gpu-offscreen-diff", "Compare CPU and WGPU pixels for a retained ZUI scene");
        gpu_offscreen_diff_step.dependOn(&run_gpu_offscreen_diff.step);

        if (target.result.os.tag == .linux) {
            const wayland_smoke = b.addExecutable(.{
                .name = "zui-gpu-wayland-smoke",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/gpu_wayland_smoke.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zui", .module = mod },
                        .{ .name = "vellz", .module = vellz_dep.module("vellz") },
                        .{ .name = "wgpu", .module = wgpu_mod.? },
                    },
                }),
            });
            const run_wayland_smoke = b.addRunArtifact(wayland_smoke);
            const wayland_smoke_step = b.step("gpu-wayland-smoke", "Present diagnostic frames through a native Wayland WGPU surface");
            wayland_smoke_step.dependOn(&run_wayland_smoke.step);

            const wayland_bridge_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/gpu_wayland_smoke.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zui", .module = mod },
                        .{ .name = "vellz", .module = vellz_dep.module("vellz") },
                        .{ .name = "wgpu", .module = wgpu_mod.? },
                    },
                }),
            });
            const run_wayland_bridge_tests = b.addRunArtifact(wayland_bridge_tests);
            const wayland_bridge_test_step = b.step("gpu-wayland-test", "Test the ZUI-to-Vellz GPU scene bridge");
            wayland_bridge_test_step.dependOn(&run_wayland_bridge_tests.step);
        }
    }

    // Vendored C image backends (nanosvg + stb_image, zero deps).
    mod.addIncludePath(b.path("third_party"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/images.c"),
        .flags = &.{ "-O2", "-std=c99", "-fno-sanitize=all" },
    });

    // AccessKit: the vendored C-ABI library is built with cargo from
    // third_party/accesskit (Rust crate `accesskit-c`, static + shared);
    // the header is translated to the `accesskit_c` import. Artifacts land
    // under third_party/accesskit/target/release (gitignored). Only the
    // `zui` module links it; consumers get it transitively.
    if (enable_accesskit) {
        const ak_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("third_party/accesskit/include/accesskit.h"),
            .target = target,
            .optimize = optimize,
        });
        const ak_lib = b.addSystemCommand(&.{ "cargo", "build", "--release" });
        ak_lib.setCwd(b.path("third_party/accesskit"));
        mod.addImport("accesskit_c", ak_translate_c.createModule());
        mod.addLibraryPath(b.path("third_party/accesskit/target/release"));
        mod.linkSystemLibrary("accesskit", .{ .needed = false });
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Compile a consumer root against only the public zui module. This is the
    // source-backed IntoElement/Render smoke gate; it must not gain imports
    // of src/elements internals as the composition API evolves.
    const composition_consumer_mod = b.createModule(.{
        .root_source_file = b.path("src/elements/composition_consumer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zui", .module = mod }},
    });
    const composition_consumer_tests = b.addTest(.{ .root_module = composition_consumer_mod });
    const run_composition_consumer_tests = b.addRunArtifact(composition_consumer_tests);
    const composition_consumer_step = b.step("test-element-composition", "Run the external typed-element composition consumer smoke test");
    composition_consumer_step.dependOn(&run_composition_consumer_tests.step);

    const adapter_tests = b.addTest(.{ .root_module = mod, .filters = &.{"adapter"} });
    const run_adapter_tests = b.addRunArtifact(adapter_tests);
    const adapter_test_step = b.step("test-zlay", "Run focused adapter agreement and grid regression tests");
    adapter_test_step.dependOn(&run_adapter_tests.step);

    // Compile the layout module as its own root as well. This catches
    // accidental dependencies on the wider ZUI surface and documents the
    // supported `@import("layout")` package boundary.
    const layout_tests = b.addTest(.{
        .root_module = layout_mod,
    });
    const run_layout_tests = b.addRunArtifact(layout_tests);

    // Focused text-system parity gate. Keeping this root separate from the
    // application/widget test graph lets font shaping and geometry tests run
    // even while unrelated widget experiments are being edited.
    const text_mod = b.createModule(.{
        .root_source_file = b.path("src/text_system_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    const text_tests = b.addTest(.{ .root_module = text_mod });
    const run_text_tests = b.addRunArtifact(text_tests);
    const text_test_step = b.step("test-text", "Run focused GPUI text-system parity tests");
    text_test_step.dependOn(&run_text_tests.step);

    const test_step = b.step("test", "Run zui unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_composition_consumer_tests.step);
    test_step.dependOn(&run_layout_tests.step);

    const renderer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/gpu/render_backend.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    const renderer_test_step = b.step("renderer-test", "Run the headless renderer-selection and recovery tests");
    renderer_test_step.dependOn(&run_renderer_tests.step);
    test_step.dependOn(&run_renderer_tests.step);

    const renderer_probe = b.addExecutable(.{ .name = "zui-render-backend-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/render_backend_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "render_backend", .module = b.createModule(.{
            .root_source_file = b.path("src/gpu/render_backend.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    }) });
    const run_renderer_probe = b.addRunArtifact(renderer_probe);
    const renderer_probe_step = b.step("renderer-probe", "Run the headless explicit renderer-selection probe");
    renderer_probe_step.dependOn(&run_renderer_probe.step);

    // Keep the GPUI source-ledger check available through the same build
    // interface as the behavioral gates. It intentionally reads the pinned
    // reference source and the Markdown matrix; it does not compile or alter
    // any framework implementation lane.
    const gpui_parity_check = b.addSystemCommand(&.{ "python3", "tools/check-gpui-parity-matrix.py" });
    const gpui_parity_step = b.step("gpui-parity", "Check GPUI public API inventory and parity-matrix evidence syntax");
    gpui_parity_step.dependOn(&gpui_parity_check.step);

    const legacy_mod_tests = b.addTest(.{ .root_module = mod });
    const run_legacy_mod_tests = b.addRunArtifact(legacy_mod_tests);
    run_legacy_mod_tests.setEnvironmentVariable("ZUI_LAYOUT", "legacy");
    const legacy_test_step = b.step("test-legacy", "Run the ZUI unit suite through the legacy layout migration path");
    legacy_test_step.dependOn(&run_legacy_mod_tests.step);

    const debug_probe = b.addExecutable(.{
        .name = "zui-headless-debug-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_debug_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "debug_trace", .module = b.createModule(.{ .root_source_file = b.path("src/debug/trace.zig"), .target = target, .optimize = optimize }) },
                .{ .name = "debug_profiler", .module = b.createModule(.{ .root_source_file = b.path("src/debug/profiler.zig"), .target = target, .optimize = optimize }) },
            },
        }),
    });
    const run_debug_probe = b.addRunArtifact(debug_probe);
    const debug_probe_step = b.step("debug-probe", "Run deterministic trace/profiler/scene snapshot diagnostics");
    debug_probe_step.dependOn(&run_debug_probe.step);

    const debug_probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_debug_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "debug_trace", .module = b.createModule(.{ .root_source_file = b.path("src/debug/trace.zig"), .target = target, .optimize = optimize }) },
                .{ .name = "debug_profiler", .module = b.createModule(.{ .root_source_file = b.path("src/debug/profiler.zig"), .target = target, .optimize = optimize }) },
            },
        }),
    });
    const run_debug_probe_tests = b.addRunArtifact(debug_probe_tests);
    const debug_test_step = b.step("debug-test", "Test deterministic headless debug artifacts");
    debug_test_step.dependOn(&run_debug_probe_tests.step);

    const visual_probe = b.addExecutable(.{
        .name = "zui-visual-test-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/visual_test_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zui", .module = mod }},
        }),
    });
    const run_visual_probe = b.addRunArtifact(visual_probe);
    const visual_probe_step = b.step("visual-test-probe", "Run the reusable offscreen TestContext smoke command");
    visual_probe_step.dependOn(&run_visual_probe.step);

    const visual_probe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/visual_test_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zui", .module = mod }},
    }) });
    const run_visual_probe_tests = b.addRunArtifact(visual_probe_tests);
    const visual_test_step = b.step("visual-test", "Test the reusable headless TestContext and visual golden harness");
    visual_test_step.dependOn(&run_visual_probe_tests.step);

    const context_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_context_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_context_tests = b.addRunArtifact(context_tests);
    const context_test_step = b.step("test-context", "Run focused deterministic TestContext and visual snapshot tests");
    context_test_step.dependOn(&run_context_tests.step);

    const use_llvm = b.option(bool, "use-llvm", "use llvm for compilation");

    const todo = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/todo/daybook.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "zui", .module = mod },
            .{ .name = "shadcn-zui", .module = shadcn_mod },
        },
        .strip = true
        }),
        .use_llvm = use_llvm,
    });
    const run_todo = b.addRunArtifact(todo);

    const run_todo_step = b.step("run-todo", "Run the todo example");
    run_todo_step.dependOn(&run_todo.step);

    // Embedded unit tests in the todo example (pure-model tests). Without
    // this, `zig build test` silently skips them.
    const todo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/todo/daybook_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = mod },
                .{ .name = "shadcn-zui", .module = shadcn_mod },
            },
        }),
    });
    const run_todo_tests = b.addRunArtifact(todo_tests);
    test_step.dependOn(&run_todo_tests.step);

    // Headless integration: drive the real event queue -> App -> Window ->
    // hit-test -> listener path with synthetic input (plan M0). Needs the
    // demo seed for its 3-todo fixture.
    const selftest_todo = b.addRunArtifact(todo);
    selftest_todo.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest_todo.setEnvironmentVariable("ZUI_TODO_DEMO", "1");
    selftest_todo.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_step = b.step("selftest-todo", "Run the todo headless integration selftest");
    selftest_step.dependOn(&selftest_todo.step);
    test_step.dependOn(&selftest_todo.step);

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

    // Animation demo: transliteration of GPUI's animation.rs example
    // (spring physics, damping slider, repeating eased spinner).
    const animation = b.addExecutable(.{
        .name = "animation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/animation/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zui",
                .module = mod,
            }},
        }),
    });
    const run_animation = b.addRunArtifact(animation);

    const run_animation_step = b.step("run-animation", "Run the animation demo (spring physics + eased spinner)");
    run_animation_step.dependOn(&run_animation.step);

    // Embedded unit tests in the animation example (spring math, easings).
    const animation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/animation/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = mod }},
        }),
    });
    const run_animation_tests = b.addRunArtifact(animation_tests);
    test_step.dependOn(&run_animation_tests.step);

    // Headless integration: synthetic click/drag through the real event
    // queue -> App -> Window -> hit-test -> listener path, asserting spring
    // retarget, settle, damping retune, and the spinner clock.
    const selftest_animation = b.addRunArtifact(animation);
    selftest_animation.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest_animation.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_animation_step = b.step("selftest-animation", "Run the animation headless integration selftest");
    selftest_animation_step.dependOn(&selftest_animation.step);
    test_step.dependOn(&selftest_animation.step);

    const dash = b.addExecutable(.{
        .name = "dash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dash/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zui",
                .module = mod,
            }},
            .strip = true,
        }),
        .use_llvm = use_llvm,
    });
    const run_dash = b.addRunArtifact(dash);

    const run_dash_step = b.step("run-dash", "Run the dashboard example");
    run_dash_step.dependOn(&run_dash.step);

    // Headless integration: synthetic clicks through the real event queue ->
    // App -> Window -> hit-test -> listener path, asserting dashboard state.
    const selftest_dash = b.addRunArtifact(dash);
    selftest_dash.setEnvironmentVariable("ZUI_BACKEND", "null");
    selftest_dash.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const selftest_dash_step = b.step("selftest-dash", "Run the dashboard headless integration selftest");
    selftest_dash_step.dependOn(&selftest_dash.step);
    test_step.dependOn(&selftest_dash.step);

    // Keep an explicit mounted-tree parity gate even though Zlay is now the
    // canonical default; ZUI_LAYOUT=legacy remains the migration escape hatch.
    const zlay_todo = b.addRunArtifact(todo);
    zlay_todo.setEnvironmentVariable("ZUI_LAYOUT", "zlay");
    zlay_todo.setEnvironmentVariable("ZUI_BACKEND", "null");
    zlay_todo.setEnvironmentVariable("ZUI_TODO_DEMO", "1");
    zlay_todo.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const zlay_dash = b.addRunArtifact(dash);
    zlay_dash.setEnvironmentVariable("ZUI_LAYOUT", "zlay");
    zlay_dash.setEnvironmentVariable("ZUI_BACKEND", "null");
    zlay_dash.setEnvironmentVariable("ZUI_SELFTEST", "1");
    const zlay_step = b.step("selftest-zlay", "Run real todo/dashboard trees through experimental Zlay layout");
    zlay_step.dependOn(&zlay_todo.step);
    zlay_step.dependOn(&zlay_dash.step);

    // Small external-oracle fixture probe. The Rust side lives in
    // `tools/taffy_oracle` and remains separate from the packaged dependency;
    // compare its line output with `cargo run --manifest-path
    // tools/taffy_oracle/Cargo.toml`.
    const zlay_probe = b.addExecutable(.{
        .name = "zlay-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zlay_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = mod }},
        }),
    });
    const run_zlay_probe = b.addRunArtifact(zlay_probe);
    run_zlay_probe.setEnvironmentVariable("ZUI_LAYOUT", "zlay");
    const zlay_probe_step = b.step("zlay-probe", "Print a matched Zlay/Taffy oracle fixture");
    zlay_probe_step.dependOn(&run_zlay_probe.step);

    // Cross-implementation differential records. The Rust side is a small
    // probe against the pinned GPUI source contract; the Zig side exercises
    // the public ZUI animation API and emits the same stable JSONL schema.
    // Comparison is intentionally kept in tools/differential so this gate
    // cannot silently become a framework implementation dependency.
    const differential_zui = b.addExecutable(.{
        .name = "zui-differential-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/differential/zui_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = mod }},
        }),
    });
    const run_differential_zui = b.addRunArtifact(differential_zui);
    const differential_zui_step = b.step("differential-zui", "Emit deterministic ZUI records for GPUI differential fixtures");
    differential_zui_step.dependOn(&run_differential_zui.step);

    // The Rust + gpui-kit take on the same dashboard lives in
    // `examples/dash-gpui`. Cargo owns that build; this step just forwards to
    // it, so it requires a Rust toolchain on PATH.
    //
    // Release, not debug: GPUI frameworks are unusably slow without
    // optimizations (layout, painting and wgpu are all affected), and the
    // first release build can take a few minutes.
    //   zig build run-dash-kit
    const run_dash_kit = b.addSystemCommand(&.{
        "cargo",
        "run",
        "--release",
        "--manifest-path",
        "examples/dash-gpui/Cargo.toml",
    });
    const run_dash_kit_step = b.step("run-dash-kit", "Run the Rust gpui-kit dashboard example");
    run_dash_kit_step.dependOn(&run_dash_kit.step);

    // Headless text-frame benchmark (no window, no `ZUI_BACKEND` selection):
    // drives the real `elements.layout` + `elements.painter` path over frames
    // of N text nodes on the cozmic engine.
    //   zig build bench-text
    // Extra harness flags go after `--`: `zig build bench-text -- --format json`.
    const bench_text_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_text.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = mod },
            .{ .name = "cozmic", .module = cozmic_dep.module("cozmic") },
        },
    });
    const bench_text_exe = b.addExecutable(.{ .name = "bench-text", .root_module = bench_text_mod });
    const run_bench_text = b.addRunArtifact(bench_text_exe);
    // The corpus dirs (`corpus_dirs`) resolve against the package root, not
    // the invocation cwd, so every row reads the same vendored fonts.
    run_bench_text.setCwd(b.path("."));
    run_bench_text.addPassthruArgs();
    const bench_text_step = b.step("bench-text", "Benchmark the text element frame path (headless, no window)");
    bench_text_step.dependOn(&run_bench_text.step);

    // Compile-only gate: builds every test root and example binary without
    // executing anything. `zig build test` cannot run on foreign targets
    // (RunArtifact would exec a foreign binary), so CI cross-target jobs
    // use `zig build check -Dtarget=<triple>` instead.
    const check_step = b.step("check", "Compile all tests and examples without running them");
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&layout_tests.step);
    check_step.dependOn(&todo_tests.step);
    check_step.dependOn(&todo.step);
    check_step.dependOn(&dash.step);
    check_step.dependOn(&images_demo.step);
    check_step.dependOn(&animation.step);
    check_step.dependOn(&animation_tests.step);
    check_step.dependOn(&bench_text_exe.step);

    // External-consumer smoke test: builds the minimal out-of-tree package
    // in tools/smoke_consumer against this checkout via a path dependency.
    // Manual equivalent: `cd tools/smoke_consumer && zig build`.
    const smoke = b.addSystemCommand(&.{ "zig", "build", "--summary", "all" });
    smoke.setCwd(b.path("tools/smoke_consumer"));
    const smoke_step = b.step("smoke", "Build the external path-dependency consumer package");
    smoke_step.dependOn(&smoke.step);
}
