//! Layout cache: per-node multi-slot memo table for computed sizes.
//!
//! Ports Taffy's `tree/cache.rs` (`CacheTree` + `compute_cached_layout`).
//! The insight: layout is a pure function of
//! `{known_dims, available_space, sizing_mode}` for a fixed style + fixed
//! children. Same input ⇒ same output, so a second visit (intrinsic probe
//! followed by real layout, or an untouched subtree on the next frame) can
//! skip the kernel entirely.
//!
//! ## Slot design (fixed, not hashed)
//!
//! Each node owns [`cache_slots`] entries (`3`: final layout + two probe
//! sizes covers the flex intrinsic pattern of min-content, max-content, and
//! definite passes). Lookup is a linear scan over 3 keys — no hashing, no
//! eviction lists, no allocation. On miss, round-robin overwrite
//! (`next` cursor) approximates LRU well because probes repeat in the same
//! order every frame (Clock-style behavior for free).
//!
//! ## What is (and is not) cached
//!
//! Cached: the node's **border-box size** only. Child *origins* are never
//! cached — the placement walk in `compute.zig` always runs so a moved
//! parent correctly repositions clean children (this is the Clay hybrid:
//! per-frame placement walk + Taffy size memo).
//!
//! Correctness rule: if you add an input that changes a kernel's output
//! (a new style field, a scale factor, a measure-hook generation counter),
//! add it to [`CacheKey`] or bump a version. A stale hit serves a wrong
//! size with zero diagnostics — the worst kind of layout bug.
//!
//! ## Invalidation
//!
//! Structural/style edits set the dirty flag up the ancestor chain
//! (`tree.markDirty`). A dirty node skips lookup but still *fills* the
//! cache, so one clean frame re-primes every slot.

const geo = @import("geometry.zig");
const core = @import("../core/root.zig");

/// Slots per node. 3 covers `{definite, min-content, max-content}` probes
/// that flex/grid containers issue for the same child within one layout.
pub const cache_slots: usize = 3;

/// Cache key: every input that can change a node's computed size.
/// Must stay in sync with `geometry.LayoutInput` — same fields, same order.
pub const CacheKey = struct {
    known_w: ?f32 = null,
    known_h: ?f32 = null,
    avail_w: geo.AvailableSpace = .max_content,
    avail_h: geo.AvailableSpace = .max_content,
    sizing: geo.SizingMode = .content_box,

    /// Build directly from a [`geo.LayoutInput`]. Single construction site
    /// so the dispatcher cannot forget a field.
    pub fn fromInput(input: geo.LayoutInput) CacheKey {
        return .{
            .known_w = input.known.w,
            .known_h = input.known.h,
            .avail_w = input.available.w,
            .avail_h = input.available.h,
            .sizing = input.sizing_mode,
        };
    }

    fn eql(a: CacheKey, b: CacheKey) bool {
        if (a.known_w != b.known_w) return false;
        if (a.known_h != b.known_h) return false;
        if (a.sizing != b.sizing) return false;
        if (!availEql(a.avail_w, b.avail_w)) return false;
        if (!availEql(a.avail_h, b.avail_h)) return false;
        return true;
    }

    /// `NaN` never flows here (all sizes are clamped before caching), so
    /// bitwise `==` on definite values is sound — no epsilon matching.
    fn availEql(a: geo.AvailableSpace, b: geo.AvailableSpace) bool {
        return switch (a) {
            .definite => |av| switch (b) {
                .definite => |bv| av == bv,
                else => false,
            },
            .min_content => b == .min_content,
            .max_content => b == .max_content,
        };
    }
};

/// One memoized size plus the key that produced it.
pub const CacheEntry = struct {
    valid: bool = false,
    key: CacheKey = .{},
    size: core.Size = .{},
};

