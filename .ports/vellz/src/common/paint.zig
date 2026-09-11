//! Port of vello_common paint.rs (Apache-2.0 OR MIT).
//!
//! `PaintType` replaces upstream's `peniko::Brush<Image, Gradient>` with the
//! explicit Vello specialization: a tagged union of a solid sRGB color, a
//! gradient, and a vello image. No general-purpose brush type is defined
//! here; `peniko` owns colors and gradients, this module owns the Vello image
//! and tint types.
//!
//! Ownership/allocator note: solid colors are plain values. A
//! `PaintType.image` payload owns an `ImageSource`, which either shares a
//! pixmap through `common/shared.zig` (`Shared(Pixmap)`, reachable via
//! `clone`/`deinit`) or is a plain handle. Releasing an image source requires
//! the allocator that created the shared pixmap. `ImageResolver.resolve`
//! returns a caller-owned `Shared(Pixmap)` reference (upstream `Arc<Pixmap>`
//! clone semantics).

const std = @import("std");
const peniko = @import("../peniko/root.zig");
const geometry = @import("geometry.zig");
const pixmap_mod = @import("pixmap.zig");
const shared = @import("shared.zig");

const Pixmap = pixmap_mod.Pixmap;
const PixelMetadata = pixmap_mod.PixelMetadata;
const RectU16 = geometry.RectU16;
const Shared = shared.Shared;

/// A paint that needs to be resolved via its index.
///
/// Upstream keeps the `u32` private so the representation can change without
/// breaking the API; this port exposes it as `value` and keeps the accessors.
pub const IndexedPaint = struct {
    value: u32,

    /// Upstream panics ("exceeded the maximum number of paints"); this port
    /// returns an explicit error instead.
    pub const Error = error{TooManyPaints};

    /// Create a new indexed paint from an index.
    pub fn new(index_value: usize) Error!IndexedPaint {
        return .{ .value = std.math.cast(u32, index_value) orelse return error.TooManyPaints };
    }

    /// Return the index of the paint.
    pub fn index(self: IndexedPaint) usize {
        return self.value;
    }
};

/// A paint used internally by a rendering frontend to store how a draw should
/// be painted.
///
/// There are only two types of paint:
///
/// 1) Simple solid colors, which are stored in premultiplied representation so
///    that the renderer doesn't have to recompute it.
/// 2) Indexed paints, which can represent any arbitrary, more complex paint
///    that is determined by the frontend.
pub const Paint = union(enum) {
    /// A premultiplied RGBA8 color.
    solid: PremulColor,
    /// A paint that needs to be resolved via an index.
    indexed: IndexedPaint,

    /// Build a solid paint from a straight-alpha sRGB color.
    pub fn fromAlphaColor(color: peniko.color.Color) Paint {
        return .{ .solid = PremulColor.fromAlphaColor(color) };
    }

    /// Build a solid paint from an already-premultiplied color.
    pub fn fromPremulColor(color: PremulColor) Paint {
        return .{ .solid = color };
    }
};

/// Opaque image handle.
pub const ImageId = struct {
    /// The raw image identifier.
    value: u32,

    /// Create a new image id from a `u32`.
    pub fn new(value: u32) ImageId {
        return .{ .value = value };
    }

    /// Return the image id as a `u32`.
    pub fn asU32(self: ImageId) u32 {
        return self.value;
    }
};

/// A handle to an external, user-provided texture.
///
/// This is resolved at render time by passing in a mapping of handles to
/// textures, but is otherwise opaque to the renderer (upstream
/// `vello_common::TextureId`).
pub const TextureId = struct {
    /// The raw texture identifier.
    value: u64,

    /// Create a new texture id from a `u64`.
    pub fn new(value: u64) TextureId {
        return .{ .value = value };
    }

    /// Return the texture id as a `u64`.
    pub fn asU64(self: TextureId) u64 {
        return self.value;
    }
};

