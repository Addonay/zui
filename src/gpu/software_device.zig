//! Software GPU device: the vellz CPU renderer behind the full device vtable.
//!
//! Layout-compatible with `NullDevice` (its `base` is the first field, so
//! every non-overridden vtable entry — which casts to `*NullDevice` —
//! keeps working; see the comptime offset assert). Only `drawScene` is
//! overridden: it rasterizes the `Scene` into the attached frame through the
//! caller-owned `vellz.Renderer`, then counts the draw like null does.
//! Backends with CPU-visible swapchain memory (Wayland SHM, X11 `XShm`)
//! attach their mapped buffer each frame with `attachFrame`.
//!
//! TODO(gpu-software): resource calls are validation-only (shared null
//! entries) — buffers/textures have no CPU backing. Decide when Vulkan
//! lands: either back them with fixed pools (glyph staging, readback
//! tests) or keep validation-only and document software as present-only.

const std = @import("std");
const device = @import("device.zig");
const null_device = @import("null_device.zig");
const vellz = @import("vellz.zig");
const scene_mod = @import("scene.zig");

pub const SoftwareDevice = struct {
    base: null_device.NullDevice = .{},
    renderer: ?*vellz.Renderer = null,
    frame: ?Frame = null,

    comptime {
        // The whole vtable-sharing trick depends on this.
        if (@offsetOf(@This(), "base") != 0) @compileError("SoftwareDevice.base must be the first field");
    }

    /// One attached CPU-visible frame buffer.
    pub const Frame = struct {
        pixels: []u8,
        width: u32,
        height: u32,
        format: vellz.PixelFormat = .rgba32,
        /// Background color applied by every `drawScene` (vellz clears the
        /// internal pixmap, which is then converted into `pixels`).
        clear: vellz.Color = .transparent,
    };

    pub const vtable: device.VTable = blk: {
        var t = null_device.NullDevice.vtable;
        t.kind = kindFn;
        t.driverName = driverNameFn;
        t.shaderFormats = shaderFormatsFn;
        t.drawScene = drawSceneFn;
        break :blk t;
    };

    pub fn handle(self: *@This()) device.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Point the device at a caller-owned renderer and CPU-visible frame
    /// memory. Both must outlive every `drawScene` until `detachFrame`.
    pub fn attachFrame(self: *@This(), renderer: *vellz.Renderer, frame: Frame) void {
        self.renderer = renderer;
        self.frame = frame;
    }

    pub fn detachFrame(self: *@This()) void {
        self.frame = null;
        self.renderer = null;
    }

    fn kindFn(ptr: *anyopaque) device.DeviceKind {
        _ = ptr;
        return .software;
    }

    fn driverNameFn(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return device.DeviceKind.software.name();
    }

    fn shaderFormatsFn(ptr: *anyopaque) u32 {
        _ = ptr;
        return device.shaderFormatsFor(.software);
    }

    fn drawSceneFn(ptr: *anyopaque, cmd: *device.CommandBuffer, scene: *const scene_mod.Scene, pixels: []const u8) bool {
        _ = cmd;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.renderer) |renderer| {
            if (self.frame) |frame| {
                renderer.render(frame.pixels, frame.width, frame.height, frame.format, frame.clear, scene, pixels, &.{}) catch |err| {
                    std.debug.print("software device: vellz render failed: {s}\n", .{@errorName(err)});
                    return false;
                };
            }
        }
        self.base.tracker.draws += 1;
        return true;
    }
};

test "software device rasterizes scenes into the attached frame" {
    const core = @import("../core/color.zig");
    var dev = SoftwareDevice{};
    const d = dev.handle();
    try std.testing.expectEqual(device.DeviceKind.software, d.kind());
    try std.testing.expectEqualStrings("software", d.driverName());

    // No frame attached: counts, paints nothing, never crashes.
    try std.testing.expect(d.render(&scene_mod.Scene{}, &.{}));

    var renderer = vellz.Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var buf: [8 * 8 * 4]u8 = std.mem.zeroes([8 * 8 * 4]u8);
    dev.attachFrame(&renderer, .{
        .pixels = &buf,
        .width = 8,
        .height = 8,
        .format = .rgba32,
        .clear = core.Color.black,
    });

    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.push(.{
        .x = 2,
        .y = 2,
        .w = 4,
        .h = 4,
        .color = core.Color.hex(0xFF0000),
    }));
    try std.testing.expect(d.render(&scene, &.{}));
    // Pixel (3,3) is red now; corner (0,0) stayed black.
    try std.testing.expectEqual(@as(u8, 255), buf[(3 * 8 + 3) * 4]);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);

    dev.detachFrame();
    var cmd = d.acquireCommandBuffer();
    try std.testing.expect(d.submitCommandBuffer(&cmd));

    // Resource tracking still works through the shared null entries.
    const b = try d.createBuffer(.{ .usage = device.BufferUsage.vertex, .size = 32 });
    d.releaseBuffer(b);
}
