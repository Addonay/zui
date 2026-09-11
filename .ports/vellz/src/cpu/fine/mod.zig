//! Port of vello_cpu src/fine/mod.rs (Apache-2.0 OR MIT).
//!
//! Fine rasterization stage: processes strip rows at pixel level into
//! column-major 4-row blocks (see the layout note below), supporting both the
//! high-precision f32 kernel (ported, `highp/mod.zig`) and, later, the u8 kernel
//! (`U8Kernel`, M4).
//!
//! Buffer layout: for a pixel column `dx` of a 4-row strip and row `y`, the
//! scratch index of component `c` is `COLOR_COMPONENTS * (TILE_HEIGHT * dx + y) + c`.
//! Layer buffers form a stack: `blend_buffers[0]` is the base target, and each
//! `push_buf`/`pop_buf` pair brackets a temporary layer that is composited by
//! `layer_fill`.
//!
//! `rasterizeRegion` order matches upstream: depth-buffer (opaque) commands
//! front-to-back with depth read/write, then the uncovered range is
//! initialized, then the regular commands back-to-front with depth read. When
//! the root is a blend target, the background is isolated into the parent
//! buffer so blend modes cannot destructively touch it.
//!
//! `indexed_fill` (gradients and images) is implemented in M2 via
//! `gradient.zig` and `image.zig`; the painters are f32-only until the u8
//! kernel lands in M4. Still deferred (explicit `error.Unsupported`, never
//! placeholder pixels): blurred rounded rects, external textures, and filter
//! paints (`filter_paints` is carried but always empty for now).
//!
//! Kernel (`K`) surface required at instantiation time
//! (`ComptimeKernel` documents it; only `highp.F32Kernel` is instantiated in
//! M1):
//!
//! ```text
//! Numeric, Composite, NumericVec        types
//! COMPOSITE_LENGTH: usize               lanes per composite (16 / 32)
//! ZERO, ONE: Numeric                    neutral values
//! extractColor(color) [4]Numeric
//! pack(level, scratch, width, region)   scratch -> region rows
//! unpack(level, region, width, scratch) region rows -> scratch
//! copySolid(level, dest, color)
//! applyMask(level, dest, src)           src is an iterator of NumericVec
//! applyTint(level, dest, tint)
//! alphaCompositeSolid(level, dest, src, alphas)
//! alphaCompositeBuffer(level, dest, src, alphas)
//! blend(level, dest, start_x, start_y, src, blend_mode, alphas, mask)
//! fillSolid(level, dest, color, alphas)
//! compositeFromSlice(slice) Composite
//! compositeFromColor(color) Composite
//! numericVecFromF32(f32x16) NumericVec
//! numericVecFromU8(u8x16) NumericVec
//! ```
//!
//! Ownership/allocator note: unlike the `Pool`/`Pixmap` convention of taking
//! an allocator per growing call, `Fine` stores the allocator it was created
//! with (like upstream's `Vec`), so `rasterizeRegion` keeps the fixed
//! `docs/cpu-pipeline.md` signature. `init`/`deinit` are still an explicit
//! pair and no hidden global allocator is used.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const geometry = @import("../../common/geometry.zig");
const target_mod = @import("../../common/target.zig");
const encode_mod = @import("../../common/encode.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const shared_mod = @import("../../common/shared.zig");
const paint_mod = @import("../../common/paint.zig");
const mask_mod = @import("../../common/mask.zig");
const common_util = @import("../../common/util.zig");
const peniko = @import("../../peniko/root.zig");
const util = @import("../util.zig");
const region_mod = @import("../region.zig");
const coarse = @import("../coarse/mod.zig");
const gradient_mod = @import("gradient.zig");
const image_mod = @import("image.zig");

const Span = util.Span;
const Region = region_mod.Region;
const DepthBuffer = coarse.DepthBuffer;
const BucketRange = coarse.BucketRange;
const CommandBucketer = coarse.CommandBucketer;
const RowState = coarse.RowState;
const RenderCmd = coarse.RenderCmd;
const PaintFill = coarse.PaintFill;
const LayerFill = coarse.LayerFill;
const PaintFillAttrs = coarse.PaintFillAttrs;
const LayerFillAttrs = coarse.LayerFillAttrs;
const Mask = mask_mod.Mask;
const Pixmap = pixmap_mod.Pixmap;
const PremulColor = paint_mod.PremulColor;
const TargetInit = target_mod.TargetInit(PremulColor);
const BlendMode = peniko.BlendMode;

/// The high-precision (f32) kernel.
pub const highp = @import("highp/mod.zig");
/// Re-export of `highp.F32Kernel` (upstream `pub use highp::F32Kernel`).
pub const F32Kernel = highp.F32Kernel;

/// Offset to shift from pixel corner to pixel center for sampling.
pub const PIXEL_CENTER_OFFSET: f64 = 0.5;

/// Number of color components per pixel (RGBA).
pub const COLOR_COMPONENTS: usize = 4;

/// The tile height in pixels.
pub const TILE_HEIGHT: u16 = 4;

/// Number of color components in a single column of a tile
/// (`height * components`).
pub const TILE_HEIGHT_COMPONENTS: usize = @as(usize, TILE_HEIGHT) * COLOR_COMPONENTS;

/// Errors produced by fine rasterization.
///
/// `Unsupported` is returned for the still-deferred paint kinds (blurred
/// rounded rects, external textures, filters); `OutOfMemory` replaces
/// upstream's abort-on-allocation-failure. Upstream panics for a missing
/// registered image or an out-of-range paint index; this port reports
/// `MissingImage`/`InvalidPaintIndex` instead.
pub const Error = error{ Unsupported, OutOfMemory, MissingImage, InvalidPaintIndex };

/// Returns whether a blend mode is the upstream default (normal + src-over).
///
/// Zig structs do not support `==`, so this replaces
/// `blend_mode == BlendMode::default()`.
pub fn isDefaultBlendMode(blend_mode: BlendMode) bool {
    return blend_mode.mix == .normal and blend_mode.compose == .src_over;
}

/// A source of composite vectors for blending: either one repeated color or a
/// packed numeric buffer in column-major scratch order.
pub fn CompositeIter(comptime K: type) type {
    return struct {
        const Source = union(enum) {
            solid: K.Composite,
            buffer: []const K.Numeric,
        };

        source: Source,
        idx: usize = 0,

        /// Iterate a single color repeated forever (upstream `iter::repeat`).
        pub fn initSolid(color: K.Composite) @This() {
            return .{ .source = .{ .solid = color } };
        }

        /// Iterate `buffer` in `COMPOSITE_LENGTH`-sized chunks (upstream
        /// `chunks_exact(..).map(from_slice)`).
        pub fn initBuffer(buffer: []const K.Numeric) @This() {
            return .{ .source = .{ .buffer = buffer } };
        }

        pub fn next(self: *@This()) ?K.Composite {
            switch (self.source) {
                .solid => |color| return color,
                .buffer => |buffer| {
                    if (self.idx >= buffer.len) return null;
                    const chunk = buffer[self.idx..][0..K.COMPOSITE_LENGTH];
                    self.idx += K.COMPOSITE_LENGTH;
                    return K.compositeFromSlice(chunk);
                },
            }
        }
    };
}

/// An iterator that repeats one numeric vector forever (upstream
/// `iter::repeat(NumericVec::from_f32(..))`).
pub fn RepeatNumericVec(comptime K: type) type {
    return struct {
        value: K.NumericVec,

        pub fn next(self: *@This()) ?K.NumericVec {
            return self.value;
        }
    };
}

/// Samples a mask for the 4 rows of the current strip, one numeric vector per
/// pixel column.
///
/// Out-of-mask samples yield `0` (fully masked out), matching `Fine::mask`.
pub fn SampledMaskIter(comptime K: type) type {
    return struct {
        m: *const Mask,
        x: u16,
        end_x: u16,
        y: u32,

        pub fn next(self: *@This()) ?K.NumericVec {
            if (self.x >= self.end_x) return null;
            const x = self.x;
            self.x += 1;

            const mask_width = self.m.width();
            const mask_height = self.m.height();
            var samples: simd.U8x16 = undefined;
            inline for (0..4) |row| {
                // Upstream computes `y` in a `u32x4` and then casts each entry
                // to `u16` before the bounds check, so mirror the truncation.
                const sample_row: u16 = @truncate(self.y + row);
                const sample: u8 = if (x < mask_width and sample_row < mask_height)
                    self.m.sample(x, sample_row)
                else
                    0;
                inline for (0..4) |component| {
                    samples[row * COLOR_COMPONENTS + component] = sample;
                }
            }

            return K.numericVecFromU8(samples);
        }
    };
}

/// Resources available to fine rasterization.
pub const FineResources = struct {
    /// One alpha buffer per thread; each pixel column of a strip occupies
    /// `TILE_HEIGHT` bytes.
    alpha_buffers: []const []const u8,
    /// Encoded paints referenced by `Paint.indexed`. The list structure is
    /// const to fine rasterization; the gradient LUTs inside are built lazily
    /// during rasterization (upstream's interior `OnceCell`).
    encoded_paints: []const encode_mod.EncodedPaint,
    /// Encoded paints produced while bucketing filter layers (M2-later; the
    /// filters themselves are still deferred).
    filter_paints: []const encode_mod.EncodedPaint,
    /// Resolver for `ImageSource.opaque_id` paints (images registered through
    /// `Resources.register_image`).
    image_resolver: paint_mod.ImageResolver,
};

fn zeroedVector(comptime K: type, allocator: std.mem.Allocator, len: usize) std.mem.Allocator.Error!std.ArrayList(K.Numeric) {
    var vector = std.ArrayList(K.Numeric).empty;
    errdefer vector.deinit(allocator);
    try vector.resize(allocator, len);
    @memset(vector.items, K.ZERO);
    return vector;
}

/// Fine rasterizer for processing strip rows at the pixel level.
pub fn Fine(comptime K: type) type {
    return struct {
        const Self = @This();

        const ScratchRange = struct {
            start: usize,
            end: usize,
        };

        /// The SIMD level this rasterizer was created with. The portable
        /// kernel is compile-time dispatched, so this is currently only
        /// carried for parity with upstream's `Fine::new(simd, ..)` and for
        /// future runtime-dispatch kernels.
        level: simd.Level,
        /// The allocator that owns every buffer in this struct.
        allocator: std.mem.Allocator,
        /// Pixel span covered by the blend buffers.
        buffer_span: Span,
        /// Stack of blend buffers for managing layers and composition.
        blend_buffers: std.ArrayList(std.ArrayList(K.Numeric)),
        /// Pool for reusing layer buffer allocations.
        buffer_pool: common_util.VecPool(K.Numeric),
        /// Intermediate buffer used by painters (M2).
        paint_buf: std.ArrayList(K.Numeric),
        /// Buffer for storing gradient interpolation parameters (M2).
        f32_buf: std.ArrayList(f32),
        /// The current strip row y-coordinate in scene/filter coordinates.
        row_y: u16,
        /// The origin of the current target we are rendering into.
        origin: [2]u16 = .{ 0, 0 },

        /// Create a new fine rasterizer with the given SIMD level.
        ///
        /// Initializes the base blend buffer to `buffer_width * 4` columns of
        /// zeroes; layers are created lazily by `pushBuf`.
        pub fn init(
            level: simd.Level,
            allocator: std.mem.Allocator,
            buffer_width: u16,
        ) std.mem.Allocator.Error!Self {
            const scratch_len = @as(usize, buffer_width) * TILE_HEIGHT_COMPONENTS;
            var blend_buffers = std.ArrayList(std.ArrayList(K.Numeric)).empty;
            errdefer {
                for (blend_buffers.items) |*buffer| buffer.deinit(allocator);
                blend_buffers.deinit(allocator);
            }
            try blend_buffers.append(allocator, try zeroedVector(K, allocator, scratch_len));

            return .{
                .level = level,
                .allocator = allocator,
                .buffer_span = Span.new(0, buffer_width),
                .blend_buffers = blend_buffers,
                .buffer_pool = common_util.VecPool(K.Numeric).init(false),
                .paint_buf = .empty,
                .f32_buf = .empty,
                .row_y = 0,
            };
        }

        /// Release all owned buffers, including pooled layer buffers.
        pub fn deinit(self: *Self) void {
            for (self.blend_buffers.items) |*buffer| buffer.deinit(self.allocator);
            self.blend_buffers.deinit(self.allocator);
            for (self.buffer_pool.entries.items) |*buffer| buffer.deinit(self.allocator);
            self.buffer_pool.deinit(self.allocator);
            self.paint_buf.deinit(self.allocator);
            self.f32_buf.deinit(self.allocator);
            self.* = undefined;
        }

        /// Set the current strip row y-coordinate.
        pub fn setRowY(self: *Self, row_y: u16) void {
            self.row_y = row_y;
        }

        /// Set the origin of the current target (used by indexed paints).
        pub fn setPaintOffset(self: *Self, paint_offset: [2]u16) void {
            self.origin = paint_offset;
        }

        fn scratchRange(span: Span) ScratchRange {
            const start = @as(usize, span.pixelX()) * TILE_HEIGHT_COMPONENTS;
            const len = @as(usize, span.pixelWidth()) * TILE_HEIGHT_COMPONENTS;
            return .{ .start = start, .end = start + len };
        }

        fn currentBuffer(self: *Self) *std.ArrayList(K.Numeric) {
            return &self.blend_buffers.items[self.blend_buffers.items.len - 1];
        }

        // The reason that we have this optimization is that, as was determined
        // by profiling, just always clearing the whole fine buffer can be
        // expensive, especially for larger viewports. The depth buffer already
        // knows which pixel ranges are covered by an opaque paint, so only the
        // parts that are not covered need to be cleared (or unpacked).
        /// Initialize every range in the buffer that has not been filled yet
        /// with a paint.
        pub fn initUncoveredRange(
            self: *Self,
            scratch_span: Span,
            region: *Region,
            target_init: TargetInit,
            depth: *const DepthBuffer,
        ) Error!void {
            switch (target_init) {
                .src_over => {
                    const Ctx = struct {
                        fine: *Self,
                        region: *Region,

                        pub fn call(ctx: @This(), span: Span) void {
                            const x = span.pixelX();
                            const end = span.pixelEnd();
                            var sub = ctx.region.subSpan(x, end - x);
                            ctx.fine.unpack(x, &sub);
                        }
                    };
                    try depth.forEachUnsetRun(scratch_span, Ctx{ .fine = self, .region = region });
                },
                // We can hint the compiler to lower this into a
                // memory-zeroing operation, hence why we handle this case
                // explicitly.
                .clear => |color| {
                    if (color.isTransparent()) {
                        const Ctx = struct {
                            fine: *Self,

                            pub fn call(ctx: @This(), span: Span) void {
                                const x = span.pixelX();
                                const end = span.pixelEnd();
                                const range = scratchRange(Span.new(x, end - x));
                                const target = ctx.fine.currentBuffer().items;
                                @memset(target[range.start..range.end], K.ZERO);
                            }
                        };
                        try depth.forEachUnsetRun(scratch_span, Ctx{ .fine = self });
                    } else {
                        const extracted = K.extractColor(color);
                        const Ctx = struct {
                            fine: *Self,
                            color: [4]K.Numeric,

                            pub fn call(ctx: @This(), span: Span) void {
                                const x = span.pixelX();
                                const end = span.pixelEnd();
                                const range = scratchRange(Span.new(x, end - x));
                                const target = ctx.fine.currentBuffer().items;
                                K.copySolid(ctx.fine.level, target[range.start..range.end], ctx.color);
                            }
                        };
                        try depth.forEachUnsetRun(scratch_span, Ctx{ .fine = self, .color = extracted });
                    }
                },
            }
        }

        /// Push a new temporary layer buffer.
        ///
        /// Reused pool buffers keep their length and contents; only `span` is
        /// zeroed because that is the range a follow-up `layerFill` will read.
        pub fn pushBuf(self: *Self, span: ?Span) std.mem.Allocator.Error!void {
            var buffer = self.buffer_pool.take(.empty);
            errdefer buffer.deinit(self.allocator);

            // Reused vectors retain their length, so in most cases this will
            // be a no-op; new elements must still be zero-initialized.
            const target_len = self.blend_buffers.items[0].items.len;
            if (buffer.items.len < target_len) {
                const old_len = buffer.items.len;
                try buffer.resize(self.allocator, target_len);
                @memset(buffer.items[old_len..], K.ZERO);
            } else if (buffer.items.len > target_len) {
                buffer.shrinkRetainingCapacity(target_len);
            }

            // Instead of always zeroing out the whole buffer, only zero the
            // row-local span that will be read when compositing this layer.
            if (span) |s| {
                if (s.intersect(self.buffer_span)) |visible| {
                    const range = scratchRange(visible);
                    @memset(buffer.items[range.start..range.end], K.ZERO);
                }
            }

            try self.blend_buffers.append(self.allocator, buffer);
        }

        /// Pop the last temporary layer buffer, returning it to the pool.
        pub fn popBuf(self: *Self) std.mem.Allocator.Error!void {
            const popped = self.blend_buffers.pop().?;
            self.buffer_pool.submit(self.allocator, popped) catch |err| {
                // `Pool.submit` drops the entry on allocation failure; the
                // allocation itself is still owned by our copy, so free it
                // instead of leaking.
                var lost = popped;
                lost.deinit(self.allocator);
                return err;
            };
        }

        /// Writes the current buffer contents to the output row.
        pub fn pack(self: *const Self, region: *Region) void {
            const width = @as(usize, region.width);
            const scratch = self.blend_buffers.items[self.blend_buffers.items.len - 1].items;
            K.pack(self.level, scratch, width, region);
        }

        /// Reads the pixels of the target back into the buffer.
        ///
        /// This does the opposite of [`Fine.pack`].
        pub fn unpack(self: *Self, scratch_x_start: u16, region: *Region) void {
            const scratch_x = @as(usize, scratch_x_start);
            const width = @as(usize, region.width);
            const scratch = self.currentBuffer().items;
            K.unpack(
                self.level,
                region,
                width,
                scratch[scratch_x * TILE_HEIGHT_COMPONENTS ..],
            );
        }

        /// Execute a bucketed rendering command on the current strip row.
        pub fn runCmd(
            self: *Self,
            command: RenderCmd,
            bucketer: *const CommandBucketer,
            row: *const RowState,
            row_y: u16,
            resources: FineResources,
            depth: *const DepthBuffer,
        ) Error!void {
            switch (command) {
                .paint_fill => |paint_fill_cmd| {
                    const attrs = &bucketer.paint_fill_attrs.items[paint_fill_cmd.attrs_idx];
                    const alpha_buffer = resources.alpha_buffers[attrs.thread_idx];

                    const span = paint_fill_cmd.span.intersect(self.buffer_span) orelse return;

                    const Ctx = struct {
                        fine: *Self,
                        command: PaintFill,
                        attrs: *const PaintFillAttrs,
                        resources: FineResources,
                        alpha_buffer: []const u8,

                        pub fn call(ctx: @This(), visible: Span) Error!void {
                            const alphas: ?[]const u8 = if (ctx.command.alpha_idx) |alpha_idx| blk: {
                                const alpha_offset = @as(usize, alpha_idx) +
                                    @as(usize, visible.pixelX() - ctx.command.span.pixelX()) * TILE_HEIGHT;
                                break :blk ctx.alpha_buffer[alpha_offset..];
                            } else null;

                            return ctx.fine.paintFill(visible, ctx.attrs, ctx.resources, alphas);
                        }
                    };

                    // Avoid using the depth buffer if it's trivially skippable,
                    // since it's generally cheaper to not use it at all than to
                    // consult it just to be returned the same span.
                    const ctx = Ctx{
                        .fine = self,
                        .command = paint_fill_cmd,
                        .attrs = attrs,
                        .resources = resources,
                        .alpha_buffer = alpha_buffer,
                    };
                    if (!row.canSkipDepth(span, attrs.draw_id)) {
                        try depth.forEachVisibleRun(span, attrs.draw_id, ctx);
                    } else {
                        try ctx.call(span);
                    }
                },
                .push_buf => |span| try self.pushBuf(span),
                .pop_buf => try self.popBuf(),
                .layer_fill => |layer_fill_cmd| {
                    const attrs = &bucketer.layer_fill_attrs.items[layer_fill_cmd.attrs_idx];
                    const alpha_buffer = resources.alpha_buffers[attrs.thread_idx];

                    const span = layer_fill_cmd.span.intersect(self.buffer_span) orelse return;

                    const Ctx = struct {
                        fine: *Self,
                        command: LayerFill,
                        attrs: *const LayerFillAttrs,
                        rows_y: u16,
                        alpha_buffer: []const u8,

                        pub fn call(ctx: @This(), visible: Span) void {
                            const alphas: ?[]const u8 = if (ctx.command.alpha_idx) |alpha_idx| blk: {
                                const alpha_offset = @as(usize, alpha_idx) +
                                    @as(usize, visible.pixelX() - ctx.command.span.pixelX()) * TILE_HEIGHT;
                                break :blk ctx.alpha_buffer[alpha_offset..];
                            } else null;

                            ctx.fine.layerFill(
                                ctx.rows_y,
                                visible,
                                ctx.attrs.blend_mode,
                                ctx.attrs.opacity,
                                ctx.attrs.mask,
                                alphas,
                            );
                        }
                    };

                    const ctx = Ctx{
                        .fine = self,
                        .command = layer_fill_cmd,
                        .attrs = attrs,
                        .rows_y = row_y,
                        .alpha_buffer = alpha_buffer,
                    };
                    // Same as for paint fills.
                    if (!row.canSkipDepth(span, attrs.draw_id)) {
                        try depth.forEachVisibleRun(span, attrs.draw_id, ctx);
                    } else {
                        ctx.call(span);
                    }
                },
            }
        }

        fn opacity(self: *Self, span: Span, opacity_value: f32) void {
            const range = scratchRange(span);
            const target = self.currentBuffer().items[range.start..range.end];
            const splat: simd.F32x16 = @splat(opacity_value);

            K.applyMask(
                self.level,
                target,
                RepeatNumericVec(K){ .value = K.numericVecFromF32(splat) },
            );
        }

        fn applyMaskLayer(self: *Self, row_y: u16, span: Span, mask: *const Mask) void {
            const x = span.pixelX();
            const width = span.pixelWidth();
            const range = scratchRange(span);
            const target = self.currentBuffer().items[range.start..range.end];

            K.applyMask(self.level, target, SampledMaskIter(K){
                .m = mask,
                .x = x,
                .end_x = x +| width,
                .y = @as(u32, row_y),
            });
        }

        /// Composite the current layer into the parent buffer.
        pub fn layerFill(
            self: *Self,
            row_y: u16,
            span: Span,
            blend_mode: BlendMode,
            opacity_value: f32,
            mask: ?*const Mask,
            alphas: ?[]const u8,
        ) void {
            if (opacity_value != 1.0) {
                self.opacity(span, opacity_value);
            }
            if (mask) |m| {
                self.applyMaskLayer(row_y, span, m);
            }

            const x = span.pixelX();
            const range = scratchRange(span);
            const last = self.blend_buffers.items.len - 1;
            const source = self.blend_buffers.items[last].items[range.start..range.end];
            const target = self.blend_buffers.items[last - 1].items[range.start..range.end];

            if (isDefaultBlendMode(blend_mode)) {
                K.alphaCompositeBuffer(self.level, target, source, alphas);
            } else {
                K.blend(
                    self.level,
                    target,
                    x,
                    row_y,
                    CompositeIter(K).initBuffer(source),
                    blend_mode,
                    alphas,
                    null,
                );
            }
        }

        /// Apply a paint to the current buffer.
        pub fn paintFill(
            self: *Self,
            span: Span,
            attrs: *const PaintFillAttrs,
            resources: FineResources,
            alphas: ?[]const u8,
        ) Error!void {
            self.setPaintOffset(attrs.origin);
            switch (attrs.paint) {
                .solid => |color| self.solidFill(span, color, attrs, alphas),
                .indexed => |index| return self.indexedFill(span, index.index(), attrs, resources, alphas),
            }
        }

        fn solidFill(
            self: *Self,
            span: Span,
            color: PremulColor,
            attrs: *const PaintFillAttrs,
            alphas: ?[]const u8,
        ) void {
            const last = self.blend_buffers.items.len - 1;
            const range = scratchRange(span);

            if (isDefaultBlendMode(attrs.blend_mode) and attrs.mask == null) {
                K.fillSolid(
                    self.level,
                    self.blend_buffers.items[last].items[range.start..range.end],
                    color,
                    alphas,
                );
                return;
            }

            if (span.pixelWidth() == 0) {
                return;
            }

            const x = span.pixelX();
            const extracted = K.extractColor(color);
            K.blend(
                self.level,
                self.blend_buffers.items[last].items[range.start..range.end],
                x,
                self.row_y,
                CompositeIter(K).initSolid(K.compositeFromColor(extracted)),
                attrs.blend_mode,
                alphas,
                attrs.mask,
            );
        }

        /// Dispatch an indexed paint (gradients, images, blurred rounded
        /// rects, filter paints).
        ///
        /// Port of upstream `Fine::indexed_fill`:
        ///
        /// ```text
        /// sample_x = span.x + origin[0]; sample_y = row_y + origin[1];
        /// sampler_x = f64(sample_x) + PIXEL_CENTER_OFFSET;
        /// sampler_y = f64(sample_y) + PIXEL_CENTER_OFFSET;
        /// size paint_buf/f32_buf; select painter; apply/blend.
        /// ```
        ///
        /// Still-deferred kinds (blurred rounded rects, external textures)
        /// return `error.Unsupported` rather than placeholder pixels.
        pub fn indexedFill(
            self: *Self,
            span: Span,
            paint_index: usize,
            attrs: *const PaintFillAttrs,
            resources: FineResources,
            alphas: ?[]const u8,
        ) Error!void {
            // The M2 painters are f32-only; the u8 kernel arrives in M4.
            comptime std.debug.assert(K.Numeric == f32);

            const x = span.pixelX();
            const y = self.row_y;
            const sample_x = @as(u32, x) +| @as(u32, self.origin[0]);
            const sample_y = @as(u32, y) +| @as(u32, self.origin[1]);
            const width = span.pixelWidth();
            const len = @as(usize, width) * TILE_HEIGHT_COMPONENTS;

            // Buffers only ever grow; upstream `Vec::resize(len, ZERO)` fills
            // any newly added values with zeroes.
            if (self.paint_buf.items.len < len) {
                try self.paint_buf.resize(self.allocator, len);
                @memset(self.paint_buf.items, 0);
            }

            const t_len = @as(usize, width) * @as(usize, TILE_HEIGHT);
            if (self.f32_buf.items.len < t_len) {
                try self.f32_buf.resize(self.allocator, t_len);
                @memset(self.f32_buf.items, 0);
            }

            // Indexed paints first address the encoded paints; filter paints
            // (when filter layers land) continue after them.
            const encoded_paint: *const encode_mod.EncodedPaint = if (paint_index < resources.encoded_paints.len)
                &resources.encoded_paints[paint_index]
            else blk: {
                const filter_index = paint_index - resources.encoded_paints.len;
                if (filter_index >= resources.filter_paints.len) return error.InvalidPaintIndex;
                break :blk &resources.filter_paints[filter_index];
            };

            const sampler_x = @as(f64, @floatFromInt(sample_x)) + PIXEL_CENTER_OFFSET;
            const sampler_y = @as(f64, @floatFromInt(sample_y)) + PIXEL_CENTER_OFFSET;

            switch (encoded_paint.*) {
                .gradient => |*gradient| {
                    // The list is only const structurally; the paint itself is
                    // owned by the render context and its LUT is built lazily.
                    const gradient_mut: *encode_mod.EncodedGradient = @constCast(gradient);
                    // Compute all t values first so the position math stays
                    // vectorized, then consume them in the painter.
                    const t_vals = self.f32_buf.items[0..t_len];
                    gradient_mod.computeTVals(gradient_mut, t_vals, sampler_x, sampler_y);
                    var painter = try gradient_mod.GradientPainter.init(
                        gradient_mut,
                        self.allocator,
                        t_vals,
                    );
                    self.applyComplexPaint(
                        span,
                        attrs,
                        alphas,
                        gradient.may_have_transparency,
                        null,
                        &painter,
                    );
                },
                .image => |*image| {
                    // Upstream clones the `Arc<Pixmap>`; this port borrows the
                    // shared handle that travels with the encoded paint and
                    // owns a resolved handle for registered images.
                    var owned_pixmap: ?shared_mod.Shared(Pixmap) = null;
                    defer if (owned_pixmap) |handle| handle.release(self.allocator);

                    const pixmap: *const Pixmap = switch (image.source) {
                        .pixmap => |handle| handle.get(),
                        .opaque_id => |registered| blk: {
                            const handle = resources.image_resolver.resolve(registered.id) orelse
                                return error.MissingImage;
                            owned_pixmap = handle;
                            break :blk handle.get();
                        },
                        // Upstream `unimplemented!`s for external textures.
                        .external_texture => return error.Unsupported,
                    };

                    const tint: ?*const paint_mod.Tint = if (image.tint) |*value| value else null;
                    var painter = image_mod.ImagePainter.init(image, pixmap, sampler_x, sampler_y);
                    self.applyComplexPaint(
                        span,
                        attrs,
                        alphas,
                        image.may_have_transparency,
                        tint,
                        &painter,
                    );
                },
                // Blurred rounded rects belong to the filter/BRR work.
                .blurred_rounded_rect => return error.Unsupported,
            }
        }

        /// Apply a painter's output to the current buffer, mirroring
        /// upstream's `fill_complex_paint!` macro.
        ///
        /// Fully opaque paints with default compositing overwrite the
        /// destination directly; otherwise the painter fills `paint_buf`,
        /// which is tinted when requested and then composited or blended into
        /// the destination.
        fn applyComplexPaint(
            self: *Self,
            span: Span,
            attrs: *const PaintFillAttrs,
            alphas: ?[]const u8,
            may_have_transparency: bool,
            tint: ?*const paint_mod.Tint,
            painter: anytype,
        ) void {
            const len = @as(usize, span.pixelWidth()) * TILE_HEIGHT_COMPONENTS;
            const range = scratchRange(span);
            const dest = self.currentBuffer().items[range.start..range.end];
            const color_buf = self.paint_buf.items[0..len];

            if (may_have_transparency or alphas != null or
                !isDefaultBlendMode(attrs.blend_mode) or attrs.mask != null)
            {
                painter.paint(color_buf);
                if (tint) |value| K.applyTint(self.level, color_buf, value);

                if (isDefaultBlendMode(attrs.blend_mode) and attrs.mask == null) {
                    K.alphaCompositeBuffer(self.level, dest, color_buf, alphas);
                } else {
                    K.blend(
                        self.level,
                        dest,
                        span.pixelX(),
                        self.row_y,
                        CompositeIter(K).initBuffer(color_buf),
                        attrs.blend_mode,
                        alphas,
                        attrs.mask,
                    );
                }
            } else {
                // A fully opaque paint can overwrite the previous values.
                painter.paint(dest);
                if (tint) |value| K.applyTint(self.level, dest, value);
            }
        }
    };
}

/// Rasterize one strip row (`region`) of a bucketed command stream.
///
/// The per-row ordering and layer isolation match upstream `rasterize_region`:
/// opaque depth commands run front-to-back with depth write, uncovered ranges
/// are initialized according to `target_init`, regular commands run
/// back-to-front with depth read, and, when `root_is_blend_target` is set and
/// the row has commands, the background is isolated in the parent buffer and
/// composited at the end.
pub fn rasterizeRegion(
    comptime K: type,
    fine: *Fine(K),
    depth: *DepthBuffer,
    region: *Region,
    bucketer: *const CommandBucketer,
    resources: FineResources,
    target_init: TargetInit,
    root_is_blend_target: bool,
) Error!void {
    const scene_y: u16 = @as(u16, @intCast(region.row_idx)) * TILE_HEIGHT;
    const row = &bucketer.rows()[region.row_idx];
    const span = Span.new(0, region.width);

    fine.setRowY(scene_y);
    depth.clear();

    const has_cmds = row.render_cmds.items.len > 0 or row.depth_cmds.items.len > 0;
    const init_isolates = switch (target_init) {
        .src_over => true,
        .clear => |color| !color.isTransparent(),
    };
    const isolate_bg = root_is_blend_target and has_cmds and init_isolates;

    var effective_target_init = target_init;
    if (isolate_bg) {
        try fine.initUncoveredRange(span, region, target_init, depth);
        try fine.pushBuf(null);

        effective_target_init = TargetInit.initClear(
            PremulColor.fromAlphaColor(peniko.Color.TRANSPARENT),
        );
    }

    // Render depth-buffer commands front-to-back, with depth-buffer read and
    // write.
    var i = row.depth_cmds.items.len;
    while (i > 0) {
        i -= 1;
        const depth_fill_cmd = row.depth_cmds.items[i];
        const attrs = &bucketer.paint_fill_attrs.items[depth_fill_cmd.attrs_idx];

        const Ctx = struct {
            fine: *Fine(K),
            attrs: *const PaintFillAttrs,
            resources: FineResources,

            pub fn call(ctx: @This(), bucket_range: BucketRange) Error!void {
                return ctx.fine.paintFill(bucket_range.span(), ctx.attrs, ctx.resources, null);
            }
        };
        try depth.forEachUnsetRunAndWrite(
            depth_fill_cmd.bucketRange(),
            attrs.draw_id,
            Ctx{ .fine = fine, .attrs = attrs, .resources = resources },
        );
    }

    // Initialize any regions in the fine buffer that haven't been filled with
    // an opaque fill.
    try fine.initUncoveredRange(span, region, effective_target_init, depth);

    // Render the main commands back-to-front, with depth-buffer read.
    for (row.render_cmds.items) |command| {
        try fine.runCmd(command, bucketer, row, scene_y, resources, depth);
    }

    if (isolate_bg) {
        fine.layerFill(scene_y, span, BlendMode.default, 1.0, null, null);
        try fine.popBuf();
    }

    // Pack the composited result back into the pixmap.
    fine.pack(region);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const RectU16 = geometry.RectU16;

fn makeBucketer(allocator: std.mem.Allocator, width: u16, height: u16) !CommandBucketer {
    return CommandBucketer.init(allocator, width, height);
}

fn solidAttrs(color: peniko.Color) PaintFillAttrs {
    return .{
        .paint = paint_mod.Paint.fromAlphaColor(color),
        .blend_mode = BlendMode.default,
        .mask = null,
        .draw_id = 1,
        .thread_idx = 0,
        .origin = .{ 0, 0 },
    };
}

/// Upstream always provides one (possibly empty) alpha buffer per thread; the
/// fine rasterizer indexes it unconditionally even when `alpha_idx` is null.
const empty_alpha_buffers = [_][]const u8{&.{}};
/// Never written through: these tests only exercise solid paints, and the
/// slice is empty.
const empty_paints_storage = [_]encode_mod.EncodedPaint{};
fn emptyResources() FineResources {
    return .{
        .alpha_buffers = &empty_alpha_buffers,
        .encoded_paints = &empty_paints_storage,
        .filter_paints = &empty_paints_storage,
        .image_resolver = paint_mod.NO_OP_IMAGE_RESOLVER,
    };
}

fn rasterize(
    allocator: std.mem.Allocator,
    pixmap: *Pixmap,
    bucketer: *const CommandBucketer,
    target_init: TargetInit,
    root_is_blend_target: bool,
    alpha_buffers: []const []const u8,
) !void {
    var depth = try DepthBuffer.init(allocator, pixmap.width);
    defer depth.deinit(allocator);

    var fine = try Fine(F32Kernel).init(simd.Level.fallback, allocator, pixmap.width);
    defer fine.deinit();

    var pixmap_mut = pixmap.asMut();
    var region = Region.init(&pixmap_mut, RectU16.new(0, 0, pixmap.width, pixmap.height));
    try rasterizeRegion(
        F32Kernel,
        &fine,
        &depth,
        &region,
        bucketer,
        .{
            .alpha_buffers = alpha_buffers,
            .encoded_paints = &empty_paints_storage,
            .filter_paints = &empty_paints_storage,
            .image_resolver = paint_mod.NO_OP_IMAGE_RESOLVER,
        },
        target_init,
        root_is_blend_target,
    );
}

test "pack_unpack_round_trip" {
    const allocator = testing.allocator;
    const width: u16 = 4;
    const height: u16 = 4;
    const scratch_len = COLOR_COMPONENTS * @as(usize, TILE_HEIGHT) * width;

    var scratch: [scratch_len]f32 = undefined;
    for (0..width) |dx| {
        for (0..4) |y| {
            for (0..COLOR_COMPONENTS) |c| {
                const n: u8 = @intCast((dx * 64 + y * 16 + c * 4) % 256);
                scratch[COLOR_COMPONENTS * (4 * dx + y) + c] =
                    @as(f32, @floatFromInt(n)) / 255.0;
            }
        }
    }

    var pixmap = try Pixmap.init(allocator, width, height);
    defer pixmap.deinit(allocator);

    {
        var pixmap_mut = pixmap.asMut();
        var region = Region.init(&pixmap_mut, RectU16.new(0, 0, width, height));
        F32Kernel.pack(simd.Level.fallback, &scratch, width, &region);
    }

    // The packed bytes must be exactly the rounded input values.
    for (0..width) |dx| {
        for (0..4) |y| {
            for (0..COLOR_COMPONENTS) |c| {
                const n: u8 = @intCast((dx * 64 + y * 16 + c * 4) % 256);
                const packed_byte = pixmap.dataAsU8Slice()[4 * (dx + y * width) + c];
                try testing.expectEqual(n, packed_byte);
            }
        }
    }

    var unpacked: [scratch_len]f32 = undefined;
    {
        var pixmap_mut = pixmap.asMut();
        var region = Region.init(&pixmap_mut, RectU16.new(0, 0, width, height));
        F32Kernel.unpack(simd.Level.fallback, &region, width, &unpacked);
    }
    try testing.expectEqualSlices(f32, &scratch, &unpacked);
}

test "rasterize_region_solid_fill_clear_transparent" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 8, 4);
    defer pixmap.deinit(allocator);

    var bucketer = try makeBucketer(allocator, 8, 4);
    defer bucketer.deinit(allocator);

    const color = peniko.Color.fromRgb8(200, 100, 50);
    try bucketer.paint_fill_attrs.append(allocator, solidAttrs(color));
    try bucketer.row_states.items[0].pushCmd(allocator, .{
        .paint_fill = PaintFill.new(Span.new(0, 8), null, 0),
    });

    try rasterize(
        allocator,
        &pixmap,
        &bucketer,
        TargetInit.initClear(PremulColor.fromAlphaColor(peniko.Color.TRANSPARENT)),
        false,
        &empty_alpha_buffers,
    );

    const expected = PremulColor.fromAlphaColor(color).asPremulRgba8();
    for (0..8) |x| {
        for (0..4) |y| {
            try testing.expectEqual(expected, pixmap.sample(@intCast(x), @intCast(y)));
        }
    }
}

