# Verification results

Captured during package development on the machine below. These are real
executions, not compile-only checks.

## Environment

* OS: Fedora Linux 44, kernel `7.1.10-200.fc44.x86_64`, x86_64
* GPU (hardware): AMD Radeon Graphics (RADV RENOIR), RADV, Mesa 26.1.8,
  Vulkan 1.4.354, `PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`
* GPU (software, used for the fallback test): llvmpipe (LLVM 22.1.8, 256 bits),
  `PHYSICAL_DEVICE_TYPE_CPU`
* Zig: `0.17.0-dev.2085+5e36170b5`
* Native library variants used:
  * release `libwgpu_native.so` SHA-256
    `be0d8270dd9d78e1039eeb413ee21be8a89776a752e56d6b0f57eefbbc2d749c`
  * release `libwgpu_native.a` SHA-256
    `011dc082d31c060202e519548fdc2163974b3d2042e64be95f5d143ce03dfbd4`
  * source build from the pinned checkout, `cargo build --release --locked`
    with `rustc 1.93.1`, SHA-256
    `fb5c22093a06a1a4d05fb9e18bd76d9417f2abd6020b3243bf6a7b50d3d80b95`
    (built in 7m25s with `CARGO_BUILD_JOBS=4`)

## Dynamic linking, release binary, hardware

`zig build check` (runs `run-compute`, `run-offscreen` and the forced-failure
check):

```
adapter: description="Mesa 26.1.8" device="AMD Radeon Graphics (RADV RENOIR)" vendor="radv" architecture=""
adapter: backend=vulkan type=integrated-gpu execution=hardware vendorID=0x1002 deviceID=0x15e7
center pixel: { 255, 0, 0, 255 } (expected { 255, 0, 0, 255 })
corner pixel: { 64, 128, 191, 255 } (expected { 64, 128, 191, 255 })
pixel census: 512 triangle, 3584 clear, 0 other (of 4096)
PASS: offscreen render pixels verified
adapter: description="Mesa 26.1.8" device="AMD Radeon Graphics (RADV RENOIR)" vendor="radv" architecture=""
adapter: backend=vulkan type=integrated-gpu execution=hardware vendorID=0x1002 deviceID=0x15e7
error scope captured validation error: "Validation Error

Caused by:
  In wgpuDeviceCreateBuffer, label = 'invalid buffer'
    `MAP` usage can only be combined with the opposite `COPY`, requested BufferUsages(MAP_READ | STORAGE)
"
compute output: { 3, 5, 7, 9, 11, 13, 15, 17 }
PASS: compute result verified against expected values
request_adapter failed: status=3 message="Validation Error

Caused by:
  No suitable graphics adapter found; ...
"
FAIL: no compatible adapter found
cleanup: all handles released
```

Exit status: 0 (all assertions pass; the forced-failure run is expected to
exit 1 and does).

## Static linking, release archive, hardware

`zig build check -Dwgpu-native-linkage=static`:

```
wgpu: native library: .reference/artifacts/prebuilt/lib/libwgpu_native.a
adapter: description="Mesa 26.1.8" device="AMD Radeon Graphics (RADV RENOIR)" vendor="radv" architecture=""
adapter: backend=vulkan type=integrated-gpu execution=hardware vendorID=0x1002 deviceID=0x15e7
pixel census: 512 triangle, 3584 clear, 0 other (of 4096)
PASS: offscreen render pixels verified
...
compute output: { 3, 5, 7, 9, 11, 13, 15, 17 }
PASS: compute result verified against expected values
```

## Source-built library, hardware

`zig build check -Dwgpu-native-lib=zig-out/lib/libwgpu_native.so` (the library
installed by `zig build native`):

```
adapter: description="Mesa 26.1.8" device="AMD Radeon Graphics (RADV RENOIR)" vendor="radv" architecture=""
adapter: backend=vulkan type=integrated-gpu execution=hardware vendorID=0x1002 deviceID=0x15e7
compute output: { 3, 5, 7, 9, 11, 13, 15, 17 }
PASS: compute result verified against expected values
...
PASS: offscreen render pixels verified
```

## Software adapter

`zig build run-compute -- --force-fallback-adapter`:

```
adapter: description="Mesa 26.1.8 (LLVM 22.1.8)" device="llvmpipe (LLVM 22.1.8, 256 bits)" vendor="llvmpipe" architecture=""
adapter: backend=vulkan type=cpu execution=software-adapter vendorID=0x10005 deviceID=0x0
compute output: { 3, 5, 7, 9, 11, 13, 15, 17 }
PASS: compute result verified against expected values
```

## Ordinary use without the reference checkout

A clean copy of the distributed file set (no `.reference/`) with an external
prefix:

```
zig build check -Dwgpu-native-prefix=/path/to/prebuilt
wgpu: native library: prefix /path/to/prebuilt
...
PASS: compute result verified against expected values
PASS: offscreen render pixels verified
```

## Additional checks

* `zig build test` — passes (generated initializer defaults, string helpers).
* `zig build check-cross` — translates and compiles the bindings for
  `x86_64-windows-gnu`, `aarch64-macos`, `aarch64-linux-gnu` (compile only).
* `zig build check-headers` — `include/wgpu_init.h is up to date`.
* `zig build native` — `cargo build --release --locked` succeeds in the pinned
  checkout and installs `zig-out/lib/libwgpu_native.so`.
* `verify/consumer` — `zig build run` through a path dependency:
  `consumer: PASS (instance, adapter, device and buffer created)`; also passes
  with `-Dwgpu-native-prefix=../../.reference/artifacts/prebuilt` and with
  `-Dwgpu-native-linkage=static` (the option is forwarded through
  `b.dependency`).
* Clean copy of the distributed file set (no `.reference/`) with
  `-Dwgpu-native-prefix=<external prebuilt>`: `zig build check check-headers`
  passes, including the forced-failure cleanup check.
