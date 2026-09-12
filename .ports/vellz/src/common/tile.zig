//! Port of vello_common tile.rs (Apache-2.0 OR MIT).
//!
//! 4x4 tile binning for the CPU sparse-strip renderer: `Tile` (with the hard
//! 27-bit line-index / 5-bit intersection-winding packing contract),
//! `CulledWindings`, and `Tiles` with the analytic-AA and MSAA tiling paths.
//!
//! Endianness: upstream swaps `Tile`'s field order per target so that the
//! in-memory `u64` equals `to_bits()`. Zig 0.17 has no `@Type`/`usingnamespace`
//! to reorder fields at comptime, so this port keeps the little-endian field
//! order (`packed`, `x`, `y`) on every target and computes `toBits()`
//! explicitly. `toBits()`, `Tile.eql`, and ordering are the observable
//! contract and are endianness-independent; only a raw `@bitCast` of the
//! struct would differ on big-endian targets.
//!
//! Allocator contract: `Tiles`, `CulledWindings`, and every `makeTiles*` call
//! take an explicit allocator; `init`/`new` do not allocate, storage grows
//! lazily in the `makeTiles*`/`reset` calls, and `deinit` releases it.
//!
//! The analytic-AA and MSAA implementations transcribe the upstream f32x4
//! code with identical operation order; per-lane arithmetic is element-wise,
//! so results are bit-identical to the upstream scalar fallback. The
//! fractional-coverage computation and the partial-winding accumulation run
//! through `@Vector` when `Tiles.level` selects a vector backend and through
//! the scalar fallback otherwise; both are bit-identical (tested).

const std = @import("std");
const simd = @import("../simd/root.zig");
const flatten = @import("flatten.zig");
const Line = flatten.Line;

const F32x4 = simd.F32x4;

/// T-op bit.
pub const T: u32 = 0b00001;
/// B-ottom bit.
pub const B: u32 = 0b00010;
/// L-eft bit.
pub const L: u32 = 0b00100;
/// R-ight bit.
pub const R: u32 = 0b01000;
/// W-inding bit.
pub const W: u32 = 0b10000;

/// Shift amount corresponding to the bottom bit.
const BOT_SHIFT: u5 = 1;
/// Shift amount corresponding to the left bit.
const LEFT_SHIFT: u5 = 2;
/// Shift amount corresponding to the right bit.
const RIGHT_SHIFT: u5 = 3;
/// Shift amount corresponding to the winding bit.
const WINDING_SHIFT: u5 = 4;

/// Mask for all intersection and winding bits (bits 0-4).
const INTERSECTION_MASK: u32 = W | R | L | B | T;

/// Shift amount corresponding to the intersection bits.
const INT_MASK_SHIFT: u5 = 5;

/// The max number of lines per path.
///
/// Trying to render a path with more lines than this may result in visual
/// artifacts.
pub const MAX_LINES_PER_PATH: u32 = 1 << (32 - @as(u32, INT_MASK_SHIFT));

/// A logical grouping of arrays used for culled tile processing.
pub const CulledWindings = struct {
    /// Number of bits in a single active mask word.
    pub const WORD_BITS: usize = 32;
    /// Bit shift equivalent to dividing by `WORD_BITS` (2^5 = 32).
    pub const WORD_SHIFT: u5 = 5;
    /// Bitmask equivalent to modulo `WORD_BITS` (32 - 1 = 31).
    pub const WORD_MASK: usize = 31;

    /// Fractional winding coverage for each individual scanline in a row.
    partial: std.ArrayList([Tile.HEIGHT]f32) = .empty,
    /// Accumulated integer winding deltas for each tile row.
    ///
    /// Note that this will cause issues if we have windings greater/less than
    /// i16, but this should only occur in pathological cases.
    coarse: std.ArrayList(i16) = .empty,
    /// Bitmask tracking which rows contain active geometry or winding data.
    active: std.ArrayList(u32) = .empty,
    /// Flag indicating if any geometry was early-culled outside the viewport.
    culled: bool = false,
    /// The viewport height the buffers are sized for.
    height: u16 = 0,

    /// Constructor chained to `Tiles`' constructor and matching its initial
    /// viewport height. Allocates zeroed buffers; release with `deinit`.
    pub fn init(allocator: std.mem.Allocator, height: u16) !CulledWindings {
        var self = CulledWindings{ .height = height };
        errdefer self.deinit(allocator);

        const num_rows = rowCount(height);
        const num_bits = (num_rows + WORD_BITS - 1) / WORD_BITS;
        try resizeZeroed([Tile.HEIGHT]f32, allocator, &self.partial, num_rows, .{ 0.0, 0.0, 0.0, 0.0 });
        try resizeZeroed(i16, allocator, &self.coarse, num_rows, 0);
        try resizeZeroed(u32, allocator, &self.active, num_bits, 0);
        return self;
    }

    /// Release all buffers.
    pub fn deinit(self: *CulledWindings, allocator: std.mem.Allocator) void {
        self.partial.deinit(allocator);
        self.coarse.deinit(allocator);
        self.active.deinit(allocator);
        self.* = .{};
    }

    fn rowCount(height: u16) usize {
        return std.math.divCeil(usize, height, Tile.HEIGHT) catch unreachable;
    }

    /// Reset the winding buffers, resizing for `height` if it changed.
    pub fn reset(self: *CulledWindings, allocator: std.mem.Allocator, height: u16) !void {
        if (self.height != height) {
            const num_rows = rowCount(height);
            const num_bits = (num_rows + WORD_BITS - 1) / WORD_BITS;
            try resizeZeroed([Tile.HEIGHT]f32, allocator, &self.partial, num_rows, .{ 0.0, 0.0, 0.0, 0.0 });
            try resizeZeroed(i16, allocator, &self.coarse, num_rows, 0);
            try resizeZeroed(u32, allocator, &self.active, num_bits, 0);
            self.height = height;
        }

        // TODO upstream: maybe consider tracking touched regions and only
        // resetting those instead of always the full array?
        if (self.culled) {
            @memset(self.partial.items, .{ 0.0, 0.0, 0.0, 0.0 });
            @memset(self.coarse.items, 0);
            @memset(self.active.items, 0);
            self.culled = false;
        }
    }

    /// Marks if a row was culled early for faster traversal in strip
    /// generation.
    pub inline fn markRowActive(self: *CulledWindings, row_idx: usize) void {
        self.active.items[row_idx >> WORD_SHIFT] |= @as(u32, 1) << @as(u5, @intCast(row_idx & WORD_MASK));
    }

    /// Bulk marks a range of rows as active [`start_row`, `end_row`).
    pub inline fn markRowRangeActive(self: *CulledWindings, start_row: usize, end_row: usize) void {
        if (start_row >= end_row) return;

        const start_word = start_row >> WORD_SHIFT;
        const end_word = (end_row - 1) >> WORD_SHIFT;

        if (start_word == end_word) {
            // All bits fall within the same u32 word.
            const shift: u5 = @intCast(start_row & WORD_MASK);
            const count = end_row - start_row;
            const mask: u32 = if (count == WORD_BITS)
                std.math.maxInt(u32)
            else
                ((@as(u32, 1) << @as(u5, @intCast(count))) - 1) << shift;
            self.active.items[start_word] |= mask;
        } else {
            // Bits span multiple words: handle start, full middle words, end.
            self.active.items[start_word] |= @as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(start_row & WORD_MASK));

            const middle = self.active.items[(start_word + 1)..end_word];
            @memset(middle, std.math.maxInt(u32));

            const end_shift = ((end_row - 1) & WORD_MASK) + 1;
            const mask: u32 = if (end_shift == WORD_BITS)
                std.math.maxInt(u32)
            else
                (@as(u32, 1) << @as(u5, @intCast(end_shift))) - 1;
            self.active.items[end_word] |= mask;
        }
    }

    /// Calls `callback(ctx, row)` on active rows in the range [`start`, `end`).
    pub fn forActiveRowsInRange(
        self: *const CulledWindings,
        start: usize,
        end: usize,
        ctx: anytype,
        comptime callback: anytype,
    ) void {
        if (start >= end) return;

        const start_word = start >> WORD_SHIFT;
        const end_word = (end - 1) >> WORD_SHIFT;

        const end_limit = ((end - 1) & WORD_MASK) + 1;
        const end_mask: u32 = if (end_limit == WORD_BITS)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << @as(u5, @intCast(end_limit))) - 1;

        {
            var word = self.active.items[start_word];
            const start_bit: u5 = @intCast(start & WORD_MASK);
            word &= ~((@as(u32, 1) << start_bit) - 1);
            if (start_word == end_word) word &= end_mask;
            processWord(word, start_word, ctx, callback);
        }

        if (start_word < end_word) {
            var word_idx = start_word + 1;
            while (word_idx < end_word) : (word_idx += 1) {
                processWord(self.active.items[word_idx], word_idx, ctx, callback);
            }
            processWord(self.active.items[end_word] & end_mask, end_word, ctx, callback);
        }
    }
};

fn processWord(word_in: u32, word_idx: usize, ctx: anytype, comptime callback: anytype) void {
    var word = word_in;
    while (word != 0) {
        const bit: u5 = @intCast(@ctz(word));
        word &= ~(@as(u32, 1) << bit);
        callback(ctx, (word_idx << CulledWindings.WORD_SHIFT) + @as(usize, bit));
    }
}

/// Grow `list` to `new_len`, zero-filling the new tail, or shrink it.
fn resizeZeroed(
    comptime Elem: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Elem),
    new_len: usize,
    zero: Elem,
) !void {
    const old_len = list.items.len;
    if (new_len <= old_len) {
        list.shrinkRetainingCapacity(new_len);
        return;
    }
    try list.resize(allocator, new_len);
    @memset(list.items[old_len..], zero);
}

