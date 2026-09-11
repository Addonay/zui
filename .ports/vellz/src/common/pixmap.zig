//! Port of vello_common pixmap.rs (Apache-2.0 OR MIT).
//!
//! A pixmap of premultiplied RGBA8 values. The upstream `Vec<PremulRgba8>`
//! becomes `std.ArrayList(PremulRgba8)` (unmanaged in Zig 0.17), so every
//! growing or mutating operation takes the allocator explicitly.
//!
//! Ownership/allocator note: a `Pixmap` owns its pixel buffer; `deinit` frees
//! it and takes no allocation. `fromParts` cannot adopt a foreign allocator's
//! buffer like Rust's `Vec` move does, so it premultiplies the caller's data
//! in place (when it is straight alpha) and then copies it into an owned
//! buffer; the caller keeps ownership of `bytes`. `takeRgba8`/`tryTakeRgb8`
//! consume the pixel data, return a caller-owned `[]u8`, and leave the
//! `Pixmap` empty but valid. `PixmapMut` borrows the buffer and the owning
//! pixmap's opacity flag for the duration of the borrow.
//!
//! Zig exposes the upstream-private `width`/`height` fields directly instead
//! of `width()`/`height()` methods, because a Zig field and method cannot
//! share a name.

const std = @import("std");
const peniko = @import("../peniko/root.zig");
const util = @import("util.zig");

const PremulRgba8 = peniko.PremulRgba8;

