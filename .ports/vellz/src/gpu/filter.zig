//! Port of `vello_gpu/src/filter.rs` (layout subset) (Apache-2.0 OR MIT).
//!
//! Filter parameter blocks are exactly 48 bytes (three `RGBA32Uint` texels)
//! and the instance stride is 36 bytes. This file carries the structs, the
//! header bit layout, the filter/pass-kind discriminants, and the
//! `FILTER_ATLAS_PADDING` constant; the `PreparedFilter` -> parameter-block
//! conversions and the pass planner land with T4/T5 and must not change these
//! layouts. See `docs/shader-interface.md` §4.

const std = @import("std");
const common = @import("../common/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const copy_mod = @import("copy.zig");
const target_mod = @import("target.zig");

/// Maximum size of the gaussian kernel (odd, ≤ `u8::MAX`); re-exported from
/// the CPU-side filter model so both sides always agree.
pub const MAX_KERNEL_SIZE: usize = common.filter.MAX_KERNEL_SIZE;

/// Maximum number of linear-sampling tap pairs per side
/// (`(MAX_KERNEL_SIZE / 2).div_ceil(2)`).
pub const MAX_TAPS_PER_SIDE: usize = (MAX_KERNEL_SIZE / 2 + 1) / 2;

/// Transparent padding reserved for filter layers, so shaders can assume
/// transparent pixels outside the layer (`MAX_KERNEL_SIZE / 2`).
pub const FILTER_ATLAS_PADDING: u16 = MAX_KERNEL_SIZE / 2;

/// Size of every filter parameter block in bytes.
pub const FILTER_SIZE_BYTES: usize = 48;
/// Size of every filter parameter block in `u32` words.
pub const FILTER_SIZE_U32: usize = FILTER_SIZE_BYTES / 4;
/// Texels occupied by one filter parameter block in an `RGBA32Uint` texture.
pub const FILTER_SIZE_TEXELS: u32 = FILTER_SIZE_BYTES / 16;
/// Header bit 13: composite the original input over the shadow.
pub const COMPOSITE_ORIGINAL_SHIFT: u32 = 13;
/// Header bit 13 as a mask.
pub const COMPOSITE_ORIGINAL_MASK: u32 = 1 << COMPOSITE_ORIGINAL_SHIFT;

/// Header bits 0–3: filter type.
pub const filter_type = struct {
    pub const OFFSET: u32 = 0;
    pub const FLOOD: u32 = 1;
    pub const GAUSSIAN_BLUR: u32 = 2;
    pub const DROP_SHADOW: u32 = 3;
};

/// Header bits 5–6: edge mode.
pub const edge_mode = struct {
    pub const DUPLICATE: u32 = 0;
    pub const WRAP: u32 = 1;
    pub const MIRROR: u32 = 2;
    pub const NONE: u32 = 3;
};

/// `filter_pass_kind` discriminants.
pub const pass_kind = struct {
    pub const COPY: u32 = 0;
    pub const FLOOD: u32 = 1;
    pub const OFFSET: u32 = 2;
    pub const DOWNSCALE: u32 = 3;
    pub const BLUR_H: u32 = 4;
    pub const BLUR_V: u32 = 5;
    pub const UPSCALE: u32 = 6;
    pub const COMPOSITE_DROP_SHADOW: u32 = 7;
    pub const COLORIZE: u32 = 8;
};

/// The CPU edge mode as a GPU header value (upstream `edge_mode_to_gpu`).
pub fn edgeModeToGpu(mode: common.filter_effects.EdgeMode) u32 {
    return switch (mode) {
        .duplicate => edge_mode.DUPLICATE,
        .wrap => edge_mode.WRAP,
        .mirror => edge_mode.MIRROR,
        .none => edge_mode.NONE,
    };
}

/// Pack a filter header with only the filter type (offset/flood).
pub fn packHeader(filter_type_value: u32) u32 {
    std.debug.assert(filter_type_value <= 31);
    return filter_type_value;
}

/// Pack a header with the gaussian parameters in bits 5–12.
///
/// `edge_mode` occupies bits 5–6, `n_decimations` bits 7–10, and
/// `n_linear_taps` bits 11–12, leaving bit 13 free for `COMPOSITE_ORIGINAL`.
pub fn packHeaderWithGaussianParams(
    filter_type_value: u32,
    edge: u32,
    n_decimations: u32,
    n_linear_taps: u32,
) u32 {
    std.debug.assert(filter_type_value <= 31);
    std.debug.assert(edge <= 3);
    std.debug.assert(n_decimations <= 15);
    std.debug.assert(n_linear_taps <= 3);
    return filter_type_value | (edge << 5) | (n_decimations << 7) | (n_linear_taps << 11);
}

comptime {
    // The gaussian fields must never overlap the composite-original bit.
    if (packHeaderWithGaussianParams(31, 3, 15, 3) & COMPOSITE_ORIGINAL_MASK != 0) {
        @compileError("gaussian filter parameters overlap the composite_original bit");
    }
}

/// A filter parameter block in its wire form. Every concrete `Gpu*` block
/// below is 48 bytes, so they can be cast into this type for upload.
///
/// Upstream assumes a uniform stride for all filter blocks; variable offsets
/// may be explored later but are not part of the contract.
pub const GpuFilterData = extern struct {
    /// Raw 48-byte block (`12` `u32` words).
    data: [FILTER_SIZE_U32]u32 align(16),

    /// The filter type encoded in header bits 0–3.
    pub fn filterType(self: *const GpuFilterData) u32 {
        return self.data[0] & 0x1F;
    }

    /// The number of decimation levels encoded in header bits 7–10.
    pub fn nDecimations(self: *const GpuFilterData) usize {
        return (self.data[0] >> 7) & 0xF;
    }

    /// Whether the composite-original bit is set.
    pub fn compositeOriginal(self: *const GpuFilterData) bool {
        return self.data[0] & COMPOSITE_ORIGINAL_MASK != 0;
    }

    /// Drop shadows with `composite_original` need the original layer kept
    /// around and composited on top of the shadow.
    pub fn needsCopyPass(self: *const GpuFilterData) bool {
        return self.filterType() == filter_type.DROP_SHADOW and self.compositeOriginal();
    }
};

comptime {
    if (@sizeOf(GpuFilterData) != FILTER_SIZE_BYTES) {
        @compileError("GpuFilterData must be exactly 48 bytes");
    }
    if (@alignOf(GpuFilterData) != 16) {
        @compileError("GpuFilterData must be 16-byte aligned");
    }
}

/// Offset filter parameters (48 bytes).
pub const GpuOffset = extern struct {
    header: u32 align(16),
    dx: f32,
    dy: f32,
    _padding: [9]u32,
};

/// Flood filter parameters (48 bytes).
pub const GpuFlood = extern struct {
    header: u32 align(16),
    color: u32,
    _padding: [10]u32,
};

/// Gaussian blur filter parameters (48 bytes).
pub const GpuGaussianBlur = extern struct {
    header: u32 align(16),
    center_weight: f32,
    linear_weights: [MAX_TAPS_PER_SIDE]f32,
    linear_offsets: [MAX_TAPS_PER_SIDE]f32,
    // Needed because the drop shadow block has a bigger footprint.
    _padding: [4]u32,
};

/// Drop shadow filter parameters (48 bytes).
pub const GpuDropShadow = extern struct {
    header: u32 align(16),
    center_weight: f32,
    linear_weights: [MAX_TAPS_PER_SIDE]f32,
    linear_offsets: [MAX_TAPS_PER_SIDE]f32,
    dx: f32,
    dy: f32,
    color: u32,
    _padding: [1]u32,
};

/// Per-instance filter pass data (36 bytes, nine `Uint32` attributes at shader
/// locations 0–8, instance step mode).
pub const FilterInstanceData = extern struct {
    /// Origin of the current ping-pong source region, packed as `u16x2`.
    source_origin: u32,
    /// Size of the source region, packed as `u16x2`.
    source_size: u32,
    /// Origin of the opposite ping-pong destination region, packed as `u16x2`.
    dest_origin: u32,
    /// Size of the destination region, packed as `u16x2`.
    dest_size: u32,
    /// Dimensions of the destination texture page, packed as `u16x2`.
    dest_texture_size: u32,
    /// Texel offset into `filter_data` where this filter's data is stored.
    filter_data_offset: u32,
    /// Origin of the original region, packed as `u16x2`.
    original_origin: u32,
    /// Size of the original region, packed as `u16x2`.
    original_size: u32,
    /// The filter pass that should be executed (see `pass_kind`).
    filter_pass_kind: u32,
};

comptime {
    const blocks = .{
        .{ GpuOffset, 48 },
        .{ GpuFlood, 48 },
        .{ GpuGaussianBlur, 48 },
        .{ GpuDropShadow, 48 },
    };
    for (blocks) |entry| {
        if (@sizeOf(entry[0]) != entry[1]) {
            @compileError(@typeName(entry[0]) ++ " must be exactly 48 bytes");
        }
        if (@alignOf(entry[0]) != 16) {
            @compileError(@typeName(entry[0]) ++ " must be 16-byte aligned");
        }
    }
    if (@sizeOf(FilterInstanceData) != 36) {
        @compileError("FilterInstanceData must be exactly 36 bytes");
    }
    if (@offsetOf(GpuGaussianBlur, "linear_weights") != 8 or
        @offsetOf(GpuGaussianBlur, "linear_offsets") != 20 or
        @offsetOf(GpuGaussianBlur, "_padding") != 32)
    {
        @compileError("GpuGaussianBlur field offsets diverged from the shader contract");
    }
    if (@offsetOf(GpuDropShadow, "dx") != 32 or
        @offsetOf(GpuDropShadow, "dy") != 36 or
        @offsetOf(GpuDropShadow, "color") != 40 or
        @offsetOf(GpuDropShadow, "_padding") != 44)
    {
        @compileError("GpuDropShadow field offsets diverged from the shader contract");
    }
    for (.{ "source_origin", "source_size", "dest_origin", "dest_size", "dest_texture_size", "filter_data_offset", "original_origin", "original_size", "filter_pass_kind" }, 0..) |name, i| {
        if (@offsetOf(FilterInstanceData, name) != i * 4) {
            @compileError("FilterInstanceData field offsets diverged from the shader contract");
        }
    }
}

// ---------------------------------------------------------------------------
// `PreparedFilter` -> parameter-block conversions (upstream `filter.rs`)
// ---------------------------------------------------------------------------

/// A linear-sampling kernel derived from a discrete Gaussian kernel.
///
/// Pairs of adjacent texels are merged into one bilinear tap so each pass
/// samples half as many times; see the linked article in the upstream source.
pub const LinearKernel = struct {
    /// Weight of the center tap.
    center_weight: f32,
    /// Merged weights for each tap pair (first `n_taps` entries valid).
    weights: [MAX_TAPS_PER_SIDE]f32,
    /// Fractional offsets for each tap pair (first `n_taps` entries valid).
    offsets: [MAX_TAPS_PER_SIDE]f32,
    /// The actual number of taps per side.
    n_taps: u8,

    /// Build a linear-sampling kernel from a discrete Gaussian kernel.
    pub fn init(kernel: *const [common.filter.MAX_KERNEL_SIZE]f32, kernel_size: u8) LinearKernel {
        const size: usize = kernel_size;
        const radius = size / 2;
        var result = LinearKernel{
            .center_weight = kernel[radius],
            .weights = @splat(0.0),
            .offsets = @splat(0.0),
            .n_taps = 0,
        };

        // The kernel is symmetric; only the positive side is processed.
        var k: usize = 0;
        while (radius + 1 + 2 * k + 1 < size) : (k += 1) {
            const w1 = kernel[radius + 1 + 2 * k];
            const w2 = kernel[radius + 1 + 2 * k + 1];
            const merged_weight = w1 + w2;
            const offset1: f32 = @floatFromInt(2 * k + 1);
            const merged_offset = if (merged_weight > 0.0)
                (w1 * offset1 + w2 * (offset1 + 1.0)) / merged_weight
            else
                offset1;
            result.weights[result.n_taps] = merged_weight;
            result.offsets[result.n_taps] = merged_offset;
            result.n_taps += 1;
        }

        // A leftover tap samples a single pixel with no fractional offset.
        if (radius + 1 + 2 * k < size) {
            result.weights[result.n_taps] = kernel[radius + 1 + 2 * k];
            result.offsets[result.n_taps] = @floatFromInt(radius);
            result.n_taps += 1;
        }
        return result;
    }
};

/// Pack two `u16` values with the first in the low half, matching the
/// shaders' `u16x2` unpack order (`x | y << 16`; upstream `pack_u16_pair`).
pub fn packU16Pair(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

const testing = std.testing;

/// Build a `GpuOffset` block from an offset filter.
pub fn gpuOffsetFrom(offset: *const common.filter.Offset) GpuOffset {
    return .{
        .header = packHeader(filter_type.OFFSET),
        .dx = offset.dx,
        .dy = offset.dy,
        ._padding = @splat(0),
    };
}

/// Build a `GpuFlood` block from a flood filter.
pub fn gpuFloodFrom(flood: *const common.filter.Flood) GpuFlood {
    return .{
        .header = packHeader(filter_type.FLOOD),
        .color = flood.color.premultiply().toRgba8().toU32(),
        ._padding = @splat(0),
    };
}

/// Build a `GpuGaussianBlur` block from a prepared gaussian blur.
pub fn gpuGaussianBlurFrom(blur: *const common.filter.GaussianBlur) GpuGaussianBlur {
    const kernel = LinearKernel.init(&blur.kernel, blur.kernel_size);
    return .{
        .header = packHeaderWithGaussianParams(
            filter_type.GAUSSIAN_BLUR,
            edgeModeToGpu(blur.edge_mode),
            @intCast(blur.n_decimations),
            kernel.n_taps,
        ),
        .center_weight = kernel.center_weight,
        .linear_weights = kernel.weights,
        .linear_offsets = kernel.offsets,
        ._padding = @splat(0),
    };
}

/// Build a `GpuDropShadow` block from a prepared drop shadow.
pub fn gpuDropShadowFrom(shadow: *const common.filter.DropShadow) GpuDropShadow {
    const kernel = LinearKernel.init(&shadow.kernel, shadow.kernel_size);
    const composite_original: u32 = if (shadow.composite_original) COMPOSITE_ORIGINAL_MASK else 0;
    return .{
        .header = packHeaderWithGaussianParams(
            filter_type.DROP_SHADOW,
            edgeModeToGpu(shadow.edge_mode),
            @intCast(shadow.n_decimations),
            kernel.n_taps,
        ) | composite_original,
        .center_weight = kernel.center_weight,
        .linear_weights = kernel.weights,
        .linear_offsets = kernel.offsets,
        .dx = shadow.dx,
        .dy = shadow.dy,
        .color = shadow.color.premultiply().toRgba8().toU32(),
        ._padding = @splat(0),
    };
}

/// Convert a prepared filter into its type-erased 48-byte block.
pub fn gpuFilterDataFrom(prepared: *const common.filter.PreparedFilter) GpuFilterData {
    var data: GpuFilterData = undefined;
    switch (prepared.*) {
        .offset => |*offset| {
            const block = gpuOffsetFrom(offset);
            @memcpy(std.mem.asBytes(&data), std.mem.asBytes(&block));
        },
        .flood => |*flood| {
            const block = gpuFloodFrom(flood);
            @memcpy(std.mem.asBytes(&data), std.mem.asBytes(&block));
        },
        .gaussian_blur => |*blur| {
            const block = gpuGaussianBlurFrom(blur);
            @memcpy(std.mem.asBytes(&data), std.mem.asBytes(&block));
        },
        .drop_shadow => |*shadow| {
            const block = gpuDropShadowFrom(shadow);
            @memcpy(std.mem.asBytes(&data), std.mem.asBytes(&block));
        },
    }
    return data;
}

/// Context tracking filter blocks accumulated while scheduling a scene.
pub const FilterContext = struct {
    /// Encoded filter parameter blocks, in offset order.
    filters: std.ArrayList(GpuFilterData) = .empty,

    /// Release the parameter blocks.
    pub fn deinit(self: *FilterContext, allocator: std.mem.Allocator) void {
        self.filters.deinit(allocator);
        self.* = undefined;
    }

    /// Drop all parameter blocks, keeping capacity.
    pub fn clear(self: *FilterContext) void {
        self.filters.clearRetainingCapacity();
    }

    /// Encode `filter_data` and return its offset block.
    ///
    /// Upstream panics on an unsupported filter shape; this port returns
    /// `error.Unsupported`.
    pub fn push(
        self: *FilterContext,
        allocator: std.mem.Allocator,
        filter_data: *const common.filter.FilterData,
    ) (std.mem.Allocator.Error || error{Unsupported})!PreparedGpuFilter {
        const data_offset = self.totalTexels();
        const prepared = common.filter.PreparedFilter.new(
            &filter_data.filter,
            filter_data.transform,
        ) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
        };
        const data = gpuFilterDataFrom(&prepared);
        try self.filters.append(allocator, data);
        return .{ .data_offset = data_offset, .data = data };
    }

    /// Whether no filters have been encoded.
    pub fn isEmpty(self: *const FilterContext) bool {
        return self.filters.items.len == 0;
    }

    /// Total number of `RGBA32Uint` texels occupied by the parameter blocks.
    pub fn totalTexels(self: *const FilterContext) u32 {
        return @intCast(self.filters.items.len * FILTER_SIZE_TEXELS);
    }

    /// Serialize the blocks into `buffer` (which must be large enough).
    pub fn serializeToBuffer(self: *const FilterContext, buffer: []u8) void {
        const src = std.mem.sliceAsBytes(self.filters.items);
        std.debug.assert(buffer.len >= src.len);
        @memcpy(buffer[0..src.len], src);
    }

    /// Required height for the filter data texture, or `null` when empty.
    pub fn requiredFilterDataHeight(self: *const FilterContext, resource_dimension: u32) ?u32 {
        const required_texels = self.totalTexels();
        if (required_texels == 0) return null;
        return (required_texels + resource_dimension - 1) / resource_dimension;
    }
};

/// Offset and encoded parameters for one filter recorded in `FilterContext`.
pub const PreparedGpuFilter = struct {
    /// Texel offset of the parameter block in the filter data texture.
    data_offset: u32,
    /// Encoded filter parameters.
    data: GpuFilterData,
};

/// Concrete filter-execution plan for a batch of scheduled filters.
pub const FilterPassPlan = struct {
    /// Copies preserving original layer contents in the shared scratch texture.
    copy_pass: std.ArrayList(copy_mod.GpuCopyInstance) = .empty,
    /// Filter instances grouped by their index in each filter's pass sequence.
    steps: std.ArrayList(std.ArrayList(FilterInstanceData)) = .empty,

    /// Release the plan's storage.
    pub fn deinit(self: *FilterPassPlan, allocator: std.mem.Allocator) void {
        for (self.steps.items) |*step| step.deinit(allocator);
        self.steps.deinit(allocator);
        self.copy_pass.deinit(allocator);
        self.* = undefined;
    }

    /// Rebuild the plan for `filters`.
    pub fn init(
        self: *FilterPassPlan,
        allocator: std.mem.Allocator,
        filters: []const FilterOp,
        texture_size: common.geometry.SizeU16,
    ) std.mem.Allocator.Error!void {
        self.clear();
        for (filters) |filter| {
            var builder = FilterPassBuilder{
                .op = filter,
                .texture_size = texture_size,
                .passes = self,
                .sizer = common.filter.DecimationSizer.init(
                    filter.textures.original.rect.width(),
                    filter.textures.original.rect.height(),
                ),
                .current_is_original = true,
                .step = 0,
            };
            if (filter.gpu_filter.needsCopyPass()) {
                try builder.pushCopyToScratchPass(allocator);
            }
            switch (filter.gpu_filter.filterType()) {
                filter_type.OFFSET => try builder.emit(allocator, pass_kind.OFFSET),
                filter_type.FLOOD => try builder.emit(allocator, pass_kind.FLOOD),
                filter_type.GAUSSIAN_BLUR => try builder.emitBlurSequence(allocator, filter.gpu_filter.nDecimations()),
                filter_type.DROP_SHADOW => {
                    try builder.emit(allocator, pass_kind.OFFSET);
                    try builder.emitBlurSequence(allocator, filter.gpu_filter.nDecimations());
                    if (filter.gpu_filter.compositeOriginal()) {
                        try builder.emit(allocator, pass_kind.COMPOSITE_DROP_SHADOW);
                    } else {
                        try builder.emit(allocator, pass_kind.COLORIZE);
                    }
                },
                else => unreachable, // unsupported filter types are never encoded
            }
            try builder.ensureResultInOriginal(allocator);
        }
    }

    /// The filter instances for each pass step.
    pub fn stepItems(self: *const FilterPassPlan, step: usize) []const FilterInstanceData {
        return self.steps.items[step].items;
    }

    /// Number of pass steps.
    pub fn stepCount(self: *const FilterPassPlan) usize {
        return self.steps.items.len;
    }

    /// The copy-to-scratch instances, or `null` when no copy is planned.
    pub fn copyPass(self: *const FilterPassPlan) ?[]const copy_mod.GpuCopyInstance {
        return if (self.copy_pass.items.len == 0) null else self.copy_pass.items;
    }

    /// Drop all planned passes, keeping capacity.
    pub fn clear(self: *FilterPassPlan) void {
        for (self.steps.items) |*step| step.clearRetainingCapacity();
        self.copy_pass.clearRetainingCapacity();
    }

    fn stepMut(self: *FilterPassPlan, allocator: std.mem.Allocator, step: usize) std.mem.Allocator.Error!*std.ArrayList(FilterInstanceData) {
        while (self.steps.items.len <= step) {
            try self.steps.append(allocator, .empty);
        }
        return &self.steps.items[step];
    }
};

/// Expands one scheduled filter into entries in a shared `FilterPassPlan`.
pub const FilterPassBuilder = struct {
    /// Scheduled filter and its original/temporary texture regions.
    op: FilterOp,
    /// Full dimensions of the intermediate texture pages.
    texture_size: common.geometry.SizeU16,
    /// The filter pass plan being written into.
    passes: *FilterPassPlan,
    /// Tracks dimensions through blur downscaling and upscaling.
    sizer: common.filter.DecimationSizer,
    /// Whether the next pass reads from the original region.
    current_is_original: bool,
    /// Index of the next pass in this filter's sequence.
    step: usize,

    /// Emit one pass, reading from the current region and writing to the other.
    pub fn emit(self: *FilterPassBuilder, allocator: std.mem.Allocator, kind: u32) std.mem.Allocator.Error!void {
        const sizes = self.applyPassDimensions(kind);
        const original = self.op.textures.original;
        const temporary = self.op.textures.temporary;
        const rects: [2]common.geometry.RectU16 = if (self.current_is_original)
            .{ original.rect, temporary.rect }
        else
            .{ temporary.rect, original.rect };
        const source_rect = rects[0];
        const dest_rect = rects[1];
        const dest_texture_size = self.texture_size;

        const step = try self.passes.stepMut(allocator, self.step);
        try step.append(allocator, .{
            .source_origin = packU16Pair(source_rect.x0, source_rect.y0),
            .source_size = packU16Pair(sizes[0].width(), sizes[0].height()),
            .dest_origin = packU16Pair(dest_rect.x0, dest_rect.y0),
            .dest_size = packU16Pair(sizes[1].width(), sizes[1].height()),
            .dest_texture_size = packU16Pair(dest_texture_size.width(), dest_texture_size.height()),
            .filter_data_offset = self.op.filter_data_offset,
            .original_origin = packU16Pair(original.rect.x0, original.rect.y0),
            .original_size = packU16Pair(original.rect.width(), original.rect.height()),
            .filter_pass_kind = kind,
        });
        self.step += 1;
        self.current_is_original = !self.current_is_original;
    }

    /// Emit the full Gaussian blur sequence for `n_decimations`.
    pub fn emitBlurSequence(self: *FilterPassBuilder, allocator: std.mem.Allocator, n_decimations: usize) std.mem.Allocator.Error!void {
        for (0..n_decimations) |_| try self.emit(allocator, pass_kind.DOWNSCALE);
        try self.emit(allocator, pass_kind.BLUR_H);

        var final_pass: u32 = pass_kind.BLUR_V;
        if (n_decimations > 0) {
            try self.emit(allocator, pass_kind.BLUR_V);
            for (0..n_decimations - 1) |_| try self.emit(allocator, pass_kind.UPSCALE);
            final_pass = pass_kind.UPSCALE;
        }
        try self.emit(allocator, final_pass);
    }

    /// Emit a copy pass if the result ended up in the temporary region.
    pub fn ensureResultInOriginal(self: *FilterPassBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (!self.current_is_original) try self.emit(allocator, pass_kind.COPY);
    }

    /// Preserve the unfiltered original layer in the shared scratch texture.
    pub fn pushCopyToScratchPass(self: *FilterPassBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        const original = self.op.textures.original;
        const dest_texture_size = self.texture_size;
        try self.passes.copy_pass.append(allocator, .{
            .dest_texture_origin = packU16Pair(original.rect.x0, original.rect.y0),
            .source_texture_origin = packU16Pair(original.rect.x0, original.rect.y0),
            .copy_rect_size = packU16Pair(original.rect.width(), original.rect.height()),
            .dest_texture_size = packU16Pair(dest_texture_size.width(), dest_texture_size.height()),
        });
    }

    fn applyPassDimensions(self: *FilterPassBuilder, kind: u32) [2]common.geometry.SizeU16 {
        const SizeU16 = common.geometry.SizeU16;
        switch (kind) {
            pass_kind.DOWNSCALE => {
                const current = self.sizer.current();
                const next = self.sizer.downscale();
                return .{ SizeU16.from(current), SizeU16.from(next) };
            },
            pass_kind.UPSCALE => {
                const current = self.sizer.current();
                const next = self.sizer.upscale();
                return .{ SizeU16.from(current), SizeU16.from(next) };
            },
            else => {
                const current = self.sizer.current();
                const value = SizeU16.from(current);
                return .{ value, value };
            },
        }
    }
};

/// Round-bindings-free filter operation: parameter offsets plus texture regions.
pub const FilterTextureRegions = struct {
    /// Region containing the input and final filtered result.
    original: target_mod.TextureRegion,
    /// Opposite-parity region used for intermediate passes.
    temporary: target_mod.TextureRegion,

    /// Create new regions.
    pub fn new(original: target_mod.TextureRegion, temporary: target_mod.TextureRegion) FilterTextureRegions {
        return .{ .original = original, .temporary = temporary };
    }

    /// The bindings required by this filter operation.
    pub fn roundBindings(self: FilterTextureRegions) target_mod.RoundBindings {
        return target_mod.RoundBindings.new(self.original.target)
            .merge(target_mod.RoundBindings.new(self.temporary.target)).?;
    }
};

/// A scheduled filter and the texture regions on which it operates.
pub const FilterOp = struct {
    /// Original and temporary regions used by the filter passes.
    textures: FilterTextureRegions,
    /// Texel offset of this filter's parameters in the filter data texture.
    filter_data_offset: u32,
    /// Prepared filter parameters used to select and size passes.
    gpu_filter: GpuFilterData,
};

test "linear kernel merges taps" {
    const kernel = common.filter.computeGaussianKernel(2.0);
    const linear = LinearKernel.init(&kernel.kernel, kernel.kernel_size);
    try std.testing.expectEqual(@as(u8, 3), linear.n_taps);
    var sum = linear.center_weight;
    for (0..linear.n_taps) |i| sum += 2.0 * linear.weights[i];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);

    const identity = common.filter.planDecimatedBlur(0.0);
    const identity_linear = LinearKernel.init(&identity.kernel, identity.kernel_size);
    try std.testing.expectEqual(@as(u8, 0), identity_linear.n_taps);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), identity_linear.center_weight, 1e-6);
}

