//! Port of `vello_gpu/src/paint.rs` plus the GPU encoded-paint preparation
//! from `render/wgpu/mod.rs` (`prepare_gpu_encoded_paints`) (Apache-2.0 OR
//! MIT).
//!
//! `PaintResolver` turns recorded paints into shader-ready `PackedPaint`
//! values; `prepareGpuEncodedPaints` packs indexed paints into the
//! `Rgba32Uint` encoded-paints texture data and records each paint's texel
//! offset. Gradients resolve through `gradient_cache.zig`.
//!
//! CPU-safe: imports only `vellz.common`, `vellz.peniko`, and the CPU-safe GPU
//! layout modules.

const std = @import("std");
const common = @import("../common/root.zig");
const peniko = @import("../peniko/root.zig");
const gradient_cache = @import("gradient_cache.zig");
const render_common = @import("render/common.zig");
const util = @import("util.zig");

const EncodedImage = common.encode.EncodedImage;
const EncodedKind = common.encode.EncodedKind;
const EncodedPaint = common.encode.EncodedPaint;
const GradientRampCache = gradient_cache.GradientRampCache;
const ImageSource = common.paint.ImageSource;
const Paint = common.paint.Paint;

/// Errors from resolving a paint to its GPU representation.
pub const Error = error{
    /// The paint kind is not implemented by this milestone (atlas-backed
    /// images, pixmap image sources).
    Unsupported,
};

/// Errors from preparing encoded paints.
pub const PrepareError = std.mem.Allocator.Error || Error;

/// Texture sampled by an image paint.
pub const TextureSourceId = union(enum) {
    /// A renderer-owned image atlas.
    atlas: u32,
    /// A texture supplied through the render-time bindings.
    external: u64,
};

/// Source used to populate a strip's paint payload.
pub const PaintPayload = union(enum) {
    /// Premultiplied RGBA value for a solid paint (`unpack4x8unorm` lane
    /// order, r least significant).
    solid: u32,
    /// Scene-space position used to evaluate a non-solid paint.
    position,

    /// The payload value for a strip whose (possibly shifted) origin is
    /// `(x, y)`.
    pub fn at(self: PaintPayload, x: u16, y: u16) u32 {
        return switch (self) {
            .solid => |rgba| rgba,
            .position => util.packU16Pair(x, y),
        };
    }
};

/// Shader-ready paint metadata for a strip.
pub const PackedPaint = struct {
    /// Value source for the strip's payload field.
    payload: PaintPayload,
    /// Packed paint kind, source, and data offset.
    paint: u32,
    /// Texture required by this paint, if any.
    texture_source: ?TextureSourceId,
    /// Whether the paint is fully opaque.
    is_opaque: bool,

    /// The payload value at a strip origin.
    pub fn payloadAt(self: PackedPaint, x: u16, y: u16) u32 {
        return self.payload.at(x, y);
    }
};

