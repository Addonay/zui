//! Port of vello_common strip.rs (Apache-2.0 OR MIT).
//!
//! Rendering strips: the sparse-strip analytic-AA coverage generation that
//! turns sorted tiles plus their source lines into strips and a column-major
//! alpha buffer (4 bytes per pixel column), and the strip-segment visitor used
//! by clipping and bounding-box code.
//!
//! This file also owns `stripBbox`, which upstream lives in `util.rs` but
//! needs `Strip`/`Tile` and therefore cannot live in this port's leaf
//! `common/util.zig` (see `docs/port-contracts.md`).
//!
//! The SIMD code is a direct transcription of the upstream `f32x4`/`f32x8`/
//! `u8x16` paths through `src/simd/root.zig`; every lane operation keeps the
//! upstream order. Upstream's `Level::baseline()` resolves to a non-FMA
//! backend on x86-64, whose `mul_add` is a separate multiply followed by an
//! add, so this file uses `simd.mulAddUnfused` (verified bit-identical
//! against a differential probe of upstream `strip::render`). The alpha block
//! is written column-major exactly as upstream: four `f32x4` accumulators
//! (one per pixel column, four pixel rows each) are combined into one
//! `f32x16`, converted by `util.f32ToU8` (x86 `cvttps2dq` truncation
//! semantics), optionally binarized by the aliasing threshold, and appended
//! as 16 bytes.
//!
//! Allocator contract: `render` appends to caller-owned `std.ArrayList`s and
//! takes the allocator explicitly. It never clears the buffers (matching
//! upstream). Each logical strip/alpha write is made atomic where practical
//! (`ensureUnusedCapacity` before the writes), and allocation failure
//! propagates as `error.OutOfMemory`; the output buffers then hold a valid
//! prefix of the strips generated so far.

const std = @import("std");
const simd = @import("../simd/root.zig");
const geometry = @import("geometry.zig");
const flatten = @import("flatten.zig");
const peniko = @import("../peniko/root.zig");
const tile_mod = @import("tile.zig");
const util = @import("util.zig");

const Fill = peniko.Fill;
const Line = flatten.Line;
const RectU16 = geometry.RectU16;
const Tile = tile_mod.Tile;
const Tiles = tile_mod.Tiles;
const CulledWindings = tile_mod.CulledWindings;

const F32x4 = simd.F32x4;
const U8x16 = simd.U8x16;

/// `Tile::WIDTH` as a `usize` for array lengths and loops.
const TILE_WIDTH: usize = Tile.WIDTH;
/// `Tile::HEIGHT` as a `usize` for the alpha column stride.
const TILE_HEIGHT: usize = Tile.HEIGHT;

/// One byte per pixel column row of a fully covered tile, appended by the
/// culled-background and captive-strip paths.
const SOLID_ALPHA: [TILE_WIDTH * TILE_HEIGHT]u8 = @splat(255);

/// The full tile space, used when `visitStripFillSegments` receives no
/// explicit bounds and by `stripBbox`. Matches upstream's
/// `RectU16::new(0, 0, u16::MAX.div_ceil(W), u16::MAX.div_ceil(H))`.
pub const FULL_TILE_BOUNDS: RectU16 = RectU16.new(
    0,
    0,
    std.math.maxInt(u16) / Tile.WIDTH + 1,
    std.math.maxInt(u16) / Tile.HEIGHT + 1,
);

/// A strip.
pub const Strip = struct {
    /// The x coordinate of the strip, in user coordinates.
    ///
    /// **IMPORTANT**: This is always a multiple of `Tile.WIDTH`.
    x: u16,
    /// The y coordinate of the strip, in user coordinates.
    ///
    /// **IMPORTANT**: This is always a multiple of `Tile.HEIGHT`.
    y: u16,
    /// Packed alpha index and fill gap flag.
    ///
    /// Bit layout (u32):
    /// - bit 31: `fill_gap` (see `fillGap()`).
    /// - bits 0..=30: `alpha_idx` (see `alphaIdx()`).
    packed_alpha_idx_fill_gap: u32,

    /// The bit mask for `fill_gap` packed into `packed_alpha_idx_fill_gap`.
    pub const FILL_GAP_MASK: u32 = 1 << 31;

    /// Creates a new strip.
    ///
    /// Upstream panics when `alpha_idx` uses the reserved `fill_gap` bit.
    pub fn new(x: u16, y: u16, alpha_idx: u32, fill_gap: bool) Strip {
        std.debug.assert(alpha_idx & FILL_GAP_MASK == 0);
        const gap: u32 = if (fill_gap) FILL_GAP_MASK else 0;
        return .{ .x = x, .y = y, .packed_alpha_idx_fill_gap = alpha_idx | gap };
    }

    /// Creates a sentinel strip.
    pub fn sentinel(y: u16, alpha_idx: u32) Strip {
        return Strip.new(std.math.maxInt(u16), y, alpha_idx, false);
    }

    /// Return whether the strip is a sentinel strip.
    pub fn isSentinel(self: Strip) bool {
        return self.x == std.math.maxInt(u16);
    }

    /// Return the y coordinate of the strip, in strip units.
    pub fn stripY(self: Strip) u16 {
        return self.y / Tile.HEIGHT;
    }

    /// Returns the horizontal pixel width of this strip.
    ///
    /// **IMPORTANT**: This assumes that `next` is actually the next adjacent
    /// strip to `self`, otherwise this method returns a garbage value.
    pub fn widthTo(self: Strip, next: Strip) u16 {
        const col = self.alphaIdx() / @as(u32, Tile.HEIGHT);
        const next_col = next.alphaIdx() / @as(u32, Tile.HEIGHT);
        return @truncate(next_col -| col);
    }

    /// Returns the alpha index.
    pub fn alphaIdx(self: Strip) u32 {
        return self.packed_alpha_idx_fill_gap & ~FILL_GAP_MASK;
    }

    /// Sets the alpha index.
    ///
    /// The largest value that can be stored in the alpha index is
    /// `u32::MAX << 1`, as the highest bit is reserved for `fill_gap`.
    /// Upstream panics when `alpha_idx` uses the reserved bit.
    pub fn setAlphaIdx(self: *Strip, alpha_idx: u32) void {
        std.debug.assert(alpha_idx & FILL_GAP_MASK == 0);
        const gap = self.packed_alpha_idx_fill_gap & FILL_GAP_MASK;
        self.packed_alpha_idx_fill_gap = alpha_idx | gap;
    }

    /// Returns whether the gap that lies between this strip and the previous
    /// strip in the same row should be filled.
    pub fn fillGap(self: Strip) bool {
        return (self.packed_alpha_idx_fill_gap & FILL_GAP_MASK) != 0;
    }

    /// Sets whether the gap that lies between this strip and the previous
    /// strip in the same row should be filled.
    pub fn setFillGap(self: *Strip, fill: bool) void {
        const gap: u32 = if (fill) FILL_GAP_MASK else 0;
        self.packed_alpha_idx_fill_gap =
            (self.packed_alpha_idx_fill_gap & ~FILL_GAP_MASK) | gap;
    }
};

