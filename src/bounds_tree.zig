//! Port of gpui/src/bounds_tree.rs: an R-tree variant that assigns z-order to overlapping bounds.
const std = @import("std");
const geometry = @import("geometry.zig");
const testing = std.testing;

/// Maximum children per internal node (R-tree style branching factor).
const max_children = 12;

/// Spatial tree that finds the maximum ordering among intersecting bounds.
pub fn BoundsTree(comptime U: type) type {
    const B = geometry.Bounds(U);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// All nodes stored contiguously for cache efficiency.
        nodes: std.ArrayList(Node) = .empty,
        /// Index of the root node, if any.
        root: ?u32 = null,
        /// Index of the leaf with the highest ordering (for fast-path lookups).
        max_leaf: ?u32 = null,
        /// Reusable stack for tree traversal during insertion.
        insert_path: std.ArrayList(u32) = .empty,
        /// Reusable stack for search operations.
        search_stack: std.ArrayList(u32) = .empty,

        const Node = struct {
            /// Bounding box containing this node and all descendants.
            bounds: B,
            /// Maximum ordering value in this subtree.
            max_order: u32,
            kind: Kind,
        };

        const Kind = union(enum) {
            /// Leaf node holding the ordering assigned to its bounds.
            leaf: u32,
            /// Internal node with children; the child with the highest max_order is kept last.
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

        /// Inserts bounds and returns its assigned ordering: one greater than the maximum
        /// ordering of any existing bounds that intersect the new bounds.
        pub fn insert(self: *Self, new_bounds: B) !u32 {
            const max_intersecting = try self.find_max_ordering(new_bounds);
            const ordering = max_intersecting + 1;

            const new_leaf_idx = try self.insert_leaf(new_bounds, ordering);

            if (self.max_leaf) |old_idx| {
                if (self.nodes.items[old_idx].max_order < ordering) self.max_leaf = new_leaf_idx;
            } else {
                self.max_leaf = new_leaf_idx;
            }

            return ordering;
        }

        /// Finds the maximum ordering among all bounds that intersect the query.
        fn find_max_ordering(self: *Self, query: B) !u32 {
            const root_idx = self.root orelse return 0;

            // Fast path: the max-ordering leaf often intersects.
            if (self.max_leaf) |max_idx| {
                const max_node = &self.nodes.items[max_idx];
                if (query.intersects(max_node.bounds)) return max_node.max_order;
            }

            self.search_stack.clearRetainingCapacity();
            try self.search_stack.append(self.allocator, root_idx);

            var max_found: u32 = 0;
            while (self.search_stack.pop()) |node_idx| {
                const node = &self.nodes.items[node_idx];

                // Pruning: skip if this subtree can't improve the result.
                if (node.max_order <= max_found) continue;
                if (!query.intersects(node.bounds)) continue;

                switch (node.kind) {
                    .leaf => |order| max_found = @max(max_found, order),
                    .internal => |*children| for (children.slice()) |child_idx| {
                        if (self.nodes.items[child_idx].max_order > max_found) {
                            try self.search_stack.append(self.allocator, child_idx);
                        }
                    },
                }
            }

            return max_found;
        }

        /// Inserts a leaf with the given bounds and ordering and returns its index.
        fn insert_leaf(self: *Self, bounds: B, order: u32) !u32 {
            const new_leaf_idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .bounds = bounds,
                .max_order = order,
                .kind = .{ .leaf = order },
            });

            const root_idx = self.root orelse {
                self.root = new_leaf_idx;
                return new_leaf_idx;
            };

            // Root is a leaf: create an internal node holding both.
            if (std.meta.activeTag(self.nodes.items[root_idx].kind) == .leaf) {
                const root_bounds = self.nodes.items[root_idx].bounds;
                const root_order = self.nodes.items[root_idx].max_order;

                var children: NodeChildren = .{};
                // Max-end invariant: the highest-order child goes last.
                if (order > root_order) {
                    children.push(root_idx);
                    children.push(new_leaf_idx);
                } else {
                    children.push(new_leaf_idx);
                    children.push(root_idx);
                }

                const new_root_idx: u32 = @intCast(self.nodes.items.len);
                try self.nodes.append(self.allocator, .{
                    .bounds = root_bounds.@"union"(bounds),
                    .max_order = @max(root_order, order),
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
                    if (order <= node.max_order) {
                        const last = kids.len - 1;
                        std.mem.swap(u32, &kids.indices[last - 1], &kids.indices[last]);
                    }
                    node.bounds = node.bounds.@"union"(bounds);
                    node.max_order = @max(node.max_order, order);
                    break;
                }

                // Node is full: replace the best leaf with a new internal node holding [best_leaf, new_leaf].
                const sibling_bounds = self.nodes.items[best_child_idx].bounds;
                const sibling_order = self.nodes.items[best_child_idx].max_order;

                var new_children: NodeChildren = .{};
                if (order > sibling_order) {
                    new_children.push(best_child_idx);
                    new_children.push(new_leaf_idx);
                } else {
                    new_children.push(new_leaf_idx);
                    new_children.push(best_child_idx);
                }

                const new_internal_idx: u32 = @intCast(self.nodes.items.len);
                const new_internal_max = @max(sibling_order, order);
                try self.nodes.append(self.allocator, .{
                    .bounds = sibling_bounds.@"union"(bounds),
                    .max_order = new_internal_max,
                    .kind = .{ .internal = new_children },
                });

                const parent = &self.nodes.items[current_idx];
                const parent_kids = &parent.kind.internal;
                const children_len = parent_kids.len;
                parent_kids.indices[best_child_pos] = new_internal_idx;
                if (new_internal_max > parent.max_order) {
                    std.mem.swap(u32, &parent_kids.indices[best_child_pos], &parent_kids.indices[children_len - 1]);
                }
                break;
            }

            // Propagate bounds and max_order up the path, deepest node first.
            var updated_child_idx: ?u32 = null;
            var path_pos = self.insert_path.items.len;
            while (path_pos > 0) {
                path_pos -= 1;
                const node_idx = self.insert_path.items[path_pos];
                const node = &self.nodes.items[node_idx];
                node.bounds = node.bounds.@"union"(bounds);

                if (node.max_order < order) {
                    node.max_order = order;

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

    const bounds1 = geometry.bounds(Point(f32){ .x = 0, .y = 0 }, Size(f32){ .width = 10, .height = 10 });
    const bounds2 = geometry.bounds(Point(f32){ .x = 5, .y = 5 }, Size(f32){ .width = 10, .height = 10 });
    const bounds3 = geometry.bounds(Point(f32){ .x = 10, .y = 10 }, Size(f32){ .width = 10, .height = 10 });

    // Overlapping bounds get increasing orders.
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds1));
    try testing.expectEqual(@as(u32, 2), try tree.insert(bounds2));
    try testing.expectEqual(@as(u32, 3), try tree.insert(bounds3));

    // Non-overlapping bounds reuse orders.
    const bounds4 = geometry.bounds(Point(f32){ .x = 20, .y = 20 }, Size(f32){ .width = 10, .height = 10 });
    const bounds5 = geometry.bounds(Point(f32){ .x = 40, .y = 40 }, Size(f32){ .width = 10, .height = 10 });
    const bounds6 = geometry.bounds(Point(f32){ .x = 25, .y = 25 }, Size(f32){ .width = 10, .height = 10 });
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds4));
    try testing.expectEqual(@as(u32, 1), try tree.insert(bounds5));
    try testing.expectEqual(@as(u32, 2), try tree.insert(bounds6));
}

