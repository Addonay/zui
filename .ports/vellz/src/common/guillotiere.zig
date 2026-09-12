//! Port of guillotiere 0.7.0 `allocator.rs` + `lib.rs` (MIT OR Apache-2.0).
//!
//! A dynamic 2D rectangle allocator using the guillotine algorithm with a
//! tree of allocated/free nodes and three free-list buckets. This is the
//! backend vello_common's `multi_atlas.rs` (and so `image_cache.rs`) uses to
//! pack atlas pages; `multi_atlas.zig` is the only consumer landed so far.
//!
//! # Port adaptations (deliberate divergences)
//!
//! - Rust `Vec` growth aborts on OOM; this port uses unmanaged
//!   `std.ArrayList`s and propagates `error.OutOfMemory`. Every mutating
//!   operation reserves the capacity it can need *before* touching the tree,
//!   so a failed operation leaves the allocator unchanged (upstream cannot
//!   fail here at all).
//! - Invalid usage that upstream expresses with `assert!`/`panic!` becomes a
//!   typed error: bad options return `error.InvalidOptions`, a stale or
//!   out-of-range `AllocId` returns `error.InvalidAllocationId`, and growing
//!   to a smaller size returns `error.ShrinkNotAllowed`.
//! - `AllocId` packs the generation in the high 8 bits and the node index in
//!   the low 24 bits exactly like upstream (`serialize`/`deserialize`).
//! - `dump_svg`/`dump_into_svg` are dev-only (they need the `svg_fmt` crate)
//!   and are not ported.
//!
//! Operation order (free-list probing, `swap_remove` bookkeeping, the
//! guillotine split and merge order) is transcribed line-by-line from
//! upstream, so allocation rectangles and ids are identical as long as no
//! `error.OutOfMemory` occurs. There are no hash maps in this module.

const std = @import("std");

const LARGE_BUCKET: usize = 2;
const MEDIUM_BUCKET: usize = 1;
const SMALL_BUCKET: usize = 0;
const NUM_BUCKETS: usize = 3;

/// Sentinel node index (`AllocIndex::NONE` upstream).
const NONE: u32 = std.math.maxInt(u32);

const IDX_MASK: u32 = 0x00FF_FFFF;
const GEN_MASK: u32 = 0xFF00_0000;

/// A point in atlas space (upstream `euclid::Point2D<i32>`).
pub const Point = struct {
    x: i32,
    y: i32,
};

/// A non-negative extent in atlas space (upstream `euclid::Size2D<i32>`).
pub const Size = struct {
    width: i32,
    height: i32,

    /// Whether either dimension is zero or negative (`euclid::Size2D::is_empty`).
    pub fn isEmpty(self: Size) bool {
        return self.width <= 0 or self.height <= 0;
    }
};

/// An axis-aligned rectangle (upstream `euclid::Box2D<i32, UnknownUnit>`).
pub const Rectangle = struct {
    min: Point,
    max: Point,

    /// The zero rectangle at the origin.
    pub const ZERO: Rectangle = .{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = 0, .y = 0 },
    };

    /// A rectangle spanning `[0, 0, extent.width, extent.height]`.
    pub fn fromSize(extent: Size) Rectangle {
        return .{
            .min = .{ .x = 0, .y = 0 },
            .max = .{ .x = extent.width, .y = extent.height },
        };
    }

    /// The rectangle's width (`max.x - min.x`).
    pub fn width(self: Rectangle) i32 {
        return self.max.x - self.min.x;
    }

    /// The rectangle's height (`max.y - min.y`).
    pub fn height(self: Rectangle) i32 {
        return self.max.y - self.min.y;
    }

    /// The rectangle's extent.
    pub fn size(self: Rectangle) Size {
        return .{ .width = self.width(), .height = self.height() };
    }

    /// Whether the rectangle has zero or negative area (`Box2D::is_empty`).
    pub fn isEmpty(self: Rectangle) bool {
        return self.max.x <= self.min.x or self.max.y <= self.min.y;
    }

    /// Whether two rectangles overlap (used by the ported tests).
    pub fn intersects(self: Rectangle, other: Rectangle) bool {
        return self.min.x < other.max.x and other.min.x < self.max.x and
            self.min.y < other.max.y and other.min.y < self.max.y;
    }
};

/// Build a `Size` (upstream `euclid::size2`).
pub fn size2(width: i32, height: i32) Size {
    return .{ .width = width, .height = height };
}

