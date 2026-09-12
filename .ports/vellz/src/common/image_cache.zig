//! Port of vello_common `image_cache.rs` (Apache-2.0 OR MIT).
//!
//! Image resource caching with multi-atlas allocation: `ImageCache` manages
//! image resources across multiple texture atlases, supporting allocation,
//! deallocation and slot reuse. The glifo glyph atlas (M3 T3) is the intended
//! consumer.
//!
//! # Port adaptations (deliberate divergences)
//!
//! - Upstream's `allocate`/`deallocate` return `Result<_, AtlasError>` with a
//!   diagnostics payload and `unwrap()` the atlas deallocation. Here the
//!   errors are a Zig error set (`error.TextureTooLarge`,
//!   `error.NoSpaceAvailable`, ... from `multi_atlas.zig`).
//! - OOM safety: upstream's `Vec::push` aborts, so it can leave an atlas
//!   allocation behind if the slot vector cannot grow. This port reserves the
//!   slot capacity *before* touching atlas space, and clears the slot only
//!   after the atlas deallocation succeeds, so a failed operation leaves the
//!   cache unchanged.
//! - `get` returns `ImageResource` by value instead of `&ImageResource`
//!   (the value is plain data; a pointer into `slots` would be invalidated by
//!   the next `allocate`).
//! - Determinism: slot ids are the upstream LIFO free-index stack (or the
//!   append index), atlas placement is guillotiere order. No hash maps are
//!   involved at this layer, so ids and offsets are deterministic and match
//!   upstream.

const std = @import("std");
const multi_atlas = @import("multi_atlas.zig");
const paint = @import("paint.zig");

const AllocId = multi_atlas.AllocId;
const AllocationStrategy = multi_atlas.AllocationStrategy;
const AtlasConfig = multi_atlas.AtlasConfig;
const AtlasId = multi_atlas.AtlasId;
const MultiAtlasManager = multi_atlas.MultiAtlasManager;
const ImageId = paint.ImageId;

/// Cache errors: `multi_atlas.AtlasError` plus `error.OutOfMemory`.
pub const Error = std.mem.Allocator.Error || multi_atlas.AtlasError;

/// Represents an image resource for rendering.
pub const ImageResource = struct {
    /// The width of the image.
    width: u16,
    /// The height of the image.
    height: u16,
    /// The Id of the atlas containing this image.
    atlas_id: AtlasId,
    /// The offset of the image within its atlas (does not include padding,
    /// i.e. it points to the position of the first actual top-left pixel).
    offset: [2]u16,
    /// The number of transparent padding pixels around the image in the atlas.
    padding: u16,
    /// The atlas allocation ID for deallocation.
    atlas_alloc_id: AllocId,

    /// Returns the offset as `[2]u16`.
    pub fn offsets(self: ImageResource) [2]u16 {
        return self.offset;
    }

    /// Returns the size as `[2]u16`.
    pub fn size(self: ImageResource) [2]u16 {
        return .{ self.width, self.height };
    }
};