/// A fill region with alpha coverage.
pub const StripAlphaFillSegment = struct {
    /// The fill region covered by this alpha segment.
    fill: StripFillSegment,
    /// The index into the alpha buffer of the segment.
    alpha_idx: u32,
};

/// A fill region without alpha coverage.
pub const StripFillSegment = struct {
    /// The inclusive start x coordinate in tile units.
    tile_x0: u16,
    /// The exclusive end x coordinate in tile units.
    tile_x1: u16,
    /// The y coordinate in tile units.
    tile_y: u16,

    /// The inclusive start x coordinate in pixels.
    pub fn x0(self: StripFillSegment) u16 {
        return self.tile_x0 * Tile.WIDTH;
    }

    /// The exclusive end x coordinate in pixels.
    pub fn x1(self: StripFillSegment) u16 {
        return self.tile_x1 * Tile.WIDTH;
    }

    /// The y coordinate in pixels.
    pub fn y(self: StripFillSegment) u16 {
        return self.tile_y * Tile.HEIGHT;
    }

    /// Return this segment's rectangle in tile coordinates.
    pub fn tileRect(self: StripFillSegment) RectU16 {
        return RectU16.new(self.tile_x0, self.tile_y, self.tile_x1, self.tile_y +| 1);
    }

    /// Return this segment's rectangle in pixel coordinates.
    pub fn pixelRect(self: StripFillSegment) RectU16 {
        return RectU16.new(
            self.tile_x0 *| Tile.WIDTH,
            self.tile_y *| Tile.HEIGHT,
            self.tile_x1 *| Tile.WIDTH,
            (self.tile_y +| 1) *| Tile.HEIGHT,
        );
    }

    /// Return this segment's pixel-space rectangle shifted by `shift`.
    pub fn shift(self: StripFillSegment, delta: [2]i32) RectU16 {
        return self.pixelRect().shift(delta);
    }
};

/// Iterate over all fill and alpha-fill regions formed by the sequence of
/// strips, within the tile-unit bounds indicated by `tile_bounds`.
///
/// A `null` `tile_bounds` means "no clipping" (the full tile space). The
/// `context` is duck-typed at comptime and must provide
/// `onAlphaSegment(ctx, StripAlphaFillSegment)` and
/// `onFillSegment(ctx, StripFillSegment)`; when the context type lives in
/// another file those methods must be declared `pub`. Pass `alpha_fill =
/// false` or `fill = false` to skip the corresponding callback entirely
/// (upstream distinguishes these with two closure arguments; the flags keep
/// the same behavior without function values).
pub fn visitStripFillSegments(
    strips: []const Strip,
    tile_bounds: ?RectU16,
    context: anytype,
    alpha_fill: bool,
    fill: bool,
) void {
    // Need at least two strips: one (or more) for the generated path, and the
    // sentinel strip.
    if (strips.len < 2) return;

    const bounds = tile_bounds orelse FULL_TILE_BOUNDS;
    if (bounds.isEmpty()) return;

    var i: usize = 0;
    while (i + 1 < strips.len) : (i += 1) {
        const strip = strips[i];
        const tile_y = strip.stripY();

        // Skip strips that are outside the viewport vertically.
        if (tile_y < bounds.y0) continue;
        if (tile_y >= bounds.y1) break;

        const next_strip = strips[i + 1];
        const strip_width = strip.widthTo(next_strip);

        if (std.debug.runtime_safety) {
            std.debug.assert(strip.x % Tile.WIDTH == 0);
            std.debug.assert(strip_width % Tile.WIDTH == 0);
        }

        const strip_tile_x0 = strip.x / Tile.WIDTH;
        const strip_tile_x1 = strip_tile_x0 +| (strip_width / Tile.WIDTH);
        // Clip strips that are outside the viewport horizontally.
        const tile_x0 = @max(strip_tile_x0, bounds.x0);
        const tile_x1 = @min(strip_tile_x1, bounds.x1);

        if (alpha_fill and tile_x0 < tile_x1) {
            context.onAlphaSegment(StripAlphaFillSegment{
                .fill = .{ .tile_x0 = tile_x0, .tile_x1 = tile_x1, .tile_y = tile_y },
                // Make sure to recalculate the index in case we had to clip.
                .alpha_idx = strip.alphaIdx() +
                    @as(u32, tile_x0 - strip_tile_x0) *
                        @as(u32, Tile.WIDTH) *
                        @as(u32, Tile.HEIGHT),
            });
        }

        if (next_strip.fillGap() and next_strip.y == strip.y) {
            // Similar procedure to above.
            const gap_x0 = @max(strip_tile_x1, bounds.x0);
            const gap_x1 = @min(next_strip.x / Tile.WIDTH, bounds.x1);

            if (fill and gap_x0 < gap_x1) {
                context.onFillSegment(StripFillSegment{
                    .tile_x0 = gap_x0,
                    .tile_x1 = gap_x1,
                    .tile_y = tile_y,
                });
            }
        }
    }
}

/// Render the tiles stored in `tiles` into the strip and alpha buffers.
///
/// Appends to `strip_buf` and `alpha_buf`; the buffers are not cleared.
/// `lines` is the flattened line buffer the tiles index into.
pub fn render(
    allocator: std.mem.Allocator,
    level: simd.Level,
    tiles: *const Tiles,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *std.ArrayList(u8),
    fill_rule: Fill,
    aliasing_threshold: ?u8,
    lines: []const Line,
) !void {
    // The port has a single portable backend, so the upstream `dispatch!`
    // collapses to a direct call.
    _ = level;
    try renderImpl(allocator, tiles, strip_buf, alpha_buf, fill_rule, aliasing_threshold, lines);
}

