# wgpu — raw Zig bindings for wgpu-native

A small, standalone Zig package that exposes the [wgpu-native] C API (WebGPU)
to Zig and wires the matching native library into the Zig build system.

**The implementation underneath remains wgpu-native.** This package does not
port, reimplement or wrap the Rust implementation, and it does not introduce a
Device/Buffer/Texture/Pipeline abstraction layer. It provides:

1. Raw bindings to the pinned `webgpu.h` and the wgpu-native extensions in
   `wgpu.h`, translated by Zig at build time.
2. Build and linking integration for the matching native library, including
   static/dynamic linking and runtime discovery.
3. Working compute and offscreen-render examples with CPU-side assertions.
4. Only the helpers the examples actually need (descriptor initializers and
   string views).

Window creation, surfaces, ZUI scene types, text handling and rendering
algorithms are deliberately out of scope; this package is meant to be the
foundation of a future Vello-derived Zig renderer.

## Pinned versions

| Component | Version / revision |
| --- | --- |
| wgpu-native | `v29.0.1.1` — commit `6aed50955d934ac36049ba8d002034841633ae02` |
| webgpu-headers submodule (`ffi/webgpu-headers`) | `673658bc2bd70ec39fc55ebe6bb0173cf6d0a603` |
| Tested Zig | `0.17.0-dev.2085+5e36170b5` |
| Rust toolchain for source builds | `1.93` (`rust-toolchain.toml` in the checkout) |
| Native build configuration | `cargo build --release --locked`, default features, crate types `cdylib` + `staticlib` |
| Verified release asset | `wgpu-linux-x86_64-release.zip` (contains `libwgpu_native.so` and `libwgpu_native.a`) |
| `include/webgpu/webgpu.h` SHA-256 | `a483031c3fed05ea5dd1c74082a71676c46c5b2b820ccca10da515c033efc997` |
| `include/webgpu/wgpu.h` SHA-256 | `7bd23656d394f620a804b1f174444ea17082b6d330a2fca0c0e6b1121ec4b284` |

The versions live in [`tools/pin.env`](tools/pin.env) and in the
`wgpu_native` struct at the top of [`build.zig`](build.zig).

## Layout

```
.ports/wgpu/
  build.zig              package build: bindings, native linking, examples
  build.zig.zon          package manifest (distribution paths exclude .reference)
  README.md
  include/
    bindings.h           umbrella header: webgpu.h + wgpu.h + wgpu_init.h
    webgpu/webgpu.h      byte-for-byte upstream header
    webgpu/wgpu.h        byte-for-byte upstream header
    wgpu_init.h          GENERATED initializer shims (tools/gen_init_shims.py)
  src/
    root.zig             module entry point; re-exports `c`, string helpers
  examples/
    common.zig           example-only callback/logging helpers
    compute.zig          WGSL compute + readback + assertions
    offscreen.zig        offscreen render + pixel checks
  tools/
    pin.env              pinned revisions and header hashes
    fetch-reference.sh   clone the pinned source checkout (for source builds)
    fetch-release.sh     download the pinned release binaries for this host
    sync-headers.sh      refresh vendored headers and regenerate wgpu_init.h
    gen_init_shims.py    generator for include/wgpu_init.h
  verify/
    consumer/            independent consumer that imports this package
  .reference/            ignored: source checkout + downloaded artifacts
```

## Bindings

The C API is translated by `zig translate-c` **at build time**, for the
consumer's target and C flags, through `b.addTranslateC`. There is exactly one
translation unit (`include/bindings.h`), so every C type has a single identity.
No generated Zig source is committed.

`@cImport` is not used: in the tested Zig version it has been removed
(`error: invalid builtin function: '@cImport'`). Build-time `translate-c` is
therefore not just preferred but required, and it has the additional advantage
that platform-specific macros are evaluated for the target being compiled
rather than for the host that generated the bindings.

```zig
const wgpu = @import("wgpu");
const c = wgpu.c;

const instance = c.wgpuCreateInstance(null) orelse return error.NoInstance;
defer c.wgpuInstanceRelease(instance);
```

To inspect the translated declarations manually:

```sh
zig translate-c -I include -lc include/bindings.h > /tmp/bindings.zig
```

### Descriptor initialization (`wgpu_init.h`)

Upstream `webgpu.h` defines one compound-literal macro per struct, e.g.
`WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;`. `translate-c` cannot
translate those macros, and zeroing a descriptor is **not** always equivalent
to its initializer: `WGPU_TEXTURE_DESCRIPTOR_INIT` sets `mipLevelCount = 1` and
`sampleCount = 1`, `WGPU_BIND_GROUP_ENTRY_INIT` sets `size = WGPU_WHOLE_SIZE`,
`WGPU_MULTISAMPLE_STATE_INIT` sets `count = 1, mask = 0xFFFFFFFF`, and the
string-view macro sets the `WGPU_STRLEN` sentinel rather than a zero length.

