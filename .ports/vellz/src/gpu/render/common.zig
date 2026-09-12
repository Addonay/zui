//! Port of `vello_gpu/src/render/common.rs` (host/shader layout subset)
//! (Apache-2.0 OR MIT).
//!
//! Every struct and packing helper here is the host side of the byte-for-byte
//! contract in `docs/shader-interface.md` §3–§4. Nothing in this file imports
//! the `wgpu` package: the layouts are usable and testable in the CPU-only
//! build. `@sizeOf`/`@offsetOf` assertions are comptime, so a divergence fails
//! compilation rather than a runtime test.

const std = @import("std");
const common = @import("../../common/root.zig");
const peniko = @import("../../peniko/root.zig");
const copy = @import("../copy.zig");
const blend = @import("../blend.zig");

// Upstream `render/common.rs` imports both instance types for its scratch
// buffers; re-export them here so the render-side namespace stays the single
// entry point (`ScratchBuffers` itself lands with the schedule).
pub const GpuCopyInstance = copy.GpuCopyInstance;
pub const GpuBlendInstance = blend.GpuBlendInstance;

// GPU paint structure sizes in texels (1 texel = 16 bytes for the RGBA32Uint
// encoded-paints texture).
pub const GPU_ENCODED_IMAGE_SIZE_TEXELS: u32 = @sizeOf(GpuEncodedImage) / 16;
pub const GPU_LINEAR_GRADIENT_SIZE_TEXELS: u32 = @sizeOf(GpuLinearGradient) / 16;
pub const GPU_RADIAL_GRADIENT_SIZE_TEXELS: u32 = @sizeOf(GpuRadialGradient) / 16;
pub const GPU_SWEEP_GRADIENT_SIZE_TEXELS: u32 = @sizeOf(GpuSweepGradient) / 16;
pub const GPU_BLURRED_ROUNDED_RECT_SIZE_TEXELS: u32 = @sizeOf(GpuBlurredRoundedRect) / 16;

/// Number of transparent padding pixels around an image in its atlas.
///
/// Upstream leaves this at 0 (it does not use native bilinear sampling for
/// uploaded images yet); keeping the constant makes the layout explicit.
pub const IMAGE_PADDING: u16 = 0;

/// Configuration for the GPU renderer (uniform, 32 bytes, 16-byte aligned).
///
/// Shader field names: `width`, `height`, `strip_height`,
/// `alphas_tex_width_bits`, `encoded_paints_tex_width_bits`, `strip_offset_x`,
/// `strip_offset_y`, `nc_y_negate`.
pub const Config = extern struct {
    /// Width of the rendering target.
    width: u32 align(16),
    /// Height of the rendering target.
    height: u32,
    /// Height of a strip in the rendering.
    strip_height: u32,
    /// Number of trailing zeros in the alphas texture width (log2 of width).
    /// Pre-calculated on the CPU because downlevel targets do not support
    /// `firstTrailingBit`.
    alphas_tex_width_bits: u32,
    /// Number of trailing zeros in the encoded paints texture width.
    encoded_paints_tex_width_bits: u32,
    /// A horizontal offset to apply to strips.
    strip_offset_x: i32,
    /// A vertical offset to apply to strips.
    strip_offset_y: i32,
    /// Whether to flip the y-component of the NDC position.
    negate_ndc: u32,
};

comptime {
    if (@sizeOf(Config) != 32) @compileError("Config must be exactly 32 bytes");
    if (@alignOf(Config) != 16) @compileError("Config must be 16-byte aligned");
    const fields = .{
        "width",                 "height",                        "strip_height",
        "alphas_tex_width_bits", "encoded_paints_tex_width_bits", "strip_offset_x",
        "strip_offset_y",        "negate_ndc",
    };
    for (fields, 0..) |name, i| {
        if (@offsetOf(Config, name) != i * 4) {
            @compileError("Config field offsets diverged from the shader contract");
        }
    }
}

