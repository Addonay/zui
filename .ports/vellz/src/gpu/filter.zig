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
