//! Core primitives: geometry, color, static limits.

pub const geometry = @import("geometry.zig");
pub const color = @import("color.zig");
pub const limits = @import("limits.zig");
pub const shared_string = @import("shared_string.zig");
pub const log = @import("log.zig");
pub const queue = @import("queue.zig");
pub const refineable = @import("refineable.zig");
pub const shared_uri = @import("shared_uri.zig");
pub const arc_cow = @import("arc_cow.zig");

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Color = color.Color;
pub const SharedString = shared_string.SharedString;
pub const string = shared_string.string;
pub const Priority = queue.Priority;
pub const PriorityQueue = queue.PriorityQueue;
pub const PriorityQueueSender = queue.PriorityQueueSender;
pub const PriorityQueueReceiver = queue.PriorityQueueReceiver;
pub const Refinement = refineable.Refinement;
pub const StyleValue = refineable.Refinement;
pub const Cascade = refineable.Cascade;
pub const SharedUri = shared_uri.SharedUri;
pub const ArcCow = arc_cow.ArcCow;

pub const point = geometry.point;
pub const size = geometry.size;
pub const rect = geometry.rect;

test {
    _ = @import("geometry.zig");
    _ = @import("color.zig");
    _ = @import("limits.zig");
    _ = @import("shared_string.zig");
    _ = @import("log.zig");
    _ = @import("queue.zig");
    _ = @import("refineable.zig");
    _ = @import("shared_uri.zig");
    _ = @import("arc_cow.zig");
}
