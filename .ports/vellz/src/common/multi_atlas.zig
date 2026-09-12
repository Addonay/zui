//! Port of vello_common `multi_atlas.rs` (Apache-2.0 OR MIT).
//!
//! Multi-atlas management for texture atlases: a set of fixed-size atlas
//! pages backed by guillotiere's guillotine allocator, with first-fit,
//! best-fit, least-used and round-robin placement strategies plus free-space
//! diagnostics for failed allocations.
//!
//! # Port adaptations (deliberate divergences)
//!
//! - Upstream's `AtlasError` enum embeds diagnostics payloads. Zig error sets
//!   cannot carry payloads, so failures propagate as `error.NoSpaceAvailable`,
//!   `error.AtlasLimitReached`, `error.TextureTooLarge`,
//!   `error.AtlasNotFound` or `error.InvalidAllocationId`, and the payload
//!   (`AtlasSpaceDiagnostics`) is available from `spaceDiagnostics` (upstream's
//!   private `space_diagnostics`, made public for callers and tests).
//! - Upstream creates the initial atlases with `.expect(...)` and asserts
//!   valid sizes/options. This port returns `error.OutOfMemory`/
//!   `error.AtlasLimitReached` instead and keeps the manager usable.
//! - `ImageResource`/`Allocation` ids and placement results are deterministic:
//!   atlases are a `Vec`/`ArrayList` in creation order and guillotiere has no
//!   hash maps. There is no `foldhash` fixed-state iteration involved at this
//!   layer.
//! - `Debug` impls are not ported; `std.testing`/`std.meta` print aggregates.

const std = @import("std");
const guillotiere = @import("guillotiere.zig");

pub const AllocId = guillotiere.AllocId;
const AtlasAllocator = guillotiere.AtlasAllocator;

/// The result of a successful rectangle allocation within a single atlas.
pub const Allocation = struct {
    /// Opaque handle used for deallocation.
    id: AllocId,
    /// X coordinate of the top-left corner of the allocated rectangle.
    x: u16,
    /// Y coordinate of the top-left corner of the allocated rectangle.
    y: u16,
};

/// Unique identifier for an atlas.
pub const AtlasId = struct {
    /// The raw id value; also the atlas's index in the manager.
    value: u32,

    /// Create a new atlas ID.
    pub fn new(id: u32) AtlasId {
        return .{ .value = id };
    }

    /// Get the raw ID value.
    pub fn asU32(self: AtlasId) u32 {
        return self.value;
    }
};

/// Usage statistics for an atlas.
pub const AtlasUsageStats = struct {
    /// Total allocated area in pixels.
    allocated_area: u32,
    /// Total available area in pixels.
    total_area: u32,
    /// Number of allocated images.
    allocated_count: u32,

    /// Calculate usage percentage (0.0 to 1.0).
    pub fn usagePercentage(self: *const AtlasUsageStats) f32 {
        if (self.total_area == 0) {
            return 0.0;
        }
        return @as(f32, @floatFromInt(self.allocated_area)) / @as(f32, @floatFromInt(self.total_area));
    }
};

