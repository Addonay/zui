//! Port of vello_common strip_generator.rs (Apache-2.0 OR MIT).
//!
//! `StripGenerator` owns the scratch state for one generation pass: the
//! flattened line buffer, the curve/stroke flattening contexts, the tile
//! container, and a temporary strip storage used when a clip path has to be
//! intersected with the generated strips.
//!
//! Cycle-split note: upstream `strip_generator.rs` and `clip.rs` import each
//! other. In this port `StripStorage`, `GenerationMode`, and `PathDataRef`
//! live in `common/strip_storage.zig`, the intersection algorithm lives in
//! `common/intersect.zig`, and this file imports both (see
//! `docs/cpu-pipeline.md`).
//!
//! Interface adaptation: upstream's `width`/`height` fields are renamed
//! `viewport_width`/`viewport_height` because Zig cannot have a field and a
//! method with the same name; the `width()`/`height()` accessors keep the
//! upstream API. Upstream's `render_fn` closure becomes a duck-typed render
//! context (`RenderCtx.render(strips, alphas)`), the same pattern used by
//! `visitStripFillSegments`.
//!
//! Allocator contract: every method that can grow a buffer takes an explicit
//! allocator and propagates `error.OutOfMemory`; `init`/`deinit` pair for the
//! owned scratch storage. On failure the generator and target storage remain
//! in a defined state (the storage holds a valid prefix, never a dangling
//! strip/alpha pair).

const std = @import("std");
const simd = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const geometry = @import("geometry.zig");
const flatten = @import("flatten.zig");
const intersect = @import("intersect.zig");
const rect_mod = @import("rect.zig");
const strip_mod = @import("strip.zig");
const strip_storage = @import("strip_storage.zig");
const tile_mod = @import("tile.zig");

const Fill = peniko.Fill;
const PathDataRef = strip_storage.PathDataRef;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;
const StripStorage = strip_storage.StripStorage;
const Tiles = tile_mod.Tiles;