test "filter instance pair packing matches the shader" {
    // Shaders unpack `u16x2` as `(value & 0xffff, value >> 16)`.
    try testing.expectEqual(@as(u32, 0x0002_0001), packU16Pair(1, 2));
    try testing.expectEqual(@as(u32, 0x0002_0001), copy_mod.GpuCopyInstance.new(
        .{ 1, 2 },
        .{ 0, 0 },
        .{ 0, 0 },
        .{ 0, 0 },
    ).dest_texture_origin);
}

test "prepared filter conversions round trip headers" {
    const offset = common.filter.Offset.new(1.0, 2.0);
    const offset_block = gpuOffsetFrom(&offset);
    try std.testing.expectEqual(filter_type.OFFSET, offset_block.header & 0x1F);
    var erased: GpuFilterData = undefined;
    @memcpy(std.mem.asBytes(&erased), std.mem.asBytes(&offset_block));
    try std.testing.expectEqual(filter_type.OFFSET, erased.filterType());

    const flood = common.filter.Flood.new(peniko.color.Color.fromRgba8(255, 0, 0, 128));
    const flood_block = gpuFloodFrom(&flood);
    try std.testing.expectEqual(filter_type.FLOOD, flood_block.header & 0x1F);

    const blur = common.filter.GaussianBlur.new(2.0, .none);
    const blur_block = gpuGaussianBlurFrom(&blur);
    try std.testing.expectEqual(filter_type.GAUSSIAN_BLUR, blur_block.header & 0x1F);
    try std.testing.expectEqual(@as(u32, 3), (blur_block.header >> 11) & 0x3);

    const shadow = common.filter.DropShadow.new(
        3.0,
        -4.0,
        8.0,
        .none,
        peniko.color.Color.fromRgb8(0, 0, 0),
    );
    const shadow_block = gpuDropShadowFrom(&shadow);
    try std.testing.expectEqual(filter_type.DROP_SHADOW, shadow_block.header & 0x1F);
    try std.testing.expect(shadow_block.header & COMPOSITE_ORIGINAL_MASK != 0);

    const prepared = common.filter.PreparedFilter{ .offset = offset };
    const data = gpuFilterDataFrom(&prepared);
    try std.testing.expectEqual(filter_type.OFFSET, data.filterType());
    try std.testing.expect(!data.needsCopyPass());
}