/// A pixmap of premultiplied RGBA8 values backed by bytes.
pub const Pixmap = struct {
    /// Width of the pixmap in pixels.
    width: u16,
    /// Height of the pixmap in pixels.
    height: u16,
    /// Buffer of the pixmap in RGBA8 format.
    buf: std.ArrayList(PremulRgba8),
    /// Whether the pixmap may have non-opaque pixels.
    ///
    /// Note: This may become stale if pixels are modified via `dataMut`,
    /// `dataAsU8SliceMut`, or `setPixel`.
    may_have_transparency: bool,

    const zero_pixel = PremulRgba8.fromU32(0);

    /// Errors from `fromParts`.
    pub const FromPartsError = error{ OutOfMemory, InvalidDataLength };

    /// Create a new pixmap with the given width and height in pixels.
    ///
    /// All pixels are initialized to transparent black.
    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) std.mem.Allocator.Error!Pixmap {
        var buf = std.ArrayList(PremulRgba8).empty;
        errdefer buf.deinit(allocator);
        try buf.resize(allocator, pixelCount(width, height));
        @memset(buf.items, zero_pixel);
        return .{
            .width = width,
            .height = height,
            .buf = buf,
            .may_have_transparency = true,
        };
    }

    /// Create a new pixmap from the given buffer of bytes, representing pixel
    /// data.
    ///
    /// When passing premultiplied pixels, the data must be correctly
    /// premultiplied, i.e. each RGB component must be less than or equal to
    /// its pixel's alpha component.
    ///
    /// When `pixel_metadata.alpha_type` is `.alpha` and the metadata allows
    /// transparency, `bytes` is premultiplied **in place** exactly like
    /// upstream; the resulting pixels are additionally scanned so a
    /// conservative transparency hint can be downgraded to fully opaque.
    ///
    /// Returns `error.InvalidDataLength` if `bytes.len` is not exactly
    /// `width * height * 4` bytes. A wrong-length buffer panics upstream; this
    /// port returns an explicit error instead.
    pub fn fromParts(
        allocator: std.mem.Allocator,
        bytes: []u8,
        width: u16,
        height: u16,
        pixel_metadata: PixelMetadata,
    ) FromPartsError!Pixmap {
        if (bytes.len != pixelCount(width, height) * 4) return error.InvalidDataLength;

        // Allocate the owned buffer first so an allocation failure leaves the
        // caller's bytes untouched.
        var buf = std.ArrayList(PremulRgba8).empty;
        errdefer buf.deinit(allocator);
        try buf.resize(allocator, pixelCount(width, height));

        // If there might be transparency and the data is not premultiplied
        // yet, we need to iterate over all pixels anyway. Rechecking the alpha
        // values only adds little overhead, and lets us downgrade a
        // conservative transparency hint to fully opaque. If the data is
        // already premultiplied, we want to avoid reloading all pixels from
        // memory just to _maybe_ downgrade the hint, so the hint is returned
        // directly.
        const may_have_transparency = if (pixel_metadata.may_have_transparency and
            pixel_metadata.alpha_type == .alpha)
            premultiplyRgba8(bytes)
        else
            pixel_metadata.may_have_transparency;

        @memcpy(std.mem.sliceAsBytes(buf.items), bytes);

        return .{
            .width = width,
            .height = height,
            .buf = buf,
            .may_have_transparency = may_have_transparency,
        };
    }

    /// Release the pixel buffer.
    pub fn deinit(self: *Pixmap, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }

    /// Resizes the pixmap container to the given width and height; this does
    /// not resize the contained image.
    ///
    /// If the pixmap buffer has to grow to fit the new size, those pixels are
    /// set to transparent black. If the pixmap buffer is larger than required,
    /// the buffer is truncated and its reserved capacity is unchanged.
    pub fn resize(self: *Pixmap, allocator: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!void {
        const new_len = pixelCount(width, height);
        const old_len = self.buf.items.len;
        // If we're growing, new pixels are transparent black.
        if (new_len > old_len) self.may_have_transparency = true;
        try self.buf.resize(allocator, new_len);
        if (new_len > old_len) {
            @memset(self.buf.items[old_len..new_len], zero_pixel);
        }
        self.width = width;
        self.height = height;
    }

    /// Shrink the capacity of the pixmap buffer to fit the pixmap's current
    /// size.
    pub fn shrinkToFit(self: *Pixmap, allocator: std.mem.Allocator) void {
        self.buf.shrinkAndFree(allocator, self.buf.items.len);
    }

    /// The reserved capacity (in pixels) of this pixmap.
    ///
    /// When calling `resize` with a `width * height` smaller than this value,
    /// the pixmap does not need to reallocate.
    pub fn capacity(self: *const Pixmap) usize {
        return self.buf.capacity;
    }

    /// Returns whether the pixmap may have non-opaque pixels.
    ///
    /// This value is computed at construction time. It may become stale if
    /// pixels are modified directly via `dataMut`, `dataAsU8SliceMut`, or
    /// `setPixel`.
    ///
    /// Use `setMayHaveTransparency` to manually update the flag, or
    /// `recomputeMayHaveTransparency` to recalculate it by scanning all
    /// pixels.
    pub fn mayHaveTransparency(self: *const Pixmap) bool {
        return self.may_have_transparency;
    }

    /// Manually set the `may_have_transparency` flag.
    pub fn setMayHaveTransparency(self: *Pixmap, may_have_transparency: bool) void {
        self.may_have_transparency = may_have_transparency;
    }

    /// Recalculate `may_have_transparency` by scanning all pixels.
    pub fn recomputeMayHaveTransparency(self: *Pixmap) void {
        var may_have_transparency = false;
        for (self.buf.items) |pixel| {
            if (pixel.a != 255) {
                may_have_transparency = true;
                break;
            }
        }
        self.may_have_transparency = may_have_transparency;
    }

    /// Apply an alpha value to the whole pixmap.
    pub fn multiplyAlpha(self: *Pixmap, alpha: u8) void {
        const alpha_wide: u16 = alpha;
        for (self.buf.items) |*pixel| {
            pixel.r = @intCast((alpha_wide * @as(u16, pixel.r)) / 255);
            pixel.g = @intCast((alpha_wide * @as(u16, pixel.g)) / 255);
            pixel.b = @intCast((alpha_wide * @as(u16, pixel.b)) / 255);
            pixel.a = @intCast((alpha_wide * @as(u16, pixel.a)) / 255);
        }

        // If we applied a non-opaque alpha, the image now has transparency.
        if (alpha != 255) self.may_have_transparency = true;
    }

    /// Returns a reference to the underlying data as premultiplied RGBA8.
    ///
    /// The pixels are in row-major order.
    pub fn data(self: *const Pixmap) []const PremulRgba8 {
        return self.buf.items;
    }

    /// Returns a mutable reference to the underlying data as premultiplied
    /// RGBA8.
    ///
    /// The pixels are in row-major order.
    pub fn dataMut(self: *Pixmap) []PremulRgba8 {
        return self.buf.items;
    }

    /// Returns a reference to the underlying data as premultiplied RGBA8
    /// bytes.
    ///
    /// Each pixel consists of four bytes in the order `[r, g, b, a]`.
    pub fn dataAsU8Slice(self: *const Pixmap) []const u8 {
        return std.mem.sliceAsBytes(self.buf.items);
    }

    /// Returns a mutable reference to the underlying data as premultiplied
    /// RGBA8 bytes.
    ///
    /// Each pixel consists of four bytes in the order `[r, g, b, a]`.
    pub fn dataAsU8SliceMut(self: *Pixmap) []u8 {
        return std.mem.sliceAsBytes(self.buf.items);
    }

    /// Return a mutable view into this pixmap's pixel data.
    pub fn asMut(self: *Pixmap) PixmapMut {
        return .{
            .width = self.width,
            .height = self.height,
            .buf = std.mem.sliceAsBytes(self.buf.items),
            .may_have_transparency = &self.may_have_transparency,
        };
    }

    /// Sample a pixel from the pixmap.
    ///
    /// The pixel data is premultiplied RGBA8.
    pub fn sample(self: *const Pixmap, x: u16, y: u16) PremulRgba8 {
        std.debug.assert(x < self.width and y < self.height);
        const idx = @as(usize, self.width) * @as(usize, y) + @as(usize, x);
        return self.buf.items[idx];
    }

    /// Sample a pixel from a custom-calculated index. This index should be
    /// calculated assuming that the data is stored in row-major order.
    pub fn sampleIdx(self: *const Pixmap, idx: u32) PremulRgba8 {
        std.debug.assert(idx < self.buf.items.len);
        return self.buf.items[idx];
    }

    /// Set a pixel in the pixmap at the given coordinates.
    ///
    /// The pixel data should be premultiplied RGBA8. The coordinate system has
    /// its origin at the top-left corner, with `x` increasing to the right and
    /// `y` increasing downward.
    pub fn setPixel(self: *Pixmap, x: u16, y: u16, pixel: PremulRgba8) void {
        std.debug.assert(x < self.width and y < self.height);
        const idx = @as(usize, self.width) * @as(usize, y) + @as(usize, x);
        self.buf.items[idx] = pixel;
    }

    /// Consume the pixmap's pixel data and return its raw RGBA8 bytes with the
    /// given alpha representation.
    ///
    /// If both premultiplied and unpremultiplied RGBA are acceptable formats,
    /// it is recommended to choose `.alpha_premultiplied`, as the data can be
    /// returned as is without any additional post-processing. On success the
    /// pixmap is left empty (all counts zero) and must not be reused; the
    /// caller owns the returned bytes.
    pub fn takeRgba8(
        self: *Pixmap,
        allocator: std.mem.Allocator,
        alpha_type: peniko.ImageAlphaType,
    ) std.mem.Allocator.Error![]u8 {
        const bytes = std.mem.sliceAsBytes(self.buf.items);
        // Allocate before mutating so an allocation failure leaves the pixmap
        // untouched.
        const out = try allocator.alloc(u8, bytes.len);
        errdefer allocator.free(out);

        @memcpy(out, bytes);
        if (self.may_have_transparency and alpha_type == .alpha) {
            _ = unpremultiplyRgba8(out);
        }

        self.buf.deinit(allocator);
        self.becomeEmpty();
        return out;
    }

    /// Consume the pixmap's pixel data and attempt to return its raw data as
    /// RGB8 pixel data.
    ///
    /// In case this is not possible (due to the pixmap containing non-opaque
    /// pixels), this method will fall back to returning the data as RGBA8 with
    /// the requested alpha representation. On success the pixmap is left empty
    /// (all counts zero) and must not be reused.
    pub fn tryTakeRgb8(
        self: *Pixmap,
        allocator: std.mem.Allocator,
        alpha_type: peniko.ImageAlphaType,
    ) std.mem.Allocator.Error!Pixels {
        const bytes = std.mem.sliceAsBytes(self.buf.items);
        const pixel_count = self.buf.items.len;

        if (self.may_have_transparency and alpha_type == .alpha) {
            // Work on a copy: if the conversion makes the image opaque we may
            // need an RGB buffer, and if an allocation fails the pixmap must
            // stay untouched and premultiplied.
            const rgba = try allocator.alloc(u8, bytes.len);
            errdefer allocator.free(rgba);
            @memcpy(rgba, bytes);
            // `unpremultiplyRgba8` rescans the alpha channels, so a stale
            // `true` hint can still be downgraded to fully opaque.
            const still_transparent = unpremultiplyRgba8(rgba);
            if (still_transparent) {
                self.buf.deinit(allocator);
                self.becomeEmpty();
                return .{ .rgba8 = rgba };
            }
            const out = try allocator.alloc(u8, pixel_count * 3);
            defer allocator.free(rgba);
            var dst: usize = 0;
            var idx: usize = 0;
            while (idx < rgba.len) : ({
                idx += 4;
                dst += 3;
            }) {
                out[dst] = rgba[idx];
                out[dst + 1] = rgba[idx + 1];
                out[dst + 2] = rgba[idx + 2];
            }
            self.buf.deinit(allocator);
            self.becomeEmpty();
            return .{ .rgb8 = out };
        }

        if (self.may_have_transparency) {
            const out = try allocator.alloc(u8, bytes.len);
            errdefer allocator.free(out);
            @memcpy(out, bytes);
            self.buf.deinit(allocator);
            self.becomeEmpty();
            return .{ .rgba8 = out };
        }

        const out = try allocator.alloc(u8, pixel_count * 3);
        errdefer allocator.free(out);
        var dst: usize = 0;
        var src: usize = 0;
        while (src < bytes.len) : ({
            src += 4;
            dst += 3;
        }) {
            out[dst] = bytes[src];
            out[dst + 1] = bytes[src + 1];
            out[dst + 2] = bytes[src + 2];
        }
        self.buf.deinit(allocator);
        self.becomeEmpty();
        return .{ .rgb8 = out };
    }

    fn becomeEmpty(self: *Pixmap) void {
        self.width = 0;
        self.height = 0;
        self.buf = .empty;
        self.may_have_transparency = true;
    }
};