/// A GPU strip instance for rendering (24 bytes), six `Uint32` vertex
/// attributes at shader locations 0–5, instance step mode.
///
/// See `StripInstance` in `render.wesl` for the field semantics.
pub const GpuStrip = extern struct {
    /// See `StripInstance::xy` in `render.wesl`.
    x: u16,
    /// See `StripInstance::xy` in `render.wesl`.
    y: u16,
    /// See `StripInstance::dense_width_or_rect_height` in `render.wesl`.
    width: u16,
    /// See `StripInstance::dense_width_or_rect_height` in `render.wesl`.
    dense_width_or_rect_height: u16,
    /// See `StripInstance::col_idx_or_rect_frac` in `render.wesl`.
    col_idx_or_rect_frac: u32,
    /// See `StripInstance::payload` in `render.wesl`.
    payload: u32,
    /// See `StripInstance::paint_and_rect_flag` in `render.wesl`.
    paint_and_rect_flag: u32,
    /// Painter's-order index used to compute z-depth for early-z rejection.
    /// The back-most draw has index 0 and every draw in front increments it.
    depth_index: u32,
};

comptime {
    if (@sizeOf(GpuStrip) != 24) @compileError("GpuStrip must be exactly 24 bytes");
    if (@alignOf(GpuStrip) != 4) @compileError("GpuStrip must be 4-byte aligned");
    const fields = .{
        "x",                    "y",
        "width",                "dense_width_or_rect_height",
        "col_idx_or_rect_frac", "payload",
        "paint_and_rect_flag",  "depth_index",
    };
    const offsets = [_]usize{ 0, 2, 4, 6, 8, 12, 16, 20 };
    for (fields, offsets) |name, offset| {
        if (@offsetOf(GpuStrip, name) != offset) {
            @compileError("GpuStrip field offsets diverged from the shader contract");
        }
    }
}

/// Per-instance data for clearing a rectangle in a render target (28 bytes).
///
/// Vertex layout: three `Uint32x2` attributes plus one `Uint32` at shader
/// locations 0–3, instance step mode.
pub const GpuClearInstance = extern struct {
    /// Atlas-space rectangle origin.
    origin: [2]u32,
    /// Width and height of the cleared rectangle.
    size: [2]u32,
    /// Width and height of the target texture.
    target_size: [2]u32,
    /// Premultiplied clear color.
    color: u32,

    /// Build an instance from a `u16` rectangle and target size (upstream
    /// builds the same fields inline in `clear_pass_inner`).
    pub fn new(origin: [2]u16, size: [2]u16, target_size: [2]u16, color: u32) GpuClearInstance {
        return .{
            .origin = .{ origin[0], origin[1] },
            .size = .{ size[0], size[1] },
            .target_size = .{ target_size[0], target_size[1] },
            .color = color,
        };
    }
};

comptime {
    if (@sizeOf(GpuClearInstance) != 28) @compileError("GpuClearInstance must be exactly 28 bytes");
    if (@offsetOf(GpuClearInstance, "origin") != 0 or
        @offsetOf(GpuClearInstance, "size") != 8 or
        @offsetOf(GpuClearInstance, "target_size") != 16 or
        @offsetOf(GpuClearInstance, "color") != 24)
    {
        @compileError("GpuClearInstance field offsets diverged from the shader contract");
    }
}

// ---------------------------------------------------------------------------
// `paint_and_rect_flag` bit layout (see `docs/shader-interface.md` §4).
// ---------------------------------------------------------------------------

/// Bit 31: the strip represents a full rectangle.
pub const RECT_STRIP_FLAG: u32 = 1 << 31;
/// Bits 29–30: payload color source (0 = payload, 1 = layer).
pub const COLOR_SOURCE_PAYLOAD: u32 = 0;
/// Bits 29–30: layer color source; stores opacity in bits 0–7.
pub const COLOR_SOURCE_LAYER: u32 = 1;
/// Bits 29–30: color source shift.
pub const COLOR_SOURCE_SHIFT: u32 = 29;
/// Bits 26–28: paint type shift.
pub const PAINT_TYPE_SHIFT: u32 = 26;
/// Bits 24–25: external texture slot shift.
pub const EXTERNAL_TEXTURE_SLOT_SHIFT: u32 = 24;
/// Bits 0–23: paint texture index mask.
pub const PAINT_TEXTURE_INDEX_MASK: u32 = (1 << EXTERNAL_TEXTURE_SLOT_SHIFT) - 1;