/// An object for easily generating strips for a filled/stroked path.
pub const StripGenerator = struct {
    /// The runtime-selected SIMD level (single portable backend).
    level: simd.Level,
    /// The flattened line buffer for the current path.
    line_buf: std.ArrayList(flatten.Line),
    /// Scratch context reused by `flatten.fill`/`flatten.stroke`.
    flatten_ctx: flatten.FlattenCtx,
    /// Scratch context reused by `flatten.stroke`.
    stroke_ctx: kurbo.StrokeCtx,
    /// Temporary storage for strips that still need to be intersected with a
    /// clip path.
    temp_storage: StripStorage,
    /// The tile buffer for the current path.
    tiles: Tiles,
    /// Viewport width (upstream field `width`; see the module docs).
    viewport_width: u16,
    /// Viewport height (upstream field `height`; see the module docs).
    viewport_height: u16,

    /// Create a new strip generator.
    pub fn init(
        allocator: std.mem.Allocator,
        new_width: u16,
        new_height: u16,
        level: simd.Level,
    ) StripGenerator {
        return .{
            .level = level,
            .line_buf = .empty,
            .flatten_ctx = flatten.FlattenCtx.init(),
            .stroke_ctx = kurbo.StrokeCtx.init(),
            .temp_storage = StripStorage.initDefault(),
            .tiles = Tiles.init(allocator, level, new_width, new_height),
            .viewport_width = new_width,
            .viewport_height = new_height,
        };
    }

    /// Release the owned scratch storage.
    pub fn deinit(self: *StripGenerator, allocator: std.mem.Allocator) void {
        self.line_buf.deinit(allocator);
        self.flatten_ctx.deinit(allocator);
        self.stroke_ctx.deinit(allocator);
        self.temp_storage.deinit(allocator);
        self.tiles.deinit(allocator);
        self.* = undefined;
    }

    /// Get this strip generator's viewport width.
    pub inline fn width(self: *const StripGenerator) u16 {
        return self.viewport_width;
    }

    /// Get this strip generator's viewport height.
    pub inline fn height(self: *const StripGenerator) u16 {
        return self.viewport_height;
    }

    /// Generate the strips for a filled path.
    pub fn generateFilledPath(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
        storage: *StripStorage,
        clip_path: ?PathDataRef,
    ) !void {
        const cull_bbox = if (clip_path) |clip|
            clip.bbox
        else
            RectU16.new(0, 0, self.viewport_width, self.viewport_height);
        try flatten.fill(
            allocator,
            self.level,
            path,
            transform,
            &self.line_buf,
            &self.flatten_ctx,
            cull_bbox,
        );

        try self.generateWithClip(
            allocator,
            aliasing_threshold,
            storage,
            fill_rule,
            clip_path,
        );
    }

    /// Generate the strips for a stroked path.
    pub fn generateStrokedPath(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        stroke: *const kurbo.Stroke,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
        storage: *StripStorage,
        clip_path: ?PathDataRef,
    ) !void {
        const cull_bbox = if (clip_path) |clip|
            clip.bbox
        else
            RectU16.new(0, 0, self.viewport_width, self.viewport_height);
        try flatten.stroke(
            allocator,
            self.level,
            path,
            stroke,
            transform,
            &self.line_buf,
            &self.flatten_ctx,
            &self.stroke_ctx,
            cull_bbox,
        );
        try self.generateWithClip(
            allocator,
            aliasing_threshold,
            storage,
            Fill.non_zero,
            clip_path,
        );
    }

    fn generateWithClip(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        aliasing_threshold: ?u8,
        storage: *StripStorage,
        fill_rule: Fill,
        clip_path: ?PathDataRef,
    ) !void {
        // The returned culled flag is also recorded in `tiles.windings`.
        _ = try self.tiles.makeTilesAnalyticAa(
            allocator,
            self.line_buf.items,
            self.viewport_width,
            self.viewport_height,
        );

        self.tiles.sortTiles();

        const render_ctx = PathRenderCtx{
            .allocator = allocator,
            .level = self.level,
            .tiles = &self.tiles,
            .lines = self.line_buf.items,
            .fill_rule = fill_rule,
            .aliasing_threshold = aliasing_threshold,
        };
        try renderWithClip(
            allocator,
            self.level,
            &self.temp_storage,
            storage,
            clip_path,
            render_ctx,
        );
    }

    /// Generate strips directly for a pixel-aligned rectangle.
    ///
    /// This bypasses the full path processing pipeline (flatten -> tiles ->
    /// strips) by directly creating strip coverage data for the rectangle.
    pub fn generateFilledRectFast(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
        storage: *StripStorage,
        clip_path: ?PathDataRef,
    ) !void {
        const viewport = kurbo.Rect.new(
            0.0,
            0.0,
            @floatFromInt(self.viewport_width),
            @floatFromInt(self.viewport_height),
        );
        const clip_bbox = if (clip_path) |clip| blk: {
            // Clip bbox is always guaranteed to be within viewport bounds, so
            // no need to intersect again.
            break :blk kurbo.Rect.new(
                @floatFromInt(clip.bbox.x0),
                @floatFromInt(clip.bbox.y0),
                @floatFromInt(clip.bbox.x1),
                @floatFromInt(clip.bbox.y1),
            );
        } else viewport;
        const clamped = rect.abs().intersect(clip_bbox);

        const render_ctx = RectRenderCtx{
            .allocator = allocator,
            .level = self.level,
            .rect = clamped,
        };
        try renderWithClip(
            allocator,
            self.level,
            &self.temp_storage,
            storage,
            clip_path,
            render_ctx,
        );
    }

    /// Reset the strip generator for a viewport size, resizing only when
    /// needed.
    pub fn reset(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        new_width: u16,
        new_height: u16,
    ) !void {
        self.viewport_width = new_width;
        self.viewport_height = new_height;
        self.line_buf.clearRetainingCapacity();
        try self.tiles.reset(allocator, new_width, new_height);
        self.temp_storage.clear();
    }
};

/// Render context for the path-based pipeline (upstream `generate_with_clip`'s
/// closure over `strip::render`).
const PathRenderCtx = struct {
    allocator: std.mem.Allocator,
    level: simd.Level,
    tiles: *const Tiles,
    lines: []const flatten.Line,
    fill_rule: Fill,
    aliasing_threshold: ?u8,

    fn render(
        self: *const PathRenderCtx,
        strips: *std.ArrayList(Strip),
        alphas: *std.ArrayList(u8),
    ) !void {
        try strip_mod.render(
            self.allocator,
            self.level,
            self.tiles,
            strips,
            alphas,
            self.fill_rule,
            self.aliasing_threshold,
            self.lines,
        );
    }
};

/// Render context for `rect::render` (upstream `generate_filled_rect_fast`'s
/// closure).
const RectRenderCtx = struct {
    allocator: std.mem.Allocator,
    level: simd.Level,
    rect: kurbo.Rect,

    fn render(
        self: *const RectRenderCtx,
        strips: *std.ArrayList(Strip),
        alphas: *std.ArrayList(u8),
    ) !void {
        try rect_mod.render(self.allocator, self.level, self.rect, strips, alphas);
    }
};