/// Bitmap source used by `Image`.
pub const ImageSource = union(enum) {
    /// Pixmap pixels travel with the scene packet.
    pixmap: Shared(Pixmap),
    /// Pixmap pixels were registered earlier; this is just a handle.
    opaque_id: OpaqueId,
    /// An externally owned texture supplied to the renderer at render time.
    external_texture: ExternalTexture,

    /// A pre-registered image handle.
    pub const OpaqueId = struct {
        /// The image handle.
        id: ImageId,
        /// Whether the image may contain non-opaque pixels.
        may_have_transparency: bool,
    };

    /// An external texture reference.
    pub const ExternalTexture = struct {
        /// Opaque external texture handle.
        id: TextureId,
        /// Source region to sample from in texel coordinates.
        source_region: RectU16,
        /// Whether the source region may contain non-opaque pixels.
        may_have_transparency: bool,
    };

    /// Errors from `initExternalTexture`.
    pub const Error = error{EmptySourceRegion};

    /// Create an `ImageSource` from a pixmap that travels with the scene
    /// packet. The caller transfers one `Shared` reference.
    pub fn initPixmap(pixmap_handle: Shared(Pixmap)) ImageSource {
        return .{ .pixmap = pixmap_handle };
    }

    /// Create an [`ImageSource`] from a pre-registered image handle.
    ///
    /// Conservatively assumes the image may have non-opaque pixels. Use
    /// `initOpaqueIdWithTransparencyHint` when you know the image is fully
    /// opaque.
    pub fn initOpaqueId(id: ImageId) ImageSource {
        return .{ .opaque_id = .{ .id = id, .may_have_transparency = true } };
    }

    /// Create an [`ImageSource`] from a pre-registered image handle, with an
    /// explicit hint about whether the image may have non-opaque pixels.
    pub fn initOpaqueIdWithTransparencyHint(
        id: ImageId,
        may_have_transparency: bool,
    ) ImageSource {
        return .{ .opaque_id = .{
            .id = id,
            .may_have_transparency = may_have_transparency,
        } };
    }

    /// Create an image source backed by a texture supplied to the renderer at
    /// render time.
    ///
    /// Upstream panics if `source_region` is empty; this port returns
    /// `error.EmptySourceRegion` instead.
    pub fn initExternalTexture(
        texture_id: TextureId,
        source_region: RectU16,
        may_have_transparency: bool,
    ) Error!ImageSource {
        if (source_region.isEmpty()) return error.EmptySourceRegion;
        return .{ .external_texture = .{
            .id = texture_id,
            .source_region = source_region,
            .may_have_transparency = may_have_transparency,
        } };
    }

    /// Returns whether this image source may contain non-opaque pixels.
    pub fn mayHaveTransparency(self: ImageSource) bool {
        return switch (self) {
            .pixmap => |p| p.get().mayHaveTransparency(),
            .opaque_id => |value| value.may_have_transparency,
            .external_texture => |value| value.may_have_transparency,
        };
    }

    /// Retain a new owned copy.
    ///
    /// Only the `pixmap` variant owns a reference; the handle variants are
    /// plain values.
    pub fn clone(self: ImageSource) ImageSource {
        return switch (self) {
            .pixmap => |p| .{ .pixmap = p.clone() },
            .opaque_id => |value| .{ .opaque_id = value },
            .external_texture => |value| .{ .external_texture = value },
        };
    }

    /// Release the owned shared pixmap, if any.
    pub fn deinit(self: *ImageSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pixmap => |p| p.release(allocator),
            .opaque_id, .external_texture => {},
        }
    }

    /// Errors from `fromPenikoImageData`.
    pub const FromPenikoImageDataError = error{
        ImageTooLarge,
        UnsupportedImageFormat,
        InvalidDataLength,
        OutOfMemory,
    };

    /// Convert a `peniko.ImageData` to an `ImageSource`.
    ///
    /// This is a somewhat lossy conversion, as the image data is transformed
    /// to premultiplied RGBA8.
    ///
    /// Upstream asserts that the image is at most `u16::MAX` in either
    /// dimension and calls `unimplemented!` for other formats; this port
    /// returns `error.ImageTooLarge` / `error.UnsupportedImageFormat`.
    pub fn fromPenikoImageData(
        allocator: std.mem.Allocator,
        image: *const peniko.image.ImageData,
    ) FromPenikoImageDataError!ImageSource {
        if (image.width > std.math.maxInt(u16) or image.height > std.math.maxInt(u16)) {
            return error.ImageTooLarge;
        }
        const width: u16 = @intCast(image.width);
        const height: u16 = @intCast(image.height);

        if (image.format != .rgba8 and image.format != .bgra8) {
            return error.UnsupportedImageFormat;
        }

        const expected = @as(usize, width) * @as(usize, height) * 4;
        if (image.data.len != expected) return error.InvalidDataLength;

        // Upstream copies the pixel bytes because the pixmap takes ownership;
        // `Pixmap.fromParts` also copies into its owned buffer, so this is a
        // staging buffer for the BGRA swap and premultiplication.
        const rgba = try allocator.dupe(u8, image.data[0..expected]);
        defer allocator.free(rgba);

        if (image.format == .bgra8) {
            var i: usize = 0;
            while (i < rgba.len) : (i += 4) {
                std.mem.swap(u8, &rgba[i], &rgba[i + 2]);
            }
        }

        var converted = try Pixmap.fromParts(
            allocator,
            rgba,
            width,
            height,
            PixelMetadata.new(image.alpha_type, true),
        );
        errdefer converted.deinit(allocator);

        return .{ .pixmap = try Shared(Pixmap).create(allocator, converted) };
    }
};