/// Resolves recorded paints to their encoded GPU offsets.
pub const PaintResolver = struct {
    /// Encoded non-solid paints indexed by `Paint.indexed`.
    encoded: []const EncodedPaint = &.{},
    /// GPU data offset (in `Rgba32Uint` texels) for each encoded paint.
    gpu_offsets: []const u32 = &.{},

    /// Empty resolver: only solid paints resolve.
    pub const solid_only: PaintResolver = .{};

    /// Build a resolver over prepared encoded paints.
    pub fn new(encoded: []const EncodedPaint, gpu_offsets: []const u32) PaintResolver {
        return .{ .encoded = encoded, .gpu_offsets = gpu_offsets };
    }

    /// Pack one recorded paint for the shader.
    pub fn pack(self: PaintResolver, paint: *const Paint) Error!PackedPaint {
        return switch (paint.*) {
            .solid => |color| .{
                .payload = .{ .solid = color.asPremulRgba8().toU32() },
                .paint = (render_common.COLOR_SOURCE_PAYLOAD << render_common.COLOR_SOURCE_SHIFT) |
                    (render_common.PAINT_TYPE_SOLID << render_common.PAINT_TYPE_SHIFT),
                .texture_source = null,
                .is_opaque = color.isOpaque(),
            },
            .indexed => |indexed| blk: {
                const paint_id = indexed.index();
                if (paint_id >= self.encoded.len or paint_id >= self.gpu_offsets.len) {
                    return error.Unsupported;
                }
                const encoded = &self.encoded[paint_id];
                const gpu_offset = self.gpu_offsets[paint_id];

                const info: EncodedInfo = switch (encoded.*) {
                    .image => |*image| switch (image.source) {
                        .external_texture => |external| .{
                            .paint_type = render_common.PAINT_TYPE_IMAGE,
                            .texture_source = .{ .external = external.id.asU64() },
                        },
                        // Atlas-backed images need the image-cache/atlas
                        // upload path, which is not ported yet.
                        .opaque_id => return error.Unsupported,
                        .pixmap => return error.Unsupported,
                    },
                    .gradient => |*gradient| .{
                        .paint_type = switch (gradient.kind) {
                            .linear => render_common.PAINT_TYPE_LINEAR_GRADIENT,
                            .radial => render_common.PAINT_TYPE_RADIAL_GRADIENT,
                            .sweep => render_common.PAINT_TYPE_SWEEP_GRADIENT,
                        },
                        .texture_source = null,
                    },
                    .blurred_rounded_rect => .{
                        .paint_type = render_common.PAINT_TYPE_BLURRED_ROUNDED_RECT,
                        .texture_source = null,
                    },
                };

                std.debug.assert(gpu_offset <= render_common.PAINT_TEXTURE_INDEX_MASK);
                break :blk .{
                    .payload = .position,
                    .paint = (render_common.COLOR_SOURCE_PAYLOAD << render_common.COLOR_SOURCE_SHIFT) |
                        (info.paint_type << render_common.PAINT_TYPE_SHIFT) |
                        (gpu_offset & render_common.PAINT_TEXTURE_INDEX_MASK),
                    .texture_source = info.texture_source,
                    .is_opaque = !encoded.mayHaveTransparency(),
                };
            },
        };
    }
};

/// Shader paint type and texture source for an encoded paint.
const EncodedInfo = struct {
    paint_type: u32,
    texture_source: ?TextureSourceId,
};

// ---------------------------------------------------------------------------
// Encoded-paint preparation (`prepare_gpu_encoded_paints`)
// ---------------------------------------------------------------------------

/// Packed encoded-paint texture data and per-paint offsets.
pub const PreparedPaints = struct {
    allocator: std.mem.Allocator,
    /// `Rgba32Uint` texel data for the encoded-paints texture.
    data: std.ArrayList(u8) = .empty,
    /// Texel offset of each encoded paint in `data`.
    offsets: std.ArrayList(u32) = .empty,
    /// Packed gradient LUT bytes (borrowed from the gradient cache until the
    /// next render); recorded here so the caller can size the texture.
    gradient_bytes: []const u8 = &.{},

    /// Release the packed data.
    pub fn deinit(self: *PreparedPaints) void {
        self.data.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
        self.* = undefined;
    }

    /// Number of `Rgba32Uint` texels in the encoded-paints texture.
    pub fn texels(self: *const PreparedPaints) u32 {
        return @intCast(self.data.items.len / 16);
    }
};

/// Pack every encoded paint into its `Rgba32Uint` representation.
///
/// Atlas-backed (`opaque_id`) and pixmap image sources need the image cache /
/// atlas upload path, which is not ported yet; they return `error.Unsupported`
/// rather than approximating.
pub fn prepareGpuEncodedPaints(
    allocator: std.mem.Allocator,
    encoded_paints: []const EncodedPaint,
    cache: *GradientRampCache,
) PrepareError!PreparedPaints {
    var prepared = PreparedPaints{ .allocator = allocator };
    errdefer prepared.deinit();

    try prepared.offsets.ensureTotalCapacity(allocator, encoded_paints.len);
    var current_texel: u32 = 0;

    for (encoded_paints) |*paint| {
        prepared.offsets.appendAssumeCapacity(current_texel);
        switch (paint.*) {
            .image => |*image| {
                const gpu_image = try encodeImagePaint(image);
                const size_texels = render_common.GPU_ENCODED_IMAGE_SIZE_TEXELS;
                try appendPaint(&prepared.data, allocator, .{ .image = gpu_image }, size_texels);
                current_texel += size_texels;
            },
            .gradient => |*gradient| {
                const ramp = try cache.getOrCreateRamp(gradient);
                const gpu_gradient = encodeGradientPaint(gradient, ramp.width, ramp.lut_start);
                const size_texels: u32 = switch (gpu_gradient) {
                    .linear_gradient => render_common.GPU_LINEAR_GRADIENT_SIZE_TEXELS,
                    .radial_gradient => render_common.GPU_RADIAL_GRADIENT_SIZE_TEXELS,
                    .sweep_gradient => render_common.GPU_SWEEP_GRADIENT_SIZE_TEXELS,
                    else => unreachable,
                };
                try appendPaint(&prepared.data, allocator, gpu_gradient, size_texels);
                current_texel += size_texels;
            },
            .blurred_rounded_rect => |*rect| {
                const gpu_rect = encodeBlurredRoundedRectPaint(rect);
                const size_texels = render_common.GPU_BLURRED_ROUNDED_RECT_SIZE_TEXELS;
                try appendPaint(&prepared.data, allocator, .{ .blurred_rounded_rect = gpu_rect }, size_texels);
                current_texel += size_texels;
            },
        }
    }

    prepared.gradient_bytes = cache.lutsBytes();
    return prepared;
}