pub const PAINT_TYPE_SOLID: u32 = 0;
pub const PAINT_TYPE_IMAGE: u32 = 1;
pub const PAINT_TYPE_LINEAR_GRADIENT: u32 = 2;
pub const PAINT_TYPE_RADIAL_GRADIENT: u32 = 3;
pub const PAINT_TYPE_SWEEP_GRADIENT: u32 = 4;
pub const PAINT_TYPE_BLURRED_ROUNDED_RECT: u32 = 5;

/// Pack the paint kind, color source, and texture index used by
/// `GpuStrip::paint_and_rect_flag` (upstream builds this inline in `paint.rs`).
pub fn packPaintAndRectFlag(color_source: u32, paint_type: u32, paint_texture_index: u32) u32 {
    std.debug.assert(color_source <= COLOR_SOURCE_LAYER);
    std.debug.assert(paint_type <= PAINT_TYPE_BLURRED_ROUNDED_RECT);
    std.debug.assert(paint_texture_index <= PAINT_TEXTURE_INDEX_MASK);
    return (color_source << COLOR_SOURCE_SHIFT) |
        (paint_type << PAINT_TYPE_SHIFT) |
        (paint_texture_index & PAINT_TEXTURE_INDEX_MASK);
}

/// Set the `RECT_STRIP_FLAG` bit on a packed paint value.
pub fn packRectStripFlag(paint: u32) u32 {
    return paint | RECT_STRIP_FLAG;
}

/// Store an external texture slot (0–3) in bits 24–25 of a packed paint value.
pub fn packExternalTextureSlot(paint: u32, slot: u32) u32 {
    std.debug.assert(slot <= 3);
    return paint | (slot << EXTERNAL_TEXTURE_SLOT_SHIFT);
}

/// Read back the external texture slot stored by [`packExternalTextureSlot`].
pub fn externalTextureSlot(paint: u32) u32 {
    return (paint >> EXTERNAL_TEXTURE_SLOT_SHIFT) & 0x3;
}

/// Layer color sources store their opacity in bits 0–7 (upstream writes the
/// packed `u8` opacity directly into the paint word).
pub fn packLayerColor(opacity: u8) u32 {
    return opacity;
}

// ---------------------------------------------------------------------------
// Encoded paints (`RGBA32Uint` texture data, alignment 16).
// ---------------------------------------------------------------------------

/// GPU encoded image data (48 bytes = 3 texels).
pub const GpuEncodedImage = extern struct {
    /// Packed rendering quality and extend modes.
    /// Bits 4–5: `extend_y` (2 bits), bits 2–3: `extend_x` (2 bits),
    /// bits 0–1: `quality` (2 bits).
    image_params: u32 align(16),
    /// Packed image width and height.
    image_size: u32,
    /// The offset of the image in the atlas texture in pixels.
    image_offset: u32,
    /// Transform matrix `[a, b, c, d, tx, ty]`.
    transform: [6]f32,
    /// Premultiplied tint color packed as RGBA8 unorm (`pack4x8unorm` layout).
    tint: u32,
    /// GPU tint mode.
    tint_mode: u32,
    /// Number of transparent padding pixels around the image in the atlas.
    image_padding: u32,
};

/// GPU encoded linear gradient data (32 bytes = 2 texels).
pub const GpuLinearGradient = extern struct {
    /// Packed texture width (bits 0–29) and extend mode (bits 30–31).
    texture_width_and_extend_mode: u32 align(16),
    /// Start coordinate in the flat gradient texture.
    gradient_start: u32,
    /// Transform matrix `[a, b, c, d, tx, ty]`.
    transform: [6]f32,
};

