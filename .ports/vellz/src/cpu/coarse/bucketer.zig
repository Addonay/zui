//! Port of vello_cpu src/coarse/bucketer.rs (Apache-2.0 OR MIT).
//!
//! The command bucketer walks the recorded render graph and emits per-row
//! `RenderCmd`s: paint fills (with optional alpha coverage), lazy `push_buf`/
//! `pop_buf` pairs for layers, and `layer_fill`s that composite a layer into
//! its parent.
//!
//! Scope of this port (M1): solid paints, regular layers (clip/opacity/blend),
//! coarse depth culling of opaque fills, alpha segments from `fill_gap`
//! handling, viewport origins, and clip bounding boxes. Deferred features fail
//! with `error.Unsupported` instead of emitting placeholder pixels:
//!
//! - **Filter layers**: `bucketCommands` rejects a recorded
//!   `RecordedLayerKind.filter` node outright. `FilterContext` (see
//!   `cpu/filter.zig`) stays empty in M1.
//! - **Indexed paints**: a `Paint.indexed` payload is rejected in
//!   `generateFill`. The encoder in `cpu/render.zig` never produces one for
//!   M1. The `encoded_paints` argument upstream's `generate_fill` takes is
//!   therefore not part of this M1 signature; M2 adds it together with the
//!   indexed-paint painters.
//!
//! Ownership/allocator note (following the repository convention): the
//! bucketer owns `row_states`, `clip_bboxes`, `active_layers`,
//! `paint_fill_attrs`, `layer_fill_attrs`, and the row/occupied-row pools. It
//! takes an explicit allocator on every operation that can grow a buffer
//! (`init`/`reset`/`bucketCommands`), and `deinit` releases everything.
//! Masks are borrowed (`?*const Mask`) exactly like `cpu/record.zig` and
//! `cpu/coarse/cmd.zig`: the recorded layer graph and the mask owner must
//! outlive bucketing and rasterization.
//!
//! Error policy: allocation failure propagates as `error.OutOfMemory` and
//! leaves the bucketer in a defined state (partial rows are valid; `reset`
//! recycles whatever an aborted pass left behind). Upstream `unwrap`s on
//! internal invariants; this port keeps those as `unreachable`/`assert` only
//! where the graph structure guarantees them.

const std = @import("std");
const record = @import("../../common/record.zig");
const cpu_record = @import("../record.zig");
const geometry = @import("../../common/geometry.zig");
const common_util = @import("../../common/util.zig");
const mask_mod = @import("../../common/mask.zig");
const paint_mod = @import("../../common/paint.zig");
const strip_mod = @import("../../common/strip.zig");
const peniko = @import("../../peniko/root.zig");
const cmd = @import("cmd.zig");
const depth = @import("depth.zig");
const filter_mod = @import("../filter.zig");
const util_cpu = @import("../util.zig");

pub const Span = util_cpu.Span;
pub const RenderCmd = cmd.RenderCmd;
pub const DepthFill = cmd.DepthFill;
pub const PaintFillAttrs = cmd.PaintFillAttrs;
pub const LayerFillAttrs = cmd.LayerFillAttrs;

const BlendMode = peniko.BlendMode;
const FilterContext = filter_mod.FilterContext;
const LayerClip = record.LayerClip;
const LayerFill = cmd.LayerFill;
const LayerProps = record.LayerProps;
const Mask = mask_mod.Mask;
const Node = record.Node;
const Paint = paint_mod.Paint;
const PaintFill = cmd.PaintFill;
const RecordedFill = cpu_record.RecordedFill;
const RecordedLayer = record.RecordedLayer;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;
const StripAlphaFillSegment = strip_mod.StripAlphaFillSegment;
const StripFillSegment = strip_mod.StripFillSegment;

/// The tile width in pixels (`Tile::WIDTH`).
const TILE_WIDTH: u16 = util_cpu.TILE_WIDTH;
/// The tile height in pixels (`Tile::HEIGHT`).
const TILE_HEIGHT: u16 = util_cpu.TILE_HEIGHT;

/// Errors from bucketing: allocation failure plus the explicitly deferred M1
/// features (filter layers, indexed paints).
pub const Error = std.mem.Allocator.Error || error{Unsupported};

fn isDefaultBlendMode(blend_mode: BlendMode) bool {
    return blend_mode.mix == .normal and blend_mode.compose == .src_over;
}

fn divCeilU16(value: u16, divisor: u16) u16 {
    if (value % divisor == 0) return value / divisor;
    return value / divisor + 1;
}

/// State for one recorded layer in one row: where its `push_buf` command lives
/// and the horizontal span its direct contents cover.
const RowLayerState = struct {
    /// Index in `RowState.render_cmds` of the layer's `push_buf`.
    push_cmd_idx: usize,
    /// The horizontal span of the layer's direct contents in this row.
    span: ?Span,
};

