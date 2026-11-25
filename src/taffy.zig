//! Port of GPUI `taffy.rs`: the layout engine, backed by zafi (a Taffy port).

const std = @import("std");
const zafi = @import("zafi");
const geometry = @import("geometry.zig");
const style_mod = @import("style.zig");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;

const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Style = style_mod.Style;

/// Identifies a node in the layout tree.
pub const LayoutId = zafi.NodeId;

/// Available space along one axis.
pub const AvailableSpace = union(enum) {
    definite: Pixels,
    min_content,
    max_content,

    pub fn min_size() Size(AvailableSpace) {
        return .{ .width = .min_content, .height = .min_content };
    }
    pub fn from(v: anytype) AvailableSpace {
        return switch (@TypeOf(v)) {
            AvailableSpace => v,
            else => .{ .definite = @floatCast(v) },
        };
    }
    fn toZafi(self: AvailableSpace, scale: f32) zafi.AvailableSpace {
        return switch (self) {
            .definite => |p| .{ .definite = p * scale },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    }
    fn fromZafi(v: zafi.AvailableSpace, scale: f32) AvailableSpace {
        return switch (v) {
            .definite => |p| .{ .definite = p / scale },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    }
};

/// A measure callback for leaves whose size depends on content (text, images).
pub const MeasureFn = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, known: Size(?Pixels), available: Size(AvailableSpace), window: *Window, cx: *App) Size(Pixels),
    /// Optional variant that also receives `final_layout: bool` (`run_mode == .perform_layout`).
    final_func: ?*const fn (ctx: *anyopaque, known: Size(?Pixels), available: Size(AvailableSpace), final_layout: bool, window: *Window, cx: *App) Size(Pixels) = null,
};

/// Callback invoked when a keyed measured node hits in `LayoutCache` (its `key_hash` matches).
/// Returns true if the previous measurement was successfully reused and `mark_dirty` can be skipped;
/// false to force re-measurement.
pub const ReuseFn = *const fn (ctx: *anyopaque, payload: ?*anyopaque, window: *Window, cx: *App) bool;

/// Destructor for an opaque per-node measure payload stored on `TaffyLayoutEngine`.
pub const PayloadDeinitFn = *const fn (allocator: std.mem.Allocator, payload: *anyopaque) void;

/// Layout nodes requested by elements under one element ID path, in request order.
/// Elements without IDs are distinguished only by their order within the nearest ancestor with one.
const LayoutScope = struct {
    requested: usize = 0,
    nodes: std.ArrayList(LayoutId) = .empty,
};

/// Persistent storage for converted grid tracks so `zafi.Style` slices remain valid across frames.
const GridBuffers = struct {
    cols_tracks: [1]zafi.TrackSizingFunction = undefined,
    cols_comps: [1]zafi.GridTemplateComponent = undefined,
    rows_tracks: [1]zafi.TrackSizingFunction = undefined,
    rows_comps: [1]zafi.GridTemplateComponent = undefined,
};

const CachedNode = struct {
    style: LayoutStyle,
    frame: u64,
    stretched: bool = false,
    grid_buffers: ?*GridBuffers = null,
};

const ComputedBounds = struct {
    origin: Point(f32),
    bounds: Bounds(Pixels),
};

const LayoutCache = struct {
    scopes: std.AutoHashMapUnmanaged(u64, LayoutScope) = .empty,
    nodes: std.AutoHashMapUnmanaged(LayoutId, CachedNode) = .empty,
    /// Nodes no element requested last frame, detached from the tree.
    free_nodes: std.ArrayList(LayoutId) = .empty,
    frame: u64 = 0,
    /// Scale factor cached device-pixel styles and measurements were computed at.
    scale_factor: ?f32 = null,
    /// Single-entry cache for consecutive sibling nodes sharing the same `scope_key`.
    last_scope_key: u64 = 0,
    last_scope_ptr: ?*LayoutScope = null,
};

const MeasureEntry = struct {
    measure: MeasureFn,
    key_hash: ?u64 = null,
    payload: ?*anyopaque = null,
    payload_deinit: ?PayloadDeinitFn = null,
};

