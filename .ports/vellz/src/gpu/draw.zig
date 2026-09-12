//! Port of `vello_gpu/src/draw.rs` (Apache-2.0 OR MIT).
//!
//! Builds the `GpuStrip` instances for one scheduled draw pass from recorded
//! paths/rectangles, routing fully opaque strips to the depth-writing opaque
//! pass and everything else to the alpha-blended pass. External-texture runs
//! are tracked exactly as upstream even though the solid-paint milestone never
//! assigns a slot; encoded paints land with the gradient/image milestone.
//!
//! Allocator contract: `Draw`, `OpaqueDraw`, and `DrawBuffers` own unmanaged
//! `ArrayList`s and take an allocator on every mutating call and on `deinit`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const common = @import("../common/root.zig");
const paint_mod = @import("paint.zig");
const rect_mod = @import("rect.zig");
const render_common = @import("render/common.zig");
const scene_mod = @import("scene.zig");
const target_mod = @import("target.zig");
const util = @import("util.zig");

const GpuStrip = render_common.GpuStrip;
const LayerClip = common.record.LayerClip;
const LayerTextureRegion = target_mod.LayerTextureRegion;
const Paint = common.paint.Paint;
const PaintResolver = paint_mod.PaintResolver;
const Rect = kurbo.Rect;
const RectPart = rect_mod.RectPart;
const RectU16 = common.geometry.RectU16;
const RecordedDraw = scene_mod.RecordedDraw;
const StripAlphaFillSegment = common.strip.StripAlphaFillSegment;
const StripFillSegment = common.strip.StripFillSegment;
const Tile = common.tile.Tile;
const TextureSourceId = paint_mod.TextureSourceId;

/// Strip ranges and texture-binding state for one scheduled draw pass.
pub const Draw = struct {
    /// Ranges selecting this draw's strips from `DrawBuffers.strips`.
    strip_ranges: util.Ranges = .{},
    /// Runs that require external texture bindings.
    external_texture_runs: std.ArrayList(ExternalTextureRun) = .empty,
    /// Whether any strip in this draw samples a child layer.
    has_child_layer: bool = false,

    /// Release the external-run list and range storage.
    pub fn deinit(self: *Draw, allocator: std.mem.Allocator) void {
        self.strip_ranges.deinit(allocator);
        self.external_texture_runs.deinit(allocator);
        self.* = undefined;
    }

    /// Drop all selected ranges and bindings.
    pub fn clear(self: *Draw) void {
        self.strip_ranges.clear();
        self.external_texture_runs.clearRetainingCapacity();
        self.has_child_layer = false;
    }

    /// Append a strip, assigning an external texture slot when needed.
    fn push(
        self: *Draw,
        allocator: std.mem.Allocator,
        strips: *std.ArrayList(GpuStrip),
        gpu_strip_in: GpuStrip,
        texture_source: ?TextureSourceId,
    ) !void {
        var gpu_strip = gpu_strip_in;
        if (try assignExternalTextureSlot(
            allocator,
            &self.external_texture_runs,
            self.strip_ranges.len(),
            texture_source,
        )) |slot| {
            gpu_strip.paint_and_rect_flag |= @as(u32, slot) << render_common.EXTERNAL_TEXTURE_SLOT_SHIFT;
        }
        try util.pushRanged(GpuStrip, strips, &self.strip_ranges, allocator, gpu_strip);
    }
};