/// Represents a single atlas in the multi-atlas system.
pub const Atlas = struct {
    /// Unique identifier for this atlas.
    id: AtlasId,
    /// Rectangle allocator backend.
    allocator: AtlasAllocator,
    /// Current usage statistics.
    ///
    /// Exposed directly instead of the upstream `stats()` method (a Zig field
    /// and method cannot share a name).
    stats: AtlasUsageStats,
    /// Allocation counter.
    allocation_counter: u32,

    /// Create a new atlas with the given ID and size.
    pub fn init(
        allocator: std.mem.Allocator,
        id: AtlasId,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!Atlas {
        if (width == 0 or height == 0) {
            return error.InvalidOptions;
        }
        const rectangle_allocator = AtlasAllocator.init(
            allocator,
            guillotiere.size2(width, height),
        ) catch |err| switch (err) {
            // Fixed positive sizes with default options cannot fail the
            // upstream asserts (upstream panics instead).
            error.InvalidOptions => return error.InvalidOptions,
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        return .{
            .id = id,
            .allocator = rectangle_allocator,
            .stats = .{
                .allocated_area = 0,
                .total_area = @as(u32, width) * @as(u32, height),
                .allocated_count = 0,
            },
            .allocation_counter = 0,
        };
    }

    /// Release the atlas's allocator storage.
    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        self.allocator.deinit(allocator);
        self.* = undefined;
    }

    /// Try to allocate an image in this atlas.
    pub fn allocate(
        self: *Atlas,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) std.mem.Allocator.Error!?Allocation {
        const alloc = (try self.allocator.allocate(allocator, guillotiere.size2(width, height))) orelse return null;
        self.stats.allocated_area += @as(u32, width) * @as(u32, height);
        self.stats.allocated_count += 1;
        self.allocation_counter += 1;
        // The atlas was created with u16 dimensions, so the i32 rectangle
        // coordinates always fit in u16 (upstream uses `try_from(...).expect`).
        return .{
            .id = alloc.id,
            .x = @intCast(alloc.rectangle.min.x),
            .y = @intCast(alloc.rectangle.min.y),
        };
    }

    /// Deallocate an image from this atlas.
    ///
    /// `error.InvalidAllocationId` replaces upstream's assert on a stale id;
    /// free-list growth can also fail with `error.OutOfMemory`, in which case
    /// the atlas is unchanged.
    pub fn deallocate(
        self: *Atlas,
        allocator: std.mem.Allocator,
        alloc_id: AllocId,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || error{InvalidAllocationId})!void {
        try self.allocator.deallocate(allocator, alloc_id);
        self.stats.allocated_area -|= @as(u32, width) * @as(u32, height);
        self.stats.allocated_count -|= 1;
    }
};

/// Errors that can occur during atlas operations (upstream `AtlasError`
/// without its embedded diagnostics; see `spaceDiagnostics`).
pub const AtlasError = error{
    /// No space available in any atlas.
    NoSpaceAvailable,
    /// Maximum number of atlases reached.
    AtlasLimitReached,
    /// The requested texture size is too large for any atlas.
    TextureTooLarge,
    /// The specified atlas was not found.
    AtlasNotFound,
    /// The allocation id does not refer to a live allocation.
    InvalidAllocationId,
    /// The atlas size is zero or the initial count exceeds the maximum
    /// (upstream asserts/panics while creating the initial atlases).
    InvalidOptions,
};

/// Result of an atlas allocation attempt.
pub const AtlasAllocation = struct {
    /// The atlas where the allocation was made.
    atlas_id: AtlasId,
    /// The allocation details.
    allocation: Allocation,
};

/// Free-space details for one atlas texture-array layer.
pub const AtlasLayerDiagnostics = struct {
    /// The atlas represented by this layer.
    atlas_id: AtlasId,
    /// The total layer area, in texels.
    total_area: u64,
    /// The total free layer area, in texels.
    free_area: u64,
    /// The number of disjoint free rectangles in the layer.
    free_rectangle_count: usize,
    /// The width of the largest free rectangle by area.
    largest_free_width: u16,
    /// The height of the largest free rectangle by area.
    largest_free_height: u16,

    /// Calculate layer utilization as a percentage from 0 to 100.
    pub fn utilizationPercentage(self: *const AtlasLayerDiagnostics) f64 {
        if (self.total_area == 0) {
            return 0.0;
        }
        return (1.0 - @as(f64, @floatFromInt(self.free_area)) / @as(f64, @floatFromInt(self.total_area))) * 100.0;
    }

    /// Calculate layer fragmentation as a percentage from 0 to 100.
    pub fn fragmentationPercentage(self: *const AtlasLayerDiagnostics) f64 {
        if (self.free_area == 0) {
            return 0.0;
        }
        const largest_free_area = @as(u64, self.largest_free_width) * @as(u64, self.largest_free_height);
        return (1.0 - @as(f64, @floatFromInt(largest_free_area)) / @as(f64, @floatFromInt(self.free_area))) * 100.0;
    }
};

/// Free-space details collected after an atlas allocation fails.
pub const AtlasSpaceDiagnostics = union(enum) {
    /// No allocation context is available.
    unavailable,
    /// Details about the requested allocation and available atlas space.
    allocation: struct {
        /// The requested allocation width.
        width: u16,
        /// The requested allocation height.
        height: u16,
        /// The width shared by all atlas layers.
        atlas_width: u16,
        /// The height shared by all atlas layers.
        atlas_height: u16,
        /// The configured maximum number of atlas layers.
        max_atlases: usize,
        /// Per-layer details for each atlas considered for the allocation.
        atlases: std.ArrayList(AtlasLayerDiagnostics),
    },

    /// Release the per-layer list (no-op for `unavailable`).
    pub fn deinit(self: *AtlasSpaceDiagnostics, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unavailable => {},
            .allocation => self.allocation.atlases.deinit(allocator),
        }
        self.* = .unavailable;
    }
};