/// A mutable view into premultiplied RGBA8 pixmap data.
///
/// Borrowed for the lifetime of the view: the owning pixmap (when any) must
/// outlive it, and the opacity flag, when present, points into that pixmap.
pub const PixmapMut = struct {
    /// Width of the pixmap in pixels.
    width: u16,
    /// Height of the pixmap in pixels.
    height: u16,
    /// Buffer of the pixmap in RGBA8 format.
    buf: []u8,
    /// Opacity metadata of the owning `Pixmap`, when this view was created
    /// from one.
    may_have_transparency: ?*bool,

    /// Create a new mutable pixmap view.
    ///
    /// Returns `null` if `buf` is not exactly `width * height * 4` bytes long.
    pub fn init(width: u16, height: u16, buf: []u8) ?PixmapMut {
        if (buf.len == pixelCount(width, height) * 4) {
            return .{
                .width = width,
                .height = height,
                .buf = buf,
                .may_have_transparency = null,
            };
        }
        return null;
    }

    /// Returns a mutable reference to the underlying data as premultiplied
    /// RGBA8 bytes.
    pub fn dataMut(self: *PixmapMut) []u8 {
        return self.buf;
    }

    /// Update the opacity hint of the owning `Pixmap`, if one exists.
    pub fn setMayHaveTransparency(self: *PixmapMut, may_have_transparency: bool) void {
        if (self.may_have_transparency) |flag| flag.* = may_have_transparency;
    }
};