/// Root-level opaque strips and the external texture bindings needed to render
/// them.
pub const OpaqueDraw = struct {
    strips: std.ArrayList(GpuStrip) = .empty,
    external_texture_runs: std.ArrayList(ExternalTextureRun) = .empty,

    /// Release both buffers.
    pub fn deinit(self: *OpaqueDraw, allocator: std.mem.Allocator) void {
        self.strips.deinit(allocator);
        self.external_texture_runs.deinit(allocator);
        self.* = undefined;
    }

    /// Append an opaque strip, assigning an external texture slot when needed.
    pub fn push(self: *OpaqueDraw, allocator: std.mem.Allocator, strip_in: GpuStrip, texture_source: ?TextureSourceId) !void {
        var strip = strip_in;
        if (try assignExternalTextureSlot(
            allocator,
            &self.external_texture_runs,
            self.strips.items.len,
            texture_source,
        )) |slot| {
            strip.paint_and_rect_flag |= @as(u32, slot) << render_common.EXTERNAL_TEXTURE_SLOT_SHIFT;
        }
        try self.strips.append(allocator, strip);
    }

    /// Reverse opaque strips for front-to-back rendering.
    pub fn reverse(self: *OpaqueDraw) void {
        std.mem.reverse(GpuStrip, self.strips.items);

        // Reassign the indices for external textures.
        var original_end = self.strips.items.len;
        var i = self.external_texture_runs.items.len;
        while (i > 0) {
            i -= 1;
            const run = &self.external_texture_runs.items[i];
            const original_start = run.strips_start;
            run.strips_start = self.strips.items.len - original_end;
            original_end = original_start;
        }
        std.mem.reverse(ExternalTextureRun, self.external_texture_runs.items);
    }

    /// Whether the opaque pass has no strips.
    pub fn isEmpty(self: *const OpaqueDraw) bool {
        return self.strips.items.len == 0;
    }

    /// The opaque strips.
    pub fn stripItems(self: *const OpaqueDraw) []const GpuStrip {
        return self.strips.items;
    }

    /// The external texture runs.
    pub fn runs(self: *const OpaqueDraw) []const ExternalTextureRun {
        return self.external_texture_runs.items;
    }

    /// Drop all strips and runs, keeping capacity.
    pub fn clear(self: *OpaqueDraw) void {
        self.strips.clearRetainingCapacity();
        self.external_texture_runs.clearRetainingCapacity();
    }
};