/// Configuration for multiple atlas support.
///
/// Note that any values provided here are recommendations and might not be
/// fully honored depending on the capabilities of the backend.
pub const AtlasConfig = struct {
    /// Initial number of atlases to create.
    ///
    /// Set this to zero to allocate the first atlas lazily.
    initial_atlas_count: usize = 0,
    /// Maximum number of atlases to create.
    max_atlases: usize = 8,
    /// Size of each atlas texture (width, height).
    atlas_size: [2]u16 = .{ 4096, 4096 },
    /// Whether to automatically create new atlases when needed.
    auto_grow: bool = true,
    /// Strategy for allocating images across atlases.
    allocation_strategy: AllocationStrategy = .first_fit,
};

/// Strategy for allocating images across multiple atlases.
pub const AllocationStrategy = enum {
    /// Try atlases in order until one has space.
    first_fit,
    /// Choose the atlas with the smallest remaining space that can fit the image.
    best_fit,
    /// Prefer the atlas with the lowest usage percentage.
    least_used,
    /// Cycle through atlases in round-robin fashion.
    round_robin,
};

/// One entry of `atlasStats`; `stats` borrows the manager's atlas.
pub const AtlasStat = struct {
    id: AtlasId,
    stats: *const AtlasUsageStats,
};

/// Manages multiple texture atlases.
pub const MultiAtlasManager = struct {
    /// All atlases managed by this instance.
    atlases: std.ArrayList(Atlas) = .empty,
    /// Configuration for atlas management.
    ///
    /// Exposed directly instead of the upstream `config()` method (a Zig field
    /// and method cannot share a name).
    config: AtlasConfig,
    /// Round-robin counter for allocation strategy.
    round_robin_counter: usize = 0,

    /// Create a new multi-atlas manager with the given configuration.
    ///
    /// Upstream panics when an initial atlas cannot be created; this port
    /// propagates `error.AtlasLimitReached`/`error.OutOfMemory` and leaves no
    /// partial manager behind.
    pub fn init(
        allocator: std.mem.Allocator,
        config: AtlasConfig,
    ) (std.mem.Allocator.Error || AtlasError)!MultiAtlasManager {
        var self = MultiAtlasManager{ .config = config };
        errdefer self.deinit(allocator);

        if (config.atlas_size[0] == 0 or config.atlas_size[1] == 0) {
            return error.InvalidOptions;
        }

        for (0..config.initial_atlas_count) |_| {
            _ = try self.createAtlas(allocator);
        }

        return self;
    }

    /// Release every atlas page.
    pub fn deinit(self: *MultiAtlasManager, allocator: std.mem.Allocator) void {
        for (self.atlases.items) |*atlas| atlas.deinit(allocator);
        self.atlases.deinit(allocator);
        self.* = undefined;
    }

    /// Create a new atlas and return its ID.
    pub fn createAtlas(self: *MultiAtlasManager, allocator: std.mem.Allocator) (std.mem.Allocator.Error || AtlasError)!AtlasId {
        if (self.atlases.items.len >= self.config.max_atlases) {
            return error.AtlasLimitReached;
        }
        if (self.atlases.items.len > std.math.maxInt(u32)) {
            // `AtlasId` cannot address more layers (upstream unwraps the cast).
            return error.AtlasLimitReached;
        }

        const atlas_id = AtlasId.new(self.nextAtlasId());

        var atlas = try Atlas.init(
            allocator,
            atlas_id,
            self.config.atlas_size[0],
            self.config.atlas_size[1],
        );
        errdefer atlas.deinit(allocator);
        try self.atlases.append(allocator, atlas);

        return atlas_id;
    }

    /// Get the next available atlas ID.
    pub fn nextAtlasId(self: *const MultiAtlasManager) u32 {
        return @intCast(self.atlases.items.len);
    }

    /// Try to allocate space for an image with the given dimensions.
    pub fn tryAllocate(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!AtlasAllocation {
        // Check if the image is too large for any atlas.
        if (width > self.config.atlas_size[0] or height > self.config.atlas_size[1]) {
            return error.TextureTooLarge;
        }

        // Try allocation based on strategy.
        return switch (self.config.allocation_strategy) {
            .first_fit => self.allocateFirstFit(allocator, width, height),
            .best_fit => self.allocateBestFit(allocator, width, height),
            .least_used => self.allocateLeastUsed(allocator, width, height),
            .round_robin => self.allocateRoundRobin(allocator, width, height),
        };
    }

    /// Collect free-space diagnostics for a failed allocation attempt.
    ///
    /// Upstream's private `space_diagnostics`, exposed so callers can inspect
    /// the payload that its `AtlasError` variants carry.
    pub fn spaceDiagnostics(
        self: *const MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) std.mem.Allocator.Error!AtlasSpaceDiagnostics {
        var atlases: std.ArrayList(AtlasLayerDiagnostics) = .empty;
        errdefer atlases.deinit(allocator);
        try atlases.ensureTotalCapacity(allocator, self.atlases.items.len);

        for (self.atlases.items) |*atlas| {
            var accum = FreeRectangleAccumulator{};
            atlas.allocator.forEachFreeRectangle(&accum, accumulateFreeRectangle);

            atlases.appendAssumeCapacity(.{
                .atlas_id = atlas.id,
                .total_area = @as(u64, atlas.stats.total_area),
                .free_area = accum.free_area,
                .free_rectangle_count = accum.free_rectangle_count,
                .largest_free_width = accum.largest_free_width,
                .largest_free_height = accum.largest_free_height,
            });
        }

        return .{ .allocation = .{
            .width = width,
            .height = height,
            .atlas_width = self.config.atlas_size[0],
            .atlas_height = self.config.atlas_size[1],
            .max_atlases = self.config.max_atlases,
            .atlases = atlases,
        } };
    }

    /// Allocate using first-fit strategy: try atlases in order until one has space.
    fn allocateFirstFit(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!AtlasAllocation {
        for (self.atlases.items) |*atlas| {
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                return .{ .atlas_id = atlas.id, .allocation = allocation };
            }
        }

        // Try creating a new atlas if auto-grow is enabled.
        if (self.config.auto_grow) {
            const atlas_id = try self.createAtlas(allocator);
            const atlas = &self.atlases.items[self.atlases.items.len - 1];
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                return .{ .atlas_id = atlas_id, .allocation = allocation };
            }
        }

        return error.NoSpaceAvailable;
    }

    /// Allocate using best-fit strategy: choose the atlas with the smallest
    /// remaining space that can fit the image.
    fn allocateBestFit(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!AtlasAllocation {
        var best_atlas_idx: ?usize = null;
        var best_remaining_space: u32 = std.math.maxInt(u32);

        // Find the atlas with the least remaining space that can fit the image.
        for (self.atlases.items, 0..) |*atlas, idx| {
            const stats = &atlas.stats;
            const remaining_space = stats.total_area - stats.allocated_area;

            if (remaining_space >= @as(u32, width) * @as(u32, height) and
                remaining_space < best_remaining_space)
            {
                best_remaining_space = remaining_space;
                best_atlas_idx = idx;
            }
        }

        if (best_atlas_idx) |idx| {
            const atlas = &self.atlases.items[idx];
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                return .{ .atlas_id = atlas.id, .allocation = allocation };
            }
        }

        // Fallback to first-fit if best-fit didn't work.
        return self.allocateFirstFit(allocator, width, height);
    }

    /// Allocate using least-used strategy: prefer the atlas with the lowest
    /// usage percentage.
    fn allocateLeastUsed(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!AtlasAllocation {
        var best_atlas_idx: ?usize = null;
        var lowest_usage: f32 = std.math.floatMax(f32);

        // Find the atlas with the lowest usage percentage.
        for (self.atlases.items, 0..) |*atlas, idx| {
            const usage = atlas.stats.usagePercentage();
            if (usage < lowest_usage) {
                lowest_usage = usage;
                best_atlas_idx = idx;
            }
        }

        if (best_atlas_idx) |idx| {
            const atlas = &self.atlases.items[idx];
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                return .{ .atlas_id = atlas.id, .allocation = allocation };
            }
        }

        // Fallback to first-fit if least-used didn't work.
        return self.allocateFirstFit(allocator, width, height);
    }

    /// Allocate using round-robin strategy: cycle through atlases using a
    /// round-robin counter.
    fn allocateRoundRobin(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!AtlasAllocation {
        if (self.atlases.items.len == 0) {
            return self.allocateFirstFit(allocator, width, height);
        }

        const start_idx = self.round_robin_counter % self.atlases.items.len;

        // Try starting from the round-robin position.
        for (0..self.atlases.items.len) |i| {
            const idx = (start_idx + i) % self.atlases.items.len;

            const atlas = &self.atlases.items[idx];
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                self.round_robin_counter = (idx + 1) % self.atlases.items.len;
                return .{ .atlas_id = atlas.id, .allocation = allocation };
            }
        }

        // Try creating a new atlas if auto-grow is enabled.
        if (self.config.auto_grow) {
            const atlas_id = try self.createAtlas(allocator);
            const atlas = &self.atlases.items[self.atlases.items.len - 1];
            if (try atlas.allocate(allocator, width, height)) |allocation| {
                self.round_robin_counter = self.atlases.items.len - 1;
                return .{ .atlas_id = atlas_id, .allocation = allocation };
            }
        }

        return error.NoSpaceAvailable;
    }

    /// Deallocate space in the specified atlas.
    pub fn deallocate(
        self: *MultiAtlasManager,
        allocator: std.mem.Allocator,
        atlas_id: AtlasId,
        alloc_id: AllocId,
        width: u16,
        height: u16,
    ) (std.mem.Allocator.Error || AtlasError)!void {
        // Since atlases only grow (never deallocate) and id is the index into
        // the atlases vec, we can do a lookup instead of a linear search.
        const idx = atlas_id.asU32();
        if (idx >= self.atlases.items.len) {
            return error.AtlasNotFound;
        }
        try self.atlases.items[idx].deallocate(allocator, alloc_id, width, height);
    }

    /// Get statistics for all atlases as a caller-owned slice.
    ///
    /// The returned `stats` pointers borrow this manager and stay valid until
    /// an atlas is added (`createAtlas`) or the manager is deinitialized.
    pub fn atlasStats(self: *MultiAtlasManager, allocator: std.mem.Allocator) std.mem.Allocator.Error![]AtlasStat {
        const stats = try allocator.alloc(AtlasStat, self.atlases.items.len);
        errdefer allocator.free(stats);
        for (self.atlases.items, 0..) |*atlas, i| {
            stats[i] = .{ .id = atlas.id, .stats = &atlas.stats };
        }
        return stats;
    }

    /// Get the number of atlases.
    pub fn atlasCount(self: *const MultiAtlasManager) usize {
        return self.atlases.items.len;
    }
};

