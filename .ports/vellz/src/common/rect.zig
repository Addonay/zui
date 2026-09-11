//! Port of vello_common rect.rs (Apache-2.0 OR MIT).
//!
//! Fast pixel-aligned rectangle rendering directly into strips. Bypasses the
//! full path pipeline (flatten -> tiles -> strips) by directly creating strip
//! coverage data for the rectangle; the caller clamps the rect to the
//! viewport (see upstream `StripGenerator::generate_filled_rect_fast`).
//!
//! Strip layout strategy (upstream):
//! - **Edge rows** (top/bottom of the rect): the rect boundary crosses partway
//!   through the tile vertically, so individual pixels need per-cell alpha.
//!   A single wide strip spans all tile columns, with alpha = x_alpha *
//!   y_alpha.
//! - **Interior rows**: every pixel has full vertical coverage, so only the
//!   left and right partial-column edges need alpha. A left edge strip is
//!   emitted always, and, when the rect spans more than one tile column, a
//!   right edge strip with `fill_gap = true` so the renderer fills solid
//!   0xFF between them. The x-alpha masks are y-independent, so they are
//!   precomputed once.
//!
//! The coverage math is transcribed exactly: `(cov * 255.0 + 0.5) as u8` is a
//! saturating float-to-int cast (`std.math.lossyCast`), `_mm_cvttps_epi32`
//! style truncation is not involved here because the product fits the
//! documented 0..1 range. `u8x16` values are built with `simd.fromSlice`
//! exactly like upstream `u8x16::from_slice`.

const std = @import("std");
const simd = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const tile_mod = @import("tile.zig");
const strip = @import("strip.zig");

const Rect = kurbo.Rect;
const Strip = strip.Strip;
const Tile = tile_mod.Tile;
const U8x16 = simd.U8x16;

/// The tile width in pixels as a `usize` for array lengths.
const TILE_WIDTH: usize = Tile.WIDTH;
/// The tile height in pixels as a `usize` for array lengths.
const TILE_HEIGHT: usize = Tile.HEIGHT;

/// Render a pixel-aligned rectangle directly into strips.
///
/// The rect bounds should already be clamped to the viewport. Appends to
/// `strip_buf` and `alpha_buf`; the buffers are not cleared.
pub fn render(
    allocator: std.mem.Allocator,
    level: simd.Level,
    rect: Rect,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *std.ArrayList(u8),
) !void {
    // The port has a single portable backend, so the upstream `dispatch!`
    // collapses to a direct call.
    _ = level;
    try renderImpl(allocator, rect, strip_buf, alpha_buf);
}

