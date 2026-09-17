//! App-owned decoded-image pool (RGBA8) keyed by content hash.
//!
//! Design mirrors the glyph atlas contract: frames reference pool offsets,
//! pool bytes must survive until present (render+present run adjacently per
//! window in `App.step`). Pool reset drops only entries unused by the
//! current frame, so already-emitted `Scene` refs stay valid; when a
//! current-frame entry blocks reset the lookup fails and the painter drops
//! the image — same drop-instead-of-grow policy as quad overflow.
//!
//! Slots and bytes reclaim independently: filling the 64 entry table evicts
//! the stalest non-pinned slot (bytes orphan until the next pool reset).
//! Every placement mints a Handle generation, so retained handles (the
//! `.handle` element path, which bypasses hash lookup) validate explicitly
//! and report stale instead of aliasing recycled bytes.

const std = @import("std");
const limits = @import("../core/limits.zig");
const color_mod = @import("../core/color.zig");
const zlog = @import("../core/log.zig");
const raster = @import("raster.zig");
const svg = @import("svg.zig");

/// Pool reference emitted into `Scene` image entries.
/// `generation` makes staleness detectable: every placement mints a fresh
/// generation, so a handle whose slot was reused or reset reports stale
/// instead of silently addressing another image's bytes. Zero is reserved
/// for `invalid` and never minted.
pub const Handle = struct {
    offset: u32,
    w: u32,
    h: u32,
    generation: u32 = 0,

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
    /// Minted per placement from `next_generation`; matches the Handle.
    generation: u32 = 0,
};