/// Appends recorded draws to a scheduled [`Draw`] and its shared buffers.
pub fn DrawBuilder(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Draw whose ranges and binding state are being built.
        draw: *Draw,
        /// Shared buffer receiving alpha-blended strips.
        strips: *std.ArrayList(GpuStrip),
        /// Root-level opaque draw receiving fully covered strips.
        opaque_draw: *OpaqueDraw,
        /// Target and depth state used to encode strips.
        state: *DrawState(T),

        /// Create a builder over a draw, the shared buffers, and target state.
        pub fn init(
            draw: *Draw,
            draw_buffers: *DrawBuffers,
            state: *DrawState(T),
        ) Self {
            return .{
                .draw = draw,
                .strips = &draw_buffers.strips,
                .opaque_draw = &draw_buffers.opaque_draw,
                .state = state,
            };
        }

        /// Encode one recorded draw.
        pub fn pushDraw(
            self: *Self,
            allocator: std.mem.Allocator,
            draw: *const RecordedDraw,
            strip_storage: *const common.strip_storage.StripStorage,
            paint_resolver: PaintResolver,
        ) !void {
            switch (draw.*) {
                .path => |path| try self.pushPath(allocator, &path, strip_storage, paint_resolver),
                .rect => |rect| try self.pushRect(allocator, &rect.rect, &rect.paint, paint_resolver),
            }
        }

        fn pushOpaque(self: *Self, allocator: std.mem.Allocator, strip: GpuStrip, texture_source: ?TextureSourceId) !bool {
            if (!self.state.use_depth_buffer or !self.state.target.enableDepth()) return false;
            try self.opaque_draw.push(allocator, strip, texture_source);
            return true;
        }

        fn pushPath(
            self: *Self,
            allocator: std.mem.Allocator,
            path: *const scene_mod.RecordedPath,
            strip_storage: *const common.strip_storage.StripStorage,
            paint_resolver: PaintResolver,
        ) !void {
            const strips = strip_storage.strips.items[path.strips.start..path.strips.end];

            const packed_paint = try paint_resolver.pack(&path.paint);
            // Note: this also advances the depth index for layer root draws
            // even though those never use the depth buffer, matching upstream.
            const depth_index = self.state.depth_counter.next(packed_paint.is_opaque);
            const tile_bounds = toTileBounds(self.state.target_bbox);
            const geometry_shift = self.state.target.geometryShift();

            var ctx = StripVisitContext(T){
                .builder = self,
                .allocator = allocator,
                .paint = packed_paint,
                .depth_index = depth_index,
                .geometry_shift = geometry_shift,
            };
            common.strip.visitStripFillSegments(strips, tile_bounds, &ctx, true, true);
            if (ctx.err) |err| return err;
        }

        fn pushRect(
            self: *Self,
            allocator: std.mem.Allocator,
            rect: *const Rect,
            paint: *const Paint,
            paint_resolver: PaintResolver,
        ) !void {
            // Recordings might contain geometry that exceeds the actual layer
            // bounding box. `visitStripFillSegments` culls paths; rectangles
            // need a simple intersection here.
            const clipped_rect = rect.intersect(self.state.target_bbox.asRect());
            if (clipped_rect.isZeroArea()) return;

            const packed_paint = try paint_resolver.pack(paint);
            const depth_index = self.state.depth_counter.next(packed_paint.is_opaque);
            const split = rect_mod.splitRect(clipped_rect);

            const parts = [5]?RectPart{
                split.main,
                split.top,
                split.bottom,
                split.left,
                split.right,
            };
            for (parts) |maybe_part| {
                const part = maybe_part orelse continue;
                const shifted = part.shift(self.state.target.geometryShift());
                const strip = stripFromRect(shifted, packed_paint.payloadAt(part.rect.x0, part.rect.y0), packed_paint.paint, depth_index);
                if (!(packed_paint.is_opaque and part.frac == 0 and
                    try self.pushOpaque(allocator, strip, packed_paint.texture_source)))
                {
                    try self.draw.push(allocator, self.strips, strip, packed_paint.texture_source);
                }
            }
        }

        /// Fill a layer region with its sampled texture (layer milestone).
        pub fn pushLayerFill(
            self: *Self,
            allocator: std.mem.Allocator,
            sample: LayerTextureRegion,
            opacity: f32,
            clip_path: ?*const LayerClip,
            strip_storage: *const common.strip_storage.StripStorage,
        ) !void {
            const sample_bbox = sample.layer_bbox.intersect(self.state.target_bbox);
            if (sample_bbox.isEmpty()) return;

            const paint = (render_common.COLOR_SOURCE_LAYER << render_common.COLOR_SOURCE_SHIFT) |
                @as(u32, util.packOpacity(opacity));

            if (clip_path) |clip| {
                const strips = strip_storage.strips.items[clip.strip_range.start..clip.strip_range.end];
                const depth_index = self.state.depth_counter.next(false);
                const tile_bounds = sample_bbox.toTileBounds();

                var ctx = LayerFillVisitContext(T){
                    .builder = self,
                    .allocator = allocator,
                    .sample = sample,
                    .paint = paint,
                    .depth_index = depth_index,
                    .geometry_shift = self.state.target.geometryShift(),
                };
                common.strip.visitStripFillSegments(strips, tile_bounds, &ctx, true, true);
                if (ctx.err) |err| return err;
            } else {
                const depth_index = self.state.depth_counter.next(false);
                const rect_part = RectPart{
                    .rect = sample_bbox.shift(self.state.target.geometryShift()),
                    .frac = 0,
                };
                self.draw.has_child_layer = true;
                const payload = payloadAt(sample, sample_bbox.x0, sample_bbox.y0);
                try self.draw.push(
                    allocator,
                    self.strips,
                    stripFromRect(rect_part, payload, paint, depth_index),
                    null,
                );
            }
        }
    };
}