/// State for a single row of strips.
pub const RowState = struct {
    /// Normal render commands rendered back-to-front with depth-buffer read.
    render_cmds: std.ArrayList(RenderCmd),
    /// Opaque fill commands rendered front-to-back with depth-buffer read and
    /// write.
    depth_cmds: std.ArrayList(cmd.DepthFill),
    /// State of the depth buffer for this row.
    depth: depth.DepthState,
    /// Current layer depth.
    layer_depth: usize,
    /// Stack of the layers that are currently open in this row.
    layer_stack: std.ArrayList(RowLayerState),

    /// Create an empty row state.
    pub fn init() RowState {
        return .{
            .render_cmds = .empty,
            .depth_cmds = .empty,
            .depth = .{},
            .layer_depth = 0,
            .layer_stack = .empty,
        };
    }

    /// Release the command storage.
    pub fn deinit(self: *RowState, allocator: std.mem.Allocator) void {
        self.render_cmds.deinit(allocator);
        self.depth_cmds.deinit(allocator);
        self.layer_stack.deinit(allocator);
        self.* = undefined;
    }

    /// Clear all commands, retaining capacity (upstream `Clear for RowState`).
    pub fn clear(self: *RowState) void {
        self.render_cmds.clearRetainingCapacity();
        self.depth_cmds.clearRetainingCapacity();
        self.depth.reset();
        self.layer_depth = 0;
        self.layer_stack.clearRetainingCapacity();
    }

    /// Whether a draw with `draw_id` over `span` can skip the depth buffer.
    pub fn canSkipDepth(self: *const RowState, span: Span, draw_id: u32) bool {
        return self.depth.canSkip(span, draw_id);
    }

    /// Append a render command, extending the current layer's span when the
    /// command covers pixels (upstream `RowState::push_cmd`).
    pub fn pushCmd(self: *RowState, allocator: std.mem.Allocator, command: RenderCmd) std.mem.Allocator.Error!void {
        try self.render_cmds.ensureUnusedCapacity(allocator, 1);
        switch (command) {
            .paint_fill => |fill| self.includeCurrentSpan(fill.span),
            .layer_fill => |fill| self.includeCurrentSpan(fill.span),
            .push_buf, .pop_buf => {},
        }
        self.render_cmds.appendAssumeCapacity(command);
    }

    /// Push a new temporary layer buffer (upstream `RowState::push_buf`).
    pub fn pushBuf(self: *RowState, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.render_cmds.ensureUnusedCapacity(allocator, 1);
        try self.layer_stack.ensureUnusedCapacity(allocator, 1);

        const push_cmd_idx = self.render_cmds.items.len;
        self.render_cmds.appendAssumeCapacity(.{ .push_buf = null });
        self.layer_stack.appendAssumeCapacity(.{ .push_cmd_idx = push_cmd_idx, .span = null });
        self.layer_depth += 1;
    }

    /// Pop the last temporary layer buffer, writing the layer's accumulated
    /// span into its `push_buf` command (upstream `RowState::pop_buf`).
    pub fn popBuf(self: *RowState, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        std.debug.assert(self.layer_stack.items.len > 0);

        try self.render_cmds.ensureUnusedCapacity(allocator, 1);

        const layer = self.layer_stack.pop().?;
        const push_cmd = &self.render_cmds.items[layer.push_cmd_idx];
        std.debug.assert(std.meta.activeTag(push_cmd.*) == .push_buf);
        push_cmd.push_buf = layer.span;

        self.render_cmds.appendAssumeCapacity(.{ .pop_buf = {} });
        self.layer_depth -= 1;
    }

    /// Append a depth-tracked opaque fill and include it in the row's coarse
    /// depth state.
    pub fn pushDepthFill(
        self: *RowState,
        allocator: std.mem.Allocator,
        fill: cmd.DepthFill,
        draw_id: u32,
    ) std.mem.Allocator.Error!void {
        self.depth.includeSpan(fill.span(), draw_id);
        try self.depth_cmds.append(allocator, fill);
    }

    /// Union `span` into the current layer's span, if any.
    fn includeCurrentSpan(self: *RowState, span: Span) void {
        if (self.layer_stack.items.len == 0) return;
        const layer = &self.layer_stack.items[self.layer_stack.items.len - 1];
        if (layer.span) |*layer_span| {
            layer_span.extend(span);
        } else {
            layer.span = span;
        }
    }
};

/// Metadata about a currently open layer (upstream `ActiveLayer`).
///
/// `mask` is borrowed; see the file-level ownership note.
pub const ActiveLayer = struct {
    /// The layer's mask, if any.
    mask: ?*const Mask,
    /// Blend mode used when compositing the layer.
    blend_mode: BlendMode,
    /// Opacity used when compositing the layer.
    opacity: f32,
    /// Clip path of the layer, if any.
    clip: ?LayerClip,
    /// Horizontal span of the layer in viewport-local coordinates.
    span: Span,
    /// Rows that have been drawn into and therefore hold a lazily-allocated
    /// `push_buf` command.
    occupied_rows: std.ArrayList(usize),
};

/// A generic fill produced by `generate` (upstream `GeneratedFill`).
const GeneratedFill = struct {
    row_idx: usize,
    span: Span,
};

/// A generic alpha fill produced by `generate` (upstream
/// `GeneratedAlphaFill`).
const GeneratedAlphaFill = struct {
    row_idx: usize,
    span: Span,
    alpha_idx: u32,
};