fn renderImpl(
    allocator: std.mem.Allocator,
    rect: Rect,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *std.ArrayList(u8),
) !void {
    if (rect.isZeroArea()) return;

    const rect_x0: f32 = @floatCast(rect.x0);
    const rect_y0: f32 = @floatCast(rect.y0);
    const rect_x1: f32 = @floatCast(rect.x1);
    const rect_y1: f32 = @floatCast(rect.y1);

    // Integer pixel bounds. Upstream uses saturating `as u16` casts: negative
    // values (and NaN) become 0, large values clamp to `u16::MAX`.
    const px_x0: u16 = std.math.lossyCast(u16, @floor(rect_x0));
    const px_y0: u16 = std.math.lossyCast(u16, @floor(rect_y0));
    const px_y1: u16 = std.math.lossyCast(u16, @ceil(rect_y1));

    const left_tile_x: u16 = (px_x0 / Tile.WIDTH) * Tile.WIDTH;
    // Inclusive, so don't use `ceil` here but just `rect_x1` directly.
    const right_tile_x: u16 = (std.math.lossyCast(u16, rect_x1) / Tile.WIDTH) * Tile.WIDTH;

    const y0: u32 = @as(u32, (px_y0 / Tile.HEIGHT) * Tile.HEIGHT);
    const y1: u32 = (@as(u32, px_y1) + @as(u32, Tile.HEIGHT - 1)) /
        @as(u32, Tile.HEIGHT) * @as(u32, Tile.HEIGHT);
    // Include one tile past the right edge so the right-edge tile column is
    // covered by the edge-row wide-strip loop.
    const x_end: u32 = @as(u32, right_tile_x) + @as(u32, Tile.WIDTH);

    if (x_end <= @as(u32, left_tile_x) or y1 <= y0) return;

    const tile_start_y = y0 / @as(u32, Tile.HEIGHT);
    const tile_end_y = y1 / @as(u32, Tile.HEIGHT);

    // A right strip is only needed when the rect spans more than one tile
    // column.
    const needs_right_strip = right_tile_x > left_tile_x;

    const left_x_cov = coverage(TILE_WIDTH, left_tile_x, rect_x0, rect_x1);
    const right_x_cov = coverage(TILE_WIDTH, right_tile_x, rect_x0, rect_x1);
    const left_x_mask = alphaMaskFromXCoverage(&left_x_cov);
    const right_x_mask = alphaMaskFromXCoverage(&right_x_cov);

    var tile_y = tile_start_y;
    while (tile_y < tile_end_y) : (tile_y += 1) {
        const strip_y: u16 = @intCast(tile_y * @as(u32, Tile.HEIGHT));
        const strip_y_f: f32 = @floatFromInt(strip_y);
        const strip_y_end_f: f32 = strip_y_f + @as(f32, @floatFromInt(Tile.HEIGHT));

        // A row is an "edge" if the rect's top or bottom boundary falls
        // *inside* it (i.e. partial vertical coverage).
        const is_top_edge = strip_y_f < rect_y0 and rect_y0 < strip_y_end_f;
        const is_bottom_edge = strip_y_f < rect_y1 and rect_y1 < strip_y_end_f;

        if (is_top_edge or is_bottom_edge) {
            const alpha_start: u32 = @truncate(alpha_buf.items.len);
            // Number of 4-pixel-wide alpha blocks this row writes.
            const blocks = (x_end - @as(u32, left_tile_x)) / @as(u32, Tile.WIDTH);
            // Reserve both outputs up front: a failure here leaves neither
            // buffer half-written.
            try strip_buf.ensureUnusedCapacity(allocator, 1);
            try alpha_buf.ensureUnusedCapacity(allocator, @as(usize, blocks) * TILE_WIDTH * TILE_HEIGHT);

            const y_cov = coverage(TILE_HEIGHT, strip_y, rect_y0, rect_y1);
            var col: u32 = left_tile_x;
            while (col + @as(u32, Tile.WIDTH) <= x_end) : (col += @as(u32, Tile.WIDTH)) {
                // TODO upstream: we could optimize this so this is only
                // computed for the left-most and right-most tile of the edge;
                // all intermediate tiles have full horizontal coverage.
                const x_cov = coverage(TILE_WIDTH, @intCast(col), rect_x0, rect_x1);
                const combined = combinedTileAlpha(&x_cov, &y_cov);
                const bytes: [TILE_WIDTH * TILE_HEIGHT]u8 = @bitCast(combined);
                alpha_buf.appendSliceAssumeCapacity(&bytes);
            }

            strip_buf.appendAssumeCapacity(Strip.new(left_tile_x, strip_y, alpha_start, false));
        } else {
            const alpha_start: u32 = @truncate(alpha_buf.items.len);
            const blocks: usize = if (needs_right_strip) 2 else 1;
            try strip_buf.ensureUnusedCapacity(allocator, blocks);
            try alpha_buf.ensureUnusedCapacity(allocator, blocks * TILE_WIDTH * TILE_HEIGHT);

            const left_bytes: [TILE_WIDTH * TILE_HEIGHT]u8 = @bitCast(left_x_mask);
            alpha_buf.appendSliceAssumeCapacity(&left_bytes);
            strip_buf.appendAssumeCapacity(Strip.new(left_tile_x, strip_y, alpha_start, false));

            if (needs_right_strip) {
                // `fill_gap = true` tells the renderer to fill solid 0xFF
                // between the previous strip's end and this strip's start.
                const right_alpha_start: u32 = @truncate(alpha_buf.items.len);
                const right_bytes: [TILE_WIDTH * TILE_HEIGHT]u8 = @bitCast(right_x_mask);
                alpha_buf.appendSliceAssumeCapacity(&right_bytes);
                strip_buf.appendAssumeCapacity(Strip.new(right_tile_x, strip_y, right_alpha_start, true));
            }
        }
    }

    // Sentinel strip: marks the end of the strip list for this shape.
    const last_strip_y: u16 = @intCast((tile_end_y - 1) * @as(u32, Tile.HEIGHT));
    try strip_buf.append(allocator, Strip.sentinel(last_strip_y, @truncate(alpha_buf.items.len)));
}