/// The result of attempting to extract RGB8 data from a `Pixmap`.
pub const Pixels = union(enum) {
    /// Three bytes per pixel in red, green, blue order.
    rgb8: []u8,
    /// Four bytes per pixel in red, green, blue, alpha order.
    rgba8: []u8,

    /// Release the payload with the allocator that produced it.
    pub fn deinit(self: Pixels, allocator: std.mem.Allocator) void {
        switch (self) {
            .rgb8 => |bytes| allocator.free(bytes),
            .rgba8 => |bytes| allocator.free(bytes),
        }
    }

    /// The bytes regardless of layout.
    pub fn asSlice(self: Pixels) []const u8 {
        return switch (self) {
            .rgb8 => |bytes| bytes,
            .rgba8 => |bytes| bytes,
        };
    }
};

/// Metadata about the pixels of an image.
pub const PixelMetadata = struct {
    /// Whether the pixels may be non-opaque.
    ///
    /// If unsure, always set this to `true`. Setting this to `false` is a
    /// strong guarantee that every pixel in the image **is guaranteed** to be
    /// opaque. Setting this to `false` mistakenly can lead to wrong rendering.
    may_have_transparency: bool,
    /// How the alpha channel is represented.
    alpha_type: peniko.ImageAlphaType,

    /// The upstream `Default`: premultiplied, conservatively transparent.
    pub const DEFAULT: PixelMetadata = .{
        .may_have_transparency = true,
        .alpha_type = .alpha_premultiplied,
    };

    /// Create a new pixel metadata description.
    pub fn new(alpha_type: peniko.ImageAlphaType, may_have_transparency: bool) PixelMetadata {
        return .{
            .may_have_transparency = may_have_transparency,
            .alpha_type = alpha_type,
        };
    }
};