fn renderImpl(
    allocator: std.mem.Allocator,
    tiles: *const Tiles,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *std.ArrayList(u8),
    fill_rule: Fill,
    aliasing_threshold: ?u8,
    lines: []const Line,
) !void {
    const row_windings = tiles.windings.coarse.items;
    const has_culled_tiles = tiles.hasCulledTiles();
    // We need to make sure strips are tile-aligned.
    const viewport_width = checkedNextMultipleOfTiles(tiles.width);
    const strip_start = strip_buf.items.len;

    // If no tiles were culled and the tile buffer is empty, we can simply
    // exit. If tiles were culled, the tile buffer may be empty but there may
    // be winding produced by culled geometry left of the viewport that must be
    // checked for filling.
    if (!has_culled_tiles and tiles.isEmpty()) return;

    // The accumulated tile winding delta. A line that crosses the top edge of
    // a tile increments the delta if the line is directed upwards, and
    // decrements it if it goes downwards. Horizontal lines leave it
    // unchanged.
    var winding_delta: i32 = 0;

    // The previous tile visited.
    var prev_tile = if (has_culled_tiles and tiles.isEmpty()) Tile.SENTINEL else tiles.get(0);

    // The accumulated (fractional) winding of the tile-sized location we're
    // currently at. Note that multiple tiles can be at the same location.
    // Note that we are also implicitly assuming here that the tile height
    // exactly fits into a SIMD vector (i.e. 128 bits).
    const zero = simd.splat(F32x4, 0.0);
    var location_winding: [TILE_WIDTH]F32x4 = .{ zero, zero, zero, zero };
    // The accumulated (fractional) windings at this location's right edge.
    // When we move to the next location, this is splatted to that location's
    // starting winding.
    var accumulated_winding: F32x4 = zero;

    const left_viewport = prev_tile.x == 0;
    if (has_culled_tiles) {
        const row_max = @min(prev_tile.y, @as(u16, @intCast(row_windings.len)));
        try emitCulledBackground(
            allocator,
            0,
            row_max,
            viewport_width,
            strip_buf,
            alpha_buf,
            &tiles.windings,
            fill_rule,
        );
        if (tiles.isEmpty()) {
            try maybeEmitSentinelStrip(allocator, strip_buf, alpha_buf, strip_start);
            return;
        }
        const captive = try emitCaptiveStrip(
            allocator,
            tiles,
            fill_rule,
            prev_tile.y,
            left_viewport,
            strip_buf,
            alpha_buf,
        );
        winding_delta = captive.wd;
        accumulated_winding = captive.acc;
        location_winding = .{ accumulated_winding, accumulated_winding, accumulated_winding, accumulated_winding };
    }

    // The strip we're building.
    var strip = Strip.new(
        prev_tile.x * Tile.WIDTH,
        prev_tile.y * Tile.HEIGHT,
        alphaLen(alpha_buf),
        shouldFill(fill_rule, winding_delta) and !left_viewport,
    );

    const tile_items = tiles.items();
    const tile_width_f: f32 = @floatFromInt(Tile.WIDTH);
    const tile_height_f: f32 = @floatFromInt(Tile.HEIGHT);

    var tile_idx: usize = 0;
    while (true) : (tile_idx += 1) {
        const tile: Tile = if (tile_idx < tile_items.len) tile_items[tile_idx] else Tile.SENTINEL;
        const line = lines[tile.lineIdx()];
        const tile_left_x = @as(f32, @floatFromInt(tile.x)) * tile_width_f;
        const tile_top_y = @as(f32, @floatFromInt(tile.y)) * tile_height_f;
        const p0_x = line.p0.x - tile_left_x;
        const p0_y = line.p0.y - tile_top_y;
        const p1_x = line.p1.x - tile_left_x;
        const p1_y = line.p1.y - tile_top_y;

        // Push out the winding as an alpha mask when we move to the next
        // location (i.e., a tile without the same location).
        if (!prev_tile.sameLoc(tile)) {
            var u8_vals: U8x16 = undefined;
            switch (fill_rule) {
                .non_zero => {
                    const p1 = simd.splat(F32x4, 0.5);
                    const p2 = simd.splat(F32x4, 255.0);

                    for (0..TILE_WIDTH) |x| {
                        const area = location_winding[x];
                        const coverage = simd.abs(area);
                        const mulled = simd.mulAddUnfused(coverage, p2, p1);
                        // Note that we are not storing the location winding
                        // here but the actual alpha value as f32, so we reuse
                        // the variable as temporary storage. Also note that we
                        // need the `min` here because the winding can be > 1
                        // and thus the calculated alpha value needs to be
                        // clamped to 255.
                        location_winding[x] = simd.min(mulled, p2);
                    }
                },
                .even_odd => {
                    const p1 = simd.splat(F32x4, 0.5);
                    const p2 = simd.splat(F32x4, -2.0);
                    const p3 = simd.splat(F32x4, 255.0);

                    for (0..TILE_WIDTH) |x| {
                        const area = location_winding[x];
                        const im1 = @floor(simd.mulAddUnfused(area, p1, p1));
                        const coverage = simd.abs(simd.mulAddUnfused(p2, im1, area));
                        const mulled = simd.mulAddUnfused(p3, coverage, p1);
                        location_winding[x] = simd.min(mulled, p3);
                    }
                },
            }

            const lo = simd.combineF32x4(location_winding[0], location_winding[1]);
            const hi = simd.combineF32x4(location_winding[2], location_winding[3]);

            u8_vals = util.f32ToU8(simd.combineF32x8(lo, hi));

            if (aliasing_threshold) |threshold| {
                const mask = simd.simdGe(u8_vals, simd.splat(U8x16, threshold));
                u8_vals = simd.select(
                    U8x16,
                    mask,
                    simd.splat(U8x16, 255),
                    simd.splat(U8x16, 0),
                );
            }

            try alpha_buf.ensureUnusedCapacity(allocator, TILE_WIDTH * TILE_HEIGHT);
            const bytes: [TILE_WIDTH * TILE_HEIGHT]u8 = @bitCast(u8_vals);
            alpha_buf.appendSliceAssumeCapacity(&bytes);

            for (0..TILE_WIDTH) |x| {
                location_winding[x] = accumulated_winding;
            }
        }

        // Push out the strip if we're moving to a next strip.
        if (!prev_tile.sameLoc(tile) and !prev_tile.prevLoc(tile)) {
            if (std.debug.runtime_safety) {
                const expected = (@as(u32, prev_tile.x) + 1) * @as(u32, Tile.WIDTH) - @as(u32, strip.x);
                const written = (alpha_buf.items.len - strip.alphaIdx()) / TILE_HEIGHT;
                std.debug.assert(expected == @as(u32, @truncate(written)));
            }
            try strip_buf.append(allocator, strip);

            const is_sentinel = tile_idx == tile_items.len;
            const next_left_viewport = tile.x == 0;
            if (!prev_tile.sameRow(tile)) {
                // Emit a final strip in the row if there is non-zero winding
                // for the sparse fill.
                if (winding_delta != 0) {
                    try strip_buf.append(allocator, Strip.new(
                        viewport_width,
                        prev_tile.y * Tile.HEIGHT,
                        alphaLen(alpha_buf),
                        shouldFill(fill_rule, winding_delta),
                    ));
                }

                // Logic identical to the start (see above): fill any vertical
                // gaps (empty rows) between the previous and current tile
                // using the row windings.
                if (has_culled_tiles and !is_sentinel) {
                    try emitCulledBackground(
                        allocator,
                        prev_tile.y + 1,
                        tile.y,
                        viewport_width,
                        strip_buf,
                        alpha_buf,
                        &tiles.windings,
                        fill_rule,
                    );

                    const captive = try emitCaptiveStrip(
                        allocator,
                        tiles,
                        fill_rule,
                        tile.y,
                        next_left_viewport,
                        strip_buf,
                        alpha_buf,
                    );
                    winding_delta = captive.wd;
                    accumulated_winding = captive.acc;
                } else {
                    winding_delta = 0;
                    accumulated_winding = simd.splat(F32x4, 0.0);
                }

                for (0..TILE_WIDTH) |x| {
                    location_winding[x] = accumulated_winding;
                }
            } else {
                // Note: this fill is mathematically not necessary. It provides
                // a way to reduce accumulation of float rounding errors.
                accumulated_winding = simd.splat(F32x4, @floatFromInt(winding_delta));
            }

            if (is_sentinel) break;

            strip = Strip.new(
                tile.x * Tile.WIDTH,
                tile.y * Tile.HEIGHT,
                alphaLen(alpha_buf),
                shouldFill(fill_rule, winding_delta) and !next_left_viewport,
            );
        }
        prev_tile = tile;

        // TODO upstream: horizontal geometry has no impact on winding. This
        // branch will be removed when horizontal geometry is culled at the
        // tile-generation stage.
        if (p0_y == p1_y) continue;

        // Lines moving upwards (in a y-down coordinate system) add to winding;
        // lines moving downwards subtract from winding.
        const sign = signumF32(p0_y - p1_y);
        const sign_i: i32 = if (std.math.isNan(sign)) 0 else if (sign > 0.0) 1 else -1;

        const line_top_y, const line_top_x, const line_bottom_y, const line_bottom_x = if (p0_y < p1_y)
            .{ p0_y, p0_x, p1_y, p1_x }
        else
            .{ p1_y, p1_x, p0_y, p0_x };

        const y_slope = (line_bottom_y - line_top_y) / (line_bottom_x - line_top_x);
        const x_slope = 1.0 / y_slope;

        winding_delta += sign_i * @as(i32, @intFromBool(tile.winding()));

        const line_top_y_v = simd.splat(F32x4, line_top_y);
        const line_bottom_y_v = simd.splat(F32x4, line_bottom_y);

        // See the explanation of this term on the `line_px_left_yx` and
        // `line_px_right_yx` variables below.
        const line_px_base_yx = simd.mulAddUnfused(
            line_top_y_v,
            simd.splat(F32x4, -x_slope),
            simd.splat(F32x4, line_top_x),
        );

        const px_top_y: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };
        const px_bottom_y = px_top_y + simd.splat(F32x4, 1.0);

        const ymin = simd.max(line_top_y_v, px_top_y);
        const ymax = simd.min(line_bottom_y_v, px_bottom_y);

        var acc: F32x4 = simd.splat(F32x4, 0.0);

        for (0..TILE_WIDTH) |x_idx| {
            const x_idx_s = simd.splat(F32x4, @floatFromInt(x_idx));
            const px_left_x = x_idx_s;
            const px_right_x = x_idx_s + simd.splat(F32x4, 1.0);

            // The y-coordinate of the intersections between the line and the
            // pixel's left and right edges respectively. `maxPrecise` is
            // required to pick `ymin` when the first operand is NaN (a
            // vertical line collinear with a pixel edge); see upstream.
            const line_px_left_y = simd.min(
                simd.maxPrecise(
                    simd.mulAddUnfused(
                        px_left_x - simd.splat(F32x4, line_top_x),
                        simd.splat(F32x4, y_slope),
                        line_top_y_v,
                    ),
                    ymin,
                ),
                ymax,
            );
            const line_px_right_y = simd.min(
                simd.maxPrecise(
                    simd.mulAddUnfused(
                        px_right_x - simd.splat(F32x4, line_top_x),
                        simd.splat(F32x4, y_slope),
                        line_top_y_v,
                    ),
                    ymin,
                ),
                ymax,
            );

            // For each pixel we calculate the x-coordinates of the left- and
            // rightmost points on the line segment within that pixel, based
            // on the y-offsets of those two points from the top of the line.
            // Note `x_slope` is always finite, as horizontal geometry is
            // elided.
            const line_px_left_yx = simd.mulAddUnfused(
                line_px_left_y,
                simd.splat(F32x4, x_slope),
                line_px_base_yx,
            );
            const line_px_right_yx = simd.mulAddUnfused(
                line_px_right_y,
                simd.splat(F32x4, x_slope),
                line_px_base_yx,
            );
            const h = simd.abs(line_px_right_y - line_px_left_y);

            // The trapezoidal area enclosed between the line and the right
            // edge of the pixel square:
            // 0.5 * h * (2. * px_right_x - line_px_right_yx - line_px_left_yx).
            const area = h * simd.mulAddUnfused(
                line_px_right_yx + line_px_left_yx,
                simd.splat(F32x4, -0.5),
                px_right_x,
            );
            location_winding[x_idx] += simd.mulAddUnfused(area, simd.splat(F32x4, sign), acc);
            acc = simd.mulAddUnfused(h, simd.splat(F32x4, sign), acc);
        }

        accumulated_winding += acc;
    }

    if (has_culled_tiles) {
        try emitCulledBackground(
            allocator,
            @min(prev_tile.y + 1, @as(u16, @intCast(row_windings.len))),
            @intCast(row_windings.len),
            viewport_width,
            strip_buf,
            alpha_buf,
            &tiles.windings,
            fill_rule,
        );
    }

    try maybeEmitSentinelStrip(allocator, strip_buf, alpha_buf, strip_start);
}