/// GPU encoded radial gradient data (64 bytes = 4 texels).
pub const GpuRadialGradient = extern struct {
    /// Packed texture width (bits 0–29) and extend mode (bits 30–31).
    texture_width_and_extend_mode: u32 align(16),
    /// Start coordinate in the flat gradient texture for dense packing.
    gradient_start: u32,
    /// Transform matrix `[a, b, c, d, tx, ty]`.
    transform: [6]f32,
    /// Packed kind (bits 0–1) and `f_is_swapped` (bit 2).
    kind_and_f_is_swapped: u32,
    /// Bias value for the radial gradient calculation.
    bias: f32,
    /// Scale factor for the radial gradient calculation.
    scale: f32,
    /// Focal point 0 parameter.
    fp0: f32,
    /// Focal point 1 parameter.
    fp1: f32,
    /// Focal radius 1 parameter.
    fr1: f32,
    /// Focal x coordinate.
    f_focal_x: f32,
    /// Scaled radius 0 squared parameter for the radial gradient strip.
    scaled_r0_squared: f32,
};

/// GPU encoded sweep gradient data (48 bytes = 3 texels).
pub const GpuSweepGradient = extern struct {
    /// Packed texture width (bits 0–29) and extend mode (bits 30–31).
    texture_width_and_extend_mode: u32 align(16),
    /// Start coordinate in the flat gradient texture for dense packing.
    gradient_start: u32,
    /// Transform matrix `[a, b, c, d, tx, ty]`.
    transform: [6]f32,
    /// Starting angle for the sweep gradient.
    start_angle: f32,
    /// Inverse of the angle delta for the sweep gradient.
    inv_angle_delta: f32,
    /// Padding for 16-byte alignment.
    _padding: [2]u32,
};

/// GPU encoded blurred rounded rectangle data (80 bytes = 5 texels).
pub const GpuBlurredRoundedRect = extern struct {
    /// Transform matrix `[a, b, c, d, tx, ty]`.
    transform: [6]f32 align(16),
    /// Premultiplied color packed as RGBA8 unorm (`pack4x8unorm` layout).
    color: u32,
    /// Whether to paint the inverse (`1 - alpha`) of the blur coverage.
    invert: u32,
    /// Blur parameters: exponent, reciprocal exponent, scale, and inverse
    /// standard deviation.
    params0: [4]f32,
    /// Blur parameters: minimum edge length, adjusted width, adjusted height,
    /// and outer radius.
    params1: [4]f32,
    /// Blur parameters `[width, height]`.
    size: [2]f32,
    /// Padding for 16-byte alignment.
    _padding1: [2]u32,
};

comptime {
    const checked = .{
        .{ GpuEncodedImage, 48 },
        .{ GpuLinearGradient, 32 },
        .{ GpuRadialGradient, 64 },
        .{ GpuSweepGradient, 48 },
        .{ GpuBlurredRoundedRect, 80 },
    };
    for (checked) |entry| {
        if (@sizeOf(entry[0]) != entry[1]) {
            @compileError(@typeName(entry[0]) ++ " has the wrong size for the shader contract");
        }
        if (@alignOf(entry[0]) != 16) {
            @compileError(@typeName(entry[0]) ++ " must be 16-byte aligned");
        }
    }

    if (@offsetOf(GpuEncodedImage, "transform") != 12 or
        @offsetOf(GpuEncodedImage, "tint") != 36 or
        @offsetOf(GpuEncodedImage, "tint_mode") != 40 or
        @offsetOf(GpuEncodedImage, "image_padding") != 44)
    {
        @compileError("GpuEncodedImage field offsets diverged from the shader contract");
    }
    if (@offsetOf(GpuRadialGradient, "kind_and_f_is_swapped") != 32 or
        @offsetOf(GpuRadialGradient, "scaled_r0_squared") != 60)
    {
        @compileError("GpuRadialGradient field offsets diverged from the shader contract");
    }
    if (@offsetOf(GpuSweepGradient, "start_angle") != 32 or
        @offsetOf(GpuSweepGradient, "inv_angle_delta") != 36 or
        @offsetOf(GpuSweepGradient, "_padding") != 40)
    {
        @compileError("GpuSweepGradient field offsets diverged from the shader contract");
    }
    if (@offsetOf(GpuBlurredRoundedRect, "color") != 24 or
        @offsetOf(GpuBlurredRoundedRect, "invert") != 28 or
        @offsetOf(GpuBlurredRoundedRect, "params0") != 32 or
        @offsetOf(GpuBlurredRoundedRect, "params1") != 48 or
        @offsetOf(GpuBlurredRoundedRect, "size") != 64 or
        @offsetOf(GpuBlurredRoundedRect, "_padding1") != 72)
    {
        @compileError("GpuBlurredRoundedRect field offsets diverged from the shader contract");
    }
}