/// Manages image resources for the renderer.
pub const ImageCache = struct {
    /// Multi-atlas manager for handling multiple texture atlases.
    atlas_manager: MultiAtlasManager,
    /// Vector of optional image resources (null = free slot).
    slots: std.ArrayList(?ImageResource) = .empty,
    /// Stack of free indices.
    free_idxs: std.ArrayList(usize) = .empty,

    /// Create a new image cache with custom atlas configuration.
    pub fn initWithConfig(allocator: std.mem.Allocator, config: AtlasConfig) Error!ImageCache {
        return .{ .atlas_manager = try MultiAtlasManager.init(allocator, config) };
    }

    /// Create a new dummy image atlas that is supposed to act as a stub.
    pub fn initDummy(allocator: std.mem.Allocator) Error!ImageCache {
        return initWithConfig(allocator, .{
            .initial_atlas_count = 1,
            .max_atlases = 1,
            .atlas_size = .{ 1, 1 },
            .auto_grow = false,
            .allocation_strategy = .first_fit,
        });
    }

    /// Release every atlas page and slot.
    pub fn deinit(self: *ImageCache, allocator: std.mem.Allocator) void {
        self.atlas_manager.deinit(allocator);
        self.slots.deinit(allocator);
        self.free_idxs.deinit(allocator);
        self.* = undefined;
    }

    /// Get an image resource by its Id.
    ///
    /// Returns the resource by value; null when the id is unknown or its slot
    /// is free.
    pub fn get(self: *const ImageCache, id: ImageId) ?ImageResource {
        const index: usize = id.asU32();
        if (index >= self.slots.items.len) {
            return null;
        }
        return self.slots.items[index];
    }

    /// Allocate an image in the cache, with optional transparent padding.
    pub fn allocate(
        self: *ImageCache,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        padding: u16,
    ) Error!ImageId {
        const doubled_padding = @as(u32, padding) * 2;
        const padded_width_wide = @as(u32, width) + doubled_padding;
        const padded_height_wide = @as(u32, height) + doubled_padding;
        // Upstream returns `AtlasError::TextureTooLarge` carrying the widened
        // dimensions; Zig error sets cannot carry the payload.
        const padded_width: u16 = std.math.cast(u16, padded_width_wide) orelse return error.TextureTooLarge;
        const padded_height: u16 = std.math.cast(u16, padded_height_wide) orelse return error.TextureTooLarge;

        // Reserve the slot before touching atlas space. Upstream pushes the
        // slot after the atlas allocation and aborts on OOM, which would leak
        // the atlas rectangle.
        var reused_idx: ?usize = null;
        if (self.free_idxs.items.len > 0) {
            reused_idx = self.free_idxs.items[self.free_idxs.items.len - 1];
        } else {
            try self.slots.ensureUnusedCapacity(allocator, 1);
        }

        const atlas_alloc = try self.atlas_manager.tryAllocate(allocator, padded_width, padded_height);

        const slot_idx = reused_idx orelse blk: {
            // No free slots, append to vector (placeholder, will be replaced).
            const index = self.slots.items.len;
            self.slots.appendAssumeCapacity(null);
            break :blk index;
        };
        if (reused_idx != null) {
            _ = self.free_idxs.pop();
        }

        const image_id = ImageId.new(@intCast(slot_idx));
        self.slots.items[slot_idx] = .{
            .width = width,
            .height = height,
            .atlas_id = atlas_alloc.atlas_id,
            .offset = .{
                atlas_alloc.allocation.x + padding,
                atlas_alloc.allocation.y + padding,
            },
            .padding = padding,
            .atlas_alloc_id = atlas_alloc.allocation.id,
        };

        return image_id;
    }

    /// Deallocate an image from the cache, returning the image resource if it
    /// existed.
    ///
    /// A stale/unknown id returns null (upstream ignores it). The atlas
    /// deallocation is not `unwrap`ped: `error.OutOfMemory` can propagate
    /// while the cache is unchanged.
    pub fn deallocate(self: *ImageCache, allocator: std.mem.Allocator, id: ImageId) Error!?ImageResource {
        const index: usize = id.asU32();
        if (index >= self.slots.items.len) {
            return null;
        }
        const image_resource = self.slots.items[index] orelse return null;

        const padded_width: u16 = @intCast(@as(u32, image_resource.width) + @as(u32, image_resource.padding) * 2);
        const padded_height: u16 = @intCast(@as(u32, image_resource.height) + @as(u32, image_resource.padding) * 2);

        // Reserve the free-list slot before mutating anything so OOM leaves
        // the cache unchanged.
        try self.free_idxs.ensureUnusedCapacity(allocator, 1);

        // Deallocate from the appropriate atlas.
        try self.atlas_manager.deallocate(
            allocator,
            image_resource.atlas_id,
            image_resource.atlas_alloc_id,
            padded_width,
            padded_height,
        );

        self.slots.items[index] = null;
        self.free_idxs.appendAssumeCapacity(index);
        return image_resource;
    }

    /// Get access to the atlas manager.
    pub fn atlasManager(self: *const ImageCache) *const MultiAtlasManager {
        return &self.atlas_manager;
    }

    /// Get the number of atlases.
    pub fn atlasCount(self: *const ImageCache) usize {
        return self.atlas_manager.atlasCount();
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from image_cache.rs; error-payload matches become
// `expectError` because Zig error sets carry no payload).
// ---------------------------------------------------------------------------

const ATLAS_SIZE: u16 = 1024;

test "insert single image" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    const id = try cache.allocate(allocator, 100, 100, 0);

    try std.testing.expectEqual(@as(u32, 0), id.asU32());
    const resource = cache.get(id).?;
    try std.testing.expectEqual(@as(u16, 100), resource.width);
    try std.testing.expectEqual(@as(u16, 100), resource.height);
    // First image should be at origin.
    try std.testing.expectEqual([2]u16{ 0, 0 }, resource.offset);
}

test "insert single image with padding" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    const id = try cache.allocate(allocator, 100, 100, 4);

    try std.testing.expectEqual(@as(u32, 0), id.asU32());
    const resource = cache.get(id).?;
    try std.testing.expectEqual(@as(u16, 100), resource.width);
    try std.testing.expectEqual(@as(u16, 100), resource.height);
    try std.testing.expectEqual(@as(u16, 4), resource.padding);
    // Offset should be shifted inward by padding.
    try std.testing.expectEqual([2]u16{ 4, 4 }, resource.offset);
}

test "rejects padded dimensions outside u16 atlas domain" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ std.math.maxInt(u16), std.math.maxInt(u16) } });
    defer cache.deinit(allocator);

    try std.testing.expectError(error.TextureTooLarge, cache.allocate(allocator, std.math.maxInt(u16), 100, 1));
}