/// A bucketer that groups commands into strip-row-sized buckets.
pub const CommandBucketer = struct {
    /// The viewport of the root/filter layer currently being bucketed.
    viewport: RectU16,
    /// Tile-aligned viewport width in pixels (upstream `width()`).
    width: u16,
    /// Tile-aligned viewport height in pixels.
    height: u16,
    /// The currently active stack of clip bboxes (from layer clips), anchored
    /// at `(0, 0)` regardless of the viewport.
    clip_bboxes: std.ArrayList(RectU16),
    /// One row state per 4-pixel strip row.
    ///
    /// Upstream names this field `rows` and uses a `RetainVec`; this port
    /// keeps the `row_states` name used by the M0 data-model seam and an
    /// `ArrayList` (which also retains capacity across `reset`).
    row_states: std.ArrayList(RowState),
    /// Attributes referenced by paint fill commands.
    paint_fill_attrs: std.ArrayList(PaintFillAttrs),
    /// Attributes referenced by layer fill commands.
    layer_fill_attrs: std.ArrayList(LayerFillAttrs),
    /// Currently active layers, to enable lazy layer pushing.
    active_layers: std.ArrayList(ActiveLayer),
    /// A pool for the `occupied_rows` vectors that are handed back when a
    /// layer is popped.
    occupied_rows_pool: common_util.VecPool(usize),
    /// Scratch space used when replaying clip strips while popping clipped
    /// layers.
    occupied_rows_bool_scratch: std.ArrayList(bool),
    /// Monotonically increasing draw ID. Starts at 1 because the depth buffer
    /// uses 0 for "no entries yet".
    next_draw_id: u32,

    /// Create a bucketer for a `width` by `height` viewport.
    ///
    /// Dimensions are snapped to tile coordinates exactly like upstream
    /// (`viewport.snap_to_tile_coordinates()`), so `height` is always a
    /// multiple of the tile height and `row_states.len == height / 4`.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) Error!CommandBucketer {
        return initViewport(allocator, RectU16.new(0, 0, width, height));
    }

    /// Create a bucketer for a tile-aligned `viewport` (upstream `new`).
    pub fn initViewport(allocator: std.mem.Allocator, viewport_in: RectU16) Error!CommandBucketer {
        const viewport = common_util.RectExt.snapToTileCoordinates(viewport_in);
        const clip_bbox = RectU16.new(0, 0, viewport.width(), viewport.height());
        const num_rows = @as(usize, clip_bbox.height()) / TILE_HEIGHT;

        var row_states = std.ArrayList(RowState).empty;
        errdefer {
            for (row_states.items) |*row| row.deinit(allocator);
            row_states.deinit(allocator);
        }
        try row_states.ensureTotalCapacity(allocator, num_rows);
        while (row_states.items.len < num_rows) {
            row_states.appendAssumeCapacity(RowState.init());
        }

        var clip_bboxes = std.ArrayList(RectU16).empty;
        errdefer clip_bboxes.deinit(allocator);
        try clip_bboxes.append(allocator, clip_bbox);

        var occupied_rows_bool_scratch = std.ArrayList(bool).empty;
        errdefer occupied_rows_bool_scratch.deinit(allocator);
        try occupied_rows_bool_scratch.resize(allocator, num_rows);
        @memset(occupied_rows_bool_scratch.items, false);

        return .{
            .viewport = viewport,
            .width = viewport.width(),
            .height = viewport.height(),
            .clip_bboxes = clip_bboxes,
            .row_states = row_states,
            .paint_fill_attrs = .empty,
            .layer_fill_attrs = .empty,
            .active_layers = .empty,
            .occupied_rows_pool = common_util.VecPool(usize).init(true),
            .occupied_rows_bool_scratch = occupied_rows_bool_scratch,
            .next_draw_id = 1,
        };
    }

    /// Release all row, attribute, clip, and pool storage.
    pub fn deinit(self: *CommandBucketer, allocator: std.mem.Allocator) void {
        for (self.row_states.items) |*row| row.deinit(allocator);
        self.row_states.deinit(allocator);
        self.clip_bboxes.deinit(allocator);
        self.paint_fill_attrs.deinit(allocator);
        self.layer_fill_attrs.deinit(allocator);
        for (self.active_layers.items) |*layer| layer.occupied_rows.deinit(allocator);
        self.active_layers.deinit(allocator);
        for (self.occupied_rows_pool.entries.items) |*occupied| occupied.deinit(allocator);
        self.occupied_rows_pool.deinit(allocator);
        self.occupied_rows_bool_scratch.deinit(allocator);
        self.* = undefined;
    }

    /// The per-row command streams (upstream `rows(&self) -> &[RowState]`).
    pub fn rows(self: *const CommandBucketer) []const RowState {
        return self.row_states.items;
    }

    /// Reset the bucketer for a new (tile-snapped) viewport, retaining
    /// capacity (upstream `reset`).
    pub fn reset(self: *CommandBucketer, allocator: std.mem.Allocator, viewport_in: RectU16) Error!void {
        const viewport = common_util.RectExt.snapToTileCoordinates(viewport_in);
        const clip_bbox = RectU16.new(0, 0, viewport.width(), viewport.height());
        const num_rows = @as(usize, clip_bbox.height()) / TILE_HEIGHT;

        // All fallible buffers are grown before any observable state changes,
        // so an allocation failure leaves the previous frame fully intact.
        try self.occupied_rows_bool_scratch.resize(allocator, num_rows);
        @memset(self.occupied_rows_bool_scratch.items, false);
        try self.row_states.ensureTotalCapacity(allocator, num_rows);
        try self.clip_bboxes.ensureTotalCapacity(allocator, 1);

        if (num_rows <= self.row_states.items.len) {
            for (self.row_states.items) |*row| row.clear();
            self.row_states.shrinkRetainingCapacity(num_rows);
        } else {
            for (self.row_states.items) |*row| row.clear();
            while (self.row_states.items.len < num_rows) {
                self.row_states.appendAssumeCapacity(RowState.init());
            }
        }

        self.paint_fill_attrs.clearRetainingCapacity();
        self.layer_fill_attrs.clearRetainingCapacity();
        for (self.active_layers.items) |*layer| {
            self.recycleOccupiedRows(allocator, layer.occupied_rows);
        }
        self.active_layers.clearRetainingCapacity();
        self.clip_bboxes.clearRetainingCapacity();
        self.clip_bboxes.appendAssumeCapacity(clip_bbox);

        self.next_draw_id = 1;
        self.viewport = viewport;
        self.width = viewport.width();
        self.height = viewport.height();
    }

    /// Return a fresh draw ID (upstream `next_draw_id`).
    fn nextDrawId(self: *CommandBucketer) u32 {
        const draw_id = self.next_draw_id;
        self.next_draw_id += 1;
        return draw_id;
    }

    fn viewportOrigin(self: *const CommandBucketer) [2]u16 {
        return .{ self.viewport.x0, self.viewport.y0 };
    }

    /// Upstream `CommandBucketer::bbox_span`.
    fn bboxSpan(bbox: RectU16) Span {
        // Bbox might be empty vertically but not horizontally. In this case,
        // it should still be considered a zero-sized span.
        if (bbox.isEmpty()) {
            return Span.new(bbox.x0, 0);
        }
        return Span.new(bbox.x0, bbox.x1 - bbox.x0);
    }

    /// Push `push_buf` commands for every active layer the given row is not
    /// yet aware of (upstream `ensure_row_layers`).
    pub fn ensureRowLayers(self: *CommandBucketer, allocator: std.mem.Allocator, row_idx: usize) Error!void {
        std.debug.assert(row_idx < self.row_states.items.len);
        const layer_depth = self.row_states.items[row_idx].layer_depth;
        if (layer_depth == self.active_layers.items.len) return;

        for (layer_depth..self.active_layers.items.len) |layer_idx| {
            // Reserve the occupied-row slot first so a failure cannot leave a
            // `push_buf` command without a corresponding pop on layer close.
            try self.active_layers.items[layer_idx].occupied_rows.ensureUnusedCapacity(allocator, 1);
            try self.row_states.items[row_idx].pushBuf(allocator);
            self.active_layers.items[layer_idx].occupied_rows.appendAssumeCapacity(row_idx);
        }
    }

    /// Bucket a recorded node list into per-row commands (upstream
    /// `bucket_commands`).
    ///
    /// Nodes are processed in order; a node's draws are bucketed before its
    /// optional layer is pushed and recursed into. `filter_ctx` is part of the
    /// upstream signature and is kept as the M2 seam; M1 rejects filter layers
    /// before consulting it.
    pub fn bucketCommands(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        nodes: []const Node,
        draws: []const RecordedFill,
        layers: []const RecordedLayer,
        strips: []const Strip,
        filter_ctx: *const FilterContext,
    ) Error!void {
        std.debug.assert(self.viewport.x0 % TILE_WIDTH == 0);
        std.debug.assert(self.viewport.y0 % TILE_HEIGHT == 0);

        for (nodes) |node| {
            // Iterate draws by pointer: `PaintFillAttrs.mask` borrows the mask
            // handle owned by the draw, so the address must be stable for the
            // whole bucketing pass.
            for (node.drawsIn(draws)) |*fill| {
                const draw_id = self.nextDrawId();
                const attrs = PaintFillAttrs{
                    .paint = fill.paint,
                    .blend_mode = fill.blend_mode,
                    .mask = if (fill.mask) |*m| m else null,
                    .draw_id = draw_id,
                    .thread_idx = fill.thread_idx,
                    .origin = self.viewportOrigin(),
                };
                const strip_range = fill.strip_range;
                try self.generateFill(
                    allocator,
                    strips[strip_range.start..strip_range.end],
                    attrs,
                );
            }

            if (node.layer) |layer_id| {
                const layer = &layers[layer_id];
                switch (layer.kind) {
                    .regular => {
                        try self.pushLayer(allocator, &layer.props);
                        // TODO upstream: avoid recursion for deeply nested
                        // layers.
                        try self.bucketCommands(
                            allocator,
                            layer.nodes.items,
                            draws,
                            layers,
                            strips,
                            filter_ctx,
                        );
                        try self.popLayer(allocator, strips);
                    },
                    .filter => return error.Unsupported,
                }
            }
        }
    }

    /// Push a new layer (upstream `push_layer`).
    ///
    /// Regular layers are inlined into the same command stream; their contents
    /// are bracketed by lazy `push_buf`/`pop_buf` commands on every row they
    /// touch. Destructive blend modes eagerly materialize the layer across its
    /// whole (non-empty) clip bbox because even untouched pixels must be
    /// blended during compositing.
    pub fn pushLayer(self: *CommandBucketer, allocator: std.mem.Allocator, props: *const LayerProps) Error!void {
        const parent_bbox = self.clip_bboxes.items[self.clip_bboxes.items.len - 1];
        const bbox: RectU16 = if (props.clip_path) |clip| blk: {
            // Translate the clip path from viewport space to local space,
            // since `clip_bboxes` uses this coordinate system.
            const clip_bbox = clip.bbox.relativeToOrigin(self.viewportOrigin());
            break :blk clip_bbox.intersect(parent_bbox);
        } else parent_bbox;

        const mask: ?*const Mask = if (props.mask) |*m| m else null;

        // Reserve every fallible buffer before publishing the layer.
        if (props.clip_path != null) {
            try self.clip_bboxes.ensureUnusedCapacity(allocator, 1);
        }
        try self.active_layers.ensureUnusedCapacity(allocator, 1);

        if (props.clip_path != null) {
            self.clip_bboxes.appendAssumeCapacity(bbox);
        }
        self.active_layers.appendAssumeCapacity(.{
            .mask = mask,
            .blend_mode = props.blend_mode,
            .opacity = props.opacity,
            .clip = props.clip_path,
            .span = bboxSpan(bbox),
            .occupied_rows = self.occupied_rows_pool.take(.empty),
        });

        // If the blend mode is destructive, we need to eagerly push to all
        // rows in the clip bbox, since even areas where nothing was drawn need
        // to be blended with the destructive blend mode.
        if (props.blend_mode.isDestructive() and !bbox.isEmpty()) {
            const row_start = @as(usize, bbox.y0 / TILE_HEIGHT);
            const row_end = @min(
                @as(usize, divCeilU16(bbox.y1, TILE_HEIGHT)),
                self.row_states.items.len,
            );
            for (row_start..row_end) |row_idx| {
                try self.ensureRowLayers(allocator, row_idx);
            }
        }
    }

    /// Pop the last layer and emit its composite commands (upstream
    /// `pop_layer`).
    pub fn popLayer(self: *CommandBucketer, allocator: std.mem.Allocator, strips: []const Strip) Error!void {
        std.debug.assert(self.active_layers.items.len > 0);

        const layer = self.active_layers.pop().?;
        const opacity = layer.opacity;
        const blend_mode = layer.blend_mode;

        // Recycle the occupied-row vector on every exit path; on success the
        // explicit submission below consumes it instead.
        const occupied_rows = layer.occupied_rows;
        errdefer self.recycleOccupiedRows(allocator, occupied_rows);

        if (layer.clip) |clip| {
            try self.layer_fill_attrs.ensureUnusedCapacity(allocator, 1);
            const attrs_idx: u32 = @intCast(self.layer_fill_attrs.items.len);
            const draw_id = self.nextDrawId();
            self.layer_fill_attrs.appendAssumeCapacity(.{
                .blend_mode = blend_mode,
                .opacity = opacity,
                .mask = layer.mask,
                .draw_id = draw_id,
                .thread_idx = clip.thread_idx,
            });

            // The parent clip bbox is restored before generating: the clip
            // strips are clipped against the parent, not against themselves.
            const popped_bbox = self.clip_bboxes.pop().?;
            _ = popped_bbox;

            // The clip strips themselves are still in viewport space; they
            // are converted to local space when generating.
            const clip_strips = strips[clip.strip_range.start..clip.strip_range.end];

            // Mark occupied rows so layer fills are only emitted for rows
            // that actually have a `push_buf` to composite into. The flags are
            // cleared before `occupied_rows` is recycled: returning the vector
            // to the pool clears its buffer contents, so it must not be read
            // afterwards.
            for (occupied_rows.items) |row_idx| {
                self.occupied_rows_bool_scratch.items[row_idx] = true;
            }
            self.generate(
                allocator,
                clip_strips,
                .{
                    .layer_fill = true,
                    .attrs_idx = attrs_idx,
                    .occupied = self.occupied_rows_bool_scratch.items,
                },
            ) catch |err| {
                for (occupied_rows.items) |row_idx| {
                    self.occupied_rows_bool_scratch.items[row_idx] = false;
                }
                return err;
            };
            for (occupied_rows.items) |row_idx| {
                self.occupied_rows_bool_scratch.items[row_idx] = false;
            }

            for (occupied_rows.items) |row_idx| {
                try self.row_states.items[row_idx].popBuf(allocator);
            }

            self.recycleOccupiedRows(allocator, occupied_rows);
        } else {
            try self.layer_fill_attrs.ensureUnusedCapacity(allocator, 1);
            const attrs_idx: u32 = @intCast(self.layer_fill_attrs.items.len);
            const draw_id = self.nextDrawId();
            self.layer_fill_attrs.appendAssumeCapacity(.{
                .blend_mode = blend_mode,
                .opacity = opacity,
                .mask = layer.mask,
                .draw_id = draw_id,
                .thread_idx = 0,
            });

            for (occupied_rows.items) |row_idx| {
                const row = &self.row_states.items[row_idx];
                // TODO upstream: emit the per-row bbox instead of the full
                // layer bbox across all rows.
                try row.pushCmd(allocator, .{
                    .layer_fill = LayerFill.new(layer.span, null, attrs_idx),
                });
                try row.popBuf(allocator);
            }

            self.recycleOccupiedRows(allocator, occupied_rows);
        }
    }

    /// Generate the fill commands for a recorded fill (upstream
    /// `generate_fill`).
    ///
    /// `attrs.draw_id` must be non-zero. Depth culling is only enabled when
    /// the fill is outside of every layer, uses the default blend mode, has no
    /// mask, and its paint is opaque.
    pub fn generateFill(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        strip_buf: []const Strip,
        attrs: PaintFillAttrs,
    ) Error!void {
        if (strip_buf.len == 0) return;

        std.debug.assert(attrs.draw_id != 0);

        const draw_id: ?u32 = blk: {
            // While in certain cases it might be okay to use depth culling
            // inside a layer, it can get very finicky with blend modes, so
            // upstream outright rejects those for now.
            if (self.active_layers.items.len != 0) break :blk null;
            if (!isDefaultBlendMode(attrs.blend_mode)) break :blk null;
            if (attrs.mask != null) break :blk null;
            switch (attrs.paint) {
                .solid => |premul| {
                    if (!premul.isOpaque()) break :blk null;
                },
                .indexed => return error.Unsupported,
            }
            break :blk attrs.draw_id;
        };

        try self.paint_fill_attrs.ensureUnusedCapacity(allocator, 1);
        const attrs_idx: u32 = @intCast(self.paint_fill_attrs.items.len);
        self.paint_fill_attrs.appendAssumeCapacity(attrs);

        try self.generate(allocator, strip_buf, .{
            .layer_fill = false,
            .attrs_idx = attrs_idx,
            .draw_id = draw_id,
        });
    }

    /// Visit a strip buffer and emit fill/alpha commands clipped to the active
    /// clip bbox and translated into viewport-local coordinates (upstream
    /// `generate`).
    fn generate(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        strip_buf: []const Strip,
        base_ctx: GenerateCtx,
    ) Error!void {
        if (strip_buf.len == 0) return;

        const clip_bbox = self.clip_bboxes.items[self.clip_bboxes.items.len - 1];
        if (clip_bbox.isEmpty()) return;

        const origin = self.viewportOrigin();
        const origin_tile_x = origin[0] / TILE_WIDTH;
        const origin_tile_y = origin[1] / TILE_HEIGHT;

        // Convert the clip bbox to scene coordinates; both additions saturate
        // so a viewport at the u16 edge cannot wrap.
        const clip_scene_x0 = origin[0] +| clip_bbox.x0;
        const clip_scene_x1 = origin[0] +| clip_bbox.x1;
        const clip_scene_y0 = origin[1] +| clip_bbox.y0;
        const clip_scene_y1 = origin[1] +| clip_bbox.y1;

        // Clip bounding box in tile units.
        const tile_bounds = RectU16.new(
            clip_scene_x0 / TILE_WIDTH,
            clip_scene_y0 / TILE_HEIGHT,
            clip_scene_x1 / TILE_WIDTH,
            clip_scene_y1 / TILE_HEIGHT,
        );

        var ctx = base_ctx;
        ctx.bucketer = self;
        ctx.allocator = allocator;
        ctx.origin_tile_x = origin_tile_x;
        ctx.origin_tile_y = origin_tile_y;

        strip_mod.visitStripFillSegments(strip_buf, tile_bounds, &ctx, true, true);
        if (ctx.err) |err| return err;
    }

    /// Note: if depth culling should be disabled, pass `null` to `draw_id`.
    fn pushFill(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        fill: GeneratedFill,
        attrs_idx: u32,
        draw_id: ?u32,
    ) Error!void {
        try self.ensureRowLayers(allocator, fill.row_idx);
        const row = &self.row_states.items[fill.row_idx];

        const effective_draw_id: ?u32 = if (draw_id) |id|
            (if (row.layer_depth == 0) id else null)
        else
            null;

        const depth_draw_id = effective_draw_id orelse {
            // Depth culling disabled: a single contiguous command.
            try row.pushCmd(allocator, .{
                .paint_fill = PaintFill.new(fill.span, null, attrs_idx),
            });
            return;
        };

        var ctx = PushFillCtx{
            .row = row,
            .allocator = allocator,
            .attrs_idx = attrs_idx,
            .draw_id = depth_draw_id,
        };
        depth.splitOpaqueSpan(fill.span, &ctx);
        if (ctx.err) |err| return err;
    }

    /// Emit a plain (no alpha) paint fill for `fill` (upstream `fill_cmd` for
    /// `generate_fill`).
    fn pushFillCmd(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        fill: GeneratedFill,
        attrs_idx: u32,
        draw_id: ?u32,
    ) Error!void {
        return self.pushFill(allocator, fill, attrs_idx, draw_id);
    }

    /// Emit an alpha-coverage paint fill for `fill` (upstream `alpha_fill_cmd`
    /// for `generate_fill`).
    fn pushAlphaCmd(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        fill: GeneratedAlphaFill,
        attrs_idx: u32,
    ) Error!void {
        try self.ensureRowLayers(allocator, fill.row_idx);
        try self.row_states.items[fill.row_idx].pushCmd(allocator, .{
            .paint_fill = PaintFill.new(fill.span, fill.alpha_idx, attrs_idx),
        });
    }

    /// Return an occupied-row vector to the pool, freeing it if the pool
    /// cannot retain it.
    fn recycleOccupiedRows(self: *CommandBucketer, allocator: std.mem.Allocator, occupied: std.ArrayList(usize)) void {
        self.occupied_rows_pool.submit(allocator, occupied) catch {
            // `submit` failed before taking ownership; free our copy instead
            // of leaking it.
            var lost = occupied;
            lost.deinit(allocator);
        };
    }
};