test "rasterize_region_solid_fill_src_over_existing" {
    const allocator = testing.allocator;

    var pixmap = try Pixmap.init(allocator, 8, 4);
    defer pixmap.deinit(allocator);
    // Existing target: opaque blue.
    for (pixmap.dataMut()) |*pixel| {
        pixel.* = PremulColor.fromAlphaColor(peniko.Color.fromRgb8(0, 0, 255)).asPremulRgba8();
    }

    var bucketer = try makeBucketer(allocator, 8, 4);
    defer bucketer.deinit(allocator);

    // 50% alpha red over blue: src + bg * (1 - src_a).
    const color = peniko.Color.fromRgb8(255, 0, 0).multiplyAlpha(0.5);
    try bucketer.paint_fill_attrs.append(allocator, solidAttrs(color));
    try bucketer.row_states.items[0].pushCmd(allocator, .{
        .paint_fill = PaintFill.new(Span.new(0, 8), null, 0),
    });

    try rasterize(allocator, &pixmap, &bucketer, TargetInit.DEFAULT, false, &empty_alpha_buffers);

    const pixel = pixmap.sample(3, 2);
    try testing.expectEqual(@as(u8, 128), pixel.r);
    try testing.expectEqual(@as(u8, 0), pixel.g);
    try testing.expectEqual(@as(u8, 128), pixel.b);
    try testing.expectEqual(@as(u8, 255), pixel.a);
}