/// Render strips via `render_ctx` with optional clip intersection.
///
/// When `clip_path` is `Some`, strips are rendered into `temp_storage` first,
/// then intersected with the clip mask into `strip_storage`. Otherwise strips
/// are rendered directly into `strip_storage`.
fn renderWithClip(
    allocator: std.mem.Allocator,
    level: simd.Level,
    temp_storage: *StripStorage,
    storage: *StripStorage,
    clip_path: ?PathDataRef,
    render_ctx: anytype,
) !void {
    switch (storage.generation_mode) {
        .replace => storage.strips.clearRetainingCapacity(),
        .append => {},
        .replace_after => |n| {
            // Rust `Vec::truncate` is a no-op when `n >= len`.
            if (n < storage.strips.items.len) {
                storage.strips.shrinkRetainingCapacity(n);
            }
        },
    }

    if (clip_path) |clip| {
        temp_storage.clear();

        try render_ctx.render(&temp_storage.strips, &temp_storage.alphas);

        const path_data = PathDataRef{
            .strips = temp_storage.strips.items,
            .alphas = temp_storage.alphas.items,
            .bbox = RectU16.new(0, 0, std.math.maxInt(u16), std.math.maxInt(u16)),
        };
        try intersect.intersect(allocator, level, clip, path_data, storage);
    } else {
        try render_ctx.render(&storage.strips, &storage.alphas);
    }
}

// ---------------------------------------------------------------------------
// Tests (ported from upstream `strip_generator.rs` `#[cfg(test)]`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "reset" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 100, 100, .baseline);
    defer generator.deinit(allocator);
    var storage = StripStorage.initDefault();
    defer storage.deinit(allocator);

    var path = try kurbo.Rect.new(0.0, 0.0, 100.0, 100.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try generator.generateFilledPath(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
        &storage,
        null,
    );

    try testing.expect(generator.line_buf.items.len != 0);
    try testing.expect(!storage.isEmpty());

    try generator.reset(allocator, 100, 100);
    storage.clear();

    try testing.expect(generator.line_buf.items.len == 0);
    try testing.expect(storage.isEmpty());
}

/// Assert that `generateFilledRectFast` produces the same strips as the
/// path-based pipeline for the given rectangle.
fn assertRectFastEqPath(
    allocator: std.mem.Allocator,
    rect: kurbo.Rect,
    test_name: []const u8,
) !void {
    // Upstream includes `test_name` in its assertion messages.
    _ = test_name;

    var generator = StripGenerator.init(allocator, 100, 100, .baseline);
    defer generator.deinit(allocator);

    var storage_path = StripStorage.initDefault();
    defer storage_path.deinit(allocator);
    var storage_rect = StripStorage.initDefault();
    defer storage_rect.deinit(allocator);

    var path = try rect.toPath(0.1, allocator);
    defer path.deinit(allocator);

    try generator.generateFilledPath(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
        &storage_path,
        null,
    );
    try generator.reset(allocator, 100, 100);

    try generator.generateFilledRectFast(allocator, rect, &storage_rect, null);

    try testing.expectEqualSlices(Strip, storage_path.strips.items, storage_rect.strips.items);
    try testing.expectEqualSlices(u8, storage_path.alphas.items, storage_rect.alphas.items);
}

test "rect small single tile" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(1.0, 1.0, 3.0, 3.0), "small_single_tile");
}

test "rect spanning multiple tiles horizontally" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(2.0, 1.0, 14.0, 3.0), "spanning_horizontal");
}

test "rect spanning multiple tiles vertically" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(1.0, 2.0, 3.0, 14.0), "spanning_vertical");
}

test "rect spanning multiple tiles both directions" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(2.0, 2.0, 18.0, 18.0), "spanning_both");
}

test "rect tile aligned" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(0.0, 0.0, 8.0, 8.0), "tile_aligned");
}

test "rect one pixel wide" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(5.0, 2.0, 6.0, 12.0), "one_pixel_wide");
}

test "rect one pixel tall" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(2.0, 5.0, 12.0, 6.0), "one_pixel_tall");
}