/// GPUI `TaffyLayoutEngine`.
pub const TaffyLayoutEngine = struct {
    taffy: zafi.Tree,
    cache: LayoutCache = .{},
    /// Kept outside `zafi.Tree`, whose `set_node_context` marks a node dirty on every call.
    measures: std.AutoHashMapUnmanaged(LayoutId, MeasureEntry) = .empty,
    computed_bounds: std.AutoHashMapUnmanaged(LayoutId, ComputedBounds) = .empty,
    computed_layouts: std.AutoHashMapUnmanaged(LayoutId, void) = .empty,
    scratch: std.ArrayList(LayoutId) = .empty,
    allocator: std.mem.Allocator,

    // Set during compute_layout for the measure trampoline.
    cur_window: ?*Window = null,
    cur_app: ?*App = null,
    cur_scale: f32 = 1,
    cur_final_layout: bool = true,
    cur_measure_node: ?LayoutId = null,
    measure_calls: usize = 0,
    last_frame_measure_calls: usize = 0,

    pub fn new(allocator: std.mem.Allocator) TaffyLayoutEngine {
        var t = zafi.Tree.init(allocator);
        t.disable_rounding();
        return .{ .taffy = t, .allocator = allocator };
    }

    pub fn deinit(self: *TaffyLayoutEngine) void {
        self.freeAllCacheResources();
        self.taffy.deinit();
        self.computed_bounds.deinit(self.allocator);
        self.computed_layouts.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    fn freeAllCacheResources(self: *TaffyLayoutEngine) void {
        self.cache.last_scope_ptr = null;
        var scope_it = self.cache.scopes.valueIterator();
        while (scope_it.next()) |scope| scope.nodes.deinit(self.allocator);
        self.cache.scopes.deinit(self.allocator);

        var node_it = self.cache.nodes.valueIterator();
        while (node_it.next()) |node| {
            if (node.grid_buffers) |buf| self.allocator.destroy(buf);
        }
        self.cache.nodes.deinit(self.allocator);
        self.cache.free_nodes.deinit(self.allocator);
        self.cache = .{};

        var measure_it = self.measures.valueIterator();
        while (measure_it.next()) |entry| {
            if (entry.payload) |p| {
                if (entry.payload_deinit) |deinit_fn| deinit_fn(self.allocator, p);
            }
        }
        self.measures.deinit(self.allocator);
        self.measures = .empty;
    }

    /// Drops every layout node kept from earlier frames, so the next frame builds its tree from scratch.
    pub fn clear_layout_cache(self: *TaffyLayoutEngine) void {
        self.freeAllCacheResources();
        self.taffy.clear();
        self.cache = .{};
        self.computed_bounds.clearRetainingCapacity();
        self.computed_layouts.clearRetainingCapacity();
        self.measure_calls = 0;
        self.last_frame_measure_calls = 0;
    }

    /// Clears the layout cache when the window's scale factor changes.
    pub fn clear_if_scale_factor_changed(self: *TaffyLayoutEngine, scale_factor: f32) void {
        if (self.cache.scale_factor) |previous| {
            if (previous != scale_factor) {
                self.clear_layout_cache();
            }
        }
        self.cache.scale_factor = scale_factor;
    }

    pub fn node_count(self: *const TaffyLayoutEngine) usize {
        return self.taffy.total_node_count();
    }

    /// Ends the frame: nodes that weren't requested during it are detached and evicted after one spare frame.
    pub fn clear(self: *TaffyLayoutEngine) void {
        self.evict_unrequested();
        self.computed_bounds.clearRetainingCapacity();
        self.computed_layouts.clearRetainingCapacity();
        self.last_frame_measure_calls = self.measure_calls;
        self.measure_calls = 0;
    }

    fn evict_unrequested(self: *TaffyLayoutEngine) void {
        const cache = &self.cache;
        cache.last_scope_ptr = null;
        for (cache.free_nodes.items) |id| {
            if (cache.nodes.fetchRemove(id)) |kv| {
                if (kv.value.grid_buffers) |buf| self.allocator.destroy(buf);
            }
            self.removeMeasure(id);
            _ = self.taffy.remove(id) catch {};
        }
        cache.free_nodes.clearRetainingCapacity();

        var dead_scopes: std.ArrayList(u64) = .empty;
        defer dead_scopes.deinit(self.allocator);
        var it = cache.scopes.iterator();
        while (it.next()) |kv| {
            const scope = kv.value_ptr;
            const requested = scope.requested;
            scope.requested = 0;
            if (requested < scope.nodes.items.len) {
                cache.free_nodes.appendSlice(self.allocator, scope.nodes.items[requested..]) catch oom();
                scope.nodes.shrinkRetainingCapacity(requested);
            }
            if (requested == 0) {
                dead_scopes.append(self.allocator, kv.key_ptr.*) catch oom();
            }
        }
        for (dead_scopes.items) |key| {
            if (cache.scopes.fetchRemove(key)) |kv| {
                var s = kv.value;
                s.nodes.deinit(self.allocator);
            }
        }

        // Every requested node had its children set to nodes requested this frame, so clearing
        // unrequested nodes' children detaches all unrequested nodes without touching the live tree.
        for (cache.free_nodes.items) |id| {
            self.removeMeasure(id);
            if ((self.taffy.child_count(id) catch 0) > 0) {
                self.taffy.set_children(id, &.{}) catch oom();
            }
        }
        cache.frame += 1;
    }

    fn removeMeasure(self: *TaffyLayoutEngine, id: LayoutId) void {
        if (self.measures.fetchRemove(id)) |kv| {
            if (kv.value.payload) |p| {
                if (kv.value.payload_deinit) |deinit_fn| deinit_fn(self.allocator, p);
            }
        }
    }

    /// Updates the persistent payload on the currently-measuring node (called during `MeasureFn`).
    pub fn set_current_measure_payload(self: *TaffyLayoutEngine, payload: ?*anyopaque, deinit_fn: ?PayloadDeinitFn) void {
        const id = self.cur_measure_node orelse return;
        const entry = self.measures.getPtr(id) orelse return;
        if (entry.payload) |old| {
            if (old != payload) {
                if (entry.payload_deinit) |old_deinit| old_deinit(self.allocator, old);
            }
        }
        entry.payload = payload;
        entry.payload_deinit = deinit_fn;
    }

    pub fn request_layout(self: *TaffyLayoutEngine, scope: u64, style: *const Style, rem_size: Pixels, scale_factor: f32, children: []const LayoutId) LayoutId {
        return self.request_layout_any(scope, style, rem_size, scale_factor, children);
    }

    /// Like `request_layout`, but reads directly from a `*const StyleRefinement` without
    /// constructing an intermediate `Style`.
    pub fn request_layout_refinement(self: *TaffyLayoutEngine, scope: u64, style: *const style_mod.StyleRefinement, rem_size: Pixels, scale_factor: f32, children: []const LayoutId) LayoutId {
        return self.request_layout_any(scope, style, rem_size, scale_factor, children);
    }

    fn request_layout_any(self: *TaffyLayoutEngine, scope: u64, style: anytype, rem_size: Pixels, scale_factor: f32, children: []const LayoutId) LayoutId {
        const id = self.acquire_node(scope, style, rem_size, scale_factor, children);
        if (self.measures.count() > 0) {
            if (self.measures.fetchRemove(id)) |kv| {
                if (kv.value.payload) |p| {
                    if (kv.value.payload_deinit) |deinit_fn| deinit_fn(self.allocator, p);
                }
                self.taffy.mark_dirty(id);
            }
        }
        return id;
    }

    pub fn request_measured_layout(self: *TaffyLayoutEngine, scope: u64, style: *const Style, rem_size: Pixels, scale_factor: f32, measure: MeasureFn) LayoutId {
        const id = self.acquire_node(scope, style, rem_size, scale_factor, &.{});
        const gop = self.measures.getOrPut(self.allocator, id) catch oom();
        if (gop.found_existing) {
            if (gop.value_ptr.payload) |p| {
                if (gop.value_ptr.payload_deinit) |deinit_fn| deinit_fn(self.allocator, p);
            }
        }
        gop.value_ptr.* = .{ .measure = measure, .key_hash = null };
        self.taffy.mark_dirty(id);
        return id;
    }

    pub fn request_keyed_measured_layout(
        self: *TaffyLayoutEngine,
        scope: u64,
        style: *const Style,
        rem_size: Pixels,
        scale_factor: f32,
        key_hash: u64,
        measure: MeasureFn,
    ) LayoutId {
        return self.request_keyed_measure(scope, style, rem_size, scale_factor, key_hash, measure, null, null, null);
    }

    pub fn request_keyed_measure(
        self: *TaffyLayoutEngine,
        scope: u64,
        style: *const Style,
        rem_size: Pixels,
        scale_factor: f32,
        key_hash: u64,
        measure: MeasureFn,
        reuse_fn: ?ReuseFn,
        window: ?*Window,
        cx: ?*App,
    ) LayoutId {
        const id = self.acquire_node(scope, style, rem_size, scale_factor, &.{});
        const gop = self.measures.getOrPut(self.allocator, id) catch oom();
        if (gop.found_existing) {
            const entry = gop.value_ptr;
            if (entry.key_hash != null and entry.key_hash.? == key_hash) {
                const reused = if (reuse_fn) |rf|
                    rf(measure.ctx, entry.payload, window.?, cx.?)
                else
                    true;
                if (reused) {
                    entry.measure = measure;
                    return id;
                }
            }
            if (entry.payload) |p| {
                if (entry.payload_deinit) |deinit_fn| deinit_fn(self.allocator, p);
            }
        }
        gop.value_ptr.* = .{ .measure = measure, .key_hash = key_hash };
        self.taffy.mark_dirty(id);
        return id;
    }

    fn acquire_node(self: *TaffyLayoutEngine, scope_key: u64, style: anytype, rem_size: Pixels, scale_factor: f32, children: []const LayoutId) LayoutId {
        const cache = &self.cache;
        const frame = cache.frame;

        const scope: *LayoutScope = if (cache.last_scope_ptr != null and cache.last_scope_key == scope_key)
            cache.last_scope_ptr.?
        else blk: {
            const scope_gop = cache.scopes.getOrPut(self.allocator, scope_key) catch oom();
            if (!scope_gop.found_existing) scope_gop.value_ptr.* = .{};
            cache.last_scope_key = scope_key;
            cache.last_scope_ptr = scope_gop.value_ptr;
            break :blk scope_gop.value_ptr;
        };

        const ordinal = scope.requested;
        scope.requested += 1;

        if (ordinal < scope.nodes.items.len) {
            const existing_id = scope.nodes.items[ordinal];
            const node = cache.nodes.getPtr(existing_id).?;
            std.debug.assert(node.frame != frame); // layout node requested twice in one frame
            if (node.stretched or !node.style.matchesAny(style, rem_size, scale_factor)) {
                const prev_grid_cols = node.style.grid_cols;
                const prev_grid_rows = node.style.grid_rows;
                const was_stretched = node.stretched;
                node.style = LayoutStyle.fromAny(style, rem_size, scale_factor);
                node.stretched = false;
                const taffy_style = node.style.toZafi(self.allocator, &node.grid_buffers);
                const same_grid = std.meta.eql(prev_grid_cols, node.style.grid_cols) and std.meta.eql(prev_grid_rows, node.style.grid_rows);
                const same_taffy = if (!was_stretched and same_grid)
                    if (self.taffy.style_of(existing_id)) |cur| zafiStylesEqualNonGridSlices(&cur, &taffy_style) else |_| false
                else
                    false;
                if (!same_taffy) {
                    self.taffy.set_style(existing_id, taffy_style) catch oom();
                }
            }
            const existing_children = self.taffy.children(existing_id) catch &.{};
            if (!std.mem.eql(LayoutId, existing_children, children)) {
                self.taffy.set_children(existing_id, children) catch oom();
            }
            node.frame = frame;
            return existing_id;
        }

        const layout_style = LayoutStyle.fromAny(style, rem_size, scale_factor);
        const new_id: LayoutId = if (cache.free_nodes.pop()) |recycled| rblk: {
            const node = cache.nodes.getPtr(recycled).?;
            node.style = layout_style;
            node.frame = frame;
            node.stretched = false;
            const taffy_style = node.style.toZafi(self.allocator, &node.grid_buffers);
            self.taffy.set_style(recycled, taffy_style) catch oom();
            break :rblk recycled;
        } else lblk: {
            var grid_buffers: ?*GridBuffers = null;
            const taffy_style = layout_style.toZafi(self.allocator, &grid_buffers);
            const leaf_id = self.taffy.new_leaf(taffy_style) catch {
                if (grid_buffers) |buf| self.allocator.destroy(buf);
                oom();
            };
            cache.nodes.put(self.allocator, leaf_id, .{
                .style = layout_style,
                .frame = frame,
                .stretched = false,
                .grid_buffers = grid_buffers,
            }) catch oom();
            break :lblk leaf_id;
        };
        if (children.len > 0) {
            self.taffy.set_children(new_id, children) catch oom();
        }
        scope.nodes.append(self.allocator, new_id) catch oom();
        return new_id;
    }

    /// Makes an auto-sized root fill `sz` (GPUI `stretch_auto_size_to_fill`).
    pub fn stretch_auto_size_to_fill(self: *TaffyLayoutEngine, id: LayoutId, sz: Size(Pixels), scale_factor: f32) void {
        var s = self.taffy.style_of(id) catch return;
        const sw = s.size.width.is_auto();
        const sh = s.size.height.is_auto();
        if (!sw and !sh) return;
        if (self.cache.nodes.getPtr(id)) |node| {
            node.stretched = true;
        }
        if (sw) s.size.width = .length(@round(sz.width * scale_factor));
        if (sh) s.size.height = .length(@round(sz.height * scale_factor));
        self.taffy.set_style(id, s) catch oom();
    }

    pub fn compute_layout(self: *TaffyLayoutEngine, id: LayoutId, available_space: Size(AvailableSpace), window: *Window, cx: *App) void {
        // A node computed as a root may still be attached to a parent from an earlier frame
        // that no element requested in this one. Its layout must not be relative to that parent.
        if (self.taffy.parent(id) catch null) |parent| {
            const parent_active = if (self.cache.nodes.get(parent)) |node| node.frame == self.cache.frame else false;
            if (!parent_active) {
                _ = self.taffy.remove_child(parent, id) catch {};
            }
        }
        const gop = self.computed_layouts.getOrPut(self.allocator, id) catch oom();
        if (gop.found_existing) {
            self.scratch.clearRetainingCapacity();
            self.scratch.append(self.allocator, id) catch oom();
            while (self.scratch.pop()) |n| {
                _ = self.computed_bounds.remove(n);
                const kids = self.taffy.children(n) catch &.{};
                self.scratch.appendSlice(self.allocator, kids) catch oom();
            }
        }
        const scale = window.scale_factor();
        const prev_window = self.cur_window;
        const prev_app = self.cur_app;
        const prev_scale = self.cur_scale;
        const prev_engine = current_engine;
        self.cur_window = window;
        self.cur_app = cx;
        self.cur_scale = scale;
        current_engine = self;
        defer {
            current_engine = prev_engine;
            self.cur_window = prev_window;
            self.cur_app = prev_app;
            self.cur_scale = prev_scale;
        }
        self.taffy.compute_layout_with_measure(id, .{
            .width = available_space.width.toZafi(scale),
            .height = available_space.height.toZafi(scale),
        }, measureTrampoline) catch oom();
    }

    threadlocal var current_engine: ?*TaffyLayoutEngine = null;

    fn measureTrampoline(context: ?*anyopaque, inputs: zafi.LayoutInput, node_id: zafi.NodeId, s: *const zafi.Style) zafi.LayoutOutput {
        _ = context;
        const self = current_engine orelse return zafi.compute_leaf_layout(inputs, s, null, null);
        const entry = self.measures.getPtr(node_id);
        const prev_final = self.cur_final_layout;
        const prev_node = self.cur_measure_node;
        self.cur_final_layout = inputs.run_mode == .perform_layout;
        self.cur_measure_node = node_id;
        defer {
            self.cur_final_layout = prev_final;
            self.cur_measure_node = prev_node;
        }
        return zafi.compute_leaf_layout(inputs, s, if (entry) |e| @ptrCast(e) else null, if (entry != null) sizeMeasure else null);
    }

    fn sizeMeasure(context: ?*anyopaque, known: zafi.Size(?f32), avail: zafi.Size(zafi.AvailableSpace)) zafi.Size(f32) {
        const self = current_engine orelse return .{ .width = 0, .height = 0 };
        const entry: *const MeasureEntry = @ptrCast(@alignCast(context orelse return .{ .width = 0, .height = 0 }));
        self.measure_calls += 1;
        const m = entry.measure;
        const scale = self.cur_scale;
        const kd: Size(?Pixels) = .{
            .width = if (known.width) |w| w / scale else null,
            .height = if (known.height) |h| h / scale else null,
        };
        const av: Size(AvailableSpace) = .{
            .width = AvailableSpace.fromZafi(avail.width, scale),
            .height = AvailableSpace.fromZafi(avail.height, scale),
        };
        const out = if (m.final_func) |ff|
            ff(m.ctx, kd, av, self.cur_final_layout, self.cur_window.?, self.cur_app.?)
        else
            m.func(m.ctx, kd, av, self.cur_window.?, self.cur_app.?);
        // Snap measured content to device pixels (GPUI ceils to avoid clipping).
        return .{ .width = @ceil(out.width * scale), .height = @ceil(out.height * scale) };
    }

    pub fn layout_bounds(self: *TaffyLayoutEngine, id: LayoutId, scale_factor: f32) Bounds(Pixels) {
        return self.layout_bounds_entry(id, scale_factor).bounds;
    }

    fn layout_bounds_entry(self: *TaffyLayoutEngine, id: LayoutId, scale_factor: f32) ComputedBounds {
        if (self.computed_bounds.get(id)) |entry| return entry;
        const lay = self.taffy.layout_of(id) catch unreachable;
        const loc: Point(f32) = .{ .x = lay.location.x, .y = lay.location.y };
        const parent = self.taffy.parent(id) catch null;
        const origin: Point(f32) = if (parent) |p| blk: {
            const pe = self.layout_bounds_entry(p, scale_factor);
            break :blk .{ .x = pe.origin.x + loc.x, .y = pe.origin.y + loc.y };
        } else loc;
        const far: Point(f32) = .{ .x = origin.x + lay.size.width, .y = origin.y + lay.size.height };
        const x0 = roundHalfTowardZero(origin.x) / scale_factor;
        const y0 = roundHalfTowardZero(origin.y) / scale_factor;
        const x1 = roundHalfTowardZero(far.x) / scale_factor;
        const y1 = roundHalfTowardZero(far.y) / scale_factor;
        const entry: ComputedBounds = .{
            .origin = origin,
            .bounds = .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = x1 - x0, .height = y1 - y0 } },
        };
        self.computed_bounds.put(self.allocator, id, entry) catch oom();
        return entry;
    }
};