/// An image brush: an image source plus sampling parameters.
///
/// Upstream `peniko::ImageBrush<ImageSource>`.
pub const Image = struct {
    /// The image to render.
    image: ImageSource,
    /// Parameters which specify how to sample from the image during rendering.
    sampler: peniko.ImageSampler,

    /// Retain a new owned copy (bumps the shared pixmap reference count).
    pub fn clone(self: Image) Image {
        return .{ .image = self.image.clone(), .sampler = self.sampler };
    }

    /// Release the owned image source.
    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
    }
};

/// Trait for resolving opaque image IDs to pixmaps at rasterization time.
///
/// This allows delaying the resolution of `ImageSource.opaque_id` until the
/// image is actually needed during rasterization (for example dynamic sprite
/// atlases whose contents may change between encoding and rendering).
///
/// Upstream is a `dyn ImageResolver` trait object, so this port keeps dynamic
/// dispatch through a function pointer. `resolve` may be called repeatedly
/// (dozens or hundreds of times per frame) and should therefore be very fast.
/// Upstream requires `Send + Sync`; Zig callers must ensure the implementation
/// is safe to call from wherever the resolver is shared.
pub const ImageResolver = struct {
    /// Implementation function. The returned reference is owned by the caller
    /// (upstream returns a cloned `Arc<Pixmap>`), or null if the id is not
    /// registered.
    resolveFn: *const fn (context: ?*const anyopaque, id: ImageId) ?Shared(Pixmap),
    /// Opaque user context passed through to `resolveFn`.
    context: ?*const anyopaque = null,

    /// Resolve an `ImageId` to its pixmap data.
    ///
    /// Returns null if the image ID is not found in the registry.
    pub fn resolve(self: ImageResolver, id: ImageId) ?Shared(Pixmap) {
        return self.resolveFn(self.context, id);
    }
};

/// A no-op image resolver that always returns `null`.
pub const NoOpImageResolver = struct {
    /// Resolve nothing.
    pub fn resolve(_: NoOpImageResolver, _: ImageId) ?Shared(Pixmap) {
        return null;
    }

    fn resolveErased(_: ?*const anyopaque, _: ImageId) ?Shared(Pixmap) {
        return null;
    }

    /// The dynamically dispatched form of this resolver (upstream
    /// `&NoOpImageResolver`).
    pub fn imageResolver(_: NoOpImageResolver) ImageResolver {
        return .{ .resolveFn = resolveErased };
    }
};