test "filter context offsets and serialization" {
    const allocator = testing.allocator;
    var context = FilterContext{};
    defer context.deinit(allocator);

    var offset_data = common.filter.FilterData.new(
        try common.filter_effects.Filter.fromPrimitive(allocator, .{ .offset = .{ .dx = 1.0, .dy = 2.0 } }),
        kurbo.Affine.IDENTITY,
    );
    defer offset_data.deinit(allocator);
    const first = try context.push(allocator, &offset_data);
    try testing.expectEqual(@as(u32, 0), first.data_offset);
    try testing.expectEqual(@as(u32, 3), context.totalTexels());
    try testing.expectEqual(@as(?u32, 1), context.requiredFilterDataHeight(4096));

    var blur_data = common.filter.FilterData.new(
        try common.filter_effects.Filter.fromPrimitive(allocator, .{
            .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
        }),
        kurbo.Affine.IDENTITY,
    );
    defer blur_data.deinit(allocator);
    const second = try context.push(allocator, &blur_data);
    try testing.expectEqual(@as(u32, 3), second.data_offset);
    try testing.expectEqual(@as(u32, 6), context.totalTexels());

    var buffer: [FILTER_SIZE_BYTES * 2]u8 = undefined;
    context.serializeToBuffer(&buffer);
    try testing.expectEqual(@as(u32, filter_type.OFFSET), std.mem.bytesAsValue(u32, buffer[0..4]).* & 0x1F);
    try testing.expectEqual(@as(u32, filter_type.GAUSSIAN_BLUR), std.mem.bytesAsValue(u32, buffer[48..52]).* & 0x1F);
}