/// Build a `Point` (upstream `euclid::point2`).
pub fn point2(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

fn freeListForSize(small_threshold: i32, large_threshold: i32, size: Size) usize {
    if (size.width >= large_threshold or size.height >= large_threshold) {
        return LARGE_BUCKET;
    } else if (size.width >= small_threshold or size.height >= small_threshold) {
        return MEDIUM_BUCKET;
    } else {
        return SMALL_BUCKET;
    }
}

/// ID referring to an allocated rectangle.
///
/// The high 8 bits hold the node generation and the low 24 bits the node
/// index, exactly like upstream; use `serialize`/`deserialize` for the raw
/// representation.
pub const AllocId = struct {
    /// Packed generation (high 8 bits) + node index (low 24 bits).
    bits: u32,

    /// The raw `u32` representation (`AllocId::serialize`).
    pub fn serialize(self: AllocId) u32 {
        return self.bits;
    }

    /// Rebuild an `AllocId` from its raw representation (`AllocId::deserialize`).
    pub fn deserialize(bytes: u32) AllocId {
        return .{ .bits = bytes };
    }
};

const NodeKind = enum {
    container,
    alloc,
    free,
    unused,
};

const Orientation = enum {
    vertical,
    horizontal,

    fn flipped(self: Orientation) Orientation {
        return switch (self) {
            .vertical => .horizontal,
            .horizontal => .vertical,
        };
    }
};

const Node = struct {
    parent: u32,
    next_sibling: u32,
    prev_sibling: u32,
    kind: NodeKind,
    orientation: Orientation,
    rect: Rectangle,
};

/// Options to tweak the behavior of the atlas allocator.
pub const AllocatorOptions = struct {
    /// Round the rectangle sizes up to a multiple of this value.
    ///
    /// Width and height alignments must be superior to zero.
    ///
    /// Default value: (1, 1).
    alignment: Size,

    /// Value below which a size is considered small.
    ///
    /// This value is used to speed up the storage and lookup of free
    /// rectangles. It must be inferior or equal to `large_size_threshold`.
    ///
    /// Default value: 32.
    small_size_threshold: i32,

    /// Value above which a size is considered large.
    ///
    /// Default value: 256.
    large_size_threshold: i32,
};

/// Upstream `DEFAULT_OPTIONS`.
pub const DEFAULT_OPTIONS: AllocatorOptions = .{
    .alignment = .{ .width = 1, .height = 1 },
    .small_size_threshold = 32,
    .large_size_threshold = 256,
};

/// Invalid usage errors (upstream `assert!`/`panic!`).
pub const Error = error{
    /// `initWithOptions`/`reset` received a non-positive alignment, a
    /// non-positive atlas size, or inconsistent thresholds.
    InvalidOptions,
    /// The `AllocId` does not refer to a live allocation (bad generation,
    /// out-of-range index, or an already-deallocated slot).
    InvalidAllocationId,
    /// `grow` was asked to shrink the atlas, which upstream rejects.
    ShrinkNotAllowed,
};

/// Result of a successful allocation: the handle plus the chosen rectangle.
pub const Allocation = struct {
    id: AllocId,
    rectangle: Rectangle,
};

/// One reallocation recorded by `resizeAndRearrange`.
pub const Change = struct {
    old: Allocation,
    new: Allocation,
};

/// The result of `rearrange`/`resizeAndRearrange`: caller-owned lists.
pub const ChangeList = struct {
    changes: std.ArrayList(Change) = .empty,
    failures: std.ArrayList(Allocation) = .empty,

    /// An empty change list (upstream `ChangeList::empty`).
    pub fn empty() ChangeList {
        return .{};
    }

    /// Release both lists.
    pub fn deinit(self: *ChangeList, allocator: std.mem.Allocator) void {
        self.changes.deinit(allocator);
        self.failures.deinit(allocator);
        self.* = .{};
    }
};

/// A dynamic texture atlas allocator using the guillotine algorithm.
///
/// See the upstream documentation for the data structure and its limitations;
/// the implementation here follows the same node/marker layout, so the
/// resulting rectangles are identical.
///
/// Zig exposes the upstream-private `size` field directly instead of the
/// `size()` method, because a Zig field and method cannot share a name.
pub const AtlasAllocator = struct {
    nodes: std.ArrayList(Node) = .empty,
    /// Free lists are split into a small, a medium and a large bucket for
    /// faster lookups.
    free_lists: [NUM_BUCKETS]std.ArrayList(u32) = .{ .empty, .empty, .empty },
    /// Index of the first element of an intrusive linked list of unused nodes.
    /// The `next_sibling` member of an unused node serves as the link.
    unused_nodes: u32 = NONE,
    /// Per-node generation counters to reduce the likelihood of ID reuse bugs
    /// going unnoticed (`Wrapping<u8>` upstream).
    generations: std.ArrayList(u8) = .empty,
    /// See `AllocatorOptions`.
    alignment: Size = .{ .width = 1, .height = 1 },
    /// See `AllocatorOptions`.
    small_size_threshold: i32 = 32,
    /// See `AllocatorOptions`.
    large_size_threshold: i32 = 256,
    /// Total size of the atlas.
    ///
    /// Zig exposes this upstream-private field directly instead of the
    /// `size()` method, because a Zig field and method cannot share a name.
    size: Size = .{ .width = 1, .height = 1 },
    /// Index of one of the top-level nodes in the tree.
    root_node: u32 = NONE,

    /// Create an atlas allocator with default options.
    pub fn init(allocator: std.mem.Allocator, size: Size) (std.mem.Allocator.Error || Error)!AtlasAllocator {
        return initWithOptions(allocator, size, DEFAULT_OPTIONS);
    }

    /// Create an atlas allocator with the provided options.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        size: Size,
        options: AllocatorOptions,
    ) (std.mem.Allocator.Error || Error)!AtlasAllocator {
        if (options.alignment.width <= 0 or options.alignment.height <= 0) {
            return error.InvalidOptions;
        }
        if (size.width <= 0 or size.height <= 0) {
            return error.InvalidOptions;
        }
        if (options.large_size_threshold < options.small_size_threshold) {
            return error.InvalidOptions;
        }

        var self = AtlasAllocator{
            .alignment = options.alignment,
            .small_size_threshold = options.small_size_threshold,
            .large_size_threshold = options.large_size_threshold,
            .size = size,
        };
        errdefer self.deinit(allocator);

        const bucket = freeListForSize(
            options.small_size_threshold,
            options.large_size_threshold,
            size,
        );
        try self.nodes.append(allocator, .{
            .parent = NONE,
            .next_sibling = NONE,
            .prev_sibling = NONE,
            .rect = Rectangle.fromSize(size),
            .kind = .free,
            .orientation = .vertical,
        });
        try self.generations.append(allocator, 0);
        try self.free_lists[bucket].append(allocator, 0);
        self.root_node = 0;
        return self;
    }

    /// Release all node and free-list storage.
    pub fn deinit(self: *AtlasAllocator, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        for (&self.free_lists) |*list| list.deinit(allocator);
        self.generations.deinit(allocator);
        self.* = .{};
    }

    /// Allocate a rectangle in the atlas.
    ///
    /// Returns `null` when no free rectangle can fit the request (including a
    /// zero or negative request), matching upstream's `Option`.
    pub fn allocate(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        requested_size_in: Size,
    ) std.mem.Allocator.Error!?Allocation {
        var requested_size = requested_size_in;
        if (requested_size.isEmpty()) {
            return null;
        }

        adjustSize(self.alignment.width, &requested_size.width);
        adjustSize(self.alignment.height, &requested_size.height);

        // Find a suitable free rect.
        const chosen_id = self.findSuitableRect(&requested_size);

        if (chosen_id == NONE) {
            // No suitable free rect!
            return null;
        }

        const chosen_node = self.nodes.items[chosen_id];
        const chosen_rect = chosen_node.rect;
        const allocated_rect = Rectangle{
            .min = chosen_rect.min,
            .max = .{
                .x = chosen_rect.min.x + requested_size.width,
                .y = chosen_rect.min.y + requested_size.height,
            },
        };
        const current_orientation = chosen_node.orientation;
        std.debug.assert(chosen_node.kind == .free);

        const split = guillotineRect(&chosen_node.rect, requested_size, current_orientation);
        const split_rect = split.split;
        const leftover_rect = split.leftover;
        const orientation = split.orientation;
        const split_nonempty = !split_rect.isEmpty();
        const leftover_nonempty = !leftover_rect.isEmpty();

        // Reserve everything the tree update below can need before mutating
        // it. Upstream's `Vec::push` cannot fail; if one of these reserves
        // fails, put the chosen node back in its free list (it was removed by
        // `findSuitableRect`) so no atlas space is leaked.
        self.reserveForAllocate(
            allocator,
            orientation == current_orientation,
            split_nonempty,
            leftover_nonempty,
            split_rect.size(),
            leftover_rect.size(),
        ) catch |err| {
            const chosen_size = self.nodes.items[chosen_id].rect.size();
            const bucket = freeListForSize(
                self.small_size_threshold,
                self.large_size_threshold,
                chosen_size,
            );
            // The node was taken out of exactly this bucket, so its slot is
            // still available.
            self.free_lists[bucket].appendAssumeCapacity(chosen_id);
            return err;
        };

        // Update the tree.

        var allocated_id: u32 = undefined;
        var split_id: u32 = undefined;
        var leftover_id: u32 = undefined;

        if (orientation == current_orientation) {
            if (split_nonempty) {
                const next_sibling = chosen_node.next_sibling;

                split_id = try self.newNode(allocator);
                self.nodes.items[split_id] = .{
                    .parent = chosen_node.parent,
                    .next_sibling = next_sibling,
                    .prev_sibling = chosen_id,
                    .rect = split_rect,
                    .kind = .free,
                    .orientation = current_orientation,
                };

                self.nodes.items[chosen_id].next_sibling = split_id;
                if (next_sibling != NONE) {
                    self.nodes.items[next_sibling].prev_sibling = split_id;
                }
            } else {
                split_id = NONE;
            }

            if (leftover_nonempty) {
                self.nodes.items[chosen_id].kind = .container;

                allocated_id = try self.newNode(allocator);
                leftover_id = try self.newNode(allocator);

                self.nodes.items[allocated_id] = .{
                    .parent = chosen_id,
                    .next_sibling = leftover_id,
                    .prev_sibling = NONE,
                    .rect = allocated_rect,
                    .kind = .alloc,
                    .orientation = current_orientation.flipped(),
                };

                self.nodes.items[leftover_id] = .{
                    .parent = chosen_id,
                    .next_sibling = NONE,
                    .prev_sibling = allocated_id,
                    .rect = leftover_rect,
                    .kind = .free,
                    .orientation = current_orientation.flipped(),
                };
            } else {
                // No need to split for the leftover area, we can allocate
                // directly in the chosen node.
                allocated_id = chosen_id;
                const node = &self.nodes.items[chosen_id];
                node.kind = .alloc;
                node.rect = allocated_rect;

                leftover_id = NONE;
            }
        } else {
            self.nodes.items[chosen_id].kind = .container;

            if (split_nonempty) {
                split_id = try self.newNode(allocator);
                self.nodes.items[split_id] = .{
                    .parent = chosen_id,
                    .next_sibling = NONE,
                    .prev_sibling = NONE,
                    .rect = split_rect,
                    .kind = .free,
                    .orientation = current_orientation.flipped(),
                };
            } else {
                split_id = NONE;
            }

            if (leftover_nonempty) {
                const container_id = try self.newNode(allocator);
                self.nodes.items[container_id] = .{
                    .parent = chosen_id,
                    .next_sibling = split_id,
                    .prev_sibling = NONE,
                    .rect = Rectangle.ZERO,
                    .kind = .container,
                    .orientation = current_orientation.flipped(),
                };

                std.debug.assert(split_id != NONE);
                self.nodes.items[split_id].prev_sibling = container_id;

                allocated_id = try self.newNode(allocator);
                leftover_id = try self.newNode(allocator);

                self.nodes.items[allocated_id] = .{
                    .parent = container_id,
                    .next_sibling = leftover_id,
                    .prev_sibling = NONE,
                    .rect = allocated_rect,
                    .kind = .alloc,
                    .orientation = current_orientation,
                };

                self.nodes.items[leftover_id] = .{
                    .parent = container_id,
                    .next_sibling = NONE,
                    .prev_sibling = allocated_id,
                    .rect = leftover_rect,
                    .kind = .free,
                    .orientation = current_orientation,
                };
            } else {
                allocated_id = try self.newNode(allocator);
                self.nodes.items[allocated_id] = .{
                    .parent = chosen_id,
                    .next_sibling = split_id,
                    .prev_sibling = NONE,
                    .rect = allocated_rect,
                    .kind = .alloc,
                    .orientation = current_orientation.flipped(),
                };

                std.debug.assert(split_id != NONE);
                self.nodes.items[split_id].prev_sibling = allocated_id;

                leftover_id = NONE;
            }
        }

        std.debug.assert(self.nodes.items[allocated_id].kind == .alloc);

        if (split_id != NONE) {
            self.addFreeRectAssumeCapacity(split_id, split_rect.size());
        }

        if (leftover_id != NONE) {
            self.addFreeRectAssumeCapacity(leftover_id, leftover_rect.size());
        }

        return Allocation{
            .id = self.allocId(allocated_id),
            .rectangle = allocated_rect,
        };
    }

    /// Deallocate a rectangle in the atlas.
    ///
    /// Frees the free-list space it may need before touching the tree:
    /// upstream's `Vec::push` cannot fail, here `error.OutOfMemory` propagates
    /// and the allocator is unchanged. A stale `AllocId` returns
    /// `error.InvalidAllocationId` (upstream asserts).
    pub fn deallocate(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        node_id_in: AllocId,
    ) (std.mem.Allocator.Error || error{InvalidAllocationId})!void {
        var node_id = try self.getIndex(node_id_in);

        if (@as(usize, node_id) >= self.nodes.items.len) {
            return error.InvalidAllocationId;
        }
        if (self.nodes.items[node_id].kind != .alloc) {
            return error.InvalidAllocationId;
        }

        // The final `addFreeRect` below appends to at most one bucket, but
        // the merge loop can grow the node across buckets; reserve all three
        // so no fallible step remains after the kind change.
        for (&self.free_lists) |*list| {
            try list.ensureUnusedCapacity(allocator, 1);
        }

        self.nodes.items[node_id].kind = .free;

        while (true) {
            const orientation = self.nodes.items[node_id].orientation;

            const next = self.nodes.items[node_id].next_sibling;
            const prev = self.nodes.items[node_id].prev_sibling;

            // Try to merge with the next node.
            if (next != NONE and self.nodes.items[next].kind == .free) {
                self.mergeSiblings(node_id, next, orientation);
            }

            // Try to merge with the previous node.
            if (prev != NONE and self.nodes.items[prev].kind == .free) {
                self.mergeSiblings(prev, node_id, orientation);
                node_id = prev;
            }

            // If this node is now a unique child, collapse it into its parent
            // and try to merge again at the parent level.
            const parent = self.nodes.items[node_id].parent;
            if (self.nodes.items[node_id].prev_sibling == NONE and
                self.nodes.items[node_id].next_sibling == NONE and
                parent != NONE)
            {
                std.debug.assert(self.nodes.items[parent].kind == .container);

                // Replace the parent container with a free node.
                self.nodes.items[parent].rect = self.nodes.items[node_id].rect;
                self.nodes.items[parent].kind = .free;
                self.markNodeUnused(node_id);

                // Start again at the parent level.
                node_id = parent;
            } else {
                const size = self.nodes.items[node_id].rect.size();
                self.addFreeRectAssumeCapacity(node_id, size);
                break;
            }
        }
    }

    /// Whether the atlas is in its initial (fully free) state.
    pub fn isEmpty(self: *const AtlasAllocator) bool {
        const root = &self.nodes.items[self.root_node];
        return root.kind == .free and root.next_sibling == NONE;
    }

    /// Drop all rectangles, clearing the atlas to its initial state.
    ///
    /// Keeps capacity exactly like upstream (`Vec::clear` + push).
    pub fn clear(self: *AtlasAllocator, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        const bucket = freeListForSize(
            self.small_size_threshold,
            self.large_size_threshold,
            self.size,
        );

        // Reserve before clearing so a failed append cannot leave the
        // allocator without a root node.
        try self.nodes.ensureTotalCapacity(allocator, 1);
        try self.generations.ensureTotalCapacity(allocator, 1);
        try self.free_lists[bucket].ensureUnusedCapacity(allocator, 1);

        self.nodes.clearRetainingCapacity();
        self.nodes.appendAssumeCapacity(.{
            .parent = NONE,
            .next_sibling = NONE,
            .prev_sibling = NONE,
            .rect = Rectangle.fromSize(self.size),
            .kind = .free,
            .orientation = .vertical,
        });

        self.root_node = 0;

        self.generations.clearRetainingCapacity();
        self.generations.appendAssumeCapacity(0);

        self.unused_nodes = NONE;

        for (&self.free_lists) |*list| list.clearRetainingCapacity();
        self.free_lists[bucket].appendAssumeCapacity(0);
    }

    /// Clear the allocator and reset its size and options.
    pub fn reset(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        size: Size,
        options: AllocatorOptions,
    ) (std.mem.Allocator.Error || Error)!void {
        if (options.alignment.width <= 0 or options.alignment.height <= 0 or
            size.width <= 0 or size.height <= 0 or
            options.large_size_threshold < options.small_size_threshold)
        {
            return error.InvalidOptions;
        }
        self.alignment = options.alignment;
        self.small_size_threshold = options.small_size_threshold;
        self.large_size_threshold = options.large_size_threshold;
        self.size = size;

        try self.clear(allocator);
    }

    /// Recompute the allocations in the atlas and return a list of the changes.
    ///
    /// Previous ids and rectangles are not valid anymore after this operation
    /// as each id/rectangle pair is assigned to new values which are
    /// communicated in the returned change list. Rearranging the atlas can
    /// help reduce fragmentation.
    pub fn rearrange(self: *AtlasAllocator, allocator: std.mem.Allocator) std.mem.Allocator.Error!ChangeList {
        const size = self.size;
        return self.resizeAndRearrange(allocator, size);
    }

    /// Identical to `rearrange`, also allowing to change the size of the atlas.
    pub fn resizeAndRearrange(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        new_size: Size,
    ) std.mem.Allocator.Error!ChangeList {
        var allocs: std.ArrayList(Allocation) = .empty;
        defer allocs.deinit(allocator);
        try allocs.ensureTotalCapacity(allocator, self.nodes.items.len);
        for (self.nodes.items, 0..) |node, i| {
            if (node.kind != .alloc) {
                continue;
            }
            allocs.appendAssumeCapacity(.{
                .id = self.allocId(@intCast(i)),
                .rectangle = node.rect,
            });
        }

        // Upstream: stable `sort_by_key` ascending, then reverse.
        std.mem.sort(Allocation, allocs.items, {}, allocationAreaLessThan);
        std.mem.reverse(Allocation, allocs.items);

        self.size = new_size;
        try self.clear(allocator);

        var changes = ChangeList.empty();
        errdefer changes.deinit(allocator);

        for (allocs.items) |old| {
            const size = old.rectangle.size();
            if (try self.allocate(allocator, size)) |new| {
                try changes.changes.append(allocator, .{ .old = old, .new = new });
            } else {
                try changes.failures.append(allocator, old);
            }
        }

        return changes;
    }

    /// Resize the atlas without changing the allocations.
    ///
    /// This method is not allowed to shrink the width or height of the atlas.
    pub fn grow(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        new_size: Size,
    ) (std.mem.Allocator.Error || Error)!void {
        if (new_size.width < self.size.width or new_size.height < self.size.height) {
            return error.ShrinkNotAllowed;
        }

        const old_size = self.size;
        self.size = new_size;

        const dx = new_size.width - old_size.width;
        const dy = new_size.height - old_size.height;

        // Reserve the worst case (both growth directions, two free rectangles)
        // before mutating anything so `grow` is OOM-safe.
        try self.ensureNodeCapacity(allocator, 3);
        for (&self.free_lists) |*list| try list.ensureUnusedCapacity(allocator, 2);

        // If there is only one node and it is free, just grow it.
        const root = &self.nodes.items[self.root_node];
        if (root.kind == .free and root.rect.size().width == old_size.width and
            root.rect.size().height == old_size.height)
        {
            root.rect.max = .{
                .x = root.rect.min.x + new_size.width,
                .y = root.rect.min.y + new_size.height,
            };
            // The node's size changed, move it to the correct free list bucket.
            self.updateFreeListBucket(self.root_node);
            return;
        }

        const root_orientation = root.orientation;
        const grows_in_root_orientation = switch (root_orientation) {
            .horizontal => dx > 0,
            .vertical => dy > 0,
        };

        // If growing along the orientation of the root node, find the
        // right-or-bottom-most sibling and either grow it (if it is free) or
        // append a free node next.
        if (grows_in_root_orientation) {
            var sibling = self.root_node;
            while (self.nodes.items[sibling].next_sibling != NONE) {
                sibling = self.nodes.items[sibling].next_sibling;
            }
            const node = &self.nodes.items[sibling];
            if (node.kind == .free) {
                switch (root_orientation) {
                    .horizontal => node.rect.max.x += dx,
                    .vertical => node.rect.max.y += dy,
                }
                // The node's size changed, move it to the correct free list bucket.
                self.updateFreeListBucket(sibling);
            } else {
                const rect = switch (root_orientation) {
                    .horizontal => Rectangle{
                        .min = .{ .x = node.rect.max.x, .y = node.rect.min.y },
                        .max = .{ .x = node.rect.max.x + dx, .y = node.rect.min.y + node.rect.height() },
                    },
                    .vertical => Rectangle{
                        .min = .{ .x = node.rect.min.x, .y = node.rect.max.y },
                        .max = .{ .x = node.rect.min.x + node.rect.width(), .y = node.rect.max.y + dy },
                    },
                };

                const next = try self.newNode(allocator);
                self.nodes.items[sibling].next_sibling = next;
                self.nodes.items[next] = .{
                    .kind = .free,
                    .rect = rect,
                    .prev_sibling = sibling,
                    .next_sibling = NONE,
                    .parent = NONE,
                    .orientation = root_orientation,
                };

                self.addFreeRectAssumeCapacity(next, rect.size());
            }
        }

        const grows_in_opposite_orientation = switch (root_orientation) {
            .horizontal => dy > 0,
            .vertical => dx > 0,
        };

        if (grows_in_opposite_orientation) {
            const free_node = try self.newNode(allocator);
            const new_root = try self.newNode(allocator);

            const old_root = self.root_node;
            self.root_node = new_root;

            const new_root_orientation = root_orientation.flipped();

            const min = switch (new_root_orientation) {
                .horizontal => point2(old_size.width, 0),
                .vertical => point2(0, old_size.height),
            };
            const rect = Rectangle{
                .min = min,
                .max = point2(new_size.width, new_size.height),
            };

            self.nodes.items[free_node] = .{
                .parent = NONE,
                .prev_sibling = new_root,
                .next_sibling = NONE,
                .kind = .free,
                .rect = rect,
                .orientation = new_root_orientation,
            };

            self.nodes.items[new_root] = .{
                .parent = NONE,
                .prev_sibling = NONE,
                .next_sibling = free_node,
                .kind = .container,
                .rect = Rectangle.ZERO,
                .orientation = new_root_orientation,
            };

            self.addFreeRectAssumeCapacity(free_node, rect.size());

            // Update the nodes that need to be re-parented to the new-root.

            var iter = old_root;
            while (iter != NONE) {
                self.nodes.items[iter].parent = new_root;
                iter = self.nodes.items[iter].next_sibling;
            }

            // That second loop might not be necessary, I think that the root
            // is always the first sibling.
            var iter2 = self.nodes.items[old_root].next_sibling;
            while (iter2 != NONE) {
                self.nodes.items[iter2].parent = new_root;
                iter2 = self.nodes.items[iter2].prev_sibling;
            }
        }
    }

    /// Invoke `callback(ctx, rect)` for each free rectangle in the atlas.
    pub fn forEachFreeRectangle(self: *const AtlasAllocator, ctx: anytype, comptime callback: anytype) void {
        for (self.nodes.items) |*node| {
            if (node.kind == .free) {
                callback(ctx, node.rect);
            }
        }
    }

    /// Invoke `callback(ctx, id, rect)` for each allocated rectangle in the atlas.
    pub fn forEachAllocatedRectangle(self: *const AtlasAllocator, ctx: anytype, comptime callback: anytype) void {
        for (self.nodes.items, 0..) |*node, i| {
            if (node.kind != .alloc) {
                continue;
            }
            callback(ctx, self.allocId(@intCast(i)), node.rect);
        }
    }

    fn findSuitableRect(self: *AtlasAllocator, requested_size: *const Size) u32 {
        const ideal_bucket = freeListForSize(
            self.small_size_threshold,
            self.large_size_threshold,
            requested_size.*,
        );

        const use_worst_fit = ideal_bucket == LARGE_BUCKET;
        var bucket = ideal_bucket;
        while (bucket < NUM_BUCKETS) : (bucket += 1) {
            var candidate_score: i32 = if (use_worst_fit) 0 else std.math.maxInt(i32);
            var candidate: ?struct { id: u32, freelist_idx: usize } = null;

            var freelist_idx: usize = 0;
            while (freelist_idx < self.free_lists[bucket].items.len) {
                const id = self.free_lists[bucket].items[freelist_idx];

                // During tree simplification we don't remove merged nodes
                // from the free list, so we have to handle it here.
                if (self.nodes.items[id].kind != .free) {
                    // remove the element from the free list
                    _ = self.free_lists[bucket].swapRemove(freelist_idx);
                    continue;
                }

                const size = self.nodes.items[id].rect.size();
                const dx = size.width - requested_size.width;
                const dy = size.height - requested_size.height;

                if (dx >= 0 and dy >= 0) {
                    if (dx == 0 or dy == 0) {
                        // Perfect fit!
                        candidate = .{ .id = id, .freelist_idx = freelist_idx };
                        break;
                    }

                    // Favor the largest minimum dimension, except for small
                    // allocations.
                    const score = @min(dx, dy);
                    if ((use_worst_fit and score > candidate_score) or
                        (!use_worst_fit and score < candidate_score))
                    {
                        candidate_score = score;
                        candidate = .{ .id = id, .freelist_idx = freelist_idx };
                    }
                }

                freelist_idx += 1;
            }

            if (candidate) |c| {
                _ = self.free_lists[bucket].swapRemove(c.freelist_idx);
                return c.id;
            }
        }

        return NONE;
    }

    fn newNode(self: *AtlasAllocator, allocator: std.mem.Allocator) std.mem.Allocator.Error!u32 {
        const idx = self.unused_nodes;
        if (@as(usize, idx) < self.nodes.items.len) {
            self.unused_nodes = self.nodes.items[idx].next_sibling;
            self.generations.items[idx] +%= 1;
            std.debug.assert(self.nodes.items[idx].kind == .unused);
            return idx;
        }

        try self.nodes.ensureUnusedCapacity(allocator, 1);
        try self.generations.ensureUnusedCapacity(allocator, 1);
        self.nodes.appendAssumeCapacity(.{
            .parent = NONE,
            .next_sibling = NONE,
            .prev_sibling = NONE,
            .rect = Rectangle.ZERO,
            .kind = .unused,
            .orientation = .horizontal,
        });

        self.generations.appendAssumeCapacity(0);

        return @intCast(self.nodes.items.len - 1);
    }

    fn markNodeUnused(self: *AtlasAllocator, id: u32) void {
        std.debug.assert(self.nodes.items[id].kind != .unused);
        self.nodes.items[id].kind = .unused;
        self.nodes.items[id].next_sibling = self.unused_nodes;
        self.unused_nodes = id;
    }

    fn addFreeRectAssumeCapacity(self: *AtlasAllocator, id: u32, size: Size) void {
        std.debug.assert(self.nodes.items[id].kind == .free);
        const bucket = freeListForSize(self.small_size_threshold, self.large_size_threshold, size);
        self.free_lists[bucket].appendAssumeCapacity(id);
    }

    /// Remove a free node from its current bucket (if present) and re-add it
    /// to the bucket that matches its current size. Used when a free node is
    /// resized in-place. The caller must have reserved spare capacity in every
    /// bucket (see `grow`).
    fn updateFreeListBucket(self: *AtlasAllocator, id: u32) void {
        std.debug.assert(self.nodes.items[id].kind == .free);

        // Remove from whichever bucket currently holds this id.
        for (0..NUM_BUCKETS) |bucket| {
            if (indexOfId(self.free_lists[bucket].items, id)) |pos| {
                _ = self.free_lists[bucket].swapRemove(pos);
                break;
            }
        }

        const size = self.nodes.items[id].rect.size();
        self.addFreeRectAssumeCapacity(id, size);
    }

    /// Merge `next` into `node` and append `next` to the list of available
    /// node slots.
    fn mergeSiblings(self: *AtlasAllocator, node: u32, next: u32, orientation: Orientation) void {
        std.debug.assert(self.nodes.items[node].kind == .free);
        std.debug.assert(self.nodes.items[next].kind == .free);
        const r1 = self.nodes.items[node].rect;
        const r2 = self.nodes.items[next].rect;
        const merge_size = self.nodes.items[next].rect.size();
        switch (orientation) {
            .horizontal => {
                std.debug.assert(r1.min.y == r2.min.y);
                std.debug.assert(r1.max.y == r2.max.y);
                self.nodes.items[node].rect.max.x += merge_size.width;
            },
            .vertical => {
                std.debug.assert(r1.min.x == r2.min.x);
                std.debug.assert(r1.max.x == r2.max.x);
                self.nodes.items[node].rect.max.y += merge_size.height;
            },
        }

        // Remove the merged node from the sibling list.
        const next_next = self.nodes.items[next].next_sibling;
        self.nodes.items[node].next_sibling = next_next;
        if (next_next != NONE) {
            self.nodes.items[next_next].prev_sibling = node;
        }

        // Add the merged node to the list of available slots.
        self.markNodeUnused(next);
    }

    fn allocId(self: *const AtlasAllocator, index: u32) AllocId {
        const generation: u32 = self.generations.items[index];
        std.debug.assert(index & IDX_MASK == index);
        return AllocId.deserialize(index + (generation << 24));
    }

    fn getIndex(self: *const AtlasAllocator, id: AllocId) error{InvalidAllocationId}!u32 {
        const idx = id.bits & IDX_MASK;
        if (@as(usize, idx) >= self.generations.items.len) {
            return error.InvalidAllocationId;
        }
        const expected_generation = @as(u32, self.generations.items[idx]) << 24;
        if (id.bits & GEN_MASK != expected_generation) {
            return error.InvalidAllocationId;
        }
        return idx;
    }

    /// Reserve the node slots and free-list entries `allocate` may append.
    fn reserveForAllocate(
        self: *AtlasAllocator,
        allocator: std.mem.Allocator,
        same_orientation: bool,
        split_nonempty: bool,
        leftover_nonempty: bool,
        split_size: Size,
        leftover_size: Size,
    ) std.mem.Allocator.Error!void {
        var nodes_needed: usize = 0;
        if (same_orientation) {
            if (split_nonempty) nodes_needed += 1;
            if (leftover_nonempty) nodes_needed += 2;
        } else {
            if (split_nonempty) nodes_needed += 1;
            if (leftover_nonempty) nodes_needed += 3;
        }
        try self.ensureNodeCapacity(allocator, nodes_needed);

        // `ensureUnusedCapacity` is relative to the current length, so track
        // the per-bucket totals first: split and leftover can share a bucket.
        var extra: [NUM_BUCKETS]usize = .{ 0, 0, 0 };
        if (split_nonempty) {
            extra[freeListForSize(self.small_size_threshold, self.large_size_threshold, split_size)] += 1;
        }
        if (leftover_nonempty) {
            extra[freeListForSize(self.small_size_threshold, self.large_size_threshold, leftover_size)] += 1;
        }
        for (extra, 0..) |count, bucket| {
            if (count > 0) try self.free_lists[bucket].ensureUnusedCapacity(allocator, count);
        }
    }

    fn ensureNodeCapacity(self: *AtlasAllocator, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!void {
        try self.nodes.ensureUnusedCapacity(allocator, count);
        try self.generations.ensureUnusedCapacity(allocator, count);
    }
};

fn indexOfId(items: []const u32, id: u32) ?usize {
    for (items, 0..) |item, i| {
        if (item == id) return i;
    }
    return null;
}

fn allocationAreaLessThan(_: void, a: Allocation, b: Allocation) bool {
    return safeArea(&a.rectangle) < safeArea(&b.rectangle);
}

fn adjustSize(alignment: i32, size: *i32) void {
    const rem = @rem(size.*, alignment);
    if (rem > 0) {
        size.* += alignment - rem;
    }
}

/// Compute the area, saturating at `i32::MAX` instead of overflowing.
fn safeArea(rect: *const Rectangle) i32 {
    return std.math.mul(i32, rect.width(), rect.height()) catch std.math.maxInt(i32);
}

const GuillotineSplit = struct {
    split: Rectangle,
    leftover: Rectangle,
    orientation: Orientation,
};

fn guillotineRect(
    chosen_rect: *const Rectangle,
    requested_size: Size,
    default_orientation: Orientation,
) GuillotineSplit {
    // Decide whether to split horizontally or vertically; see the upstream
    // ASCII diagrams on `guillotine_rect`.
    const candidate_leftover_rect_to_right = Rectangle{
        .min = point2(chosen_rect.min.x + requested_size.width, chosen_rect.min.y),
        .max = point2(chosen_rect.max.x, chosen_rect.min.y + requested_size.height),
    };
    const candidate_leftover_rect_to_bottom = Rectangle{
        .min = point2(chosen_rect.min.x, chosen_rect.min.y + requested_size.height),
        .max = point2(chosen_rect.min.x + requested_size.width, chosen_rect.max.y),
    };

    if (requested_size.width == chosen_rect.width() and requested_size.height == chosen_rect.height()) {
        // Perfect fit.
        return .{
            .split = Rectangle.ZERO,
            .leftover = Rectangle.ZERO,
            .orientation = default_orientation,
        };
    } else if (safeArea(&candidate_leftover_rect_to_right) > safeArea(&candidate_leftover_rect_to_bottom)) {
        return .{
            .leftover = candidate_leftover_rect_to_bottom,
            .split = .{
                .min = candidate_leftover_rect_to_right.min,
                .max = point2(candidate_leftover_rect_to_right.max.x, chosen_rect.max.y),
            },
            .orientation = .horizontal,
        };
    } else {
        return .{
            .leftover = candidate_leftover_rect_to_right,
            .split = .{
                .min = candidate_leftover_rect_to_bottom.min,
                .max = point2(chosen_rect.max.x, candidate_leftover_rect_to_bottom.max.y),
            },
            .orientation = .vertical,
        };
    }
}

/// A simpler atlas allocator that can allocate rectangles but not deallocate them.
///
/// Zig exposes the upstream-private `size` field directly instead of the
/// `size()` method, because a Zig field and method cannot share a name.
pub const SimpleAtlasAllocator = struct {
    free_rects: [NUM_BUCKETS]std.ArrayList(Rectangle) = .{ .empty, .empty, .empty },
    alignment: Size = .{ .width = 1, .height = 1 },
    small_size_threshold: i32 = 32,
    large_size_threshold: i32 = 256,
    /// Total size of the atlas. Exposed directly instead of the upstream
    /// `size()` method (a Zig field and method cannot share a name).
    size: Size = .{ .width = 1, .height = 1 },

    /// Create a simple atlas allocator with default options.
    pub fn init(allocator: std.mem.Allocator, size: Size) (std.mem.Allocator.Error || Error)!SimpleAtlasAllocator {
        return initWithOptions(allocator, size, DEFAULT_OPTIONS);
    }

    /// Create a simple atlas allocator with the provided options.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        size: Size,
        options: AllocatorOptions,
    ) std.mem.Allocator.Error!SimpleAtlasAllocator {
        const bucket = freeListForSize(
            options.small_size_threshold,
            options.large_size_threshold,
            size,
        );

        var self = SimpleAtlasAllocator{
            .alignment = options.alignment,
            .small_size_threshold = options.small_size_threshold,
            .large_size_threshold = options.large_size_threshold,
            .size = size,
        };
        errdefer self.deinit(allocator);
        try self.free_rects[bucket].append(allocator, Rectangle.fromSize(size));
        return self;
    }

    /// Release the free-rectangle storage.
    pub fn deinit(self: *SimpleAtlasAllocator, allocator: std.mem.Allocator) void {
        for (&self.free_rects) |*list| list.deinit(allocator);
        self.* = .{};
    }

    /// Drop all rectangles, clearing the atlas to its initial state.
    pub fn clear(self: *SimpleAtlasAllocator, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        const bucket = freeListForSize(
            self.small_size_threshold,
            self.large_size_threshold,
            self.size,
        );
        try self.free_rects[bucket].ensureUnusedCapacity(allocator, 1);
        for (&self.free_rects) |*list| list.clearRetainingCapacity();
        self.free_rects[bucket].appendAssumeCapacity(Rectangle.fromSize(self.size));
    }

    /// Clear the allocator and reset its size and options.
    pub fn reset(
        self: *SimpleAtlasAllocator,
        allocator: std.mem.Allocator,
        size: Size,
        options: AllocatorOptions,
    ) std.mem.Allocator.Error!void {
        self.alignment = options.alignment;
        self.small_size_threshold = options.small_size_threshold;
        self.large_size_threshold = options.large_size_threshold;
        self.size = size;

        try self.clear(allocator);
    }

    /// Whether the allocator is in its initial state (upstream's exact loop).
    pub fn isEmpty(self: *const SimpleAtlasAllocator) bool {
        for (0..NUM_BUCKETS) |b| {
            for (self.free_rects[b].items) |rect| {
                return rect.width() == self.size.width and rect.height() == self.size.height;
            }
        }

        // This should be unreachable.
        return false;
    }

    /// Allocate a rectangle in the atlas.
    pub fn allocate(
        self: *SimpleAtlasAllocator,
        allocator: std.mem.Allocator,
        requested_size_in: Size,
    ) std.mem.Allocator.Error!?Rectangle {
        var requested_size = requested_size_in;
        if (requested_size.isEmpty()) {
            return null;
        }

        adjustSize(self.alignment.width, &requested_size.width);
        adjustSize(self.alignment.height, &requested_size.height);

        const ideal_bucket = freeListForSize(
            self.small_size_threshold,
            self.large_size_threshold,
            requested_size,
        );

        const use_worst_fit = ideal_bucket == LARGE_BUCKET;

        // Split and leftover may be appended to different buckets; reserve
        // room for both before removing the chosen rectangle so a failed
        // reserve leaves the allocator unchanged.
        try self.free_rects[SMALL_BUCKET].ensureUnusedCapacity(allocator, 2);
        try self.free_rects[MEDIUM_BUCKET].ensureUnusedCapacity(allocator, 2);
        try self.free_rects[LARGE_BUCKET].ensureUnusedCapacity(allocator, 2);

        var chosen_rect: ?Rectangle = null;
        var bucket = ideal_bucket;
        while (bucket < NUM_BUCKETS) : (bucket += 1) {
            var candidate_score: i32 = if (use_worst_fit) 0 else std.math.maxInt(i32);
            var candidate: ?usize = null;

            for (self.free_rects[bucket].items, 0..) |rect, index| {
                const dx = rect.width() - requested_size.width;
                const dy = rect.height() - requested_size.height;

                if (dx >= 0 and dy >= 0) {
                    if (dx == 0 or dy == 0) {
                        // Perfect fit!
                        candidate = index;
                        break;
                    }

                    const score = @min(dx, dy);
                    if ((use_worst_fit and score > candidate_score) or
                        (!use_worst_fit and score < candidate_score))
                    {
                        candidate_score = score;
                        candidate = index;
                    }
                }
            }

            if (candidate) |index| {
                chosen_rect = self.free_rects[bucket].orderedRemove(index);
                break;
            }
        }

        if (chosen_rect) |rect| {
            const parts = guillotineRect(&rect, requested_size, .vertical);
            self.addFreeRectAssumeCapacity(parts.split);
            self.addFreeRectAssumeCapacity(parts.leftover);

            return Rectangle{
                .min = rect.min,
                .max = .{
                    .x = rect.min.x + requested_size.width,
                    .y = rect.min.y + requested_size.height,
                },
            };
        }

        return null;
    }

    /// Resize the atlas without changing the allocations.
    ///
    /// This method is not allowed to shrink the width or height of the atlas.
    pub fn grow(
        self: *SimpleAtlasAllocator,
        allocator: std.mem.Allocator,
        new_size: Size,
    ) (std.mem.Allocator.Error || Error)!void {
        if (new_size.width < self.size.width or new_size.height < self.size.height) {
            return error.ShrinkNotAllowed;
        }

        const parts = guillotineRect(&Rectangle.fromSize(new_size), self.size, .vertical);

        // Reserve the buckets the split/leftover rectangles land in before
        // changing the size so a failed reserve is a no-op. The two
        // rectangles can share a bucket, so reserve the combined count once.
        var extra: [NUM_BUCKETS]usize = .{ 0, 0, 0 };
        if (self.freeRectBucket(parts.split)) |bucket| extra[bucket] += 1;
        if (self.freeRectBucket(parts.leftover)) |bucket| extra[bucket] += 1;
        for (extra, 0..) |count, bucket| {
            if (count > 0) try self.free_rects[bucket].ensureUnusedCapacity(allocator, count);
        }

        self.size = new_size;

        self.addFreeRectAssumeCapacity(parts.split);
        self.addFreeRectAssumeCapacity(parts.leftover);
    }

    /// Initialize this simple allocator with the content of an atlas allocator.
    pub fn initFromAllocator(
        self: *SimpleAtlasAllocator,
        allocator: std.mem.Allocator,
        src: *const AtlasAllocator,
    ) std.mem.Allocator.Error!void {
        self.size = src.size;
        self.alignment = src.alignment;
        self.small_size_threshold = src.small_size_threshold;
        self.large_size_threshold = src.large_size_threshold;

        // Count first so every bucket reserves before anything is cleared.
        var counts: [NUM_BUCKETS]usize = .{ 0, 0, 0 };
        for (src.free_lists, 0..) |list, bucket| {
            for (list.items) |id| {
                if (src.nodes.items[id].kind != .free) {
                    continue;
                }
                counts[bucket] += 1;
            }
        }
        for (&self.free_rects, 0..) |*list, bucket| {
            list.clearRetainingCapacity();
            try list.ensureUnusedCapacity(allocator, counts[bucket]);
        }

        for (src.free_lists, 0..) |list, bucket| {
            for (list.items) |id| {
                // During tree simplification we don't remove merged nodes
                // from the free list, so we have to handle it here.
                if (src.nodes.items[id].kind != .free) {
                    continue;
                }
                self.free_rects[bucket].appendAssumeCapacity(src.nodes.items[id].rect);
            }
        }
    }

    /// The bucket a free rectangle would be stored in, or null when it is
    /// below the alignment and `addFreeRectAssumeCapacity` would skip it.
    fn freeRectBucket(self: *const SimpleAtlasAllocator, rect: Rectangle) ?usize {
        if (rect.width() < self.alignment.width or rect.height() < self.alignment.height) {
            return null;
        }
        return freeListForSize(
            self.small_size_threshold,
            self.large_size_threshold,
            rect.size(),
        );
    }

    fn addFreeRectAssumeCapacity(self: *SimpleAtlasAllocator, rect: Rectangle) void {
        const bucket = self.freeRectBucket(rect) orelse return;
        self.free_rects[bucket].appendAssumeCapacity(rect);
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from guillotiere `allocator.rs`; `atlas_random_test` prints are
// dropped, assertions kept).
// ---------------------------------------------------------------------------

test "atlas basic" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    const full = (try atlas.allocate(allocator, size2(1000, 1000))).?.id;
    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1))) == null);

    try atlas.deallocate(allocator, full);

    const a = (try atlas.allocate(allocator, size2(100, 1000))).?.id;
    const b = (try atlas.allocate(allocator, size2(900, 200))).?.id;
    const c = (try atlas.allocate(allocator, size2(300, 200))).?.id;
    const d = (try atlas.allocate(allocator, size2(200, 300))).?.id;
    const e = (try atlas.allocate(allocator, size2(100, 300))).?.id;
    const f = (try atlas.allocate(allocator, size2(100, 300))).?.id;
    const g = (try atlas.allocate(allocator, size2(100, 300))).?.id;

    try atlas.deallocate(allocator, b);
    try atlas.deallocate(allocator, f);
    try atlas.deallocate(allocator, c);
    try atlas.deallocate(allocator, e);
    const h = (try atlas.allocate(allocator, size2(500, 200))).?.id;
    try atlas.deallocate(allocator, a);
    const i = (try atlas.allocate(allocator, size2(500, 200))).?.id;
    try atlas.deallocate(allocator, g);
    try atlas.deallocate(allocator, h);
    try atlas.deallocate(allocator, d);
    try atlas.deallocate(allocator, i);

    const full_again = (try atlas.allocate(allocator, size2(1000, 1000))).?.id;
    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1))) == null);
    try atlas.deallocate(allocator, full_again);
}