/// Different types of GPU encoded paints (upstream `GpuEncodedPaint`).
pub const GpuEncodedPaint = union(enum) {
    /// An encoded image.
    image: GpuEncodedImage,
    /// An encoded linear gradient.
    linear_gradient: GpuLinearGradient,
    /// An encoded radial gradient.
    radial_gradient: GpuRadialGradient,
    /// An encoded sweep gradient.
    sweep_gradient: GpuSweepGradient,
    /// An encoded blurred rounded rectangle.
    blurred_rounded_rect: GpuBlurredRoundedRect,

    /// Returns the byte representation of this paint.
    pub fn asBytes(self: *const GpuEncodedPaint) []const u8 {
        return switch (self.*) {
            .image => std.mem.asBytes(&self.image),
            .linear_gradient => std.mem.asBytes(&self.linear_gradient),
            .radial_gradient => std.mem.asBytes(&self.radial_gradient),
            .sweep_gradient => std.mem.asBytes(&self.sweep_gradient),
            .blurred_rounded_rect => std.mem.asBytes(&self.blurred_rounded_rect),
        };
    }

    /// Number of `RGBA32Uint` texels this paint occupies in the encoded-paints
    /// texture.
    pub fn sizeTexels(self: *const GpuEncodedPaint) u32 {
        return switch (self.*) {
            .image => GPU_ENCODED_IMAGE_SIZE_TEXELS,
            .linear_gradient => GPU_LINEAR_GRADIENT_SIZE_TEXELS,
            .radial_gradient => GPU_RADIAL_GRADIENT_SIZE_TEXELS,
            .sweep_gradient => GPU_SWEEP_GRADIENT_SIZE_TEXELS,
            .blurred_rounded_rect => GPU_BLURRED_ROUNDED_RECT_SIZE_TEXELS,
        };
    }
};

// ---------------------------------------------------------------------------
// Encoded-paint packing helpers (see `docs/shader-interface.md` §4).
// ---------------------------------------------------------------------------

/// Pack a gradient texture width and extend mode into a single `u32`.
///
/// `extend_mode`: 0 = pad, 1 = repeat, 2 = reflect (bits 30–31).
/// `texture_width`: bits 0–29 (max value `2^30 - 1`).
pub fn packTextureWidthAndExtendMode(texture_width: u32, extend_mode: u32) u32 {
    const EXTEND_MODE_MASK: u32 = 1 << 30;
    const TEXTURE_WIDTH_MASK: u32 = ~EXTEND_MODE_MASK;
    std.debug.assert(extend_mode <= 2);
    std.debug.assert(texture_width <= TEXTURE_WIDTH_MASK);
    return (extend_mode << 30) | (texture_width & TEXTURE_WIDTH_MASK);
}

/// Pack the radial gradient kind and swapped flag into a single `u32`.
///
/// `kind`: 0 = radial, 1 = strip, 2 = focal (bits 0–1).
/// `f_is_swapped`: bit 2.
pub fn packRadialKindAndSwapped(kind: u32, f_is_swapped: u32) u32 {
    std.debug.assert(kind <= 2);
    std.debug.assert(f_is_swapped <= 1);
    return (f_is_swapped << 2) | (kind & 0x3);
}

/// Pack image `width` and `height` into a single `u32` (width high, height
/// low).
pub fn packImageSize(width: u16, height: u16) u32 {
    return (@as(u32, width) << 16) | @as(u32, height);
}

/// Pack image offset coordinates `x` and `y` into a single `u32` (x high,
/// y low).
pub fn packImageOffset(x: u16, y: u16) u32 {
    return (@as(u32, x) << 16) | @as(u32, y);
}

/// Pack image `quality` and extend modes into a single `u32`.
///
/// `extend_y`: bits 4–5, `extend_x`: bits 2–3, `quality`: bits 0–1.
pub fn packImageParams(quality: u32, extend_x: u32, extend_y: u32) u32 {
    std.debug.assert(extend_x <= 3);
    std.debug.assert(extend_y <= 3);
    std.debug.assert(quality <= 3);
    return (extend_y << 4) | (extend_x << 2) | quality;
}