fn roundHalfTowardZero(v: f32) f32 {
    const r = @round(v);
    if (@abs(v - @trunc(v)) == 0.5) return @trunc(v);
    return r;
}

fn oom() noreturn {
    @panic("out of memory");
}

/// Deterministic 64-bit hash of any value key (canonicalizing float +/-0.0 and hashing structs by field).
pub fn hashKey(key: anytype) u64 {
    const T = @TypeOf(key);
    if (T == u64) return key;
    var hasher = std.hash.Wyhash.init(std.hash.Wyhash.hash(0x4b65794d, @typeName(T)));
    hashValue(&hasher, key);
    return hasher.final();
}

fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => hasher.update(&.{@intFromBool(value)}),
        .int => hasher.update(std.mem.asBytes(&value)),
        .comptime_int => {
            const v: i128 = value;
            hasher.update(std.mem.asBytes(&v));
        },
        .float => |info| {
            const normalized: T = if (value == 0) 0 else value;
            const Bits = @Int(.unsigned, info.bits);
            const bits: Bits = @bitCast(normalized);
            hasher.update(std.mem.asBytes(&bits));
        },
        .comptime_float => {
            const v: f64 = value;
            hashValue(hasher, v);
        },
        .@"enum" => hashValue(hasher, @intFromEnum(value)),
        .optional => if (value) |some| {
            hasher.update(&.{1});
            hashValue(hasher, some);
        } else hasher.update(&.{0}),
        .array => for (value) |item| hashValue(hasher, item),
        .pointer => |info| switch (info.size) {
            .slice => {
                hashValue(hasher, value.len);
                for (value) |item| hashValue(hasher, item);
            },
            .one => hashValue(hasher, value.*),
            else => @compileError("cannot hash " ++ @typeName(T)),
        },
        .@"struct" => |info| inline for (info.field_names) |name| hashValue(hasher, @field(value, name)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                hashValue(hasher, tag);
                hashValue(hasher, payload);
            },
        },
        else => @compileError("cannot hash " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------
// LayoutStyle & Style -> zafi conversion (GPUI `LayoutStyle` / `ToTaffy`).

/// The fields of a `Style` that affect layout, plus the `rem_size` and `scale_factor`
/// they resolve against.
const LayoutStyle = struct {
    rem_size: Pixels,
    scale_factor: f32,
    display: style_mod.Display,
    overflow: Point(style_mod.Overflow),
    scrollbar_width: geometry.AbsoluteLength,
    position: style_mod.Position,
    inset: geometry.Edges(geometry.Length),
    size: Size(geometry.Length),
    min_size: Size(geometry.Length),
    max_size: Size(geometry.Length),
    aspect_ratio: ?f32,
    margin: geometry.Edges(geometry.Length),
    padding: geometry.Edges(geometry.DefiniteLength),
    border_widths: geometry.Edges(geometry.AbsoluteLength),
    align_items: ?style_mod.AlignItems,
    align_self: ?style_mod.AlignSelf,
    align_content: ?style_mod.AlignContent,
    justify_content: ?style_mod.JustifyContent,
    gap: Size(geometry.DefiniteLength),
    flex_direction: style_mod.FlexDirection,
    flex_wrap: style_mod.FlexWrap,
    flex_basis: geometry.Length,
    flex_grow: f32,
    flex_shrink: f32,
    grid_rows: ?style_mod.GridTemplate,
    grid_cols: ?style_mod.GridTemplate,
    grid_location: ?style_mod.GridLocation,

    inline fn valOr(comptime T: type, v: anytype, default: T) T {
        return if (@TypeOf(v) == ?T) (v orelse default) else v;
    }

    inline fn resolvePoint(comptime T: type, p: anytype, default: T) Point(T) {
        return .{ .x = valOr(T, p.x, default), .y = valOr(T, p.y, default) };
    }

    inline fn resolveSize(comptime T: type, sz: anytype, default: T) Size(T) {
        return .{ .width = valOr(T, sz.width, default), .height = valOr(T, sz.height, default) };
    }

    inline fn resolveEdges(comptime T: type, ed: anytype, default: T) geometry.Edges(T) {
        return .{
            .top = valOr(T, ed.top, default),
            .right = valOr(T, ed.right, default),
            .bottom = valOr(T, ed.bottom, default),
            .left = valOr(T, ed.left, default),
        };
    }

    const zero_abs: geometry.AbsoluteLength = .{ .pixels = 0 };
    const zero_def: geometry.DefiniteLength = .{ .absolute = zero_abs };
    const zero_len: geometry.Length = .{ .definite = zero_def };

    fn fromAny(s: anytype, rem_size: Pixels, scale_factor: f32) LayoutStyle {
        return .{
            .rem_size = rem_size,
            .scale_factor = scale_factor,
            .display = valOr(style_mod.Display, s.display, .block),
            .overflow = resolvePoint(style_mod.Overflow, s.overflow, .visible),
            .scrollbar_width = valOr(geometry.AbsoluteLength, s.scrollbar_width, zero_abs),
            .position = valOr(style_mod.Position, s.position, .relative),
            .inset = resolveEdges(geometry.Length, s.inset, .auto),
            .size = resolveSize(geometry.Length, s.size, .auto),
            .min_size = resolveSize(geometry.Length, s.min_size, .auto),
            .max_size = resolveSize(geometry.Length, s.max_size, .auto),
            .aspect_ratio = s.aspect_ratio,
            .margin = resolveEdges(geometry.Length, s.margin, zero_len),
            .padding = resolveEdges(geometry.DefiniteLength, s.padding, zero_def),
            .border_widths = resolveEdges(geometry.AbsoluteLength, s.border_widths, zero_abs),
            .align_items = s.align_items,
            .align_self = s.align_self,
            .align_content = s.align_content,
            .justify_content = s.justify_content,
            .gap = resolveSize(geometry.DefiniteLength, s.gap, zero_def),
            .flex_direction = valOr(style_mod.FlexDirection, s.flex_direction, .row),
            .flex_wrap = valOr(style_mod.FlexWrap, s.flex_wrap, .no_wrap),
            .flex_basis = valOr(geometry.Length, s.flex_basis, .auto),
            .flex_grow = valOr(f32, s.flex_grow, 0),
            .flex_shrink = valOr(f32, s.flex_shrink, 1),
            .grid_rows = s.grid_rows,
            .grid_cols = s.grid_cols,
            .grid_location = s.grid_location,
        };
    }

    fn fromStyle(s: *const Style, rem_size: Pixels, scale_factor: f32) LayoutStyle {
        return fromAny(s, rem_size, scale_factor);
    }

    inline fn matchAbsLen(a: geometry.AbsoluteLength, b: anytype) bool {
        if (@TypeOf(b) == ?geometry.AbsoluteLength) {
            const v = b orelse return a == .pixels and a.pixels == 0;
            return switch (a) {
                .pixels => |p| v == .pixels and v.pixels == p,
                .rems => |r| v == .rems and v.rems.value == r.value,
            };
        }
        return switch (a) {
            .pixels => |p| b == .pixels and b.pixels == p,
            .rems => |r| b == .rems and b.rems.value == r.value,
        };
    }

    inline fn matchDefLen(a: geometry.DefiniteLength, b: anytype) bool {
        if (@TypeOf(b) == ?geometry.DefiniteLength) {
            const v = b orelse return a == .absolute and a.absolute == .pixels and a.absolute.pixels == 0;
            return switch (a) {
                .absolute => |ab| v == .absolute and matchAbsLen(ab, v.absolute),
                .fraction => |f| v == .fraction and v.fraction == f,
            };
        }
        return switch (a) {
            .absolute => |ab| b == .absolute and matchAbsLen(ab, b.absolute),
            .fraction => |f| b == .fraction and b.fraction == f,
        };
    }

    inline fn matchLen(a: geometry.Length, b: anytype, comptime default_auto: bool) bool {
        if (@TypeOf(b) == ?geometry.Length) {
            const v = b orelse {
                if (default_auto) return a == .auto;
                return a == .definite and a.definite == .absolute and a.definite.absolute == .pixels and a.definite.absolute.pixels == 0;
            };
            return switch (a) {
                .definite => |d| v == .definite and matchDefLen(d, v.definite),
                .auto => v == .auto,
            };
        }
        return switch (a) {
            .definite => |d| b == .definite and matchDefLen(d, b.definite),
            .auto => b == .auto,
        };
    }

    inline fn matchSizeLen(a: Size(geometry.Length), b: anytype, comptime default_auto: bool) bool {
        return matchLen(a.width, b.width, default_auto) and matchLen(a.height, b.height, default_auto);
    }

    inline fn matchSizeDef(a: Size(geometry.DefiniteLength), b: anytype) bool {
        return matchDefLen(a.width, b.width) and matchDefLen(a.height, b.height);
    }

    inline fn matchEdgesLen(a: geometry.Edges(geometry.Length), b: anytype, comptime default_auto: bool) bool {
        return matchLen(a.top, b.top, default_auto) and
            matchLen(a.right, b.right, default_auto) and
            matchLen(a.bottom, b.bottom, default_auto) and
            matchLen(a.left, b.left, default_auto);
    }

    inline fn matchEdgesDef(a: geometry.Edges(geometry.DefiniteLength), b: anytype) bool {
        return matchDefLen(a.top, b.top) and
            matchDefLen(a.right, b.right) and
            matchDefLen(a.bottom, b.bottom) and
            matchDefLen(a.left, b.left);
    }

    inline fn matchEdgesAbs(a: geometry.Edges(geometry.AbsoluteLength), b: anytype) bool {
        return matchAbsLen(a.top, b.top) and
            matchAbsLen(a.right, b.right) and
            matchAbsLen(a.bottom, b.bottom) and
            matchAbsLen(a.left, b.left);
    }

    fn matchesAny(self: *const LayoutStyle, s: anytype, rem_size: Pixels, scale_factor: f32) bool {
        if (self.rem_size != rem_size or self.scale_factor != scale_factor) return false;
        if (self.display != valOr(style_mod.Display, s.display, .block)) return false;
        if (self.position != valOr(style_mod.Position, s.position, .relative)) return false;
        if (self.flex_direction != valOr(style_mod.FlexDirection, s.flex_direction, .row)) return false;
        if (self.flex_wrap != valOr(style_mod.FlexWrap, s.flex_wrap, .no_wrap)) return false;
        if (self.flex_grow != valOr(f32, s.flex_grow, 0)) return false;
        if (self.flex_shrink != valOr(f32, s.flex_shrink, 1)) return false;
        if (!matchSizeLen(self.size, s.size, true)) return false;
        if (self.overflow.x != valOr(style_mod.Overflow, s.overflow.x, .visible) or
            self.overflow.y != valOr(style_mod.Overflow, s.overflow.y, .visible)) return false;
        if (!matchAbsLen(self.scrollbar_width, s.scrollbar_width)) return false;
        if (!matchEdgesLen(self.inset, s.inset, true)) return false;
        if (!matchSizeLen(self.min_size, s.min_size, true)) return false;
        if (!matchSizeLen(self.max_size, s.max_size, true)) return false;
        if (self.aspect_ratio != s.aspect_ratio) return false;
        if (!matchEdgesLen(self.margin, s.margin, false)) return false;
        if (!matchEdgesDef(self.padding, s.padding)) return false;
        if (!matchEdgesAbs(self.border_widths, s.border_widths)) return false;
        if (self.align_items != s.align_items) return false;
        if (self.align_self != s.align_self) return false;
        if (self.align_content != s.align_content) return false;
        if (self.justify_content != s.justify_content) return false;
        if (!matchSizeDef(self.gap, s.gap)) return false;
        if (!matchLen(self.flex_basis, s.flex_basis, true)) return false;
        if (!std.meta.eql(self.grid_rows, s.grid_rows)) return false;
        if (!std.meta.eql(self.grid_cols, s.grid_cols)) return false;
        if (!std.meta.eql(self.grid_location, s.grid_location)) return false;
        return true;
    }

    fn toZafi(self: *const LayoutStyle, allocator: std.mem.Allocator, grid_buffers: *?*GridBuffers) zafi.Style {
        var t = toTaffyCore(self);
        if (self.grid_cols == null and self.grid_rows == null) {
            if (grid_buffers.*) |buf| {
                allocator.destroy(buf);
                grid_buffers.* = null;
            }
            return t;
        }
        const buf = grid_buffers.* orelse blk: {
            const b = allocator.create(GridBuffers) catch oom();
            grid_buffers.* = b;
            break :blk b;
        };
        if (self.grid_cols) |g| {
            t.grid_template_columns = fillGridTemplate(g, &buf.cols_tracks, &buf.cols_comps);
        }
        if (self.grid_rows) |g| {
            t.grid_template_rows = fillGridTemplate(g, &buf.rows_tracks, &buf.rows_comps);
        }
        return t;
    }
};

fn zafiStylesEqualNonGridSlices(a: *const zafi.Style, b: *const zafi.Style) bool {
    inline for (@typeInfo(zafi.Style).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "grid_template_rows") or std.mem.eql(u8, name, "grid_template_columns")) {
            continue;
        } else if (comptime @typeInfo(@TypeOf(@field(a.*, name))) == .pointer) {
            if (@field(a.*, name).len != 0 or @field(b.*, name).len != 0) return false;
        } else {
            if (!std.meta.eql(@field(a.*, name), @field(b.*, name))) return false;
        }
    }
    return true;
}