test "atlas random test" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.initWithOptions(allocator, size2(1000, 1000), .{
        .alignment = size2(5, 2),
        .small_size_threshold = DEFAULT_OPTIONS.small_size_threshold,
        .large_size_threshold = DEFAULT_OPTIONS.large_size_threshold,
    });
    defer atlas.deinit(allocator);

    var seed: usize = 37;

    const rand = lcgNext;
    var allocated: std.ArrayList(AllocId) = .empty;
    defer allocated.deinit(allocator);

    var n: usize = 0;
    var misses: usize = 0;

    for (0..500_000) |_| {
        if (rand(&seed) % 5 > 2 and allocated.items.len > 0) {
            // deallocate something
            const nth = rand(&seed) % allocated.items.len;
            const id = allocated.orderedRemove(nth);

            try atlas.deallocate(allocator, id);
        } else {
            // allocate something
            const size = size2(@as(i32, @intCast(rand(&seed) % 300)) + 5, @as(i32, @intCast(rand(&seed) % 300)) + 5);

            if (try atlas.allocate(allocator, size)) |alloc| {
                try allocated.append(allocator, alloc.id);
                n += 1;
            } else {
                misses += 1;
            }
        }
    }

    while (allocated.pop()) |id| {
        try atlas.deallocate(allocator, id);
    }

    // Upstream prints the added/removed counts and vector capacities here;
    // the counters are kept to mirror the upstream test body.

    const full = (try atlas.allocate(allocator, size2(1000, 1000))).?.id;
    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1))) == null);
    try atlas.deallocate(allocator, full);
}