/// Context for `visitStripFillSegments`-driven command generation.
///
/// `visitStripFillSegments` cannot return errors, so callbacks record the
/// first failure in `err` and skip all further work; `generate` re-raises it
/// after the visitor returns.
const GenerateCtx = struct {
    bucketer: *CommandBucketer = undefined,
    allocator: std.mem.Allocator = undefined,
    attrs_idx: u32 = 0,
    draw_id: ?u32 = null,
    /// `true` for `pop_layer`'s layer-fill generation, `false` for paint
    /// fills.
    layer_fill: bool,
    /// Occupied-row flags for layer fills (indexed by row).
    occupied: []const bool = &.{},
    origin_tile_x: u16 = 0,
    origin_tile_y: u16 = 0,
    err: ?Error = null,

    pub fn onAlphaSegment(self: *GenerateCtx, segment: StripAlphaFillSegment) void {
        if (self.err != null) return;
        self.emit(segment.fill, segment.alpha_idx) catch |err| {
            self.err = err;
        };
    }

    pub fn onFillSegment(self: *GenerateCtx, segment: StripFillSegment) void {
        if (self.err != null) return;
        self.emit(segment, null) catch |err| {
            self.err = err;
        };
    }

    fn emit(self: *GenerateCtx, fill: StripFillSegment, alpha_idx: ?u32) Error!void {
        const row_idx = @as(usize, fill.tile_y - self.origin_tile_y);
        const x0 = (fill.tile_x0 - self.origin_tile_x) * TILE_WIDTH;
        const x1 = (fill.tile_x1 - self.origin_tile_x) * TILE_WIDTH;
        const span = Span.new(x0, x1 - x0);

        if (self.layer_fill) {
            if (!self.occupied[row_idx]) return;
            try self.bucketer.row_states.items[row_idx].pushCmd(self.allocator, .{
                .layer_fill = LayerFill.new(span, alpha_idx, self.attrs_idx),
            });
            return;
        }

        if (alpha_idx) |idx| {
            try self.bucketer.pushAlphaCmd(self.allocator, .{
                .row_idx = row_idx,
                .span = span,
                .alpha_idx = idx,
            }, self.attrs_idx);
        } else {
            try self.bucketer.pushFillCmd(self.allocator, .{
                .row_idx = row_idx,
                .span = span,
            }, self.attrs_idx, self.draw_id);
        }
    }
};

