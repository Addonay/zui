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

    pub inline fn fromU64(raw: u64) Key {
        return .{
            .ordering = @truncate(raw >> 32),
            .kind = @enumFromInt(@as(u32, @truncate(raw))),
        };
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
    const Vec4 = @Vector(4, U);
    const Mask4 = @Vector(4, bool);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Internal nodes stored contiguously with inline SoA child bounds and keys.
        internals: std.ArrayList(InternalNode) = .empty,
        root: Root = .empty,
        /// Bounds and key of the leaf with the highest key (for fast-path lookups).
        max_leaf_key: ?Key = null,
        max_leaf_bounds: B = undefined,
        /// Reusable path stack for tree traversal during insertion.
        insert_path: std.ArrayList(PathStep) = .empty,
        /// Reusable stack of internal node indices for search operations.
        search_stack: std.ArrayList(u32) = .empty,

        const Root = union(enum) {
            empty,
            leaf: struct { bounds: B, key: Key },
            internal: u32,
        };

        const PathStep = struct {
            node_idx: u32,
            child_pos: u16,
        };

        const InternalNode = struct {
            /// Bounding box containing this node and all descendants.
            bounds: B,
            /// Maximum key in this subtree.
            max_key: Key,
            /// Inline SoA child bounds (`max_children = 12`, 3x 4-wide SIMD lanes).
            min_x: [max_children]U = @splat(0),
            min_y: [max_children]U = @splat(0),
            max_x: [max_children]U = @splat(0),
            max_y: [max_children]U = @splat(0),
            /// Inline `Key.asU64()` of each child.
            child_keys: [max_children]u64 = @splat(0),
            /// Child internal node index when `is_leaf_level` is false.
            child_indices: [max_children]u32 = @splat(0),
            len: u16 = 0,
            /// True when all children are inline leaves; false when all children are internal nodes.
            is_leaf_level: bool = true,

            inline fn setChild(self: *InternalNode, pos: usize, b: B, key_u64: u64, child_idx: u32) void {
                self.min_x[pos] = b.origin.x;
                self.min_y[pos] = b.origin.y;
                self.max_x[pos] = b.origin.x + b.size.width;
                self.max_y[pos] = b.origin.y + b.size.height;
                self.child_keys[pos] = key_u64;
                self.child_indices[pos] = child_idx;
            }

            inline fn pushChild(self: *InternalNode, b: B, key_u64: u64, child_idx: u32) void {
                std.debug.assert(self.len < max_children);
                const pos = self.len;
                self.len = pos + 1;
                self.setChild(pos, b, key_u64, child_idx);
            }

            inline fn swapChildren(self: *InternalNode, a: usize, b: usize) void {
                if (a == b) return;
                std.mem.swap(U, &self.min_x[a], &self.min_x[b]);
                std.mem.swap(U, &self.min_y[a], &self.min_y[b]);
                std.mem.swap(U, &self.max_x[a], &self.max_x[b]);
                std.mem.swap(U, &self.max_y[a], &self.max_y[b]);
                std.mem.swap(u64, &self.child_keys[a], &self.child_keys[b]);
                std.mem.swap(u32, &self.child_indices[a], &self.child_indices[b]);
            }

            /// Recomputes `bounds`, `max_key`, and enforces the max-end invariant across `0..len`.
            fn finalizeMetadata(self: *InternalNode) void {
                std.debug.assert(self.len > 0);
                var x0 = self.min_x[0];
                var y0 = self.min_y[0];
                var x1 = self.max_x[0];
                var y1 = self.max_y[0];
                var max_k = self.child_keys[0];
                var max_pos: usize = 0;
                for (1..self.len) |i| {
                    x0 = @min(x0, self.min_x[i]);
                    y0 = @min(y0, self.min_y[i]);
                    x1 = @max(x1, self.max_x[i]);
                    y1 = @max(y1, self.max_y[i]);
                    if (self.child_keys[i] > max_k) {
                        max_k = self.child_keys[i];
                        max_pos = i;
                    }
                }
                self.bounds = B.from_corners(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 });
                self.max_key = Key.fromU64(max_k);
                self.swapChildren(max_pos, self.len - 1);
            }

            /// Tests all inline children against `query` using 4-wide SIMD and returns a bitmask of intersecting lanes.
            inline fn intersectMask(self: *const InternalNode, q_min_x: Vec4, q_min_y: Vec4, q_max_x: Vec4, q_max_y: Vec4) u16 {
                var mask: u16 = 0;
                inline for (0..3) |chunk| {
                    const base = chunk * 4;
                    const c_min_x: Vec4 = self.min_x[base..][0..4].*;
                    const c_min_y: Vec4 = self.min_y[base..][0..4].*;
                    const c_max_x: Vec4 = self.max_x[base..][0..4].*;
                    const c_max_y: Vec4 = self.max_y[base..][0..4].*;
                    const hit: Mask4 = (q_max_x > c_min_x) & (q_min_x < c_max_x) & (q_max_y > c_min_y) & (q_min_y < c_max_y);
                    mask |= @as(u16, @as(u4, @bitCast(hit))) << @intCast(base);
                }
                const valid_mask: u16 = (@as(u16, 1) << @intCast(self.len)) - 1;
                return mask & valid_mask;
            }

            /// Returns the child index minimizing half-perimeter enlargement (tie-broken by child half-perimeter) using 4-wide SIMD.
            inline fn bestChildPos(self: *const InternalNode, vb_min_x: Vec4, vb_min_y: Vec4, vb_max_x: Vec4, vb_max_y: Vec4) usize {
                var enlargements: [max_children]U = undefined;
                var perimeters: [max_children]U = undefined;
                inline for (0..3) |chunk| {
                    const base = chunk * 4;
                    const c_min_x: Vec4 = self.min_x[base..][0..4].*;
                    const c_min_y: Vec4 = self.min_y[base..][0..4].*;
                    const c_max_x: Vec4 = self.max_x[base..][0..4].*;
                    const c_max_y: Vec4 = self.max_y[base..][0..4].*;
                    const u_min_x = @min(vb_min_x, c_min_x);
                    const u_min_y = @min(vb_min_y, c_min_y);
                    const u_max_x = @max(vb_max_x, c_max_x);
                    const u_max_y = @max(vb_max_y, c_max_y);
                    const c_hp = (c_max_x - c_min_x) + (c_max_y - c_min_y);
                    const u_hp = (u_max_x - u_min_x) + (u_max_y - u_min_y);
                    perimeters[base..][0..4].* = c_hp;
                    enlargements[base..][0..4].* = u_hp - c_hp;
                }
                var best_pos: usize = 0;
                var best_enl = enlargements[0];
                var best_hp = perimeters[0];
                for (1..self.len) |pos| {
                    const enl = enlargements[pos];
                    const hp = perimeters[pos];
                    if (enl < best_enl or (enl == best_enl and hp < best_hp)) {
                        best_enl = enl;
                        best_hp = hp;
                        best_pos = pos;
                    }
                }
                return best_pos;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.internals.deinit(self.allocator);
            self.insert_path.deinit(self.allocator);
            self.search_stack.deinit(self.allocator);
        }

        /// Clears all nodes from the tree, retaining capacity.
        pub fn clear(self: *Self) void {
            self.internals.clearRetainingCapacity();
            self.root = .empty;
            self.max_leaf_key = null;
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

            try self.insert_leaf(new_bounds, key);

            if (self.max_leaf_key) |old_key| {
                if (old_key.lt(key)) {
                    self.max_leaf_key = key;
                    self.max_leaf_bounds = new_bounds;
                }
            } else {
                self.max_leaf_key = key;
                self.max_leaf_bounds = new_bounds;
            }

            return ordering;
        }

        /// Finds the maximum key among all bounds that intersect the query.
        fn find_max_key(self: *Self, query: B) !?Key {
            const root_idx: u32 = switch (self.root) {
                .empty => return null,
                .leaf => |leaf| return if (query.intersects(leaf.bounds)) leaf.key else null,
                .internal => |idx| idx,
            };

            // Fast path: the max-key leaf often intersects.
            if (self.max_leaf_key) |max_key| {
                if (query.intersects(self.max_leaf_bounds)) return max_key;
            }

            // Instant root-bounds check before touching the search stack.
            if (!query.intersects(self.internals.items[root_idx].bounds)) return null;

            const q_min_x: Vec4 = @splat(query.origin.x);
            const q_min_y: Vec4 = @splat(query.origin.y);
            const q_max_x: Vec4 = @splat(query.origin.x + query.size.width);
            const q_max_y: Vec4 = @splat(query.origin.y + query.size.height);

            self.search_stack.clearRetainingCapacity();

            var max_found_u64: u64 = 0;
            var current_opt: ?u32 = root_idx;
            while (current_opt) |node_idx| {
                const node = &self.internals.items[node_idx];
                if (node.max_key.asU64() > max_found_u64) {
                    var hits = node.intersectMask(q_min_x, q_min_y, q_max_x, q_max_y);
                    if (hits != 0) {
                        if (node.is_leaf_level) {
                            // Leaf children update max_found directly without pushing onto search_stack.
                            while (hits != 0) {
                                const bit: u4 = @intCast(@ctz(hits));
                                hits &= hits - 1;
                                const ck = node.child_keys[bit];
                                if (ck > max_found_u64) max_found_u64 = ck;
                            }
                        } else {
                            // Internal children: only push intersecting nodes whose max_key can beat max_found.
                            // Max-end invariant keeps the highest-key child last, so pushing in ascending index
                            // order pops it first from the LIFO stack.
                            try self.search_stack.ensureUnusedCapacity(self.allocator, max_children);
                            while (hits != 0) {
                                const bit: u4 = @intCast(@ctz(hits));
                                hits &= hits - 1;
                                if (node.child_keys[bit] > max_found_u64) {
                                    self.search_stack.appendAssumeCapacity(node.child_indices[bit]);
                                }
                            }
                        }
                    }
                }
                current_opt = self.search_stack.pop();
            }

            if (max_found_u64 == 0) return null;
            return Key.fromU64(max_found_u64);
        }

        /// Splits a full `InternalNode` (`len == max_children`) plus one new child `(b, key_u64, child_idx)`
        /// into `node` (6 children) and a newly appended `InternalNode` (7 children), returning its index.
        fn splitNode(self: *Self, node_idx: u32, b: B, key_u64: u64, child_idx: u32) !u32 {
            const total = max_children + 1;
            var e_min_x: [total]U = undefined;
            var e_min_y: [total]U = undefined;
            var e_max_x: [total]U = undefined;
            var e_max_y: [total]U = undefined;
            var e_keys: [total]u64 = undefined;
            var e_idx: [total]u32 = undefined;

            const src = &self.internals.items[node_idx];
            const is_leaf_level = src.is_leaf_level;
            @memcpy(e_min_x[0..max_children], &src.min_x);
            @memcpy(e_min_y[0..max_children], &src.min_y);
            @memcpy(e_max_x[0..max_children], &src.max_x);
            @memcpy(e_max_y[0..max_children], &src.max_y);
            @memcpy(e_keys[0..max_children], &src.child_keys);
            @memcpy(e_idx[0..max_children], &src.child_indices);
            e_min_x[max_children] = b.origin.x;
            e_min_y[max_children] = b.origin.y;
            e_max_x[max_children] = b.origin.x + b.size.width;
            e_max_y[max_children] = b.origin.y + b.size.height;
            e_keys[max_children] = key_u64;
            e_idx[max_children] = child_idx;

            var all_min_x = e_min_x[0];
            var all_min_y = e_min_y[0];
            var all_max_x = e_max_x[0];
            var all_max_y = e_max_y[0];
            for (1..total) |i| {
                all_min_x = @min(all_min_x, e_min_x[i]);
                all_min_y = @min(all_min_y, e_min_y[i]);
                all_max_x = @max(all_max_x, e_max_x[i]);
                all_max_y = @max(all_max_y, e_max_y[i]);
            }

            const split_x = (all_max_x - all_min_x) >= (all_max_y - all_min_y);
            var order: [total]u8 = undefined;
            var centers: [total]U = undefined;
            for (0..total) |i| {
                order[i] = @intCast(i);
                centers[i] = if (split_x) e_min_x[i] + e_max_x[i] else e_min_y[i] + e_max_y[i];
            }
            // Insertion sort of 13 elements by axis center.
            for (1..total) |i| {
                const ord_i = order[i];
                const key_i = centers[ord_i];
                var j = i;
                while (j > 0 and centers[order[j - 1]] > key_i) {
                    order[j] = order[j - 1];
                    j -= 1;
                }
                order[j] = ord_i;
            }

            const left_count: usize = 6;
            var right_node: InternalNode = .{
                .bounds = undefined,
                .max_key = undefined,
                .len = @intCast(total - left_count),
                .is_leaf_level = is_leaf_level,
            };
            for (left_count..total, 0..) |k, dst_i| {
                const idx = order[k];
                right_node.min_x[dst_i] = e_min_x[idx];
                right_node.min_y[dst_i] = e_min_y[idx];
                right_node.max_x[dst_i] = e_max_x[idx];
                right_node.max_y[dst_i] = e_max_y[idx];
                right_node.child_keys[dst_i] = e_keys[idx];
                right_node.child_indices[dst_i] = e_idx[idx];
            }
            right_node.finalizeMetadata();

            const right_idx: u32 = @intCast(self.internals.items.len);
            try self.internals.append(self.allocator, right_node);

            // Re-index `self.internals.items[node_idx]` after append.
            const left_node = &self.internals.items[node_idx];
            left_node.len = left_count;
            for (0..left_count) |dst_i| {
                const idx = order[dst_i];
                left_node.min_x[dst_i] = e_min_x[idx];
                left_node.min_y[dst_i] = e_min_y[idx];
                left_node.max_x[dst_i] = e_max_x[idx];
                left_node.max_y[dst_i] = e_max_y[idx];
                left_node.child_keys[dst_i] = e_keys[idx];
                left_node.child_indices[dst_i] = e_idx[idx];
            }
            left_node.finalizeMetadata();
            return right_idx;
        }

        /// Inserts a leaf with the given bounds and key into a balanced R-tree.
        fn insert_leaf(self: *Self, bounds: B, key: Key) !void {
            const key_u64 = key.asU64();
            const root_idx: u32 = switch (self.root) {
                .empty => {
                    self.root = .{ .leaf = .{ .bounds = bounds, .key = key } };
                    return;
                },
                .leaf => |root_leaf| {
                    var node: InternalNode = .{
                        .bounds = root_leaf.bounds.@"union"(bounds),
                        .max_key = Key.max(root_leaf.key, key),
                        .is_leaf_level = true,
                    };
                    // Max-end invariant: the highest-key child goes last.
                    if (key.gt(root_leaf.key)) {
                        node.pushChild(root_leaf.bounds, root_leaf.key.asU64(), 0);
                        node.pushChild(bounds, key_u64, 0);
                    } else {
                        node.pushChild(bounds, key_u64, 0);
                        node.pushChild(root_leaf.bounds, root_leaf.key.asU64(), 0);
                    }
                    const new_root_idx: u32 = @intCast(self.internals.items.len);
                    try self.internals.append(self.allocator, node);
                    self.root = .{ .internal = new_root_idx };
                    return;
                },
                .internal => |idx| idx,
            };

            const b_min_x = bounds.origin.x;
            const b_min_y = bounds.origin.y;
            const b_max_x = bounds.origin.x + bounds.size.width;
            const b_max_y = bounds.origin.y + bounds.size.height;
            const vb_min_x: Vec4 = @splat(b_min_x);
            const vb_min_y: Vec4 = @splat(b_min_y);
            const vb_max_x: Vec4 = @splat(b_max_x);
            const vb_max_y: Vec4 = @splat(b_max_y);

            // Descend to the leaf-level internal node that best fits the new bounds.
            self.insert_path.clearRetainingCapacity();
            var current_idx = root_idx;
            while (!self.internals.items[current_idx].is_leaf_level) {
                const best_pos = self.internals.items[current_idx].bestChildPos(vb_min_x, vb_min_y, vb_max_x, vb_max_y);
                try self.insert_path.append(self.allocator, .{
                    .node_idx = current_idx,
                    .child_pos = @intCast(best_pos),
                });
                current_idx = self.internals.items[current_idx].child_indices[best_pos];
            }

            var split_right_idx: ?u32 = null;
            if (self.internals.items[current_idx].len < max_children) {
                const node = &self.internals.items[current_idx];
                node.pushChild(bounds, key_u64, 0);
                if (key.le(node.max_key)) {
                    const last = node.len - 1;
                    node.swapChildren(last - 1, last);
                } else {
                    node.max_key = key;
                }
                node.bounds = node.bounds.@"union"(bounds);
            } else {
                split_right_idx = try self.splitNode(current_idx, bounds, key_u64, 0);
            }

            // Propagate splits, bounds, and max_key up the ancestor path.
            var path_pos = self.insert_path.items.len;
            while (path_pos > 0) {
                path_pos -= 1;
                const step = self.insert_path.items[path_pos];
                const parent_idx = step.node_idx;
                const pos: usize = step.child_pos;

                if (split_right_idx) |r_idx| {
                    const left_idx = self.internals.items[parent_idx].child_indices[pos];
                    const left_bounds = self.internals.items[left_idx].bounds;
                    const left_key = self.internals.items[left_idx].max_key.asU64();
                    const right_bounds = self.internals.items[r_idx].bounds;
                    const right_key = self.internals.items[r_idx].max_key.asU64();

                    self.internals.items[parent_idx].setChild(pos, left_bounds, left_key, left_idx);

                    if (self.internals.items[parent_idx].len < max_children) {
                        const parent = &self.internals.items[parent_idx];
                        parent.pushChild(right_bounds, right_key, r_idx);
                        parent.finalizeMetadata();
                        split_right_idx = null;
                    } else {
                        split_right_idx = try self.splitNode(parent_idx, right_bounds, right_key, r_idx);
                    }
                } else {
                    const node = &self.internals.items[parent_idx];
                    node.min_x[pos] = @min(node.min_x[pos], b_min_x);
                    node.min_y[pos] = @min(node.min_y[pos], b_min_y);
                    node.max_x[pos] = @max(node.max_x[pos], b_max_x);
                    node.max_y[pos] = @max(node.max_y[pos], b_max_y);
                    if (key_u64 > node.child_keys[pos]) {
                        node.child_keys[pos] = key_u64;
                    }
                    node.bounds = node.bounds.@"union"(bounds);
                    if (node.max_key.lt(key)) {
                        node.max_key = key;
                        const last = node.len - 1;
                        node.swapChildren(pos, last);
                    }
                }
            }

            // If the root split, allocate a new root above [old_root, split_right].
            if (split_right_idx) |r_idx| {
                const left_bounds = self.internals.items[root_idx].bounds;
                const left_key = self.internals.items[root_idx].max_key;
                const right_bounds = self.internals.items[r_idx].bounds;
                const right_key = self.internals.items[r_idx].max_key;

                var new_root: InternalNode = .{
                    .bounds = left_bounds.@"union"(right_bounds),
                    .max_key = Key.max(left_key, right_key),
                    .is_leaf_level = false,
                };
                if (right_key.gt(left_key)) {
                    new_root.pushChild(left_bounds, left_key.asU64(), root_idx);
                    new_root.pushChild(right_bounds, right_key.asU64(), r_idx);
                } else {
                    new_root.pushChild(right_bounds, right_key.asU64(), r_idx);
                    new_root.pushChild(left_bounds, left_key.asU64(), root_idx);
                }
                const new_root_idx: u32 = @intCast(self.internals.items.len);
                try self.internals.append(self.allocator, new_root);
                self.root = .{ .internal = new_root_idx };
            }
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

test "1500 mixed overlapping, non-overlapping, and edge-touching primitives match O(N^2) oracle" {
    const kinds = [_]PrimitiveKind{ .shadow, .quad, .path, .underline, .monochrome_sprite, .subpixel_sprite, .polychrome_sprite, .surface };
    var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafebabe);
    const random = prng.random();

    var tree = BoundsTree(f32).init(testing.allocator);
    defer tree.deinit();

    var expected: std.ArrayList(struct { bounds: geometry.Bounds(f32), key: Key }) = .empty;
    defer expected.deinit(testing.allocator);

    // Grid-snapped + continuous bounds to hit edge-touching, deep overlap, and disjoint regions.
    const num_bounds: usize = 1500;
    for (0..num_bounds) |i| {
        const bounds = if (i % 5 == 0) blk: {
            // Edge-touching 10x10 tiles on a coarse grid.
            const gx: f32 = @floatFromInt(random.intRangeAtMost(i32, -10, 10) * 10);
            const gy: f32 = @floatFromInt(random.intRangeAtMost(i32, -10, 10) * 10);
            break :blk geometry.bounds(Point(f32){ .x = gx, .y = gy }, Size(f32){ .width = 10, .height = 10 });
        } else if (i % 17 == 0) blk: {
            // Zero-width or zero-height edge cases.
            const x = -50.0 + random.float(f32) * 100.0;
            const y = -50.0 + random.float(f32) * 100.0;
            const w: f32 = if (i % 2 == 0) 0 else 15.0;
            const h: f32 = if (i % 2 == 0) 15.0 else 0;
            break :blk geometry.bounds(Point(f32){ .x = x, .y = y }, Size(f32){ .width = w, .height = h });
        } else blk: {
            const min_x = -500.0 + random.float(f32) * 1000.0;
            const min_y = -500.0 + random.float(f32) * 1000.0;
            const width = random.float(f32) * 120.0;
            const height = random.float(f32) * 120.0;
            break :blk geometry.bounds(Point(f32){ .x = min_x, .y = min_y }, Size(f32){ .width = width, .height = height });
        };

        const kind = kinds[random.intRangeLessThan(usize, 0, kinds.len)];
        const max_shared_kind = kind.max_shared_kind();

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