/// A tile represents an aligned area on the pixmap, used to subdivide the
/// viewport into sub-areas (currently 4x4) and analyze line intersections
/// inside each such area.
///
/// Keep in mind that it is possible to have multiple tiles with the same
/// index, namely if we have multiple lines crossing the same 4x4 area!
pub const Tile = struct {
    /// The width of a tile in pixels.
    pub const WIDTH: u16 = 4;

    /// The height of a tile in pixels.
    pub const HEIGHT: u16 = 4;

    /// A special tile used to signal the end of a tile stream during
    /// rendering.
    pub const SENTINEL: Tile = .{
        .packed_winding_line_idx = 0,
        .x = std.math.maxInt(u16),
        .y = std.math.maxInt(u16),
    };

    /// The index of the line this tile belongs to into the line buffer,
    /// intersection data, and winding data packed together.
    ///
    /// The layout is:
    /// - **Bits 0-4 (5 bits):** Intersection and Winding Mask (`W | R | L | B | T`).
    ///   - Bit 0 (mask `0b00001`): Intersects top edge (T)
    ///   - Bit 1 (mask `0b00010`): Intersects bottom edge (B)
    ///   - Bit 2 (mask `0b00100`): Intersects left edge (L)
    ///   - Bit 3 (mask `0b01000`): Intersects right edge (R)
    ///   - Bit 4 (mask `0b10000`): Winding (W) - 1 if crosses top edge.
    /// - **Bits 5-31 (27 bits):** The line index (`line_idx`).
    ///
    /// **Sorting note:** `line_idx` occupies the higher bits so that tiles
    /// with the same `(x, y)` are sorted by line index first and then by
    /// intersection mask.
    packed_winding_line_idx: u32,

    // The field order below matches upstream's little-endian order; see the
    // module docs for the big-endian note.
    /// The index of the tile in the x direction.
    x: u16,
    /// The index of the tile in the y direction.
    y: u16,

    /// Create a new tile.
    /// `x` and `y` will be clamped to the largest possible coordinate if they
    /// are too large.
    ///
    /// `line_idx` must be smaller than [`MAX_LINES_PER_PATH`].
    pub inline fn newClamped(x: u16, y: u16, line_idx: u32, intersection_mask: u32) Tile {
        return Tile.new(
            // Make sure that x and y stay in range when multiplying with the
            // tile width and height during strip generation.
            @min(x, std.math.maxInt(u16) / WIDTH),
            @min(y, std.math.maxInt(u16) / HEIGHT),
            line_idx,
            intersection_mask,
        );
    }

    /// The base tile constructor.
    ///
    /// Unlike [`newClamped`], this constructor stores `x` and `y` exactly as
    /// provided. Callers must ensure these coordinates do not exceed the
    /// limits required by downstream processing (typically
    /// `u16::MAX / WIDTH` and `u16::MAX / HEIGHT`).
    pub inline fn new(x: u16, y: u16, line_idx: u32, intersection_mask: u32) Tile {
        // Upstream `#[cfg(debug_assertions)] panic!`.
        if (std.debug.runtime_safety) {
            std.debug.assert(line_idx < MAX_LINES_PER_PATH);
        }
        // The intersection mask is expected to contain bits 0-4 (T, B, L, R,
        // W). We pack line_idx into the high bits (5-31) and intersection_mask
        // into the low bits (0-4).
        return .{
            .packed_winding_line_idx = (line_idx << INT_MASK_SHIFT) | intersection_mask,
            .x = x,
            .y = y,
        };
    }

    /// Check whether two tiles are at the same location.
    pub inline fn sameLoc(self: Tile, other: Tile) bool {
        return self.sameRow(other) and self.x == other.x;
    }

    /// Check whether `self` is adjacent to the left of `other`.
    pub inline fn prevLoc(self: Tile, other: Tile) bool {
        return self.sameRow(other) and self.x + 1 == other.x;
    }

    /// Check whether two tiles are on the same row.
    pub inline fn sameRow(self: Tile, other: Tile) bool {
        return self.y == other.y;
    }

    /// The index of the line this tile belongs to into the line buffer.
    ///
    /// Returns the high 27 bits.
    pub inline fn lineIdx(self: Tile) u32 {
        return self.packed_winding_line_idx >> INT_MASK_SHIFT;
    }

    /// Whether the line crosses the top edge of the tile.
    ///
    /// Lines making this crossing increment or decrement the coarse tile
    /// winding, depending on the line direction. Checks bit 4 (winding).
    pub inline fn winding(self: Tile) bool {
        return (self.packed_winding_line_idx & W) != 0;
    }

    /// The 5 bits of intersection and winding data.
    pub inline fn intersectionMask(self: Tile) u32 {
        return self.packed_winding_line_idx & INTERSECTION_MASK;
    }

    /// Whether the line intersects the top edge of the tile.
    pub inline fn intersectsTop(self: Tile) bool {
        return (self.intersectionMask() & T) != 0;
    }

    /// Whether the line intersects the bottom edge of the tile.
    pub inline fn intersectsBottom(self: Tile) bool {
        return (self.intersectionMask() & B) != 0;
    }

    /// Whether the line intersects the left edge of the tile.
    pub inline fn intersectsLeft(self: Tile) bool {
        return (self.intersectionMask() & L) != 0;
    }

    /// Whether the line intersects the right edge of the tile.
    pub inline fn intersectsRight(self: Tile) bool {
        return (self.intersectionMask() & R) != 0;
    }

    /// Return the `u64` representation of this tile.
    ///
    /// This is the `u64` interpretation of `(y, x, packed_winding_line_idx)`
    /// where `y` is the most-significant part and `packed_winding_line_idx`
    /// the least significant. Upstream keeps this private; it is public here
    /// so the ordering/equality contract can be tested directly.
    pub inline fn toBits(self: Tile) u64 {
        // Note that for correct rendering, tiles only need to be sorted on
        // `(y, x)`. Sorting on the line index in addition to the coordinate
        // improves data locality in strip rendering.
        return (@as(u64, self.y) << 48) | (@as(u64, self.x) << 32) | @as(u64, self.packed_winding_line_idx);
    }

    /// Whether `self` sorts before `other`.
    pub inline fn lessThan(self: Tile, other: Tile) bool {
        return self.toBits() < other.toBits();
    }

    /// Upstream `PartialEq for Tile`: equality is defined on `toBits()`.
    pub inline fn eql(self: Tile, other: Tile) bool {
        return self.toBits() == other.toBits();
    }

    /// Whether a tile is a sentinel tile.
    ///
    /// A tile produced organically by a `makeTiles` call can never have this
    /// coordinate because of the division by tile size on creation, so
    /// checking on x is sufficient to identify it.
    pub inline fn isSentinel(self: Tile) bool {
        return self.x == std.math.maxInt(u16);
    }
};

