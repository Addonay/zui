//! Glyph atlas cache with age-based eviction.
//!
//! Port of `glifo/src/atlas/cache.rs`. The cache stores one `AtlasSlot` per
//! distinct `GlyphCacheKey`, allocates atlas space through the shared
//! `ImageCache`, queues per-page command recorders for deferred replay, and
//! evicts entries that have not been touched for `max_entry_age` frames.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Explicit allocators: every mutating entry point takes the allocator used
//!   for map/vector storage and for the `ImageCache` calls.
//! - `insert` distinguishes `error.OutOfMemory` from "atlas full" (`null`);
//!   upstream's `.ok()?` collapses both.
//! - Variable-font entries use upstream's two-level map, partitioned by the
//!   raw `GlyphCacheKey.var_coords` slice (which stays excluded from key
//!   equality). The outer key owns a copy of the coordinates; lookups are
//!   allocation-free borrowed-content lookups.
//! - `PendingBitmapUpload` is a borrowing queue (`pendingUploads` +
//!   `clearPendingUploads`) instead of a draining iterator, because Zig's
//!   `clearRetainingCapacity` poisons the backing storage in safe builds.
//!   The backend copies each pixmap into its atlas page before clearing.
//! - Deterministic hash map type: fixed-seed Wyhash (`key.KeyContext`).
//!   Iteration/eviction order is not part of the pixel contract.