/// Compute fractional pixel coverage for `N` consecutive pixels starting at
/// `start`.
fn coverage(comptime N: usize, start: u16, rect_lo: f32, rect_hi: f32) [N]f32 {
    var cov: [N]f32 = undefined;
    for (0..N) |i| {
        const px: f32 = @floatFromInt(@as(usize, start) + i);
        cov[i] = std.math.clamp(@min(rect_hi, px + 1.0) - @max(rect_lo, px), 0.0, 1.0);
    }
    return cov;
}

/// Build an alpha mask for the 4x4 tile from the given horizontal coverages,
/// splatting them across the other dimension.
fn alphaMaskFromXCoverage(cov: *const [TILE_WIDTH]f32) U8x16 {
    var buf: [TILE_WIDTH * TILE_HEIGHT]u8 = undefined;

    for (0..TILE_WIDTH) |col| {
        const alpha: u8 = std.math.lossyCast(u8, cov[col] * 255.0 + 0.5);
        const base = col * TILE_HEIGHT;
        buf[base..][0..TILE_HEIGHT].* = @splat(alpha);
    }

    return simd.fromSlice(U8x16, &buf);
}

/// Compute the alphas for a single 4x4 tile, taking horizontal as well as
/// vertical coverage of the rectangle into account.
fn combinedTileAlpha(
    x_cov: *const [TILE_WIDTH]f32,
    y_cov: *const [TILE_HEIGHT]f32,
) U8x16 {
    var buf: [TILE_WIDTH * TILE_HEIGHT]u8 = undefined;
    for (0..TILE_WIDTH) |col| {
        const xc = x_cov[col];
        for (0..TILE_HEIGHT) |row| {
            const yc = y_cov[row];
            buf[col * TILE_HEIGHT + row] = std.math.lossyCast(u8, xc * yc * 255.0 + 0.5);
        }
    }

    return simd.fromSlice(U8x16, &buf);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "render edge row at u16 right edge" {
    const allocator = testing.allocator;

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    const rect = Rect.new(
        @floatFromInt(std.math.maxInt(u16) - 3),
        0.5,
        @floatFromInt(std.math.maxInt(u16)),
        3.5,
    );

    try render(allocator, .baseline, rect, &strips, &alphas);

    try testing.expectEqual(@as(usize, 2), strips.items.len);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16) - 3), strips.items[0].x);
    try testing.expectEqual(@as(u32, 0), strips.items[0].alphaIdx());
    try testing.expectEqual(TILE_WIDTH * TILE_HEIGHT, alphas.items.len);
    try testing.expect(strips.items[1].isSentinel());
}

test "render edge row at u16 bottom edge" {
    const allocator = testing.allocator;

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    const rect = Rect.new(
        0.5,
        @floatFromInt(std.math.maxInt(u16) - 3),
        3.5,
        @floatFromInt(std.math.maxInt(u16)),
    );

    try render(allocator, .baseline, rect, &strips, &alphas);

    try testing.expectEqual(@as(usize, 2), strips.items.len);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16) - 3), strips.items[0].y);
    try testing.expectEqual(@as(u32, 0), strips.items[0].alphaIdx());
    try testing.expectEqual(TILE_WIDTH * TILE_HEIGHT, alphas.items.len);
    try testing.expect(strips.items[1].isSentinel());
}

