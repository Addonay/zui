//! Port of gpui/src/bounds_tree.rs: an R-tree variant that assigns z-order to overlapping bounds.
const std = @import("std");
const geometry = @import("geometry.zig");
const scene = @import("scene.zig");
const testing = std.testing;

const PrimitiveKind = scene.PrimitiveKind;

/// Maximum children per internal node (R-tree style branching factor).
const max_children = 12;

/// The ordering of a bounds, then its kind, which orders the bounds that share an ordering.
pub const Key = struct {
    ordering: u32,
    kind: PrimitiveKind,

    pub inline fn asU64(self: Key) u64 {
        return (@as(u64, self.ordering) << 32) | @intFromEnum(self.kind);
    }

    pub inline fn lt(a: Key, b: Key) bool {
        return a.asU64() < b.asU64();
    }

    pub inline fn le(a: Key, b: Key) bool {
        return a.asU64() <= b.asU64();
    }

    pub inline fn gt(a: Key, b: Key) bool {
        return a.asU64() > b.asU64();
    }

    pub inline fn max(a: Key, b: Key) Key {
        return if (a.asU64() >= b.asU64()) a else b;
    }
};

/// Spatial tree that finds the maximum key among intersecting bounds.
pub fn BoundsTree(comptime U: type) type {
    const B = geometry.Bounds(U);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// All nodes stored contiguously for cache efficiency.
        nodes: std.ArrayList(Node) = .empty,
        /// Index of the root node, if any.
        root: ?u32 = null,
        /// Index of the leaf with the highest key (for fast-path lookups).
        max_leaf: ?u32 = null,
        /// Reusable stack for tree traversal during insertion.
        insert_path: std.ArrayList(u32) = .empty,
        /// Reusable stack for search operations.
        search_stack: std.ArrayList(u32) = .empty,

        const Node = struct {
            /// Bounding box containing this node and all descendants.
            bounds: B,
            /// Maximum key in this subtree.
            max_key: Key,
            kind: Kind,
        };

        const Kind = union(enum) {
            /// Leaf node holding the key assigned to its bounds.
            leaf: Key,
            /// Internal node with children; the child with the highest max_key is kept last.
            internal: NodeChildren,
        };

        const NodeChildren = struct {
            indices: [max_children]u32 = undefined,
            len: u32 = 0,

            fn push(self: *NodeChildren, index: u32) void {
                std.debug.assert(self.len < max_children);
                self.indices[self.len] = index;
                self.len += 1;
            }

            fn slice(self: *const NodeChildren) []const u32 {
                return self.indices[0..self.len];
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.insert_path.deinit(self.allocator);
            self.search_stack.deinit(self.allocator);
        }

        /// Clears all nodes from the tree, retaining capacity.
        pub fn clear(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.root = null;
            self.max_leaf = null;
            self.insert_path.clearRetainingCapacity();
            self.search_stack.clearRetainingCapacity();
        }

        /// Inserts bounds of the given kind into the tree and returns its assigned ordering.
        ///
        /// The ordering is one greater than the maximum ordering of any existing bounds
        /// that intersect with the new bounds. The new bounds share that maximum ordering
        /// instead if every intersecting bounds there has a kind of at most `max_shared_kind`,
        /// since those are drawn first.
        pub fn insert(self: *Self, new_bounds: B, kind: PrimitiveKind, max_shared_kind: PrimitiveKind) !u32 {
            const ordering = if (try self.find_max_key(new_bounds)) |max_key|
                if (@intFromEnum(max_key.kind) <= @intFromEnum(max_shared_kind)) max_key.ordering else max_key.ordering + 1
            else
                1;
            const key: Key = .{ .ordering = ordering, .kind = kind };

            const new_leaf_idx = try self.insert_leaf(new_bounds, key);

            if (self.max_leaf) |old_idx| {
                if (self.nodes.items[old_idx].max_key.lt(key)) self.max_leaf = new_leaf_idx;
            } else {
                self.max_leaf = new_leaf_idx;
            }

            return ordering;
        }

        /// Finds the maximum key among all bounds that intersect the query.
        fn find_max_key(self: *Self, query: B) !?Key {
            const root_idx = self.root orelse return null;

            // Fast path: the max-key leaf often intersects.
            if (self.max_leaf) |max_idx| {
                const max_node = &self.nodes.items[max_idx];
                if (query.intersects(max_node.bounds)) return max_node.max_key;
            }

            self.search_stack.clearRetainingCapacity();
            try self.search_stack.append(self.allocator, root_idx);

            var max_found: ?Key = null;
            while (self.search_stack.pop()) |node_idx| {
                const node = &self.nodes.items[node_idx];

                // Pruning: skip if this subtree can't improve the result.
                if (max_found) |mf| {
                    if (node.max_key.le(mf)) continue;
                }
                if (!query.intersects(node.bounds)) continue;

                switch (node.kind) {
                    .leaf => |key| max_found = if (max_found) |mf| Key.max(mf, key) else key,
                    .internal => |*children| for (children.slice()) |child_idx| {
                        const child_key = self.nodes.items[child_idx].max_key;
                        if (max_found == null or child_key.gt(max_found.?)) {
                            try self.search_stack.append(self.allocator, child_idx);
                        }
                    },
                }
            }

            return max_found;
        }

        /// Inserts a leaf with the given bounds and key and returns its index.
        fn insert_leaf(self: *Self, bounds: B, key: Key) !u32 {
            const new_leaf_idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .bounds = bounds,
                .max_key = key,
                .kind = .{ .leaf = key },
            });

            const root_idx = self.root orelse {
                self.root = new_leaf_idx;
                return new_leaf_idx;
            };

            // Root is a leaf: create an internal node holding both.
            if (std.meta.activeTag(self.nodes.items[root_idx].kind) == .leaf) {
                const root_bounds = self.nodes.items[root_idx].bounds;
                const root_key = self.nodes.items[root_idx].max_key;

                var children: NodeChildren = .{};
                // Max-end invariant: the highest-key child goes last.
                if (key.gt(root_key)) {
                    children.push(root_idx);
                    children.push(new_leaf_idx);
                } else {
                    children.push(new_leaf_idx);
                    children.push(root_idx);
                }

                const new_root_idx: u32 = @intCast(self.nodes.items.len);
                try self.nodes.append(self.allocator, .{
                    .bounds = root_bounds.@"union"(bounds),
                    .max_key = Key.max(root_key, key),
                    .kind = .{ .internal = children },
                });
                self.root = new_root_idx;
                return new_leaf_idx;
            }

            // Descend to the internal node that best fits the new bounds.
            self.insert_path.clearRetainingCapacity();
            var current_idx = root_idx;

            while (true) {
                const children: *const NodeChildren = switch (self.nodes.items[current_idx].kind) {
                    .internal => |*kids| kids,
                    .leaf => unreachable,
                };
                try self.insert_path.append(self.allocator, current_idx);

                const child_slice = children.slice();
                var best_child_idx = child_slice[0];
                var best_child_pos: usize = 0;
                var best_cost = bounds.@"union"(self.nodes.items[best_child_idx].bounds).half_perimeter();
                for (child_slice[1..], 1..) |child_idx, pos| {
                    const cost = bounds.@"union"(self.nodes.items[child_idx].bounds).half_perimeter();
                    if (cost < best_cost) {
                        best_cost = cost;
                        best_child_idx = child_idx;
                        best_child_pos = pos;
                    }
                }

                if (std.meta.activeTag(self.nodes.items[best_child_idx].kind) != .leaf) {
                    current_idx = best_child_idx;
                    continue;
                }

                if (children.len < max_children) {
                    // Room in this node: add the new leaf directly.
                    const node = &self.nodes.items[current_idx];
                    const kids = &node.kind.internal;
                    kids.push(new_leaf_idx);
                    // Keep the max-end invariant unless the new leaf is the highest.
                    if (key.le(node.max_key)) {
                        const last = kids.len - 1;
                        std.mem.swap(u32, &kids.indices[last - 1], &kids.indices[last]);
                    }
                    node.bounds = node.bounds.@"union"(bounds);
                    node.max_key = Key.max(node.max_key, key);
                    break;
                }

                // Node is full: replace the best leaf with a new internal node holding [best_leaf, new_leaf].
                const sibling_bounds = self.nodes.items[best_child_idx].bounds;
                const sibling_key = self.nodes.items[best_child_idx].max_key;

                var new_children: NodeChildren = .{};
                if (key.gt(sibling_key)) {
                    new_children.push(best_child_idx);
                    new_children.push(new_leaf_idx);
                } else {
                    new_children.push(new_leaf_idx);
                    new_children.push(best_child_idx);
                }

                const new_internal_idx: u32 = @intCast(self.nodes.items.len);
                const new_internal_max = Key.max(sibling_key, key);
                try self.nodes.append(self.allocator, .{
                    .bounds = sibling_bounds.@"union"(bounds),
                    .max_key = new_internal_max,
                    .kind = .{ .internal = new_children },
                });

                const parent = &self.nodes.items[current_idx];
                const parent_kids = &parent.kind.internal;
                const children_len = parent_kids.len;
                parent_kids.indices[best_child_pos] = new_internal_idx;
                if (new_internal_max.gt(parent.max_key)) {
                    std.mem.swap(u32, &parent_kids.indices[best_child_pos], &parent_kids.indices[children_len - 1]);
                }
                break;
            }

            // Propagate bounds and max_key up the path, deepest node first.
            var updated_child_idx: ?u32 = null;
            var path_pos = self.insert_path.items.len;
            while (path_pos > 0) {
                path_pos -= 1;
                const node_idx = self.insert_path.items[path_pos];
                const node = &self.nodes.items[node_idx];
                node.bounds = node.bounds.@"union"(bounds);

                if (node.max_key.lt(key)) {
                    node.max_key = key;

                    // The invariant for the updated child was already handled at its own level.
                    if (updated_child_idx) |child_idx| {
                        const kids = &node.kind.internal;
                        if (std.mem.indexOfScalar(u32, kids.slice(), child_idx)) |pos| {
                            const last = kids.len - 1;
                            if (pos != last) std.mem.swap(u32, &kids.indices[pos], &kids.indices[last]);
                        }
                    }
                }

                updated_child_idx = node_idx;
            }

            return new_leaf_idx;
        }
    };
}