const std = @import("std");
const image_cache_mod = @import("../../common/image_cache.zig");
const paint_mod = @import("../../common/paint.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const shared_mod = @import("../../common/shared.zig");
const key_mod = @import("key.zig");
const region = @import("region.zig");
const commands = @import("commands.zig");

pub const GlyphCacheKey = key_mod.GlyphCacheKey;
pub const GlyphCacheConfig = struct {
    /// Maximum age (in frames) before an unused entry is evicted.
    max_entry_age: u64 = 64,
    /// How often (in frames) to run the eviction pass.
    eviction_frequency: u64 = 64,
    /// Maximum font size (in ppem) that will be cached. Glyphs rendered at
    /// sizes above this threshold are drawn directly each frame.
    max_cached_font_size: f32 = 128.0,
};

/// Padding in pixels added to each side of a glyph to prevent texture bleeding.
///
/// The hybrid (GPU) renderer samples atlas sub-images via `Extend::Pad`, which
/// clamps out-of-bounds coordinates to the edge texel. 1px is sufficient: the
/// strip-rasteriser overshoot is sub-pixel and the transparent padding absorbs
/// it. This padding also enables a future switch to native bilinear sampling.
pub const GLYPH_PADDING: u16 = 1;

/// An atlas region that must be cleared to transparent.
///
/// Accumulated during eviction (`GlyphAtlas.maintain`); the application must
/// zero each region so a later reuse of the slot cannot composite stale pixels
/// through `SrcOver`.
pub const PendingClearRect = struct {
    /// Which atlas page contains this region.
    page_index: u32,
    /// X position of the padded region in the atlas (pixels).
    x: u16,
    /// Y position of the padded region in the atlas (pixels).
    y: u16,
    /// Width of the padded region (pixels).
    width: u16,
    /// Height of the padded region (pixels).
    height: u16,
};

/// One cache entry: the allocated slot and its last-touch serial.
pub const GlyphCacheEntry = struct {
    /// Atlas slot information for blitting.
    atlas_slot: region.AtlasSlot,
    /// Frame serial when last accessed (for age-based eviction).
    serial: u64,
};

/// A bitmap glyph pixmap awaiting upload into an atlas page.
///
/// Accumulated during glyph encoding when a bitmap glyph is inserted into the
/// cache. The backend must copy each pixmap into the atlas at the position
/// indicated by `atlas_slot` before the render pass that samples the page.
pub const PendingBitmapUpload = struct {
    /// The image ID allocated in the shared `ImageCache`.
    image_id: paint_mod.ImageId,
    /// The bitmap pixel data to upload.
    pixmap: shared_mod.Shared(pixmap_mod.Pixmap),
    /// The atlas slot information for this glyph (includes dimensions).
    atlas_slot: region.AtlasSlot,
};

const GlyphMap = std.HashMapUnmanaged(
    GlyphCacheKey,
    *GlyphCacheEntry,
    key_mod.KeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Owned variation-coordinate key for the second-level atlas map.
pub const VarKey = struct {
    coords: []const key_mod.NormalizedCoord,
};

const VarContext = struct {
    pub fn hash(_: VarContext, key: VarKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(key.coords));
        return h.final();
    }

    pub fn eql(_: VarContext, a: VarKey, b: VarKey) bool {
        return std.mem.eql(key_mod.NormalizedCoord, a.coords, b.coords);
    }
};

const VariableMap = std.HashMapUnmanaged(
    VarKey,
    *GlyphMap,
    VarContext,
    std.hash_map.default_max_load_percentage,
);

/// Core glyph atlas cache data shared by all renderer backends.
///
/// Contains the cache entries, age tracking, and pending queues. Does **not**
/// own pixel storage — the integrating renderer owns the page pixmaps (see
/// `cpu/text.zig`).
pub const GlyphAtlas = struct {
    /// Eviction configuration.
    eviction_config: GlyphCacheConfig = .{},
    /// Entries for non-variable fonts.
    static_entries: GlyphMap = .empty,
    /// Entries for variable fonts, partitioned by the variation coordinates
    /// (upstream's `variable_entries`). The inner keys exclude `var_coords`
    /// from equality, exactly like upstream.
    variable_entries: VariableMap = .empty,
    /// Current frame serial for age tracking.
    serial: u64 = 0,
    /// Serial of the last eviction pass.
    last_eviction_serial: u64 = 0,
    /// Total cached glyph count.
    entry_count: usize = 0,
    /// Bitmap glyphs awaiting upload into their atlas pages.
    pending_uploads: std.ArrayListUnmanaged(PendingBitmapUpload) = .empty,
    /// Atlas regions that must be cleared to transparent before reuse.
    pending_clear_rects: std.ArrayListUnmanaged(PendingClearRect) = .empty,
    /// Outline commands awaiting replay, indexed by atlas page.
    pending_atlas_commands: std.ArrayListUnmanaged(?commands.AtlasCommandRecorder) = .empty,
    /// Number of cache hits since last `clearStats`.
    cache_hits: u64 = 0,
    /// Number of cache misses since last `clearStats`.
    cache_misses: u64 = 0,

    /// Creates a new empty cache with default eviction settings.
    pub fn init() GlyphAtlas {
        return .{};
    }

    /// Creates a new empty cache with custom eviction settings.
    pub fn initWithConfig(config: GlyphCacheConfig) GlyphAtlas {
        return .{ .eviction_config = config };
    }

    /// Release every cache entry, pending command and queue allocation.
    pub fn deinit(self: *GlyphAtlas, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.static_entries.deinit(allocator);
        self.variable_entries.deinit(allocator);
        self.pending_uploads.deinit(allocator);
        self.pending_clear_rects.deinit(allocator);
        self.pending_atlas_commands.deinit(allocator);
        self.* = undefined;
    }

    /// The map that holds `coords`: the static map for an empty slice,
    /// otherwise the second-level variable map (upstream's two-level layout).
    fn mapForCoords(self: *GlyphAtlas, coords: []const key_mod.NormalizedCoord) ?*GlyphMap {
        if (coords.len == 0) return &self.static_entries;
        const ptr = self.variable_entries.getPtr(.{ .coords = coords }) orelse return null;
        return ptr.*;
    }

    fn mapForInsert(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        coords: []const key_mod.NormalizedCoord,
    ) std.mem.Allocator.Error!struct { map: *GlyphMap, created: bool } {
        if (coords.len == 0) return .{ .map = &self.static_entries, .created = false };
        if (self.variable_entries.getPtr(.{ .coords = coords })) |existing| {
            return .{ .map = existing.*, .created = false };
        }
        const owned = try allocator.dupe(key_mod.NormalizedCoord, coords);
        errdefer allocator.free(owned);
        const map = try allocator.create(GlyphMap);
        map.* = .empty;
        errdefer allocator.destroy(map);
        try self.variable_entries.put(allocator, .{ .coords = owned }, map);
        return .{ .map = map, .created = true };
    }

    /// Look up a cached glyph, updating its age serial.
    pub fn get(self: *GlyphAtlas, key: GlyphCacheKey) ?region.AtlasSlot {
        const map = self.mapForCoords(key.var_coords) orelse {
            self.cache_misses += 1;
            return null;
        };
        const entry = map.get(key) orelse {
            self.cache_misses += 1;
            return null;
        };
        entry.serial = self.serial;
        self.cache_hits += 1;
        return entry.atlas_slot;
    }

    /// Allocate atlas space and insert a cache entry.
    ///
    /// Returns `null` when the atlas could not fit the glyph
    /// (`error.OutOfMemory` is propagated so the caller can distinguish OOM
    /// from "atlas full", which upstream's `.ok()?` collapses).
    pub fn insertEntry(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        image_cache: *image_cache_mod.ImageCache,
        key: GlyphCacheKey,
        raster_metrics: region.RasterMetrics,
    ) (std.mem.Allocator.Error || @import("../../common/multi_atlas.zig").AtlasError)!?region.AtlasSlot {
        const padding: u32 = @as(u32, GLYPH_PADDING) * 2;
        const padded_width_wide = @as(u32, raster_metrics.width) + padding;
        const padded_height_wide = @as(u32, raster_metrics.height) + padding;
        const padded_width: u16 = std.math.cast(u16, padded_width_wide) orelse return null;
        const padded_height: u16 = std.math.cast(u16, padded_height_wide) orelse return null;

        const image_id = image_cache.allocate(allocator, padded_width, padded_height, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const resource = image_cache.get(image_id) orelse return null;

        const atlas_slot: region.AtlasSlot = .{
            .image_id = image_id,
            .page_index = resource.atlas_id.asU32(),
            .x = resource.offset[0] + GLYPH_PADDING,
            .y = resource.offset[1] + GLYPH_PADDING,
            .width = raster_metrics.width,
            .height = raster_metrics.height,
            .bearing_x = raster_metrics.bearing_x,
            .bearing_y = raster_metrics.bearing_y,
        };

        const entry = allocator.create(GlyphCacheEntry) catch |err| {
            // Leave the cache unchanged: return the atlas allocation first.
            _ = image_cache.deallocate(allocator, image_id) catch {};
            return err;
        };
        errdefer allocator.destroy(entry);
        entry.* = .{ .atlas_slot = atlas_slot, .serial = self.serial };

        const target = self.mapForInsert(allocator, key.var_coords) catch |err| {
            _ = image_cache.deallocate(allocator, image_id) catch {};
            return err;
        };
        target.map.put(allocator, key, entry) catch |err| {
            if (target.created) {
                const removed = self.variable_entries.fetchRemove(.{ .coords = key.var_coords }).?;
                removed.value.deinit(allocator);
                allocator.destroy(removed.value);
                allocator.free(removed.key.coords);
            }
            _ = image_cache.deallocate(allocator, image_id) catch {};
            return err;
        };
        self.entry_count += 1;
        return atlas_slot;
    }

    /// Insert result: the allocated slot plus the page recorder to append to.
    pub const InsertResult = struct {
        slot: region.AtlasSlot,
        recorder: *commands.AtlasCommandRecorder,
    };

    /// Allocate atlas space, insert a cache entry, and return the page
    /// recorder.
    pub fn insert(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        image_cache: *image_cache_mod.ImageCache,
        key: GlyphCacheKey,
        raster_metrics: region.RasterMetrics,
    ) (std.mem.Allocator.Error || @import("../../common/multi_atlas.zig").AtlasError)!?InsertResult {
        const atlas_slot = (try self.insertEntry(allocator, image_cache, key, raster_metrics)) orelse
            return null;
        const atlas_config = image_cache.atlasManager().config;
        const recorder = try self.recorderForPage(
            allocator,
            atlas_slot.page_index,
            atlas_config.atlas_size[0],
            atlas_config.atlas_size[1],
        );
        return .{ .slot = atlas_slot, .recorder = recorder };
    }

    /// Get (or create) the command recorder for the given atlas page.
    pub fn recorderForPage(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        page_index: u32,
        atlas_width: u16,
        atlas_height: u16,
    ) !*commands.AtlasCommandRecorder {
        const idx: usize = page_index;
        while (self.pending_atlas_commands.items.len <= idx) {
            try self.pending_atlas_commands.append(allocator, null);
        }
        const slot = &self.pending_atlas_commands.items[idx];
        if (slot.* == null) {
            slot.* = commands.AtlasCommandRecorder.init(page_index, atlas_width, atlas_height);
        }
        return &slot.*.?;
    }

    /// Replay all pending atlas command recorders (one per dirty page).
    ///
    /// `context` may be any value with a method
    /// `fn replay(self, recorder: *AtlasCommandRecorder) !void`; it is called
    /// for each non-empty recorder. All pending commands are cleared after
    /// replay, including when `replay` returns an error; only the first error
    /// is returned. Recorder allocations are kept for reuse next frame.
    pub fn replayPendingAtlasCommands(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        context: anytype,
    ) !void {
        var first_error: ?anyerror = null;
        for (self.pending_atlas_commands.items) |*slot| {
            if (slot.*) |*recorder| {
                if (recorder.commands.items.len != 0) {
                    if (first_error == null) {
                        context.replay(recorder) catch |err| {
                            first_error = err;
                        };
                    }
                    recorder.clearCommands(allocator);
                }
            }
        }
        if (first_error) |err| return err;
    }

    /// Borrow the pending bitmap uploads.
    ///
    /// The returned slice stays valid until `clearPendingUploads`; the backend
    /// copies every pixmap into its atlas page first.
    pub fn pendingUploads(self: *const GlyphAtlas) []const PendingBitmapUpload {
        return self.pending_uploads.items;
    }

    /// Queue a bitmap pixmap for later upload. Retains one reference to
    /// `pixmap`; the reference is released by `clearPendingUploads`/`clear`/
    /// `deinit`.
    pub fn pushPendingUpload(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        image_id: paint_mod.ImageId,
        pixmap: shared_mod.Shared(pixmap_mod.Pixmap),
        atlas_slot: region.AtlasSlot,
    ) std.mem.Allocator.Error!void {
        self.pending_uploads.append(allocator, .{
            .image_id = image_id,
            .pixmap = pixmap,
            .atlas_slot = atlas_slot,
        }) catch |err| {
            pixmap.release(allocator);
            return err;
        };
    }

    /// Drop the pending bitmap uploads, keeping their allocation for reuse.
    pub fn clearPendingUploads(self: *GlyphAtlas, allocator: std.mem.Allocator) void {
        for (self.pending_uploads.items) |upload| upload.pixmap.release(allocator);
        self.pending_uploads.clearRetainingCapacity();
    }

    /// Borrow the pending clear rects.
    ///
    /// The returned slice stays valid until the next atlas mutation; consume
    /// it before calling `clearPendingClearRects`. (Upstream returns a
    /// borrowing iterator from `drain`; Zig's `clearRetainingCapacity` poisons
    /// the backing storage in safe builds, so drain and clear are split.)
    pub fn pendingClearRects(self: *const GlyphAtlas) []const PendingClearRect {
        return self.pending_clear_rects.items;
    }

    /// Drop the pending clear rects, keeping their allocation for reuse.
    pub fn clearPendingClearRects(self: *GlyphAtlas) void {
        self.pending_clear_rects.clearRetainingCapacity();
    }

    /// Advance the frame counter and evict old entries when due.
    pub fn maintain(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        image_cache: *image_cache_mod.ImageCache,
    ) !void {
        self.serial += 1;
        const frames_since_eviction = self.serial -% self.last_eviction_serial;
        if (frames_since_eviction < self.eviction_config.eviction_frequency) return;
        self.last_eviction_serial = self.serial;
        try self.evictOldEntries(allocator, image_cache);
    }

    /// Evict entries that haven't been used recently.
    ///
    /// Queues a `PendingClearRect` for every evicted entry. A failed
    /// allocation leaves the affected entries cached (the cache stays
    /// correct; eviction is best-effort by design).
    fn evictOldEntries(
        self: *GlyphAtlas,
        allocator: std.mem.Allocator,
        image_cache: *image_cache_mod.ImageCache,
    ) !void {
        var expired: std.ArrayListUnmanaged(GlyphCacheKey) = .empty;
        defer expired.deinit(allocator);

        var iterator = self.static_entries.iterator();
        while (iterator.next()) |map_entry| {
            const entry = map_entry.value_ptr.*;
            const age = self.serial -% entry.serial;
            if (age > self.eviction_config.max_entry_age) {
                try expired.append(allocator, map_entry.key_ptr.*);
            }
        }
        var outer_iterator = self.variable_entries.iterator();
        while (outer_iterator.next()) |outer| {
            var inner_iterator = outer.value_ptr.*.iterator();
            while (inner_iterator.next()) |map_entry| {
                const entry = map_entry.value_ptr.*;
                const age = self.serial -% entry.serial;
                if (age > self.eviction_config.max_entry_age) {
                    try expired.append(allocator, map_entry.key_ptr.*);
                }
            }
        }

        for (expired.items) |key| {
            const map = self.mapForCoords(key.var_coords) orelse continue;
            const entry = map.get(key) orelse continue;
            try self.pending_clear_rects.ensureUnusedCapacity(allocator, 1);
            _ = image_cache.deallocate(allocator, entry.atlas_slot.image_id) catch {
                // Keep the entry cached when its atlas region cannot be
                // released; the next eviction pass retries.
                continue;
            };
            const slot = entry.atlas_slot;
            _ = map.remove(key);
            self.pending_clear_rects.appendAssumeCapacity(pushClearRectForSlot(slot));
            allocator.destroy(entry);
            self.entry_count -|= 1;
        }

        // Drop second-level maps that became empty, releasing their owned
        // coordinate keys.
        var empty_keys: std.ArrayListUnmanaged(VarKey) = .empty;
        defer empty_keys.deinit(allocator);
        var prune_iterator = self.variable_entries.iterator();
        while (prune_iterator.next()) |outer| {
            if (outer.value_ptr.*.count() == 0) {
                try empty_keys.append(allocator, outer.key_ptr.*);
            }
        }
        for (empty_keys.items) |var_key| {
            const removed = self.variable_entries.fetchRemove(var_key).?;
            removed.value.deinit(allocator);
            allocator.destroy(removed.value);
            allocator.free(removed.key.coords);
        }
    }

    /// Clear all cache entries, pending work queues and statistics.
    ///
    /// Mirrors upstream: atlas allocations inside the shared `ImageCache` are
    /// *not* deallocated here; the `ImageCache` owns that lifetime.
    pub fn clear(self: *GlyphAtlas, allocator: std.mem.Allocator) void {
        var iterator = self.static_entries.iterator();
        while (iterator.next()) |map_entry| allocator.destroy(map_entry.value_ptr.*);
        self.static_entries.clearRetainingCapacity();
        var outer_iterator = self.variable_entries.iterator();
        while (outer_iterator.next()) |outer| {
            const map = outer.value_ptr.*;
            var inner_iterator = map.iterator();
            while (inner_iterator.next()) |map_entry| allocator.destroy(map_entry.value_ptr.*);
            map.deinit(allocator);
            allocator.destroy(map);
            allocator.free(outer.key_ptr.coords);
        }
        self.variable_entries.clearRetainingCapacity();
        self.clearPendingUploads(allocator);
        self.pending_clear_rects.clearRetainingCapacity();
        for (self.pending_atlas_commands.items) |*slot| {
            if (slot.*) |*recorder| recorder.deinit(allocator);
            slot.* = null;
        }
        self.pending_atlas_commands.clearRetainingCapacity();
        self.serial = 0;
        self.last_eviction_serial = 0;
        self.entry_count = 0;
        self.cache_hits = 0;
        self.cache_misses = 0;
    }

    /// Get the number of cached glyphs.
    pub fn len(self: *const GlyphAtlas) usize {
        return self.entry_count;
    }

    /// Returns `true` if the cache contains no entries.
    pub fn isEmpty(self: *const GlyphAtlas) bool {
        return self.entry_count == 0;
    }

    /// Get the number of cache hits since last `clearStats`.
    pub fn cacheHits(self: *const GlyphAtlas) u64 {
        return self.cache_hits;
    }

    /// Get the number of cache misses since last `clearStats`.
    pub fn cacheMisses(self: *const GlyphAtlas) u64 {
        return self.cache_misses;
    }

    /// Reset the hit/miss counters without clearing the cache itself.
    pub fn clearStats(self: *GlyphAtlas) void {
        self.cache_hits = 0;
        self.cache_misses = 0;
    }
};

/// Queue a clear rect covering the full padded region of an evicted slot.
///
/// The slot's `x`/`y` are inset by `GLYPH_PADDING` from the allocation origin,
/// so the padding is subtracted back out here.
fn pushClearRectForSlot(slot: region.AtlasSlot) PendingClearRect {
    return .{
        .page_index = slot.page_index,
        .x = slot.x - GLYPH_PADDING,
        .y = slot.y - GLYPH_PADDING,
        .width = slot.width + 2 * GLYPH_PADDING,
        .height = slot.height + 2 * GLYPH_PADDING,
    };
}

const testing = std.testing;
const peniko = @import("../../peniko/root.zig");

fn testKey(glyph_id: u32) GlyphCacheKey {
    return key_mod.newKey(
        1,
        0,
        glyph_id,
        16.0,
        false,
        0.0,
        peniko.Color.BLACK,
        key_mod.packColor(peniko.Color.BLACK),
        @import("../outline_cache.zig").FontEmbolden{},
        &.{},
    );
}

fn testVarKey(glyph_id: u32, coords: []const i16) GlyphCacheKey {
    return key_mod.newKey(
        1,
        0,
        glyph_id,
        16.0,
        false,
        0.0,
        peniko.Color.BLACK,
        key_mod.packColor(peniko.Color.BLACK),
        @import("../outline_cache.zig").FontEmbolden{},
        coords,
    );
}

fn testCache(allocator: std.mem.Allocator, atlas_size: [2]u16) !image_cache_mod.ImageCache {
    return image_cache_mod.ImageCache.initWithConfig(allocator, .{ .atlas_size = atlas_size });
}

fn testMetrics(width: u16, height: u16) region.RasterMetrics {
    return .{ .width = width, .height = height, .bearing_x = 0, .bearing_y = 0 };
}

test "insert allocates a padded slot and get hits it" {
    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 256, 256 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    const key = testKey(42);
    const result = (try atlas.insert(allocator, &cache, key, testMetrics(4, 6))).?;
    try testing.expectEqual(@as(usize, 1), atlas.len());
    try testing.expectEqual(@as(u64, 0), atlas.cacheHits());
    try testing.expectEqual(@as(u64, 0), atlas.cacheMisses());
    // Slot is inset by GLYPH_PADDING; allocation covers 4+2 x 6+2.
    try testing.expectEqual(GLYPH_PADDING, result.slot.x);
    try testing.expectEqual(GLYPH_PADDING, result.slot.y);
    try testing.expectEqual(@as(u16, 4), result.slot.width);
    try testing.expectEqual(@as(u16, 6), result.slot.height);

    const hit = atlas.get(key).?;
    try testing.expectEqual(result.slot.image_id.asU32(), hit.image_id.asU32());
    try testing.expectEqual(@as(u64, 1), atlas.cacheHits());

    try testing.expect(atlas.get(testKey(43)) == null);
    try testing.expectEqual(@as(u64, 1), atlas.cacheMisses());
}

test "variable coordinates partition the atlas cache" {
    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 256, 256 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    const coords_a = [_]i16{ 0x4000, 0 };
    const coords_b = [_]i16{ -0x4000, 0x2000 };
    const static_result = (try atlas.insert(allocator, &cache, testKey(7), testMetrics(4, 4))).?;
    const a_result = (try atlas.insert(allocator, &cache, testVarKey(7, &coords_a), testMetrics(4, 4))).?;
    const b_result = (try atlas.insert(allocator, &cache, testVarKey(7, &coords_b), testMetrics(4, 4))).?;
    try testing.expectEqual(@as(usize, 3), atlas.len());
    try testing.expectEqual(@as(usize, 2), atlas.variable_entries.count());

    try testing.expectEqual(static_result.slot.image_id.asU32(), atlas.get(testKey(7)).?.image_id.asU32());
    try testing.expectEqual(a_result.slot.image_id.asU32(), atlas.get(testVarKey(7, &coords_a)).?.image_id.asU32());
    try testing.expectEqual(b_result.slot.image_id.asU32(), atlas.get(testVarKey(7, &coords_b)).?.image_id.asU32());
    try testing.expect(atlas.get(testVarKey(7, &.{0})) == null);

    // Eviction frees the nested maps and their owned coordinate keys.
    var i: u32 = 0;
    while (i < 130) : (i += 1) try atlas.maintain(allocator, &cache);
    try testing.expectEqual(@as(usize, 0), atlas.len());
    try testing.expectEqual(@as(usize, 0), atlas.variable_entries.count());
    try testing.expectEqual(@as(usize, 3), atlas.pendingClearRects().len);
}

test "insert returns null when the atlas cannot fit the glyph" {    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 16, 16 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    const too_wide = testMetrics(15, 4);
    try testing.expect((try atlas.insert(allocator, &cache, testKey(1), too_wide)) == null);
    try testing.expectEqual(@as(usize, 0), atlas.len());
}

test "eviction after max age deallocates and queues a clear rect" {
    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 256, 256 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    const key = testKey(7);
    _ = (try atlas.insert(allocator, &cache, key, testMetrics(8, 8))).?;
    try testing.expectEqual(@as(usize, 1), atlas.len());

    // The first maintain starts the serial clock; a prune once the serial has
    // exceeded the age window evicts the entry.
    var i: u32 = 0;
    while (i < 130) : (i += 1) try atlas.maintain(allocator, &cache);
    try testing.expectEqual(@as(usize, 0), atlas.len());
    try testing.expect(atlas.get(key) == null);

    const rects = atlas.pendingClearRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 10), rects[0].width);
    try testing.expectEqual(@as(u16, 10), rects[0].height);
    atlas.clearPendingClearRects();
    try testing.expectEqual(@as(usize, 0), atlas.pendingClearRects().len);
}