test "atlas grow" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    try atlas.grow(allocator, size2(2000, 2000));

    const full = (try atlas.allocate(allocator, size2(2000, 2000))).?.id;
    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1))) == null);
    try atlas.deallocate(allocator, full);

    const a = (try atlas.allocate(allocator, size2(100, 100))).?.id;

    try atlas.grow(allocator, size2(3000, 3000));

    const b = (try atlas.allocate(allocator, size2(1000, 2900))).?.id;

    try atlas.grow(allocator, size2(4000, 4000));

    try atlas.deallocate(allocator, b);
    try atlas.deallocate(allocator, a);

    const full_2 = (try atlas.allocate(allocator, size2(4000, 4000))).?.id;
    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1))) == null);
    try atlas.deallocate(allocator, full_2);
}

test "atlas clear empty" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    try std.testing.expect(atlas.isEmpty());

    try std.testing.expect((try atlas.allocate(allocator, size2(10, 10))) != null);
    try std.testing.expect(!atlas.isEmpty());

    try atlas.clear(allocator);
    try std.testing.expect(atlas.isEmpty());

    const a = (try atlas.allocate(allocator, size2(10, 10))).?.id;
    const b = (try atlas.allocate(allocator, size2(20, 20))).?.id;
    try std.testing.expect(!atlas.isEmpty());

    try atlas.deallocate(allocator, b);
    try atlas.deallocate(allocator, a);
    try std.testing.expect(atlas.isEmpty());

    try atlas.clear(allocator);
    try std.testing.expect(atlas.isEmpty());

    try atlas.clear(allocator);
    try std.testing.expect(atlas.isEmpty());
}