test "rect fractional within single tile" {
    const cases = [_][4]f64{
        .{ 0.25, 0.75, 2.5, 3.5 },
        .{ 1.2, 1.3, 1.8, 1.7 },
        .{ 0.1, 0.1, 3.9, 3.9 },
        .{ 2.5, 2.5, 2.6, 2.6 },
        .{ 0.01, 0.99, 3.99, 3.01 },
    };
    for (cases) |case| {
        try assertRectFastEqPath(
            testing.allocator,
            kurbo.Rect.new(case[0], case[1], case[2], case[3]),
            "fractional",
        );
    }
}

test "rect fractional multi tile" {
    const cases = [_][4]f64{
        .{ 1.5, 2.3, 10.7, 8.9 },
        .{ 0.5, 0.5, 8.5, 8.5 },
        .{ 2.3, 5.1, 15.7, 5.9 },
        .{ 5.1, 2.3, 5.9, 15.7 },
        .{ 0.25, 0.25, 12.75, 12.75 },
        .{ 1.0 / 3.0, 2.0 / 3.0, 10.33, 8.67 },
        .{ 1.99, 2.01, 9.01, 7.99 },
        .{ 3.9, 3.9, 8.1, 8.1 },
        .{ 3.2, 6.3, 14.8, 6.7 },
        .{ 6.3, 3.2, 6.7, 14.8 },
        .{ 0.1, 0.9, 49.9, 49.1 },
        .{ 4.0, 2.7, 12.0, 9.3 },
        .{ 2.7, 4.0, 9.3, 12.0 },
        .{ 1.5, 1.2, 10.5, 2.8 },
        .{ 1.5, 2.5, 14.5, 18.5 },
        .{ 0.7, 0.3, 30.2, 25.8 },
        .{ 7.9, 7.9, 8.1, 8.1 },
        .{ 3.5, 0.5, 4.5, 0.9 },
        .{ 0.01, 0.01, 99.99, 99.99 },
        .{ 10.0, 10.0, 10.1, 10.1 },
    };
    for (cases) |case| {
        try assertRectFastEqPath(
            testing.allocator,
            kurbo.Rect.new(case[0], case[1], case[2], case[3]),
            "fractional",
        );
    }
}

test "rect fractional exhaustive" {
    const allocator = testing.allocator;
    var xi: u32 = 0;
    while (xi < 100) : (xi += 1) {
        var yi: u32 = 0;
        while (yi < 100) : (yi += 1) {
            const dx = @as(f64, @floatFromInt(xi)) * 0.01;
            const dy = @as(f64, @floatFromInt(yi)) * 0.01;
            const rect = kurbo.Rect.new(dx, dy, 50.0 + dx, 50.0 + dy);
            try assertRectFastEqPath(allocator, rect, "exhaustive");
        }
    }
}

test "rect inverted both axes" {
    try assertRectFastEqPath(testing.allocator, kurbo.Rect.new(18.0, 18.0, 2.0, 2.0), "inverted_both_axes");
}

test "stroked path generates strips" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 64, 64, .baseline);
    defer generator.deinit(allocator);
    var storage = StripStorage.initDefault();
    defer storage.deinit(allocator);

    const path = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(4.0, 32.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(60.0, 32.0)),
    };
    const stroke = kurbo.Stroke.new(4.0);

    try generator.generateStrokedPath(
        allocator,
        &path,
        &stroke,
        kurbo.Affine.IDENTITY,
        null,
        &storage,
        null,
    );

    try testing.expect(generator.line_buf.items.len != 0);
    try testing.expect(!storage.isEmpty());
    const bbox = strip_mod.stripBbox(storage.strips.items) orelse return error.TestUnexpectedResult;
    // The stroke of a 4px-wide horizontal line centered at y=32 spans
    // y in [30, 34], so the tile-aligned bbox is [0, 28, 64, 36].
    try testing.expectEqual(RectU16.new(0, 28, 64, 36), bbox);
}

test "generate with clip path culls to clip bbox" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 100, 100, .baseline);
    defer generator.deinit(allocator);

    var clip_storage = StripStorage.initDefault();
    defer clip_storage.deinit(allocator);
    var target = StripStorage.initDefault();
    defer target.deinit(allocator);

    var clip_path = try kurbo.Rect.new(0.0, 0.0, 16.0, 16.0).toPath(0.1, allocator);
    defer clip_path.deinit(allocator);
    var path = try kurbo.Rect.new(0.0, 0.0, 32.0, 32.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try generator.generateFilledPath(
        allocator,
        clip_path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
        &clip_storage,
        null,
    );
    const clip_ref = PathDataRef{
        .strips = clip_storage.strips.items,
        .alphas = clip_storage.alphas.items,
        .bbox = strip_mod.stripBbox(clip_storage.strips.items) orelse return error.TestUnexpectedResult,
    };

    try generator.generateFilledPath(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
        &target,
        clip_ref,
    );

    // Intersecting an opaque 32x32 rect with an opaque 16x16 clip yields
    // exactly the clip path's strip data (the printed strips confirm the
    // right-edge marker strip of the clip path is preserved).
    try testing.expectEqualSlices(Strip, clip_storage.strips.items, target.strips.items);
    try testing.expectEqualSlices(u8, clip_storage.alphas.items, target.alphas.items);

    const bbox = strip_mod.stripBbox(target.strips.items) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(clip_ref.bbox, bbox);
}