const FreeRectangleAccumulator = struct {
    free_area: u64 = 0,
    free_rectangle_count: usize = 0,
    largest_free_area: u64 = 0,
    largest_free_width: u16 = 0,
    largest_free_height: u16 = 0,
};

fn accumulateFreeRectangle(accum: *FreeRectangleAccumulator, rect: guillotiere.Rectangle) void {
    // Atlas dimensions are u16, so the rectangle extents always fit.
    const rect_width: u16 = @intCast(rect.width());
    const rect_height: u16 = @intCast(rect.height());
    const rect_area = @as(u64, rect_width) * @as(u64, rect_height);
    accum.free_area += rect_area;
    accum.free_rectangle_count += 1;

    if (rect_area > accum.largest_free_area) {
        accum.largest_free_area = rect_area;
        accum.largest_free_width = rect_width;
        accum.largest_free_height = rect_height;
    }
}

// ---------------------------------------------------------------------------
// Tests (ported from multi_atlas.rs; error-payload assertions use
// `spaceDiagnostics` because Zig error sets carry no payload).
// ---------------------------------------------------------------------------

test "atlas creation" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{ .initial_atlas_count = 0 });
    defer manager.deinit(allocator);

    const atlas_id = try manager.createAtlas(allocator);
    try std.testing.expectEqual(@as(u32, 0), atlas_id.asU32());
    try std.testing.expectEqual(@as(usize, 1), manager.atlasCount());
}