/// Handles the tiling of paths.
pub const Tiles = struct {
    /// The emitted tiles; unsorted until `sortTiles` is called.
    tile_buf: std.ArrayList(Tile) = .empty,
    /// The SIMD level selecting the analytic-AA vector/scalar backends.
    level: simd.Level,
    /// Whether `tile_buf` has been sorted.
    sorted: bool = false,
    /// The viewport width used for this tile buffer.
    width: u16 = 0,
    /// The viewport height used for this tile buffer.
    height: u16 = 0,
    /// Auxiliary data tracking row windings and active rows for early
    /// culling.
    windings: CulledWindings = .{},

    /// Create a new tiles container. Does not allocate; the buffers grow in
    /// `makeTiles*`/`reset`.
    pub fn init(allocator: std.mem.Allocator, level: simd.Level, width: u16, height: u16) Tiles {
        // Kept for interface symmetry with upstream; storage is allocated
        // lazily by the first `reset`.
        _ = allocator;
        return .{ .level = level, .width = width, .height = height };
    }

    /// Release the tile buffer and winding buffers.
    pub fn deinit(self: *Tiles, allocator: std.mem.Allocator) void {
        self.tile_buf.deinit(allocator);
        self.windings.deinit(allocator);
        self.* = .{ .level = self.level };
    }

    /// Get the number of tiles in the container.
    pub fn len(self: *const Tiles) u32 {
        return @intCast(self.tile_buf.items.len);
    }

    /// Returns `true` if the container has no tiles.
    pub fn isEmpty(self: *const Tiles) bool {
        return self.tile_buf.items.len == 0;
    }

    /// Returns `true` if any geometry was early-culled outside the viewport.
    pub fn hasCulledTiles(self: *const Tiles) bool {
        return self.windings.culled;
    }

    /// Reset the tiles' container and resize to the given dimensions.
    pub fn reset(self: *Tiles, allocator: std.mem.Allocator, width: u16, height: u16) !void {
        try self.windings.reset(allocator, height);
        self.width = width;
        self.height = height;
        self.tile_buf.clearRetainingCapacity();
        self.sorted = false;
    }

    /// Sort the tiles in the container.
    pub fn sortTiles(self: *Tiles) void {
        self.sorted = true;
        std.mem.sortUnstable(Tile, self.tile_buf.items, {}, tileLessThan);
    }

    /// Get the tile at a certain index.
    ///
    /// Asserts that the container has been sorted first (upstream panics).
    pub inline fn get(self: *const Tiles, index: usize) Tile {
        std.debug.assert(self.sorted);
        return self.tile_buf.items[index];
    }

    /// Iterate over the tiles in sorted order.
    ///
    /// Asserts that the container has been sorted first (upstream panics).
    pub inline fn items(self: *const Tiles) []const Tile {
        std.debug.assert(self.sorted);
        return self.tile_buf.items;
    }

    /// Generates tile commands for Analytic Anti-Aliasing rasterization.
    /// Unlike the MSAA path, this function performs "coarse binning" to simply
    /// identify every tile a line segment traverses. It encodes the line index
    /// and winding direction, delegating the precise calculation of pixel
    /// coverage to `strip::render`.
    ///
    /// Returns `windings.culled`: whether geometry left of the viewport was
    /// culled.
    pub fn makeTilesAnalyticAa(
        self: *Tiles,
        allocator: std.mem.Allocator,
        lines: []const Line,
        width: u16,
        height: u16,
    ) !bool {
        try self.reset(allocator, width, height);

        if (width == 0 or height == 0) return self.windings.culled;

        std.debug.assert(lines.len <= @as(usize, MAX_LINES_PER_PATH));

        const tile_columns = std.math.divCeil(u16, width, Tile.WIDTH) catch unreachable;
        const tile_rows = std.math.divCeil(u16, height, Tile.HEIGHT) catch unreachable;

        const tile_width_f32: f32 = @floatFromInt(Tile.WIDTH);
        const tile_height_f32: f32 = @floatFromInt(Tile.HEIGHT);
        const tile_columns_f32: f32 = @floatFromInt(tile_columns);

        const max_lines: usize = @min(lines.len, @as(usize, MAX_LINES_PER_PATH));
        for (lines[0..max_lines], 0..) |line, line_index| {
            const line_idx: u32 = @intCast(line_index);

            const p0_x = line.p0.x / tile_width_f32;
            const p0_y = line.p0.y / tile_height_f32;
            const p1_x = line.p1.x / tile_width_f32;
            const p1_y = line.p1.y / tile_height_f32;

            const line_left_x = @min(p0_x, p1_x);
            const line_right_x = @max(p0_x, p1_x);

            // Lines whose left-most endpoint exceeds the right edge of the
            // viewport are culled.
            if (line_left_x > tile_columns_f32) continue;

            const p0_is_top = p0_y < p1_y;
            const line_top_y = if (p0_is_top) p0_y else p1_y;
            const line_top_x = if (p0_is_top) p0_x else p1_x;
            const line_bottom_y = if (p0_is_top) p1_y else p0_y;
            const line_bottom_x = if (p0_is_top) p1_x else p0_x;

            // The saturating f32 -> u16 casts here intentionally clamp
            // negative coordinates to 0 (Rust `as u16`).
            const y_top_tiles = @min(f32ToU16Sat(line_top_y), tile_rows);
            const line_bottom_y_ceil = @ceil(line_bottom_y);
            const y_bottom_tiles = @min(f32ToU16Sat(line_bottom_y_ceil), tile_rows);

            // If y_top_tiles == y_bottom_tiles, then the line is either
            // completely above or below the viewport OR it is perfectly
            // horizontal and aligned to the tile grid, contributing no
            // winding. In either case, it should be culled.
            if (y_top_tiles >= y_bottom_tiles) continue;

            const dir: i16 = if (p0_y >= p1_y) 1 else -1;
            const f_dir: f32 = @floatFromInt(dir);

            // Lines fully to the left of the viewport are not visible but
            // still produce winding which we record here and forward to the
            // rendering stage.
            if (line_right_x < 0.0) {
                const is_start_culled = line_top_y < 0.0;

                // This branch is for handling the "start" of the line. In
                // case the line reaches above the viewport, we are already in
                // the middle so we can skip that part.
                if (!is_start_culled) {
                    self.windings.markRowActive(y_top_tiles);

                    // Note: in theory `==` should be enough, but as
                    // additional safety against numerical precision errors we
                    // use `<=`.
                    const at_top_of_tile = line_top_y <= @as(f32, @floatFromInt(y_top_tiles));
                    if (at_top_of_tile) self.windings.coarse.items[y_top_tiles] += dir;

                    const fractional_coverage = self.fractionalCoverage(y_top_tiles, line_top_y, line_bottom_y);
                    self.applyPartial(y_top_tiles, fractional_coverage, f_dir, if (at_top_of_tile) f_dir else 0.0);
                }

                const y_start_middle = if (is_start_culled) y_top_tiles else y_top_tiles + 1;
                const line_bottom_floor = @floor(line_bottom_y);
                const y_end_middle = @min(f32ToU16Sat(line_bottom_floor), tile_rows);

                var y_idx = y_start_middle;
                while (y_idx < y_end_middle) : (y_idx += 1) {
                    self.windings.coarse.items[y_idx] += dir;
                }
                self.windings.markRowRangeActive(y_start_middle, y_end_middle);

                if (line_bottom_y != line_bottom_floor and
                    y_end_middle < tile_rows and
                    // Prevent double-processing, unless the start was
                    // off-screen and hasn't been handled yet.
                    (is_start_culled or y_end_middle != y_top_tiles))
                {
                    self.windings.markRowActive(y_end_middle);
                    // Ends implicitly cross the top.
                    self.windings.coarse.items[y_end_middle] += dir;
                    const fractional_coverage = self.fractionalCoverage(y_end_middle, line_top_y, line_bottom_y);
                    // Subtract the inverse direction to avoid double counting
                    // with the coarse winding.
                    self.applyPartial(y_end_middle, fractional_coverage, f_dir, f_dir);
                }

                self.windings.culled = true;
                continue;
            }

            // Get tile coordinates for start/end points, use i32 to preserve
            // negative coordinates.
            const p0_tile_x = f32ToI32Sat(@floor(line_top_x));
            const p0_tile_y = f32ToI32Sat(@floor(line_top_y));
            const p1_tile_x = f32ToI32Sat(@floor(line_bottom_x));
            const p1_tile_y = f32ToI32Sat(@floor(line_bottom_y));

            // Special-case out lines which are fully contained within a tile.
            const not_same_tile = p0_tile_y != p1_tile_y or p0_tile_x != p1_tile_x;
            if (not_same_tile) {
                // Case vertical lines: by definition, these cannot be
                // horizontally crossing, and thus require no additional
                // left-edge culling handling.
                if (line_left_x == line_right_x) {
                    const x = @min(f32ToU16Sat(line_left_x), tile_columns -| 1);

                    // Row start, not culled.
                    const is_start_culled = line_top_y < 0.0;
                    if (!is_start_culled) {
                        const winding = bool32(@as(f32, @floatFromInt(y_top_tiles)) >= line_top_y) << WINDING_SHIFT;
                        try self.tile_buf.append(
                            allocator,
                            Tile.newClamped(x, y_top_tiles, line_idx, winding),
                        );
                    }

                    // Middle. If the start was culled, the first tile inside
                    // the viewport is a middle.
                    const y_start = if (is_start_culled) y_top_tiles else y_top_tiles + 1;

                    var y_idx = y_start;
                    while (y_idx < y_bottom_tiles) : (y_idx += 1) {
                        try self.tile_buf.append(
                            allocator,
                            Tile.newClamped(x, y_idx, line_idx, W),
                        );
                    }
                } else {
                    // General case, any line which crosses more than one tile
                    // and is not vertical.
                    const dx = p1_x - p0_x;
                    const dy = p1_y - p0_y;
                    const x_slope = dx / dy;
                    const dx_dir = bool32(line_bottom_x >= line_top_x);
                    const not_dx_dir = dx_dir ^ 1;

                    const w_start_base = dx_dir << WINDING_SHIFT;
                    const w_end_base = not_dx_dir << WINDING_SHIFT;

                    var row_ctx = AnalyticRowCtx{
                        .tiles = self,
                        .allocator = allocator,
                        .line_idx = line_idx,
                        .tile_columns = tile_columns,
                        .p0_x = p0_x,
                        .p0_y = p0_y,
                        .p1_x = p1_x,
                        .p1_y = p1_y,
                        .x_slope = x_slope,
                        .line_left_x = line_left_x,
                        .line_right_x = line_right_x,
                        .dir = dir,
                        .f_dir = f_dir,
                    };

                    const is_start_culled = line_top_y < 0.0;
                    // This branch is taken in case the line is completely
                    // inside the viewport, allowing us to save many
                    // calculations that otherwise would need to be made for
                    // viewport culling work.
                    if (line_left_x >= 0.0 and line_right_x < tile_columns_f32) {
                        if (!is_start_culled) {
                            const y: f32 = @floatFromInt(y_top_tiles);
                            const row_bottom_y = @min(y + 1.0, line_bottom_y);
                            const row_bottom_x = if (row_bottom_y == line_bottom_y)
                                line_bottom_x
                            else
                                p0_x + (row_bottom_y - p0_y) * x_slope;
                            const mask = bool32(y >= line_top_y) << WINDING_SHIFT;
                            try row_ctx.pushRowExtents(
                                y_top_tiles,
                                @min(line_top_x, row_bottom_x),
                                @max(line_top_x, row_bottom_x),
                                w_start_base & mask,
                                w_end_base & mask,
                                W & mask,
                            );
                        }

                        const y_start = if (is_start_culled) y_top_tiles else y_top_tiles + 1;

                        if (y_start < y_bottom_tiles) {
                            var row_top_x = p0_x + (@as(f32, @floatFromInt(y_start)) - p0_y) * x_slope;
                            var y_idx = y_start;
                            while (y_idx < y_bottom_tiles) : (y_idx += 1) {
                                const y: f32 = @floatFromInt(y_idx);
                                // Note: we purposefully don't precompute it
                                // once and just increment by `x_slope` after
                                // every iteration to avoid errors due to
                                // floating point inaccuracies.
                                const row_bottom_x = if (line_bottom_y < y + 1.0)
                                    line_bottom_x
                                else
                                    p0_x + (y + 1.0 - p0_y) * x_slope;
                                try row_ctx.pushRowExtents(
                                    y_idx,
                                    @min(row_top_x, row_bottom_x),
                                    @max(row_top_x, row_bottom_x),
                                    w_start_base,
                                    w_end_base,
                                    W,
                                );
                                row_top_x = row_bottom_x;
                            }
                        }
                    } else {
                        if (!is_start_culled) {
                            const y: f32 = @floatFromInt(y_top_tiles);
                            const row_bottom_y = @min(y + 1.0, line_bottom_y);
                            const mask = bool32(y >= line_top_y) << WINDING_SHIFT;
                            try row_ctx.pushRow(
                                y_top_tiles,
                                line_top_y,
                                row_bottom_y,
                                w_start_base & mask,
                                w_end_base & mask,
                                W & mask,
                            );
                        }

                        const y_start = if (is_start_culled) y_top_tiles else y_top_tiles + 1;

                        var y_idx = y_start;
                        while (y_idx < y_bottom_tiles) : (y_idx += 1) {
                            const y: f32 = @floatFromInt(y_idx);
                            const row_bottom_y = @min(y + 1.0, line_bottom_y);
                            try row_ctx.pushRow(y_idx, y, row_bottom_y, w_start_base, w_end_base, W);
                        }
                    }
                }
            } else {
                // Case line is fully contained within a single tile: these
                // also cannot cross edges!
                try self.tile_buf.append(allocator, Tile.newClamped(
                    @min(f32ToU16Sat(line_left_x), tile_columns + 1),
                    y_top_tiles,
                    line_idx,
                    bool32(@as(f32, @floatFromInt(y_top_tiles)) >= line_top_y) << WINDING_SHIFT,
                ));
            }
        }

        return self.windings.culled;
    }

    /// The 4-lane fractional coverage of a horizontal slice of a row,
    /// dispatched per `self.level` (upstream `calc_fractional_coverage!`).
    fn fractionalCoverage(
        self: *const Tiles,
        y_idx: u16,
        segment_top_y: f32,
        segment_bottom_y: f32,
    ) [Tile.HEIGHT]f32 {
        if (self.level.isFallback()) {
            return calcFractionalCoverage(y_idx, segment_top_y, segment_bottom_y);
        }
        return calcFractionalCoverageVector(y_idx, segment_top_y, segment_bottom_y);
    }

    /// Add `coverage * add` to a row's fractional winding, after optionally
    /// subtracting `subtract` from every lane (upstream `current -
    /// double_count`, then `mul_add(f_dir_v, ...)`).
    ///
    /// `fallback` runs the scalar lane loop; vector levels run the same
    /// operation order as a single `f32x4` op.
    fn applyPartial(self: *Tiles, y_idx: u16, coverage: [Tile.HEIGHT]f32, add: f32, subtract: f32) void {
        if (self.level.isFallback()) {
            const current = self.windings.partial.items[y_idx];
            var next: [Tile.HEIGHT]f32 = undefined;
            inline for (0..Tile.HEIGHT) |k| {
                next[k] = mulAdd(coverage[k], add, current[k] - subtract);
            }
            self.windings.partial.items[y_idx] = next;
            return;
        }

        const current: F32x4 = self.windings.partial.items[y_idx];
        const next = simd.mulAddUnfused(
            @as(F32x4, coverage),
            @as(F32x4, @splat(add)),
            current - @as(F32x4, @splat(subtract)),
        );
        self.windings.partial.items[y_idx] = next;
    }

    /// Generates tile commands for MSAA (Multisample Anti-Aliasing)
    /// rasterization.
    ///
    /// The primary goal is to establish "ground truth" for line-tile
    /// intersections: rather than computing exact intersection coordinates,
    /// this emits a lightweight intersection bitmask that unambiguously
    /// defines which edges of a tile a line segment touches or crosses.
    ///
    /// See upstream `make_tiles_msaa` for the bitmask layout.
    pub fn makeTilesMsaa(
        self: *Tiles,
        allocator: std.mem.Allocator,
        lines: []const Line,
        width: u16,
        height: u16,
    ) !void {
        try self.reset(allocator, width, height);

        if (width == 0 or height == 0) return;

        std.debug.assert(lines.len <= @as(usize, MAX_LINES_PER_PATH));

        const tile_columns = std.math.divCeil(u16, width, Tile.WIDTH) catch unreachable;
        const tile_rows = std.math.divCeil(u16, height, Tile.HEIGHT) catch unreachable;

        const tile_width_f32: f32 = @floatFromInt(Tile.WIDTH);
        const tile_height_f32: f32 = @floatFromInt(Tile.HEIGHT);
        const tile_columns_f32: f32 = @floatFromInt(tile_columns);

        const max_lines: usize = @min(lines.len, @as(usize, MAX_LINES_PER_PATH));
        for (lines[0..max_lines], 0..) |line, line_index| {
            const line_idx: u32 = @intCast(line_index);

            const p0_x = line.p0.x / tile_width_f32;
            const p0_y = line.p0.y / tile_height_f32;
            const p1_x = line.p1.x / tile_width_f32;
            const p1_y = line.p1.y / tile_height_f32;

            const line_left_x = @min(p0_x, p1_x);
            const line_right_x = @max(p0_x, p1_x);

            // Lines whose left-most endpoint exceeds the right edge of the
            // viewport are culled.
            if (line_left_x > tile_columns_f32) continue;

            const p0_is_top = p0_y < p1_y;
            const line_top_y = if (p0_is_top) p0_y else p1_y;
            const line_top_x = if (p0_is_top) p0_x else p1_x;
            const line_bottom_y = if (p0_is_top) p1_y else p0_y;
            const line_bottom_x = if (p0_is_top) p1_x else p0_x;

            // The saturating f32 -> u16 casts here intentionally clamp
            // negative coordinates to 0 (Rust `as u16`).
            const y_top_tiles = @min(f32ToU16Sat(line_top_y), tile_rows);
            const line_bottom_y_ceil = @ceil(line_bottom_y);
            const y_bottom_tiles = @min(f32ToU16Sat(line_bottom_y_ceil), tile_rows);

            if (y_top_tiles >= y_bottom_tiles) continue;

            // Get tile coordinates for start/end points, use i32 to preserve
            // negative coordinates.
            const p0_tile_x = f32ToI32Sat(@floor(line_top_x));
            const p0_tile_y = f32ToI32Sat(@floor(line_top_y));
            const p1_tile_x = f32ToI32Sat(@floor(line_bottom_x));
            const p1_tile_y = if (line_bottom_y == line_bottom_y_ceil)
                f32ToI32Sat(line_bottom_y) - 1
            else
                f32ToI32Sat(@floor(line_bottom_y));

            // Special-case out lines which are fully contained within a tile.
            const not_same_tile = p0_tile_y != p1_tile_y or p0_tile_x != p1_tile_x;
            if (not_same_tile) {
                // For ease of logic, special-case purely vertical lines.
                if (line_left_x == line_right_x) {
                    const x = @min(f32ToU16Sat(line_left_x), tile_columns -| 1);

                    // Row start, not culled.
                    const is_start_culled = line_top_y < 0.0;
                    if (!is_start_culled) {
                        const winding = bool32(@as(f32, @floatFromInt(y_top_tiles)) >= line_top_y) << WINDING_SHIFT;
                        const intersection_mask = B | winding;
                        try self.tile_buf.append(
                            allocator,
                            Tile.newClamped(x, y_top_tiles, line_idx, intersection_mask),
                        );
                    }

                    // Middle. If the start was culled, the first tile inside
                    // the viewport is a middle.
                    const y_start = if (is_start_culled) y_top_tiles else y_top_tiles + 1;
                    const line_bottom_floor = @floor(line_bottom_y);
                    const y_end_idx = @min(f32ToU16Sat(line_bottom_floor), tile_rows);

                    if (y_start < y_end_idx) {
                        const y_last = y_end_idx - 1;
                        var y_idx = y_start;
                        while (y_idx < y_last) : (y_idx += 1) {
                            const intersection_mask = W | B | T;
                            try self.tile_buf.append(
                                allocator,
                                Tile.newClamped(x, y_idx, line_idx, intersection_mask),
                            );
                        }

                        // Perfect touching B case.
                        {
                            const is_end_tile = bool32(@as(i32, y_last) == p1_tile_y);
                            const intersection_mask = W | T | ((1 ^ is_end_tile) << BOT_SHIFT);
                            try self.tile_buf.append(
                                allocator,
                                Tile.newClamped(x, y_last, line_idx, intersection_mask),
                            );
                        }
                    }

                    // Row end: handle the final tile (`y_end_idx`), but *only*
                    // if the line does not perfectly end on the top edge of
                    // the tile. In the case that it does, it gets handled by
                    // the middle logic above.
                    if (line_bottom_y != line_bottom_floor and y_end_idx < tile_rows) {
                        const intersection_mask = W | T;
                        try self.tile_buf.append(
                            allocator,
                            Tile.newClamped(x, y_end_idx, line_idx, intersection_mask),
                        );
                    }
                } else {
                    const dx = p1_x - p0_x;
                    const dy = p1_y - p0_y;
                    const x_slope = dx / dy;
                    const dx_dir = bool32(line_bottom_x >= line_top_x);
                    const not_dx_dir = dx_dir ^ 1;

                    const w_start_base = dx_dir << WINDING_SHIFT;
                    const w_end_base = not_dx_dir << WINDING_SHIFT;

                    // Check if the line is fully within the horizontal
                    // viewport bounds. If it is, we can skip the min/max
                    // clamping per row. Note: we use `>=` on the right edge to
                    // ensure strictly safe integer truncation.
                    const min_x = @min(p0_x, p1_x);
                    const max_x = @max(p0_x, p1_x);
                    const needs_clamping = min_x < line_left_x or max_x >= line_right_x;

                    var row_ctx = MsaaRowCtx{
                        .tiles = self,
                        .allocator = allocator,
                        .line_idx = line_idx,
                        .tile_columns = tile_columns,
                        .p0_x = p0_x,
                        .p0_y = p0_y,
                        .x_slope = x_slope,
                        .line_left_x = line_left_x,
                        .line_right_x = line_right_x,
                        .p0_tile_x = p0_tile_x,
                        .p0_tile_y = p0_tile_y,
                        .p1_tile_x = p1_tile_x,
                        .p1_tile_y = p1_tile_y,
                        .dx_dir = dx_dir,
                        .not_dx_dir = not_dx_dir,
                        .w_start_base = w_start_base,
                        .w_end_base = w_end_base,
                    };

                    try row_ctx.runLoops(
                        needs_clamping,
                        line_top_y,
                        line_bottom_y,
                        y_top_tiles,
                        tile_rows,
                    );
                }
            } else {
                // Case: line is fully contained within a single tile.
                try self.tile_buf.append(allocator, Tile.newClamped(
                    @min(f32ToU16Sat(line_left_x), tile_columns + 1),
                    y_top_tiles,
                    line_idx,
                    bool32(@as(f32, @floatFromInt(y_top_tiles)) >= line_top_y) << WINDING_SHIFT,
                ));
            }
        }
    }
};

