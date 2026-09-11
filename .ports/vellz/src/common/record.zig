//! Port of vello_common record.rs (Apache-2.0 OR MIT).
//!
//! Recording rendering commands into a scene-graph-like structure that both
//! renderers consume: Vello CPU buckets the recorded draws by strip row, Vello
//! GPU schedules draws and layer operations across intermediate textures.
//! Recording up front lets filter layers request pixmaps that may be larger
//! than the viewport and lets each renderer plan its own work.
//!
//! # Ownership and allocator contract
//!
//! - `CommandRecorder(D)` owns every allocation it creates: the `nodes`,
//!   `draws`, `layers`, `filter_layers`, and `layer_stack` vectors plus every
//!   `RecordedLayer.nodes` list. `deinit(allocator)` releases all of them.
//! - `LayerProps.mask` and the `FilterData` passed to `pushLayer` are owned
//!   handles (`Mask` and `Filter` are reference-counted). A successful
//!   `pushLayer` takes ownership; clone (`Mask.clone`, `Filter.clone`) before
//!   pushing the same resource twice. On `error.OutOfMemory` nothing is
//!   recorded and ownership stays with the caller.
//! - `reset` takes the allocator because dropping recorded layers must release
//!   their masks and filter graphs (upstream relies on `Drop`).
//! - A `RecordedLayer` stored in the recorder must not be copied out: its node
//!   list and owned handles belong to the recorder.
//! - The draw type `D` must not own heap memory: Zig has no destructor the
//!   recorder could run over `draws` entries. The recorded draw types in this
//!   repository are plain values plus borrowed handles.
//!
//! # `Drawable`
//!
//! Zig has no traits, so `Drawable` is comptime duck typing; see
//! `Drawable.assertImpl` for the required method set and `Drawable.blendMode`
//! for the accepted return shapes. `pushDraw` recomputes the active layer's
//! bounding box through `Drawable.bbox` (using `strip.stripBbox` for the
//! repository's `RecordedFill`).
//!
//! # Errors
//!
//! Allocation failure propagates as `error.OutOfMemory`. Invalid usage that
//! upstream expresses as a panic becomes a typed error: `popLayer` on an empty
//! layer stack returns `error.NoActiveLayer` (upstream unwraps a `None`).

const std = @import("std");
const filter_mod = @import("filter.zig");
const geometry = @import("geometry.zig");
const mask_mod = @import("mask.zig");
const peniko = @import("../peniko/root.zig");
const strip_mod = @import("strip.zig");
const util = @import("util.zig");

const FilterData = filter_mod.FilterData;
const FilterLayerPlacement = filter_mod.FilterLayerPlacement;
const Mask = mask_mod.Mask;
const BlendMode = peniko.BlendMode;
const RectU16 = geometry.RectU16;
const SizeU16 = geometry.SizeU16;
const Strip = strip_mod.Strip;

/// A half-open index range `[start, end)`, replacing `core::ops::Range<T>`.
///
/// The upstream `Node.draws` range is `Range<u32>` and
/// `LayerClip.strip_range` is `Range<usize>`; both instantiate this type.
pub fn Range(comptime T: type) type {
    return struct {
        /// First index, inclusive.
        start: T,
        /// End index, exclusive.
        end: T,

        const Self = @This();

        /// Create a new range.
        pub fn new(start: T, end: T) Self {
            return .{ .start = start, .end = end };
        }

        /// The number of indices in the range.
        pub fn len(self: Self) T {
            return self.end - self.start;
        }

        /// Whether the range contains no indices.
        pub fn isEmpty(self: Self) bool {
            return self.start >= self.end;
        }
    };
}

/// A drawable object that can report its bounding box.
///
/// This struct is the comptime duck-typed replacement for upstream's
/// `Drawable` trait; consumers are generic over the concrete `D` and nothing
/// is boxed or dynamically dispatched.
pub const Drawable = struct {
    /// Check at compile time that `D` declares the drawable method set.
    ///
    /// `pushDraw` calls this, so a missing method is reported as a named
    /// compile error instead of a confusing method-not-found error in generic
    /// code.
    pub fn assertImpl(comptime D: type) void {
        if (!@hasDecl(D, "bbox")) {
            @compileError(@typeName(D) ++
                " does not implement Drawable.bbox(self, strips: []const Strip) ?RectU16");
        }
        if (!@hasDecl(D, "blendMode")) {
            @compileError(@typeName(D) ++ " does not implement Drawable.blendMode(self)");
        }
    }

    /// Call `Drawable::bbox`, enforcing its return type.
    pub fn bbox(draw: anytype, strips: []const Strip) ?RectU16 {
        const result = draw.bbox(strips);
        if (@TypeOf(result) != ?RectU16) {
            @compileError("Drawable.bbox must return ?RectU16, got " ++ @typeName(@TypeOf(result)));
        }
        return result;
    }

    /// Call `Drawable::blend_mode` and normalize the accepted return shapes.
    ///
    /// Upstream returns `Option<&BlendMode>`; this port accepts `BlendMode`,
    /// `?BlendMode`, `*const BlendMode`, and `?*const BlendMode` so both the
    /// plain-value interface and `cpu/record.zig`'s `RecordedFill` fit.
    /// `null` means "no directly applied blend mode", which `pushDraw` treats
    /// like the default blend mode.
    pub fn blendMode(draw: anytype) ?BlendMode {
        const result = draw.blendMode();
        return switch (@TypeOf(result)) {
            BlendMode => result,
            ?BlendMode => result,
            *const BlendMode => result.*,
            ?*const BlendMode => if (result) |ptr| ptr.* else null,
            else => @compileError(
                "Drawable.blendMode must return BlendMode, ?BlendMode, *const BlendMode, or ?*const BlendMode, got " ++
                    @typeName(@TypeOf(result)),
            ),
        };
    }
};