/// Visit context that routes strip segments into the draw.
fn StripVisitContext(comptime T: type) type {
    return struct {
        builder: *DrawBuilder(T),
        allocator: std.mem.Allocator,
        paint: paint_mod.PackedPaint,
        depth_index: u32,
        geometry_shift: [2]i32,
        err: ?std.mem.Allocator.Error = null,

        pub fn onAlphaSegment(self: *@This(), segment: StripAlphaFillSegment) void {
            if (self.err != null) return;
            const shifted = segment.fill.shift(self.geometry_shift);
            const strip = stripFromFillSegment(
                shifted,
                segment.alpha_idx / @as(u32, Tile.HEIGHT),
                self.paint.payloadAt(segment.fill.x0(), segment.fill.y()),
                self.paint.paint,
                self.depth_index,
            );
            self.builder.draw.push(self.allocator, self.builder.strips, strip, self.paint.texture_source) catch |e| {
                self.err = e;
            };
        }

        pub fn onFillSegment(self: *@This(), segment: StripFillSegment) void {
            if (self.err != null) return;
            const shifted = segment.shift(self.geometry_shift);
            const strip = stripFromFillSegment(
                shifted,
                null,
                self.paint.payloadAt(segment.x0(), segment.y()),
                self.paint.paint,
                self.depth_index,
            );
            const routed_opaque = self.paint.is_opaque and
                (self.builder.pushOpaque(self.allocator, strip, self.paint.texture_source) catch |e| {
                    self.err = e;
                    return;
                });
            if (!routed_opaque) {
                self.builder.draw.push(self.allocator, self.builder.strips, strip, self.paint.texture_source) catch |e| {
                    self.err = e;
                };
            }
        }
    };
}

/// Visit context that routes strip segments into a clipped layer fill
/// (layer milestone).
fn LayerFillVisitContext(comptime T: type) type {
    return struct {
        builder: *DrawBuilder(T),
        allocator: std.mem.Allocator,
        sample: LayerTextureRegion,
        paint: u32,
        depth_index: u32,
        geometry_shift: [2]i32,
        err: ?std.mem.Allocator.Error = null,

        pub fn onAlphaSegment(self: *@This(), segment: StripAlphaFillSegment) void {
            self.push(segment.fill, segment.alpha_idx / @as(u32, Tile.HEIGHT));
        }

        pub fn onFillSegment(self: *@This(), segment: StripFillSegment) void {
            self.push(segment, null);
        }

        fn push(self: *@This(), segment: StripFillSegment, col_idx: ?u32) void {
            if (self.err != null) return;
            self.builder.draw.has_child_layer = true;
            const payload = payloadAt(self.sample, segment.x0(), segment.y());
            const shifted = segment.shift(self.geometry_shift);
            const strip = stripFromFillSegment(shifted, col_idx, payload, self.paint, self.depth_index);
            self.builder.draw.push(self.allocator, self.builder.strips, strip, null) catch |e| {
                self.err = e;
            };
        }
    };
}

/// Reusable strip storage shared by all draws in a schedule.
pub const DrawBuffers = struct {
    /// Root-level opaque draw rendered in the early depth-writing pass.
    opaque_draw: OpaqueDraw = .{},
    /// Alpha-blended strips selected by each draw's ranges.
    strips: std.ArrayList(GpuStrip) = .empty,

    /// Release both buffers.
    pub fn deinit(self: *DrawBuffers, allocator: std.mem.Allocator) void {
        self.opaque_draw.deinit(allocator);
        self.strips.deinit(allocator);
        self.* = undefined;
    }

    /// Drop all strips, keeping capacity.
    pub fn clear(self: *DrawBuffers) void {
        self.opaque_draw.clear();
        self.strips.clearRetainingCapacity();
    }
};

/// Target-specific state used while encoding a draw.
pub fn DrawState(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Destination into which strips will be rendered.
        target: T,
        /// Whether opaque strips may use the target's depth buffer.
        use_depth_buffer: bool,
        /// Assigns depth values to opaque strips.
        depth_counter: DepthCounter = .{},
        /// Scene-space bounds visible in the target.
        target_bbox: RectU16,

        /// Create state for `target` with the given visible bounds.
        pub fn init(target: T, target_bbox: RectU16, use_depth_buffer: bool) Self {
            return .{
                .target = target,
                .use_depth_buffer = use_depth_buffer,
                .target_bbox = target_bbox,
            };
        }
    };
}

/// Bit 31 of `GpuStrip::paint_and_rect_flag` signals that the strip represents
/// a full rectangle.
pub const RECT_STRIP_FLAG: u32 = 1 << 31;

