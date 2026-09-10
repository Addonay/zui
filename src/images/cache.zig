//! App-owned decoded-image pool (RGBA8) keyed by content hash.
//!
//! Design mirrors the glyph atlas contract: frames reference pool offsets,
//! pool bytes must survive until present (render+present run adjacently per
//! window in `App.step`). Eviction only drops entries unused by the current
//! frame, so already-emitted `Scene` refs stay valid; when nothing is
//! evictable the lookup fails and the painter drops the image — same
//! drop-instead-of-grow policy as quad overflow.

const std = @import("std");
const limits = @import("../core/limits.zig");
const color_mod = @import("../core/color.zig");
const zlog = @import("../core/log.zig");
const raster = @import("raster.zig");
const svg = @import("svg.zig");

/// Pool reference emitted into `Scene` image entries.
pub const Handle = struct {
    offset: u32,
    w: u32,
    h: u32,

    pub const invalid: Handle = .{ .offset = 0, .w = 0, .h = 0 };
};

const Entry = struct {
    hash: u64 = 0,
    offset: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    /// Last frame that looked this entry up; eviction skips current-frame.
    pin: u64 = 0,
    live: bool = false,
};

pub const Cache = struct {
    pool: []u8 = &.{},
    used: usize = 0,
    entries: [limits.MAX_CACHED_IMAGES]Entry = undefined,

    pub fn init(allocator: std.mem.Allocator) !*Cache {
        const self = try allocator.create(Cache);
        errdefer allocator.destroy(self);
        self.* = .{};
        for (&self.entries) |*e| e.* = .{};
        self.pool = try allocator.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
        return self;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.pool);
        allocator.destroy(self);
    }

    pub fn pixels(self: *const Cache, h: Handle) []const u8 {
        const end = @as(usize, h.offset) + @as(usize, h.w) * h.h * 4;
        if (end > self.pool.len) return &.{};
        return self.pool[h.offset..end];
    }

    /// Raster bytes (PNG/JPEG/GIF/BMP) at intrinsic dimensions.
    pub fn imageFromBytes(
        self: *Cache,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        frame: u64,
    ) !Handle {
        const hash = std.hash.Wyhash.hash(0, bytes);
        if (self.lookup(hash, frame)) |hit| return hit;
        const decoded = raster.decode(allocator, bytes) catch |err| {
            zlog.log("images", "decode failed: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(decoded.pixels);
        return self.place(hash, decoded.pixels, decoded.w, decoded.h, frame);
    }

    /// SVG bytes rasterized at exactly `w` x `h` with optional tint.
    pub fn svgFromBytes(
        self: *Cache,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        w: u32,
        h: u32,
        tint: ?color_mod.Color,
        frame: u64,
    ) !Handle {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(bytes);
        hasher.update(std.mem.asBytes(&w));
        hasher.update(std.mem.asBytes(&h));
        const tc = tint orelse color_mod.Color.white;
        hasher.update(std.mem.asBytes(&tc.r));
        hasher.update(std.mem.asBytes(&tc.g));
        hasher.update(std.mem.asBytes(&tc.b));
        const hash = hasher.final();
        if (self.lookup(hash, frame)) |hit| return hit;
        const rendered = svg.render(allocator, bytes, w, h, tint) catch |err| {
            zlog.log("images", "svg render failed: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(rendered.pixels);
        return self.place(hash, rendered.pixels, rendered.w, rendered.h, frame);
    }

    fn lookup(self: *Cache, hash: u64, frame: u64) ?Handle {
        for (&self.entries) |*e| {
            if (e.live and e.hash == hash) {
                e.pin = frame;
                return .{ .offset = e.offset, .w = e.w, .h = e.h };
            }
        }
        return null;
    }

    const PlaceError = error{ ImageCacheFull, ImageTooLarge };

    fn place(self: *Cache, hash: u64, src: []const u8, w: u32, h: u32, frame: u64) PlaceError!Handle {
        if (src.len > self.pool.len) return PlaceError.ImageTooLarge;
        if (self.used + src.len > self.pool.len) {
            // Reclaim only when no entry is pinned by the current frame;
            // otherwise already-emitted Scene refs would go stale.
            for (&self.entries) |*e| {
                if (e.live and e.pin == frame) return PlaceError.ImageCacheFull;
            }
            for (&self.entries) |*e| e.live = false;
            self.used = 0;
            zlog.log("images", "pool reset ({d} bytes reclaimed)", .{self.pool.len});
        }
        const slot = for (&self.entries) |*e| {
            if (!e.live) break e;
        } else return PlaceError.ImageCacheFull;
        @memcpy(self.pool[self.used..][0..src.len], src);
        slot.* = .{
            .hash = hash,
            .offset = @intCast(self.used),
            .w = w,
            .h = h,
            .pin = frame,
            .live = true,
        };
        self.used += src.len;
        return .{ .offset = slot.offset, .w = w, .h = h };
    }
};

test "cache decodes once and hits on hash" {
    const t = std.testing.allocator;
    // Minimal 2x2 RGBA PNG: build the raw bytes with/zlib? Use the
    // decoder's own failure path for misses and a stub for hits.
    var cache = try Cache.init(t);
    defer cache.deinit(t);

    // Unknown bytes miss with a logged decode failure.
    try std.testing.expectError(error.UnsupportedFormat, cache.imageFromBytes(t, "not an image", 1));

    // place/lookup round-trip through the pool directly.
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const h1 = try cache.place(12345, &px, 2, 2, 7);
    try std.testing.expectEqual(@as(u32, 2), h1.w);
    try std.testing.expectEqualSlices(u8, &px, cache.pixels(h1));
    // Same hash hits without placing again.
    const h2 = cache.lookup(12345, 8) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(h1.offset, h2.offset);
    try std.testing.expect(cache.lookup(999, 8) == null);
}

test "cache reset reclaims stale entries but keeps pinned" {
    const t = std.testing.allocator;
    var cache = try Cache.init(t);
    defer cache.deinit(t);
    // Fill the pool with one huge stale entry.
    const big = try t.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
    defer t.free(big);
    @memset(big, 0xAB);
    _ = try cache.place(1, big, 1024, @intCast(limits.MAX_IMAGE_POOL_BYTES / 4096), 1);
    // Stale pin (frame 1) vs current frame 2: reset allowed.
    var small: [16]u8 = @splat(1);
    const h = try cache.place(2, &small, 2, 2, 2);
    try std.testing.expectEqualSlices(u8, &small, cache.pixels(h));
    // Now pin it this frame and fill again: must refuse, not corrupt.
    _ = cache.lookup(2, 3);
    const big2 = try t.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
    defer t.free(big2);
    try std.testing.expectError(error.ImageCacheFull, cache.place(3, big2, 1024, @intCast(limits.MAX_IMAGE_POOL_BYTES / 4096), 3));
    // Pinned entry still intact.
    try std.testing.expectEqualSlices(u8, &small, cache.pixels(h));
}