fn pixelCount(width: u16, height: u16) usize {
    return @as(usize, width) * @as(usize, height);
}

/// Premultiplies each RGBA8 pixel in `data`.
///
/// Returns `true` if at least one pixel is not fully opaque. The scalar loop
/// is the exact per-lane equivalent of the upstream SIMD body and tail:
/// `(component * alpha + 255) >> 8`.
fn premultiplyRgba8(data: []u8) bool {
    var may_have_transparency = false;
    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const alpha = data[i + 3];
        if (alpha != 255) may_have_transparency = true;
        const alpha_wide: u16 = alpha;
        inline for (0..3) |component| {
            data[i + component] = @intCast(
                (@as(u16, data[i + component]) * alpha_wide + 255) >> 8,
            );
        }
    }
    return may_have_transparency;
}

/// Unpremultiplies each RGBA8 pixel in `data`.
///
/// Returns `true` if at least one pixel is not fully opaque.
fn unpremultiplyRgba8(data: []u8) bool {
    var may_have_transparency = false;
    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const alpha = data[i + 3];
        if (alpha != 255) may_have_transparency = true;
        const reciprocal = util.unpremultiply.reciprocal(alpha);
        inline for (0..3) |component| {
            data[i + component] = util.unpremultiply.scalar(data[i + component], reciprocal);
        }
    }
    return may_have_transparency;
}