/// A packed `(tint_color_u32, tint_mode_u32)` pair.
pub const PackedTint = struct {
    /// Premultiplied tint color as RGBA8 unorm.
    color: u32,
    /// GPU tint mode.
    mode: u32,
};

/// Pack an optional [`common.paint.Tint`] for the GPU.
///
/// The tint color is premultiplied before packing into a `u32` in the same
/// layout as WGSL `pack4x8unorm`. With no tint, `u32::MAX` (1.0 on all lanes)
/// is used with `Multiply`, which leaves the image sample unchanged.
pub fn packTint(tint: ?common.paint.Tint) PackedTint {
    if (tint) |t| {
        return .{
            .color = t.color.premultiply().toRgba8().toU32(),
            .mode = t.mode.asU32(),
        };
    }
    return .{
        .color = std.math.maxInt(u32),
        .mode = common.paint.TintMode.multiply.asU32(),
    };
}

test "config layout" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Config));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(Config));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Config, "width"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Config, "negate_ndc"));
}

test "gpu strip layout" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(GpuStrip));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(GpuStrip));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(GpuStrip, "x"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(GpuStrip, "dense_width_or_rect_height"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(GpuStrip, "col_idx_or_rect_frac"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(GpuStrip, "depth_index"));

    const strip = GpuStrip{
        .x = 1,
        .y = 2,
        .width = 3,
        .dense_width_or_rect_height = 4,
        .col_idx_or_rect_frac = 5,
        .payload = 6,
        .paint_and_rect_flag = 7,
        .depth_index = 8,
    };
    const bytes = std.mem.asBytes(&strip);
    try std.testing.expectEqual(@as(usize, 24), bytes.len);
    try std.testing.expectEqual(@as(u8, 1), bytes[0]);
    // depth_index lives at offset 20 and is 8 on little endian.
    try std.testing.expectEqual(@as(u8, 8), bytes[20]);
}

test "gpu clear instance layout" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(GpuClearInstance));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(GpuClearInstance, "size"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(GpuClearInstance, "target_size"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(GpuClearInstance, "color"));

    const instance = GpuClearInstance.new(.{ 1, 2 }, .{ 3, 4 }, .{ 64, 64 }, 0x11223344);
    try std.testing.expectEqual([2]u32{ 1, 2 }, instance.origin);
    try std.testing.expectEqual([2]u32{ 3, 4 }, instance.size);
    try std.testing.expectEqual([2]u32{ 64, 64 }, instance.target_size);
    try std.testing.expectEqual(@as(u32, 0x11223344), instance.color);
}

test "encoded paint layouts" {
    try std.testing.expectEqual(@as(u32, 3), GPU_ENCODED_IMAGE_SIZE_TEXELS);
    try std.testing.expectEqual(@as(u32, 2), GPU_LINEAR_GRADIENT_SIZE_TEXELS);
    try std.testing.expectEqual(@as(u32, 4), GPU_RADIAL_GRADIENT_SIZE_TEXELS);
    try std.testing.expectEqual(@as(u32, 3), GPU_SWEEP_GRADIENT_SIZE_TEXELS);
    try std.testing.expectEqual(@as(u32, 5), GPU_BLURRED_ROUNDED_RECT_SIZE_TEXELS);
    try std.testing.expectEqual(@as(usize, 16), @alignOf(GpuEncodedImage));

    var paint = GpuEncodedPaint{
        .linear_gradient = std.mem.zeroes(GpuLinearGradient),
    };
    try std.testing.expectEqual(@as(usize, 32), paint.asBytes().len);
    try std.testing.expectEqual(@as(u32, 2), paint.sizeTexels());

    paint = .{ .blurred_rounded_rect = std.mem.zeroes(GpuBlurredRoundedRect) };
    try std.testing.expectEqual(@as(usize, 80), paint.asBytes().len);
    try std.testing.expectEqual(@as(u32, 5), paint.sizeTexels());
}