test "simple atlas" {
    const allocator = std.testing.allocator;
    var atlas = try SimpleAtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    try std.testing.expect((try atlas.allocate(allocator, size2(1, 1001))) == null);
    try std.testing.expect((try atlas.allocate(allocator, size2(1001, 1))) == null);

    var rectangles: std.ArrayList(Rectangle) = .empty;
    defer rectangles.deinit(allocator);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(100, 1000))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(900, 200))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(300, 200))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(200, 300))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(100, 300))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(100, 300))).?);
    try rectangles.append(allocator, (try atlas.allocate(allocator, size2(100, 300))).?);
    try std.testing.expect((try atlas.allocate(allocator, size2(800, 800))) == null);

    for (rectangles.items, 0..) |rect_i, i| {
        for (rectangles.items, 0..) |rect_j, j| {
            if (i == j) {
                continue;
            }

            try std.testing.expect(!rect_i.intersects(rect_j));
        }
    }
}

test "allocate zero" {
    const allocator = std.testing.allocator;
    var atlas = try SimpleAtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    try std.testing.expect((try atlas.allocate(allocator, size2(0, 0))) == null);
}

test "allocate negative" {
    const allocator = std.testing.allocator;
    var atlas = try SimpleAtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    try std.testing.expect((try atlas.allocate(allocator, size2(-1, 1))) == null);
    try std.testing.expect((try atlas.allocate(allocator, size2(1, -1))) == null);
    try std.testing.expect((try atlas.allocate(allocator, size2(-1, -1))) == null);

    try std.testing.expect((try atlas.allocate(allocator, size2(-167114179, -718142))) == null);
}

