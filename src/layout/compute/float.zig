//! Float placement for a block formatting context.
//!
//! This follows the state model in Taffy's `compute/float.rs`: floats are
//! retained by side, clearance bottoms are retained even for zero-height
//! floats, and every placement searches downward until the full outer box
//! fits between the active float edges. The Rust segment cache is represented
//! here by the same observable float bands, calculated from the placed boxes;
//! the later optimization can restore explicit segment subdivision without
//! changing this API.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const available = @import("../style/available_space.zig");

pub const FloatLayoutStatus = enum { no_float, left, right };
pub const FIT_TOLERANCE: f32 = 0.001;

pub const ContentSlot = struct {
    segment_id: ?usize = null,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = std.math.inf(f32),
};

pub const BfcSlot = struct {
    segment_id: ?usize = null,
    x: f32 = 0,
    y: f32 = 0,
    border_width: f32 = 0,
    stretch_width: f32 = 0,
};

pub const PlacedFloatedBox = struct {
    width: f32 = 0,
    height: f32 = 0,
    x_inset: f32 = 0,
    y: f32 = 0,
};

/// A non-overlapping vertical band in the block formatting context. Taffy
/// uses these bands so a float's full height can be checked against a stable
/// horizontal inset instead of repeatedly walking every float box.
pub const Segment = struct {
    y_start: f32,
    y_end: f32,
    insets: [2]f32 = .{ 0, 0 },
    has_float: [2]bool = .{ false, false },

    pub fn contains(self: Segment, y: f32) bool {
        return self.y_start <= y and y < self.y_end;
    }

    pub fn fits_float_width(self: Segment, floated_box: geometry.Size(f32), direction: style.float.FloatDirection, bfc_width: f32, cb_insets: [2]f32) bool {
        return float_fits_horizontally(floated_box.width, direction, bfc_width, .{
            .left = self.insets[0],
            .right = self.insets[1],
            .has_left = self.has_float[0],
            .has_right = self.has_float[1],
        }, cb_insets);
    }
};

pub const SegmentRange = struct { start: usize, end: usize };

const SideInsets = struct {
    left: f32 = 0,
    right: f32 = 0,
    has_left: bool = false,
    has_right: bool = false,
};

fn float_fits_horizontally(width: f32, direction: style.float.FloatDirection, bfc_width: f32, float_insets: SideInsets, cb_insets: [2]f32) bool {
    const lead: usize = @backingInt(direction);
    const trail = 1 - lead;
    const lead_inset = if (lead == 0) float_insets.left else float_insets.right;
    const trail_inset = if (trail == 0) float_insets.left else float_insets.right;
    const lead_has_float = if (lead == 0) float_insets.has_left else float_insets.has_right;
    const trail_has_float = if (trail == 0) float_insets.has_left else float_insets.has_right;
    const x_inset = @max(lead_inset, cb_insets[lead]);
    const opposite_floats_fit = !trail_has_float or x_inset + width <= bfc_width - trail_inset + FIT_TOLERANCE;
    const containing_block_fit = !lead_has_float or x_inset + width <= bfc_width - cb_insets[trail] + FIT_TOLERANCE;
    return opposite_floats_fit and containing_block_fit;
}

const FloatFitter = struct {
    bfc_width: f32,
    slot_height: f64,
    float_insets: SideInsets = .{},
    cb_insets: [2]f32,

    fn new(bfc_width: f32, slot_height: f32, cb_insets: [2]f32) FloatFitter {
        return .{ .bfc_width = bfc_width, .slot_height = slot_height, .cb_insets = cb_insets };
    }

    fn union_insets(self: *FloatFitter, insets: SideInsets) void {
        self.float_insets.left = @max(self.float_insets.left, insets.left);
        self.float_insets.right = @max(self.float_insets.right, insets.right);
        self.float_insets.has_left = self.float_insets.has_left or insets.has_left;
        self.float_insets.has_right = self.float_insets.has_right or insets.has_right;
    }

    fn placed_inset(self: *const FloatFitter, direction: style.float.FloatDirection) f32 {
        const side = @backingInt(direction);
        return @max(if (side == 0) self.float_insets.left else self.float_insets.right, self.cb_insets[side]);
    }

    fn fits_horiontally(self: *const FloatFitter, width: f32, direction: style.float.FloatDirection) bool {
        return float_fits_horizontally(width, direction, self.bfc_width, self.float_insets, self.cb_insets);
    }

    fn add_height(self: *FloatFitter, height: f32) void {
        self.slot_height += @as(f64, height);
    }

    fn fits_vertically(self: *const FloatFitter, height: f32) bool {
        return self.slot_height + FIT_TOLERANCE >= @as(f64, height);
    }
};

