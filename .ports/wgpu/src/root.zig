//! wgpu — raw Zig bindings to wgpu-native.
//!
//! The implementation underneath remains [wgpu-native], the Rust WebGPU
//! implementation by the `gfx-rs` project. This package does not port it and
//! does not wrap it in a higher-level GPU abstraction: it exposes the C ABI
//! declared by the pinned upstream headers and integrates the matching native
//! library with the Zig build system.
//!
//! [wgpu-native]: https://github.com/gfx-rs/wgpu-native
//!
//! ## Using the raw API
//!
//! ```zig
//! const wgpu = @import("wgpu");
//! const c = wgpu.c;
//!
//! const instance = c.wgpuCreateInstance(null) orelse return error.NoInstance;
//! defer c.wgpuInstanceRelease(instance);
//! ```
//!
//! `c` is the complete translated API: types, enums, callback types, constants
//! and `wgpu*` functions, plus the generated `wgpu_zig_init_*` descriptor
//! helpers (see below).
//!
//! The C API is translated at build time with `zig translate-c`, for the
//! consumer's target and C flags, so there is one translation unit and one
//! identity for every C type. `@cImport` is not used because it was removed in
//! Zig 0.17.
//!
//! ## Descriptor initialization
//!
//! Upstream `webgpu.h` defines a `WGPU_*_INIT` compound-literal macro per
//! struct. `translate-c` cannot translate those macros, and zeroing a
//! descriptor is not always equivalent to its initializer (for example
//! `WGPU_TEXTURE_DESCRIPTOR_INIT` sets `mipLevelCount = 1` and
//! `sampleCount = 1`, and `WGPU_BIND_GROUP_ENTRY_INIT` sets
//! `size = WGPU_WHOLE_SIZE`). The package therefore ships generated C shims
//! (`include/wgpu_init.h`) which translate-c turns into Zig functions:
//!
//! ```zig
//! var desc = c.wgpu_zig_init_WGPUBufferDescriptor();
//! desc.size = 1024;
//! desc.usage = c.WGPUBufferUsage_Storage;
//! ```
//!
//! Use those instead of `std.mem.zeroes` whenever an upstream `_INIT` macro
//! exists.
//!
//! ## Ownership and lifetimes (pinned v29.0.1.1 API)
//!
//! * Every object handle returned by a `wgpuDeviceCreate*`/`wgpuCreate*`
//!   function is reference counted. Drop your reference with the matching
//!   `wgpu*Release` function: `wgpuBufferRelease`, `wgpuTextureRelease`,
//!   `wgpuShaderModuleRelease`, `wgpuDeviceRelease`, `wgpuAdapterRelease`,
//!   `wgpuInstanceRelease`, and so on. Releasing the last reference destroys
//!   the underlying resource.
//! * `wgpuBufferDestroy`/`wgpuTextureDestroy` destroy the GPU resource
//!   eagerly while the handle stays valid until released. Use `Destroy` to
//!   free VRAM early; use `Release` for lifetime management. The pinned
//!   revision documents that releasing the last reference to a `WGPUDevice`
//!   also calls `wgpuDeviceDestroy`.
//! * A `WGPUQueue` obtained from `wgpuDeviceGetQueue` is owned by the device;
//!   `wgpuQueueRelease` only drops the reference you received.
//! * Callbacks pass their `userdata1`/`userdata2` through verbatim. The memory
//!   they point at must stay alive until the callback runs. In this revision
//!   `wgpuInstanceRequestAdapter`, `wgpuAdapterRequestDevice` and
//!   `wgpuDevicePopErrorScope` invoke their callbacks synchronously, while
//!   `wgpuBufferMapAsync` and the device uncaptured-error callback are
//!   delivered during `wgpuDevicePoll(device, true, null)`. Keeping locals
//!   alive until after the blocking call is sufficient. `WGPUCallbackMode` is
//!   accepted but currently ignored by the implementation.
//! * `wgpuBufferMapAsync` callbacks must not be used to touch the mapping;
//!   after the callback fires, call `wgpuBufferGetMappedRange`, then
//!   `wgpuBufferUnmap` when done. The mapped range is invalid after `Unmap`
//!   and must not outlive it.
//! * `WGPUStringView` is `{ data, length }`. Pass `WGPU_STRLEN` as the length
//!   for a NUL-terminated string, or the exact byte length (which permits
//!   embedded NULs). The two helpers below cover the common cases.
//!
//! `wgpuSetLogCallback`/`wgpuSetLogLevel` (wgpu-native extensions) and the
//! standard error scopes (`wgpuDevicePushErrorScope`/`PopErrorScope`) are the
//! error-reporting mechanisms in this revision.

const std = @import("std");

/// The translated wgpu-native C API. See the module documentation for usage.
pub const c = @import("c");

/// A `WGPUStringView` over a byte slice with an explicit length. The slice
/// must remain valid for as long as the API may read it.
pub fn stringView(text: []const u8) c.WGPUStringView {
    return .{ .data = text.ptr, .length = text.len };
}

/// A `WGPUStringView` with the `WGPU_STRLEN` sentinel, for a NUL-terminated
/// Zig string such as a string literal or a `[:0]const u8`.
pub fn stringViewZ(text: [:0]const u8) c.WGPUStringView {
    return .{ .data = text.ptr, .length = c.WGPU_STRLEN };
}

test "descriptor initializer shims follow upstream defaults" {
    // WGPU_TEXTURE_DESCRIPTOR_INIT: zeroing is not equivalent.
    const texture = c.wgpu_zig_init_WGPUTextureDescriptor();
    try std.testing.expectEqual(@as(u32, 1), texture.mipLevelCount);
    try std.testing.expectEqual(@as(u32, 1), texture.sampleCount);
    try std.testing.expectEqual(@as(u32, 1), texture.size.height);
    try std.testing.expectEqual(@as(u32, 1), texture.size.depthOrArrayLayers);

    // WGPU_BIND_GROUP_ENTRY_INIT: WGPU_WHOLE_SIZE, not zero.
    const entry = c.wgpu_zig_init_WGPUBindGroupEntry();
    try std.testing.expectEqual(@as(u64, c.WGPU_WHOLE_SIZE), entry.size);

    // WGPU_STRING_VIEW_INIT: the length sentinel, not zero.
    const view = c.wgpu_zig_init_WGPUStringView();
    try std.testing.expectEqual(c.WGPU_STRLEN, view.length);

    // WGPU_MULTISAMPLE_STATE_INIT: one sample and a full mask, not zeros.
    const multisample = c.wgpu_zig_init_WGPUMultisampleState();
    try std.testing.expectEqual(@as(u32, 1), multisample.count);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), multisample.mask);

    // WGPU_SAMPLER_DESCRIPTOR_INIT: lodMaxClamp and maxAnisotropy have
    // non-zero defaults.
    const sampler = c.wgpu_zig_init_WGPUSamplerDescriptor();
    try std.testing.expectEqual(@as(f32, 32.0), sampler.lodMaxClamp);
    try std.testing.expectEqual(@as(u16, 1), sampler.maxAnisotropy);
}

test "string view helpers" {
    const text = "wgpu";
    const explicit = stringView(text);
    try std.testing.expectEqual(@as(usize, 4), explicit.length);

    const zero_terminated = stringViewZ("wgpu");
    try std.testing.expectEqual(c.WGPU_STRLEN, zero_terminated.length);
}