/// Build a strip for a fill segment (`col_idx` is `null` for gap fills).
pub fn stripFromFillSegment(
    rect: RectU16,
    col_idx: ?u32,
    payload: u32,
    paint: u32,
    depth_index: u32,
) GpuStrip {
    const width = rect.width();
    const dense_width_or_rect_height: u16 = if (col_idx != null) width else 0;
    const col_idx_or_rect_frac: u32 = if (col_idx) |idx| idx else 0;

    return .{
        .x = rect.x0,
        .y = rect.y0,
        .width = width,
        .dense_width_or_rect_height = dense_width_or_rect_height,
        .col_idx_or_rect_frac = col_idx_or_rect_frac,
        .payload = payload,
        .paint_and_rect_flag = paint,
        .depth_index = depth_index,
    };
}

/// Build a strip for a rectangle part.
pub fn stripFromRect(part: RectPart, payload: u32, paint: u32, depth_index: u32) GpuStrip {
    return .{
        .x = part.rect.x0,
        .y = part.rect.y0,
        .width = part.rect.width(),
        .dense_width_or_rect_height = part.rect.height(),
        .col_idx_or_rect_frac = part.frac,
        .payload = payload,
        .paint_and_rect_flag = paint | RECT_STRIP_FLAG,
        .depth_index = depth_index,
    };
}

/// The payload for a layer fill sample at scene-space `(x, y)`.
pub fn payloadAt(region: LayerTextureRegion, x: u16, y: u16) u32 {
    const shift = region.geometryShift();
    // Cannot fail: the caller only samples values within the layer bbox, and
    // the shift only accounts for the bbox origin.
    const source_x: u16 = @intCast(@as(i32, x) + shift[0]);
    const source_y: u16 = @intCast(@as(i32, y) + shift[1]);
    return util.packU16Pair(source_x, source_y);
}

/// Number of external textures that can be sampled by one strip draw.
pub const EXTERNAL_TEXTURE_SLOT_COUNT: usize = 4;

/// External texture bindings for one strip draw.
pub const ExternalTextureBindings = struct {
    texture_sources: [EXTERNAL_TEXTURE_SLOT_COUNT]?TextureSourceId = @splat(null),

    /// No bindings.
    pub const EMPTY: ExternalTextureBindings = .{};

    /// Return the existing slot for `texture_source`, or insert it into the
    /// first empty slot. Returns `null` when all four slots are occupied by
    /// other textures.
    pub fn getOrInsert(self: *ExternalTextureBindings, texture_source: TextureSourceId) ?u8 {
        for (&self.texture_sources, 0..) |*candidate, slot| {
            if (candidate.*) |source| {
                if (std.meta.eql(source, texture_source)) return @intCast(slot);
            } else {
                candidate.* = texture_source;
                return @intCast(slot);
            }
        }
        return null;
    }

    /// The bindings as an array.
    pub fn asArray(self: ExternalTextureBindings) [EXTERNAL_TEXTURE_SLOT_COUNT]?TextureSourceId {
        return self.texture_sources;
    }
};

/// Specifies a run of strips that can be drawn with the same external texture
/// bindings.
pub const ExternalTextureRun = struct {
    /// External textures bound for the run.
    bindings: ExternalTextureBindings,
    /// Start index of the strip range for this run. The end is implicitly the
    /// start of the next run, or, for the last run, the total number of strips
    /// in the pass.
    strips_start: usize,
};

/// Assign a slot for `texture_source`, starting a fresh run when the current
/// run's four slots are all taken by other textures.
fn assignExternalTextureSlot(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(ExternalTextureRun),
    strips_len: usize,
    texture_source: ?TextureSourceId,
) !?u8 {
    const source = texture_source orelse return null;

    if (runs.items.len > 0) {
        if (runs.items[runs.items.len - 1].bindings.getOrInsert(source)) |slot| {
            return slot;
        }
    }

    var bindings = ExternalTextureBindings.EMPTY;
    const slot = bindings.getOrInsert(source).?;
    const strips_start = if (runs.items.len == 0) 0 else strips_len;
    try runs.append(allocator, .{ .bindings = bindings, .strips_start = strips_start });
    return slot;
}

/// Assigns monotonically increasing depth values to opaque strips.
pub const DepthCounter = struct {
    /// Number of opaque strips assigned so far.
    count: u32 = 0,

    /// Advance for one draw and return the depth index to store on its strips.
    pub fn next(self: *DepthCounter, is_opaque: bool) u32 {
        self.count += @intFromBool(is_opaque);
        return self.count;
    }
};