fn tileLessThan(_: void, a: Tile, b: Tile) bool {
    return a.lessThan(b);
}

/// The row-bookkeeping half of the analytic-AA general (non-vertical) case.
const AnalyticRowCtx = struct {
    tiles: *Tiles,
    allocator: std.mem.Allocator,
    line_idx: u32,
    tile_columns: u16,
    p0_x: f32,
    p0_y: f32,
    p1_x: f32,
    p1_y: f32,
    x_slope: f32,
    line_left_x: f32,
    line_right_x: f32,
    dir: i16,
    f_dir: f32,

    /// Emit the tiles covered by `[row_left_x, row_right_x]` in row `y_idx`
    /// (upstream `push_row_extents`).
    fn pushRowExtents(
        self: *const AnalyticRowCtx,
        y_idx: u16,
        row_left_x: f32,
        row_right_x: f32,
        w_start: u32,
        w_end: u32,
        w_single: u32,
    ) !void {
        const x_start = f32ToU16Sat(row_left_x);
        const x_end = @min(f32ToU16Sat(row_right_x), self.tile_columns - 1);

        if (x_start <= x_end) {
            const winding = if (x_start == x_end) w_single else w_start;

            try self.tiles.tile_buf.append(
                self.allocator,
                Tile.new(x_start, y_idx, self.line_idx, winding),
            );

            var x_idx = x_start +| 1;
            while (x_idx < x_end) : (x_idx += 1) {
                try self.tiles.tile_buf.append(
                    self.allocator,
                    Tile.new(x_idx, y_idx, self.line_idx, 0),
                );
            }

            if (x_start < x_end) {
                try self.tiles.tile_buf.append(
                    self.allocator,
                    Tile.new(x_end, y_idx, self.line_idx, w_end),
                );
            }
        }
    }

    /// Record off-screen winding for a row and emit its on-screen extent
    /// (upstream `push_row`).
    fn pushRow(
        self: *const AnalyticRowCtx,
        y_idx: u16,
        row_top_y: f32,
        row_bottom_y: f32,
        w_start: u32,
        w_end: u32,
        w_single: u32,
    ) !void {
        const row_top_x = self.p0_x + (row_top_y - self.p0_y) * self.x_slope;
        const row_bottom_x = self.p0_x + (row_bottom_y - self.p0_y) * self.x_slope;

        // TODO upstream: evaluate whether we need the second max/min.
        const row_left_x = @max(@min(row_top_x, row_bottom_x), self.line_left_x);
        const row_right_x = @min(@max(row_top_x, row_bottom_x), self.line_right_x);

        if (row_left_x < 0.0) {
            self.tiles.windings.culled = true;

            if (row_right_x < 0.0) {
                // Although the line may cross the left edge, the rightmost
                // point in this row may still be fully left of the viewport.
                // In this case, record the winding and emit no tiles.
                self.tiles.windings.markRowActive(y_idx);

                const crosses_top = (w_single & W) != 0;
                if (crosses_top) self.tiles.windings.coarse.items[y_idx] += self.dir;

                const fractional_coverage = self.tiles.fractionalCoverage(y_idx, row_top_y, row_bottom_y);
                self.tiles.applyPartial(
                    y_idx,
                    fractional_coverage,
                    self.f_dir,
                    if (crosses_top) self.f_dir else 0.0,
                );
                return;
            } else {
                // The line crosses into the viewport in this row. Record only
                // the fractional portion of the winding, as the coarse
                // winding will naturally get included by the clamped tile
                // logic!
                const y_slope = (self.p1_y - self.p0_y) / (self.p1_x - self.p0_x);
                const y_intersect = row_top_y - (row_top_x * y_slope);

                const off_screen_top_y, const off_screen_bottom_y = if (row_top_x < 0.0)
                    .{ row_top_y, @min(row_bottom_y, y_intersect) }
                else
                    .{ @max(row_top_y, y_intersect), row_bottom_y };

                if (off_screen_top_y < off_screen_bottom_y) {
                    self.tiles.windings.markRowActive(y_idx);
                    const fractional_coverage = self.tiles.fractionalCoverage(y_idx, off_screen_top_y, off_screen_bottom_y);
                    self.tiles.applyPartial(y_idx, fractional_coverage, self.f_dir, 0.0);
                }
            }
        }

        try self.pushRowExtents(y_idx, row_left_x, row_right_x, w_start, w_end, w_single);
    }
};