test "clear retains capacity and resets ordering" {
    var tree = BoundsTree(f32).init(testing.allocator);
    defer tree.deinit();

    const unit = geometry.bounds(Point(f32){ .x = 0, .y = 0 }, Size(f32){ .width = 10, .height = 10 });
    try testing.expectEqual(@as(u32, 1), try tree.insert(unit));
    try testing.expectEqual(@as(u32, 2), try tree.insert(unit));
    tree.clear();
    try testing.expectEqual(@as(u32, 1), try tree.insert(unit));
}

test "random iterations match brute force" {
    const max_bounds = 100;
    var seed: u64 = 1;
    while (seed <= 1000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var tree = BoundsTree(f32).init(testing.allocator);
        defer tree.deinit();

        var expected: std.ArrayList(struct { bounds: geometry.Bounds(f32), order: u32 }) = .empty;
        defer expected.deinit(testing.allocator);

        const num_bounds = random.intRangeAtMost(usize, 1, max_bounds);
        for (0..num_bounds) |_| {
            const min_x = -100.0 + random.float(f32) * 200.0;
            const min_y = -100.0 + random.float(f32) * 200.0;
            const width = random.float(f32) * 50.0;
            const height = random.float(f32) * 50.0;
            const bounds = geometry.bounds(Point(f32){ .x = min_x, .y = min_y }, Size(f32){ .width = width, .height = height });

            var expected_order: u32 = 0;
            for (expected.items) |quad| {
                if (quad.bounds.intersects(bounds)) expected_order = @max(expected_order, quad.order);
            }
            expected_order += 1;
            try expected.append(testing.allocator, .{ .bounds = bounds, .order = expected_order });

            try testing.expectEqual(expected_order, try tree.insert(bounds));
        }
    }
}