fn appendPaint(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    paint: render_common.GpuEncodedPaint,
    size_texels: u32,
) std.mem.Allocator.Error!void {
    const bytes = paint.asBytes();
    std.debug.assert(bytes.len == @as(usize, size_texels) * 16);
    try list.appendSlice(allocator, bytes);
}

/// Build the `GpuEncodedImage` for an encoded image paint.
pub fn encodeImagePaint(image: *const EncodedImage) PrepareError!render_common.GpuEncodedImage {
    const coeffs = image.transform.asCoeffs();
    const transform: [6]f32 = .{
        @floatCast(coeffs[0]),
        @floatCast(coeffs[1]),
        @floatCast(coeffs[2]),
        @floatCast(coeffs[3]),
        @floatCast(coeffs[4]),
        @floatCast(coeffs[5]),
    };

    const tint = render_common.packTint(image.tint);
    const quality: u32 = @intFromEnum(image.sampler.quality);
    const extend_x: u32 = image.sampler.x_extend.toU8();
    const extend_y: u32 = image.sampler.y_extend.toU8();
    const params = render_common.packImageParams(quality, extend_x, extend_y);

    return switch (image.source) {
        .external_texture => |external| .{
            .image_params = params,
            .image_size = render_common.packImageSize(
                external.source_region.width(),
                external.source_region.height(),
            ),
            .image_offset = render_common.packImageOffset(
                external.source_region.x0,
                external.source_region.y0,
            ),
            .transform = transform,
            .tint = tint.color,
            .tint_mode = tint.mode,
            .image_padding = 0,
        },
        // Atlas-backed images need the atlas upload path (`resources.rs`);
        // pixmap sources are explicitly unsupported by upstream GPU too.
        .opaque_id, .pixmap => error.Unsupported,
    };
}

/// Build the `GpuEncodedPaint` for an encoded gradient (upstream
/// `encode_gradient_paint`).
pub fn encodeGradientPaint(
    gradient: *const common.encode.EncodedGradient,
    gradient_width: u32,
    gradient_start: u32,
) render_common.GpuEncodedPaint {
    const coeffs = gradient.transform.asCoeffs();
    const transform: [6]f32 = .{
        @floatCast(coeffs[0]),
        @floatCast(coeffs[1]),
        @floatCast(coeffs[2]),
        @floatCast(coeffs[3]),
        @floatCast(coeffs[4]),
        @floatCast(coeffs[5]),
    };
    const extend_mode: u32 = gradient.extend.toU8();
    const texture_width_and_extend_mode =
        render_common.packTextureWidthAndExtendMode(gradient_width, extend_mode);

    return switch (gradient.kind) {
        .linear => .{ .linear_gradient = .{
            .texture_width_and_extend_mode = texture_width_and_extend_mode,
            .gradient_start = gradient_start,
            .transform = transform,
        } },
        .radial => |radial| .{
            .radial_gradient = encodeRadialGradient(radial, texture_width_and_extend_mode, gradient_start, transform),
        },
        .sweep => |sweep| .{ .sweep_gradient = .{
            .texture_width_and_extend_mode = texture_width_and_extend_mode,
            .gradient_start = gradient_start,
            .transform = transform,
            .start_angle = sweep.start_angle,
            .inv_angle_delta = sweep.inv_angle_delta,
            ._padding = .{ 0, 0 },
        } },
    };
}