pub const FloatContext = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    available_width: f32 = 0,
    has_any_float: bool = false,
    left_boxes: std.ArrayList(PlacedFloatedBox) = .empty,
    right_boxes: std.ArrayList(PlacedFloatedBox) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    last_placed_floats: [2]SegmentRange = .{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    clear_bottoms: [2]?f32 = .{ null, null },
    float_ceiling: ?f32 = null,
    last_containing_block_insets: [2]f32 = .{ 0, 0 },

    pub fn new() FloatContext {
        return .{};
    }

    pub fn init(allocator: std.mem.Allocator) FloatContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FloatContext, allocator: std.mem.Allocator) void {
        // `FloatContext` is embedded in the copyable block context, so its
        // first-pass default allocator is the process allocator. Keep the
        // parameter in the public seam for the eventual tree-owned arena.
        _ = allocator;
        self.left_boxes.deinit(self.allocator);
        self.right_boxes.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    pub fn has_floats(self: *const FloatContext) bool {
        return self.has_any_float;
    }

    pub fn has_active_floats(self: *const FloatContext, min_y: f32) bool {
        if (!self.has_any_float) return false;
        for (self.left_boxes.items) |box| if (box.height > 0 and box.y + box.height > min_y) return true;
        for (self.right_boxes.items) |box| if (box.height > 0 and box.y + box.height > min_y) return true;
        return false;
    }

    pub fn set_width(self: *FloatContext, available_width: f32) void {
        self.available_width = available_width;
    }

    pub fn left_floats(self: *const FloatContext) []const PlacedFloatedBox {
        return self.left_boxes.items;
    }

    pub fn right_floats(self: *const FloatContext) []const PlacedFloatedBox {
        return self.right_boxes.items;
    }

    pub fn segment_count(self: *const FloatContext) usize {
        return self.segments.items.len;
    }

    pub fn segment(self: *const FloatContext, index: usize) ?Segment {
        return if (index < self.segments.items.len) self.segments.items[index] else null;
    }

    /// Split a segment at an interior y boundary. This mirrors Taffy's
    /// explicit subdivision helper and keeps the operation available to a
    /// future segment-first placement path.
    pub fn subdivide_segment(self: *FloatContext, index: usize, divide_at_y: f32) void {
        if (index >= self.segments.items.len) return;
        const old = self.segments.items[index];
        if (!(old.y_start < divide_at_y and divide_at_y < old.y_end)) return;
        self.segments.items[index].y_end = divide_at_y;
        self.segments.insert(self.allocator, index + 1, .{
            .y_start = divide_at_y,
            .y_end = old.y_end,
            .insets = old.insets,
            .has_float = old.has_float,
        }) catch @panic("Taffy float segment allocation failed");
    }

    pub fn update_last_placed_float(self: *FloatContext, direction: style.float.FloatDirection, placement: SegmentRange) void {
        const slot = @backingInt(direction);
        self.last_placed_floats[slot].start = @max(self.last_placed_floats[slot].start, placement.start);
        self.last_placed_floats[slot].end = @max(self.last_placed_floats[slot].end, placement.end);
    }

    pub fn cleared_segment(self: *const FloatContext, clear: style.float.Clear) ?usize {
        const left = self.last_placed_floats[0].end;
        const right = self.last_placed_floats[1].end;
        return switch (clear) {
            .left => if (left > 0) left else null,
            .right => if (right > 0) right else null,
            .both => if (left > 0 or right > 0) @max(left, right) else null,
            .none => null,
        };
    }

    fn clear_bottom(self: *const FloatContext, clear: style.float.Clear) ?f32 {
        return switch (clear) {
            .left => self.clear_bottoms[0],
            .right => self.clear_bottoms[1],
            .both => if (self.clear_bottoms[0]) |left| if (self.clear_bottoms[1]) |right| @max(left, right) else left else self.clear_bottoms[1],
            .none => null,
        };
    }

    pub fn cleared_threshold(self: *const FloatContext, clear: style.float.Clear) ?f32 {
        return self.clear_bottom(clear);
    }

    fn side_insets(self: *const FloatContext, y: f32, height: f32, cb_insets: [2]f32) SideInsets {
        var result = SideInsets{};
        for (self.left_boxes.items) |box| {
            if (box.y < y + height and box.y + box.height > y) {
                result.left = @max(result.left, box.x_inset + box.width);
                result.has_left = true;
            }
        }
        for (self.right_boxes.items) |box| {
            if (box.y < y + height and box.y + box.height > y) {
                // `x_inset` is measured from the right edge; the occupied
                // inset is the float's width plus that outer inset.
                result.right = @max(result.right, box.x_inset + box.width);
                result.has_right = true;
            }
        }
        result.left = @max(result.left, cb_insets[0]);
        result.right = @max(result.right, cb_insets[1]);
        return result;
    }

    fn next_obstacle_y(self: *const FloatContext, y: f32, height: f32, insets: SideInsets, direction: style.float.FloatDirection) ?f32 {
        var next: ?f32 = null;
        const lead = @backingInt(direction);
        for (self.left_boxes.items) |box| {
            if (box.y < y + height and box.y + box.height > y) {
                if (lead == 0 or insets.right + box.width > self.available_width) next = if (next) |value| @max(value, box.y + box.height) else box.y + box.height;
            }
        }
        for (self.right_boxes.items) |box| {
            if (box.y < y + height and box.y + box.height > y) {
                if (lead == 1 or insets.left + box.width > self.available_width) next = if (next) |value| @max(value, box.y + box.height) else box.y + box.height;
            }
        }
        return next;
    }

    pub fn place_floated_box(self: *FloatContext, floated_box: geometry.Size(f32), min_y: f32, containing_block_insets: [2]f32, direction: style.float.FloatDirection, clear: style.float.Clear) geometry.Point(f32) {
        self.has_any_float = true;
        self.last_containing_block_insets = containing_block_insets;
        const placed = self.place_floated_box_inner(floated_box, min_y, containing_block_insets, direction, clear);
        const side = @backingInt(direction);
        if (side == 0) self.left_boxes.append(self.allocator, placed) catch @panic("Taffy float allocation failed") else self.right_boxes.append(self.allocator, placed) catch @panic("Taffy float allocation failed");
        self.rebuild_segments();
        const range = self.range_for_float(placed);
        self.update_last_placed_float(direction, range);

        const bottom = placed.y + floated_box.height;
        self.clear_bottoms[side] = if (self.clear_bottoms[side]) |old| @max(old, bottom) else bottom;
        self.float_ceiling = if (self.float_ceiling) |old| @max(old, placed.y) else placed.y;
        return .{ .x = if (side == 0) placed.x_inset else self.available_width - placed.x_inset - floated_box.width, .y = placed.y };
    }

    fn place_floated_box_inner(self: *FloatContext, floated_box: geometry.Size(f32), min_y: f32, containing_block_insets: [2]f32, direction: style.float.FloatDirection, clear: style.float.Clear) PlacedFloatedBox {
        var y = @max(min_y, self.float_ceiling orelse -std.math.inf(f32));
        y = @max(y, self.clear_bottom(clear) orelse -std.math.inf(f32));
        while (true) {
            const insets = self.side_insets(y, floated_box.height, containing_block_insets);
            if (float_fits_horizontally(floated_box.width, direction, self.available_width, insets, containing_block_insets)) break;
            y = self.next_obstacle_y(y, @max(floated_box.height, FIT_TOLERANCE), insets, direction) orelse y + @max(floated_box.height, 1);
        }
        const final_insets = self.side_insets(y, floated_box.height, containing_block_insets);
        const side = @backingInt(direction);
        const lead_inset = if (side == 0) final_insets.left else final_insets.right;
        return .{ .width = floated_box.width, .height = floated_box.height, .x_inset = lead_inset, .y = y };
    }

    fn range_for_float(self: *const FloatContext, floated_box: PlacedFloatedBox) SegmentRange {
        var result = SegmentRange{ .start = self.segments.items.len, .end = self.segments.items.len };
        for (self.segments.items, 0..) |segment_value, index| {
            if (segment_value.y_start < floated_box.y + floated_box.height and segment_value.y_end > floated_box.y) {
                result.start = @min(result.start, index);
                result.end = @max(result.end, index + 1);
            }
        }
        return result;
    }

    fn segment_at(self: *const FloatContext, y: f32) ?usize {
        for (self.segments.items, 0..) |segment_value, index| if (segment_value.contains(y)) return index;
        return null;
    }

    /// Rebuild the observable segment bands from the placed floats. Keeping
    /// this derivation centralized makes zero-height floats remain clearance
    /// constraints without incorrectly creating a positive-height segment.
    fn rebuild_segments(self: *FloatContext) void {
        self.segments.clearRetainingCapacity();
        var boundaries = std.ArrayList(f32).empty;
        defer boundaries.deinit(self.allocator);
        boundaries.append(self.allocator, 0) catch @panic("Taffy float segment allocation failed");
        for (self.left_boxes.items) |box| {
            if (box.height > 0) {
                boundaries.append(self.allocator, box.y) catch @panic("Taffy float segment allocation failed");
                boundaries.append(self.allocator, box.y + box.height) catch @panic("Taffy float segment allocation failed");
            }
        }
        for (self.right_boxes.items) |box| {
            if (box.height > 0) {
                boundaries.append(self.allocator, box.y) catch @panic("Taffy float segment allocation failed");
                boundaries.append(self.allocator, box.y + box.height) catch @panic("Taffy float segment allocation failed");
            }
        }
        std.sort.heap(f32, boundaries.items, {}, struct {
            fn lessThan(_: void, lhs: f32, rhs: f32) bool {
                return lhs < rhs;
            }
        }.lessThan);
        var unique: usize = 0;
        for (boundaries.items) |value| {
            if (unique == 0 or boundaries.items[unique - 1] != value) {
                boundaries.items[unique] = value;
                unique += 1;
            }
        }
        boundaries.items.len = unique;
        if (boundaries.items.len < 2) return;
        for (boundaries.items[0 .. boundaries.items.len - 1], 0..) |_, index| {
            const start = boundaries.items[index];
            const end = boundaries.items[index + 1];
            if (end <= start) continue;
            var current = Segment{ .y_start = start, .y_end = end };
            for (self.left_boxes.items) |box| if (box.y < end and box.y + box.height > start) {
                current.insets[0] = @max(current.insets[0], box.x_inset + box.width);
                current.has_float[0] = true;
            };
            for (self.right_boxes.items) |box| if (box.y < end and box.y + box.height > start) {
                current.insets[1] = @max(current.insets[1], box.x_inset + box.width);
                current.has_float[1] = true;
            };
            self.segments.append(self.allocator, current) catch @panic("Taffy float segment allocation failed");
        }
    }

    fn insets_for_left(self: *const FloatContext, y: f32, height: f32, cb_insets: [2]f32) f32 {
        return self.side_insets(y, height, cb_insets).left;
    }

    fn insets_for_right(self: *const FloatContext, y: f32, height: f32, cb_insets: [2]f32) f32 {
        return self.side_insets(y, height, cb_insets).right;
    }

    pub fn find_content_slot(self: *const FloatContext, min_y: f32, containing_block_insets: [2]f32, clear: style.float.Clear, after: ?usize) ContentSlot {
        _ = after;
        var y = @max(min_y, self.clear_bottom(clear) orelse -std.math.inf(f32));
        while (true) {
            const insets = self.side_insets(y, 0.0001, containing_block_insets);
            const width = self.available_width - insets.left - insets.right;
            if (width >= -FIT_TOLERANCE or !self.has_active_floats(y)) return .{ .segment_id = self.segment_at(y), .x = insets.left, .y = y, .width = @max(0, width) };
            y = self.next_obstacle_y(y, 0.0001, insets, .left) orelse y + 1;
        }
    }

    pub fn find_bfc_slot(self: *const FloatContext, min_y: f32, containing_block_insets: [2]f32, margins: [2]f32, direction: style.Direction, clear: style.float.Clear, after: ?usize) BfcSlot {
        _ = after;
        const margin_insets = .{ containing_block_insets[0] + margins[0], containing_block_insets[1] + margins[1] };
        var y = @max(min_y, self.clear_bottom(clear) orelse -std.math.inf(f32));
        while (true) {
            const insets = self.side_insets(y, 0.0001, containing_block_insets);
            const lead: usize = if (direction == .ltr) 0 else 1;
            const trail = 1 - lead;
            const fit_lead = @max(if (lead == 0) insets.left else insets.right, margin_insets[lead]);
            const fit_trail = @max(if (trail == 0) insets.left else insets.right, containing_block_insets[trail]);
            const width = self.available_width - fit_lead - fit_trail;
            if (width >= -FIT_TOLERANCE or !self.has_active_floats(y)) {
                const stretch_trail = @max(if (trail == 0) insets.left else insets.right, margin_insets[trail]);
                const stretch = self.available_width - fit_lead - stretch_trail;
                return .{ .segment_id = self.segment_at(y), .x = if (lead == 0) fit_lead else self.available_width - fit_lead - width, .y = y, .border_width = @max(0, width), .stretch_width = @max(0, stretch) };
            }
            y = self.next_obstacle_y(y, 0.0001, insets, if (lead == 0) .left else .right) orelse y + 1;
        }
    }
};