test "paint and rect flag packing" {
    try std.testing.expectEqual(@as(u32, 1 << 31), RECT_STRIP_FLAG);

    // Layer paint: color source 1, image type 1, texture index 7.
    const layer = packPaintAndRectFlag(COLOR_SOURCE_LAYER, PAINT_TYPE_IMAGE, 7);
    try std.testing.expectEqual(@as(u32, (1 << 29) | (1 << 26) | 7), layer);
    try std.testing.expectEqual(
        @as(u32, (1 << 29) | (1 << 26) | 7 | (1 << 31)),
        packRectStripFlag(layer),
    );
    // External texture slots occupy bits 24–25 and are not part of the index.
    const slotted = packExternalTextureSlot(layer, 2);
    try std.testing.expectEqual(@as(u32, 2), externalTextureSlot(slotted));
    try std.testing.expectEqual(
        @as(u32, (1 << 29) | (1 << 26) | 7 | (2 << 24)),
        slotted,
    );

    // Solid paint: color source 0, type 0, texture index 0.
    try std.testing.expectEqual(@as(u32, 0), packPaintAndRectFlag(COLOR_SOURCE_PAYLOAD, PAINT_TYPE_SOLID, 0));

    // Layer opacity is stored in the low byte.
    try std.testing.expectEqual(@as(u32, 128), packLayerColor(128));

    // A full texture index leaves the slot bits untouched.
    try std.testing.expectEqual(
        @as(u32, PAINT_TEXTURE_INDEX_MASK),
        packPaintAndRectFlag(COLOR_SOURCE_PAYLOAD, PAINT_TYPE_SOLID, PAINT_TEXTURE_INDEX_MASK),
    );
}

test "encoded paint packing helpers" {
    // docs/shader-interface.md: pack_image_size(w, h) = w << 16 | h
    try std.testing.expectEqual(@as(u32, 0x1234_5678), packImageSize(0x1234, 0x5678));
    // pack_image_offset(x, y) = x << 16 | y
    try std.testing.expectEqual(@as(u32, 0x0010_0020), packImageOffset(0x10, 0x20));
    // pack_image_params(quality, extend_x, extend_y) = extend_y << 4 | extend_x << 2 | quality
    try std.testing.expectEqual(@as(u32, 0x39), packImageParams(1, 2, 3));
    try std.testing.expectEqual(@as(u32, 0x3F), packImageParams(3, 3, 3));
    // pack_texture_width_and_extend_mode(width, extend): extend in bits 30–31.
    try std.testing.expectEqual(@as(u32, (2 << 30) | 1024), packTextureWidthAndExtendMode(1024, 2));
    try std.testing.expectEqual(@as(u32, 4096), packTextureWidthAndExtendMode(4096, 0));
    // pack_radial_kind_and_swapped(kind, swapped): kind bits 0–1, swapped bit 2.
    try std.testing.expectEqual(@as(u32, 0x6), packRadialKindAndSwapped(2, 1));
    try std.testing.expectEqual(@as(u32, 0x1), packRadialKindAndSwapped(1, 0));
}

test "tint packing" {
    // No tint: u32::MAX with Multiply (the identity under componentwise
    // multiply).
    const none = packTint(null);
    try std.testing.expectEqual(std.math.maxInt(u32), none.color);
    try std.testing.expectEqual(common.paint.TintMode.multiply.asU32(), none.mode);

    // Premultiplied RGBA8 (r,g,b,a) => u32 with r least significant.
    const color = peniko.color.Color.fromRgba8(255, 128, 0, 255);
    var tint = common.paint.Tint{ .color = color, .mode = .alpha_mask };
    try expectTint(tint, 0xFF00_80FF, common.paint.TintMode.alpha_mask.asU32());

    // 50% alpha premultiplies the channels (fastRoundToU8 uses +0.5).
    tint.color = peniko.color.Color.fromRgba8(255, 0, 0, 128);
    try expectTint(tint, 0x8000_0080, common.paint.TintMode.alpha_mask.asU32());
}

fn expectTint(tint: common.paint.Tint, color: u32, mode: u32) !void {
    const packed_tint = packTint(tint);
    try std.testing.expectEqual(color, packed_tint.color);
    try std.testing.expectEqual(mode, packed_tint.mode);
}