test "filter pass plan sequences" {
    const allocator = testing.allocator;
    const SizeU16 = common.geometry.SizeU16;
    const regions = FilterTextureRegions.new(
        .{ .target = target_mod.LayerTextureId.new(.odd, 0), .rect = common.geometry.RectU16.new(0, 0, 32, 24) },
        .{ .target = target_mod.LayerTextureId.new(.even, 0), .rect = common.geometry.RectU16.new(40, 0, 72, 24) },
    );

    var blur_data = common.filter.FilterData.new(
        try common.filter_effects.Filter.fromPrimitive(allocator, .{
            .gaussian_blur = .{ .std_deviation = 8.0, .edge_mode = .none },
        }),
        kurbo.Affine.IDENTITY,
    );
    defer blur_data.deinit(allocator);
    var context = FilterContext{};
    defer context.deinit(allocator);
    const prepared = try context.push(allocator, &blur_data);
    try testing.expect(prepared.data.nDecimations() > 0);

    var plan = FilterPassPlan{};
    defer plan.deinit(allocator);
    try plan.init(
        allocator,
        &.{.{
            .textures = regions,
            .filter_data_offset = prepared.data_offset,
            .gpu_filter = prepared.data,
        }},
        SizeU16.new(64),
    );
    try testing.expect(plan.copyPass() == null);
    try testing.expectEqual(@as(u32, pass_kind.DOWNSCALE), plan.stepItems(0)[0].filter_pass_kind);
    // A blur that decimates ends in the original region after its final
    // upscale, so no extra copy pass is required.
    try testing.expectEqual(
        @as(u32, pass_kind.UPSCALE),
        plan.stepItems(plan.stepCount() - 1)[0].filter_pass_kind,
    );

    var shadow_data = common.filter.FilterData.new(
        try common.filter_effects.Filter.fromPrimitive(allocator, .{
            .drop_shadow = .{
                .dx = 3.0,
                .dy = -4.0,
                .std_deviation = 8.0,
                .edge_mode = .none,
                .color = peniko.color.Color.fromRgb8(0, 0, 0),
            },
        }),
        kurbo.Affine.IDENTITY,
    );
    defer shadow_data.deinit(allocator);
    const shadow = try context.push(allocator, &shadow_data);
    try testing.expect(shadow.data.needsCopyPass());
    try plan.init(
        allocator,
        &.{.{
            .textures = regions,
            .filter_data_offset = shadow.data_offset,
            .gpu_filter = shadow.data,
        }},
        SizeU16.new(64),
    );
    try testing.expect(plan.copyPass() != null);
}