test "clear drops entries and command recorders" {
    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 256, 256 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    _ = (try atlas.insert(allocator, &cache, testKey(1), testMetrics(4, 4))).?;
    const recorder = try atlas.recorderForPage(allocator, 0, 256, 256);
    try recorder.setTransform(allocator, @import("../../kurbo/root.zig").Affine.IDENTITY);
    try testing.expectEqual(@as(usize, 1), atlas.pending_atlas_commands.items.len);

    atlas.clear(allocator);
    try testing.expectEqual(@as(usize, 0), atlas.len());
    try testing.expectEqual(@as(usize, 0), atlas.pending_atlas_commands.items.len);
    // The recorded command storage was released; the testing allocator fails
    // the test if any command leaked.
}

test "replay clears commands even when the callback errors" {
    const allocator = testing.allocator;
    var cache = try testCache(allocator, .{ 256, 256 });
    defer cache.deinit(allocator);
    var atlas = GlyphAtlas.init();
    defer atlas.deinit(allocator);

    _ = (try atlas.insert(allocator, &cache, testKey(9), testMetrics(4, 4))).?;
    const recorder = try atlas.recorderForPage(allocator, 0, 256, 256);
    try recorder.setTransform(allocator, @import("../../kurbo/root.zig").Affine.IDENTITY);
    try testing.expectEqual(@as(usize, 1), recorder.commands.items.len);

    const Failing = struct {
        pub fn replay(_: @This(), _: *commands.AtlasCommandRecorder) !void {
            return error.ReplayFailed;
        }
    };
    try testing.expectError(
        error.ReplayFailed,
        atlas.replayPendingAtlasCommands(allocator, Failing{}),
    );
    // Upstream clears every recorder after replay, success or failure.
    try testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
}