/// A node in the recorded render graph.
pub const Node = struct {
    /// A contiguous (possibly empty) batch of draw commands indexing
    /// `CommandRecorder.draws`.
    draws: Range(u32),
    /// An optional layer composition, invoked after `draws`.
    layer: ?u32,

    /// Return the draw commands referenced by this node.
    pub fn drawsIn(self: Node, draws: anytype) []const std.meta.Elem(@TypeOf(draws)) {
        const D = std.meta.Elem(@TypeOf(draws));
        const all: []const D = draws[0..];
        return all[self.draws.start..self.draws.end];
    }
};

/// Metadata and child nodes for a recorded layer.
pub const RecordedLayer = struct {
    /// Properties of the layer.
    props: LayerProps,
    /// The child nodes of the layer.
    ///
    /// Upstream uses `SmallVec<[Node; 2]>`; this port uses an unmanaged
    /// `std.ArrayList` whose storage is owned (and released) by the recorder.
    nodes: std.ArrayList(Node),
    /// The kind of recorded layer.
    kind: RecordedLayerKind,
    /// Nesting depth of the layer.
    depth: usize,
    /// Tile-aligned bounding box of the layer.
    ///
    /// **IMPORTANT**: This field only indicates the bounding box of visible
    /// contents directly in this layer. It does not mean that any child layer
    /// is also strictly contained within those bounds; for a filter layer it
    /// is the (possibly padded) pixmap bounding box.
    bbox: RectU16,

    /// Create a regular layer (upstream `RecordedLayer::regular`).
    fn regular(props: LayerProps, depth: usize) RecordedLayer {
        return .{
            .props = props,
            .nodes = .empty,
            .kind = .regular,
            .depth = depth,
            // Will be initialized once `popLayer` runs.
            .bbox = RectU16.ZERO,
        };
    }

    /// Create a filter layer (upstream `RecordedLayer::filter`).
    fn filter(props: LayerProps, filter_plan: FilterData, depth: usize) RecordedLayer {
        return .{
            .props = props,
            .nodes = .empty,
            .kind = .{
                .filter = .{
                    .filter_data = filter_plan,
                    // Will be initialized once `popLayer` runs.
                    .placement = FilterLayerPlacement.EMPTY,
                },
            },
            .depth = depth,
            // Will be initialized once `popLayer` runs.
            .bbox = RectU16.ZERO,
        };
    }

    /// Release the layer's owned resources: its node list and, when present,
    /// the mask handle and the filter graph.
    ///
    /// The recorder calls this from `deinit`/`reset`; a `RecordedLayer` must
    /// not be deinitialized independently while it is still stored.
    pub fn deinit(self: *RecordedLayer, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        if (self.props.mask) |mask| mask.deinit(allocator);
        self.props.mask = null;
        switch (self.kind) {
            .regular => {},
            .filter => |*filter_kind| filter_kind.filter_data.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Properties for a recorded layer.
pub const LayerProps = struct {
    /// The default properties: normal blend, fully opaque, no mask, no clip.
    pub const default: LayerProps = .{
        .blend_mode = BlendMode.default,
        .opacity = 1.0,
        .mask = null,
        .clip_path = null,
    };

    /// Blend mode used when compositing the layer.
    blend_mode: BlendMode,
    /// Opacity applied when compositing the layer.
    opacity: f32,
    /// Optional mask applied when compositing the layer.
    ///
    /// Owned handle: on a successful `pushLayer` ownership transfers to the
    /// recorder, which releases it in `deinit`/`reset`.
    mask: ?Mask,
    /// Optional clip path applied when compositing the layer.
    clip_path: ?LayerClip,
};

/// Clip path associated with a recorded layer.
pub const LayerClip = struct {
    /// Range of strips representing the clip path.
    strip_range: Range(usize),
    /// Index of the thread-local strip storage containing the strips.
    thread_idx: u8,
    /// Tile-aligned bounds of the clip path.
    bbox: RectU16,
};

/// Additional metadata for regular and filter layers.
pub const RecordedLayerKind = union(enum) {
    /// A regular layer.
    regular,
    /// A filter layer.
    filter: struct {
        /// Static data about the filter itself.
        filter_data: FilterData,
        /// Data about how to place the filter layer, which can only be
        /// determined once its contents have been recorded.
        placement: FilterLayerPlacement,
    },
};

/// Kind of layer returned by [`CommandRecorder.popLayer`].
pub const PoppedLayer = enum {
    /// A regular layer.
    regular,
    /// A filter layer.
    filter,
};

/// Errors from `popLayer`.
///
/// Upstream panics (`Option::unwrap`) when popping without an open layer;
/// this port returns a typed error.
pub const PopLayerError = error{NoActiveLayer};

/// A layer that has been pushed but not yet popped.
const OpenLayer = struct {
    id: u32,
    /// The bounding box of the contents recorded into this layer.
    bbox: RectU16,
    parent_layer: ?u32,
};

/// Recorder for a scene description.
///
/// Upstream calls this `CommandRecorder` as well (a rename is pending
/// upstream). All public fields mirror upstream field names; see the
/// file-level ownership notes.
pub fn CommandRecorder(comptime D: type) type {
    return struct {
        const Self = @This();

        /// Tile-aligned dimensions of the root scene.
        scene_size: SizeU16 = SizeU16.ZERO,
        /// The nodes of the root layer.
        nodes: std.ArrayList(Node) = .empty,
        /// Flat storage for all draw commands that are part of the recording.
        draws: std.ArrayList(D) = .empty,
        /// Data about recorded layers, indexed by their ID.
        layers: std.ArrayList(RecordedLayer) = .empty,
        /// IDs of recorded filter layers in creation order.
        filter_layers: std.ArrayList(u32) = .empty,
        /// Whether the root is the target of a non-default blending operation.
        root_is_blend_target: bool = false,
        /// Maximum layer depth across the whole layer graph.
        max_layer_depth: usize = 0,
        /// The largest dimensions of any recorded layer.
        largest_layer_size: ?SizeU16 = null,
        /// The largest dimensions of any recorded filter layer.
        largest_filter_layer_size: ?SizeU16 = null,
        /// Whether there exists at least one layer that uses a non-default
        /// blend mode.
        has_non_default_blend: bool = false,
        /// The layer whose command stream is currently the base.
        ///
        /// This is `null` if there is no active layer and we are recording
        /// into the root layer instead.
        active_layer: ?u32 = null,
        /// Stack of currently pushed layers.
        layer_stack: std.ArrayList(OpenLayer) = .empty,

        /// Create a new command recorder for a `width` x `height` scene.
        ///
        /// Upstream also has a `Default` impl; the field defaults above play
        /// that role, and `new` is the only constructor consumers need.
        pub fn new(width: u16, height: u16) Self {
            return .{ .scene_size = snappedSceneSize(width, height) };
        }

        /// Release every heap allocation owned by the recorder, including the
        /// masks and filter graphs of recorded layers.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.releaseLayers(allocator);
            self.releaseDraws(allocator);
            self.nodes.deinit(allocator);
            self.draws.deinit(allocator);
            self.layers.deinit(allocator);
            self.filter_layers.deinit(allocator);
            self.layer_stack.deinit(allocator);
            self.* = undefined;
        }

        /// Whether any layers are currently open.
        pub fn hasLayers(self: *const Self) bool {
            return self.layer_stack.items.len != 0;
        }

        /// Reset the command recorder for a new scene.
        ///
        /// Diverges from upstream (`fn reset(&mut self, width, height)`) by
        /// taking the allocator: recorded layers own masks and filter graphs
        /// that must be released here, whereas upstream relies on `Drop`.
        /// Open layers are dropped exactly like upstream's `Vec::clear`.
        pub fn reset(self: *Self, allocator: std.mem.Allocator, width: u16, height: u16) void {
            self.releaseLayers(allocator);
            self.releaseDraws(allocator);
            self.scene_size = snappedSceneSize(width, height);
            self.nodes.clearRetainingCapacity();
            self.draws.clearRetainingCapacity();
            self.layers.clearRetainingCapacity();
            self.filter_layers.clearRetainingCapacity();
            self.root_is_blend_target = false;
            self.max_layer_depth = 0;
            self.largest_layer_size = null;
            self.largest_filter_layer_size = null;
            self.has_non_default_blend = false;
            self.active_layer = null;
            self.layer_stack.clearRetainingCapacity();
        }

        /// Push a new layer.
        ///
        /// `filter_plan` selects a regular layer (`null`) or a filter layer.
        /// On success the recorder owns `props.mask` and `filter_plan`; on
        /// `error.OutOfMemory` nothing is recorded and the caller keeps
        /// ownership of both.
        pub fn pushLayer(
            self: *Self,
            allocator: std.mem.Allocator,
            props: LayerProps,
            filter_plan: ?FilterData,
        ) std.mem.Allocator.Error!void {
            if (filter_plan) |plan| {
                try self.pushFilterLayer(allocator, props, plan);
            } else {
                try self.pushRegularLayer(allocator, props);
            }
        }

        fn pushRegularLayer(
            self: *Self,
            allocator: std.mem.Allocator,
            props: LayerProps,
        ) std.mem.Allocator.Error!void {
            const depth = self.layer_stack.items.len + 1;
            _ = try self.pushRecordedLayer(allocator, RecordedLayer.regular(props, depth));
        }

        fn pushFilterLayer(
            self: *Self,
            allocator: std.mem.Allocator,
            props: LayerProps,
            filter_plan: FilterData,
        ) std.mem.Allocator.Error!void {
            const depth = self.layer_stack.items.len + 1;
            _ = try self.pushRecordedLayer(allocator, RecordedLayer.filter(props, filter_plan, depth));
        }

        /// Push an already-constructed layer (upstream `push_recorded_layer`,
        /// which is private there as well).
        ///
        /// Every fallible append is reserved before any observable state
        /// changes, so an allocation failure leaves the recorder exactly as it
        /// was and the caller still owns the layer's mask/filter handles.
        fn pushRecordedLayer(
            self: *Self,
            allocator: std.mem.Allocator,
            layer: RecordedLayer,
        ) std.mem.Allocator.Error!u32 {
            const parent_layer = self.active_layer;
            const is_filter = std.meta.activeTag(layer.kind) == .filter;

            try self.layers.ensureUnusedCapacity(allocator, 1);
            try self.layer_stack.ensureUnusedCapacity(allocator, 1);
            if (is_filter) try self.filter_layers.ensureUnusedCapacity(allocator, 1);
            if (!self.canReuseLayerNode()) {
                try self.currentNodeList().ensureUnusedCapacity(allocator, 1);
            }

            self.max_layer_depth = @max(self.max_layer_depth, layer.depth);
            if (!isDefaultBlendMode(layer.props.blend_mode)) {
                self.has_non_default_blend = true;
                if (parent_layer == null) self.root_is_blend_target = true;
            }

            const id: u32 = @truncate(self.layers.items.len);
            self.layers.appendAssumeCapacity(layer);
            self.pushLayerNode(id);
            self.active_layer = id;
            self.layer_stack.appendAssumeCapacity(.{
                .id = id,
                // Will be populated as we record commands.
                .bbox = RectU16.INVERTED,
                .parent_layer = parent_layer,
            });
            if (is_filter) self.filter_layers.appendAssumeCapacity(id);

            return id;
        }

        /// Pop the currently active layer.
        ///
        /// Returns `error.NoActiveLayer` when no layer is open (upstream
        /// panics on the `unwrap`).
        pub fn popLayer(self: *Self) PopLayerError!PoppedLayer {
            const open_layer = self.layer_stack.pop() orelse return error.NoActiveLayer;
            const recorded_layer = &self.layers.items[open_layer.id];

            var popped: PoppedLayer = undefined;
            var bbox_in_parent: RectU16 = undefined;

            switch (recorded_layer.kind) {
                .regular => {
                    var bbox = open_layer.bbox;

                    // Turn the potentially still-inverted bbox into a
                    // zero-sized one.
                    if (bbox.isEmpty()) bbox = RectU16.ZERO;

                    if (recorded_layer.props.clip_path) |clip_path| {
                        bbox = bbox.intersect(clip_path.bbox);
                    }

                    recorded_layer.bbox = bbox;

                    const layer_size = bbox.toSizeU16();
                    self.largest_layer_size = if (self.largest_layer_size) |current|
                        current.max(layer_size)
                    else
                        layer_size;

                    popped = .regular;
                    bbox_in_parent = bbox;
                },
                .filter => |*filter_kind| {
                    filter_kind.placement = FilterLayerPlacement.new(
                        open_layer.bbox,
                        &filter_kind.filter_data,
                    );
                    recorded_layer.bbox = filter_kind.placement.pixmap_bbox;

                    const filter_size = filter_kind.placement.pixmap_bbox.toSizeU16();
                    self.largest_layer_size = if (self.largest_layer_size) |current|
                        current.max(filter_size)
                    else
                        filter_size;
                    self.largest_filter_layer_size = if (self.largest_filter_layer_size) |current|
                        current.max(filter_size)
                    else
                        filter_size;

                    popped = .filter;
                    bbox_in_parent = filter_kind.placement.dest_bbox;
                },
            }

            // Update the parent bbox as well.
            self.active_layer = open_layer.parent_layer;
            self.recordBbox(bbox_in_parent);

            return popped;
        }

        /// Push a draw command.
        ///
        /// On `error.OutOfMemory` nothing is recorded (the draw, its node, and
        /// the layer bounding box are all committed only after every fallible
        /// reservation succeeded). `draw` must be a `Drawable`; see the
        /// file-level `Drawable` note.
        pub fn pushDraw(
            self: *Self,
            allocator: std.mem.Allocator,
            draw: D,
            strips: []const Strip,
        ) std.mem.Allocator.Error!void {
            Drawable.assertImpl(D);

            const draw_idx: u32 = @truncate(self.draws.items.len);

            // Reserve all fallible appends before mutating observable state.
            try self.draws.ensureUnusedCapacity(allocator, 1);
            if (!self.canAppendDrawToCurrentNode(draw_idx)) {
                try self.currentNodeList().ensureUnusedCapacity(allocator, 1);
            }

            if (self.active_layer == null) {
                if (Drawable.blendMode(draw)) |blend_mode| {
                    if (!isDefaultBlendMode(blend_mode)) self.root_is_blend_target = true;
                }
            }

            if (self.layer_stack.items.len > 0) {
                self.recordBbox(Drawable.bbox(draw, strips));
            }

            self.draws.appendAssumeCapacity(draw);

            const node_list = self.currentNodeList();
            if (node_list.items.len > 0) {
                const last = &node_list.items[node_list.items.len - 1];
                if (last.layer == null and last.draws.end == draw_idx) {
                    last.draws.end += 1;
                    return;
                }
            }
            node_list.appendAssumeCapacity(.{
                .draws = .{ .start = draw_idx, .end = draw_idx + 1 },
                .layer = null,
            });
        }

        /// The node list of the currently active layer (or the root list).
        fn currentNodeList(self: *Self) *std.ArrayList(Node) {
            if (self.active_layer) |id| {
                return &self.layers.items[id].nodes;
            }
            return &self.nodes;
        }

        /// The nodes of the currently active layer (or the root nodes).
        fn currentNodeItems(self: *const Self) []Node {
            if (self.active_layer) |id| {
                return self.layers.items[id].nodes.items;
            }
            return self.nodes.items;
        }

        /// Whether `pushLayerNode` can reuse the current last node instead of
        /// appending one (upstream's `Some(node) if node.layer.is_none()`).
        fn canReuseLayerNode(self: *const Self) bool {
            const nodes = self.currentNodeItems();
            if (nodes.len == 0) return false;
            return nodes[nodes.len - 1].layer == null;
        }

        /// Whether `pushDraw` can extend the current last node instead of
        /// pushing a new one (upstream's `Some(node) if node.layer.is_none()
        /// && node.draws.end == draw_idx`).
        fn canAppendDrawToCurrentNode(self: *const Self, draw_idx: u32) bool {
            const nodes = self.currentNodeItems();
            if (nodes.len == 0) return false;
            const last = nodes[nodes.len - 1];
            return last.layer == null and last.draws.end == draw_idx;
        }

        /// Append a node to the currently active node list. The caller must
        /// have reserved capacity for one more node (`pushDraw` is
        /// transactional and reserves up front).
        fn pushNode(self: *Self, node: Node) void {
            if (self.active_layer) |id| {
                self.layers.items[id].nodes.appendAssumeCapacity(node);
            } else {
                self.nodes.appendAssumeCapacity(node);
            }
        }

        /// Attach `layer_id` to the current last node if it has no layer yet,
        /// otherwise push a new empty node pointing at the layer (upstream
        /// `push_layer_node`). The caller must have reserved capacity when a
        /// new node is required.
        fn pushLayerNode(self: *Self, layer_id: u32) void {
            const draw_idx: u32 = @truncate(self.draws.items.len);

            const node_list = self.currentNodeList();
            if (node_list.items.len > 0) {
                const last = &node_list.items[node_list.items.len - 1];
                if (last.layer == null) {
                    last.layer = layer_id;
                    return;
                }
            }

            self.pushNode(.{
                .draws = .{ .start = draw_idx, .end = draw_idx },
                .layer = layer_id,
            });
        }

        /// Union a non-empty bounding box into the open layer's bbox
        /// (upstream `record_bbox`; the closure argument is collapsed into a
        /// plain value because bbox computation has no side effects here).
        fn recordBbox(self: *Self, bbox: ?RectU16) void {
            const layers = self.layer_stack.items;
            if (layers.len == 0) return;

            const b = bbox orelse return;
            if (b.isEmpty()) return;

            layers[layers.len - 1].bbox.unionWith(b);
        }

        /// Release the resources of every recorded layer.
        /// Release resources owned by recorded draw values.
        ///
        /// The recorded draw type may declare `deinit(self, allocator)`; when
        /// it does (e.g. `vello_cpu`'s `RecordedFill`, which owns a mask
        /// handle), the recorder releases those resources on `reset` and
        /// `deinit`, matching upstream's `Drop` behavior. Draw types without
        /// the method (e.g. GPU draw records in this port) are plain values.
        fn releaseDraws(self: *Self, allocator: std.mem.Allocator) void {
            if (@hasDecl(D, "deinit")) {
                for (self.draws.items) |*draw| draw.deinit(allocator);
            }
            self.draws.clearRetainingCapacity();
        }

        fn releaseLayers(self: *Self, allocator: std.mem.Allocator) void {
            for (self.layers.items) |*layer| layer.deinit(allocator);
        }
    };
}

/// Snap the scene dimensions up to whole tile coordinates (upstream
/// `snapped_scene_size`).
pub fn snappedSceneSize(width: u16, height: u16) SizeU16 {
    return util.RectExt.snapToTileCoordinates(RectU16.new(0, 0, width, height)).toSizeU16();
}

/// Upstream `blend_mode == BlendMode::default()` (Zig structs do not support
/// `==`).
fn isDefaultBlendMode(blend_mode: BlendMode) bool {
    return blend_mode.mix == .normal and blend_mode.compose == .src_over;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const filter_effects = @import("filter_effects.zig");
const kurbo = @import("../kurbo/root.zig");
const tile_mod = @import("tile.zig");

const Filter = filter_effects.Filter;
const PaddingU16 = geometry.PaddingU16;
const Tile = tile_mod.Tile;

const DEFAULT_SIZE: u16 = 10;

const TestDraw = struct {
    pub fn bbox(_: TestDraw, _: []const Strip) ?RectU16 {
        return RectU16.new(0, 0, 64, 4);
    }

    pub fn blendMode(_: TestDraw) ?*const BlendMode {
        return null;
    }
};

const EmptyDraw = struct {
    pub fn bbox(_: EmptyDraw, _: []const Strip) ?RectU16 {
        return null;
    }

    pub fn blendMode(_: EmptyDraw) ?*const BlendMode {
        return null;
    }
};

const BlendedDraw = struct {
    blend_mode: BlendMode,

    pub fn bbox(_: BlendedDraw, _: []const Strip) ?RectU16 {
        return RectU16.new(0, 0, 64, 4);
    }

    pub fn blendMode(self: *const BlendedDraw) ?*const BlendMode {
        return &self.blend_mode;
    }
};

/// A draw whose bbox comes from the strips (the shape `cpu/record.zig`'s
/// `RecordedFill` will use once `bbox` is completed there).
const StripDraw = struct {
    pub fn bbox(_: StripDraw, strips: []const Strip) ?RectU16 {
        return strip_mod.stripBbox(strips);
    }

    pub fn blendMode(_: StripDraw) BlendMode {
        return BlendMode.default;
    }
};

/// Exercises the plain-value `blendMode` return shape named by the port
/// contract (upstream returns an optional reference).
const PlainBlendDraw = struct {
    pub fn bbox(_: PlainBlendDraw, _: []const Strip) ?RectU16 {
        return null;
    }

    pub fn blendMode(_: PlainBlendDraw) BlendMode {
        return BlendMode.from(peniko.Mix.multiply);
    }
};

fn layerProps() LayerProps {
    return LayerProps.default;
}

fn blendedLayerProps() LayerProps {
    var props = LayerProps.default;
    props.blend_mode = BlendMode.from(peniko.Mix.multiply);
    return props;
}

fn filterData(
    allocator: std.mem.Allocator,
    filter_padding: PaddingU16,
    source_padding: PaddingU16,
) !FilterData {
    return .{
        .filter = try Filter.fromPrimitive(allocator, .{ .offset = .{ .dx = 0.0, .dy = 0.0 } }),
        .transform = kurbo.Affine.IDENTITY,
        .filter_padding = filter_padding,
        .source_padding = source_padding,
    };
}

fn testMask(allocator: std.mem.Allocator) !Mask {
    return Mask.fromParts(allocator, &[_]u8{1}, 1, 1);
}

const ExpectedCmd = struct {
    draws: Range(u32),
    layer: ?u32,
};

fn assertCmds(cmds: []const Node, expected: []const ExpectedCmd) !void {
    try testing.expectEqual(expected.len, cmds.len);
    for (cmds, expected) |cmd, exp| {
        try testing.expectEqual(exp.draws.start, cmd.draws.start);
        try testing.expectEqual(exp.draws.end, cmd.draws.end);
        try testing.expectEqual(exp.layer, cmd.layer);
    }
}

fn layerCmds(recorder: anytype, id: usize) []const Node {
    return recorder.layers.items[id].nodes.items;
}

test "scene size is tile aligned" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(10, 10);
    defer recorder.deinit(allocator);

    try testing.expectEqual(SizeU16.new(12), recorder.scene_size);

    recorder.reset(allocator, 13, 7);
    try testing.expectEqual(SizeU16.fromWh(16, 8), recorder.scene_size);

    recorder.reset(allocator, Tile.WIDTH * 5, Tile.HEIGHT * 3);
    try testing.expectEqual(SizeU16.fromWh(Tile.WIDTH * 5, Tile.HEIGHT * 3), recorder.scene_size);
}

test "filter placement padding expands bbox" {
    const allocator = testing.allocator;
    var data = try filterData(allocator, PaddingU16.new(2, 4, 6, 8), PaddingU16.ZERO);
    defer data.deinit(allocator);

    const placement = FilterLayerPlacement.new(RectU16.new(8, 8, 16, 20), &data);

    // Since we are tile-aligned, values are expanded to a multiple of
    // tile-size.
    try testing.expectEqual(RectU16.new(4, 4, 24, 28), placement.pixmap_bbox);
    try testing.expectEqual(RectU16.new(4, 4, 24, 28), placement.dest_bbox);
    try testing.expectEqual([2]u16{ 0, 0 }, placement.srcOrigin());
}

test "filter placement with source shift" {
    const allocator = testing.allocator;
    var data = try filterData(
        allocator,
        PaddingU16.new(6, 2, 4, 6),
        PaddingU16.new(10, 16, 0, 0),
    );
    defer data.deinit(allocator);

    const placement = FilterLayerPlacement.new(RectU16.new(8, 12, 20, 24), &data);

    // Bbox expanded with padding is [8 - 6, 12 - 2, 20 + 4, 24 + 6]
    // = [2, 10, 24, 30], snapping this gives us [0, 8, 24, 32].
    try testing.expectEqual(RectU16.new(0, 8, 24, 32), placement.pixmap_bbox);
    // Account for the source origin using saturating subtraction of 10
    // horizontally and 16 vertically.
    try testing.expectEqual(RectU16.new(0, 0, 14, 16), placement.dest_bbox);
    // Source origin is now 10 - 0 = 10 and 16 - 8 = 8.
    try testing.expectEqual([2]u16{ 10, 8 }, placement.srcOrigin());
}

test "layer behavior" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushLayer(allocator, layerProps(), try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO));
    try recorder.pushLayer(allocator, layerProps(), try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO));
    try recorder.pushLayer(allocator, layerProps(), null);

    try recorder.pushDraw(allocator, TestDraw{}, &.{});

    try testing.expectEqual(PoppedLayer.regular, try recorder.popLayer());
    try testing.expectEqual(PoppedLayer.filter, try recorder.popLayer());

    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    try testing.expectEqual(PoppedLayer.regular, try recorder.popLayer());
    try testing.expectEqual(PoppedLayer.filter, try recorder.popLayer());

    try assertCmds(recorder.nodes.items, &.{
        .{ .draws = .{ .start = 0, .end = 0 }, .layer = 0 },
    });
    try assertCmds(layerCmds(&recorder, 0), &.{
        .{ .draws = .{ .start = 0, .end = 0 }, .layer = 1 },
        .{ .draws = .{ .start = 1, .end = 1 }, .layer = 3 },
    });
    try assertCmds(layerCmds(&recorder, 1), &.{
        .{ .draws = .{ .start = 0, .end = 0 }, .layer = 2 },
    });
    try assertCmds(layerCmds(&recorder, 2), &.{
        .{ .draws = .{ .start = 0, .end = 1 }, .layer = null },
    });
    try assertCmds(layerCmds(&recorder, 3), &.{
        .{ .draws = .{ .start = 1, .end = 2 }, .layer = null },
    });
    try testing.expectEqual(@as(usize, 2), recorder.draws.items.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, recorder.filter_layers.items);
    try testing.expectEqual(@as(usize, 1), recorder.layers.items[0].depth);
    try testing.expectEqual(@as(usize, 2), recorder.layers.items[1].depth);
    try testing.expectEqual(@as(usize, 3), recorder.layers.items[2].depth);
    try testing.expectEqual(@as(usize, 2), recorder.layers.items[3].depth);
    try testing.expectEqual(@as(usize, 3), recorder.max_layer_depth);
    try testing.expect(!recorder.has_non_default_blend);
    try testing.expectEqual(@as(?SizeU16, SizeU16.fromWh(64, 4)), recorder.largest_layer_size);
    try testing.expectEqual(@as(?SizeU16, SizeU16.fromWh(64, 4)), recorder.largest_filter_layer_size);
}