/// Ready-made `ImageResolver` for the no-op resolver.
pub const NO_OP_IMAGE_RESOLVER: ImageResolver = .{ .resolveFn = NoOpImageResolver.resolveErased };

/// A premultiplied color.
pub const PremulColor = struct {
    /// The color in premultiplied RGBA8.
    premul_u8: peniko.PremulRgba8,
    /// The color in premultiplied f32 sRGB.
    premul_f32: peniko.PremulColor(peniko.Srgb),

    /// Create a new premultiplied color.
    pub fn fromAlphaColor(color: peniko.color.Color) PremulColor {
        return fromPremulColor(color.premultiply());
    }

    /// Create a new premultiplied color from `peniko.PremulColor`.
    pub fn fromPremulColor(color: peniko.PremulColor(peniko.Srgb)) PremulColor {
        return .{ .premul_u8 = color.toRgba8(), .premul_f32 = color };
    }

    /// Return the color as a premultiplied RGBA8 color.
    pub fn asPremulRgba8(self: PremulColor) peniko.PremulRgba8 {
        return self.premul_u8;
    }

    /// Return the color as a premultiplied f32 color.
    pub fn asPremulF32(self: PremulColor) peniko.PremulColor(peniko.Srgb) {
        return self.premul_f32;
    }

    /// Return whether the color is opaque (i.e. doesn't have transparency).
    pub fn isOpaque(self: PremulColor) bool {
        return self.premul_f32.components[3] == 1.0;
    }

    /// Return whether the color is fully transparent.
    pub fn isTransparent(self: PremulColor) bool {
        return self.premul_f32.components[3] == 0.0;
    }
};

/// How tint color is applied to an image.
pub const TintMode = enum(u8) {
    /// Alpha-mask tinting: `tint_premul * source.alpha`.
    ///
    /// The source image's alpha channel is used as a coverage mask, and the
    /// result is filled with the premultiplied tint color. This is the
    /// standard approach for glyph / monochrome image tinting.
    alpha_mask = 0,
    /// Component-wise multiply: `source * tint`.
    ///
    /// Each channel of the source pixel is multiplied by the corresponding
    /// channel of the tint color. This works well for full-color images.
    multiply = 1,

    /// Return the discriminant as a `u32`.
    pub fn asU32(self: TintMode) u32 {
        return @backingInt(self);
    }
};

/// A tint applied to image paints.
pub const Tint = struct {
    /// The tint color.
    color: peniko.color.Color,
    /// How the tint is applied.
    mode: TintMode,
};

/// A kind of paint that can be used for filling and stroking shapes.
///
/// Upstream `peniko::Brush<Image, Gradient>`; this is the Vello specialization
/// so that no second general-purpose brush type exists in the port.
pub const PaintType = union(enum) {
    /// Solid color paint.
    solid: peniko.color.Color,
    /// Gradient paint.
    gradient: peniko.Gradient,
    /// Image paint.
    image: Image,

    /// Build a solid paint (`From<AlphaColor<Srgb>>` upstream).
    pub fn fromAlphaColor(color: peniko.color.Color) PaintType {
        return .{ .solid = color };
    }

    /// Build a gradient paint (`From<Gradient>` upstream).
    pub fn fromGradient(gradient: peniko.Gradient) PaintType {
        return .{ .gradient = gradient };
    }

    /// Build an image paint (`From<ImageBrush<D>>` upstream).
    pub fn fromImage(image: Image) PaintType {
        return .{ .image = image };
    }

    /// Retain a new owned copy.
    ///
    /// Gradients clone their stops with the allocator (peniko contract);
    /// images bump the shared pixmap reference count.
    pub fn clone(self: PaintType, allocator: std.mem.Allocator) std.mem.Allocator.Error!PaintType {
        return switch (self) {
            .solid => |color| .{ .solid = color },
            .gradient => |gradient| .{ .gradient = try gradient.clone(allocator) },
            .image => |image| .{ .image = image.clone() },
        };
    }

    /// Release the payload's owned resources.
    pub fn deinit(self: *PaintType, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .solid => {},
            .gradient => |*gradient| gradient.deinit(),
            .image => |*image| image.deinit(allocator),
        }
    }
};

