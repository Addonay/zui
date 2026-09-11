//! Port of peniko 0.6.1 image.rs (Apache-2.0 OR MIT).
//!
//! Upstream `ImageBrush<D = ImageData>` is generic over the image storage and
//! uses `Blob<u8>` for shared ownership; `ImageBrushRef<'a>` is the borrowed
//! form. This port keeps the generic brush (`Image`, an alias of
//! `ImageBrush`, is generic too), and adds [`ImageSource`], an owned-or-borrowed
//! storage type used as the peniko-side default. `vello_common` defines its
//! own `ImageSource` and instantiates `ImageBrush` with it.

const std = @import("std");
const gradient = @import("gradient.zig");

pub const Extend = gradient.Extend;

/// Defines the pixel format of an [`ImageData`].
pub const ImageFormat = enum(u8) {
    /// 32-bit RGBA with 8-bit channels.
    rgba8 = 0,
    /// 32-bit BGRA with 8-bit channels.
    bgra8 = 1,

    /// The default format: [`ImageFormat.rgba8`].
    pub const default: ImageFormat = .rgba8;

    /// Returns the required size in bytes for an image in this format of the
    /// given dimensions, or `null` if the size calculation overflows.
    pub fn sizeInBytes(self: ImageFormat, width: u32, height: u32) ?usize {
        _ = self;
        const w: usize = width;
        const h: usize = height;
        const row = std.math.mul(usize, 4, w) catch return null;
        return std.math.mul(usize, row, h) catch null;
    }

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: ImageFormat) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?ImageFormat {
        if (value > 1) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Handling of the alpha channel in image data.
pub const ImageAlphaType = enum(u8) {
    /// The image has a separate alpha channel (straight/unpremultiplied).
    alpha = 0,
    /// The image has premultiplied alpha.
    alpha_premultiplied = 1,

    /// The default alpha type: [`ImageAlphaType.alpha`].
    pub const default: ImageAlphaType = .alpha;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: ImageAlphaType) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?ImageAlphaType {
        if (value > 1) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Desired quality when sampling an image.
pub const ImageQuality = enum(u8) {
    /// Lowest quality (typically nearest-neighbor).
    low = 0,
    /// Medium quality (typically bilinear).
    medium = 1,
    /// Highest quality (typically bicubic).
    high = 2,

    /// The upstream `Default` implementation: [`ImageQuality.medium`].
    pub const default: ImageQuality = .medium;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: ImageQuality) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?ImageQuality {
        if (value > 2) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Parameters that specify how to sample an image during rendering.
pub const ImageSampler = struct {
    /// Extend mode in the horizontal direction.
    x_extend: Extend = .pad,
    /// Extend mode in the vertical direction.
    y_extend: Extend = .pad,
    /// Hint for desired rendering quality.
    quality: ImageQuality = .medium,
    /// An additional alpha multiplier to use with the image.
    alpha: f32 = 1.0,

    /// The upstream `Default` implementation.
    pub const default: ImageSampler = .{};

    /// Creates a new sampler with default values.
    pub fn new() ImageSampler {
        return .{};
    }

    /// Set the extend mode in both directions.
    pub fn withExtend(self: ImageSampler, mode: Extend) ImageSampler {
        var result = self;
        result.x_extend = mode;
        result.y_extend = mode;
        return result;
    }

    /// Set the extend mode in the horizontal direction.
    pub fn withXExtend(self: ImageSampler, mode: Extend) ImageSampler {
        var result = self;
        result.x_extend = mode;
        return result;
    }

    /// Set the extend mode in the vertical direction.
    pub fn withYExtend(self: ImageSampler, mode: Extend) ImageSampler {
        var result = self;
        result.y_extend = mode;
        return result;
    }

    /// Set the desired sampling quality.
    pub fn withQuality(self: ImageSampler, quality: ImageQuality) ImageSampler {
        var result = self;
        result.quality = quality;
        return result;
    }

    /// Set the alpha multiplier to `alpha`.
    pub fn withAlpha(self: ImageSampler, alpha: f32) ImageSampler {
        std.debug.assert(std.math.isFinite(alpha) and alpha >= 0.0);
        var result = self;
        result.alpha = alpha;
        return result;
    }

    /// Multiply the alpha multiplier by `alpha`.
    ///
    /// The behavior of this transformation is undefined if `alpha` is
    /// negative.
    pub fn multiplyAlpha(self: ImageSampler, alpha: f32) ImageSampler {
        std.debug.assert(std.math.isFinite(alpha) and alpha >= 0.0);
        var result = self;
        result.alpha *= alpha;
        return result;
    }
};

/// Owned image resource: pixel bytes plus format and dimensions.
///
/// The `data` slice is owned when `allocator` is non-null; a struct literal
/// with a borrowed slice leaves `allocator` null and `deinit` is a no-op.
/// Prefer [`ImageData.init`] (copies) or [`ImageData.initTakeOwnership`]
/// (adopts an existing allocation).
pub const ImageData = struct {
    /// Pixel bytes.
    data: []const u8 = &.{},
    /// Pixel format of the image.
    format: ImageFormat = .rgba8,
    /// Encoding of alpha in the image pixels.
    alpha_type: ImageAlphaType = .alpha,
    /// Width of the image.
    width: u32 = 0,
    /// Height of the image.
    height: u32 = 0,
    /// Allocator owning `data`, or null for borrowed data.
    allocator: ?std.mem.Allocator = null,

    /// Copy `data` into a new allocation owned by the result.
    pub fn init(
        allocator: std.mem.Allocator,
        data: []const u8,
        format: ImageFormat,
        alpha_type: ImageAlphaType,
        width: u32,
        height: u32,
    ) !ImageData {
        const owned = try allocator.dupe(u8, data);
        return .{
            .data = owned,
            .format = format,
            .alpha_type = alpha_type,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Adopt an existing allocation without copying.
    ///
    /// `data` must have been allocated by `allocator`; it is freed by
    /// [`ImageData.deinit`].
    pub fn initTakeOwnership(
        allocator: std.mem.Allocator,
        data: []u8,
        format: ImageFormat,
        alpha_type: ImageAlphaType,
        width: u32,
        height: u32,
    ) ImageData {
        return .{
            .data = data,
            .format = format,
            .alpha_type = alpha_type,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Free the owned pixel data. Safe to call repeatedly.
    pub fn deinit(self: *ImageData) void {
        if (self.allocator) |allocator| {
            allocator.free(self.data);
        }
        self.* = .{};
    }

    /// Deep-copy the image data using `allocator`.
    pub fn clone(self: *const ImageData, allocator: std.mem.Allocator) !ImageData {
        return init(allocator, self.data, self.format, self.alpha_type, self.width, self.height);
    }

    /// The required size in bytes for this image, or `null` on overflow.
    pub fn sizeInBytes(self: *const ImageData) ?usize {
        return self.format.sizeInBytes(self.width, self.height);
    }
};

/// Owned-or-borrowed image storage for [`Image`].
///
/// Upstream peniko 0.6.1 has no `ImageSource`: `ImageBrush<D>` is generic over
/// the storage and `Blob<u8>` handles shared ownership. `vello_common` defines
/// its own `ImageSource` (pixmaps, opaque ids, external textures). This union
/// is the peniko-side default storage for brushes that need either an owned
/// image or a borrowed one without reference counting.
pub const ImageSource = union(enum) {
    /// Image data owned by this value.
    owned: ImageData,
    /// Image data borrowed from the caller; the caller must keep it alive.
    borrowed: *const ImageData,

    /// Access the image data regardless of ownership.
    pub fn data(self: *const ImageSource) *const ImageData {
        return switch (self.*) {
            .owned => |*image| image,
            .borrowed => |image| image,
        };
    }

    /// Free the image data if it is owned. Safe to call repeatedly.
    pub fn deinit(self: *ImageSource) void {
        switch (self.*) {
            .owned => |*image| {
                image.deinit();
                self.* = .{ .owned = .{} };
            },
            .borrowed => {},
        }
    }

    /// Deep-copy owned data, or copy the pointer for borrowed data.
    pub fn clone(self: *const ImageSource, allocator: std.mem.Allocator) !ImageSource {
        return switch (self.*) {
            .owned => |*image| .{ .owned = try image.clone(allocator) },
            .borrowed => |image| .{ .borrowed = image },
        };
    }
};

/// Describes the image content of a filled or stroked shape.
///
/// Generic over the storage `D` (upstream `ImageBrush<D = ImageData>`).
pub fn ImageBrush(comptime D: type) type {
    return struct {
        /// The image to render.
        image: D,
        /// Parameters that specify how to sample from the image.
        sampler: ImageSampler = .{},

        const Self = @This();

        /// Create a brush for `image` with the default sampler.
        pub fn new(image: D) Self {
            return .{ .image = image };
        }

        /// Create a brush for `image` with an explicit sampler.
        pub fn init(image: D, sampler: ImageSampler) Self {
            return .{ .image = image, .sampler = sampler };
        }

        /// Set the extend mode in both directions.
        pub fn withExtend(self: Self, mode: Extend) Self {
            var result = self;
            result.sampler.x_extend = mode;
            result.sampler.y_extend = mode;
            return result;
        }

        /// Set the extend mode in the horizontal direction.
        pub fn withXExtend(self: Self, mode: Extend) Self {
            var result = self;
            result.sampler.x_extend = mode;
            return result;
        }

        /// Set the extend mode in the vertical direction.
        pub fn withYExtend(self: Self, mode: Extend) Self {
            var result = self;
            result.sampler.y_extend = mode;
            return result;
        }

        /// Set the desired sampling quality.
        pub fn withQuality(self: Self, quality: ImageQuality) Self {
            var result = self;
            result.sampler.quality = quality;
            return result;
        }

        /// Set the alpha multiplier to `alpha`.
        pub fn withAlpha(self: Self, alpha: f32) Self {
            std.debug.assert(std.math.isFinite(alpha) and alpha >= 0.0);
            var result = self;
            result.sampler.alpha = alpha;
            return result;
        }

        /// Multiply the alpha multiplier by `alpha`.
        pub fn multiplyAlpha(self: Self, alpha: f32) Self {
            std.debug.assert(std.math.isFinite(alpha) and alpha >= 0.0);
            var result = self;
            result.sampler.alpha *= alpha;
            return result;
        }
    };
}

/// The peniko 0.2-era name for the generic image brush; kept so
/// `root.zig`'s `Image` export stays meaningful. `Image(D)` is exactly
/// `ImageBrush(D)`; `Image(ImageSource)` is the owned-or-borrowed default,
/// while `vello_common` uses `Image(common.ImageSource)`.
pub fn Image(comptime D: type) type {
    return ImageBrush(D);
}

/// Borrowed version of `ImageBrush<ImageData>` (upstream `ImageBrushRef`).
pub const ImageBrushRef = ImageBrush(*const ImageData);

test "image sampler defaults" {
    const sampler = ImageSampler.default;
    try std.testing.expectEqual(Extend.pad, sampler.x_extend);
    try std.testing.expectEqual(Extend.pad, sampler.y_extend);
    try std.testing.expectEqual(ImageQuality.medium, sampler.quality);
    try std.testing.expectEqual(@as(f32, 1.0), sampler.alpha);
    try std.testing.expectEqual(ImageSampler.default, ImageSampler.new());
    try std.testing.expectEqual(ImageSampler.default, ImageSampler{});
}

test "image sampler builders" {
    const sampler = ImageSampler.new()
        .withExtend(.reflect)
        .withQuality(.high)
        .withAlpha(0.5);
    try std.testing.expectEqual(Extend.reflect, sampler.x_extend);
    try std.testing.expectEqual(Extend.reflect, sampler.y_extend);
    try std.testing.expectEqual(ImageQuality.high, sampler.quality);
    try std.testing.expectEqual(@as(f32, 0.5), sampler.alpha);

    try std.testing.expectEqual(Extend.repeat, sampler.withXExtend(.repeat).x_extend);
    try std.testing.expectEqual(Extend.reflect, sampler.withXExtend(.repeat).y_extend);
    try std.testing.expectEqual(Extend.repeat, sampler.withYExtend(.repeat).y_extend);
    try std.testing.expectEqual(Extend.reflect, sampler.withYExtend(.repeat).x_extend);

    try std.testing.expectEqual(@as(f32, 0.25), sampler.multiplyAlpha(0.5).alpha);
}

test "image format size in bytes" {
    try std.testing.expectEqual(@as(?usize, 60), ImageFormat.rgba8.sizeInBytes(3, 5));
    try std.testing.expectEqual(@as(?usize, 60), ImageFormat.bgra8.sizeInBytes(3, 5));
    try std.testing.expectEqual(@as(?usize, 0), ImageFormat.rgba8.sizeInBytes(0, 5));
    try std.testing.expectEqual(
        @as(?usize, null),
        ImageFormat.rgba8.sizeInBytes(std.math.maxInt(u32), std.math.maxInt(u32)),
    );
}

test "image format and alpha type discriminants" {
    try std.testing.expectEqual(@as(u8, 0), ImageFormat.rgba8.toU8());
    try std.testing.expectEqual(@as(u8, 1), ImageFormat.bgra8.toU8());
    try std.testing.expectEqual(ImageFormat.fromU8(1).?, ImageFormat.bgra8);
    try std.testing.expectEqual(@as(?ImageFormat, null), ImageFormat.fromU8(2));

    try std.testing.expectEqual(@as(u8, 0), ImageAlphaType.alpha.toU8());
    try std.testing.expectEqual(@as(u8, 1), ImageAlphaType.alpha_premultiplied.toU8());
    try std.testing.expectEqual(ImageAlphaType.fromU8(0).?, ImageAlphaType.alpha);
    try std.testing.expectEqual(@as(?ImageAlphaType, null), ImageAlphaType.fromU8(2));

    try std.testing.expectEqual(ImageQuality.medium, ImageQuality.default);
    try std.testing.expectEqual(ImageQuality.fromU8(2).?, ImageQuality.high);
    try std.testing.expectEqual(@as(?ImageQuality, null), ImageQuality.fromU8(3));
}

test "image data owns its bytes" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var image = try ImageData.init(allocator, &pixels, .rgba8, .alpha, 2, 1);
    defer image.deinit();
    try std.testing.expectEqualSlices(u8, &pixels, image.data);
    try std.testing.expectEqual(@as(?usize, 8), image.sizeInBytes());
    // The copy must not alias the caller's stack buffer.
    try std.testing.expect(@intFromPtr(image.data.ptr) != @intFromPtr(&pixels));

    var cloned = try image.clone(allocator);
    defer cloned.deinit();
    try std.testing.expectEqualSlices(u8, image.data, cloned.data);
    try std.testing.expect(cloned.data.ptr != image.data.ptr);

    // Adopting an existing allocation takes ownership without a copy.
    const owned = try allocator.dupe(u8, &pixels);
    var adopted = ImageData.initTakeOwnership(allocator, owned, .bgra8, .alpha_premultiplied, 2, 1);
    defer adopted.deinit();
    try std.testing.expectEqual(owned.ptr, adopted.data.ptr);
}

test "image data with borrowed bytes does not free" {
    const pixels = [_]u8{ 1, 2, 3, 4 };
    var image = ImageData{
        .data = &pixels,
        .format = .rgba8,
        .alpha_type = .alpha,
        .width = 1,
        .height = 1,
    };
    image.deinit();
    try std.testing.expectEqual(@as(usize, 0), image.data.len);
}

test "image brush fields and builders" {
    var image = ImageData{
        .data = &.{},
        .width = 4,
        .height = 2,
    };
    // Empty borrowed data: deinit must be a no-op.
    image.deinit();

    const data = ImageData{ .data = &.{}, .width = 4, .height = 2 };
    const brush = ImageBrush(*const ImageData).new(&data);
    try std.testing.expectEqual(@as(*const ImageData, &data), brush.image);
    try std.testing.expectEqual(ImageSampler.default, brush.sampler);

    const tuned = brush.withExtend(.repeat).withQuality(.low).withAlpha(0.5);
    try std.testing.expectEqual(Extend.repeat, tuned.sampler.x_extend);
    try std.testing.expectEqual(ImageQuality.low, tuned.sampler.quality);
    try std.testing.expectEqual(@as(f32, 0.5), tuned.sampler.alpha);

    const explicit = ImageBrush(*const ImageData).init(&data, ImageSampler.new().withAlpha(0.25));
    try std.testing.expectEqual(@as(f32, 0.25), explicit.sampler.alpha);
}

test "image source owned and borrowed" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 10, 20, 30, 40 };

    var source = ImageSource{ .owned = try ImageData.init(allocator, &pixels, .rgba8, .alpha, 1, 1) };
    defer source.deinit();
    try std.testing.expectEqualSlices(u8, &pixels, source.data().data);

    var clone = try source.clone(allocator);
    defer clone.deinit();
    try std.testing.expect(clone.data() != source.data());
    try std.testing.expectEqualSlices(u8, source.data().data, clone.data().data);

    const borrowed_data = ImageData{ .data = &pixels, .width = 1, .height = 1 };
    var borrowed = ImageSource{ .borrowed = &borrowed_data };
    try std.testing.expectEqual(@as(*const ImageData, &borrowed_data), borrowed.data());
    borrowed.deinit(); // No-op.

    // `Image(ImageSource)` is the generic brush instantiated with this
    // storage.
    var brush = Image(ImageSource).new(try source.clone(allocator));
    defer brush.image.deinit();
    const tinted = brush.withQuality(.high).withYExtend(.reflect);
    try std.testing.expectEqual(ImageQuality.high, tinted.sampler.quality);
    try std.testing.expectEqual(Extend.reflect, tinted.sampler.y_extend);
}

test "image brush ref" {
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const data = ImageData{ .data = &pixels, .width = 1, .height = 1 };
    const as_ref = ImageBrushRef.new(&data);
    try std.testing.expectEqual(@as(*const ImageData, &data), as_ref.image);
}