fn fillGridTemplate(
    t: style_mod.GridTemplate,
    tracks_buf: *[1]zafi.TrackSizingFunction,
    comps_buf: *[1]zafi.GridTemplateComponent,
) []const zafi.GridTemplateComponent {
    const helpers = zafi.style_helpers;
    const min: zafi.MinTrackSizingFunction = switch (t.min_size) {
        .zero => .zero,
        .min_content => .min_content,
        .max_content => .max_content,
    };
    tracks_buf[0] = helpers.minmax(min, .fr(1.0));
    comps_buf[0] = helpers.repeat(t.repeat, tracks_buf);
    return comps_buf;
}

fn toTaffyCore(s: anytype) zafi.Style {
    const rem = s.rem_size;
    const scale = s.scale_factor;
    var t: zafi.Style = .{};
    t.display = switch (s.display) {
        .block => .block,
        .flex => .flex,
        .grid => .grid,
        .none => .none,
    };
    t.overflow = .{ .x = overflow(s.overflow.x), .y = overflow(s.overflow.y) };
    t.scrollbar_width = absPx(s.scrollbar_width, rem, scale);
    t.position = switch (s.position) {
        .relative => .relative,
        .absolute => .absolute,
    };
    t.inset = .{
        .top = lpaFromLength(s.inset.top, rem, scale),
        .right = lpaFromLength(s.inset.right, rem, scale),
        .bottom = lpaFromLength(s.inset.bottom, rem, scale),
        .left = lpaFromLength(s.inset.left, rem, scale),
    };
    t.size = .{ .width = dimFromLength(s.size.width, rem, scale), .height = dimFromLength(s.size.height, rem, scale) };
    t.min_size = .{ .width = lpaFromLength(s.min_size.width, rem, scale), .height = lpaFromLength(s.min_size.height, rem, scale) };
    t.max_size = .{ .width = lpaFromLength(s.max_size.width, rem, scale), .height = lpaFromLength(s.max_size.height, rem, scale) };
    t.aspect_ratio = s.aspect_ratio;
    t.margin = .{
        .top = lpaFromLength(s.margin.top, rem, scale),
        .right = lpaFromLength(s.margin.right, rem, scale),
        .bottom = lpaFromLength(s.margin.bottom, rem, scale),
        .left = lpaFromLength(s.margin.left, rem, scale),
    };
    t.padding = .{
        .top = lpFromDefinite(s.padding.top, rem, scale),
        .right = lpFromDefinite(s.padding.right, rem, scale),
        .bottom = lpFromDefinite(s.padding.bottom, rem, scale),
        .left = lpFromDefinite(s.padding.left, rem, scale),
    };
    t.border = .{
        .top = .length(absPx(s.border_widths.top, rem, scale)),
        .right = .length(absPx(s.border_widths.right, rem, scale)),
        .bottom = .length(absPx(s.border_widths.bottom, rem, scale)),
        .left = .length(absPx(s.border_widths.left, rem, scale)),
    };
    if (s.align_items) |a| t.align_items = alignItems(a);
    if (s.align_self) |a| t.align_self = alignItems(a);
    if (s.align_content) |a| t.align_content = alignContent(a);
    if (s.justify_content) |a| t.justify_content = alignContent(a);
    t.gap = .{ .width = lpFromDefinite(s.gap.width, rem, scale), .height = lpFromDefinite(s.gap.height, rem, scale) };
    t.flex_direction = switch (s.flex_direction) {
        .row => .row,
        .column => .column,
        .row_reverse => .row_reverse,
        .column_reverse => .column_reverse,
    };
    t.flex_wrap = switch (s.flex_wrap) {
        .no_wrap => .no_wrap,
        .wrap => .wrap,
        .wrap_reverse => .wrap_reverse,
    };
    t.flex_basis = dimFromLength(s.flex_basis, rem, scale);
    t.flex_grow = s.flex_grow;
    t.flex_shrink = s.flex_shrink;
    if (s.grid_location) |loc| {
        t.grid_row = .{ .start = gridPlacement(loc.row.start), .end = gridPlacement(loc.row.end) };
        t.grid_column = .{ .start = gridPlacement(loc.column.start), .end = gridPlacement(loc.column.end) };
    }
    return t;
}