/// Emit the final sentinel strip, if we produced at least one strip.
fn maybeEmitSentinelStrip(
    allocator: std.mem.Allocator,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *const std.ArrayList(u8),
    strip_start: usize,
) !void {
    if (strip_buf.items.len <= strip_start) return;
    const last_y = strip_buf.items[strip_buf.items.len - 1].y;
    try strip_buf.append(allocator, Strip.sentinel(last_y, alphaLen(alpha_buf)));
}

const CaptiveStrip = struct {
    wd: i32,
    acc: F32x4,
};

/// Handle "captive strips". When a row has tiles, but the first tile is not at
/// the left edge of the viewport (x != 0), we must emit a solid strip from x=0
/// to that tile if the coarse winding dictates a fill.
fn emitCaptiveStrip(
    allocator: std.mem.Allocator,
    tiles: *const Tiles,
    fill_rule: Fill,
    y: u16,
    is_left_viewport: bool,
    strips: *std.ArrayList(Strip),
    alphas: *std.ArrayList(u8),
) !CaptiveStrip {
    const coarse_wd: i32 = tiles.windings.coarse.items[y];

    if (shouldFill(fill_rule, coarse_wd) and !is_left_viewport) {
        // Reserve both outputs first so a failure leaves neither half-written.
        try strips.ensureUnusedCapacity(allocator, 1);
        try alphas.ensureUnusedCapacity(allocator, TILE_WIDTH * TILE_HEIGHT);
        strips.appendAssumeCapacity(Strip.new(0, y * Tile.HEIGHT, alphaLen(alphas), false));
        alphas.appendSliceAssumeCapacity(&SOLID_ALPHA);
    }

    var acc = simd.splat(F32x4, @floatFromInt(coarse_wd));
    if (is_left_viewport) {
        acc += simd.fromSlice(F32x4, &tiles.windings.partial.items[y]);
    }

    return .{ .wd = coarse_wd, .acc = acc };
}