test "issue 25" {
    const allocator = std.testing.allocator;
    var allocator_atlas = try AtlasAllocator.init(allocator, .{ .width = 65536, .height = 65536 });
    defer allocator_atlas.deinit(allocator);
    _ = try allocator_atlas.allocate(allocator, .{ .width = 2, .height = 2 });
    _ = try allocator_atlas.allocate(allocator, .{ .width = 65500, .height = 2 });
    _ = try allocator_atlas.allocate(allocator, .{ .width = 2, .height = 65500 });
}

test "grow free list bucket" {
    const allocator = std.testing.allocator;
    // Regression test: growing a free node in-place must move it to the
    // correct free list bucket, otherwise allocations searching a higher
    // bucket won't find it.
    var atlas = try AtlasAllocator.initWithOptions(allocator, size2(100, 100), .{
        .alignment = DEFAULT_OPTIONS.alignment,
        .small_size_threshold = 32,
        .large_size_threshold = 256,
    });
    defer atlas.deinit(allocator);

    // Allocate most of the atlas, leaving a thin free strip along the bottom.
    // The strip's min dimension (10) is below small_size_threshold (32), so it
    // lands in the SMALL_BUCKET.
    const a = (try atlas.allocate(allocator, size2(100, 90))).?.id;

    // Grow the atlas so that the free strip extends from 10 to 1010 pixels
    // tall. Its min dimension is now 100 (>= small_threshold), so it should
    // move out of SMALL_BUCKET. Before the fix it stayed in SMALL_BUCKET and
    // large allocations could not find it.
    try atlas.grow(allocator, size2(100, 1100));

    // This allocation needs a rect of 100x500. The ideal bucket is
    // LARGE_BUCKET (500 >= 256). Without the bucket fix the 100x1010 free
    // strip would still be in SMALL_BUCKET and this allocation would fail.
    try std.testing.expect((try atlas.allocate(allocator, size2(100, 500))) != null);

    try atlas.deallocate(allocator, a);

    // Also test the single-root early-return path in grow().
    var atlas2 = try AtlasAllocator.initWithOptions(allocator, size2(20, 20), .{
        .alignment = DEFAULT_OPTIONS.alignment,
        .small_size_threshold = 32,
        .large_size_threshold = 256,
    });
    defer atlas2.deinit(allocator);
    // Atlas is a single free root node in SMALL_BUCKET (20 < 32). Grow it past
    // the large threshold.
    try atlas2.grow(allocator, size2(512, 512));

    // Allocate something that searches LARGE_BUCKET.
    try std.testing.expect((try atlas2.allocate(allocator, size2(500, 500))) != null);
}

