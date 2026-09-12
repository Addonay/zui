//! Port of `vello_gpu/src/paint.rs` (Apache-2.0 OR MIT).
//!
//! GPU paint packing for scheduled strip draws. The first strip-pass milestone
//! supports solid paints only: encoded (indexed) paints need the gradient cache
//! and the encoded-paints GPU offset table, which are not ported yet. Packing
//! an indexed paint returns `error.Unsupported` — never a silent fallback.
//!
//! CPU-safe: imports only `vellz.common.paint` and the layout constants from
//! `render/common.zig`.

const std = @import("std");
const common = @import("../common/root.zig");
const util = @import("util.zig");
const render_common = @import("render/common.zig");

const Paint = common.paint.Paint;

/// Errors from resolving a paint to its GPU representation.
pub const Error = error{
    /// The paint kind is not implemented by this milestone (indexed paints:
    /// gradients, images, blurred rounded rects).
    Unsupported,
};

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
///
/// The solid-only milestone has no encoded-paint storage; the type is kept as
/// a value so `draw.zig` can be generic over future resolvers.
pub const PaintResolver = struct {
    /// Empty resolver: only solid paints resolve.
    pub const solid_only: PaintResolver = .{};

    /// Pack one recorded paint for the shader.
    pub fn pack(self: PaintResolver, paint: *const Paint) Error!PackedPaint {
        _ = self;
        return switch (paint.*) {
            .solid => |color| .{
                .payload = .{ .solid = color.asPremulRgba8().toU32() },
                .paint = (render_common.COLOR_SOURCE_PAYLOAD << render_common.COLOR_SOURCE_SHIFT) |
                    (render_common.PAINT_TYPE_SOLID << render_common.PAINT_TYPE_SHIFT),
                .texture_source = null,
                .is_opaque = color.isOpaque(),
            },
            .indexed => error.Unsupported,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const peniko = @import("../peniko/root.zig");

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