fn absPx(l: geometry.AbsoluteLength, rem: Pixels, scale: f32) f32 {
    return l.to_pixels(rem) * scale;
}

fn lpFromDefinite(l: geometry.DefiniteLength, rem: Pixels, scale: f32) zafi.LengthPercentage {
    return switch (l) {
        .absolute => |a| .length(absPx(a, rem, scale)),
        .fraction => |f| .percent(f),
    };
}

fn lpaFromLength(l: geometry.Length, rem: Pixels, scale: f32) zafi.LengthPercentageAuto {
    return switch (l) {
        .auto => .auto(),
        .definite => |d| switch (d) {
            .absolute => |a| .length(absPx(a, rem, scale)),
            .fraction => |f| .percent(f),
        },
    };
}

fn dimFromLength(l: geometry.Length, rem: Pixels, scale: f32) zafi.Dimension {
    return switch (l) {
        .auto => .auto,
        .definite => |d| switch (d) {
            .absolute => |a| .length(absPx(a, rem, scale)),
            .fraction => |f| .percent(f),
        },
    };
}

fn alignItems(a: style_mod.AlignItems) zafi.AlignItems {
    return switch (a) {
        .start => .START,
        .end => .END,
        .flex_start => .FLEX_START,
        .flex_end => .FLEX_END,
        .center => .CENTER,
        .baseline => .BASELINE,
        .stretch => .STRETCH,
    };
}