test "premul_color_conversion" {
    const black = peniko.color.Color.BLACK;
    const premul = PremulColor.fromAlphaColor(black);
    try std.testing.expect(premul.isOpaque());
    try std.testing.expect(!premul.isTransparent());
    try std.testing.expectEqual(peniko.PremulRgba8{ .r = 0, .g = 0, .b = 0, .a = 255 }, premul.asPremulRgba8());

    const transparent = PremulColor.fromAlphaColor(peniko.color.Color.TRANSPARENT);
    try std.testing.expect(transparent.isTransparent());
    try std.testing.expect(!transparent.isOpaque());

    const half = PremulColor.fromAlphaColor(peniko.color.Color.new(.{ 0.2, 0.4, 0.6, 0.5 }));
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.5 }, &half.asPremulF32().components);
    try std.testing.expectEqual(peniko.PremulRgba8{ .r = 26, .g = 51, .b = 77, .a = 128 }, half.asPremulRgba8());

    const paint = Paint.fromAlphaColor(black);
    try std.testing.expectEqual(PremulColor.fromAlphaColor(black), paint.solid);
}

test "indexed_paint_capacity" {
    const paint = try IndexedPaint.new(42);
    try std.testing.expectEqual(@as(usize, 42), paint.index());

    _ = try IndexedPaint.new(std.math.maxInt(u32));
    try std.testing.expectError(
        error.TooManyPaints,
        IndexedPaint.new(@as(usize, std.math.maxInt(u32)) + 1),
    );
}

test "tint_mode_discriminants" {
    try std.testing.expectEqual(@as(u32, 0), TintMode.alpha_mask.asU32());
    try std.testing.expectEqual(@as(u32, 1), TintMode.multiply.asU32());

    const tint = Tint{ .color = peniko.color.Color.fromRgb8(255, 0, 0), .mode = .multiply };
    try std.testing.expectEqual(TintMode.multiply, tint.mode);
}

test "image_ids" {
    try std.testing.expectEqual(@as(u32, 7), ImageId.new(7).asU32());
    try std.testing.expectEqual(@as(u64, 9), TextureId.new(9).asU64());
}

test "image_source_variants" {
    const opaque_source = ImageSource.initOpaqueId(ImageId.new(1));
    try std.testing.expect(opaque_source.mayHaveTransparency());
    try std.testing.expectEqual(@as(u32, 1), opaque_source.opaque_id.id.value);

    const hinted = ImageSource.initOpaqueIdWithTransparencyHint(ImageId.new(2), false);
    try std.testing.expect(!hinted.mayHaveTransparency());

    const external = try ImageSource.initExternalTexture(
        TextureId.new(3),
        RectU16.new(0, 0, 4, 4),
        false,
    );
    try std.testing.expect(!external.mayHaveTransparency());
    try std.testing.expectError(
        error.EmptySourceRegion,
        ImageSource.initExternalTexture(TextureId.new(3), RectU16.new(0, 0, 0, 0), true),
    );
}