/// When early culling is active, geometry fully to the left of the viewport
/// creates no tiles. However, if that geometry has a non-zero winding (e.g. a
/// large shape surrounding the viewport), then we must output strips for those
/// fills.
///
/// We reconstruct this "background" fill using `row_windings` (the winding at
/// x=0) to emit solid strips for:
///   1. All rows vertically above the first visible tile.
///   2. 'Captive' rows between two tile-containing rows.
///   3. All rows vertically below the last visible tile.
fn emitCulledBackground(
    allocator: std.mem.Allocator,
    start: u16,
    end: u16,
    viewport_width: u16,
    strips: *std.ArrayList(Strip),
    alphas: *std.ArrayList(u8),
    windings: *const CulledWindings,
    fill_rule: Fill,
) !void {
    // First pass: count the rows that will actually be filled so both buffers
    // can be reserved up front and this emission stays atomic.
    var count_ctx = CountRowsCtx{ .windings = windings, .fill_rule = fill_rule };
    windings.forActiveRowsInRange(start, end, &count_ctx, CountRowsCtx.countRow);
    if (count_ctx.count == 0) return;

    try strips.ensureUnusedCapacity(allocator, count_ctx.count * 2);
    try alphas.ensureUnusedCapacity(allocator, count_ctx.count * TILE_WIDTH * TILE_HEIGHT);

    var emit_ctx = EmitRowsCtx{
        .strips = strips,
        .alphas = alphas,
        .viewport_width = viewport_width,
        .windings = windings,
        .fill_rule = fill_rule,
    };
    windings.forActiveRowsInRange(start, end, &emit_ctx, EmitRowsCtx.emitRow);
}

const CountRowsCtx = struct {
    windings: *const CulledWindings,
    fill_rule: Fill,
    count: usize = 0,

    fn countRow(self: *CountRowsCtx, row: usize) void {
        if (shouldFill(self.fill_rule, @as(i32, self.windings.coarse.items[row]))) {
            self.count += 1;
        }
    }
};

const EmitRowsCtx = struct {
    strips: *std.ArrayList(Strip),
    alphas: *std.ArrayList(u8),
    viewport_width: u16,
    windings: *const CulledWindings,
    fill_rule: Fill,

    fn emitRow(self: *EmitRowsCtx, row: usize) void {
        if (!shouldFill(self.fill_rule, @as(i32, self.windings.coarse.items[row]))) return;

        const y_pos: u16 = @intCast(row * TILE_HEIGHT);
        self.strips.appendAssumeCapacity(Strip.new(0, y_pos, alphaLen(self.alphas), false));
        // TODO upstream: would be nice to get rid of this, but the current
        // clipping code only allows zero-width strips as a row terminator, not
        // in-between.
        self.alphas.appendSliceAssumeCapacity(&SOLID_ALPHA);
        self.strips.appendAssumeCapacity(Strip.new(
            self.viewport_width,
            y_pos,
            alphaLen(self.alphas),
            true,
        ));
    }
};