fn encodeRadialGradient(
    radial: common.encode.RadialKind,
    texture_width_and_extend_mode: u32,
    gradient_start: u32,
    transform: [6]f32,
) render_common.GpuRadialGradient {
    var result = render_common.GpuRadialGradient{
        .texture_width_and_extend_mode = texture_width_and_extend_mode,
        .gradient_start = gradient_start,
        .transform = transform,
        .kind_and_f_is_swapped = 0,
        .bias = 0.0,
        .scale = 0.0,
        .fp0 = 0.0,
        .fp1 = 0.0,
        .fr1 = 0.0,
        .f_focal_x = 0.0,
        .scaled_r0_squared = 0.0,
    };
    switch (radial) {
        .radial => |value| {
            result.kind_and_f_is_swapped = render_common.packRadialKindAndSwapped(0, 0);
            result.bias = value.bias;
            result.scale = value.scale;
        },
        .strip => |value| {
            result.kind_and_f_is_swapped = render_common.packRadialKindAndSwapped(1, 0);
            result.scaled_r0_squared = value.scaled_r0_squared;
        },
        .focal => |value| {
            result.kind_and_f_is_swapped = render_common.packRadialKindAndSwapped(
                2,
                @intFromBool(value.focal_data.f_is_swapped),
            );
            result.bias = value.fp0;
            result.scale = value.fp1;
            result.fp0 = value.fp0;
            result.fp1 = value.fp1;
            result.fr1 = value.focal_data.fr1;
            result.f_focal_x = value.focal_data.f_focal_x;
        },
    }
    return result;
}

/// Build the `GpuEncodedPaint` for a blurred rounded rectangle (upstream
/// `encode_blurred_rounded_rect_paint`).
pub fn encodeBlurredRoundedRectPaint(
    rect: *const common.encode.EncodedBlurredRoundedRectangle,
) render_common.GpuBlurredRoundedRect {
    const coeffs = rect.transform.asCoeffs();
    return .{
        .transform = .{
            @floatCast(coeffs[0]),
            @floatCast(coeffs[1]),
            @floatCast(coeffs[2]),
            @floatCast(coeffs[3]),
            @floatCast(coeffs[4]),
            @floatCast(coeffs[5]),
        },
        .color = rect.color.asPremulRgba8().toU32(),
        .invert = @intFromBool(rect.invert),
        .params0 = .{ rect.exponent, rect.recip_exponent, rect.scale, rect.std_dev_inv },
        .params1 = .{ rect.min_edge, rect.w, rect.h, rect.r1 },
        .size = .{ rect.width, rect.height },
        ._padding1 = .{ 0, 0 },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "solid paint packs to opaque premultiplied rgba" {
    const resolver = PaintResolver.solid_only;
    const paint = Paint.fromAlphaColor(peniko.color.Color.fromRgba8(30, 80, 200, 255));
    const packed_paint = try resolver.pack(&paint);

    try testing.expect(packed_paint.is_opaque);
    try testing.expectEqual(@as(?TextureSourceId, null), packed_paint.texture_source);
    try testing.expectEqual(@as(u32, 0), packed_paint.paint);
    // Premultiplied RGBA8 packs r least significant (WGSL `pack4x8unorm`).
    try testing.expectEqual(@as(u32, 0xFFC8_501E), packed_paint.payloadAt(0, 0));
}

test "translucent solid paint is not opaque" {
    const resolver = PaintResolver.solid_only;
    const paint = Paint.fromAlphaColor(peniko.color.Color.fromRgba8(255, 0, 0, 128));
    const packed_paint = try resolver.pack(&paint);

    try testing.expect(!packed_paint.is_opaque);
    // 128/255 premultiplies the red channel to 128 with `+0.5` rounding.
    try testing.expectEqual(@as(u32, 0x8000_0080), packed_paint.payloadAt(0, 0));
}

test "payload position packs the strip origin" {
    const packed_paint = PackedPaint{
        .payload = .position,
        .paint = 0,
        .texture_source = null,
        .is_opaque = false,
    };
    try testing.expectEqual(@as(u32, 0x0002_0001), packed_paint.payloadAt(1, 2));
}

test "indexed paint is unsupported" {
    const resolver = PaintResolver.solid_only;
    const paint = Paint{ .indexed = .{ .value = 3 } };
    try testing.expectError(error.Unsupported, resolver.pack(&paint));
}
