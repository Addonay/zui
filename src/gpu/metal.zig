//! Metal driver skeleton (macOS-only).
//!
//! Pattern modeled on SDL3 `src/gpu/metal/SDL_gpu_metal.m` (zlib,
//! Copyright 1997-2026 Sam Lantinga), reimplemented in Zig — no verbatim
//! ObjC ported. The real driver talks to `MTLDevice` (via
//! `MTLCreateSystemDefaultDevice`), compiles MSL/`metallib` shaders into a
//! `MTLLibrary`, and presents through the `CAMetalLayer` backing the
//! `NSView` from `platform/macos/cocoa.zig`, supplied as
//! `device.SurfaceHandle{ .tag = .cocoa }`. Shader format bits:
//! `msl | metallib` (see `device.shaderFormatsFor`). Cannot be verified on
//! this Linux box: `isAvailable()` is macOS-only and `init()` stays
//! `error.Unsupported` until the driver lands.

const std = @import("std");
const builtin = @import("builtin");
const device = @import("device.zig");
const scene_mod = @import("scene.zig");

/// Objective-C runtime entry points the driver will resolve via
/// `platform/macos/bindings.zig` (names only until the driver lands):
/// `objc_getClass` ("MTLCreateSystemDefaultDevice" lives in Metal.framework
/// itself: `MTLCreateSystemDefaultDevice`), `CAMetalLayer` ("CAMetalLayer"),
/// selectors `device`, `newCommandQueue`, `newLibraryWithSource:options:error:`,
/// `newRenderPipelineStateWithDescriptor:error:`, `currentDrawable`,
/// `presentDrawable:`, `commit`, `waitUntilCompleted`.
pub const planned_objc_selectors: []const []const u8 = &.{
    "MTLCreateSystemDefaultDevice",
    "CAMetalLayer",
    "device",
    "newCommandQueue",
    "currentDrawable",
    "presentDrawable:",
    "commit",
};

pub const MetalDevice = struct {
    tracker: device.Tracker = .{ .kind = .metal },

    // TODO(gpu-metal): real init, in order —
    // 1. MTLCreateSystemDefaultDevice via platform/macos/bindings.zig;
    //    hard error when nil (no software fallback inside this driver —
    //    that is what the software device is for).
    // 2. command queue + per-frame-in-flight command buffers.
    // 3. MTLLibrary from offline metallib (@embedFile) or MSL source;
    //    textured-rect pipeline matching the Vulkan quad pipeline's
    //    vertex layout so Scene translation is shared.
    // 4. CAMetalLayer on the Cocoa NSView (SurfaceHandle .cocoa);
    //    nextDrawable/presentDrawable driven by waitAndAcquireSwapchainTexture.
    // NOTE: needs macOS hardware to verify; keep the stub green until then.

    pub fn isAvailable() bool {
        return builtin.os.tag == .macos;
    }

    pub fn init() !void {
        return error.Unsupported;
    }

    pub fn handle(self: *@This()) device.Device {
        return .{ .ptr = &self.tracker, .vtable = &device.stub_vtable };
    }
};

test "metal stub reports kind but constructs nowhere on linux" {
    var m = MetalDevice{};
    const d = m.handle();
    try std.testing.expectEqual(device.DeviceKind.metal, d.kind());
    try std.testing.expectEqualStrings("metal", d.driverName());
    try std.testing.expectError(error.Unsupported, MetalDevice.init());
    if (builtin.os.tag != .macos) try std.testing.expect(!MetalDevice.isAvailable());
    try std.testing.expect(d.render(&scene_mod.Scene{}, &.{}));
    try std.testing.expect(planned_objc_selectors.len >= 5);
}