test "default lazily creates first atlas" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{});
    defer manager.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), manager.atlasCount());

    const allocation = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation.atlas_id.asU32());
    try std.testing.expectEqual(@as(usize, 1), manager.atlasCount());
}

test "allocation strategies" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 1,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .first_fit,
        .auto_grow = true,
    });
    defer manager.deinit(allocator);

    // Should create atlas automatically.
    const allocation = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation.atlas_id.asU32());
}

test "atlas limit" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 1,
        .max_atlases = 1,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .first_fit,
        .auto_grow = false,
    });
    defer manager.deinit(allocator);

    try std.testing.expectError(error.AtlasLimitReached, manager.createAtlas(allocator));
}

test "no space diagnostics" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 1,
        .max_atlases = 1,
        .atlas_size = .{ 256, 256 },
        .auto_grow = false,
    });
    defer manager.deinit(allocator);
    _ = try manager.tryAllocate(allocator, 128, 256);

    try std.testing.expectError(error.NoSpaceAvailable, manager.tryAllocate(allocator, 129, 256));

    var diagnostics = try manager.spaceDiagnostics(allocator, 129, 256);
    defer diagnostics.deinit(allocator);

    switch (diagnostics) {
        .unavailable => return error.TestUnexpectedResult,
        .allocation => |allocation| {
            try std.testing.expectEqual(@as(u16, 129), allocation.width);
            try std.testing.expectEqual(@as(u16, 256), allocation.height);
            try std.testing.expectEqual(@as(u16, 256), allocation.atlas_width);
            try std.testing.expectEqual(@as(u16, 256), allocation.atlas_height);
            try std.testing.expectEqual(@as(usize, 1), allocation.max_atlases);
            try std.testing.expectEqual(@as(usize, 1), allocation.atlases.items.len);

            const atlas = allocation.atlases.items[0];
            try std.testing.expectEqual(@as(u32, 0), atlas.atlas_id.asU32());
            try std.testing.expectEqual(@as(u64, 65_536), atlas.total_area);
            try std.testing.expectEqual(@as(u64, 32_768), atlas.free_area);
            try std.testing.expectEqual(@as(usize, 1), atlas.free_rectangle_count);
            try std.testing.expectEqual(@as(u16, 128), atlas.largest_free_width);
            try std.testing.expectEqual(@as(u16, 256), atlas.largest_free_height);
            try std.testing.expectEqual(@as(f64, 0.0), atlas.fragmentationPercentage());
        },
    }
}

