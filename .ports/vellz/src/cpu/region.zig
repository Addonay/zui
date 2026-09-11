//! Port of vello_cpu src/region.rs (Apache-2.0 OR MIT).
//!
//! Splitting a single mutable buffer into regions that can be accessed
//! concurrently: a `Region` is a view into one 4-pixel strip row of a pixmap.
//!
//! Ownership/lifetime note: a `Region` holds borrowed mutable slices into the
//! byte buffer of the `PixmapMut` it was created from. The port cannot express
//! the Rust lifetime, so the invariant is documented here: the backing pixmap
//! (or buffer) must outlive every `Region` derived from it, and regions
//! obtained from [`Regions`] are disjoint by construction. `subSpan` returns a
//! region borrowing from its parent, so the parent must be kept alive while the
//! sub-span is used.
//!
//! `Region` exposes the upstream `width`/`height` fields directly instead of
//! the `width()`/`height()` methods, because a Zig field and method cannot
//! share a name.

const std = @import("std");
const geometry = @import("../common/geometry.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const util = @import("util.zig");

const RectU16 = geometry.RectU16;
const PixmapMut = pixmap_mod.PixmapMut;

/// Number of color components per pixel (RGBA).
///
/// Mirrors `fine.COLOR_COMPONENTS`; kept local so `region.zig` does not create
/// an import cycle with `fine/mod.zig`.
const COLOR_COMPONENTS: usize = 4;

/// The tile height in pixels.
const TILE_HEIGHT: u16 = util.TILE_HEIGHT;

/// A view into a part of a single strip row of a pixmap.
pub const Region = struct {
    /// The index of the strip row this region covers (row-height bands).
    row_idx: usize = 0,
    /// The width of the region in pixels.
    width: u16 = 0,
    /// The height of the region in pixels (at most [`TILE_HEIGHT`]).
    height: u16 = 0,
    /// The borrowed pixel data for each row. Only the first `height` entries
    /// are valid; each entry is `width * 4` bytes long.
    areas: [@as(usize, TILE_HEIGHT)][]u8 = emptyAreas(),

    /// Create a region covering the top 4-pixel row band of `rect` in `pixmap`.
    ///
    /// `rect` must lie within the pixmap, exactly like upstream.
    pub fn init(pixmap: *PixmapMut, rect: RectU16) Region {
        return initFromRow(pixmap, rect, 0);
    }

    /// Create a region covering row band `row_idx` of `rect` in `pixmap`.
    pub fn initFromRow(pixmap: *PixmapMut, rect: RectU16, row_idx: usize) Region {
        const width = rect.width();
        const height = @min(rect.height(), TILE_HEIGHT);
        const row_stride = @as(usize, pixmap.width) * COLOR_COMPONENTS;
        const start_offset = @as(usize, rect.y0) * row_stride;
        const x_offset = @as(usize, rect.x0) * COLOR_COMPONENTS;
        const buffer = pixmap.dataMut();
        return fromRows(
            row_idx,
            width,
            height,
            row_stride,
            x_offset,
            buffer[start_offset..],
        );
    }

    /// Return the mutable slice for row `y` of this region.
    pub fn rowMut(self: *Region, y: u16) []u8 {
        return self.areas[y];
    }

    /// Return the width of the region in pixels.
    pub fn widthPixels(self: Region) u16 {
        return self.width;
    }

    /// Return the height of the region in pixels.
    pub fn heightPixels(self: Region) u16 {
        return self.height;
    }

    /// Return a horizontal sub-span of the region.
    ///
    /// The returned region borrows from `self`; `self` must outlive it.
    pub fn subSpan(self: *Region, x: u16, width: u16) Region {
        const x_offset = @as(usize, x) * COLOR_COMPONENTS;
        const row_width_bytes = @as(usize, width) * COLOR_COMPONENTS;
        var areas = emptyAreas();

        for (self.areas[0..self.height], 0..) |source, i| {
            // Panics on out-of-range exactly like upstream's `split_at_mut`.
            const row = source[x_offset..];
            areas[i] = row[0..row_width_bytes];
        }

        return .{
            .row_idx = self.row_idx,
            .width = width,
            .height = self.height,
            .areas = areas,
        };
    }

    /// Borrow the full array of row slices.
    pub fn areasMut(self: *Region) *[@as(usize, TILE_HEIGHT)][]u8 {
        return &self.areas;
    }

    fn fromRows(
        row_idx: usize,
        width: u16,
        height: u16,
        row_stride: usize,
        x_offset: usize,
        rows: []u8,
    ) Region {
        const row_width_bytes = @as(usize, width) * COLOR_COMPONENTS;
        var areas = emptyAreas();
        var remaining = rows;

        for (areas[0..height]) |*area| {
            // Panics when `rows` is too short, like upstream's `split_at_mut`.
            const row = remaining[0..row_stride];
            const row_x = row[x_offset..];
            area.* = row_x[0..row_width_bytes];
            remaining = remaining[row_stride..];
        }

        return .{
            .row_idx = row_idx,
            .width = width,
            .height = height,
            .areas = areas,
        };
    }

    fn emptyAreas() [@as(usize, TILE_HEIGHT)][]u8 {
        return .{
            @as([]u8, &.{}),
            @as([]u8, &.{}),
            @as([]u8, &.{}),
            @as([]u8, &.{}),
        };
    }
};

/// Split a pixmap into an array of regions.
///
/// Lifetime: the regions borrow `target`'s byte buffer; `target` must outlive
/// the `Regions` value.
pub const Regions = struct {
    /// The disjoint regions, top to bottom.
    regions: std.ArrayList(Region),

    /// Create up to `row_count` regions covering `scene_size` at `offset`
    /// within `target`.
    pub fn init(
        allocator: std.mem.Allocator,
        target: *PixmapMut,
        scene_size: [2]u16,
        offset: [2]u16,
        row_count: usize,
    ) std.mem.Allocator.Error!Regions {
        const dst_x = offset[0];
        const dst_y = offset[1];
        const scene_width = scene_size[0];
        const scene_height = scene_size[1];

        const width = @min(scene_width, target.width -| dst_x);
        const height = @min(scene_height, target.height -| dst_y);

        var regions = std.ArrayList(Region).empty;
        errdefer regions.deinit(allocator);

        if (width == 0 or height == 0) {
            return .{ .regions = regions };
        }

        const clamped_row_count = @min(
            row_count,
            (@as(usize, height) + TILE_HEIGHT - 1) / TILE_HEIGHT,
        );
        const stride = @as(usize, target.width) * COLOR_COMPONENTS;
        const x_offset = @as(usize, dst_x) * COLOR_COMPONENTS;
        const render_bytes = @as(usize, height) * stride;
        const target_bytes = target.dataMut();
        var remaining = target_bytes[@as(usize, dst_y) * stride ..][0..render_bytes];
        try regions.ensureTotalCapacity(allocator, clamped_row_count);

        for (0..clamped_row_count) |row_idx| {
            const row_y: u16 = @intCast(row_idx * TILE_HEIGHT);
            const row_height = @min(height - row_y, TILE_HEIGHT);
            const band_len = @as(usize, row_height) * stride;
            const band = remaining[0..band_len];
            remaining = remaining[band_len..];
            try regions.append(allocator, Region.fromRows(
                row_idx,
                width,
                row_height,
                stride,
                x_offset,
                band,
            ));
        }

        return .{ .regions = regions };
    }

    /// Release the region list (not the borrowed pixel data).
    pub fn deinit(self: *Regions, allocator: std.mem.Allocator) void {
        self.regions.deinit(allocator);
        self.* = undefined;
    }

    /// Apply `ctx.call(region)` to every region.
    pub fn update(self: *Regions, ctx: anytype) void {
        for (self.regions.items) |*region| {
            ctx.call(region);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Pixmap = pixmap_mod.Pixmap;

test "regions_with_off_target_offsets_do_not_panic" {
    const offsets = [_][2]u16{ .{ 20, 0 }, .{ 0, 20 } };
    for (offsets) |offset| {
        var pixmap = try Pixmap.init(testing.allocator, 10, 10);
        defer pixmap.deinit(testing.allocator);
        var pixmap_mut = pixmap.asMut();
        var regions = try Regions.init(testing.allocator, &pixmap_mut, .{ 4, 4 }, offset, 1);
        defer regions.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), regions.regions.items.len);
    }
}

test "regions_cover_rows_and_sub_spans" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 8, 6);
    defer pixmap.deinit(allocator);

    {
        var pixmap_mut = pixmap.asMut();
        var regions = try Regions.init(allocator, &pixmap_mut, .{ 8, 6 }, .{ 0, 0 }, 2);
        defer regions.deinit(allocator);

        try testing.expectEqual(@as(usize, 2), regions.regions.items.len);
        try testing.expectEqual(@as(u16, 8), regions.regions.items[0].width);
        try testing.expectEqual(@as(u16, 4), regions.regions.items[0].height);
        try testing.expectEqual(@as(u16, 2), regions.regions.items[1].height);
        try testing.expectEqual(@as(usize, 32), regions.regions.items[0].rowMut(0).len);
        try testing.expectEqual(@as(usize, 32), regions.regions.items[1].rowMut(1).len);

        // The regions are disjoint views over the same backing buffer, laid
        // out row band after row band.
        regions.regions.items[0].rowMut(0)[0] = 11;
        regions.regions.items[0].rowMut(3)[7 * 4] = 22;
        regions.regions.items[1].rowMut(1)[0] = 33;
    }

    try testing.expectEqual(@as(u8, 11), pixmap.sample(0, 0).r);
    try testing.expectEqual(@as(u8, 22), pixmap.sample(7, 3).r);
    try testing.expectEqual(@as(u8, 33), pixmap.sample(0, 5).r);
}

