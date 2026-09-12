//! Outline cache, ported from `glifo/src/glyph.rs`.
//!
//! Caches `BezPath` outlines keyed by font identity, glyph, size bits,
//! embolden parameters and hint flag, with upstream's `maintain()` policy
//! (`MAX_ENTRY_AGE = 64`, `PRUNE_FREQUENCY = 64`,
//! `CACHED_COUNT_THRESHOLD = 256`, `MAX_FREE_LIST_SIZE = 128`).
//!
//! Variable fonts use upstream's two-level map: an empty coordinate slice goes
//! to `static_map`, anything else to `variable_map[coords]`. The partition key
//! is the *raw* slice (all-zero coordinates still get a variable entry, exactly
//! like `OutlineCacheSession` upstream), while `skrifa` collapses all-zero
//! coordinates to "no variation" when drawing through `effective_coords`.
//!
//! Ownership: entries own heap-allocated `BezPath`s and hand out borrowed
//! pointers (`CachedOutline.path`). A borrowed path is valid until the next
//! `maintain`, `clear` or `deinit` that evicts it; callers must not hold it
//! across frames.
//!
//! Divergence from upstream (documented per plan.md §3): upstream holds
//! `Arc<BezPath>` and only recycles uniquely-owned paths through its free
//! list, so an evicted path can outlive the cache. Here eviction invalidates
//! borrowed pointers. The renderer consumes outlines within a frame, so
//! pixels are unaffected.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const pen_mod = @import("pen.zig");

pub const GlyphId = font_mod.GlyphId;
pub const NormalizedCoord = font_mod.NormalizedCoord;

/// Font identity for cache keys; matches `glifo`'s `FontInfo`.
pub const FontInfo = struct {
    id: u64,
    index: u32,
    upem: f32,
};

/// Synthetic embolden request. Only the default (zero amount) is supported;
/// anything else is `error.Unsupported` until kurbo `expand_path` is ported.
pub const FontEmbolden = struct {
    amount: [2]f32 = .{ 0.0, 0.0 },
    join: kurbo.Join = .miter,
    miter_limit: f64 = 4.0,
    tolerance: f64 = 0.1,

    pub fn new(amount: [2]f32) FontEmbolden {
        return .{ .amount = amount };
    }

    pub fn withJoin(self: FontEmbolden, join: kurbo.Join) FontEmbolden {
        var result = self;
        result.join = join;
        return result;
    }

    pub fn withMiterLimit(self: FontEmbolden, miter_limit: f64) FontEmbolden {
        var result = self;
        result.miter_limit = miter_limit;
        return result;
    }

    pub fn withTolerance(self: FontEmbolden, tolerance: f64) FontEmbolden {
        var result = self;
        result.tolerance = tolerance;
        return result;
    }

    pub fn isDefault(self: FontEmbolden) bool {
        return self.amount[0] == 0.0 and self.amount[1] == 0.0;
    }
};

/// Cache key; field-for-field the upstream `OutlineKey` (u32 bit patterns for
/// every float and the packed join discriminant). Variation coordinates are
/// deliberately absent: the two-level map partitions by them, matching
/// upstream.
pub const OutlineKey = struct {
    font_id: u64,
    font_index: u32,
    glyph_id: u32,
    size_bits: u32,
    embolden_x_bits: u32,
    embolden_y_bits: u32,
    embolden_join_bits: u8,
    embolden_miter_limit_bits: u32,
    embolden_tolerance_bits: u32,
    hint: bool,
};

/// Deterministic hasher (upstream uses `foldhash` with a fixed seed; Zig's
/// default map seed is per-instance, so pin Wyhash seed 0 here). Iteration
/// order is not part of the pixel contract.
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: OutlineKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.font_id));
        h.update(std.mem.asBytes(&key.font_index));
        h.update(std.mem.asBytes(&key.glyph_id));
        h.update(std.mem.asBytes(&key.size_bits));
        h.update(std.mem.asBytes(&key.embolden_x_bits));
        h.update(std.mem.asBytes(&key.embolden_y_bits));
        h.update(std.mem.asBytes(&key.embolden_join_bits));
        h.update(std.mem.asBytes(&key.embolden_miter_limit_bits));
        h.update(std.mem.asBytes(&key.embolden_tolerance_bits));
        h.update(std.mem.asBytes(&key.hint));
        return h.final();
    }

    pub fn eql(_: KeyContext, a: OutlineKey, b: OutlineKey) bool {
        return std.meta.eql(a, b);
    }
};