test "draw batches are split by layers" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    _ = try recorder.popLayer();
    try recorder.pushDraw(allocator, TestDraw{}, &.{});

    try assertCmds(recorder.nodes.items, &.{
        .{ .draws = .{ .start = 0, .end = 2 }, .layer = 0 },
        .{ .draws = .{ .start = 3, .end = 4 }, .layer = null },
    });
    try assertCmds(layerCmds(&recorder, 0), &.{
        .{ .draws = .{ .start = 2, .end = 3 }, .layer = null },
    });
}

test "node resolves draw range" {
    const draws = [_]u32{ 0, 1, 2, 3 };
    const node = Node{ .draws = .{ .start = 1, .end = 3 }, .layer = null };

    try testing.expectEqualSlices(u32, &.{ 1, 2 }, node.drawsIn(&draws));
}

test "empty draws do not affect layer bounds" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(EmptyDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushDraw(allocator, EmptyDraw{}, &.{});
    _ = try recorder.popLayer();

    try testing.expect(recorder.layers.items[0].bbox.isEmpty());
}

test "disjoint layer bounds are empty but not inverted" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    var props = layerProps();
    props.clip_path = .{
        .strip_range = .{ .start = 0, .end = 0 },
        .thread_idx = 0,
        .bbox = RectU16.new(8, 8, 12, 12),
    };

    try recorder.pushLayer(allocator, props, null);
    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    _ = try recorder.popLayer();

    try testing.expectEqual(RectU16.new(8, 8, 12, 8), recorder.layers.items[0].bbox);
}

