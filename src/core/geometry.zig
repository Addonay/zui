//! Geometry primitives shared by layout, scene, and backends.
//!
//! Why plain f32 structs: layout works in logical pixels, the painter
//! converts to physical once via content scale. Keeping one canonical
//! type avoids per-backend drift (shared window-struct fields and one
//! rect type everywhere).

const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn isEmpty(self: @This()) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: @This(), p: Point) bool {
        if (p.x < self.x) return false;
        if (p.y < self.y) return false;
        if (p.x > self.x + self.w) return false;
        if (p.y > self.y + self.h) return false;
        return true;
    }

    pub fn intersects(self: @This(), other: @This()) bool {
        if (self.x + self.w < other.x) return false;
        if (other.x + other.w < self.x) return false;
        if (self.y + self.h < other.y) return false;
        if (other.y + other.h < self.y) return false;
        return true;
    }
};

pub const Bounds = struct {
    origin: Point = .{},
    size: Size = .{},

    pub fn rect(self: @This()) Rect {
        return .{ .x = self.origin.x, .y = self.origin.y, .w = self.size.w, .h = self.size.h };
    }

    pub fn centered(parent: ?Rect, sz: Size, cx: anytype) Bounds {
        _ = cx;
        if (parent) |p| {
            return .{
                .origin = .{
                    .x = p.x + (p.w - sz.w) / 2.0,
                    .y = p.y + (p.h - sz.h) / 2.0,
                },
                .size = sz,
            };
        }
        const screen_w: f32 = 1920;
        const screen_h: f32 = 1080;
        return .{
            .origin = .{
                .x = @max(0.0, (screen_w - sz.w) / 2.0),
                .y = @max(0.0, (screen_h - sz.h) / 2.0),
            },
            .size = sz,
        };
    }
};

pub fn point(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

pub fn size(w: f32, h: f32) Size {
    return .{ .w = w, .h = h };
}

pub fn rect(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

test "rect contains is inclusive of edges" {
    const r = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expect(r.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(r.contains(.{ .x = 10, .y = 10 }));
    try std.testing.expect(!r.contains(.{ .x = 11, .y = 5 }));
}

test "rect intersects rejects separated boxes" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 20, .y = 20, .w = 10, .h = 10 };
    const c = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expect(!a.intersects(b));
    try std.testing.expect(a.intersects(c));
}

test "bounds centered centers within parent or screen" {
    const b1 = Bounds.centered(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, Size{ .w = 40, .h = 20 }, {});
    try std.testing.expectEqual(@as(f32, 30), b1.origin.x);
    try std.testing.expectEqual(@as(f32, 40), b1.origin.y);
    try std.testing.expectEqual(@as(f32, 40), b1.size.w);
    try std.testing.expectEqual(@as(f32, 20), b1.size.h);

    const b2 = Bounds.centered(null, Size{ .w = 800, .h = 600 }, {});
    try std.testing.expectEqual(@as(f32, (1920 - 800) / 2.0), b2.origin.x);
    try std.testing.expectEqual(@as(f32, (1080 - 600) / 2.0), b2.origin.y);
}