/// The row-bookkeeping half of the MSAA general (non-vertical) case.
const MsaaRowCtx = struct {
    tiles: *Tiles,
    allocator: std.mem.Allocator,
    line_idx: u32,
    tile_columns: u16,
    p0_x: f32,
    p0_y: f32,
    x_slope: f32,
    line_left_x: f32,
    line_right_x: f32,
    p0_tile_x: i32,
    p0_tile_y: i32,
    p1_tile_x: i32,
    p1_tile_y: i32,
    dx_dir: u32,
    not_dx_dir: u32,
    w_start_base: u32,
    w_end_base: u32,

    /// Upstream `push_edge!`: compute the intersection bitmask for one edge
    /// tile and append it.
    fn pushEdge(
        self: *const MsaaRowCtx,
        x_idx: u16,
        y: u16,
        row_top_x: f32,
        row_bottom_x: f32,
        canonical_start: i32,
        canonical_end: u16,
        winding_input: u32,
        check_s: bool,
        check_e: bool,
    ) !void {
        const unc_row_start = bool32(@as(i32, x_idx) == canonical_start);
        const unc_row_end = bool32(x_idx == canonical_end);

        const canonical_row_start = (self.dx_dir & unc_row_start) | (self.not_dx_dir & unc_row_end);
        const canonical_row_end = (self.not_dx_dir & unc_row_start) | (self.dx_dir & unc_row_end);

        const start_tile: u32 = if (check_s) bool32(@as(i32, x_idx) == self.p0_tile_x and @as(i32, y) == self.p0_tile_y) else 0;

        const end_tile: u32 = if (check_e) bool32(@as(i32, x_idx) == self.p1_tile_x and @as(i32, y) == self.p1_tile_y) else 0;

        var mask = winding_input;

        // Entrant/Exit.
        mask |= canonical_row_start & (1 ^ start_tile);
        mask |= ((1 ^ canonical_row_start) << @as(u5, @intCast(self.not_dx_dir))) << LEFT_SHIFT;
        mask |= (canonical_row_end & (1 ^ end_tile)) << BOT_SHIFT;
        mask |= ((1 ^ canonical_row_end) << @as(u5, @intCast(self.dx_dir))) << LEFT_SHIFT;

        // Corner.
        const x_left_f: f32 = @floatFromInt(x_idx);
        const x_right_f: f32 = @floatFromInt(x_idx + 1);
        const trc = bool32(row_top_x == x_right_f) & (1 ^ start_tile);
        const tlc = bool32(row_top_x == x_left_f) & (1 ^ start_tile);
        const brc = bool32(row_bottom_x == x_right_f) & (1 ^ end_tile);
        const blc = bool32(row_bottom_x == x_left_f) & (1 ^ end_tile);
        // Top left is handled specially.
        const tie_break = tlc & (canonical_row_start ^ 1);

        mask |= (tie_break | blc) << LEFT_SHIFT;
        mask |= (trc | brc) << RIGHT_SHIFT;
        mask &= ~(tie_break | trc);
        mask &= ~((blc | brc) << BOT_SHIFT);

        try self.tiles.tile_buf.append(self.allocator, Tile.new(x_idx, y, self.line_idx, mask));
    }

    /// Upstream `process_row!`: clip a row, then emit its edge tiles and the
    /// `R | L` interior tiles.
    fn processRow(
        self: *const MsaaRowCtx,
        y_idx: u16,
        row_top_y: f32,
        row_bottom_y: f32,
        w_mask: u32,
        check_s: bool,
        check_e: bool,
        clamped: bool,
    ) !void {
        const row_top_x = self.p0_x + (row_top_y - self.p0_y) * self.x_slope;
        const row_bottom_x = self.p0_x + (row_bottom_y - self.p0_y) * self.x_slope;

        var row_left_x: f32 = undefined;
        var row_right_x: f32 = undefined;
        var x_end: u16 = undefined;
        if (clamped) {
            row_left_x = @max(@min(row_top_x, row_bottom_x), self.line_left_x);
            row_right_x = @min(@max(row_top_x, row_bottom_x), self.line_right_x);
            x_end = @min(f32ToU16Sat(row_right_x), self.tile_columns -| 1);
        } else {
            row_left_x = @min(row_top_x, row_bottom_x);
            row_right_x = @max(row_top_x, row_bottom_x);
            // Safe because we checked bounds earlier.
            x_end = f32ToU16Sat(row_right_x);
        }

        const canonical_x_start = f32ToI32Sat(@floor(row_left_x));
        const canonical_x_end = f32ToU16Sat(row_right_x);
        const x_start = f32ToU16Sat(row_left_x);

        if (x_start <= x_end) {
            const is_single = bool32(x_start == x_end);
            const w_left = (self.w_start_base | (is_single << WINDING_SHIFT)) & w_mask;

            try self.pushEdge(
                x_start,
                y_idx,
                row_top_x,
                row_bottom_x,
                canonical_x_start,
                canonical_x_end,
                w_left,
                check_s,
                check_e,
            );

            var x_idx = x_start +| 1;
            while (x_idx < x_end) : (x_idx += 1) {
                try self.tiles.tile_buf.append(
                    self.allocator,
                    Tile.new(x_idx, y_idx, self.line_idx, R | L),
                );
            }

            if (x_start < x_end) {
                const w_right = self.w_end_base & w_mask;
                try self.pushEdge(
                    x_end,
                    y_idx,
                    row_top_x,
                    row_bottom_x,
                    canonical_x_start,
                    canonical_x_end,
                    w_right,
                    check_s,
                    check_e,
                );
            }
        }
    }

    /// Upstream `run_loops!`: walk the top row, middle rows, and (if present)
    /// the bottom row of a line.
    fn runLoops(
        self: *const MsaaRowCtx,
        clamped: bool,
        line_top_y: f32,
        line_bottom_y: f32,
        y_top_tiles: u16,
        tile_rows: u16,
    ) !void {
        // Top row.
        const is_start_culled = line_top_y < 0.0;
        if (!is_start_culled) {
            const y: f32 = @floatFromInt(y_top_tiles);
            const row_bottom_y = @min(y + 1.0, line_bottom_y);
            const mask = bool32(y >= line_top_y) << WINDING_SHIFT;
            try self.processRow(y_top_tiles, line_top_y, row_bottom_y, mask, true, true, clamped);
        }

        const y_start_middle = if (is_start_culled) y_top_tiles else y_top_tiles + 1;
        const line_bottom_floor = @floor(line_bottom_y);
        const y_end_middle = @min(f32ToU16Sat(line_bottom_floor), tile_rows);
        const has_separate_bottom_row = line_bottom_y != line_bottom_floor and
            y_end_middle < tile_rows and
            (is_start_culled or y_end_middle != y_top_tiles);

        if (y_start_middle < y_end_middle) {
            var y_idx = y_start_middle;
            while (y_idx < y_end_middle) : (y_idx += 1) {
                const y: f32 = @floatFromInt(y_idx);
                const row_bottom_y = @min(y + 1.0, line_bottom_y);
                const is_last_middle = y_idx == y_end_middle - 1;
                const check_end = is_last_middle and !has_separate_bottom_row;

                try self.processRow(y_idx, y, row_bottom_y, std.math.maxInt(u32), false, check_end, clamped);
            }
        }

        // Bottom row.
        if (has_separate_bottom_row) {
            const y_idx = y_end_middle;
            const y: f32 = @floatFromInt(y_idx);
            try self.processRow(y_idx, y, line_bottom_y, std.math.maxInt(u32), false, true, clamped);
        }
    }
};

/// The 4-lane fractional coverage of a horizontal slice of a row, matching
/// upstream's f32x4 `px_top`/`px_bottom` computation.
fn calcFractionalCoverage(y_idx: u16, segment_top_y: f32, segment_bottom_y: f32) [Tile.HEIGHT]f32 {
    const y_idx_f32: f32 = @floatFromInt(y_idx);
    const tile_height_f32: f32 = @floatFromInt(Tile.HEIGHT);
    const local_y_start = (segment_top_y - y_idx_f32) * tile_height_f32;
    const local_y_end = (segment_bottom_y - y_idx_f32) * tile_height_f32;

    var out: [Tile.HEIGHT]f32 = undefined;
    inline for (0..Tile.HEIGHT) |i| {
        const px_top: f32 = @floatFromInt(i);
        const px_bottom = px_top + 1.0;
        out[i] = @max(@min(px_bottom, local_y_end) - @max(px_top, local_y_start), 0.0);
    }
    return out;
}