pub const FloatIntrinsicWidthCalculator = struct {
    available_width: available.AvailableSpace,
    side_sums: [2]f32 = .{ 0, 0 },
    contribution: f32 = 0,
    widest: f32 = 0,

    pub fn new(available_width: available.AvailableSpace) FloatIntrinsicWidthCalculator {
        return .{ .available_width = available_width };
    }

    pub fn add_float(self: *FloatIntrinsicWidthCalculator, width: f32, direction: style.float.FloatDirection, clear: style.float.Clear) void {
        switch (self.available_width) {
            .definite, .max_content => {
                if (clear == .left or clear == .both) self.side_sums[0] = 0;
                if (clear == .right or clear == .both) self.side_sums[1] = 0;
                self.side_sums[@backingInt(direction)] += width;
                self.contribution = @max(self.contribution, self.side_sums[0] + self.side_sums[1]);
            },
            .min_content => self.contribution = @max(self.contribution, width),
        }
        self.widest = @max(self.widest, width);
    }

    pub fn result(self: *const FloatIntrinsicWidthCalculator) f32 {
        return switch (self.available_width) {
            .definite => |width| @max(self.widest, @min(width, self.contribution)),
            .min_content, .max_content => self.contribution,
        };
    }
};

test "float placement preserves clearance and side edges" {
    const testing = std.testing;
    var context = FloatContext.new();
    defer context.deinit(testing.allocator);
    context.set_width(100);
    const left = context.place_floated_box(.{ .width = 40, .height = 20 }, 0, .{ 0, 0 }, .left, .none);
    try testing.expectEqual(@as(f32, 0), left.x);
    const right = context.place_floated_box(.{ .width = 40, .height = 20 }, 0, .{ 0, 0 }, .right, .none);
    try testing.expectEqual(@as(f32, 60), right.x);
    const slot = context.find_content_slot(0, .{ 0, 0 }, .none, null);
    try testing.expectEqual(@as(f32, 20), slot.width);
    try testing.expect(context.cleared_threshold(.both) != null);
    try testing.expectEqual(@as(usize, 1), context.segment_count());
    try testing.expect(context.segment(0).?.fits_float_width(.{ .width = 30, .height = 10 }, .left, 100, .{ 0, 0 }) == false);
    try testing.expect(context.cleared_segment(.both) != null);
    var zero = FloatContext.init(testing.allocator);
    defer zero.deinit(testing.allocator);
    zero.set_width(100);
    _ = zero.place_floated_box(.{ .width = 20, .height = 0 }, 5, .{ 0, 0 }, .left, .none);
    try testing.expect(!zero.has_active_floats(5));
    try testing.expectEqual(@as(?f32, 5), zero.cleared_threshold(.left));
}