const OutlineMap = std.HashMapUnmanaged(
    OutlineKey,
    *OutlineEntry,
    KeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Owned variation-coordinate key for the second-level map. Lookups use a
/// borrowed slice with the same content hash, so `get` never allocates.
pub const VarKey = struct {
    coords: []const NormalizedCoord,
};

const VarContext = struct {
    pub fn hash(_: VarContext, key: VarKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(key.coords));
        return h.final();
    }

    pub fn eql(_: VarContext, a: VarKey, b: VarKey) bool {
        return std.mem.eql(NormalizedCoord, a.coords, b.coords);
    }
};

const VariableMap = std.HashMapUnmanaged(
    VarKey,
    *OutlineMap,
    VarContext,
    std.hash_map.default_max_load_percentage,
);

const OutlineEntry = struct {
    path: *kurbo.BezPath,
    bbox: kurbo.Rect,
    serial: u32,
};

/// A cached outline plus its tight bounding box.
pub const CachedOutline = struct {
    /// Borrowed; valid until the owning cache evicts the entry.
    path: *const kurbo.BezPath,
    bbox: kurbo.Rect,
};

/// Maximum number of full renders where an unused glyph is retained.
const max_entry_age: u32 = 64;
/// Maximum number of full renders before a forced prune.
const prune_frequency: u32 = 64;
/// Always prune when the cached count is above this.
const cached_count_threshold: usize = 256;
/// Number of paths kept on the free list for reuse.
const max_free_list_size: usize = 128;