test "generation modes replace append and replace_after" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 100, 100, .baseline);
    defer generator.deinit(allocator);
    var storage = StripStorage.initDefault();
    defer storage.deinit(allocator);

    var path = try kurbo.Rect.new(0.0, 0.0, 32.0, 32.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    const run = struct {
        fn call(
            alloc: std.mem.Allocator,
            gen: *StripGenerator,
            p: []const kurbo.PathEl,
            target: *StripStorage,
        ) !void {
            try gen.generateFilledPath(
                alloc,
                p,
                .non_zero,
                kurbo.Affine.IDENTITY,
                null,
                target,
                null,
            );
        }
    }.call;

    // `replace` clears strips at the start of the pass; the alpha buffer is
    // untouched (upstream `render_with_clip`), so repeated passes accumulate
    // alphas while the strip list stays the same size.
    storage.setGenerationMode(.replace);
    try run(allocator, &generator, path.elementsSlice(), &storage);
    const pass_strips = storage.strips.items.len;
    const pass_alphas = storage.alphas.items.len;
    try testing.expect(pass_strips > 0);
    try testing.expect(pass_alphas > 0);
    try testing.expectEqual(@as(u32, 0), storage.strips.items[0].alphaIdx());

    // Second `replace` pass: strips are regenerated, alpha indices continue
    // after the existing alpha bytes.
    try run(allocator, &generator, path.elementsSlice(), &storage);
    try testing.expectEqual(pass_strips, storage.strips.items.len);
    try testing.expectEqual(pass_alphas * 2, storage.alphas.items.len);
    try testing.expectEqual(@as(u32, @intCast(pass_alphas)), storage.strips.items[0].alphaIdx());
    const second_pass_first = storage.strips.items[0];

    // `append` keeps the previous pass and appends a full new one.
    storage.setGenerationMode(.append);
    try run(allocator, &generator, path.elementsSlice(), &storage);
    try testing.expectEqual(pass_strips * 2, storage.strips.items.len);
    try testing.expectEqual(pass_alphas * 3, storage.alphas.items.len);
    try testing.expectEqual(second_pass_first.alphaIdx(), storage.strips.items[0].alphaIdx());

    // `replace_after(n)` keeps the first `n` strips and appends the new pass.
    storage.setGenerationMode(.{ .replace_after = 1 });
    try run(allocator, &generator, path.elementsSlice(), &storage);
    try testing.expectEqual(1 + pass_strips, storage.strips.items.len);
    try testing.expectEqual(pass_alphas * 4, storage.alphas.items.len);
    try testing.expectEqual(second_pass_first.x, storage.strips.items[0].x);
    try testing.expectEqual(second_pass_first.y, storage.strips.items[0].y);
    try testing.expectEqual(second_pass_first.alphaIdx(), storage.strips.items[0].alphaIdx());
    try testing.expectEqual(second_pass_first.fillGap(), storage.strips.items[0].fillGap());
    // The newly appended pass starts after the alphas accumulated so far.
    try testing.expectEqual(@as(u32, @intCast(pass_alphas * 3)), storage.strips.items[1].alphaIdx());
}

test "generate filled path allocation failure safety" {
    const Runs = struct {
        fn run(allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void {
            var generator = StripGenerator.init(allocator, 64, 64, .baseline);
            defer generator.deinit(allocator);
            var storage = StripStorage.initDefault();
            defer storage.deinit(allocator);

            try generator.generateFilledPath(
                allocator,
                path,
                .non_zero,
                kurbo.Affine.IDENTITY,
                null,
                &storage,
                null,
            );
            try testing.expect(!storage.isEmpty());
        }
    };

    const rect_els = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(2.0, 3.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(30.0, 3.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(30.0, 27.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(2.0, 27.0)),
        kurbo.PathEl.closePath(),
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runs.run, .{&rect_els});
}