test "from_peniko_image_data_computes_transparency_hint" {
    const allocator = std.testing.allocator;
    const make = struct {
        fn f(
            alloc: std.mem.Allocator,
            pixels: []const u8,
            alpha_type: peniko.ImageAlphaType,
        ) !peniko.image.ImageData {
            return peniko.image.ImageData.init(
                alloc,
                pixels,
                .rgba8,
                alpha_type,
                @intCast(pixels.len / 4),
                1,
            );
        }
    }.f;

    var opaque_data = try make(allocator, &.{ 10, 20, 30, 255, 40, 50, 60, 255 }, .alpha);
    defer opaque_data.deinit();
    var opaque_source = try ImageSource.fromPenikoImageData(allocator, &opaque_data);
    defer opaque_source.deinit(allocator);
    try std.testing.expect(!opaque_source.mayHaveTransparency());

    var translucent_data = try make(allocator, &.{ 10, 20, 30, 255, 40, 50, 60, 128 }, .alpha);
    defer translucent_data.deinit();
    var translucent = try ImageSource.fromPenikoImageData(allocator, &translucent_data);
    defer translucent.deinit(allocator);
    try std.testing.expect(translucent.mayHaveTransparency());

    var premultiplied_data = try make(
        allocator,
        &.{ 10, 20, 30, 255, 40, 50, 60, 255 },
        .alpha_premultiplied,
    );
    defer premultiplied_data.deinit();
    var premultiplied = try ImageSource.fromPenikoImageData(allocator, &premultiplied_data);
    defer premultiplied.deinit(allocator);
    try std.testing.expect(premultiplied.mayHaveTransparency());
}

test "from_peniko_image_data_rejects_oversized_images" {
    const allocator = std.testing.allocator;
    var too_large = try peniko.image.ImageData.init(
        allocator,
        &.{},
        .rgba8,
        .alpha,
        @as(u32, std.math.maxInt(u16)) + 1,
        1,
    );
    defer too_large.deinit();
    try std.testing.expectError(
        error.ImageTooLarge,
        ImageSource.fromPenikoImageData(allocator, &too_large),
    );

    var undersized = try peniko.image.ImageData.init(allocator, &.{}, .rgba8, .alpha, 1, 1);
    defer undersized.deinit();
    try std.testing.expectError(
        error.InvalidDataLength,
        ImageSource.fromPenikoImageData(allocator, &undersized),
    );
}

test "image_source_shared_pixmap_ownership" {
    const allocator = std.testing.allocator;
    const pixmap_handle = try Shared(Pixmap).create(allocator, try Pixmap.init(allocator, 1, 1));

    var source = ImageSource.initPixmap(pixmap_handle);
    const copy = source.clone();
    try std.testing.expectEqual(@as(usize, 2), source.pixmap.refCount());
    try std.testing.expect(source.mayHaveTransparency());

    var image = Image{ .image = copy, .sampler = peniko.ImageSampler.default };
    var image_copy = image.clone();
    try std.testing.expectEqual(@as(usize, 3), source.pixmap.refCount());

    image_copy.image.deinit(allocator);
    image.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), source.pixmap.refCount());

    source.deinit(allocator);
    // The testing allocator verifies the pixmap was freed with the last
    // reference.
}

test "paint_type_constructors_and_cleanup" {
    const allocator = std.testing.allocator;

    const solid = PaintType.fromAlphaColor(peniko.color.Color.BLACK);
    try std.testing.expectEqual(peniko.color.Color.BLACK, solid.solid);

    const pixmap_handle = try Shared(Pixmap).create(allocator, try Pixmap.init(allocator, 1, 1));
    var paint = PaintType.fromImage(.{
        .image = ImageSource.initPixmap(pixmap_handle),
        .sampler = peniko.ImageSampler.default,
    });
    var cloned = try paint.clone(allocator);
    try std.testing.expectEqual(@as(usize, 2), paint.image.image.pixmap.refCount());

    cloned.deinit(allocator);
    paint.deinit(allocator);
    // The testing allocator verifies the shared pixmap was freed.
}

test "image_resolver_noop" {
    const resolver = NoOpImageResolver.imageResolver(.{});
    try std.testing.expectEqual(@as(?Shared(Pixmap), null), resolver.resolve(ImageId.new(1)));
    try std.testing.expectEqual(@as(?Shared(Pixmap), null), NO_OP_IMAGE_RESOLVER.resolve(ImageId.new(2)));
    try std.testing.expectEqual(@as(?Shared(Pixmap), null), NoOpImageResolver.resolve(.{}, ImageId.new(3)));
}