pub const OutlineCache = struct {
    free_list: std.ArrayList(*kurbo.BezPath) = .empty,
    static_map: OutlineMap = .empty,
    variable_map: VariableMap = .empty,
    cached_count: usize = 0,
    serial: u32 = 0,
    last_prune_serial: u32 = 0,

    /// Looks up, or draws and stores, the outline for `gid`.
    ///
    /// `hint_instance` runs the TrueType interpreter (configured for `size`)
    /// and makes the cache key hint-distinct; `null` draws unhinted. Non-empty
    /// `coords` on a font without variation tables are a no-op (they only
    /// select the variable map), matching upstream. Non-default embolden is
    /// still `error.Unsupported`.
    pub fn getOrInsert(
        self: *OutlineCache,
        allocator: std.mem.Allocator,
        outlines: *const glyf.Outlines,
        gid: GlyphId,
        font_info: FontInfo,
        size: f32,
        embolden: FontEmbolden,
        coords: []const NormalizedCoord,
        hint_instance: ?*const glyf.HintInstance,
    ) glyf.DrawError!CachedOutline {
        if (!embolden.isDefault()) return error.Unsupported;

        const key = OutlineKey{
            .font_id = font_info.id,
            .font_index = font_info.index,
            .glyph_id = gid,
            .size_bits = @bitCast(size),
            .embolden_x_bits = @bitCast(embolden.amount[0]),
            .embolden_y_bits = @bitCast(embolden.amount[1]),
            .embolden_join_bits = @backingInt(embolden.join),
            .embolden_miter_limit_bits = @bitCast(@as(f32, @floatCast(embolden.miter_limit))),
            .embolden_tolerance_bits = @bitCast(@as(f32, @floatCast(embolden.tolerance))),
            .hint = hint_instance != null,
        };
        if (coords.len == 0) {
            return self.mapGetOrInsert(
                allocator,
                &self.static_map,
                key,
                outlines,
                gid,
                size,
                coords,
                hint_instance,
            );
        }
        const lookup = VarKey{ .coords = coords };
        const map = if (self.variable_map.getPtr(lookup)) |existing| existing.* else blk: {
            const owned = try allocator.dupe(NormalizedCoord, coords);
            errdefer allocator.free(owned);
            const created = try allocator.create(OutlineMap);
            created.* = .empty;
            errdefer allocator.destroy(created);
            try self.variable_map.put(allocator, .{ .coords = owned }, created);
            break :blk created;
        };
        return self.mapGetOrInsert(
            allocator,
            map,
            key,
            outlines,
            gid,
            size,
            coords,
            hint_instance,
        );
    }

    fn mapGetOrInsert(
        self: *OutlineCache,
        allocator: std.mem.Allocator,
        map: *OutlineMap,
        key: OutlineKey,
        outlines: *const glyf.Outlines,
        gid: GlyphId,
        size: f32,
        coords: []const NormalizedCoord,
        hint_instance: ?*const glyf.HintInstance,
    ) glyf.DrawError!CachedOutline {
        if (map.getPtr(key)) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.serial = self.serial;
            return .{ .path = entry.path, .bbox = entry.bbox };
        }

        const path = self.free_list.pop() orelse blk: {
            const created = try allocator.create(kurbo.BezPath);
            created.* = kurbo.BezPath.init();
            break :blk created;
        };
        path.truncate(0);
        errdefer {
            path.deinit(allocator);
            allocator.destroy(path);
        }
        var path_pen = pen_mod.PathPen.init(allocator, path);
        const metrics = try outlines.draw(allocator, gid, .{
            .size = size,
            .coords = coords,
            .hint_instance = hint_instance,
        }, &path_pen);
        _ = metrics;
        const bbox = path.boundingBox();
        const entry = try allocator.create(OutlineEntry);
        errdefer allocator.destroy(entry);
        entry.* = .{ .path = path, .bbox = bbox, .serial = self.serial };
        try map.put(allocator, key, entry);
        self.cached_count += 1;
        return .{ .path = path, .bbox = bbox };
    }

    /// Evicts entries not touched for `max_entry_age` serials.
    ///
    /// Mirrors upstream: cheap no-op inside the prune window unless the cache
    /// grew past the threshold.
    pub fn maintain(self: *OutlineCache, allocator: std.mem.Allocator) void {
        self.serial +%= 1;
        if (self.serial -% self.last_prune_serial < prune_frequency and
            self.cached_count < cached_count_threshold)
        {
            return;
        }
        self.last_prune_serial = self.serial;

        var expired: std.ArrayList(OutlineKey) = .empty;
        defer expired.deinit(allocator);
        var expired_var: std.ArrayList(VarKey) = .empty;
        defer expired_var.deinit(allocator);

        var iterator = self.static_map.iterator();
        while (iterator.next()) |map_entry| {
            const entry = map_entry.value_ptr.*;
            if (self.serial -% entry.serial > max_entry_age) {
                expired.append(allocator, map_entry.key_ptr.*) catch {
                    // Allocation failure only limits how much we evict; the
                    // cache stays correct, so keep what we already collected.
                    break;
                };
            }
        }
        for (expired.items) |key| {
            const entry = self.static_map.fetchRemove(key).?.value;
            self.recycle(allocator, entry);
        }

        var var_iterator = self.variable_map.iterator();
        while (var_iterator.next()) |outer| {
            const map = outer.value_ptr.*;
            var inner_iterator = map.iterator();
            while (inner_iterator.next()) |map_entry| {
                const entry = map_entry.value_ptr.*;
                if (self.serial -% entry.serial > max_entry_age) {
                    expired_var.append(allocator, outer.key_ptr.*) catch break;
                    break;
                }
            }
        }
        for (expired_var.items) |var_key| {
            const map = self.variable_map.get(var_key) orelse continue;
            var inner_iterator = map.iterator();
            var remove_keys: std.ArrayList(OutlineKey) = .empty;
            defer remove_keys.deinit(allocator);
            while (inner_iterator.next()) |map_entry| {
                const entry = map_entry.value_ptr.*;
                if (self.serial -% entry.serial > max_entry_age) {
                    remove_keys.append(allocator, map_entry.key_ptr.*) catch break;
                }
            }
            for (remove_keys.items) |key| {
                const entry = map.fetchRemove(key).?.value;
                self.recycle(allocator, entry);
            }
            if (map.count() == 0) {
                const removed = self.variable_map.fetchRemove(var_key).?;
                removed.value.deinit(allocator);
                allocator.destroy(removed.value);
                allocator.free(removed.key.coords);
            }
        }
    }

    fn recycle(self: *OutlineCache, allocator: std.mem.Allocator, entry: *OutlineEntry) void {
        if (self.free_list.items.len < max_free_list_size) {
            entry.path.truncate(0);
            self.free_list.append(allocator, entry.path) catch {
                entry.path.deinit(allocator);
                allocator.destroy(entry.path);
            };
        } else {
            entry.path.deinit(allocator);
            allocator.destroy(entry.path);
        }
        allocator.destroy(entry);
        self.cached_count -= 1;
    }

    /// Drops every cached outline and the free list.
    pub fn clear(self: *OutlineCache, allocator: std.mem.Allocator) void {
        var iterator = self.static_map.iterator();
        while (iterator.next()) |map_entry| {
            const entry = map_entry.value_ptr.*;
            entry.path.deinit(allocator);
            allocator.destroy(entry.path);
            allocator.destroy(entry);
        }
        self.static_map.clearRetainingCapacity();
        var var_iterator = self.variable_map.iterator();
        while (var_iterator.next()) |outer| {
            const map = outer.value_ptr.*;
            var inner_iterator = map.iterator();
            while (inner_iterator.next()) |map_entry| {
                const entry = map_entry.value_ptr.*;
                entry.path.deinit(allocator);
                allocator.destroy(entry.path);
                allocator.destroy(entry);
            }
            map.deinit(allocator);
            allocator.destroy(map);
            allocator.free(outer.key_ptr.coords);
        }
        self.variable_map.clearRetainingCapacity();
        self.cached_count = 0;
        self.serial = 0;
        self.last_prune_serial = 0;
        for (self.free_list.items) |path| {
            path.deinit(allocator);
            allocator.destroy(path);
        }
        self.free_list.clearRetainingCapacity();
    }

    /// Frees the cache's own storage; call at teardown.
    pub fn deinit(self: *OutlineCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.free_list.deinit(allocator);
        self.static_map.deinit(allocator);
        self.variable_map.deinit(allocator);
        self.* = .{};
    }

    pub fn cachedCount(self: *const OutlineCache) usize {
        return self.cached_count;
    }
};

