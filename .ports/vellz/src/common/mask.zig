//! Port of vello_common mask.rs (Apache-2.0 OR MIT).
//!
//! Alpha and luminance masks.
//!
//! Ownership/allocator note: `Mask` is a reference-counted handle over
//! `MaskRepr`, a `Shared(MaskRepr)` replacing upstream's `Arc<MaskRepr>`.
//! `newAlpha`, `newLuminance`, and `fromParts` allocate with the passed
//! allocator and return a handle with a reference count of one; `clone`
//! retains and `deinit` releases. The pixel buffer lives next to the
//! dimensions inside the shared allocation (upstream stores width and height
//! inside the `Arc` on purpose to reduce the memory footprint of the struct);
//! it is freed when the last handle is released.
//!
//! `fromParts` copies the caller's bytes into an owned buffer, matching the
//! owning-type contract used by `common/pixmap.zig`: the caller keeps
//! ownership of its slice.

const std = @import("std");
const peniko = @import("../peniko/root.zig");
const pixmap = @import("pixmap.zig");
const shared = @import("shared.zig");

/// The shared representation of a mask: its dimensions and one byte per pixel
/// in row-major order.
///
/// This is the `MaskRepr` private struct from upstream, made public only
/// because it is the payload type of the public `Mask.repr` handle.
pub const MaskRepr = struct {
    /// One mask value (alpha or luminance) per pixel, row-major.
    data: std.ArrayList(u8),
    /// The width of the mask.
    width: u16,
    /// The height of the mask.
    height: u16,

    /// Release the pixel buffer. Called by `Shared.release` on the last
    /// handle.
    pub fn deinit(self: *MaskRepr, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

/// A mask.
pub const Mask = struct {
    /// The shared representation. Every value copy must go through `clone`.
    repr: shared.Shared(MaskRepr),

    /// Errors from `fromParts`.
    pub const FromPartsError = error{ OutOfMemory, InvalidDataLength };

    /// Create a new alpha mask from the pixmap.
    pub fn newAlpha(allocator: std.mem.Allocator, pixmap_ref: *const pixmap.Pixmap) std.mem.Allocator.Error!Mask {
        return newWith(allocator, pixmap_ref, true);
    }

    /// Create a new luminance mask from the pixmap.
    pub fn newLuminance(allocator: std.mem.Allocator, pixmap_ref: *const pixmap.Pixmap) std.mem.Allocator.Error!Mask {
        return newWith(allocator, pixmap_ref, false);
    }

    /// Create a new mask from the given mask data.
    ///
    /// The `data` slice must be of length `width * height` exactly; the pixels
    /// are in row-major order. The data is copied, and the caller keeps
    /// ownership of its slice.
    ///
    /// Upstream panics on a length mismatch; this port returns
    /// `error.InvalidDataLength` like `Pixmap.fromParts` does.
    pub fn fromParts(
        allocator: std.mem.Allocator,
        data: []const u8,
        mask_width: u16,
        mask_height: u16,
    ) FromPartsError!Mask {
        if (data.len != @as(usize, mask_width) * @as(usize, mask_height)) {
            return error.InvalidDataLength;
        }

        var owned = std.ArrayList(u8).empty;
        errdefer owned.deinit(allocator);
        try owned.appendSlice(allocator, data);

        return .{
            .repr = try shared.Shared(MaskRepr).create(allocator, .{
                .data = owned,
                .width = mask_width,
                .height = mask_height,
            }),
        };
    }

    fn newWith(
        allocator: std.mem.Allocator,
        pixmap_ref: *const pixmap.Pixmap,
        alpha_mask: bool,
    ) std.mem.Allocator.Error!Mask {
        const pixels = pixmap_ref.data();

        var owned = std.ArrayList(u8).empty;
        errdefer owned.deinit(allocator);
        try owned.resize(allocator, pixels.len);

        for (pixels, owned.items) |pixel, *out| {
            out.* = if (alpha_mask) pixel.a else luminance(pixel);
        }

        return .{
            .repr = try shared.Shared(MaskRepr).create(allocator, .{
                .data = owned,
                .width = pixmap_ref.width,
                .height = pixmap_ref.height,
            }),
        };
    }

    /// Add one reference and return a second owned handle.
    pub fn clone(self: Mask) Mask {
        return .{ .repr = self.repr.clone() };
    }

    /// Drop one reference, freeing the pixel buffer on the last one.
    pub fn deinit(self: Mask, allocator: std.mem.Allocator) void {
        self.repr.release(allocator);
    }

    /// Return the width of the mask.
    pub fn width(self: Mask) u16 {
        return self.repr.get().width;
    }

    /// Return the height of the mask.
    pub fn height(self: Mask) u16 {
        return self.repr.get().height;
    }

    /// Sample the value at a specific location.
    ///
    /// This function might panic or yield a wrong result if the location is
    /// out-of-bounds.
    pub fn sample(self: Mask, x: u16, y: u16) u8 {
        const repr = self.repr.get();
        std.debug.assert(x < repr.width and y < repr.height);
        return repr.data.items[@as(usize, y) * @as(usize, repr.width) + @as(usize, x)];
    }

    /// Compare two masks by their dimensions and pixel data (upstream
    /// `PartialEq`, which compares the referenced `MaskRepr`s).
    pub fn eql(a: Mask, b: Mask) bool {
        if (shared.Shared(MaskRepr).ptrEq(a.repr, b.repr)) return true;
        const ra = a.repr.get();
        const rb = b.repr.get();
        if (ra.width != rb.width or ra.height != rb.height) return false;
        return std.mem.eql(u8, ra.data.items, rb.data.items);
    }
};

/// See CSS Masking Module Level 1 § 7.10.1
/// (<https://www.w3.org/TR/css-masking-1/#MaskValues>) and Filter Effects
/// Module Level 1 § 9.6
/// (<https://www.w3.org/TR/filter-effects-1/#elementdef-fecolormatrix>).
///
/// The pixel channels are premultiplied by alpha.
fn luminance(pixel: peniko.PremulRgba8) u8 {
    const r = @as(f32, @floatFromInt(pixel.r)) / 255.0;
    const g = @as(f32, @floatFromInt(pixel.g)) / 255.0;
    const b = @as(f32, @floatFromInt(pixel.b)) / 255.0;

    const luma = r * 0.2126 + g * 0.7152 + b * 0.0722;
    // Rust's float-to-int `as` cast saturates (and maps NaN to 0); the
    // weights sum to 1, so only the upper bound can be reached.
    return @intFromFloat(std.math.clamp(luma * 255.0 + 0.5, 0.0, 255.0));
}

test "from_parts, dimensions and sampling" {
    const allocator = std.testing.allocator;
    const mask = try Mask.fromParts(allocator, &[_]u8{ 1, 2, 3, 4 }, 2, 2);
    defer mask.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 2), mask.width());
    try std.testing.expectEqual(@as(u16, 2), mask.height());
    try std.testing.expectEqual(@as(u8, 1), mask.sample(0, 0));
    try std.testing.expectEqual(@as(u8, 2), mask.sample(1, 0));
    try std.testing.expectEqual(@as(u8, 3), mask.sample(0, 1));
    try std.testing.expectEqual(@as(u8, 4), mask.sample(1, 1));
}