/// Calculate the bounding box of the strips (upstream `util::strip_bbox`).
///
/// Returns `null` when no strip contributes coverage.
pub fn stripBbox(strips: []const Strip) ?RectU16 {
    // Fill and alpha fill segments internally store their coordinates in tile
    // units; to avoid multiplications in every invocation of the callback we
    // calculate the bbox in tile units first and then convert back to pixel
    // units.
    var tile_bbox = RectU16.INVERTED;

    var ctx = BboxContext{ .bbox = &tile_bbox };
    visitStripFillSegments(strips, FULL_TILE_BOUNDS, &ctx, true, true);

    // Convert to pixel units.
    if (tile_bbox.isEmpty()) return null;
    return RectU16.new(
        tileToPixels(tile_bbox.x0, Tile.WIDTH),
        tileToPixels(tile_bbox.y0, Tile.HEIGHT),
        tileToPixels(tile_bbox.x1, Tile.WIDTH),
        tileToPixels(tile_bbox.y1, Tile.HEIGHT),
    );
}

const BboxContext = struct {
    bbox: *RectU16,

    fn onAlphaSegment(self: *BboxContext, segment: StripAlphaFillSegment) void {
        self.bbox.unionWith(segment.fill.tileRect());
    }

    fn onFillSegment(self: *BboxContext, segment: StripFillSegment) void {
        self.bbox.unionWith(segment.tileRect());
    }
};

/// Upstream `RectU16::checked_mul(...).unwrap()`: panics on overflow.
fn tileToPixels(value: u16, scale: u16) u16 {
    return std.math.mul(u16, value, scale) catch @panic("strip bbox overflows u16");
}

/// Upstream `should_fill`: `NonZero` fills any non-zero winding, `EvenOdd`
/// fills odd windings.
fn shouldFill(fill_rule: Fill, winding: i32) bool {
    return switch (fill_rule) {
        .non_zero => winding != 0,
        .even_odd => @rem(winding, 2) != 0,
    };
}

/// Upstream `f32::signum`: NaN for NaN, otherwise ±1.0 according to the sign
/// bit (including for zero).
fn signumF32(x: f32) f32 {
    if (std.math.isNan(x)) return x;
    return if (std.math.signbit(x)) -1.0 else 1.0;
}

/// `width.checked_next_multiple_of(Tile::WIDTH).unwrap_or(u16::MAX)`.
fn checkedNextMultipleOfTiles(width: u16) u16 {
    const w: u32 = width;
    const rem = w % @as(u32, Tile.WIDTH);
    const next = w + (if (rem == 0) 0 else @as(u32, Tile.WIDTH) - rem);
    return if (next > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(next);
}

/// `alpha_buf.len() as u32` (truncating, like the Rust `as` cast).
fn alphaLen(alpha_buf: *const std.ArrayList(u8)) u32 {
    return @truncate(alpha_buf.items.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectStripEqual(expected: Strip, actual: Strip) !void {
    try testing.expectEqual(expected.x, actual.x);
    try testing.expectEqual(expected.y, actual.y);
    try testing.expectEqual(expected.alphaIdx(), actual.alphaIdx());
    try testing.expectEqual(expected.fillGap(), actual.fillGap());
}

const WINDING_BIT: u32 = 1 << 4;

/// Minimal collector for `visitStripFillSegments` tests.
const Segments = struct {
    alpha: [8]StripAlphaFillSegment = undefined,
    alpha_len: usize = 0,
    fill: [8]StripFillSegment = undefined,
    fill_len: usize = 0,

    fn onAlphaSegment(self: *Segments, segment: StripAlphaFillSegment) void {
        std.debug.assert(self.alpha_len < self.alpha.len);
        self.alpha[self.alpha_len] = segment;
        self.alpha_len += 1;
    }

    fn onFillSegment(self: *Segments, segment: StripFillSegment) void {
        std.debug.assert(self.fill_len < self.fill.len);
        self.fill[self.fill_len] = segment;
        self.fill_len += 1;
    }
};

const SOLID_ALPHA_32: [32]u8 = @splat(255);

test "strip accessors and segments" {
    var strip = Strip.new(8, 4, 64, false);
    try testing.expectEqual(@as(u16, 8), strip.x);
    try testing.expectEqual(@as(u16, 4), strip.y);
    try testing.expectEqual(@as(u32, 64), strip.alphaIdx());
    try testing.expect(!strip.fillGap());
    try testing.expect(!strip.isSentinel());
    try testing.expectEqual(@as(u16, 1), strip.stripY());

    strip.setFillGap(true);
    try testing.expect(strip.fillGap());
    try testing.expectEqual(@as(u32, 64), strip.alphaIdx());
    strip.setAlphaIdx(32);
    try testing.expectEqual(@as(u32, 32), strip.alphaIdx());
    try testing.expect(strip.fillGap());

    const next = Strip.new(8, 4, 96, false);
    try testing.expectEqual(@as(u16, 16), strip.widthTo(next));

    const sentinel = Strip.sentinel(4, 96);
    try testing.expect(sentinel.isSentinel());
    try testing.expectEqual(@as(u16, 1), sentinel.stripY());

    const segment = StripFillSegment{ .tile_x0 = 3, .tile_x1 = 5, .tile_y = 2 };
    try testing.expectEqual(@as(u16, 12), segment.x0());
    try testing.expectEqual(@as(u16, 20), segment.x1());
    try testing.expectEqual(@as(u16, 8), segment.y());
    try testing.expectEqual(RectU16.new(3, 2, 5, 3), segment.tileRect());
    try testing.expectEqual(RectU16.new(12, 8, 20, 12), segment.pixelRect());
    try testing.expectEqual(RectU16.new(10, 6, 18, 10), segment.shift(.{ -2, -2 }));
}

test "visitStripFillSegments clips alpha segments and fill gaps" {
    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(32, 0, 64, true),
        Strip.sentinel(0, 64),
    };

    var seg = Segments{};
    visitStripFillSegments(&strips, RectU16.new(0, 0, 6, 1), &seg, true, true);

    try testing.expectEqual(@as(usize, 1), seg.alpha_len);
    try testing.expectEqual(@as(u16, 0), seg.alpha[0].fill.tile_x0);
    try testing.expectEqual(@as(u16, 4), seg.alpha[0].fill.tile_x1);
    try testing.expectEqual(@as(u16, 0), seg.alpha[0].fill.tile_y);
    try testing.expectEqual(@as(u32, 0), seg.alpha[0].alpha_idx);

    try testing.expectEqual(@as(usize, 1), seg.fill_len);
    try testing.expectEqual(@as(u16, 4), seg.fill[0].tile_x0);
    try testing.expectEqual(@as(u16, 6), seg.fill[0].tile_x1);
    try testing.expectEqual(@as(u16, 0), seg.fill[0].tile_y);
}

test "visitStripFillSegments recalculates alpha index after left clipping" {
    const strips = [_]Strip{
        Strip.new(8, 4, 64, false),
        Strip.sentinel(4, 128),
    };

    var seg = Segments{};
    visitStripFillSegments(&strips, RectU16.new(3, 1, 8, 2), &seg, true, true);

    try testing.expectEqual(@as(usize, 1), seg.alpha_len);
    try testing.expectEqual(StripFillSegment{ .tile_x0 = 3, .tile_x1 = 6, .tile_y = 1 }, seg.alpha[0].fill);
    try testing.expectEqual(@as(u32, 80), seg.alpha[0].alpha_idx);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);
}

test "visitStripFillSegments with null bounds does not clip" {
    const strips = [_]Strip{
        Strip.new(8, 4, 64, false),
        Strip.sentinel(4, 128),
    };

    var seg = Segments{};
    visitStripFillSegments(&strips, null, &seg, true, true);

    try testing.expectEqual(@as(usize, 1), seg.alpha_len);
    try testing.expectEqual(StripFillSegment{ .tile_x0 = 2, .tile_x1 = 6, .tile_y = 1 }, seg.alpha[0].fill);
    try testing.expectEqual(@as(u32, 64), seg.alpha[0].alpha_idx);
}

test "visitStripFillSegments applies vertical bounds and segment flags" {
    const strips = [_]Strip{
        Strip.new(8, 4, 64, false),
        Strip.sentinel(4, 128),
    };

    // `tile_bounds.y1` is exclusive for tile_y == 1, so the pair is skipped.
    var seg = Segments{};
    visitStripFillSegments(&strips, RectU16.new(0, 0, 4, 1), &seg, true, true);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);

    // `tile_bounds.y0` above the strip skips it, then the following pairs are
    // below the upper bound and stop the scan.
    seg = Segments{};
    visitStripFillSegments(&strips, RectU16.new(0, 2, 4, 4), &seg, true, true);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);

    // Empty bounds produce nothing.
    seg = Segments{};
    visitStripFillSegments(&strips, RectU16.new(0, 0, 0, 0), &seg, true, true);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);

    // Flags select which callbacks run.
    seg = Segments{};
    visitStripFillSegments(&strips, null, &seg, false, false);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);

    seg = Segments{};
    visitStripFillSegments(&strips, null, &seg, true, false);
    try testing.expectEqual(@as(usize, 1), seg.alpha_len);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);

    seg = Segments{};
    visitStripFillSegments(&strips, null, &seg, false, true);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);

    // A scenario with a fill gap: the flags select the callback that runs.
    const gap_strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(32, 0, 64, true),
        Strip.sentinel(0, 64),
    };
    seg = Segments{};
    visitStripFillSegments(&gap_strips, null, &seg, true, false);
    try testing.expectEqual(@as(usize, 1), seg.alpha_len);
    try testing.expectEqual(@as(usize, 0), seg.fill_len);

    seg = Segments{};
    visitStripFillSegments(&gap_strips, null, &seg, false, true);
    try testing.expectEqual(@as(usize, 0), seg.alpha_len);
    try testing.expectEqual(@as(usize, 1), seg.fill_len);
    try testing.expectEqual(StripFillSegment{ .tile_x0 = 4, .tile_x1 = 8, .tile_y = 0 }, seg.fill[0]);
}