// --------------------------------------------------------------------- tests

fn testFontInfo() FontInfo {
    return .{ .id = 0x1234, .index = 0, .upem = 2048.0 };
}

test "outline cache reuses entries and survives repeated lookups" {
    const fixture = @import("test_fixture.zig");
    const font = try font_mod.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var cache = OutlineCache{};
    defer cache.deinit(std.testing.allocator);
    const first = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        null,
    );
    const second = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), cache.cachedCount());
    try std.testing.expectEqual(first.path, second.path);
    try std.testing.expect(first.path.elementsSlice().len > 0);
}

test "outline cache content matches a direct draw" {
    const fixture = @import("test_fixture.zig");
    const font = try font_mod.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();

    var direct = pen_mod.PathElementPen.init(std.testing.allocator);
    defer direct.deinit();
    _ = try outlines.draw(std.testing.allocator, 37, .{ .size = 16.0 }, &direct);

    var cache = OutlineCache{};
    defer cache.deinit(std.testing.allocator);
    const cached = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        null,
    );
    // f64 BezPath elements widen the exact f32 the pen emitted, so casting
    // back recovers the same bits.
    try std.testing.expectEqual(direct.elements.items.len, cached.path.elementsSlice().len);
    for (direct.elements.items, cached.path.elementsSlice()) |expected, actual| {
        switch (expected) {
            .move_to => |p| {
                const q = switch (actual) {
                    .MoveTo => |point| point,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(@as(u32, @bitCast(p[0])), @as(u32, @bitCast(@as(f32, @floatCast(q.x)))));
                try std.testing.expectEqual(@as(u32, @bitCast(p[1])), @as(u32, @bitCast(@as(f32, @floatCast(q.y)))));
            },
            .line_to => |p| {
                const q = switch (actual) {
                    .LineTo => |point| point,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(@as(u32, @bitCast(p[0])), @as(u32, @bitCast(@as(f32, @floatCast(q.x)))));
                try std.testing.expectEqual(@as(u32, @bitCast(p[1])), @as(u32, @bitCast(@as(f32, @floatCast(q.y)))));
            },
            .quad_to => |q| {
                const a = switch (actual) {
                    .QuadTo => |points| points,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(@as(u32, @bitCast(q.c0[0])), @as(u32, @bitCast(@as(f32, @floatCast(a.p1.x)))));
                try std.testing.expectEqual(@as(u32, @bitCast(q.c0[1])), @as(u32, @bitCast(@as(f32, @floatCast(a.p1.y)))));
                try std.testing.expectEqual(@as(u32, @bitCast(q.p[0])), @as(u32, @bitCast(@as(f32, @floatCast(a.p2.x)))));
                try std.testing.expectEqual(@as(u32, @bitCast(q.p[1])), @as(u32, @bitCast(@as(f32, @floatCast(a.p2.y)))));
            },
            .close => try std.testing.expectEqual(kurbo.PathEl.ClosePath, actual),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "outline cache evicts unused entries after max age" {
    const fixture = @import("test_fixture.zig");
    const font = try font_mod.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var cache = OutlineCache{};
    defer cache.deinit(std.testing.allocator);
    _ = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), cache.cachedCount());
    // First maintain starts the serial clock; the entry is touched at serial
    // 0, so a prune at serial > 64 evicts it. Maintain is a no-op inside the
    // 64-render prune window, so run two windows' worth.
    var i: usize = 0;
    while (i <= max_entry_age * 2 + 2) : (i += 1) {
        cache.maintain(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), cache.cachedCount());
    try std.testing.expect(cache.free_list.items.len > 0);
    cache.clear(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cache.free_list.items.len);
}

test "outline cache separates variable coordinates" {
    const fixture = @import("test_fixture.zig");
    const font = try font_mod.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var cache = OutlineCache{};
    defer cache.deinit(std.testing.allocator);
    // A non-variable font ignores the coordinates (no-op), but upstream still
    // separates the entries by the raw coordinate slice.
    const static_entry = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        null,
    );
    const var_entry = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{0},
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), cache.cachedCount());
    try std.testing.expectEqual(@as(usize, 1), cache.variable_map.count());
    try std.testing.expect(static_entry.path != var_entry.path);
    // Same coordinates reuse the variable entry.
    const again = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{0},
        null,
    );
    try std.testing.expectEqual(var_entry.path, again.path);
    try std.testing.expectEqual(@as(usize, 2), cache.cachedCount());

    // A second coordinate key adds a second outer entry.
    _ = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{ 100, -100 },
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), cache.variable_map.count());
    try std.testing.expectEqual(@as(usize, 3), cache.cachedCount());

    // Eviction releases the nested maps and their owned coordinate keys.
    var i: usize = 0;
    while (i <= max_entry_age * 2 + 2) : (i += 1) {
        cache.maintain(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), cache.cachedCount());
    try std.testing.expectEqual(@as(usize, 0), cache.variable_map.count());
}

test "outline cache rejects unsupported inputs" {
    const fixture = @import("test_fixture.zig");
    const font = try font_mod.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var cache = OutlineCache{};
    defer cache.deinit(std.testing.allocator);
    var instance = try outlines.createHintInstance(
        std.testing.allocator,
        16.0,
        &.{},
        glyf.glifo_hint_target,
    );
    defer instance.deinit();
    const hinted = try cache.getOrInsert(
        std.testing.allocator,
        &outlines,
        37,
        testFontInfo(),
        16.0,
        .{},
        &.{},
        &instance,
    );
    try std.testing.expect(hinted.path.elementsSlice().len > 0);
    try std.testing.expectError(
        error.Unsupported,
        cache.getOrInsert(
            std.testing.allocator,
            &outlines,
            37,
            testFontInfo(),
            16.0,
            FontEmbolden.new(.{ 0.5, 0.0 }),
            &.{},
            null,
        ),
    );
}