test "filter block layouts" {
    try std.testing.expectEqual(@as(usize, 48), FILTER_SIZE_BYTES);
    try std.testing.expectEqual(@as(u32, 3), FILTER_SIZE_TEXELS);
    try std.testing.expectEqual(@as(usize, 3), MAX_TAPS_PER_SIDE);
    try std.testing.expectEqual(@as(u16, 6), FILTER_ATLAS_PADDING);
    try std.testing.expectEqual(@as(usize, 13), MAX_KERNEL_SIZE);
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(FilterInstanceData));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(FilterInstanceData));
    comptime {
        if (@sizeOf(GpuFilterData) != 48 or FILTER_SIZE_U32 != 12) {
            @compileError("GpuFilterData size diverged");
        }
    }

    const offset = GpuOffset{ .header = 0, .dx = 1.0, .dy = 2.0, ._padding = @splat(0) };
    try std.testing.expectEqual(@as(usize, 48), std.mem.asBytes(&offset).len);
    const flood = GpuFlood{ .header = 0, .color = 0xFFFFFFFF, ._padding = @splat(0) };
    try std.testing.expectEqual(@as(usize, 48), std.mem.asBytes(&flood).len);
    const blur = GpuGaussianBlur{
        .header = 0,
        .center_weight = 0.5,
        .linear_weights = @splat(0.25),
        .linear_offsets = @splat(1.0),
        ._padding = @splat(0),
    };
    try std.testing.expectEqual(@as(usize, 48), std.mem.asBytes(&blur).len);
    const shadow = GpuDropShadow{
        .header = 0,
        .center_weight = 0.5,
        .linear_weights = @splat(0.25),
        .linear_offsets = @splat(1.0),
        .dx = 1.0,
        .dy = 2.0,
        .color = 0,
        ._padding = @splat(0),
    };
    try std.testing.expectEqual(@as(usize, 48), std.mem.asBytes(&shadow).len);
}