`tools/gen_init_shims.py` scans the pinned headers for every `WGPU_*_INIT`
macro and emits `include/wgpu_init.h`, one `static inline` function per macro.
`translate-c` turns each function into an ordinary Zig function whose body
contains the exact upstream defaults, evaluated for the target. There are 92
shims. Use them instead of `std.mem.zeroes`:

```zig
var desc = c.wgpu_zig_init_WGPUTextureDescriptor();
desc.usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc;
desc.format = c.WGPUTextureFormat_RGBA8Unorm;
desc.size = .{ .width = 64, .height = 64, .depthOrArrayLayers = 1 };
```

`include/wgpu_init.h` is generated; never hand-edit it. Regenerate with
`tools/sync-headers.sh` and verify with `zig build check-headers`.

### Strings and callbacks (pinned revision behavior)

* `WGPUStringView` is `{ data, length }`. `WGPU_STRLEN` as the length means
  NUL-terminated; an exact length permits embedded NULs; `{NULL, 0}` is the
  empty string. `wgpu.stringView([]const u8)` and `wgpu.stringViewZ([:0]const u8)`
  cover both cases used by the examples.
* Callback signatures are the five-argument form
  `(status, result, message, userdata1, userdata2)` declared by `webgpu.h` in
  this revision.
* `WGPUCallbackMode` is part of the callback-info structs but is currently
  **ignored** by wgpu-native. Upstream examples leave it zero, which is exactly
  what the upstream `_INIT` macros specify.
* In this revision `wgpuInstanceRequestAdapter`, `wgpuAdapterRequestDevice`,
  `wgpuDevicePopErrorScope` and `wgpuGenerateReport` invoke their callbacks
  synchronously. `wgpuBufferMapAsync` callbacks and the device uncaptured-error
  callback are delivered while `wgpuDevicePoll(device, true, null)` runs.
* `userdata1`/`userdata2` are passed through verbatim; keep the pointed-to
  memory alive until the callback has run. Keeping locals alive across the
  blocking poll is sufficient.

### Ownership and lifetimes

Following the pinned C API exactly:

* **Retain/release**: every object returned by a `wgpu*Create*`/`wgpu*Get*`
  function is reference counted. Drop your reference with the matching
  `wgpu*Release` (`wgpuBufferRelease`, `wgpuTextureRelease`, `wgpuDeviceRelease`,
  `wgpuAdapterRelease`, `wgpuInstanceRelease`, ...). `wgpu*AddRef` retains.
  Releasing the last reference destroys the underlying resource.
* **Destroy vs release**: `wgpuBufferDestroy`/`wgpuTextureDestroy` free the GPU
  resource eagerly while the handle remains valid until released; use `Destroy`
  to reclaim VRAM early, `Release` for lifetime management. In this revision,
  releasing the last reference to a device also destroys it.
* **Queue**: `wgpuDeviceGetQueue` returns a reference owned by the device;
  `wgpuQueueRelease` only drops the reference you received.
* **Mapped buffers**: `wgpuBufferMapAsync` is asynchronous. Do not touch the
  mapping from the callback; after it completes call
  `wgpuBufferGetMappedRange`, then `wgpuBufferUnmap`. The mapped range is
  invalid after `Unmap` and must not be used afterwards.
* **Async completion**: callbacks are driven by blocking calls. Use
  `wgpuDevicePoll(device, true, null)` to wait for queue work and device
  callbacks, and `wgpuInstanceProcessEvents(instance)` for instance-level
  events. Both are used in the examples.
* **Error reporting**: `wgpuDevicePushErrorScope`/`wgpuDevicePopErrorScope`
  capture errors per scope; the device uncaptured-error callback
  (`WGPUDeviceDescriptor.uncapturedErrorCallbackInfo`) reports everything else.
  `wgpuSetLogCallback`/`wgpuSetLogLevel` (wgpu-native extension) control
  implementation logging. All three are demonstrated.

## Providing the native library

Importing headers is only half of a working setup; applications must link the
matching wgpu-native library. The `wgpu` module propagates the include path,
library path, link requirement, and (for dynamic linking) an rpath, so
consumers do not configure any of this twice.