fn alignContent(a: style_mod.AlignContent) zafi.AlignContent {
    return switch (a) {
        .start => .START,
        .end => .END,
        .flex_start => .FLEX_START,
        .flex_end => .FLEX_END,
        .center => .CENTER,
        .stretch => .STRETCH,
        .space_between => .SPACE_BETWEEN,
        .space_evenly => .SPACE_EVENLY,
        .space_around => .SPACE_AROUND,
    };
}

fn gridTemplate(t: style_mod.GridTemplate, arena: std.mem.Allocator) []const zafi.GridTemplateComponent {
    const helpers = zafi.style_helpers;
    const min: zafi.MinTrackSizingFunction = switch (t.min_size) {
        .zero => .zero,
        .min_content => .min_content,
        .max_content => .max_content,
    };
    const track = arena.alloc(zafi.TrackSizingFunction, 1) catch oom();
    track[0] = helpers.minmax(min, .fr(1.0));
    const comps = arena.alloc(zafi.GridTemplateComponent, 1) catch oom();
    comps[0] = helpers.repeat(t.repeat, track);
    return comps;
}

fn gridPlacement(p: style_mod.GridPlacement) zafi.GridPlacement {
    return switch (p) {
        .line => |l| .from_line_index(l),
        .span => |s| .from_span(s),
        .auto => .auto,
    };
}

/// Converts a GPUI style into a zafi style, in device pixels.
pub fn to_taffy(s: *const Style, rem: Pixels, scale: f32, arena: std.mem.Allocator) zafi.Style {
    const ls = LayoutStyle.fromStyle(s, rem, scale);
    var t = toTaffyCore(&ls);
    if (s.grid_cols) |g| t.grid_template_columns = gridTemplate(g, arena);
    if (s.grid_rows) |g| t.grid_template_rows = gridTemplate(g, arena);
    return t;
}