test "blend metadata distinguishes root and nested targets" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushLayer(allocator, blendedLayerProps(), null);

    try testing.expect(!recorder.root_is_blend_target);
    try testing.expect(recorder.has_non_default_blend);
    try testing.expectEqual(@as(usize, 2), recorder.max_layer_depth);

    _ = try recorder.popLayer();
    _ = try recorder.popLayer();
    try recorder.pushLayer(allocator, blendedLayerProps(), null);

    try testing.expect(recorder.root_is_blend_target);
}

test "draw blend metadata distinguishes root and nested targets" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(BlendedDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushDraw(allocator, BlendedDraw{ .blend_mode = .default }, &.{});
    try testing.expect(!recorder.root_is_blend_target);

    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushDraw(allocator, BlendedDraw{
        .blend_mode = BlendMode.from(peniko.Mix.multiply),
    }, &.{});
    try testing.expect(!recorder.root_is_blend_target);
    _ = try recorder.popLayer();

    try recorder.pushDraw(allocator, BlendedDraw{
        .blend_mode = BlendMode.from(peniko.Mix.multiply),
    }, &.{});
    try testing.expect(recorder.root_is_blend_target);
}

test "reset clears all metadata" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushLayer(allocator, blendedLayerProps(), null);
    try recorder.pushLayer(allocator, layerProps(), try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO));
    try recorder.pushDraw(allocator, TestDraw{}, &.{});
    _ = try recorder.popLayer();
    _ = try recorder.popLayer();

    try testing.expect(recorder.root_is_blend_target);
    try testing.expect(recorder.has_non_default_blend);
    try testing.expectEqual(@as(usize, 2), recorder.max_layer_depth);
    try testing.expect(recorder.largest_layer_size != null);
    try testing.expect(recorder.largest_filter_layer_size != null);

    recorder.reset(allocator, 13, 7);

    try testing.expectEqual(SizeU16.fromWh(16, 8), recorder.scene_size);
    try testing.expect(!recorder.root_is_blend_target);
    try testing.expect(!recorder.has_non_default_blend);
    try testing.expectEqual(@as(usize, 0), recorder.max_layer_depth);
    try testing.expect(recorder.largest_layer_size == null);
    try testing.expect(recorder.largest_filter_layer_size == null);
    try testing.expectEqual(@as(usize, 0), recorder.filter_layers.items.len);
}

