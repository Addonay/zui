//! Runtime probe for the optional real Vellz/WGPU backend.
//!
//! ZUI's default renderer remains CPU Vellz. This probe keeps the GPU gate
//! honest by resolving the actual WGPU device path and acquiring one adapter
//! and device; surface presentation is still a separate integration step.
const std = @import("std");
const vellz = @import("vellz");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const backend = vellz.gpu.backend;

    var instance = try backend.Instance.create();
    defer instance.deinit();

    var adapter = try backend.Adapter.acquire(&instance, .{});
    defer adapter.deinit();
    adapter.info.print();

    var device = try backend.Device.acquire(allocator, &adapter, "zui-gpu-probe");
    defer device.deinit();
    const limits = try device.getLimits();
    if (limits.max_texture_dimension_2d == 0) return error.InvalidDeviceLimits;
    try device.check();

    // Force analysis of the offscreen renderer as part of the same gate. It
    // is not initialized here because that would require a target texture;
    // the Vellz package owns the full offscreen corpus gate separately.
    _ = backend.renderer.Renderer;
    std.debug.print("PASS: WGPU device acquired; maxTextureDimension2D={d}\n", .{limits.max_texture_dimension_2d});
}