/// Context for `depth.splitOpaqueSpan`, which is non-fallible; the first
/// failure is recorded and re-raised by `pushFill`.
const PushFillCtx = struct {
    row: *RowState,
    allocator: std.mem.Allocator,
    attrs_idx: u32,
    draw_id: u32,
    err: ?Error = null,

    pub fn call(self: *PushFillCtx, segment: depth.DepthSegment) void {
        if (self.err != null) return;
        switch (segment) {
            .regular => |span| {
                self.row.pushCmd(self.allocator, .{
                    .paint_fill = PaintFill.new(span, null, self.attrs_idx),
                }) catch |err| {
                    self.err = err;
                };
            },
            .opaque_fill => |bucket_range| {
                self.row.pushDepthFill(
                    self.allocator,
                    cmd.DepthFill.new(bucket_range, self.attrs_idx),
                    self.draw_id,
                ) catch |err| {
                    self.err = err;
                };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (ports of the upstream `#[cfg(test)]` module)
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

fn fillAttrs(paint: Paint) PaintFillAttrs {
    return .{
        .paint = paint,
        .blend_mode = BlendMode.default,
        .mask = null,
        .draw_id = 1,
        .thread_idx = 0,
        .origin = .{ 0, 0 },
    };
}

fn layerProps() LayerProps {
    return LayerProps.default;
}

fn clippedLayerProps(bbox: RectU16) LayerProps {
    var props = LayerProps.default;
    props.clip_path = .{
        .strip_range = .{ .start = 0, .end = 0 },
        .thread_idx = 0,
        .bbox = bbox,
    };
    return props;
}

fn destructiveClippedLayerProps(bbox: RectU16) LayerProps {
    var props = clippedLayerProps(bbox);
    props.blend_mode = BlendMode.new(.normal, .clear);
    return props;
}

fn clippedLayerPropsWithStrips(bbox: RectU16, strip_start: usize, strip_end: usize) LayerProps {
    var props = LayerProps.default;
    props.clip_path = .{
        .strip_range = .{ .start = strip_start, .end = strip_end },
        .thread_idx = 0,
        .bbox = bbox,
    };
    return props;
}

fn countLayerFills(cmds: []const RenderCmd) usize {
    var count: usize = 0;
    for (cmds) |command| {
        if (std.meta.activeTag(command) == .layer_fill) count += 1;
    }
    return count;
}

test "opaque fill inside layer does not use depth write" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, depth.DEPTH_BUCKET_WIDTH, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(depth.DEPTH_BUCKET_WIDTH, 0, 0, true),
    };

    var props = layerProps();
    try bucketer.pushLayer(allocator, &props);
    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );

    const row = &bucketer.rows()[0];
    try testing.expectEqual(@as(usize, 0), row.depth_cmds.items.len);
    try testing.expectEqual(@as(usize, 2), row.render_cmds.items.len);
    try testing.expect(std.meta.activeTag(row.render_cmds.items[0]) == .push_buf);
    switch (row.render_cmds.items[1]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(@as(u16, 0), paint_fill.span.pixelX());
            try testing.expectEqual(depth.DEPTH_BUCKET_WIDTH, paint_fill.span.pixelWidth());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "alpha fill is clipped to active layer bbox" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, 8, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(12, 0, 48, false),
    };

    var props = clippedLayerProps(RectU16.new(4, 0, 8, 4));
    try bucketer.pushLayer(allocator, &props);
    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );

    const row = &bucketer.rows()[0];
    try testing.expectEqual(@as(usize, 2), row.render_cmds.items.len);
    try testing.expect(std.meta.activeTag(row.render_cmds.items[0]) == .push_buf);
    switch (row.render_cmds.items[1]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(@as(u16, 4), paint_fill.span.pixelX());
            try testing.expectEqual(@as(u16, 4), paint_fill.span.pixelWidth());
            try testing.expectEqual(@as(?u32, 4 * TILE_HEIGHT), paint_fill.alphaIdx());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "disjoint nested clip bounds do not emit commands" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, 16, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(16, 0, 0, true),
    };

    var outer = clippedLayerProps(RectU16.new(0, 0, 4, 4));
    var inner = clippedLayerProps(RectU16.new(8, 0, 12, 4));
    try bucketer.pushLayer(allocator, &outer);
    try bucketer.pushLayer(allocator, &inner);
    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );

    for (bucketer.rows()) |row| {
        try testing.expectEqual(@as(usize, 0), row.render_cmds.items.len);
    }
}