test "filter header packing" {
    try std.testing.expectEqual(@as(u32, 0), packHeader(filter_type.OFFSET));
    try std.testing.expectEqual(@as(u32, 1), packHeader(filter_type.FLOOD));
    try std.testing.expectEqual(@as(u32, 3), packHeader(filter_type.DROP_SHADOW));

    // type 2 | edge 1 << 5 | decimations 4 << 7 | taps 3 << 11
    const header = packHeaderWithGaussianParams(filter_type.GAUSSIAN_BLUR, edge_mode.WRAP, 4, 3);
    try std.testing.expectEqual(@as(u32, 2 | (1 << 5) | (4 << 7) | (3 << 11)), header);
    try std.testing.expectEqual(@as(u32, 0), header & COMPOSITE_ORIGINAL_MASK);

    var data = std.mem.zeroes(GpuFilterData);
    data.data[0] = header | COMPOSITE_ORIGINAL_MASK;
    try std.testing.expectEqual(@as(u32, filter_type.GAUSSIAN_BLUR), data.filterType());
    try std.testing.expectEqual(@as(usize, 4), data.nDecimations());
    try std.testing.expect(data.compositeOriginal());
    // Only drop shadows with the composite bit need the copy pass.
    try std.testing.expect(!data.needsCopyPass());
    data.data[0] = packHeaderWithGaussianParams(filter_type.DROP_SHADOW, edge_mode.NONE, 0, 2) | COMPOSITE_ORIGINAL_MASK;
    try std.testing.expect(data.needsCopyPass());
}