pub const Cache = struct {
    /// Asset registry shares this App-owned pool's lifetime.
    assets: @import("service.zig").Service = undefined,
    pool: []u8 = &.{},
    used: usize = 0,
    entries: [limits.MAX_CACHED_IMAGES]Entry = undefined,
    /// Monotonic placement generation; 0 is never minted (see Handle).
    next_generation: u32 = 1,
    /// Slot-eviction + stale-handle drops since init (observable budgets).
    slot_evictions: u64 = 0,
    stale_drops: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Cache {
        const self = try allocator.create(Cache);
        errdefer allocator.destroy(self);
        self.* = .{};
        self.assets = @import("service.zig").Service.init(allocator, self);
        for (&self.entries) |*e| e.* = .{};
        self.pool = try allocator.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
        return self;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.assets.deinit();
        allocator.free(self.pool);
        allocator.destroy(self);
    }

    /// Read-only resolution: returns empty unless `h` matches a live entry's
    /// generation, offset, and dimensions. Stale validation is inseparable
    /// from resolution here — callers can never observe recycled bytes
    /// through a handle whose slot was reused or whose pool was reset.
    /// Unlike `validate`, this takes a const pointer and never re-pins:
    /// pinning (which protects bytes from reset/eviction) is an explicit
    /// write effect done by `validate`/`lookup` on the paint/lookup path.
    pub fn pixels(self: *const Cache, h: Handle) []const u8 {
        if (h.generation == 0) return &.{};
        var live_match = false;
        for (&self.entries) |*e| {
            if (e.live and e.generation == h.generation and e.offset == h.offset and e.w == h.w and e.h == h.h) {
                live_match = true;
                break;
            }
        }
        if (!live_match) return &.{};
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

    pub fn lookup(self: *Cache, hash: u64, frame: u64) ?Handle {
        for (&self.entries) |*e| {
            if (e.live and e.hash == hash) {
                e.pin = frame;
                return .{ .offset = e.offset, .w = e.w, .h = e.h, .generation = e.generation };
            }
        }
        return null;
    }

    /// Re-resolve a retained handle (the `.handle` element path, which
    /// bypasses hash lookup). Returns false when the slot was reused or the
    /// pool reset since the handle was minted — the painter drops the image
    /// instead of drawing another image's bytes. On success the entry is
    /// re-pinned to `frame`, protecting its bytes like a fresh lookup.
    pub fn validate(self: *Cache, h: Handle, frame: u64) bool {
        if (h.generation == 0) {
            self.stale_drops += 1;
            return false;
        }
        for (&self.entries) |*e| {
            if (e.live and e.generation == h.generation and e.offset == h.offset and e.w == h.w and e.h == h.h) {
                e.pin = frame;
                return true;
            }
        }
        self.stale_drops += 1;
        return false;
    }

    const PlaceError = error{ ImageCacheFull, ImageTooLarge };

    pub fn place(self: *Cache, hash: u64, src: []const u8, w: u32, h: u32, frame: u64) PlaceError!Handle {
        if (src.len > self.pool.len) return PlaceError.ImageTooLarge;
        if (self.used + src.len > self.pool.len) {
            // Reclaim only when no entry is pinned by the current frame;
            // otherwise already-emitted Scene refs would go stale.
            for (&self.entries) |*e| {
                if (e.live and e.pin == frame) {
                    // Visible: the painter swallows this error, so a silent
                    // return here blanks trailing images with no trace.
                    zlog.log("images", "pool full ({d}/{d} bytes); entry dropped", .{ self.used, self.pool.len });
                    return PlaceError.ImageCacheFull;
                }
            }
            for (&self.entries) |*e| e.live = false;
            self.used = 0;
            zlog.log("images", "pool reset ({d} bytes reclaimed)", .{self.pool.len});
        }
        const slot = for (&self.entries) |*e| {
            if (!e.live) break e;
        } else blk: {
            // Ordinary slot eviction: reuse the stalest entry not pinned by
            // the current frame (its pool bytes stay orphaned until the next
            // pool reset — slots and bytes reclaim independently). The old
            // handle's generation dies with the slot, so retained handles
            // report stale instead of aliasing the new bytes.
            var victim: ?*Entry = null;
            for (&self.entries) |*e| {
                if (e.pin == frame) continue;
                if (victim == null or e.pin < victim.?.pin) victim = e;
            }
            const v = victim orelse return PlaceError.ImageCacheFull;
            self.slot_evictions += 1;
            break :blk v;
        };
        // Mint before writing: even a zero-size placement retires the old
        // generation (a reused slot never aliases a retained handle).
        // Wraps after 4B placements, skipping 0; no handle can outlive
        // the pool churn between reuses.
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        @memcpy(self.pool[self.used..][0..src.len], src);
        slot.* = .{
            .hash = hash,
            .offset = @intCast(self.used),
            .w = w,
            .h = h,
            .pin = frame,
            .live = true,
            .generation = generation,
        };
        self.used += src.len;
        return .{ .offset = slot.offset, .w = w, .h = h, .generation = generation };
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

test "cache evicts stalest slot when the table fills" {
    const t = std.testing.allocator;
    var cache = try Cache.init(t);
    defer cache.deinit(t);
    var px: [4]u8 = @splat(7);
    var first: Handle = .invalid;
    var i: u64 = 0;
    while (i < limits.MAX_CACHED_IMAGES) : (i += 1) {
        const h = try cache.place(1000 + i, &px, 1, 1, 1);
        if (i == 0) first = h;
        try std.testing.expect(h.generation != 0);
    }
    // Table full, pool nearly empty: the 65th placement evicts the stalest
    // non-pinned slot instead of failing.
    const fresh = try cache.place(99999, &px, 1, 1, 2);
    try std.testing.expectEqual(@as(u64, 1), cache.slot_evictions);
    try std.testing.expect(cache.validate(fresh, 2));
    // The evicted handle reports stale — it must never alias the new bytes.
    try std.testing.expect(!cache.validate(first, 2));
    try std.testing.expectEqual(@as(u64, 1), cache.stale_drops);
    // ...while a surviving entry still validates.
    const survivor = try cache.place(88888, &px, 1, 1, 2);
    _ = survivor;
    try std.testing.expect(cache.validate(fresh, 2));
}

test "cache handle goes stale across pool reset" {
    const t = std.testing.allocator;
    var cache = try Cache.init(t);
    defer cache.deinit(t);
    var small: [16]u8 = @splat(3);
    const h = try cache.place(42, &small, 2, 2, 1);
    try std.testing.expect(cache.validate(h, 1));
    // Next frame the pool resets around it (stale pin, no current pins).
    const big = try t.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
    defer t.free(big);
    _ = try cache.place(43, big, 1024, @intCast(limits.MAX_IMAGE_POOL_BYTES / 4096), 2);
    try std.testing.expect(!cache.validate(h, 2));
    // Invalid handles never validate.
    try std.testing.expect(!cache.validate(.invalid, 2));
}

test "stale handle pixels return empty, not recycled bytes" {
    // Regression: pixels() used to bounds-check only, so a stale handle
    // after a pool reset aliased whatever was placed at the same offset.
    const t = std.testing.allocator;
    var cache = try Cache.init(t);
    defer cache.deinit(t);
    var small: [16]u8 = @splat(3);
    const stale = try cache.place(42, &small, 2, 2, 1);
    try std.testing.expectEqualSlices(u8, &small, cache.pixels(stale));
    const big = try t.alloc(u8, limits.MAX_IMAGE_POOL_BYTES);
    defer t.free(big);
    @memset(big, 0xCD);
    const fresh = try cache.place(43, big, 1024, @intCast(limits.MAX_IMAGE_POOL_BYTES / 4096), 2);
    // The recycled offset now holds new bytes; the stale handle must not
    // expose them, and the invalid handle never resolves.
    try std.testing.expectEqual(@as(usize, 0), cache.pixels(stale).len);
    try std.testing.expect(!cache.validate(stale, 2));
    try std.testing.expectEqual(@as(usize, 0), cache.pixels(.invalid).len);
    try std.testing.expect(cache.pixels(fresh).len > 0);
}