| Build option | Default | Meaning |
| --- | --- | --- |
| `-Dwgpu-native-prefix=PATH` | auto-detect | wgpu-native install prefix; searches `PATH/lib`, `PATH/lib64`, `PATH/bin`, `PATH` and adds `PATH/include` |
| `-Dwgpu-native-lib=PATH` | — | exact library file; overrides `-Dwgpu-native-prefix` |
| `-Dwgpu-native-include=PATH` | — | extra include directory with matching upstream headers |
| `-Dwgpu-native-linkage=dynamic\|static` | `dynamic` | link `libwgpu_native.so`/`.dylib`/`.dll` or the static archive |
| `-Dwgpu-native-link=true\|false` | `true` | set `false` to manage linking yourself |
| `-Dwgpu-native-reference=PATH` | `.reference/wgpu-native` | source checkout used by `zig build native` |
| `-Dwgpu-native-jobs=N` | — | `CARGO_BUILD_JOBS` for `zig build native` |

Resolution order when no option is given:

1. `.reference/artifacts/prebuilt/lib` (release binaries, see below),
2. `.reference/wgpu-native/target/release` (cargo output),
3. `zig-out/lib` (result of `zig build native`),
4. the system linker search path (`-lwgpu_native`).

Steps 1–3 are package-relative and only used for native targets; ordinary
consumers should pass `-Dwgpu-native-prefix`.

### Route A: prebuilt release binaries (no Cargo)

```sh
tools/fetch-release.sh
# offline alternative: download wgpu-linux-x86_64-release.zip from
# https://github.com/gfx-rs/wgpu-native/releases/tag/v29.0.1.1 and extract it.
zig build -Dwgpu-native-prefix=.reference/artifacts/prebuilt
```

The extracted layout is `include/webgpu/*.h` + `lib/libwgpu_native.{so,a}`,
which is exactly what `-Dwgpu-native-prefix` expects. A supplied prebuilt
library does not require Cargo to compile a Zig consumer.

### Route B: build the pinned source (Cargo required)

```sh
tools/fetch-reference.sh                  # clones v29.0.1.1 + headers submodule
zig build native -Dwgpu-native-jobs=4     # cargo build --release --locked + install
zig build check                           # run both examples against it
```

`zig build native` runs `cargo build --release --locked` in
`.reference/wgpu-native` and installs the resulting shared library into
`zig-out/lib`. Cargo (1.93 per the checkout's `rust-toolchain.toml`) is needed
for this route only. `-Dwgpu-native-reference=PATH` points at a checkout
elsewhere. The step builds for the host; cross-compiling the native library is
out of scope (use the prebuilt release assets for other targets).

### Static linking

```sh
zig build check -Dwgpu-native-linkage=static \
  -Dwgpu-native-lib=.reference/artifacts/prebuilt/lib/libwgpu_native.a
```

The static route links the Rust `staticlib` plus `gcc_s`, `pthread`, `dl` and
`m` on Linux-family targets, and produces self-contained executables (no
runtime library discovery). `-Dwgpu-native-linkage=static` with dynamic
`-Dwgpu-native-lib` is a configuration error; pass the matching archive.

### Runtime discovery and deployment

For dynamic linking the package adds an rpath pointing at the library
directory, so examples run directly from the build tree and cache. For
deployment, either install/copy `libwgpu_native.so` next to the executable or
keep the library where the baked rpath points. Applications that need a
different layout can set `-Dwgpu-native-link=false` and link the library
themselves.

### Cross-compilation

The bindings themselves translate for the consumer's target (verified
compile-only for `x86_64-windows-gnu`, `aarch64-macos` and
`aarch64-linux-gnu` via `zig build check-cross`). The *native library* must
match the target; auto-detection is disabled for non-native targets, so pass a
matching `-Dwgpu-native-prefix`/`-Dwgpu-native-lib` and a libc/sysroot
configuration to Zig. Prebuilt assets exist for Linux, macOS, Windows, Android
and iOS for the pinned tag.

## Complete consumer example

`verify/consumer` is an independent package that depends on this one through
`build.zig`. Full files:

```zig
// build.zig.zon
.{
    .name = .wgpu_consumer,
    .version = "0.0.0",
    .fingerprint = 0xc2e9c31ff2afe771,
    .minimum_zig_version = "0.17.0-dev.2085+5e36170b5",
    .dependencies = .{
        .wgpu = .{ .path = "../.." }, // or a fetched package
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // User options belong to the root package, so forward the ones you want
    // the wgpu package to see. Omit them to use the package's own detection.
    const native_prefix = b.option([]const u8, "wgpu-native-prefix", "wgpu-native prefix");

    const wgpu_dep = b.dependency("wgpu", .{
        .target = target,
        .optimize = optimize,
        .@"wgpu-native-prefix" = native_prefix,
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wgpu", .module = wgpu_dep.module("wgpu") }},
        }),
    });
    b.installArtifact(exe);
}
```