test "filter constants and edge modes" {
    try std.testing.expectEqual(@as(u32, 0), edgeModeToGpu(.duplicate));
    try std.testing.expectEqual(@as(u32, 1), edgeModeToGpu(.wrap));
    try std.testing.expectEqual(@as(u32, 2), edgeModeToGpu(.mirror));
    try std.testing.expectEqual(@as(u32, 3), edgeModeToGpu(.none));

    // Pass kinds match docs/shader-interface.md §4.
    try std.testing.expectEqual(@as(u32, 0), pass_kind.COPY);
    try std.testing.expectEqual(@as(u32, 1), pass_kind.FLOOD);
    try std.testing.expectEqual(@as(u32, 2), pass_kind.OFFSET);
    try std.testing.expectEqual(@as(u32, 3), pass_kind.DOWNSCALE);
    try std.testing.expectEqual(@as(u32, 4), pass_kind.BLUR_H);
    try std.testing.expectEqual(@as(u32, 5), pass_kind.BLUR_V);
    try std.testing.expectEqual(@as(u32, 6), pass_kind.UPSCALE);
    try std.testing.expectEqual(@as(u32, 7), pass_kind.COMPOSITE_DROP_SHADOW);
    try std.testing.expectEqual(@as(u32, 8), pass_kind.COLORIZE);
}