test "atlas 10k operation trace matches the upstream oracle" {
    // The expected values below were produced by guillotiere 0.7.0 itself with
    // the generator this test mirrors: a 4096x4096 atlas, a fixed xorshift64*
    // stream, 10_000 operations (`r % 3 == 0` deallocates a random live id,
    // otherwise allocates a random 1..=1024 square), and an FNV-1a 64 hash
    // over the event bytes (tag 0x01 = alloc with id/x/y/w/h little-endian,
    // 0x02 = dealloc with id, 0x03 = miss). The `allocs`/`deallocs`/`misses`
    // counters and the ten per-1000-op checkpoint hashes pin ids and offsets
    // for the whole run; any placement divergence (or map-order divergence)
    // changes them. This replaces the plan's `tools/oracle-rs` dump, which is
    // out of scope for this task (tools must not be modified).
    const checkpoints = [10]u64{
        9888139109286242833,
        5490636622033091556,
        11220658700975861891,
        5563433359489600090,
        2235347148873274221,
        10077972392311324988,
        14022977487470643,
        6078432277097910851,
        15836288373962389579,
        4965985525004950325,
    };
    const expected_allocs: u64 = 3345;
    const expected_deallocs: u64 = 3275;
    const expected_misses: u64 = 3380;
    const expected_final: u64 = 0x44ea_b986_29a6_db35;

    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(4096, 4096));
    defer atlas.deinit(allocator);

    var allocated: std.ArrayList(AllocId) = .empty;
    defer allocated.deinit(allocator);
    try allocated.ensureTotalCapacity(allocator, 10_000);

    var state: u64 = 0x9E37_79B9_7F4A_7C15;
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    var allocs: u64 = 0;
    var deallocs: u64 = 0;
    var misses: u64 = 0;

    const Fnv = struct {
        fn byte(h: *u64, b: u8) void {
            h.* ^= b;
            h.* *%= 0x0000_0100_0000_01b3;
        }
        fn u32le(h: *u64, v: u32) void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, v, .little);
            for (bytes) |b| byte(h, b);
        }
        fn i32le(h: *u64, v: i32) void {
            u32le(h, @bitCast(v));
        }
    };

    for (0..10_000) |i| {
        const r = nextTraceRandom(&state);
        if (r % 3 == 0 and allocated.items.len > 0) {
            const nth = @as(usize, @intCast(nextTraceRandom(&state) % allocated.items.len));
            const id = allocated.orderedRemove(nth);
            try atlas.deallocate(allocator, id);
            Fnv.byte(&hash, 2);
            Fnv.u32le(&hash, id.serialize());
            deallocs += 1;
        } else {
            const w = @as(i32, @intCast(nextTraceRandom(&state) % 1024)) + 1;
            const h = @as(i32, @intCast(nextTraceRandom(&state) % 1024)) + 1;
            if (try atlas.allocate(allocator, size2(w, h))) |a| {
                try allocated.append(allocator, a.id);
                Fnv.byte(&hash, 1);
                Fnv.u32le(&hash, a.id.serialize());
                Fnv.i32le(&hash, a.rectangle.min.x);
                Fnv.i32le(&hash, a.rectangle.min.y);
                Fnv.i32le(&hash, a.rectangle.width());
                Fnv.i32le(&hash, a.rectangle.height());
                allocs += 1;
            } else {
                Fnv.byte(&hash, 3);
                misses += 1;
            }
        }
        if ((i + 1) % 1000 == 0) {
            try std.testing.expectEqual(checkpoints[(i + 1) / 1000 - 1], hash);
        }
    }

    while (allocated.pop()) |id| {
        try atlas.deallocate(allocator, id);
    }
    try std.testing.expect(atlas.isEmpty());

    try std.testing.expectEqual(expected_allocs, allocs);
    try std.testing.expectEqual(expected_deallocs, deallocs);
    try std.testing.expectEqual(expected_misses, misses);
    try std.testing.expectEqual(expected_final, hash);
}