test "pop layer without a push returns a typed error" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try testing.expect(!recorder.hasLayers());
    try testing.expectError(error.NoActiveLayer, recorder.popLayer());
    try testing.expect(!recorder.hasLayers());
}

test "push draw computes the layer bbox from strips" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(StripDraw).new(64, 64);
    defer recorder.deinit(allocator);

    try recorder.pushLayer(allocator, layerProps(), null);

    const strips = [_]Strip{
        Strip.new(8, 4, 0, false),
        Strip.sentinel(4, 16),
    };
    try recorder.pushDraw(allocator, StripDraw{}, &strips);

    try testing.expectEqual(PoppedLayer.regular, try recorder.popLayer());
    try testing.expectEqual(RectU16.new(8, 4, 12, 8), recorder.layers.items[0].bbox);
}

test "pop filter layer computes placement" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    // The draw bbox is (0, 0, 64, 4); padding (2, 4, 6, 8) expands it to
    // (0, 0, 70, 12), which snaps to (0, 0, 72, 12).
    try recorder.pushLayer(allocator, layerProps(), try filterData(
        allocator,
        PaddingU16.new(2, 4, 6, 8),
        PaddingU16.ZERO,
    ));
    try recorder.pushDraw(allocator, TestDraw{}, &.{});

    try testing.expectEqual(PoppedLayer.filter, try recorder.popLayer());

    const layer = &recorder.layers.items[0];
    try testing.expectEqual(RectU16.new(0, 0, 72, 12), layer.bbox);
    try testing.expectEqual(RectU16.new(0, 0, 72, 12), layer.kind.filter.placement.pixmap_bbox);
    try testing.expectEqual(RectU16.new(0, 0, 72, 12), layer.kind.filter.placement.dest_bbox);
    try testing.expectEqual([2]u16{ 0, 0 }, layer.kind.filter.placement.srcOrigin());
    try testing.expectEqual(SizeU16.fromWh(72, 12), recorder.largest_layer_size.?);
    try testing.expectEqual(SizeU16.fromWh(72, 12), recorder.largest_filter_layer_size.?);
}