const Point = geometry.Point;
const Size = geometry.Size;

test "insert" {
    var tree = BoundsTree(f32).init(testing.allocator);
    defer tree.deinit();

    const quad = PrimitiveKind.quad;
    const shadow = PrimitiveKind.shadow;
    const bounds1 = geometry.bounds(Point(f32){ .x = 0, .y = 0 }, Size(f32){ .width = 10, .height = 10 });
    const bounds2 = geometry.bounds(Point(f32){ .x = 5, .y = 5 }, Size(f32){ .width = 10, .height = 10 });
    const bounds3 = geometry.bounds(Point(f32){ .x = 10, .y = 10 }, Size(f32){ .width = 10, .height = 10 });

    // Overlapping bounds get increasing orders when max_shared_kind < existing kind.
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds1, quad, shadow));
    try testing.expectEqual(@as(u32, 2), try tree.insert(bounds2, quad, shadow));
    try testing.expectEqual(@as(u32, 3), try tree.insert(bounds3, quad, shadow));

    // Non-overlapping bounds reuse orders.
    const bounds4 = geometry.bounds(Point(f32){ .x = 20, .y = 20 }, Size(f32){ .width = 10, .height = 10 });
    const bounds5 = geometry.bounds(Point(f32){ .x = 40, .y = 40 }, Size(f32){ .width = 10, .height = 10 });
    const bounds6 = geometry.bounds(Point(f32){ .x = 25, .y = 25 }, Size(f32){ .width = 10, .height = 10 });
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds4, quad, shadow));
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds5, quad, shadow));
    try testing.expectEqual(@as(u32, 2), try tree.insert(bounds6, quad, shadow));
}