test "rasterize_region_blend_multiply" {
    const allocator = testing.allocator;

    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    for (pixmap.dataMut()) |*pixel| {
        pixel.* = PremulColor.fromAlphaColor(peniko.Color.fromRgb8(255, 128, 64)).asPremulRgba8();
    }

    var bucketer = try makeBucketer(allocator, 4, 4);
    defer bucketer.deinit(allocator);

    const color = peniko.Color.fromRgb8(128, 255, 255);
    var attrs = solidAttrs(color);
    attrs.blend_mode = BlendMode.from(peniko.Mix.multiply);
    try bucketer.paint_fill_attrs.append(allocator, attrs);
    try bucketer.row_states.items[0].pushCmd(allocator, .{
        .paint_fill = PaintFill.new(Span.new(0, 4), null, 0),
    });

    try rasterize(allocator, &pixmap, &bucketer, TargetInit.DEFAULT, false, &empty_alpha_buffers);

    // Opaque source + opaque backdrop with `multiply` yields the
    // component-wise product.
    const pixel = pixmap.sample(0, 0);
    const expected_r: u8 = @intFromFloat(255.0 * 128.0 / 255.0 + 0.5);
    const expected_g: u8 = @intFromFloat(128.0 * 255.0 / 255.0 + 0.5);
    const expected_b: u8 = @intFromFloat(64.0 * 255.0 / 255.0 + 0.5);
    try testing.expectEqual(expected_r, pixel.r);
    try testing.expectEqual(expected_g, pixel.g);
    try testing.expectEqual(expected_b, pixel.b);
    try testing.expectEqual(@as(u8, 255), pixel.a);
}