/// Tile-space conversion for a tile-aligned bounding box.
pub fn toTileBounds(rect: RectU16) RectU16 {
    if (std.debug.runtime_safety) {
        std.debug.assert(rect.x0 % Tile.WIDTH == 0 and rect.x1 % Tile.WIDTH == 0 and
            rect.y0 % Tile.HEIGHT == 0 and rect.y1 % Tile.HEIGHT == 0);
    }
    return RectU16.new(
        rect.x0 / Tile.WIDTH,
        rect.y0 / Tile.HEIGHT,
        rect.x1 / Tile.WIDTH,
        rect.y1 / Tile.HEIGHT,
    );
}

// ---------------------------------------------------------------------------
// Tests (ported / adapted from `draw.rs`)
// ---------------------------------------------------------------------------

const testing = std.testing;
const peniko = @import("../peniko/root.zig");
const IndexedPaint = common.paint.IndexedPaint;

fn solid(alpha: f32) Paint {
    return Paint.fromAlphaColor(peniko.color.Color.fromRgb8(0, 0, 255).withAlpha(alpha));
}

fn testRect(x: f64) Rect {
    return Rect.new(x, 0.0, x + 4.0, 4.0);
}

test "opaque routing" {
    const allocator = testing.allocator;
    var buffers = DrawBuffers{};
    defer buffers.deinit(allocator);
    var state = DrawState(target_mod.RootTarget).init(.user_surface, RectU16.new(0, 0, 16, 8), true);
    var draw = Draw{};
    defer draw.deinit(allocator);

    var builder = DrawBuilder(target_mod.RootTarget).init(&draw, &buffers, &state);
    const resolver = PaintResolver.solid_only;
    const opaque_rect = RecordedDraw{ .rect = .{ .rect = testRect(0.0), .paint = solid(1.0) } };
    try builder.pushDraw(allocator, &opaque_rect, &.{}, resolver);
    const fractional_rect = RecordedDraw{ .rect = .{
        .rect = Rect.new(8.25, 0.0, 12.0, 4.0),
        .paint = solid(1.0),
    } };
    try builder.pushDraw(allocator, &fractional_rect, &.{}, resolver);

    // The pixel-aligned opaque rect goes to the opaque pass; the fractional
    // one stays in the alpha pass.
    try testing.expectEqual(@as(usize, 1), buffers.opaque_draw.strips.items.len);
    try testing.expectEqual(@as(usize, 1), draw.strip_ranges.len());

    // Atlas layers never enable the depth optimization, so the strip stays in
    // the alpha draw and the opaque pass keeps only the user-surface strip.
    var atlas_state = DrawState(target_mod.RootTarget).init(.atlas_layer, RectU16.new(0, 0, 8, 8), true);
    var atlas_draw = Draw{};
    defer atlas_draw.deinit(allocator);
    var atlas_builder = DrawBuilder(target_mod.RootTarget).init(&atlas_draw, &buffers, &atlas_state);
    const atlas_rect = RecordedDraw{ .rect = .{ .rect = testRect(0.0), .paint = solid(1.0) } };
    try atlas_builder.pushDraw(allocator, &atlas_rect, &.{}, resolver);

    try testing.expectEqual(@as(usize, 1), buffers.opaque_draw.strips.items.len);
    try testing.expectEqual(@as(usize, 1), atlas_draw.strip_ranges.len());
}

