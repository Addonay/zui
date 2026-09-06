//! Per-frame scene: the GPU-independent draw list.
//!
//! Why a collector: GPUI's `scene.rs` and Gooey's `scene/scene.zig` both
//! collect one frame of quads/glyphs on the CPU, then hand dense batches
//! to Metal/Vulkan/GL. Backends stay thin; batching and clipping live
//! here once. Storage is a fixed array so frames never allocate.

const std = @import("std");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");

pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: color.Color,
    radius: f32 = 0,
};

pub const Scene = struct {
    quads: [limits.MAX_QUADS_PER_FRAME]Quad = undefined,
    len: usize = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn push(self: *@This(), q: Quad) bool {
        std.debug.assert(q.w >= 0);
        std.debug.assert(q.h >= 0);
        if (self.len >= self.quads.len) return false;
        self.quads[self.len] = q;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const @This()) []const Quad {
        return self.quads[0..self.len];
    }
};

test "scene pushes in order and reports overflow" {
    var s = Scene{};
    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expect(s.push(.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = .white }));
    try std.testing.expectEqual(@as(usize, 1), s.slice().len);
    s.len = s.quads.len;
    try std.testing.expect(!s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .black }));
}