test "rasterize_region_isolates_blend_target_background" {
    const allocator = testing.allocator;

    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    var bucketer = try makeBucketer(allocator, 4, 4);
    defer bucketer.deinit(allocator);

    // A 50% layer over an opaque clear color: isolate the background, then
    // composite the layer with src-over, which must reproduce normal
    // composition.
    const background = peniko.Color.fromRgb8(0, 200, 0);
    const color = peniko.Color.fromRgb8(255, 0, 0).multiplyAlpha(0.5);
    try bucketer.paint_fill_attrs.append(allocator, solidAttrs(color));
    try bucketer.row_states.items[0].pushCmd(allocator, .{
        .paint_fill = PaintFill.new(Span.new(0, 4), null, 0),
    });

    try rasterize(
        allocator,
        &pixmap,
        &bucketer,
        TargetInit.initClear(PremulColor.fromAlphaColor(background)),
        true,
        &empty_alpha_buffers,
    );

    // Opaque green background under 50% red: src + bg * 0.5.
    const pixel = pixmap.sample(0, 0);
    try testing.expectEqual(@as(u8, 128), pixel.r);
    try testing.expectEqual(@as(u8, 100), pixel.g);
    try testing.expectEqual(@as(u8, 0), pixel.b);
    try testing.expectEqual(@as(u8, 255), pixel.a);
}

