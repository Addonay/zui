//! Core primitives: geometry, color, static limits.

pub const geometry = @import("geometry.zig");
pub const color = @import("color.zig");
pub const limits = @import("limits.zig");
pub const shared_string = @import("shared_string.zig");
pub const log = @import("log.zig");

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Color = color.Color;
pub const SharedString = shared_string.SharedString;
pub const string = shared_string.string;

pub const point = geometry.point;
pub const size = geometry.size;
pub const rect = geometry.rect;

test {
    _ = @import("geometry.zig");
    _ = @import("color.zig");
    _ = @import("limits.zig");
    _ = @import("shared_string.zig");
    _ = @import("log.zig");
}
