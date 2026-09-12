//! Outline pens: the `skrifa` `OutlinePen` sink, adapted to Zig.
//!
//! `skrifa`'s `OutlinePen` is infallible; Zig's `BezPath` allocates, so the
//! sinks here own an allocator and the callbacks return `!void` (documented
//! adaptation in `.ports/vellz/docs/glifo-m3-plan.md` §3). `PathElementPen`
//! keeps the raw f32 values for the `--dump-glyphs` oracle comparison;
//! `PathPen` records into `vellz.kurbo.BezPath` for the renderer.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");

/// A single path element with the exact f32 coordinates emitted by the
/// scaler, mirroring `read-fonts`' `PathElement`.
pub const PathElement = union(enum) {
    move_to: [2]f32,
    line_to: [2]f32,
    quad_to: struct { c0: [2]f32, p: [2]f32 },
    curve_to: struct { c0: [2]f32, c1: [2]f32, p: [2]f32 },
    close,

    pub fn eql(a: PathElement, b: PathElement) bool {
        return switch (a) {
            .move_to => |v| switch (b) {
                .move_to => |w| std.meta.eql(v, w),
                else => false,
            },
            .line_to => |v| switch (b) {
                .line_to => |w| std.meta.eql(v, w),
                else => false,
            },
            .quad_to => |v| switch (b) {
                .quad_to => |w| std.meta.eql(v, w),
                else => false,
            },
            .curve_to => |v| switch (b) {
                .curve_to => |w| std.meta.eql(v, w),
                else => false,
            },
            .close => b == .close,
        };
    }
};

/// Pen that records `PathElement`s (f32 bit-exact).
pub const PathElementPen = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(PathElement) = .empty,

    pub fn init(allocator: std.mem.Allocator) PathElementPen {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PathElementPen) void {
        self.elements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *PathElementPen) void {
        self.elements.clearRetainingCapacity();
    }

    pub fn moveTo(self: *PathElementPen, x: f32, y: f32) !void {
        try self.elements.append(self.allocator, .{ .move_to = .{ x, y } });
    }

    pub fn lineTo(self: *PathElementPen, x: f32, y: f32) !void {
        try self.elements.append(self.allocator, .{ .line_to = .{ x, y } });
    }

    pub fn quadTo(self: *PathElementPen, cx0: f32, cy0: f32, x: f32, y: f32) !void {
        try self.elements.append(self.allocator, .{
            .quad_to = .{ .c0 = .{ cx0, cy0 }, .p = .{ x, y } },
        });
    }

    pub fn curveTo(
        self: *PathElementPen,
        cx0: f32,
        cy0: f32,
        cx1: f32,
        cy1: f32,
        x: f32,
        y: f32,
    ) !void {
        try self.elements.append(self.allocator, .{
            .curve_to = .{
                .c0 = .{ cx0, cy0 },
                .c1 = .{ cx1, cy1 },
                .p = .{ x, y },
            },
        });
    }

    pub fn close(self: *PathElementPen) !void {
        try self.elements.append(self.allocator, .close);
    }
};

/// Pen that records into a caller-owned `kurbo.BezPath`.
pub const PathPen = struct {
    allocator: std.mem.Allocator,
    path: *kurbo.BezPath,

    pub fn init(allocator: std.mem.Allocator, path: *kurbo.BezPath) PathPen {
        return .{ .allocator = allocator, .path = path };
    }

    pub fn moveTo(self: *PathPen, x: f32, y: f32) !void {
        try self.path.moveTo(self.allocator, kurbo.Point.new(x, y));
    }

    pub fn lineTo(self: *PathPen, x: f32, y: f32) !void {
        try self.path.lineTo(self.allocator, kurbo.Point.new(x, y));
    }

    pub fn quadTo(self: *PathPen, cx0: f32, cy0: f32, x: f32, y: f32) !void {
        try self.path.quadTo(
            self.allocator,
            kurbo.Point.new(cx0, cy0),
            kurbo.Point.new(x, y),
        );
    }

    pub fn curveTo(
        self: *PathPen,
        cx0: f32,
        cy0: f32,
        cx1: f32,
        cy1: f32,
        x: f32,
        y: f32,
    ) !void {
        try self.path.curveTo(
            self.allocator,
            kurbo.Point.new(cx0, cy0),
            kurbo.Point.new(cx1, cy1),
            kurbo.Point.new(x, y),
        );
    }

    pub fn close(self: *PathPen) !void {
        try self.path.closePath(self.allocator);
    }
};

test "PathElementPen records in order" {
    var pen = PathElementPen.init(std.testing.allocator);
    defer pen.deinit();
    try pen.moveTo(1.0, 2.0);
    try pen.quadTo(3.0, 4.0, 5.0, 6.0);
    try pen.curveTo(7.0, 8.0, 9.0, 10.0, 11.0, 12.0);
    try pen.lineTo(0.0, 0.0);
    try pen.close();
    try std.testing.expectEqual(@as(usize, 5), pen.elements.items.len);
    try std.testing.expectEqual(@as(f32, 3.0), pen.elements.items[1].quad_to.c0[0]);
    try std.testing.expect(PathElement.close == pen.elements.items[4]);
}

test "PathPen mirrors elements into a BezPath" {
    var path = kurbo.BezPath.init();
    defer path.deinit(std.testing.allocator);
    var pen = PathPen.init(std.testing.allocator, &path);
    try pen.moveTo(1.5, -2.25);
    try pen.lineTo(3.0, 4.0);
    try pen.quadTo(5.0, 6.0, 7.0, 8.0);
    try pen.close();
    try std.testing.expectEqual(@as(usize, 4), path.elementsSlice().len);
    const first = path.elementsSlice()[0];
    switch (first) {
        .MoveTo => |p| {
            try std.testing.expectEqual(@as(f64, 1.5), p.x);
            try std.testing.expectEqual(@as(f64, -2.25), p.y);
        },
        else => return error.TestUnexpectedResult,
    }
}