test "rasterize_region_layer_opacity" {
    const allocator = testing.allocator;

    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    var bucketer = try makeBucketer(allocator, 4, 4);
    defer bucketer.deinit(allocator);

    const color = peniko.Color.fromRgb8(255, 0, 0);
    try bucketer.paint_fill_attrs.append(allocator, solidAttrs(color));

    const layer_attrs = LayerFillAttrs{
        .blend_mode = BlendMode.default,
        .opacity = 0.5,
        .mask = null,
        .draw_id = 2,
        .thread_idx = 0,
    };
    try bucketer.layer_fill_attrs.append(allocator, layer_attrs);

    const row = &bucketer.row_states.items[0];
    try row.pushBuf(allocator);
    try row.pushCmd(allocator, .{ .paint_fill = PaintFill.new(Span.new(0, 4), null, 0) });
    try row.pushCmd(allocator, .{ .layer_fill = LayerFill.new(Span.new(0, 4), null, 0) });
    try row.popBuf(allocator);

    try rasterize(
        allocator,
        &pixmap,
        &bucketer,
        TargetInit.initClear(PremulColor.fromAlphaColor(peniko.Color.TRANSPARENT)),
        false,
        &empty_alpha_buffers,
    );

    // The layer's red is scaled by 0.5, then composed over transparent black.
    // Note that the opaque fill inside the layer is written to a transparent
    // child buffer, so the layer fill sees it as one unit.
    const pixel = pixmap.sample(0, 0);
    try testing.expectEqual(@as(u8, 128), pixel.r);
    try testing.expectEqual(@as(u8, 0), pixel.g);
    try testing.expectEqual(@as(u8, 0), pixel.b);
    try testing.expectEqual(@as(u8, 128), pixel.a);
}