test "depth progression" {
    const allocator = testing.allocator;
    var buffers = DrawBuffers{};
    defer buffers.deinit(allocator);
    var state = DrawState(target_mod.RootTarget).init(.user_surface, RectU16.new(0, 0, 64, 8), true);
    var draw = Draw{};
    defer draw.deinit(allocator);

    var builder = DrawBuilder(target_mod.RootTarget).init(&draw, &buffers, &state);
    const resolver = PaintResolver.solid_only;
    const opacity = [_]f32{ 0.5, 0.5, 1.0, 0.5, 0.5, 1.0, 0.5 };
    for (opacity, 0..) |alpha, index| {
        const recorded = RecordedDraw{ .rect = .{
            .rect = testRect(@floatFromInt(index * 8)),
            .paint = solid(alpha),
        } };
        try builder.pushDraw(allocator, &recorded, &.{}, resolver);
    }

    var iter = util.RangedSlice(render_common.GpuStrip).init(buffers.strips.items, &draw.strip_ranges).iter();
    var alpha_depths: [5]u32 = undefined;
    for (&alpha_depths) |*depth| depth.* = iter.next().?.depth_index;
    try testing.expectEqual([5]u32{ 0, 0, 1, 1, 2 }, alpha_depths);

    var opaque_depths = [_]u32{ 0, 0 };
    for (&opaque_depths, 0..) |*depth, index| depth.* = buffers.opaque_draw.strips.items[index].depth_index;
    try testing.expectEqual([2]u32{ 1, 2 }, opaque_depths);
}

test "opaque reverse without texture runs" {
    const allocator = testing.allocator;
    var draw = OpaqueDraw{};
    defer draw.deinit(allocator);

    for (0..3) |x| {
        try draw.push(allocator, .{
            .x = @intCast(x),
            .y = 0,
            .width = 1,
            .dense_width_or_rect_height = 0,
            .col_idx_or_rect_frac = 0,
            .payload = 0,
            .paint_and_rect_flag = 0,
            .depth_index = 0,
        }, null);
    }

    draw.reverse();

    try testing.expectEqual(@as(u16, 2), draw.strips.items[0].x);
    try testing.expectEqual(@as(u16, 0), draw.strips.items[2].x);
    try testing.expect(draw.external_texture_runs.items.len == 0);
}

test "texture runs coalesce distinct paints for same texture" {
    const allocator = testing.allocator;
    var runs: std.ArrayList(ExternalTextureRun) = .empty;
    defer runs.deinit(allocator);

    const texture = TextureSourceId{ .external = 7 };
    try testing.expectEqual(@as(?u8, 0), try assignExternalTextureSlot(allocator, &runs, 0, texture));
    try testing.expectEqual(@as(?u8, 0), try assignExternalTextureSlot(allocator, &runs, 1, texture));
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(@as(usize, 0), runs.items[0].strips_start);
    try testing.expectEqual(@as(?u8, null), try assignExternalTextureSlot(allocator, &runs, 2, null));
}

test "fifth external texture starts a fresh run" {
    const allocator = testing.allocator;
    var runs: std.ArrayList(ExternalTextureRun) = .empty;
    defer runs.deinit(allocator);

    var textures: [5]TextureSourceId = undefined;
    for (&textures, 0..) |*texture, index| texture.* = .{ .external = index };
    for (textures, 0..) |texture, index| {
        const expected_slot: u8 = if (index < EXTERNAL_TEXTURE_SLOT_COUNT) @intCast(index) else 0;
        try testing.expectEqual(@as(?u8, expected_slot), try assignExternalTextureSlot(allocator, &runs, index, texture));
    }
    // The fifth texture starts a fresh run at strip index 4 and takes slot 0.
    try testing.expectEqual(@as(usize, 2), runs.items.len);
    try testing.expectEqual(@as(usize, 4), runs.items[1].strips_start);
    // Reusing the first texture gets the second slot in the fresh run.
    try testing.expectEqual(@as(?u8, 1), try assignExternalTextureSlot(allocator, &runs, 5, textures[0]));
}

test "indexed paint resolution is unsupported" {
    var draw = Draw{};
    defer draw.deinit(testing.allocator);
    var buffers = DrawBuffers{};
    defer buffers.deinit(testing.allocator);
    var state = DrawState(target_mod.RootTarget).init(.user_surface, RectU16.new(0, 0, 16, 8), false);
    var builder = DrawBuilder(target_mod.RootTarget).init(&draw, &buffers, &state);
    const indexed = IndexedPaint.new(0) catch unreachable;
    const paint = Paint{ .indexed = indexed };
    const recorded = RecordedDraw{ .rect = .{ .rect = testRect(0.0), .paint = paint } };
    try testing.expectError(
        error.Unsupported,
        builder.pushDraw(testing.allocator, &recorded, &.{}, PaintResolver.solid_only),
    );
}