test "insert multiple images" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    const id1 = try cache.allocate(allocator, 50, 50, 0);
    const id2 = try cache.allocate(allocator, 75, 75, 0);

    try std.testing.expectEqual(@as(u32, 0), id1.asU32());
    try std.testing.expectEqual(@as(u32, 1), id2.asU32());

    const resource1 = cache.get(id1).?;
    const resource2 = cache.get(id2).?;

    try std.testing.expectEqual(@as(u16, 50), resource1.width);
    try std.testing.expectEqual(@as(u16, 75), resource2.width);

    // Second image should be placed adjacent to the first.
    try std.testing.expect(!std.mem.eql(u16, &resource1.offset, &resource2.offset));
}

test "get nonexistent image" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    try std.testing.expect(cache.get(ImageId.new(0)) == null);
    try std.testing.expect(cache.get(ImageId.new(999)) == null);
}

test "remove image" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    const id = try cache.allocate(allocator, 100, 100, 0);
    try std.testing.expect(cache.get(id) != null);

    _ = try cache.deallocate(allocator, id);
    try std.testing.expect(cache.get(id) == null);
}

test "remove nonexistent image" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    // Should not fail when unregistering a non-existent image.
    try std.testing.expect((try cache.deallocate(allocator, ImageId.new(0))) == null);
    try std.testing.expect((try cache.deallocate(allocator, ImageId.new(999))) == null);
}

test "slot reuse after remove" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    // Register three images.
    const id1 = try cache.allocate(allocator, 50, 50, 0);
    const id2 = try cache.allocate(allocator, 60, 60, 0);
    const id3 = try cache.allocate(allocator, 70, 70, 0);

    try std.testing.expectEqual(@as(u32, 0), id1.asU32());
    try std.testing.expectEqual(@as(u32, 1), id2.asU32());
    try std.testing.expectEqual(@as(u32, 2), id3.asU32());

    // Unregister the middle one.
    _ = try cache.deallocate(allocator, id2);
    try std.testing.expect(cache.get(id2) == null);

    // Register a new image - should reuse slot 1.
    const id4 = try cache.allocate(allocator, 80, 80, 0);
    try std.testing.expectEqual(@as(u32, 1), id4.asU32());

    // Verify other images are still there.
    try std.testing.expect(cache.get(id1) != null);
    try std.testing.expect(cache.get(id3) != null);
    try std.testing.expect(cache.get(id4) != null);
    try std.testing.expectEqual(@as(u16, 80), cache.get(id4).?.width);
}

test "multiple remove and reuse" {
    const allocator = std.testing.allocator;
    var cache = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ ATLAS_SIZE, ATLAS_SIZE } });
    defer cache.deinit(allocator);

    // Register several images.
    var ids: [5]ImageId = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try cache.allocate(allocator, @intCast(100 + i * 10), @intCast(100 + i * 10), 0);
    }

    // Unregister some in the middle.
    _ = try cache.deallocate(allocator, ids[1]);
    _ = try cache.deallocate(allocator, ids[3]);

    // Register new images - should reuse the freed slots.
    const new_id1 = try cache.allocate(allocator, 200, 200, 0);
    const new_id2 = try cache.allocate(allocator, 300, 300, 0);

    // Should have reused slots 3 and 1 (in reverse order due to stack behavior).
    try std.testing.expectEqual(@as(u32, 3), new_id1.asU32());
    try std.testing.expectEqual(@as(u32, 1), new_id2.asU32());
    try std.testing.expect(new_id1.asU32() != new_id2.asU32());
}

test "deterministic ids and placement" {
    // Two caches fed the same allocate/deallocate sequence must produce the
    // same slot ids and the same atlas offsets (guillotiere placement order
    // plus the upstream LIFO slot stack).
    const allocator = std.testing.allocator;
    var first = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 256, 256 } });
    defer first.deinit(allocator);
    var second = try ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 256, 256 } });
    defer second.deinit(allocator);

    const ids = [_]u32{ 64, 32, 96, 16, 128 };
    var recorded: [ids.len]ImageResource = undefined;
    for (ids, 0..) |size, i| {
        const first_id = try first.allocate(allocator, @intCast(size), @intCast(size), 0);
        const second_id = try second.allocate(allocator, @intCast(size), @intCast(size), 0);
        try std.testing.expectEqual(first_id.asU32(), second_id.asU32());
        recorded[i] = first.get(first_id).?;

        const second_resource = second.get(second_id).?;
        try std.testing.expectEqual(recorded[i].offset, second_resource.offset);
        try std.testing.expectEqual(recorded[i].atlas_id.asU32(), second_resource.atlas_id.asU32());
    }

    // Free slot 2 in both and reallocate; the reuse id and offset must match.
    _ = try first.deallocate(allocator, ImageId.new(2));
    _ = try second.deallocate(allocator, ImageId.new(2));
    const first_id = try first.allocate(allocator, 24, 24, 2);
    const second_id = try second.allocate(allocator, 24, 24, 2);
    try std.testing.expectEqual(@as(u32, 2), first_id.asU32());
    try std.testing.expectEqual(first.get(first_id).?.offset, second.get(second_id).?.offset);
}