/// `@Vector` backend of [`calcFractionalCoverage`] (upstream `px_top`/
/// `px_bottom` f32x4 computation). Same per-lane operation order as the
/// scalar loop.
fn calcFractionalCoverageVector(
    y_idx: u16,
    segment_top_y: f32,
    segment_bottom_y: f32,
) [Tile.HEIGHT]f32 {
    const y_idx_f32: f32 = @floatFromInt(y_idx);
    const tile_height_f32: f32 = @floatFromInt(Tile.HEIGHT);
    const local_y_start = (segment_top_y - y_idx_f32) * tile_height_f32;
    const local_y_end = (segment_bottom_y - y_idx_f32) * tile_height_f32;

    const px_top: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };
    const px_bottom = px_top + @as(F32x4, @splat(1.0));
    const start_v: F32x4 = @splat(local_y_start);
    const end_v: F32x4 = @splat(local_y_end);
    const zero: F32x4 = @splat(0.0);

    return @max(@min(px_bottom, end_v) - @max(px_top, start_v), zero);
}

/// Rust `bool as u32`.
inline fn bool32(b: bool) u32 {
    return @intFromBool(b);
}

/// Multiply-add with upstream's scalar-fallback semantics: a separate
/// multiply, then an add. Zig's strict float mode does not contract this.
inline fn mulAdd(a: f32, b: f32, c: f32) f32 {
    const product = a * b;
    return product + c;
}

/// Rust `f32 as u16`: truncate toward zero, saturate, NaN becomes 0.
inline fn f32ToU16Sat(x: f32) u16 {
    if (!(x > 0.0)) return 0; // Also catches NaN.
    if (x >= @as(f32, @floatFromInt(std.math.maxInt(u16)))) return std.math.maxInt(u16);
    return @intFromFloat(x);
}

/// Rust `f32 as i32`: truncate toward zero, saturate, NaN becomes 0.
inline fn f32ToI32Sat(x: f32) i32 {
    if (std.math.isNan(x)) return 0;
    const min: f32 = @floatFromInt(std.math.minInt(i32));
    const max: f32 = @floatFromInt(std.math.maxInt(i32));
    if (x <= min) return std.math.minInt(i32);
    if (x >= max) return std.math.maxInt(i32);
    return @intFromFloat(x);
}

// ---------------------------------------------------------------------------
// Tests (ported from tile.rs `#[cfg(test)] mod tests`).
// ---------------------------------------------------------------------------

const testing = std.testing;

const VIEW_DIM: u16 = 100;
const F_V_DIM: f32 = @floatFromInt(VIEW_DIM);

fn mkLine(x0: f32, y0: f32, x1: f32, y1: f32) Line {
    return .{ .p0 = .{ .x = x0, .y = y0 }, .p1 = .{ .x = x1, .y = y1 } };
}

fn newTiles(allocator: std.mem.Allocator) Tiles {
    return Tiles.init(allocator, .baseline, VIEW_DIM, VIEW_DIM);
}

fn expectTilesEqual(actual: []const Tile, expected: []const Tile, comptime msg: []const u8) !void {
    if (actual.len != expected.len) {
        std.debug.print("{s}: expected {} tiles, got {}\n", .{ msg, expected.len, actual.len });
        for (actual, 0..) |t, i| std.debug.print("  actual[{}] = {any}\n", .{ i, t });
        return error.TestUnexpectedResult;
    }
    for (actual, expected, 0..) |got, want, i| {
        if (got.toBits() != want.toBits()) {
            std.debug.print("{s}: tile[{}]: got {any}, want {any}\n", .{ msg, i, got, want });
            return error.TestUnexpectedResult;
        }
    }
}

fn checkAnalyticAaMatches(actual: []const Tile, expected: []const Tile) !void {
    if (actual.len != expected.len) {
        std.debug.print("Analytic AA: expected {} tiles, got {}\n", .{ expected.len, actual.len });
        return error.TestUnexpectedResult;
    }
    for (actual, expected, 0..) |got, want, i| {
        const got_winding = got.packed_winding_line_idx & W;
        const want_winding = want.packed_winding_line_idx & W;
        if (got.x != want.x or got.y != want.y or got.lineIdx() != want.lineIdx() or
            got_winding != want_winding)
        {
            std.debug.print("Analytic AA: tile[{}]: got {any}, want {any}\n", .{ i, got, want });
            return error.TestUnexpectedResult;
        }
    }
}

fn assertTilesMatch(
    allocator: std.mem.Allocator,
    tiles: *Tiles,
    lines: []const Line,
    width: u16,
    height: u16,
    expected: []const Tile,
) !void {
    try tiles.makeTilesMsaa(allocator, lines, width, height);
    try expectTilesEqual(tiles.tile_buf.items, expected, "MSAA: Tile buffer mismatch");

    _ = try tiles.makeTilesAnalyticAa(allocator, lines, width, height);
    try checkAnalyticAaMatches(tiles.tile_buf.items, expected);
}

//==============================================================================================
// Culled lines
//==============================================================================================

test "cull sloped outside lines" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, -7.0, 3.0, -1.0),
        mkLine(1.0, -11.0, 3.0, -1.0),
        mkLine(F_V_DIM + 1.0, 50.0, F_V_DIM + 3.0, 70.0),
        mkLine(1.0, F_V_DIM + 1.0, 3.0, F_V_DIM + 7.0),
        mkLine(1.0, F_V_DIM + 1.0, 3.0, F_V_DIM + 13.0),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &.{});
}

test "sloped line crossing top" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(-2.0, -3.0, 2.0, 1.0),
        mkLine(6.0, -1.0, 5.0, 2.0),
        mkLine(9.0, -10.0, 10.0, 3.0),
        mkLine(2.0, 1.0, -2.0, -3.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | T),
        Tile.new(1, 0, 1, W | T),
        Tile.new(2, 0, 2, W | T),
        Tile.new(0, 0, 3, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped line crossing bot" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(5.0, F_V_DIM + 3.0, 6.0, F_V_DIM - 2.0),
        mkLine(10.0, F_V_DIM + 1.0, 9.0, F_V_DIM - 1.0),
        mkLine(2.0, F_V_DIM - 2.0, 3.0, F_V_DIM + 3.0),
    };
    const expected = [_]Tile{
        Tile.new(1, 24, 0, B),
        Tile.new(2, 24, 1, B),
        Tile.new(0, 24, 2, B),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped line crossing top multi tile" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, -5.0, 6.0, 7.0),
        mkLine(2.5, -10.0, 3.5, 6.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | T | R),
        Tile.new(1, 0, 0, L | B),
        Tile.new(1, 1, 0, W | T),
        Tile.new(0, 0, 1, W | T | B),
        Tile.new(0, 1, 1, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped line crossing bot multi tile" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(12.0, F_V_DIM + 10.0, 2.0, 94.0),
        mkLine(1.5, F_V_DIM + 5.0, 3.5, 94.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 23, 0, B),
        Tile.new(0, 24, 0, W | T | R),
        Tile.new(1, 24, 0, B | L),
        Tile.new(0, 23, 1, B),
        Tile.new(0, 24, 1, W | T | B),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped line crossing right" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(97.0, 1.0, F_V_DIM + 1.0, 2.0),
        mkLine(93.0, 1.0, F_V_DIM + 5.0, 2.0),
    };
    const expected = [_]Tile{
        Tile.new(24, 0, 0, R),
        Tile.new(23, 0, 1, R),
        Tile.new(24, 0, 1, R | L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped line crossing left" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(-5.0, 1.0, 1.0, 2.0),
        mkLine(-5.0, 1.0, 5.0, 2.0),
        mkLine(-5.0, 1.0, 13.0, 9.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, L),
        Tile.new(0, 0, 1, L | R),
        Tile.new(1, 0, 1, L),
        Tile.new(0, 0, 2, L | B),
        Tile.new(0, 1, 2, W | R | T),
        Tile.new(1, 1, 2, R | L),
        Tile.new(2, 1, 2, L | B),
        Tile.new(2, 2, 2, W | R | T),
        Tile.new(3, 2, 2, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "horizontal line above viewport" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(10.0, -5.0, 90.0, -5.0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &.{});
}

test "horizontal line below viewport" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(10.0, F_V_DIM + 5.0, 90.0, F_V_DIM + 5.0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &.{});
}

test "horizontal line crossing left viewport" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(-10.0, 10.0, 10.0, 10.0)};
    const expected = [_]Tile{
        Tile.new(0, 2, 0, L | R),
        Tile.new(1, 2, 0, L | R),
        Tile.new(2, 2, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "horizontal line crossing right viewport" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(F_V_DIM - 5.0, 10.0, F_V_DIM + 5.0, 10.0)};
    const expected = [_]Tile{
        Tile.new(23, 2, 0, R),
        Tile.new(24, 2, 0, L | R),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical lines outside viewport" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, -5.0, 1.0, -1.0),
        mkLine(1.0, F_V_DIM + 1.0, 1.0, F_V_DIM + 5.0),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &.{});
}

test "vertical path on the right of viewport" {
    const a = testing.allocator;
    const viewport_width: u16 = 10;
    const viewport_height: u16 = 10;

    var path = try @import("../kurbo/root.zig").bezpath.fromSvg(a, "M261,0 L78848,0 L78848,4 L261,4 Z");
    defer path.deinit(a);

    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(a);
    var ctx = flatten.FlattenCtx.init();
    defer ctx.deinit(a);
    try flatten.fill(
        a,
        .baseline,
        path.elementsSlice(),
        @import("../kurbo/root.zig").Affine.IDENTITY,
        &line_buf,
        &ctx,
        @import("geometry.zig").RectU16.new(0, 0, viewport_width, viewport_height),
    );

    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, line_buf.items, viewport_width, viewport_height, &.{});
}

