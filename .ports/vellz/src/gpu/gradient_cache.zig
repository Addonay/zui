//! Port of `vello_gpu/src/gradient_cache.rs` (Apache-2.0 OR MIT).
//!
//! Packs gradient LUTs into a flat `Rgba8Unorm` byte buffer and caches them by
//! `GradientCacheKey`. Upstream keeps an LRU with compaction across frames;
//! this port builds the cache per render call, so entries live as long as the
//! scene's encoded paints and no eviction is needed. Identical gradients still
//! share one LUT via `GradientCacheKey.bitEql`.
//!
//! CPU-safe: imports only `vellz.common` and the CPU-safe GPU layout modules.

const std = @import("std");
const common = @import("../common/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");

const EncodedGradient = common.encode.EncodedGradient;
const GradientCacheKey = common.encode.GradientCacheKey;

/// Number of bytes per texel in the gradient texture (RGBA8).
pub const BYTES_PER_TEXEL: u32 = 4;

/// A cached gradient ramp and its location in the packed LUT bytes.
pub const CachedRamp = struct {
    /// Width of this gradient's LUT in texels.
    width: u32,
    /// Start of this ramp in the packed LUT, in texels.
    lut_start: u32,
};

/// The per-render gradient ramp cache.
pub const GradientRampCache = struct {
    allocator: std.mem.Allocator,
    /// Packed LUT bytes (RGBA8, `BYTES_PER_TEXEL` per texel).
    luts: std.ArrayList(u8) = .empty,
    /// Cache entries in insertion order.
    entries: std.ArrayList(Entry) = .empty,
    /// Whether any LUT was added since the last upload.
    has_changed: bool = false,

    const Entry = struct {
        key: *const GradientCacheKey,
        ramp: CachedRamp,
    };

    /// Create an empty cache.
    pub fn init(allocator: std.mem.Allocator) GradientRampCache {
        return .{ .allocator = allocator };
    }

    /// Release the packed LUT bytes.
    pub fn deinit(self: *GradientRampCache) void {
        self.luts.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Get or build the ramp for `gradient`, returning its packed location.
    ///
    /// `u8Lut` lazily caches the LUT inside the (scene-owned) encoded paint;
    /// the pointer is const here to keep the resolver's signature, and the
    /// scene is exclusively borrowed for the duration of a render.
    pub fn getOrCreateRamp(
        self: *GradientRampCache,
        gradient: *const EncodedGradient,
    ) std.mem.Allocator.Error!CachedRamp {
        for (self.entries.items) |entry| {
            if (gradient.cache_key.bitEql(entry.key)) return entry.ramp;
        }

        // `u8Lut` lazily caches the built LUT inside the encoded paint, which
        // is owned by the exclusively borrowed scene; the const cast keeps
        // the resolver signature read-only.
        const lut = try @constCast(gradient).u8Lut(self.allocator);
        const bytes = std.mem.sliceAsBytes(lut.lut());
        const width: u32 = @intCast(lut.width());
        const lut_start: u32 = @intCast(self.luts.items.len / BYTES_PER_TEXEL);

        try self.luts.appendSlice(self.allocator, bytes);
        // Keep the buffer texel-aligned for the next ramp.
        const padded = std.mem.alignForward(usize, self.luts.items.len, BYTES_PER_TEXEL);
        if (padded > self.luts.items.len) {
            try self.luts.appendNTimes(self.allocator, 0, padded - self.luts.items.len);
        }

        const ramp = CachedRamp{ .width = width, .lut_start = lut_start };
        try self.entries.append(self.allocator, .{ .key = &gradient.cache_key, .ramp = ramp });
        self.has_changed = true;
        return ramp;
    }

    /// The packed LUT bytes.
    pub fn lutsBytes(self: *const GradientRampCache) []const u8 {
        return self.luts.items;
    }

    /// The packed LUT size in bytes.
    pub fn lutsSize(self: *const GradientRampCache) usize {
        return self.luts.items.len;
    }

    /// Whether any LUT was added since construction.
    pub fn hasChanged(self: *const GradientRampCache) bool {
        return self.has_changed;
    }
};

test "gradient ramps deduplicate by cache key" {
    const allocator = std.testing.allocator;
    var cache = GradientRampCache.init(allocator);
    defer cache.deinit();

    var gradient = try encodedLinearGradient(allocator, 0.5);
    defer gradient.deinit(allocator);

    const first = try cache.getOrCreateRamp(&gradient);
    const second = try cache.getOrCreateRamp(&gradient);
    try std.testing.expectEqual(first.lut_start, second.lut_start);
    try std.testing.expectEqual(first.width, second.width);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expectEqual(@as(usize, first.width * BYTES_PER_TEXEL), cache.lutsSize());
    try std.testing.expect(cache.hasChanged());

    var other = try encodedLinearGradient(allocator, 0.75);
    defer other.deinit(allocator);
    const third = try cache.getOrCreateRamp(&other);
    try std.testing.expect(third.lut_start > first.lut_start);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
}

/// Build an encoded linear gradient for tests.
pub fn encodedLinearGradient(
    allocator: std.mem.Allocator,
    middle_offset: f32,
) !EncodedGradient {
    var gradient: peniko.Gradient = .{};
    gradient.kind = .{ .linear = peniko.LinearGradientPosition.new(
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 64.0, .y = 0.0 },
    ) };
    gradient.stops = try peniko.ColorStops.fromSlice(allocator, &.{
        .{ .offset = 0.0, .color = peniko.color.Color.fromRgb8(255, 0, 0) },
        .{ .offset = middle_offset, .color = peniko.color.Color.fromRgb8(0, 255, 0) },
        .{ .offset = 1.0, .color = peniko.color.Color.fromRgb8(0, 0, 255) },
    });
    defer gradient.deinit();

    var paints: std.ArrayList(common.encode.EncodedPaint) = .empty;
    defer {
        for (paints.items) |*paint| paint.deinit(allocator);
        paints.deinit(allocator);
    }
    _ = try common.encode.encodeGradient(
        &gradient,
        allocator,
        &paints,
        kurbo.Affine.IDENTITY,
        null,
    );
    // Move the gradient encoding out of the temporary paint list; the
    // deferred cleanup below then sees an empty list.
    const encoded = paints.items[0].gradient;
    paints.clearRetainingCapacity();
    return encoded;
}