test "checked next multiple of tile width" {
    try testing.expectEqual(@as(u16, 0), checkedNextMultipleOfTiles(0));
    try testing.expectEqual(@as(u16, 4), checkedNextMultipleOfTiles(4));
    try testing.expectEqual(@as(u16, 8), checkedNextMultipleOfTiles(5));
    try testing.expectEqual(@as(u16, 65532), checkedNextMultipleOfTiles(65532));
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), checkedNextMultipleOfTiles(65533));
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), checkedNextMultipleOfTiles(65535));
}

test "render nonzero single tile emits exact strips and alpha" {
    const allocator = testing.allocator;

    var tiles = Tiles.init(allocator, .baseline, 4, 4);
    defer tiles.deinit(allocator);
    try tiles.reset(allocator, 4, 4);
    try tiles.tile_buf.append(allocator, Tile.new(0, 0, 0, WINDING_BIT));
    tiles.sortTiles();

    const lines = [_]Line{
        Line.new(flatten.Point.new(2.0, -2.0), flatten.Point.new(2.0, 6.0)),
    };

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, null, &lines);

    try testing.expectEqual(@as(usize, 3), strips.items.len);
    try expectStripEqual(Strip.new(0, 0, 0, false), strips.items[0]);
    try expectStripEqual(Strip.new(4, 0, 16, true), strips.items[1]);
    try expectStripEqual(Strip.sentinel(0, 16), strips.items[2]);

    try testing.expectEqualSlices(u8, &.{
        0,   0,   0,   0,
        0,   0,   0,   0,
        255, 255, 255, 255,
        255, 255, 255, 255,
    }, alphas.items);
}

test "render even odd and aliasing threshold" {
    const allocator = testing.allocator;

    var tiles = Tiles.init(allocator, .baseline, 4, 4);
    defer tiles.deinit(allocator);
    try tiles.reset(allocator, 4, 4);
    try tiles.tile_buf.append(allocator, Tile.new(0, 0, 0, WINDING_BIT));
    tiles.sortTiles();

    const lines = [_]Line{
        Line.new(flatten.Point.new(2.0, -2.0), flatten.Point.new(2.0, 6.0)),
    };

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    // Even-odd: the two covered columns have winding -1 (odd) and the two
    // uncovered columns have winding 0.
    try render(allocator, .baseline, &tiles, &strips, &alphas, .even_odd, null, &lines);
    try testing.expectEqualSlices(u8, &.{
        0,   0,   0,   0,
        0,   0,   0,   0,
        255, 255, 255, 255,
        255, 255, 255, 255,
    }, alphas.items);

    strips.clearRetainingCapacity();
    alphas.clearRetainingCapacity();

    // With the aliasing threshold, every generated value is binarized.
    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, 200, &lines);
    try testing.expectEqualSlices(u8, &.{
        0,   0,   0,   0,
        0,   0,   0,   0,
        255, 255, 255, 255,
        255, 255, 255, 255,
    }, alphas.items);
}