```zig
// src/main.zig
const wgpu = @import("wgpu");
const c = wgpu.c;

pub fn main(init: std.process.Init) !void {
    _ = init;
    const instance = c.wgpuCreateInstance(null) orelse return error.NoInstance;
    defer c.wgpuInstanceRelease(instance);
    // ... request an adapter and device, then use the raw C API.
}
```

Run it from `verify/consumer`:

```sh
zig build run
# or with an explicit native prefix:
zig build run -Dwgpu-native-prefix=../../.reference/artifacts/prebuilt
```

## Running the verification examples

From the package directory, with a native library available (see above):

```sh
zig build check            # runs both examples and the failure-path check
zig build run-compute      # WGSL compute shader + readback, asserted values
zig build run-offscreen    # offscreen render + pixel checks
zig build check-failure    # forced adapter failure; asserts cleanup and exit code
zig build test             # binding unit tests (init defaults, string helpers)
zig build check-cross      # translate + compile the bindings for 3 foreign targets
zig build check-headers    # verify include/wgpu_init.h is up to date
zig build native           # cargo-build and install the pinned native library
```

What is validated and how:

* **Instance/adapter/device**: created in both examples; the adapter name,
  backend, type, vendor/device IDs and hardware-vs-software classification are
  printed. The compute example additionally asserts the intentional validation
  error is captured by `wgpuDevicePushErrorScope`/`PopErrorScope` and does not
  surface as an uncaptured error.
* **Compute**: `examples/compute.zig` writes 8 `u32` values to a storage
  buffer, dispatches a `@workgroup_size(4)` WGSL kernel (`out = in * 2 + 1`),
  copies the result to a map-read staging buffer, maps it, and asserts every
  value (`{ 3, 5, 7, 9, 11, 13, 15, 17 }`).
* **Offscreen rendering**: `examples/offscreen.zig` renders a centered triangle
  over a clear color into a 64x64 RGBA8Unorm texture, copies it to a readback
  buffer, checks the center pixel (triangle color), a corner pixel (clear
  color) and a full-texture pixel census (512 triangle, 3584 clear, 0 other).
* **Cleanup**: both examples release every handle they create on success and on
  early error returns (`defer`), and the consumer smoke test does the same.
  `zig build check-failure` runs the compute example with
  `--force-adapter-failure`, forcing the adapter request to fail so the
  initialization-failure path executes, prints `cleanup: all handles released`,
  and exits with code 1 as expected.
* **Separate consumer**: `verify/consumer` links through a normal
  `b.dependency("wgpu", ...)` and runs the instance/adapter/device/buffer flow.

## Tested platforms

| Platform | Bindings | Linking | Examples executed |
| --- | --- | --- | --- |
| Linux x86_64 (Fedora 44, AMD RADV, Vulkan) | tested | dynamic release `.so`, static release `.a`, cargo-built `.so` | yes, on hardware |
| Linux aarch64 | translate + compile checked (`check-cross`) | not linked | no |
| Windows x86_64 (GNU) | translate + compile checked (`check-cross`) | not linked | no |
| macOS aarch64 | translate + compile checked (`check-cross`) | not linked | no |

Execution proof on the tested machine: `wgpu-example-compute` and
`wgpu-example-offscreen` both pass against `libwgpu_native.so` from the
`v29.0.1.1` release and against the `cargo build --release --locked` library
from the pinned checkout. The reported adapter was
`AMD Radeon Graphics (RADV RENOIR)`, backend `vulkan`, type `integrated-gpu`,
i.e. real hardware; the examples print `execution=software-adapter` when they
land on a CPU implementation such as lavapipe. Everything not listed in the
table is intended but untested.

## Regenerating the vendored headers and shims

```sh
tools/fetch-reference.sh     # if needed
tools/sync-headers.sh        # copy headers, verify hashes, regenerate wgpu_init.h
git diff                     # review
```

After changing the pin, update `tools/pin.env`, the `wgpu_native` struct in
`build.zig`, and the tables in this file.

## Third-party notices

* `include/webgpu/webgpu.h` is the WebGPU C API header from
  [webgpu-headers], BSD-3-Clause (notice retained in the file).
* `include/webgpu/wgpu.h` and the native library are from [wgpu-native],
  MIT OR Apache-2.0.
* This package's own code is part of the enclosing repository.

[wgpu-native]: https://github.com/gfx-rs/wgpu-native
[webgpu-headers]: https://github.com/webgpu-native/webgpu-headers