test "straight_alpha_is_premultiplied_in_body_and_tail" {
    const allocator = std.testing.allocator;
    var data = [_]u8{
        // SIMD body (16 pixels)
        200, 100, 50,  128, 128, 64,  32, 128, 255, 128, 64,  64,  255, 100, 1,  0,   64,  32, 16, 192,
        10,  20,  30,  255, 240, 120, 60, 128, 80,  40,  20,  64,  100, 50,  25, 128, 32,  16, 8,  192,
        200, 150, 100, 64,  3,   2,   1,  128, 254, 253, 252, 128, 1,   2,   3,  64,  127, 63, 31, 192,
        9,   8,   7,   255,
        // Scalar tail (1 pixel)
        80,  40,  20, 64,
    };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        17,
        1,
        PixelMetadata.new(.alpha, true),
    );
    defer pixmap.deinit(allocator);

    try std.testing.expect(pixmap.mayHaveTransparency());
    try std.testing.expectEqualSlices(u8, &.{
        // SIMD body
        100, 50, 25, 128, 64,  32, 16, 128, 64,  32,  16,  64,  0,  0,  0,  0,   48, 24, 12, 192,
        10,  20, 30, 255, 120, 60, 30, 128, 20,  10,  5,   64,  50, 25, 13, 128, 24, 12, 6,  192,
        50,  38, 25, 64,  2,   1,  1,  128, 127, 127, 126, 128, 1,  1,  1,  64,  96, 48, 24, 192,
        9,   8,  7,  255,
        // Scalar tail
        20,  10, 5,  64,
    }, pixmap.dataAsU8Slice());
}

test "straight_alpha_is_premultiplied_with_only_tail" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 200, 100, 50, 128, 9, 8, 7, 255 };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        2,
        1,
        PixelMetadata.new(.alpha, true),
    );
    defer pixmap.deinit(allocator);

    try std.testing.expect(pixmap.mayHaveTransparency());
    try std.testing.expectEqualSlices(u8, &.{ 100, 50, 25, 128, 9, 8, 7, 255 }, pixmap.dataAsU8Slice());
}

test "straight_opaque_alpha_clears_transparency_hint_in_body_and_tail" {
    const allocator = std.testing.allocator;
    var data = [_]u8{
        // SIMD body
        200, 100, 50, 255, 1,  2,   3,  255, 4,  5,   6,  255, 7,  8,   9,  255, 10, 11,  12, 255, 13, 14,
        15,  255, 16, 17,  18, 255, 19, 20,  21, 255, 22, 23,  24, 255, 25, 26,  27, 255, 28, 29,  30, 255,
        31,  32,  33, 255, 34, 35,  36, 255, 37, 38,  39, 255, 40, 41,  42, 255, 43, 44,  45, 255,
        // Scalar tail
        80, 40,
        20,  255,
    };
    const expected = data;
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        17,
        1,
        PixelMetadata.new(.alpha, true),
    );
    defer pixmap.deinit(allocator);

    try std.testing.expect(!pixmap.mayHaveTransparency());
    try std.testing.expectEqualSlices(u8, &expected, pixmap.dataAsU8Slice());
}

test "straight_opaque_alpha_clears_transparency_hint_with_only_tail" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 255 };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        1,
        1,
        PixelMetadata.new(.alpha, true),
    );
    defer pixmap.deinit(allocator);

    try std.testing.expect(!pixmap.mayHaveTransparency());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, pixmap.dataAsU8Slice());
}

test "opaque_pixmap_compacts_to_rgb" {
    const allocator = std.testing.allocator;
    var rgba: [33 * 4]u8 = undefined;
    var expected: [33 * 3]u8 = undefined;
    for (0..33) |pixel| {
        const p: u8 = @intCast(pixel);
        rgba[pixel * 4] = p *% 3;
        rgba[pixel * 4 + 1] = p *% 5;
        rgba[pixel * 4 + 2] = p *% 7;
        rgba[pixel * 4 + 3] = 255;
        expected[pixel * 3] = p *% 3;
        expected[pixel * 3 + 1] = p *% 5;
        expected[pixel * 3 + 2] = p *% 7;
    }
    var pixmap = try Pixmap.fromParts(
        allocator,
        &rgba,
        33,
        1,
        PixelMetadata.new(.alpha_premultiplied, false),
    );
    defer pixmap.deinit(allocator);

    const pixels = try pixmap.tryTakeRgb8(allocator, .alpha);
    defer pixels.deinit(allocator);

    try std.testing.expectEqual(std.meta.Tag(Pixels).rgb8, std.meta.activeTag(pixels));
    try std.testing.expectEqualSlices(u8, &expected, pixels.asSlice());
}