test "region_sub_span_offsets_each_row" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 8, 4);
    defer pixmap.deinit(allocator);
    var pixmap_mut = pixmap.asMut();

    {
        var region = Region.init(&pixmap_mut, RectU16.new(0, 0, 8, 4));
        var sub = region.subSpan(2, 3);
        try testing.expectEqual(@as(u16, 3), sub.width);
        try testing.expectEqual(@as(u16, 4), sub.height);
        try testing.expectEqual(@as(usize, 12), sub.rowMut(0).len);

        sub.rowMut(0)[0] = 9; // pixel (2, 0)
        sub.rowMut(3)[8] = 8; // pixel (4, 3), red component
    }
    try testing.expectEqual(@as(u8, 9), pixmap.sample(2, 0).r);
    try testing.expectEqual(@as(u8, 8), pixmap.sample(4, 3).r);
}

test "regions_update_visits_all_regions" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    var pixmap_mut = pixmap.asMut();

    var regions = try Regions.init(allocator, &pixmap_mut, .{ 4, 4 }, .{ 0, 0 }, 4);
    defer regions.deinit(allocator);

    const Counter = struct {
        count: *usize,
        fn call(self: @This(), region: *Region) void {
            _ = region;
            self.count.* += 1;
        }
    };
    var count: usize = 0;
    regions.update(Counter{ .count = &count });
    try testing.expectEqual(@as(usize, 1), count);
}