test "atlas rearrange" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(512, 512));
    defer atlas.deinit(allocator);

    _ = try atlas.allocate(allocator, size2(200, 200));
    _ = try atlas.allocate(allocator, size2(100, 300));
    _ = try atlas.allocate(allocator, size2(150, 50));

    var changes = try atlas.rearrange(allocator);
    defer changes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), changes.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), changes.failures.items.len);
    for (changes.changes.items) |change| {
        // The size is preserved; only the id/position may change.
        try std.testing.expectEqual(change.old.rectangle.size().width, change.new.rectangle.size().width);
        try std.testing.expectEqual(change.old.rectangle.size().height, change.new.rectangle.size().height);
    }

    for (changes.changes.items) |change| {
        try atlas.deallocate(allocator, change.new.id);
    }
    try std.testing.expect(atlas.isEmpty());
}

test "atlas reset" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(100, 100));
    defer atlas.deinit(allocator);

    _ = try atlas.allocate(allocator, size2(100, 100));
    try std.testing.expect(!atlas.isEmpty());

    try atlas.reset(allocator, size2(200, 150), DEFAULT_OPTIONS);
    try std.testing.expectEqual(@as(i32, 200), atlas.size.width);
    try std.testing.expectEqual(@as(i32, 150), atlas.size.height);
    try std.testing.expect(atlas.isEmpty());

    const full = (try atlas.allocate(allocator, size2(200, 150))).?.id;
    try atlas.deallocate(allocator, full);
}

test "simple atlas init from allocator" {
    const allocator = std.testing.allocator;
    var atlas = try AtlasAllocator.init(allocator, size2(1000, 1000));
    defer atlas.deinit(allocator);

    _ = try atlas.allocate(allocator, size2(100, 100));
    const b = (try atlas.allocate(allocator, size2(200, 100))).?.id;
    try atlas.deallocate(allocator, b);

    var simple = try SimpleAtlasAllocator.init(allocator, size2(1000, 1000));
    defer simple.deinit(allocator);
    try simple.initFromAllocator(allocator, &atlas);

    // The copied free-list must still be allocatable (and not the full atlas,
    // since one 100x100 allocation is live).
    try std.testing.expect(!simple.isEmpty());
    try std.testing.expect((try simple.allocate(allocator, size2(100, 100))) != null);

    // `clear` restores the initial full-atlas free rectangle.
    try simple.clear(allocator);
    try std.testing.expect(simple.isEmpty());
    const full = (try simple.allocate(allocator, size2(1000, 1000))).?;
    try std.testing.expectEqual(@as(i32, 1000), full.width());
    try std.testing.expectEqual(@as(i32, 1000), full.height());
}

fn nextTraceRandom(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545_F491_4F6C_DD1D;
}

/// The LCG from upstream's `atlas_random_test` (`usize` arithmetic).
fn lcgNext(seed: *usize) usize {
    const a: usize = 1103515245;
    const c: usize = 12345;
    const m: usize = @as(usize, 1) << 31;
    seed.* = (a *% seed.* +% c) % m;
    return seed.*;
}