fn overflow(o: style_mod.Overflow) zafi.Overflow {
    return switch (o) {
        .visible => .visible,
        .clip => .clip,
        .hidden => .hidden,
        .scroll => .scroll,
    };
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

const TestMeasuredLeaf = struct {
    measured_size: Size(Pixels),
    style: Style = .{},
    keyed: bool = true,
    measure_counter: ?*usize = null,
    out_bounds: ?*Bounds(Pixels) = null,
    elem_id: ?@import("element.zig").ElementId = null,

    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    pub fn id(self: *TestMeasuredLeaf) ?@import("element.zig").ElementId {
        return self.elem_id;
    }

    pub fn request_layout(self: *TestMeasuredLeaf, _: ?*const @import("element.zig").GlobalElementId, window: *Window, _: *App) struct { LayoutId, void } {
        const lid = if (self.keyed)
            window.request_keyed_measured_layout(&self.style, self.measured_size, .{ .ctx = self, .func = measure })
        else
            window.request_measured_layout(&self.style, .{ .ctx = self, .func = measure });
        return .{ lid, {} };
    }

    fn measure(ctx: *anyopaque, _: Size(?Pixels), _: Size(AvailableSpace), _: *Window, _: *App) Size(Pixels) {
        const self: *TestMeasuredLeaf = @ptrCast(@alignCast(ctx));
        if (self.measure_counter) |c| c.* += 1;
        return self.measured_size;
    }

    pub fn prepaint(self: *TestMeasuredLeaf, _: ?*const @import("element.zig").GlobalElementId, bounds: Bounds(Pixels), _: *void, _: *Window, _: *App) void {
        if (self.out_bounds) |out| out.* = bounds;
    }

    pub fn paint(_: *TestMeasuredLeaf, _: ?*const @import("element.zig").GlobalElementId, _: Bounds(Pixels), _: *void, _: *void, _: *Window, _: *App) void {}

    fn intoElement(val: TestMeasuredLeaf) @import("element.zig").AnyElement {
        const window_mod = @import("window.zig");
        const p = window_mod.frame_arena().create(TestMeasuredLeaf) catch oom();
        p.* = val;
        return @import("element.zig").AnyElement.new(p);
    }
};

test "LayoutCache reuses LayoutIds across frames, recycles and evicts unrequested nodes, and frees grid tracks with zero leaks" {
    var engine = TaffyLayoutEngine.new(testing.allocator);
    defer engine.deinit();

    // Frame 0: grid container with 2 children.
    var grid_style: Style = .{
        .display = .grid,
        .grid_cols = .{ .repeat = 2, .min_size = .zero },
        .grid_rows = .{ .repeat = 1, .min_size = .min_content },
        .size = .{ .width = .{ .definite = .{ .absolute = .{ .pixels = 100 } } }, .height = .{ .definite = .{ .absolute = .{ .pixels = 40 } } } },
    };
    const child_style: Style = .{};
    const c0_f0 = engine.request_layout(10, &child_style, 16, 1, &.{});
    const c1_f0 = engine.request_layout(11, &child_style, 16, 1, &.{});
    const root_f0 = engine.request_layout(1, &grid_style, 16, 1, &.{ c0_f0, c1_f0 });
    try testing.expectEqual(@as(usize, 3), engine.node_count());
    engine.clear();

    // Frame 1: unchanged request reuses exact LayoutIds and skips style/children mutation.
    const c0_f1 = engine.request_layout(10, &child_style, 16, 1, &.{});
    const c1_f1 = engine.request_layout(11, &child_style, 16, 1, &.{});
    const root_f1 = engine.request_layout(1, &grid_style, 16, 1, &.{ c0_f1, c1_f1 });
    try testing.expectEqual(c0_f0, c0_f1);
    try testing.expectEqual(c1_f0, c1_f1);
    try testing.expectEqual(root_f0, root_f1);
    try testing.expectEqual(@as(usize, 3), engine.node_count());
    engine.clear();

    // Frame 2: drop grid tracks and omit child c1 -> c1 moves to free_nodes (still counted until next clear).
    grid_style.display = .flex;
    grid_style.grid_cols = null;
    grid_style.grid_rows = null;
    const c0_f2 = engine.request_layout(10, &child_style, 16, 1, &.{});
    const root_f2 = engine.request_layout(1, &grid_style, 16, 1, &.{c0_f2});
    try testing.expectEqual(c0_f0, c0_f2);
    try testing.expectEqual(root_f0, root_f2);
    try testing.expect(engine.cache.nodes.get(root_f2).?.grid_buffers == null);
    engine.clear();
    try testing.expectEqual(@as(usize, 1), engine.cache.free_nodes.items.len);
    try testing.expectEqual(@as(usize, 3), engine.node_count());

    // Frame 3: c1 still unrequested -> evicted from zafi.Tree at end of frame.
    const c0_f3 = engine.request_layout(10, &child_style, 16, 1, &.{});
    const root_f3 = engine.request_layout(1, &grid_style, 16, 1, &.{c0_f3});
    try testing.expectEqual(c0_f0, c0_f3);
    try testing.expectEqual(root_f0, root_f3);
    engine.clear();
    try testing.expectEqual(@as(usize, 0), engine.cache.free_nodes.items.len);
    try testing.expectEqual(@as(usize, 2), engine.node_count());
}

test "stretch_auto_size_to_fill restores real style when node is reused" {
    var engine = TaffyLayoutEngine.new(testing.allocator);
    defer engine.deinit();

    const auto_style: Style = .{};
    const id0 = engine.request_layout(0, &auto_style, 16, 1, &.{});
    engine.stretch_auto_size_to_fill(id0, .{ .width = 300, .height = 200 }, 1);
    const stretched = try engine.taffy.style_of(id0);
    try testing.expect(!stretched.size.width.is_auto());
    try testing.expect(engine.cache.nodes.get(id0).?.stretched);
    engine.clear();

    const id1 = engine.request_layout(0, &auto_style, 16, 1, &.{});
    try testing.expectEqual(id0, id1);
    const restored = try engine.taffy.style_of(id1);
    try testing.expect(restored.size.width.is_auto());
    try testing.expect(restored.size.height.is_auto());
    try testing.expect(!engine.cache.nodes.get(id1).?.stretched);
    engine.clear();
}

test "measured leaf is measured again only when its key changes, while unkeyed measures every frame" {
    const TestAppContext = @import("app/test_context.zig").TestAppContext;
    const div_mod = @import("elements/div.zig");
    const app_mod = @import("app.zig");

    const View = struct {
        leaf_size: Size(Pixels) = .{ .width = 10, .height = 10 },
        keyed: bool = true,
        measures: usize = 0,
        bounds: Bounds(Pixels) = .{},

        pub fn render(self: *@This(), _: *Window, _: *app_mod.Context(@This())) *div_mod.Div {
            return div_mod.div().flex().child(TestMeasuredLeaf.intoElement(.{
                .measured_size = self.leaf_size,
                .keyed = self.keyed,
                .measure_counter = &self.measures,
                .out_bounds = &self.bounds,
            }));
        }

        fn build(_: *Window, app: *App) app_mod.Entity(@This()) {
            return app.new(@This(){});
        }
        fn touch(_: *@This(), cx: *app_mod.Context(@This())) void {
            cx.notify();
        }
        fn set_size(self: *@This(), s: Size(Pixels), cx: *app_mod.Context(@This())) void {
            self.leaf_size = s;
            cx.notify();
        }
        fn set_keyed(self: *@This(), k: bool, cx: *app_mod.Context(@This())) void {
            self.keyed = k;
            cx.notify();
        }
    };

    var cx = TestAppContext.build(0);
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(View.build);
    const initial_nodes = vcx.window.layout_node_count();
    try testing.expect(view.read(cx.app).measures > 0);
    try testing.expectEqual(@as(f32, 10), view.read(cx.app).bounds.size.width);

    // Unchanged redraws skip measurement and keep node count stable.
    for (0..3) |_| {
        view.update(cx.app, View.touch, .{});
        cx.run_until_parked();
        try testing.expectEqual(@as(usize, 0), vcx.window.last_frame_measure_calls());
        try testing.expectEqual(initial_nodes, vcx.window.layout_node_count());
        try testing.expectEqual(@as(f32, 10), view.read(cx.app).bounds.size.width);
    }

    // Changing the key re-measures once, then steady-state skips again.
    view.update(cx.app, View.set_size, .{Size(Pixels){ .width = 45, .height = 22 }});
    cx.run_until_parked();
    try testing.expect(vcx.window.last_frame_measure_calls() > 0);
    try testing.expectEqual(@as(f32, 45), view.read(cx.app).bounds.size.width);
    try testing.expectEqual(@as(f32, 22), view.read(cx.app).bounds.size.height);

    view.update(cx.app, View.touch, .{});
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 0), vcx.window.last_frame_measure_calls());

    // Scale factor change clears the layout cache and re-measures cleanly.
    vcx.simulate_scale_factor_change(2.0);
    try testing.expect(vcx.window.last_frame_measure_calls() > 0);
    try testing.expectEqual(@as(f32, 45), view.read(cx.app).bounds.size.width);
    view.update(cx.app, View.touch, .{});
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 0), vcx.window.last_frame_measure_calls());

    // Unkeyed request_measured_layout always measures every frame.
    view.update(cx.app, View.set_keyed, .{false});
    cx.run_until_parked();
    try testing.expect(vcx.window.last_frame_measure_calls() > 0);
    view.update(cx.app, View.touch, .{});
    cx.run_until_parked();
    try testing.expect(vcx.window.last_frame_measure_calls() > 0);
}