test "vertical line crossing top viewport" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, -7.0, 1.0, 3.0),
        mkLine(1.0, -7.0, 1.0, 7.0),
        mkLine(1.0, -7.0, 1.0, 8.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | T),
        Tile.new(0, 0, 1, W | B | T),
        Tile.new(0, 1, 1, W | T),
        Tile.new(0, 0, 2, W | B | T),
        Tile.new(0, 1, 2, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line crossing bot viewport" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, F_V_DIM - 1.0, 1.0, F_V_DIM + 5.0),
        mkLine(1.0, F_V_DIM - 5.0, 1.0, F_V_DIM + 5.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 24, 0, B),
        Tile.new(0, 23, 1, B),
        Tile.new(0, 24, 1, W | T | B),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "clip top left corner" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(-1.0, 2.0, 2.0, -1.0)};
    const expected = [_]Tile{Tile.new(0, 0, 0, W | L | T)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "clip bottom right corner" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(F_V_DIM + 1.0, F_V_DIM - 2.0, F_V_DIM - 2.0, F_V_DIM + 1.0)};
    const expected = [_]Tile{Tile.new(24, 24, 0, R | B)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

//==============================================================================================
// Axis-aligned lines
//==============================================================================================

test "horizontal line left to right three tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.5, 1.0, 8.5, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "resize works correctly" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.5, 1.0, 8.5, 1.0),
        mkLine(1.5, 13.0, 8.5, 13.0),
    };
    const small_expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, L),
    };
    const large_expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, L),
        Tile.new(0, 3, 1, R),
        Tile.new(1, 3, 1, R | L),
        Tile.new(2, 3, 1, L),
    };

    var tiles = Tiles.init(a, .baseline, 12, 8);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, 12, 8, &small_expected);
    try assertTilesMatch(a, &tiles, &lines, 12, 16, &large_expected);
    try assertTilesMatch(a, &tiles, &lines, 12, 8, &small_expected);
}

test "horizontal line right to left three tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(8.5, 1.0, 1.5, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "horizontal line multi tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.5, 1.0, 12.5, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, R | L),
        Tile.new(3, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line down three tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.5, 1.0, 8.5)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, B),
        Tile.new(0, 1, 0, W | T | B),
        Tile.new(0, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line down multi tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 1.0, 13.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, B),
        Tile.new(0, 1, 0, W | T | B),
        Tile.new(0, 2, 0, W | T | B),
        Tile.new(0, 3, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line up three tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 13.0, 1.0, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, B),
        Tile.new(0, 1, 0, W | T | B),
        Tile.new(0, 2, 0, W | T | B),
        Tile.new(0, 3, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line up multi tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 8.5, 1.0, 1.5)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, B),
        Tile.new(0, 1, 0, W | T | B),
        Tile.new(0, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line touching bot" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 1.0, 8.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, B),
        Tile.new(0, 1, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "vertical line touching top" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 0.0, 1.0, 7.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | B),
        Tile.new(0, 1, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

//==============================================================================================
// Sloped lines
//==============================================================================================

test "top left to bottom right" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 11.0, 9.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, L | B),
        Tile.new(1, 1, 0, W | R | T),
        Tile.new(2, 1, 0, L | B),
        Tile.new(2, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "bottom right to top left" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(11.0, 9.0, 1.0, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, L | B),
        Tile.new(1, 1, 0, W | R | T),
        Tile.new(2, 1, 0, L | B),
        Tile.new(2, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "bottom left to top right" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(2.0, 11.0, 14.0, 6.0)};
    const expected = [_]Tile{
        Tile.new(2, 1, 0, R | B),
        Tile.new(3, 1, 0, L),
        Tile.new(0, 2, 0, R),
        Tile.new(1, 2, 0, R | L),
        Tile.new(2, 2, 0, W | L | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "top right to bottom left" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(14.0, 6.0, 2.0, 11.0)};
    const expected = [_]Tile{
        Tile.new(2, 1, 0, R | B),
        Tile.new(3, 1, 0, L),
        Tile.new(0, 2, 0, R),
        Tile.new(1, 2, 0, R | L),
        Tile.new(2, 2, 0, W | L | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "two lines in single tile" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, 3.0, 3.0, 3.0),
        mkLine(3.0, 3.0, 0.0, 1.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, 0),
        Tile.new(0, 0, 1, 0),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal cross corner" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(3.0, 5.0, 5.0, 3.0)};
    const expected = [_]Tile{
        Tile.new(1, 0, 0, L),
        Tile.new(0, 1, 0, R),
        Tile.new(1, 1, 0, W | L | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal cross corner two" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(7.9, 7.9, 0.1, 0.1)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, L),
        Tile.new(1, 1, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal down slope tiles" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(5.0, 5.0, 9.0, 9.0)};
    const expected = [_]Tile{
        Tile.new(1, 1, 0, R),
        Tile.new(2, 1, 0, L),
        Tile.new(2, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal up slope tiles" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(5.0, 9.0, 9.0, 5.0)};
    const expected = [_]Tile{
        Tile.new(1, 1, 0, R | B),
        Tile.new(2, 1, 0, L),
        Tile.new(1, 2, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal down one tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 0.0, 4.0, 4.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | R),
        Tile.new(1, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal up one tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 4.0, 4.0, 0.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, W | L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal down two tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 0.0, 8.0, 8.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | R),
        Tile.new(1, 0, 0, L),
        Tile.new(1, 1, 0, W | R | T),
        Tile.new(2, 1, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "diagonal up two tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 8.0, 8.0, 0.0)};
    const expected = [_]Tile{
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, W | L),
        Tile.new(0, 1, 0, R),
        Tile.new(1, 1, 0, W | L | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped ending right" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 8.0, 2.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, R | L),
        Tile.new(2, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

// This test reproduces an issue where a floating point inaccuracy would cause
// a tile with the winding bit being emitted at a slightly earlier position,
// causing a filled 4x4 block artifact to appear.
test "issue early winding emission" {
    const a = testing.allocator;
    const width: u16 = Tile.WIDTH * 35;
    const height: u16 = Tile.HEIGHT * 7;

    const tile_width: f32 = @floatFromInt(Tile.WIDTH);
    const tile_height: f32 = @floatFromInt(Tile.HEIGHT);
    const lines = [_]Line{
        mkLine(32.89 * tile_width, 0.9 * tile_height, 33.5 * tile_width, 7.0 * tile_height),
    };

    var tiles = Tiles.init(a, .baseline, height, height);
    defer tiles.deinit(a);
    _ = try tiles.makeTilesAnalyticAa(a, &lines, width, height);

    var row_tiles: [8]Tile = undefined;
    var count: usize = 0;
    for (tiles.tile_buf.items) |t| {
        if (t.y == 2) {
            row_tiles[count] = t;
            count += 1;
        }
    }

    // When the issue occurred, another tile at location x = 32, y = 2 would be
    // emitted.
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(Tile.new(33, 2, 0, W).toBits(), row_tiles[0].toBits());
}

test "sloped touching top" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 8.0, 4.0, 0.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R | B),
        Tile.new(1, 0, 0, W | L),
        Tile.new(0, 1, 0, W | T),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "sloped touching bot" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 0.0, 4.0, 8.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W | B),
        Tile.new(0, 1, 0, W | R | T),
        Tile.new(1, 1, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

//==============================================================================================
// Same-tile cases
//==============================================================================================

test "same tile" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 3.0, 3.0)};
    const expected = [_]Tile{Tile.new(0, 0, 0, 0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "same tile left" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(0.0, 1.0, 3.0, 1.0)};
    const expected = [_]Tile{Tile.new(0, 0, 0, 0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "same tile top" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 0.0, 1.0, 3.0)};
    const expected = [_]Tile{Tile.new(0, 0, 0, W)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "same tile right" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 4.0, 1.0)};
    const expected = [_]Tile{
        Tile.new(0, 0, 0, R),
        Tile.new(1, 0, 0, L),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "same tile bottom" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(1.0, 1.0, 1.0, 4.0),
        mkLine(1.0, 1.0, 2.0, 4.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, 0),
        Tile.new(0, 0, 1, 0),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

test "same tile top left" {
    const a = testing.allocator;
    const lines = [_]Line{
        mkLine(0.0, 1.0, 1.0, 0.0),
        mkLine(0.0, 0.0001, 0.0001, 0.0),
    };
    const expected = [_]Tile{
        Tile.new(0, 0, 0, W),
        Tile.new(0, 0, 1, W),
    };
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try assertTilesMatch(a, &tiles, &lines, VIEW_DIM, VIEW_DIM, &expected);
}

//==============================================================================================
// CulledWindings & row marking logic
//==============================================================================================

test "culled windings new and reset" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 8);
    defer windings.deinit(a);

    try testing.expectEqual(@as(usize, 2), windings.partial.items.len);
    try testing.expectEqual(@as(usize, 2), windings.coarse.items.len);
    try testing.expectEqual(@as(usize, 1), windings.active.items.len);

    windings.coarse.items[0] = 1;
    windings.active.items[0] = 0xFF;
    windings.culled = true;

    try windings.reset(a, 8);
    try testing.expectEqual(@as(i16, 0), windings.coarse.items[0]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[0]);

    windings.coarse.items[0] = 1;
    windings.active.items[0] = 0xFF;
    windings.culled = false;

    try windings.reset(a, 8);
    try testing.expectEqual(@as(i16, 1), windings.coarse.items[0]);
    try testing.expectEqual(@as(u32, 0xFF), windings.active.items[0]);

    windings.culled = true;
    try windings.reset(a, 12);
    try testing.expectEqual(@as(i16, 0), windings.coarse.items[0]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[0]);
}

test "mark row active" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowActive(0);
    windings.markRowActive(5);
    windings.markRowActive(31);
    windings.markRowActive(32);
    try testing.expectEqual((@as(u32, 1) << 0) | (@as(u32, 1) << 5) | (@as(u32, 1) << 31), windings.active.items[0]);
    try testing.expectEqual(@as(u32, 1) << 0, windings.active.items[1]);
}

test "mark row range single word" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowRangeActive(5, 10);
    const expected_mask = ((@as(u32, 1) << 5) - 1) << 5;
    try testing.expectEqual(expected_mask, windings.active.items[0]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[1]);
}

test "mark row range full word" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowRangeActive(0, 32);
    try testing.expectEqual(std.math.maxInt(u32), windings.active.items[0]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[1]);
}

test "mark row range spanning two words" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowRangeActive(30, 35);
    try testing.expectEqual((@as(u32, 1) << 30) | (@as(u32, 1) << 31), windings.active.items[0]);
    try testing.expectEqual((@as(u32, 1) << 0) | (@as(u32, 1) << 1) | (@as(u32, 1) << 2), windings.active.items[1]);
}

test "mark row range spanning multiple words" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 500);
    defer windings.deinit(a);

    windings.markRowRangeActive(10, 80);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)) << 10, windings.active.items[0]);
    try testing.expectEqual(std.math.maxInt(u32), windings.active.items[1]);
    try testing.expectEqual((@as(u32, 1) << 16) - 1, windings.active.items[2]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[3]);
}