test "empty destructive clip does not push rows" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, 16, 4);
    defer bucketer.deinit(allocator);

    var outer = clippedLayerProps(RectU16.new(0, 0, 4, 4));
    var inner = destructiveClippedLayerProps(RectU16.new(8, 0, 12, 4));
    try bucketer.pushLayer(allocator, &outer);
    try bucketer.pushLayer(allocator, &inner);

    for (bucketer.rows()) |row| {
        try testing.expectEqual(@as(usize, 0), row.render_cmds.items.len);
    }
}

test "opaque fill uses depth write when possible" {
    const allocator = testing.allocator;
    const end = depth.DEPTH_BUCKET_WIDTH * 2 + 4;
    var bucketer = try CommandBucketer.init(allocator, end, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(4, 0, 0, false),
        Strip.new(end, 0, 0, true),
    };

    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );

    const row = &bucketer.rows()[0];
    try testing.expectEqual(@as(usize, 1), row.depth_cmds.items.len);
    try testing.expectEqual(
        depth.BucketRange.new(1, 2),
        row.depth_cmds.items[0].bucketRange(),
    );
    try testing.expectEqual(@as(usize, 2), row.render_cmds.items.len);
    switch (row.render_cmds.items[0]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(@as(u16, 4), paint_fill.span.pixelX());
            try testing.expectEqual(
                depth.DEPTH_BUCKET_WIDTH - 4,
                paint_fill.span.pixelWidth(),
            );
        },
        else => return error.TestUnexpectedResult,
    }
    switch (row.render_cmds.items[1]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(
                depth.DEPTH_BUCKET_WIDTH * 2,
                paint_fill.span.pixelX(),
            );
            try testing.expectEqual(@as(u16, 4), paint_fill.span.pixelWidth());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "non opaque fill uses regular commands" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, depth.DEPTH_BUCKET_WIDTH, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(depth.DEPTH_BUCKET_WIDTH, 0, 0, true),
    };

    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.BLUE.withAlpha(0.5))),
    );

    const row = &bucketer.rows()[0];
    try testing.expectEqual(@as(usize, 0), row.depth_cmds.items.len);
    try testing.expectEqual(@as(usize, 1), row.render_cmds.items.len);
    switch (row.render_cmds.items[0]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(@as(u16, 0), paint_fill.span.pixelX());
            try testing.expectEqual(depth.DEPTH_BUCKET_WIDTH, paint_fill.span.pixelWidth());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "clips fills correctly inside nonzero origin viewport" {
    const allocator = testing.allocator;
    // Viewport spans scene (32, 32) to (96, 96). Local space is 64x64, the
    // origin at (32, 32).
    var bucketer = try CommandBucketer.initViewport(allocator, RectU16.new(32, 32, 96, 96));
    defer bucketer.deinit(allocator);

    // Clip bbox in scene coordinates: (40, 32)..(72, 96) => local
    // (8, 0)..(40, 64).
    var props = clippedLayerProps(RectU16.new(40, 32, 72, 96));
    try bucketer.pushLayer(allocator, &props);

    // A 32px-wide alpha strip at scene (40, 32) => local (8, 0), fully inside
    // the clip.
    const strips = [_]Strip{
        Strip.new(40, 32, 0, false),
        Strip.new(72, 32, 32 * @as(u32, TILE_HEIGHT), false),
    };
    try bucketer.generateFill(
        allocator,
        &strips,
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );

    const row = &bucketer.rows()[0];
    try testing.expect(std.meta.activeTag(row.render_cmds.items[0]) == .push_buf);
    // The fill inside should not have been clipped.
    switch (row.render_cmds.items[1]) {
        .paint_fill => |paint_fill| {
            try testing.expectEqual(@as(u16, 8), paint_fill.span.pixelX());
            try testing.expectEqual(@as(u16, 32), paint_fill.span.pixelWidth());
            try testing.expectEqual(@as(?u32, 0), paint_fill.alphaIdx());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "culls clip strips above viewport origin" {
    const allocator = testing.allocator;
    // Viewport spans scene (0, 32) to (64, 96). Local space is 64x64, the
    // origin at (0, 32).
    var bucketer = try CommandBucketer.initViewport(allocator, RectU16.new(0, 32, 64, 96));
    defer bucketer.deinit(allocator);

    const alpha = @as(u32, TILE_HEIGHT);
    const strips = [_]Strip{
        // Content: 16px alpha strip at scene (0, 32) => local row 0.
        Strip.new(0, 32, 0, false),
        Strip.new(16, 32, 16 * alpha, false),
        // Clip strip above the viewport origin at scene y = 0, covering
        // nothing visible.
        Strip.new(0, 0, 16 * alpha, false),
        Strip.new(16, 0, 32 * alpha, false),
        // Clip strip at scene y = 32 => local row 0: the real coverage.
        Strip.new(0, 32, 32 * alpha, false),
        Strip.new(16, 32, 48 * alpha, false),
    };

    // Clip bbox in scene coordinates: (0, 0)..(16, 40) => local
    // (0, 0)..(16, 8).
    var props = clippedLayerPropsWithStrips(RectU16.new(0, 0, 16, 40), 2, 6);
    try bucketer.pushLayer(allocator, &props);
    try bucketer.generateFill(
        allocator,
        strips[0..2],
        fillAttrs(Paint.fromAlphaColor(palette.RED)),
    );
    try bucketer.popLayer(allocator, &strips);

    const row = &bucketer.rows()[0];
    try testing.expectEqual(
        @as(usize, 1),
        countLayerFills(row.render_cmds.items),
    );
}

test "bucketer rows are tile aligned" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, 5, 5);
    defer bucketer.deinit(allocator);

    try testing.expectEqual(@as(u16, 8), bucketer.width);
    try testing.expectEqual(@as(u16, 8), bucketer.height);
    try testing.expectEqual(@as(usize, 2), bucketer.rows().len);

    const attrs = PaintFillAttrs{
        .paint = .{ .solid = paint_mod.PremulColor.fromAlphaColor(peniko.Color.BLACK) },
        .blend_mode = peniko.BlendMode.default,
        .mask = null,
        .draw_id = 1,
        .thread_idx = 0,
        .origin = .{ 0, 0 },
    };
    try bucketer.paint_fill_attrs.append(allocator, attrs);
    try bucketer.row_states.items[0].pushBuf(allocator);
    try bucketer.row_states.items[0].pushCmd(allocator, .{
        .paint_fill = cmd.PaintFill.new(Span.new(0, 8), null, 0),
    });
    try bucketer.row_states.items[0].popBuf(allocator);

    try testing.expectEqual(@as(usize, 3), bucketer.rows()[0].render_cmds.items.len);
    try testing.expectEqual(@as(usize, 0), bucketer.rows()[0].layer_depth);
    // The push command carries the span accumulated from the paint fill.
    switch (bucketer.rows()[0].render_cmds.items[0]) {
        .push_buf => |span| try testing.expectEqual(@as(?Span, Span.new(0, 8)), span),
        else => return error.TestUnexpectedResult,
    }
}

test "generate_fill rejects indexed paints" {
    const allocator = testing.allocator;
    var bucketer = try CommandBucketer.init(allocator, 8, 4);
    defer bucketer.deinit(allocator);

    const strips = [_]Strip{
        Strip.new(0, 0, 0, false),
        Strip.new(8, 0, 0, true),
    };
    var attrs = fillAttrs(.{ .indexed = try paint_mod.IndexedPaint.new(0) });
    attrs.draw_id = 1;

    try testing.expectError(
        error.Unsupported,
        bucketer.generateFill(allocator, &strips, attrs),
    );
}