/// Fixed slot array for a single node. Lives in a parallel pool in
/// `compute.zig` (`caches: [max_nodes]NodeCache`), never inside `Node`
/// itself, keeping the hot tree struct small.
pub const NodeCache = struct {
    slots: [cache_slots]CacheEntry = undefined,
    next: usize = 0,

    /// Look up a size. Returns `null` on miss. `undefined` slots are only
    /// read after [`clear`] (which marks all invalid), so construct then
    /// clear before first use — see `ComputeTree.init`.
    pub fn get(self: *const NodeCache, key: CacheKey) ?core.Size {
        for (self.slots) |s| {
            if (s.valid and s.key.eql(key)) return s.size;
        }
        return null;
    }

    /// Store a size, evicting the oldest slot round-robin.
    pub fn put(self: *NodeCache, key: CacheKey, size: core.Size) void {
        self.slots[self.next] = .{ .valid = true, .key = key, .size = size };
        self.next = (self.next + 1) % cache_slots;
    }

    /// Invalidate all slots (frame reset / style change path).
    pub fn clear(self: *NodeCache) void {
        for (&self.slots) |*s| s.valid = false;
        self.next = 0;
    }
};

test "cache miss then hit" {
    const testing = @import("std").testing;
    var c = NodeCache{};
    c.clear();
    const k = CacheKey{ .known_w = 10 };
    try testing.expect(c.get(k) == null);
    c.put(k, .{ .w = 10, .h = 5 });
    const hit = c.get(k).?;
    try testing.expectEqual(@as(f32, 10), hit.w);
    try testing.expectEqual(@as(f32, 5), hit.h);
}

test "cache distinguishes axes and sizing mode" {
    const testing = @import("std").testing;
    var c = NodeCache{};
    c.clear();
    c.put(.{ .known_w = 10 }, .{ .w = 1, .h = 1 });
    // Different known_h misses.
    try testing.expect(c.get(.{ .known_w = 10, .known_h = 5 }) == null);
    // Different sizing mode misses.
    try testing.expect(c.get(.{ .known_w = 10, .sizing = .inherent }) == null);
    // Different available space misses.
    try testing.expect(c.get(.{ .known_w = 10, .avail_w = .{ .definite = 99 } }) == null);
}

test "cache round-robin holds three live entries" {
    const testing = @import("std").testing;
    var c = NodeCache{};
    c.clear();
    c.put(.{ .known_w = 1 }, .{ .w = 1, .h = 0 });
    c.put(.{ .known_w = 2 }, .{ .w = 2, .h = 0 });
    c.put(.{ .known_w = 3 }, .{ .w = 3, .h = 0 });
    try testing.expectEqual(@as(f32, 1), c.get(.{ .known_w = 1 }).?.w);
    try testing.expectEqual(@as(f32, 2), c.get(.{ .known_w = 2 }).?.w);
    try testing.expectEqual(@as(f32, 3), c.get(.{ .known_w = 3 }).?.w);
    // Fourth entry evicts the oldest (key 1).
    c.put(.{ .known_w = 4 }, .{ .w = 4, .h = 0 });
    try testing.expect(c.get(.{ .known_w = 1 }) == null);
    try testing.expectEqual(@as(f32, 4), c.get(.{ .known_w = 4 }).?.w);
}

test "cache clear invalidates everything" {
    const testing = @import("std").testing;
    var c = NodeCache{};
    c.clear();
    c.put(.{}, .{ .w = 9, .h = 9 });
    try testing.expect(c.get(.{}) != null);
    c.clear();
    try testing.expect(c.get(.{}) == null);
}

test "cache key from layout input" {
    const testing = @import("std").testing;
    const input = geo.LayoutInput{
        .known = .{ .w = 10 },
        .available = .{ .w = .{ .definite = 100 }, .h = .max_content },
        .sizing_mode = .inherent,
    };
    const k = CacheKey.fromInput(input);
    try testing.expectEqual(@as(?f32, 10), k.known_w);
    try testing.expect(k.known_h == null);
    try testing.expectEqual(@as(?f32, 100), k.avail_w.opt());
    try testing.expect(k.avail_h == .max_content);
    try testing.expect(k.sizing == .inherent);
}