test "mark row range empty or invalid" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowRangeActive(10, 10);
    windings.markRowRangeActive(15, 10);
    try testing.expectEqual(@as(u32, 0), windings.active.items[0]);
    try testing.expectEqual(@as(u32, 0), windings.active.items[1]);
}

test "for active rows in range visits set rows" {
    const a = testing.allocator;
    var windings = try CulledWindings.init(a, 200);
    defer windings.deinit(a);

    windings.markRowActive(0);
    windings.markRowActive(5);
    windings.markRowActive(40);
    windings.markRowActive(63);

    var visited = std.ArrayList(usize).empty;
    defer visited.deinit(a);
    const Ctx = struct {
        rows: *std.ArrayList(usize),
        fn onRow(ctx: *@This(), row: usize) void {
            ctx.rows.append(std.testing.allocator, row) catch @panic("OOM");
        }
    };
    var ctx = Ctx{ .rows = &visited };
    windings.forActiveRowsInRange(0, 64, &ctx, Ctx.onRow);

    try testing.expectEqualSlices(usize, &.{ 0, 5, 40, 63 }, visited.items);
    visited.clearRetainingCapacity();
    windings.forActiveRowsInRange(1, 63, &ctx, Ctx.onRow);
    try testing.expectEqualSlices(usize, &.{ 5, 40 }, visited.items);
}

//==============================================================================================
// Miscellaneous cases
//==============================================================================================

// See https://github.com/LaurenzV/cpu-sparse-experiments/issues/46.
test "infinite loop" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(22.0, 552.0, 224.0, 388.0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    try tiles.makeTilesMsaa(a, &lines, 600, 600);
    _ = try tiles.makeTilesAnalyticAa(a, &lines, 600, 600);
}

test "analytic aa tiling is bit-identical across SIMD levels" {
    const a = testing.allocator;

    const levels = [_]simd.Level{
        .baseline, .sse2, .sse4_2, .avx2, .avx512, .neon, .wasm_simd128,
    };

    var scalar = Tiles.init(a, .fallback, 128, 128);
    defer scalar.deinit(a);
    var vector = Tiles.init(a, .baseline, 128, 128);
    defer vector.deinit(a);

    var prng = std.Random.DefaultPrng.init(0x7113_c0de);
    const random = prng.random();

    var lines: [64]Line = undefined;
    var iter: usize = 0;
    while (iter < 128) : (iter += 1) {
        const n = 1 + random.uintLessThan(usize, 64);
        for (lines[0..n]) |*line| {
            // Mix axis crossings, off-screen starts, and vertical lines.
            const x0 = random.float(f32) * 400.0 - 100.0;
            const y0 = random.float(f32) * 400.0 - 100.0;
            const x1 = if (iter % 5 == 0) x0 else random.float(f32) * 400.0 - 100.0;
            const y1 = random.float(f32) * 400.0 - 100.0;
            line.* = mkLine(x0, y0, x1, y1);
        }

        const culled_reference = try scalar.makeTilesAnalyticAa(a, lines[0..n], 128, 128);
        for (levels) |level| {
            vector.level = level;
            const culled = try vector.makeTilesAnalyticAa(a, lines[0..n], 128, 128);
            try testing.expectEqual(culled_reference, culled);
            try testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(scalar.tile_buf.items),
                std.mem.sliceAsBytes(vector.tile_buf.items),
            );
            try testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(scalar.windings.partial.items),
                std.mem.sliceAsBytes(vector.windings.partial.items),
            );
            try testing.expectEqualSlices(
                i16,
                scalar.windings.coarse.items,
                vector.windings.coarse.items,
            );
            try testing.expectEqualSlices(
                u32,
                scalar.windings.active.items,
                vector.windings.active.items,
            );
        }
    }
}

// See https://github.com/linebender/vello/issues/1321.
test "overflow" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(59.60001, 40.78, 520599.6, 100.18)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);
    _ = try tiles.makeTilesAnalyticAa(a, &lines, 200, 100);
    try tiles.makeTilesMsaa(a, &lines, 200, 100);
}

test "sort test" {
    const a = testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(a);
    var tiles = Tiles.init(a, .baseline, VIEW_DIM, VIEW_DIM);
    defer tiles.deinit(a);

    var y = F_V_DIM - 10.0;
    while (y > 10.0) : (y -= 4.0) {
        try lines.append(a, mkLine(F_V_DIM - 10.0, y, 10.0, y));
        try lines.append(a, mkLine(F_V_DIM - 12.0, y, 12.0, y));
    }

    try tiles.makeTilesMsaa(a, lines.items, VIEW_DIM, VIEW_DIM);
    try testing.expect(tiles.tile_buf.items[0].y > tiles.tile_buf.items[tiles.tile_buf.items.len - 1].y);
    tiles.sortTiles();
    try checkSorted(tiles.tile_buf.items);

    _ = try tiles.makeTilesAnalyticAa(a, lines.items, VIEW_DIM, VIEW_DIM);
    try testing.expect(tiles.tile_buf.items[0].y > tiles.tile_buf.items[tiles.tile_buf.items.len - 1].y);
    tiles.sortTiles();
    try checkSorted(tiles.tile_buf.items);
}

fn checkSorted(buf: []const Tile) !void {
    for (buf[0 .. buf.len - 1], 0..) |current, i| {
        const next = buf[i + 1];

        if (current.y > next.y) {
            std.debug.print(
                "Sort failure [Y]: Tile[{}] (y={}) > Tile[{}] (y={})\n",
                .{ i, current.y, i + 1, next.y },
            );
            return error.TestUnexpectedResult;
        }

        if (current.y == next.y) {
            if (current.x > next.x) {
                std.debug.print(
                    "Sort failure [X]: at Row y={}, Tile[{}] (x={}) > Tile[{}] (x={})\n",
                    .{ current.y, i, current.x, i + 1, next.x },
                );
                return error.TestUnexpectedResult;
            }

            if (current.x == next.x and
                current.packed_winding_line_idx > next.packed_winding_line_idx)
            {
                std.debug.print(
                    "Sort failure [Payload]: at {}x{}, Tile[{}] (val={}) > Tile[{}] (val={})\n",
                    .{ current.x, current.y, i, current.packed_winding_line_idx, i + 1, next.packed_winding_line_idx },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

//==============================================================================================
// Bit-packing and constants
//==============================================================================================

test "tile bit packing helpers" {
    const t = Tile.new(3, 5, 17, W | R | L | B | T);
    try testing.expectEqual(@as(u32, 17), t.lineIdx());
    try testing.expectEqual(@as(u32, 31), t.intersectionMask());
    try testing.expect(t.winding());
    try testing.expect(t.intersectsTop());
    try testing.expect(t.intersectsBottom());
    try testing.expect(t.intersectsLeft());
    try testing.expect(t.intersectsRight());

    try testing.expectEqual(
        (@as(u64, 5) << 48) | (@as(u64, 3) << 32) | ((@as(u64, 17) << 5) | 31),
        t.toBits(),
    );
    try testing.expect(Tile.new(3, 5, 17, W | R | L | B | T).lessThan(Tile.new(3, 5, 17, W | R | L | B)) == false);
    try testing.expect(!Tile.new(3, 5, 17, W).eql(Tile.new(3, 5, 17, R)));
    try testing.expect(Tile.new(3, 5, 17, W).eql(Tile.new(3, 5, 17, W)));
    try testing.expect(Tile.new(3, 5, 17, 0).lessThan(Tile.new(3, 5, 18, 0)));
    try testing.expect(Tile.new(3, 5, 17, 0).lessThan(Tile.new(4, 5, 0, 0)));
    try testing.expect(Tile.new(3, 5, 17, 0).lessThan(Tile.new(3, 6, 0, 0)));

    try testing.expect(Tile.SENTINEL.isSentinel());
    try testing.expect(!Tile.new(0, 0, 0, 0).isSentinel());

    try testing.expect(Tile.newClamped(0xFFFF, 0xFFFF, 0, 0).x == std.math.maxInt(u16) / Tile.WIDTH);
    try testing.expect(Tile.newClamped(0xFFFF, 0xFFFF, 0, 0).y == std.math.maxInt(u16) / Tile.HEIGHT);

    const a = Tile.new(2, 3, 1, 0);
    const b = Tile.new(2, 3, 2, 0);
    try testing.expect(a.sameLoc(b));
    try testing.expect(a.sameRow(b));
    try testing.expect(a.prevLoc(Tile.new(3, 3, 2, 0)));
    try testing.expect(!a.prevLoc(Tile.new(4, 3, 2, 0)));
}

test "tile constants agree with flatten" {
    try testing.expectEqual(flatten.TILE_HEIGHT, Tile.HEIGHT);
    try testing.expectEqual(flatten.TILE_HEIGHT, 4);
    try testing.expectEqual(@as(u32, 1 << 27), MAX_LINES_PER_PATH);
}

test "tiles accessors require sorting and expose tiles" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.5, 1.0, 8.5, 1.0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);

    _ = try tiles.makeTilesAnalyticAa(a, &lines, VIEW_DIM, VIEW_DIM);
    try testing.expectEqual(@as(u32, 3), tiles.len());
    try testing.expect(!tiles.isEmpty());
    try testing.expect(!tiles.hasCulledTiles());
    tiles.sortTiles();
    // The analytic path emits mask 0 for a horizontal line inside the strip;
    // sorting orders the three tiles by (y, x).
    try testing.expectEqual(Tile.new(0, 0, 0, 0).toBits(), tiles.get(0).toBits());
    try testing.expectEqual(Tile.new(1, 0, 0, 0).toBits(), tiles.get(1).toBits());
    try testing.expectEqual(Tile.new(2, 0, 0, 0).toBits(), tiles.get(2).toBits());
    try testing.expectEqual(@as(usize, 3), tiles.items().len);
}

test "zero-sized viewport" {
    const a = testing.allocator;
    const lines = [_]Line{mkLine(1.0, 1.0, 2.0, 2.0)};
    var tiles = newTiles(a);
    defer tiles.deinit(a);

    const culled = try tiles.makeTilesAnalyticAa(a, &lines, 0, 10);
    try testing.expect(!culled);
    try testing.expectEqual(@as(usize, 0), tiles.tile_buf.items.len);
    try tiles.makeTilesMsaa(a, &lines, 10, 0);
    try testing.expectEqual(@as(usize, 0), tiles.tile_buf.items.len);
}