test "from_parts rejects a mismatched length" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDataLength, Mask.fromParts(allocator, &[_]u8{ 1, 2, 3 }, 2, 2));
}

test "clone shares the representation" {
    const allocator = std.testing.allocator;
    const mask = try Mask.fromParts(allocator, &[_]u8{ 7, 8 }, 2, 1);
    defer mask.deinit(allocator);

    const copy = mask.clone();
    defer copy.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), mask.repr.refCount());
    try std.testing.expect(mask.eql(copy));
    try std.testing.expectEqual(@as(u8, 8), copy.sample(1, 0));

    // Both handles refer to the same allocation.
    try std.testing.expect(shared.Shared(MaskRepr).ptrEq(mask.repr, copy.repr));
}

test "eql compares dimensions and pixel data" {
    const allocator = std.testing.allocator;
    const a = try Mask.fromParts(allocator, &[_]u8{ 1, 2, 3, 4 }, 2, 2);
    defer a.deinit(allocator);
    const b = try Mask.fromParts(allocator, &[_]u8{ 1, 2, 3, 4 }, 2, 2);
    defer b.deinit(allocator);
    const c = try Mask.fromParts(allocator, &[_]u8{ 1, 2, 3, 5 }, 2, 2);
    defer c.deinit(allocator);
    const d = try Mask.fromParts(allocator, &[_]u8{ 1, 2, 3, 4 }, 4, 1);
    defer d.deinit(allocator);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
}

test "new_alpha extracts the alpha channel" {
    const allocator = std.testing.allocator;
    var bytes = [_]u8{ 10, 20, 30, 40, 200, 100, 50, 255 };
    var pixmap_ref = try pixmap.Pixmap.fromParts(allocator, &bytes, 2, 1, .{
        .alpha_type = .alpha_premultiplied,
        .may_have_transparency = true,
    });
    defer pixmap_ref.deinit(allocator);

    const mask = try Mask.newAlpha(allocator, &pixmap_ref);
    defer mask.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 2), mask.width());
    try std.testing.expectEqual(@as(u16, 1), mask.height());
    try std.testing.expectEqual(@as(u8, 40), mask.sample(0, 0));
    try std.testing.expectEqual(@as(u8, 255), mask.sample(1, 0));
}

test "new_luminance uses the CSS weights on premultiplied channels" {
    const allocator = std.testing.allocator;
    // Premultiplied red, premultiplied white, transparent black.
    var bytes = [_]u8{ 255, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 0 };
    var pixmap_ref = try pixmap.Pixmap.fromParts(allocator, &bytes, 3, 1, .{
        .alpha_type = .alpha_premultiplied,
        .may_have_transparency = true,
    });
    defer pixmap_ref.deinit(allocator);

    const mask = try Mask.newLuminance(allocator, &pixmap_ref);
    defer mask.deinit(allocator);

    // 0.2126 * 255 + 0.5 = 54.713, truncated.
    try std.testing.expectEqual(@as(u8, 54), mask.sample(0, 0));
    // 1.0 * 255 + 0.5 saturates.
    try std.testing.expectEqual(@as(u8, 255), mask.sample(1, 0));
    try std.testing.expectEqual(@as(u8, 0), mask.sample(2, 0));
}