test "rasterize_region_depth_commands_render_front_to_back" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 256, 4);
    defer pixmap.deinit(allocator);

    var bucketer = try makeBucketer(allocator, 256, 4);
    defer bucketer.deinit(allocator);

    // Red (back, draw 1) covers both depth buckets; blue (front, draw 2)
    // covers bucket 1 only. Rendering front-to-back must skip the red fill
    // where blue has already written depth.
    var red_attrs = solidAttrs(peniko.Color.fromRgb8(255, 0, 0));
    red_attrs.draw_id = 1;
    var blue_attrs = solidAttrs(peniko.Color.fromRgb8(0, 0, 255));
    blue_attrs.draw_id = 2;
    try bucketer.paint_fill_attrs.append(allocator, red_attrs);
    try bucketer.paint_fill_attrs.append(allocator, blue_attrs);

    const row = &bucketer.row_states.items[0];
    try row.pushDepthFill(
        allocator,
        coarse.DepthFill.new(coarse.BucketRange.new(0, 2), 0),
        1,
    );
    try row.pushDepthFill(
        allocator,
        coarse.DepthFill.new(coarse.BucketRange.new(1, 2), 1),
        2,
    );

    try rasterize(
        allocator,
        &pixmap,
        &bucketer,
        TargetInit.initClear(PremulColor.fromAlphaColor(peniko.Color.TRANSPARENT)),
        false,
        &empty_alpha_buffers,
    );

    const red = pixmap.sample(0, 0);
    try testing.expectEqual(@as(u8, 255), red.r);
    try testing.expectEqual(@as(u8, 0), red.b);

    const blue = pixmap.sample(200, 0);
    try testing.expectEqual(@as(u8, 0), blue.r);
    try testing.expectEqual(@as(u8, 255), blue.b);
}

test "indexed fill without an encoded paint fails explicitly" {
    const allocator = testing.allocator;
    var fine = try Fine(F32Kernel).init(simd.Level.fallback, allocator, 4);
    defer fine.deinit();

    const attrs = PaintFillAttrs{
        .paint = .{ .indexed = try paint_mod.IndexedPaint.new(0) },
        .blend_mode = BlendMode.default,
        .mask = null,
        .draw_id = 1,
        .thread_idx = 0,
        .origin = .{ 0, 0 },
    };
    // No encoded paints and no filter paints: the index cannot be resolved.
    try testing.expectError(
        error.InvalidPaintIndex,
        fine.paintFill(Span.new(0, 4), &attrs, emptyResources(), null),
    );
}