test "kind-aware order sharing" {
    var tree = BoundsTree(f32).init(testing.allocator);
    defer tree.deinit();

    const full = geometry.bounds(Point(f32){ .x = 0, .y = 0 }, Size(f32){ .width = 20, .height = 20 });
    // Shadow followed by quad (sharing up to quad) -> same order 1.
    try testing.expectEqual(@as(u32, 1), try tree.insert(full, .shadow, .shadow));
    try testing.expectEqual(@as(u32, 1), try tree.insert(full, .quad, .quad));
    // Monochrome sprite (shares up to underline) over quad -> same order 1.
    try testing.expectEqual(@as(u32, 1), try tree.insert(full, .monochrome_sprite, .underline));
    // Quad over monochrome sprite -> bumps to order 2 because monochrome_sprite > quad.
    try testing.expectEqual(@as(u32, 2), try tree.insert(full, .quad, .quad));
}

test "clear retains capacity and resets ordering" {
    var tree = BoundsTree(f32).init(testing.allocator);
    defer tree.deinit();

    const unit = geometry.bounds(Point(f32){ .x = 0, .y = 0 }, Size(f32){ .width = 10, .height = 10 });
    try testing.expectEqual(@as(u32, 1), try tree.insert(unit, .quad, .shadow));
    try testing.expectEqual(@as(u32, 2), try tree.insert(unit, .quad, .shadow));
    tree.clear();
    try testing.expectEqual(@as(u32, 1), try tree.insert(unit, .quad, .shadow));
}