test "atlas limit diagnostics" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 1,
        .max_atlases = 1,
        .atlas_size = .{ 256, 256 },
        .auto_grow = true,
    });
    defer manager.deinit(allocator);
    _ = try manager.tryAllocate(allocator, 128, 256);

    try std.testing.expectError(error.AtlasLimitReached, manager.tryAllocate(allocator, 129, 256));

    var diagnostics = try manager.spaceDiagnostics(allocator, 129, 256);
    defer diagnostics.deinit(allocator);
    switch (diagnostics) {
        .unavailable => return error.TestUnexpectedResult,
        .allocation => |allocation| {
            try std.testing.expectEqual(@as(usize, 1), allocation.atlases.items.len);
        },
    }
}

test "fragmentation per atlas layer" {
    const atlases = [2]AtlasLayerDiagnostics{
        .{
            .atlas_id = AtlasId.new(0),
            .total_area = 100,
            .free_area = 100,
            .free_rectangle_count = 1,
            .largest_free_width = 10,
            .largest_free_height = 10,
        },
        .{
            .atlas_id = AtlasId.new(1),
            .total_area = 100,
            .free_area = 100,
            .free_rectangle_count = 2,
            .largest_free_width = 5,
            .largest_free_height = 10,
        },
    };

    try std.testing.expectEqual(@as(f64, 0.0), atlases[0].fragmentationPercentage());
    try std.testing.expectEqual(@as(f64, 50.0), atlases[1].fragmentationPercentage());
}

test "texture too large" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{ .atlas_size = .{ 256, 256 } });
    defer manager.deinit(allocator);

    try std.testing.expectError(error.TextureTooLarge, manager.tryAllocate(allocator, 300, 300));
}

test "first fit allocation strategy" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 3,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .first_fit,
        .auto_grow = false,
    });
    defer manager.deinit(allocator);

    // First allocation should go to atlas 0.
    const allocation0 = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation0.atlas_id.asU32());

    // Second allocation should also go to atlas 0 (first fit).
    const allocation1 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 0), allocation1.atlas_id.asU32());

    // Third allocation should still go to atlas 0.
    const allocation2 = try manager.tryAllocate(allocator, 80, 80);
    try std.testing.expectEqual(@as(u32, 0), allocation2.atlas_id.asU32());

    // A large allocation forces it to go to atlas 1.
    const allocation3 = try manager.tryAllocate(allocator, 200, 200);
    try std.testing.expectEqual(@as(u32, 1), allocation3.atlas_id.asU32());

    // Next small allocation should go back to atlas 0 (first fit tries atlas 0 first).
    const allocation4 = try manager.tryAllocate(allocator, 20, 20);
    try std.testing.expectEqual(@as(u32, 0), allocation4.atlas_id.asU32());
}