test "transparent_pixmap_falls_back_to_rgba" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 64, 32, 16, 128 };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        1,
        1,
        PixelMetadata.new(.alpha_premultiplied, true),
    );
    defer pixmap.deinit(allocator);

    const pixels = try pixmap.tryTakeRgb8(allocator, .alpha);
    defer pixels.deinit(allocator);

    try std.testing.expectEqual(std.meta.Tag(Pixels).rgba8, std.meta.activeTag(pixels));
    try std.testing.expectEqualSlices(u8, &.{ 128, 64, 32, 128 }, pixels.asSlice());
}

test "transparent_pixmap_falls_back_to_premultiplied_rgba" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 64, 32, 16, 128 };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        1,
        1,
        PixelMetadata.new(.alpha_premultiplied, true),
    );
    defer pixmap.deinit(allocator);

    const pixels = try pixmap.tryTakeRgb8(allocator, .alpha_premultiplied);
    defer pixels.deinit(allocator);

    try std.testing.expectEqual(std.meta.Tag(Pixels).rgba8, std.meta.activeTag(pixels));
    try std.testing.expectEqualSlices(u8, &.{ 64, 32, 16, 128 }, pixels.asSlice());
}

test "take_rgba8_unpremultiplies_and_empties" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 64, 32, 16, 128 };
    var pixmap = try Pixmap.fromParts(
        allocator,
        &data,
        1,
        1,
        PixelMetadata.new(.alpha_premultiplied, true),
    );
    defer pixmap.deinit(allocator);

    const bytes = try pixmap.takeRgba8(allocator, .alpha);
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 128, 64, 32, 128 }, bytes);
    // The pixmap stays valid but empty.
    try std.testing.expectEqual(@as(usize, 0), pixmap.data().len);
    try std.testing.expectEqual(@as(u16, 0), pixmap.width);
}

test "resize, sample, set_pixel and multiply_alpha" {
    const allocator = std.testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);

    try std.testing.expectEqual(PremulRgba8.fromU32(0), pixmap.sample(1, 1));
    pixmap.setPixel(1, 0, .{ .r = 200, .g = 100, .b = 50, .a = 255 });
    try std.testing.expectEqual(@as(u8, 200), pixmap.sample(1, 0).r);

    try pixmap.resize(allocator, 4, 4);
    try std.testing.expectEqual(@as(u16, 4), pixmap.width);
    try std.testing.expectEqual(PremulRgba8.fromU32(0), pixmap.sample(3, 3));
    try std.testing.expect(pixmap.capacity() >= 16);

    pixmap.multiplyAlpha(128);
    try std.testing.expectEqual(@as(u8, 100), pixmap.sample(1, 0).r);
    try std.testing.expectEqual(@as(u8, 128), pixmap.sample(1, 0).a);
    try std.testing.expect(pixmap.mayHaveTransparency());

    pixmap.setMayHaveTransparency(false);
    pixmap.recomputeMayHaveTransparency();
    try std.testing.expect(pixmap.mayHaveTransparency());

    pixmap.shrinkToFit(allocator);
    try std.testing.expect(pixmap.capacity() >= 16);
}

test "from_parts_rejects_wrong_length" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(
        error.InvalidDataLength,
        Pixmap.fromParts(allocator, &data, 2, 1, PixelMetadata.DEFAULT),
    );
}

test "pixmap_mut_borrows_opacity_flag" {
    const allocator = std.testing.allocator;
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);

    var view = pixmap.asMut();
    try std.testing.expectEqual(@as(u16, 1), view.width);
    try std.testing.expectEqual(@as(usize, 4), view.dataMut().len);
    view.setMayHaveTransparency(false);
    try std.testing.expectEqual(false, pixmap.mayHaveTransparency());

    var buf = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expect(PixmapMut.init(1, 1, &buf) != null);
    try std.testing.expect(PixmapMut.init(2, 1, &buf) == null);
}