test "reset releases layer mask and filter data" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    var props = layerProps();
    props.mask = try testMask(allocator);
    try recorder.pushLayer(allocator, props, try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO));

    // No pop: reset drops the open layer and its owned mask/filter graph.
    recorder.reset(allocator, 13, 7);

    try testing.expectEqual(@as(usize, 0), recorder.layers.items.len);
    try testing.expect(!recorder.hasLayers());
}

test "deinit releases layer mask and filter data" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);

    var props = layerProps();
    props.mask = try testMask(allocator);
    try recorder.pushLayer(allocator, props, try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO));
    _ = try recorder.popLayer();

    // The testing allocator fails the test on any leaked mask/filter graph.
    recorder.deinit(allocator);
}

test "drawable accepts a plain blend mode return" {
    const allocator = testing.allocator;
    var recorder = CommandRecorder(PlainBlendDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    try recorder.pushDraw(allocator, PlainBlendDraw{}, &.{});
    try testing.expect(recorder.root_is_blend_target);
}

fn allocFailureCase(allocator: std.mem.Allocator) !void {
    var recorder = CommandRecorder(TestDraw).new(DEFAULT_SIZE, DEFAULT_SIZE);
    defer recorder.deinit(allocator);

    // Existing state that a failed transactional push must not disturb.
    try recorder.pushLayer(allocator, layerProps(), null);
    try recorder.pushDraw(allocator, TestDraw{}, &.{});

    var mask: ?Mask = try testMask(allocator);
    defer if (mask) |owned| owned.deinit(allocator);
    var filter_data: ?FilterData = try filterData(allocator, PaddingU16.ZERO, PaddingU16.ZERO);
    defer if (filter_data) |*owned| owned.deinit(allocator);

    const layers_before = recorder.layers.items.len;
    const nodes_before = recorder.nodes.items.len;

    var props = layerProps();
    props.mask = mask.?;
    recorder.pushLayer(allocator, props, filter_data) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(layers_before, recorder.layers.items.len);
        try testing.expectEqual(nodes_before, recorder.nodes.items.len);
        try testing.expectEqual(@as(usize, 0), recorder.filter_layers.items.len);
        return err;
    };

    // The recorder now owns the mask and the filter graph.
    mask = null;
    filter_data = null;
    try testing.expectEqual(@as(usize, 1), recorder.filter_layers.items.len);

    recorder.pushDraw(allocator, TestDraw{}, &.{}) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(layers_before + 1, recorder.layers.items.len);
        return err;
    };

    _ = try recorder.popLayer();
    _ = try recorder.popLayer();
}

test "push paths are atomic under allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, allocFailureCase, .{});
}