test "aliasing threshold binarizes fractional coverage" {
    const allocator = testing.allocator;

    var tiles = Tiles.init(allocator, .baseline, 4, 4);
    defer tiles.deinit(allocator);
    const lines = [_]Line{
        Line.new(flatten.Point.new(0.0, 0.0), flatten.Point.new(4.0, 4.0)),
    };
    const culled = try tiles.makeTilesAnalyticAa(allocator, &lines, 4, 4);
    try testing.expect(!culled);
    try testing.expect(!tiles.isEmpty());
    tiles.sortTiles();

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    // A threshold of 100 keeps pixels with fractional coverage; 200 drops
    // them. Both renders must be fully binarized, and the lower threshold
    // must keep at least one pixel the higher one drops.
    var low_count: usize = 0;
    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, 100, &lines);
    const alpha_len = alphas.items.len;
    for (alphas.items) |a| {
        try testing.expect(a == 0 or a == 255);
        low_count += a / 255;
    }

    strips.clearRetainingCapacity();
    alphas.clearRetainingCapacity();

    var high_count: usize = 0;
    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, 200, &lines);
    try testing.expectEqual(alpha_len, alphas.items.len);
    for (alphas.items) |a| {
        try testing.expect(a == 0 or a == 255);
        high_count += a / 255;
    }

    try testing.expect(low_count > high_count);
}

test "render culled background rows" {
    const allocator = testing.allocator;

    var tiles = Tiles.init(allocator, .baseline, 4, 8);
    defer tiles.deinit(allocator);

    // A vertical line entirely to the left of the viewport creates no tiles
    // but leaves winding in both tile rows.
    const lines = [_]Line{
        Line.new(flatten.Point.new(-2.0, -4.0), flatten.Point.new(-2.0, 12.0)),
    };
    const culled = try tiles.makeTilesAnalyticAa(allocator, &lines, 4, 8);
    try testing.expect(culled);
    try testing.expect(tiles.isEmpty());
    tiles.sortTiles();

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, null, &lines);

    try testing.expectEqual(@as(usize, 5), strips.items.len);
    try expectStripEqual(Strip.new(0, 0, 0, false), strips.items[0]);
    try expectStripEqual(Strip.new(4, 0, 16, true), strips.items[1]);
    try expectStripEqual(Strip.new(0, 4, 16, false), strips.items[2]);
    try expectStripEqual(Strip.new(4, 4, 32, true), strips.items[3]);
    try expectStripEqual(Strip.sentinel(4, 32), strips.items[4]);
    try testing.expectEqualSlices(u8, &SOLID_ALPHA_32, alphas.items);
}

test "render culled captive strip fills the left gap" {
    const allocator = testing.allocator;

    var tiles = Tiles.init(allocator, .baseline, 16, 4);
    defer tiles.deinit(allocator);
    try tiles.reset(allocator, 16, 4);

    // Simulate culled geometry with winding 1 and a single visible tile at
    // x = 2 whose source line crosses it at x = 8.5.
    tiles.windings.culled = true;
    tiles.windings.coarse.items[0] = 1;
    tiles.windings.markRowActive(0);
    try tiles.tile_buf.append(allocator, Tile.new(2, 0, 0, 0));
    tiles.sortTiles();

    const lines = [_]Line{
        Line.new(flatten.Point.new(8.5, -1.0), flatten.Point.new(8.5, 5.0)),
    };

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, &tiles, &strips, &alphas, .non_zero, null, &lines);

    try testing.expectEqual(@as(usize, 4), strips.items.len);
    try expectStripEqual(Strip.new(0, 0, 0, false), strips.items[0]);
    try expectStripEqual(Strip.new(8, 0, 16, true), strips.items[1]);
    try expectStripEqual(Strip.new(16, 0, 32, true), strips.items[2]);
    try expectStripEqual(Strip.sentinel(0, 32), strips.items[3]);

    try testing.expectEqualSlices(u8, &.{
        255, 255, 255, 255,
        255, 255, 255, 255,
        255, 255, 255, 255,
        255, 255, 255, 255,
        128, 128, 128, 128,
        0,   0,   0,   0,
        0,   0,   0,   0,
        0,   0,   0,   0,
    }, alphas.items);
}

test "strip bbox empty" {
    const strips = [_]Strip{Strip.sentinel(0, 0)};
    try testing.expectEqual(@as(?RectU16, null), stripBbox(&strips));
}

test "strip bbox single strip" {
    const strips = [_]Strip{
        Strip.new(8, 4, 0, false),
        Strip.sentinel(4, 16),
    };
    try testing.expectEqual(@as(?RectU16, RectU16.new(8, 4, 12, 8)), stripBbox(&strips));
}

test "strip bbox with fill gap" {
    const strips = [_]Strip{
        Strip.new(4, 0, 0, false),
        Strip.new(20, 0, 16, true),
        Strip.sentinel(0, 32),
    };
    try testing.expectEqual(@as(?RectU16, RectU16.new(4, 0, 24, 4)), stripBbox(&strips));
}

test "strip bbox with row end fill gap" {
    const strips = [_]Strip{
        Strip.new(4, 0, 0, false),
        Strip.new(32, 0, 16, true),
        Strip.sentinel(0, 16),
    };
    try testing.expectEqual(@as(?RectU16, RectU16.new(4, 0, 32, 4)), stripBbox(&strips));
}

test "strip bbox with multiple rows" {
    const strips = [_]Strip{
        Strip.new(12, 0, 0, false),
        Strip.new(4, 8, 16, false),
        Strip.sentinel(8, 32),
    };
    try testing.expectEqual(@as(?RectU16, RectU16.new(4, 0, 16, 12)), stripBbox(&strips));
}