test "random iterations match brute force" {
    const max_bounds = 100;
    const kinds = [_]PrimitiveKind{ .shadow, .quad, .path, .underline, .monochrome_sprite };
    var seed: u64 = 1;
    while (seed <= 1000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var tree = BoundsTree(f32).init(testing.allocator);
        defer tree.deinit();

        var expected: std.ArrayList(struct { bounds: geometry.Bounds(f32), key: Key }) = .empty;
        defer expected.deinit(testing.allocator);

        const num_bounds = random.intRangeAtMost(usize, 1, max_bounds);
        for (0..num_bounds) |_| {
            const min_x = -100.0 + random.float(f32) * 200.0;
            const min_y = -100.0 + random.float(f32) * 200.0;
            const width = random.float(f32) * 50.0;
            const height = random.float(f32) * 50.0;
            const bounds = geometry.bounds(Point(f32){ .x = min_x, .y = min_y }, Size(f32){ .width = width, .height = height });
            const kind = kinds[random.intRangeLessThan(usize, 0, kinds.len)];
            const max_shared_kind = kinds[random.intRangeLessThan(usize, 0, kinds.len)];

            var max_intersecting: ?Key = null;
            for (expected.items) |item| {
                if (item.bounds.intersects(bounds)) {
                    max_intersecting = if (max_intersecting) |m| Key.max(m, item.key) else item.key;
                }
            }
            const expected_order: u32 = if (max_intersecting) |m|
                if (@intFromEnum(m.kind) <= @intFromEnum(max_shared_kind)) m.ordering else m.ordering + 1
            else
                1;
            try expected.append(testing.allocator, .{
                .bounds = bounds,
                .key = .{ .ordering = expected_order, .kind = kind },
            });

            try testing.expectEqual(expected_order, try tree.insert(bounds, kind, max_shared_kind));
        }
    }
}