test "persistent layout invalidates on style, rem_size, display toggle, children change, and unrequested parent" {
    const TestAppContext = @import("app/test_context.zig").TestAppContext;
    const div_mod = @import("elements/div.zig");
    const app_mod = @import("app.zig");

    const View = struct {
        const Self = @This();
        mode: enum { hidden, shown, grid_mode, detached_root } = .hidden,
        rem_px: f32 = 16,
        child_bounds: Bounds(Pixels) = .{},
        root_bounds: Bounds(Pixels) = .{},

        pub fn render(self: *Self, window: *Window, cx: *app_mod.Context(Self)) *div_mod.Div {
            window.set_rem_size(self.rem_px);

            return switch (self.mode) {
                .hidden => blk: {
                    var child = div_mod.div().w(geometry.rems(2)).h(geometry.px(20));
                    child.interactivity.base_style.display = .none;
                    break :blk div_mod.div().flex().on_children_prepainted(cx.listener(record_child)).child(child);
                },
                .shown => div_mod.div().flex().on_children_prepainted(cx.listener(record_child)).child(
                    div_mod.div().w(geometry.rems(2)).h(geometry.px(20)),
                ),
                .grid_mode => div_mod.div().grid().grid_cols(2).grid_rows(2).w(geometry.px(100)).h(geometry.px(80))
                    .on_children_prepainted(cx.listener(record_child))
                    .child(div_mod.div().h(geometry.px(10)))
                    .child(div_mod.div().h(geometry.px(10)))
                    .child(div_mod.div().h(geometry.px(10)))
                    .child(div_mod.div().h(geometry.px(10))),
                .detached_root => div_mod.div().p(geometry.px(15)).on_children_prepainted(cx.listener(record_root)).child(
                    div_mod.div().size(geometry.px(30)),
                ),
            };
        }

        fn record_child(self: *Self, ev: *const div_mod.PrepaintedChildren, _: *Window, _: *app_mod.Context(Self)) void {
            if (ev.bounds.len > 0) self.child_bounds = ev.bounds[0];
        }

        fn record_root(self: *Self, ev: *const div_mod.PrepaintedChildren, _: *Window, _: *app_mod.Context(Self)) void {
            if (ev.bounds.len > 0) self.root_bounds = ev.bounds[0];
        }

        fn build(_: *Window, app: *App) app_mod.Entity(@This()) {
            return app.new(@This(){});
        }
        fn set(self: *@This(), m: @TypeOf(self.mode), r: f32, cx: *app_mod.Context(@This())) void {
            self.mode = m;
            self.rem_px = r;
            cx.notify();
        }
    };

    var cx = TestAppContext.build(0);
    defer cx.deinit();
    const view, _ = cx.add_window_view(View.build);
    try testing.expectEqual(@as(f32, 0), view.read(cx.app).child_bounds.size.width);

    view.update(cx.app, View.set, .{ .shown, 16 });
    cx.run_until_parked();
    try testing.expectEqual(@as(f32, 32), view.read(cx.app).child_bounds.size.width);
    try testing.expectEqual(@as(f32, 20), view.read(cx.app).child_bounds.size.height);

    // Changing rem_size resolves rems again.
    view.update(cx.app, View.set, .{ .shown, 13 });
    cx.run_until_parked();
    try testing.expectEqual(@as(f32, 26), view.read(cx.app).child_bounds.size.width);

    // Switching to grid with 4 children, then back to 1 child, then detached_root.
    view.update(cx.app, View.set, .{ .grid_mode, 16 });
    cx.run_until_parked();
    try testing.expectEqual(@as(f32, 50), view.read(cx.app).child_bounds.size.width);

    view.update(cx.app, View.set, .{ .detached_root, 16 });
    cx.run_until_parked();
    try testing.expectEqual(@as(f32, 15), view.read(cx.app).root_bounds.origin.x);
    try testing.expectEqual(@as(f32, 30), view.read(cx.app).root_bounds.size.width);

    view.update(cx.app, View.set, .{ .hidden, 16 });
    cx.run_until_parked();
    try testing.expectEqual(@as(f32, 0), view.read(cx.app).child_bounds.size.width);
}

test "evicted nodes do not accumulate when element ids churn every frame" {
    const TestAppContext = @import("app/test_context.zig").TestAppContext;
    const div_mod = @import("elements/div.zig");
    const app_mod = @import("app.zig");

    const View = struct {
        frame_ix: usize = 0,

        pub fn render(self: *@This(), window: *Window, _: *app_mod.Context(@This())) *div_mod.Div {
            var root = div_mod.div().grid().grid_cols(2).grid_rows(2).size_full();
            for (0..4) |i| {
                const label = @import("window.zig").format("item-{d}-{d}", .{ self.frame_ix, i });
                root = root.child(div_mod.div().id(label).w(geometry.px(40)).h(geometry.px(20)));
            }
            _ = window;
            return root;
        }

        fn build(_: *Window, app: *App) app_mod.Entity(@This()) {
            return app.new(@This(){});
        }

        fn churn(self: *@This(), cx: *app_mod.Context(@This())) void {
            self.frame_ix += 1;
            cx.notify();
        }
    };

    var cx = TestAppContext.build(0);
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(View.build);
    const base_count = vcx.window.layout_node_count();

    for (0..10) |_| {
        view.update(cx.app, View.churn, .{});
        cx.run_until_parked();
    }
    // At most 1 previous frame's nodes sit in free_nodes; node count stays bounded.
    try testing.expect(vcx.window.layout_node_count() <= base_count * 2);
}