test "best fit allocation strategy" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 3,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .best_fit,
        .auto_grow = false,
    });
    defer manager.deinit(allocator);

    // All atlases start empty, so first allocation goes to atlas 0 (first available).
    const allocation0 = try manager.tryAllocate(allocator, 150, 150);
    try std.testing.expectEqual(@as(u32, 0), allocation0.atlas_id.asU32());

    // Second allocation should also go to atlas 0 since it still has the least
    // remaining space that can fit the image.
    const allocation1 = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation1.atlas_id.asU32());

    // For a small allocation, atlas 0 still has the least remaining space.
    const allocation2 = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation2.atlas_id.asU32());

    // A large allocation that won't fit in atlas 0's remaining space goes to atlas 1.
    const allocation3 = try manager.tryAllocate(allocator, 200, 200);
    try std.testing.expectEqual(@as(u32, 1), allocation3.atlas_id.asU32());

    // Now atlas 1 has less remaining space; a small allocation goes to atlas 0.
    const allocation4 = try manager.tryAllocate(allocator, 80, 80);
    try std.testing.expectEqual(@as(u32, 0), allocation4.atlas_id.asU32());

    // Atlas 1 has less remaining space but can't fit the allocation; it goes
    // to atlas 2 (best fit - least remaining space).
    const allocation5 = try manager.tryAllocate(allocator, 80, 80);
    try std.testing.expectEqual(@as(u32, 2), allocation5.atlas_id.asU32());
}

test "least used allocation strategy" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 3,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .least_used,
        .auto_grow = false,
    });
    defer manager.deinit(allocator);

    // First allocation goes to atlas 0 (all atlases have 0% usage, picks first).
    const allocation0 = try manager.tryAllocate(allocator, 100, 100);
    try std.testing.expectEqual(@as(u32, 0), allocation0.atlas_id.asU32());

    // Second allocation should go to atlas 1 (least used among remaining).
    const allocation1 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 1), allocation1.atlas_id.asU32());

    // Third allocation should go to atlas 2 (least used).
    const allocation2 = try manager.tryAllocate(allocator, 30, 30);
    try std.testing.expectEqual(@as(u32, 2), allocation2.atlas_id.asU32());

    // Fourth allocation should go to atlas 2 again (still least used).
    const allocation3 = try manager.tryAllocate(allocator, 30, 30);
    try std.testing.expectEqual(@as(u32, 2), allocation3.atlas_id.asU32());
}

test "round robin allocation strategy" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 3,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .round_robin,
        .auto_grow = false,
    });
    defer manager.deinit(allocator);

    // Allocations should cycle through atlases in order.
    const allocation0 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 0), allocation0.atlas_id.asU32());

    const allocation1 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 1), allocation1.atlas_id.asU32());

    const allocation2 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 2), allocation2.atlas_id.asU32());

    // Should wrap back to atlas 0.
    const allocation3 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 0), allocation3.atlas_id.asU32());

    // Continue the cycle.
    const allocation4 = try manager.tryAllocate(allocator, 50, 50);
    try std.testing.expectEqual(@as(u32, 1), allocation4.atlas_id.asU32());
}

test "auto grow" {
    const allocator = std.testing.allocator;
    var manager = try MultiAtlasManager.init(allocator, .{
        .initial_atlas_count = 1,
        .max_atlases = 3,
        .atlas_size = .{ 256, 256 },
        .allocation_strategy = .first_fit,
        .auto_grow = true,
    });
    defer manager.deinit(allocator);

    const allocation0 = try manager.tryAllocate(allocator, 256, 256);
    try std.testing.expectEqual(@as(u32, 0), allocation0.atlas_id.asU32());

    const allocation1 = try manager.tryAllocate(allocator, 256, 256);
    try std.testing.expectEqual(@as(u32, 1), allocation1.atlas_id.asU32());

    const allocation2 = try manager.tryAllocate(allocator, 256, 256);
    try std.testing.expectEqual(@as(u32, 2), allocation2.atlas_id.asU32());
}