test "render fractional edge tile alpha" {
    const allocator = testing.allocator;

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, Rect.new(0.5, 0.5, 1.5, 1.5), &strips, &alphas);

    try testing.expectEqual(@as(usize, 2), strips.items.len);
    try testing.expectEqual(Strip.new(0, 0, 0, false), strips.items[0]);
    try testing.expect(strips.items[1].isSentinel());
    try testing.expectEqual(@as(u16, 0), strips.items[1].y);
    try testing.expectEqual(@as(u32, 16), strips.items[1].alphaIdx());

    try testing.expectEqualSlices(u8, &.{
        64, 64, 0, 0,
        64, 64, 0, 0,
        0,  0,  0, 0,
        0,  0,  0, 0,
    }, alphas.items);
}

test "render interior rows with left and right edge strips" {
    const allocator = testing.allocator;

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, Rect.new(0.5, 0.5, 9.5, 8.5), &strips, &alphas);

    try testing.expectEqual(@as(usize, 5), strips.items.len);
    try testing.expectEqual(Strip.new(0, 0, 0, false), strips.items[0]);
    try testing.expectEqual(Strip.new(0, 4, 48, false), strips.items[1]);
    try testing.expectEqual(Strip.new(8, 4, 64, true), strips.items[2]);
    try testing.expectEqual(Strip.new(0, 8, 80, false), strips.items[3]);
    try testing.expect(strips.items[4].isSentinel());
    try testing.expectEqual(@as(u16, 8), strips.items[4].y);
    try testing.expectEqual(@as(u32, 128), strips.items[4].alphaIdx());

    try testing.expectEqualSlices(u8, &.{
        // Top edge row, tile column 0.
        64,  128, 128, 128,
        128, 255, 255, 255,
        128, 255, 255, 255,
        128, 255, 255, 255,
        // Top edge row, tile column 4.
        128, 255, 255, 255,
        128, 255, 255, 255,
        128, 255, 255, 255,
        128, 255, 255, 255,
        // Top edge row, tile column 8.
        128, 255, 255, 255,
        64,  128, 128, 128,
        0,   0,   0,   0,
        0,   0,   0,   0,
        // Interior row: left x mask.
        128, 128, 128, 128,
        255, 255, 255, 255,
        255, 255, 255, 255,
        255, 255, 255, 255,
        // Interior row: right x mask (gap filled by `fill_gap`).
        255, 255, 255, 255,
        128, 128, 128, 128,
        0,   0,   0,   0,
        0,   0,   0,   0,
        // Bottom edge row, tile column 0.
        64,  0,   0,   0,
        128, 0,   0,   0,
        128, 0,   0,   0,
        128, 0,   0,   0,
        // Bottom edge row, tile column 4.
        128, 0,   0,   0,
        128, 0,   0,   0,
        128, 0,   0,   0,
        128, 0,   0,   0,
        // Bottom edge row, tile column 8.
        128, 0,   0,   0,
        64,  0,   0,   0,
        0,   0,   0,   0,
        0,   0,   0,   0,
    }, alphas.items);
}

test "render degenerate rects produce no output" {
    const allocator = testing.allocator;

    var strips = std.ArrayList(Strip).empty;
    defer strips.deinit(allocator);
    var alphas = std.ArrayList(u8).empty;
    defer alphas.deinit(allocator);

    try render(allocator, .baseline, Rect.new(2.0, 2.0, 2.0, 5.0), &strips, &alphas);
    try render(allocator, .baseline, Rect.new(2.0, 2.0, 5.0, 2.0), &strips, &alphas);
    try testing.expectEqual(@as(usize, 0), strips.items.len);
    try testing.expectEqual(@as(usize, 0), alphas.items.len);
}
