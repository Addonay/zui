//! Drawing COLR glyphs.
//!
//! Port of `glifo/src/colr.rs` together with the `skrifa 0.44.0` color
//! machinery it drives: `skrifa/src/color/mod.rs` (the `ColorGlyph` collection
//! and paint entry point), `color/instance.rs` (`resolve_paint`,
//! `resolve_clip_box`, color-stop resolution), `color/traversal.rs` (paint
//! graph DFS, composite layers, decycler) and `color/transform.rs` (matrix
//! conversion), plus skrifa's `decycler.rs` cycle check.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3, T4):
//! - `ColorPainter` becomes the type-erased `Painter` vtable (`&mut dyn
//!   ColorPainter` upstream). A comptime-generic painter would monomorphize
//!   the nested `Glyph` optimization without bound, so traversal always goes
//!   through the vtable. The `fill_glyph` default method from the Rust trait
//!   is the free function `traitFillGlyph`; every painter exposes `fillGlyph`
//!   calling it, and `CollectFillGlyphPainter` deliberately inherits it so
//!   nested `Glyph` paints fall back to the unoptimized traversal (upstream
//!   semantics).
//! - Allocating sinks take the allocator and return `!void`; the traversal
//!   therefore uses `anyerror` internally. Upstream `glifo` ignores paint
//!   errors ("for now") and `paint()` here catches the `tables.colr` parse
//!   errors while propagating `error.OutOfMemory` and any other backend error
//!   (which upstream would abort on). The remaining stack entries are popped
//!   afterwards, exactly like upstream.
//! - Variation coordinates are rejected at run preparation, so the traversal
//!   is always invoked with empty coordinates: `skrifa` would resolve every
//!   `Var*` delta to zero, which is what `tables/colr.zig` implements.
//! - Upstream derives `CachedOutline` for clip glyphs through an
//!   `OutlineCacheSession`; this port passes the cache and allocator
//!   explicitly.
//! - `palette_index_to_color` indexes the raw CPAL color-record array exactly
//!   like upstream (which is the first palette when its start index is 0).
//!   Out-of-range indices panic upstream and resolve to `null` (BLACK) here.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const paint_mod = @import("../common/paint.zig");
const sfnt = @import("tables/sfnt.zig");
const tables = @import("tables/colr.zig");
const cpal_mod = @import("tables/cpal.zig");
const glyf = @import("glyf.zig");
const outline_cache = @import("outline_cache.zig");
const util = @import("util.zig");
const glyph_mod = @import("glyph.zig");
const atlas_commands = @import("atlas/commands.zig");

const FontInfo = outline_cache.FontInfo;
const FontEmbolden = outline_cache.FontEmbolden;
const CachedOutline = outline_cache.CachedOutline;

/// A resolved color stop (`skrifa::color::ColorStop` with deltas applied).
pub const ColorStop = struct {
    offset: f32,
    palette_index: u16,
    alpha: f32,
};

/// A resolved brush (`skrifa::color::Brush`), holding f32 font-unit geometry.
pub const Brush = union(enum) {
    solid: struct { palette_index: u16, alpha: f32 },
    linear_gradient: struct {
        p0: PointF,
        p1: PointF,
        color_stops: []const ColorStop,
        extend: tables.Extend,
    },
    radial_gradient: struct {
        c0: PointF,
        r0: f32,
        c1: PointF,
        r1: f32,
        color_stops: []const ColorStop,
        extend: tables.Extend,
    },
    sweep_gradient: struct {
        c0: PointF,
        start_angle: f32,
        end_angle: f32,
        color_stops: []const ColorStop,
        extend: tables.Extend,
    },
};

/// Type-erased `ColorPainter` (upstream `&mut dyn ColorPainter`).
///
/// `traverse` drives this instead of taking the painter type as a comptime
/// parameter: nested `Glyph` paints wrap the painter in a
/// `CollectFillGlyphPainter`, and a generic design would monomorphize that
/// nesting without bound. The two concrete painters (`ColrPainter(Sink)` and
/// `GlyphInfoExtractor`) and the collector install their own vtable.
pub const Painter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        pushTransform: *const fn (context: *anyopaque, transform: tables.Affine2x3) anyerror!void,
        popTransform: *const fn (context: *anyopaque) void,
        pushClipGlyph: *const fn (context: *anyopaque, glyph_id: u16) anyerror!void,
        pushClipBox: *const fn (context: *anyopaque, clip_box: tables.ClipBox) anyerror!void,
        popClip: *const fn (context: *anyopaque) anyerror!void,
        fill: *const fn (context: *anyopaque, brush: Brush) anyerror!void,
        pushLayer: *const fn (context: *anyopaque, mode: tables.CompositeMode) anyerror!void,
        popLayer: *const fn (context: *anyopaque) anyerror!void,
        fillGlyph: *const fn (
            context: *anyopaque,
            glyph_id: u16,
            brush_transform: ?tables.Affine2x3,
            brush: Brush,
        ) anyerror!void,
    };

    /// Build a vtable from any concrete painter value (`*ColrPainter(Sink)`,
    /// `*GlyphInfoExtractor`, `*CollectFillGlyphPainter`). The pointer must
    /// stay alive (and unmoved) while the `Painter` is in use.
    pub fn init(pointer: anytype) Painter {
        const Pointer = @TypeOf(pointer);
        const Impl = struct {
            fn pushTransform(context: *anyopaque, transform: tables.Affine2x3) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.pushTransform(transform);
            }
            fn popTransform(context: *anyopaque) void {
                const self: Pointer = @ptrCast(@alignCast(context));
                self.popTransform();
            }
            fn pushClipGlyph(context: *anyopaque, glyph_id: u16) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.pushClipGlyph(glyph_id);
            }
            fn pushClipBox(context: *anyopaque, clip_box: tables.ClipBox) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.pushClipBox(clip_box);
            }
            fn popClip(context: *anyopaque) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.popClip();
            }
            fn fill(context: *anyopaque, brush: Brush) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.fill(brush);
            }
            fn pushLayer(context: *anyopaque, mode: tables.CompositeMode) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.pushLayer(mode);
            }
            fn popLayer(context: *anyopaque) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.popLayer();
            }
            fn fillGlyph(
                context: *anyopaque,
                glyph_id: u16,
                brush_transform: ?tables.Affine2x3,
                brush: Brush,
            ) anyerror!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.fillGlyph(glyph_id, brush_transform, brush);
            }
        };
        return .{
            .context = @ptrCast(pointer),
            .vtable = &.{
                .pushTransform = Impl.pushTransform,
                .popTransform = Impl.popTransform,
                .pushClipGlyph = Impl.pushClipGlyph,
                .pushClipBox = Impl.pushClipBox,
                .popClip = Impl.popClip,
                .fill = Impl.fill,
                .pushLayer = Impl.pushLayer,
                .popLayer = Impl.popLayer,
                .fillGlyph = Impl.fillGlyph,
            },
        };
    }

    pub fn pushTransform(self: *const Painter, transform: tables.Affine2x3) anyerror!void {
        return self.vtable.pushTransform(self.context, transform);
    }

    pub fn popTransform(self: *const Painter) void {
        self.vtable.popTransform(self.context);
    }

    pub fn pushClipGlyph(self: *const Painter, glyph_id: u16) anyerror!void {
        return self.vtable.pushClipGlyph(self.context, glyph_id);
    }

    pub fn pushClipBox(self: *const Painter, clip_box: tables.ClipBox) anyerror!void {
        return self.vtable.pushClipBox(self.context, clip_box);
    }

    pub fn popClip(self: *const Painter) anyerror!void {
        return self.vtable.popClip(self.context);
    }

    pub fn fill(self: *const Painter, brush: Brush) anyerror!void {
        return self.vtable.fill(self.context, brush);
    }

    pub fn pushLayer(self: *const Painter, mode: tables.CompositeMode) anyerror!void {
        return self.vtable.pushLayer(self.context, mode);
    }

    pub fn popLayer(self: *const Painter) anyerror!void {
        return self.vtable.popLayer(self.context);
    }

    pub fn fillGlyph(
        self: *const Painter,
        glyph_id: u16,
        brush_transform: ?tables.Affine2x3,
        brush: Brush,
    ) anyerror!void {
        return self.vtable.fillGlyph(self.context, glyph_id, brush_transform, brush);
    }
};

/// f32 point (`read_fonts::types::Point<f32>`), kept f32 so traversal math is
/// bit-identical to skrifa; widened to `kurbo.Point` only at the sink.
pub const PointF = struct {
    x: f32,
    y: f32,

    pub fn new(x: f32, y: f32) PointF {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: PointF, b: PointF) PointF {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: PointF, b: PointF) PointF {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: PointF, s: f32) PointF {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn eql(a: PointF, b: PointF) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// HarfBuzz-style DFS cycle detector (`skrifa::decycler::Decycler<usize, 64>`).
pub const PaintDecycler = struct {
    node_ids: [tables.max_traversal_depth]usize = @splat(0),
    depth: usize = 0,

    /// Enter a node; returns `error.PaintCycleDetected` when the Floyd
    /// half-depth check collides and `error.DepthLimitExceeded` at the limit.
    /// The caller must `leave()` exactly once per successful `enter()`.
    pub fn enter(self: *PaintDecycler, node_id: usize) tables.Error!void {
        if (self.depth < tables.max_traversal_depth) {
            if (self.depth == 0 or self.node_ids[self.depth / 2] != node_id) {
                self.node_ids[self.depth] = node_id;
                self.depth += 1;
                return;
            }
            return error.PaintCycleDetected;
        }
        return error.DepthLimitExceeded;
    }

    pub fn leave(self: *PaintDecycler) void {
        self.depth -= 1;
    }
};

/// A color glyph: either a COLRv0 layer range or a COLRv1 paint graph.
pub const ColorGlyph = struct {
    colr: tables.Colr,
    root: Root,

    pub const Root = union(enum) {
        v0_range: tables.LayerRange,
        v1_paint: struct {
            paint: tables.Paint,
            glyph_id: u16,
        },
    };

    /// `ColorGlyph::format`.
    pub fn format(self: ColorGlyph) Format {
        return switch (self.root) {
            .v0_range => .colr_v0,
            .v1_paint => .colr_v1,
        };
    }

    /// `ColorGlyph::bounding_box(location, Size::unscaled())`: the COLRv1 clip
    /// box in font units, or `null` (always for COLRv0).
    pub fn boundingBox(self: ColorGlyph) ?tables.ClipBox {
        return switch (self.root) {
            .v1_paint => |v1| self.colr.v1ClipBox(v1.glyph_id),
            .v0_range => null,
        };
    }
};

/// `skrifa::color::ColorGlyphFormat`.
pub const Format = enum { colr_v0, colr_v1 };

/// `ColorGlyphCollection`: face-level COLR table plus glyph lookup.
pub const ColorGlyphCollection = struct {
    colr: ?tables.Colr,

    /// `ColorGlyphCollection::new(font)`: absent/malformed COLR tables resolve
    /// to an empty collection.
    pub fn init(face: sfnt.Face) ColorGlyphCollection {
        return .{
            .colr = if (face.table(sfnt.tag_colr)) |data| tables.Colr.parse(data) else null,
        };
    }

    /// `ColorGlyphCollection::get`: prefers COLRv1 over COLRv0.
    pub fn get(self: ColorGlyphCollection, glyph_id: u32) ?ColorGlyph {
        return self.getWithFormat(glyph_id, .colr_v1) orelse
            self.getWithFormat(glyph_id, .colr_v0);
    }

    /// `ColorGlyphCollection::get_with_format`.
    pub fn getWithFormat(
        self: ColorGlyphCollection,
        glyph_id: u32,
        glyph_format: Format,
    ) ?ColorGlyph {
        const colr = self.colr orelse return null;
        const root: ColorGlyph.Root = switch (glyph_format) {
            .colr_v0 => .{ .v0_range = colr.v0BaseGlyph(glyph_id) orelse return null },
            .colr_v1 => .{ .v1_paint = .{
                .paint = colr.v1BaseGlyph(glyph_id) orelse return null,
                .glyph_id = std.math.cast(u16, glyph_id) orelse return null,
            } },
        };
        return .{ .colr = colr, .root = root };
    }
};

/// `ColorGlyph::paint`: traverse `glyph` and drive `painter`.
///
/// The painter is type-erased (`Painter`); see its docs for why.
fn paintColorGlyph(
    allocator: std.mem.Allocator,
    painter: *const Painter,
    glyph: ColorGlyph,
) anyerror!void {
    switch (glyph.root) {
        .v1_paint => |v1| {
            const clip_box = glyph.colr.v1ClipBox(v1.glyph_id);
            if (clip_box) |cb| try painter.pushClipBox(cb);
            var decycler = PaintDecycler{};
            try decycler.enter(v1.paint.abs);
            defer decycler.leave();
            var stops: std.ArrayListUnmanaged(ColorStop) = .empty;
            defer stops.deinit(allocator);
            const resolved = try tables.resolvePaint(v1.paint);
            try traverse(allocator, glyph.colr, painter, resolved, &decycler, &stops, 0);
            if (clip_box != null) try painter.popClip();
        },
        .v0_range => |range| {
            const end = range.start + range.len;
            var i: usize = range.start;
            while (i < end) : (i += 1) {
                const layer = glyph.colr.v0Layer(i) orelse return error.MalformedFont;
                try painter.fillGlyph(
                    layer.glyph_id,
                    null,
                    .{ .solid = .{ .palette_index = layer.palette_index, .alpha = 1.0 } },
                );
            }
        },
    }
}

/// `traverse_with_callbacks`: DFS over the resolved paint graph.
///
/// The error set is intentionally `anyerror`: parse failures from
/// `tables.colr` (which `glifo` ignores) and backend/allocator failures from
/// the painter (which must propagate) share one channel. Callers filter with
/// `error.OutOfMemory` / `tables.Error` before swallowing.
fn traverse(
    allocator: std.mem.Allocator,
    colr: tables.Colr,
    painter: *const Painter,
    paint: tables.ResolvedPaint,
    decycler: *PaintDecycler,
    stops: *std.ArrayListUnmanaged(ColorStop),
    recurse_depth: usize,
) anyerror!void {
    if (recurse_depth >= tables.max_traversal_depth) return error.DepthLimitExceeded;
    switch (paint) {
        .colr_layers => |layers| {
            var i: usize = 0;
            while (i < layers.count) : (i += 1) {
                const layer = colr.v1Layer(layers.start + i) orelse return error.MalformedFont;
                try decycler.enter(layer.abs);
                defer decycler.leave();
                try traverse(
                    allocator,
                    colr,
                    painter,
                    try tables.resolvePaint(layer),
                    decycler,
                    stops,
                    recurse_depth + 1,
                );
            }
        },
        .solid => |solid| {
            try painter.fill(.{ .solid = .{
                .palette_index = solid.palette_index,
                .alpha = solid.alpha,
            } });
        },
        .linear_gradient => |gradient| {
            var p0 = PointF.new(gradient.x0, gradient.y0);
            const p1 = PointF.new(gradient.x1, gradient.y1);
            const p2 = PointF.new(gradient.x2, gradient.y2);

            try makeSortedResolvedStops(allocator, gradient.color_stops, stops);

            // If p0p1 or p0p2 are degenerate probably nothing should be drawn.
            // If p0p1 and p0p2 are parallel then one side is the first color
            // and the other side is the last color, depending on the
            // direction. For now, just use the first color.
            if (PointF.eql(p1, p0) or PointF.eql(p2, p0) or
                cross(PointF.sub(p1, p0), PointF.sub(p2, p0)) == 0.0)
            {
                if (stops.items.len != 0) {
                    const stop = stops.items[0];
                    try painter.fill(.{ .solid = .{
                        .palette_index = stop.palette_index,
                        .alpha = stop.alpha,
                    } });
                }
                return;
            }

            // Follow the implementation note in nanoemoji to compute a new
            // gradient end point P3 as the orthogonal projection of the vector
            // from p0 to p1 onto a line perpendicular to p0p2 through p0.
            var perpendicular_to_p2 = PointF.sub(p2, p0);
            perpendicular_to_p2 = PointF.new(perpendicular_to_p2.y, -perpendicular_to_p2.x);
            var p3 = PointF.add(p0, projectOnto(PointF.sub(p1, p0), perpendicular_to_p2));

            if (stops.items.len != 0) {
                const first_stop = stops.items[0];
                const last_stop = stops.items[stops.items.len - 1];
                var color_stop_range = last_stop.offset - first_stop.offset;

                // Nothing can be drawn for this situation.
                if (color_stop_range == 0.0 and gradient.extend != .pad) return;

                // In the Pad case, for providing normalized stops in the 0..1
                // range to the client, insert a color stop at the end.
                if (color_stop_range == 0.0 and gradient.extend == .pad) {
                    var extra_stop = last_stop;
                    extra_stop.offset += 1.0;
                    try stops.append(allocator, extra_stop);
                    color_stop_range = 1.0;
                }

                if (color_stop_range != 1.0 or first_stop.offset != 0.0) {
                    const p0_p3 = PointF.sub(p3, p0);
                    const p0_offset = PointF.scale(p0_p3, first_stop.offset);
                    const p3_offset = PointF.scale(p0_p3, last_stop.offset);

                    p3 = PointF.add(p0, p3_offset);
                    p0 = PointF.add(p0, p0_offset);

                    const scale_factor = 1.0 / color_stop_range;
                    const start_offset = first_stop.offset;
                    for (stops.items) |*stop| {
                        stop.offset = (stop.offset - start_offset) * scale_factor;
                    }
                }

                try painter.fill(.{ .linear_gradient = .{
                    .p0 = p0,
                    .p1 = p3,
                    .color_stops = stops.items,
                    .extend = gradient.extend,
                } });
            }
        },
        .radial_gradient => |gradient| {
            var c0 = PointF.new(gradient.x0, gradient.y0);
            var c1 = PointF.new(gradient.x1, gradient.y1);
            var radius0 = gradient.radius0;
            var radius1 = gradient.radius1;

            try makeSortedResolvedStops(allocator, gradient.color_stops, stops);

            if (stops.items.len != 0) {
                const first_stop = stops.items[0];
                const last_stop = stops.items[stops.items.len - 1];
                var color_stop_range = last_stop.offset - first_stop.offset;

                if (color_stop_range == 0.0 and gradient.extend != .pad) return;

                if (color_stop_range == 0.0 and gradient.extend == .pad) {
                    var extra_stop = last_stop;
                    extra_stop.offset += 1.0;
                    try stops.append(allocator, extra_stop);
                    color_stop_range = 1.0;
                }

                if (color_stop_range != 1.0 or first_stop.offset != 0.0) {
                    const c0_to_c1 = PointF.sub(c1, c0);
                    const radius_diff = radius1 - radius0;
                    const scale_factor = 1.0 / color_stop_range;

                    const c0_offset = PointF.scale(c0_to_c1, first_stop.offset);
                    const c1_offset = PointF.scale(c0_to_c1, last_stop.offset);
                    const stops_start_offset = first_stop.offset;

                    // Order of reassignments is important to avoid shadowing.
                    c1 = PointF.add(c0, c1_offset);
                    c0 = PointF.add(c0, c0_offset);
                    radius1 = radius0 + radius_diff * last_stop.offset;
                    radius0 += radius_diff * first_stop.offset;

                    for (stops.items) |*stop| {
                        stop.offset = (stop.offset - stops_start_offset) * scale_factor;
                    }
                }

                try painter.fill(.{ .radial_gradient = .{
                    .c0 = c0,
                    .r0 = radius0,
                    .c1 = c1,
                    .r1 = radius1,
                    .color_stops = stops.items,
                    .extend = gradient.extend,
                } });
            }
        },
        .sweep_gradient => |gradient| {
            // OpenType 1.9.1 adds a shift to the angle to ease specification
            // of a 0 to 360 degree sweep.
            const start_angle = gradient.start_angle * 180.0 + 180.0;
            const end_angle = gradient.end_angle * 180.0 + 180.0;

            const sector_angle = end_angle - start_angle;

            try makeSortedResolvedStops(allocator, gradient.color_stops, stops);
            if (stops.items.len == 0) return;

            const first_stop = stops.items[0];
            const last_stop = stops.items[stops.items.len - 1];
            var color_stop_range = last_stop.offset - first_stop.offset;

            var start_angle_scaled = start_angle + sector_angle * first_stop.offset;
            var end_angle_scaled = start_angle + sector_angle * last_stop.offset;

            const start_offset = first_stop.offset;

            if (color_stop_range == 0.0 and gradient.extend != .pad) return;

            if (color_stop_range == 0.0 and gradient.extend == .pad) {
                var offset_last = last_stop;
                offset_last.offset += 1.0;
                try stops.append(allocator, offset_last);
                color_stop_range = 1.0;
            }

            const scale_factor = 1.0 / color_stop_range;
            for (stops.items) |*stop| {
                stop.offset = (stop.offset - start_offset) * scale_factor;
            }

            // Convert counter-clockwise angles/stops to clockwise for the
            // shader when the gradient is not already reversed.
            start_angle_scaled = 360.0 - start_angle_scaled;
            end_angle_scaled = 360.0 - end_angle_scaled;

            if (start_angle_scaled >= end_angle_scaled) {
                const tmp = start_angle_scaled;
                start_angle_scaled = end_angle_scaled;
                end_angle_scaled = tmp;
                std.mem.reverse(ColorStop, stops.items);
                for (stops.items) |*stop| {
                    stop.offset = 1.0 - stop.offset;
                }
            }

            // "If the color line's extend mode is reflect or repeat and start
            // and end angle are equal, nothing shall be drawn."
            if (start_angle_scaled == end_angle_scaled and gradient.extend != .pad) return;

            try painter.fill(.{ .sweep_gradient = .{
                .c0 = PointF.new(gradient.center_x, gradient.center_y),
                .start_angle = start_angle_scaled,
                .end_angle = end_angle_scaled,
                .color_stops = stops.items,
                .extend = gradient.extend,
            } });
        },
        .glyph => |g| {
            var optimizer = CollectFillGlyphPainter{
                .glyph_id = g.glyph_id,
                .parent = painter,
            };
            var optimizer_painter = Painter.init(&optimizer);
            var result: anyerror!void = traverse(
                allocator,
                colr,
                &optimizer_painter,
                try tables.resolvePaint(g.paint),
                decycler,
                stops,
                recurse_depth + 1,
            );

            // In case the optimization was not successful, just push a clip,
            // and continue unoptimized traversal.
            if (!optimizer.optimization_success) {
                try painter.pushClipGlyph(g.glyph_id);
                result = traverse(
                    allocator,
                    colr,
                    painter,
                    try tables.resolvePaint(g.paint),
                    decycler,
                    stops,
                    recurse_depth + 1,
                );
                try painter.popClip();
            }
            return result;
        },
        .colr_glyph => |g| {
            const base = colr.v1BaseGlyph(g.glyph_id) orelse return error.GlyphNotFound;
            try decycler.enter(base.abs);
            defer decycler.leave();
            // `ColorGlyph::paint`'s nested-clipbox handling: every ColrGlyph
            // pushes its own clip box (when present) around its subgraph.
            const clip_box = colr.v1ClipBox(g.glyph_id);
            if (clip_box) |cb| try painter.pushClipBox(cb);
            const resolved = tables.resolvePaint(base) catch |err| return err;
            const result = traverse(
                allocator,
                colr,
                painter,
                resolved,
                decycler,
                stops,
                recurse_depth + 1,
            );
            if (clip_box != null) try painter.popClip();
            return result;
        },
        .transform,
        .translate,
        .scale,
        .rotate,
        .skew,
        => {
            try painter.pushTransform(try transformFromPaint(paint));
            const child = switch (paint) {
                .transform => |t| t.paint,
                .translate => |t| t.paint,
                .scale => |t| t.paint,
                .rotate => |t| t.paint,
                .skew => |t| t.paint,
                else => unreachable,
            };
            const result = traverse(
                allocator,
                colr,
                painter,
                try tables.resolvePaint(child),
                decycler,
                stops,
                recurse_depth + 1,
            );
            painter.popTransform();
            return result;
        },
        .composite => |c| {
            try painter.pushLayer(.src_over);
            var result: anyerror!void = traverse(
                allocator,
                colr,
                painter,
                try tables.resolvePaint(c.backdrop_paint),
                decycler,
                stops,
                recurse_depth + 1,
            );
            try result;
            try painter.pushLayer(c.mode);
            result = traverse(
                allocator,
                colr,
                painter,
                try tables.resolvePaint(c.source_paint),
                decycler,
                stops,
                recurse_depth + 1,
            );
            // `pop_layer_with_mode` defaults to `pop_layer` in skrifa, and
            // glifo's painter only implements `pop_layer`.
            try painter.popLayer();
            try painter.popLayer();
            return result;
        },
    }
}

/// `make_sorted_resolved_stops`: resolve the color line (zero variation
/// deltas) and sort by offset with `partial_cmp(..).unwrap_or(Equal)`.
fn makeSortedResolvedStops(
    allocator: std.mem.Allocator,
    color_stops: tables.ColorStops,
    out: *std.ArrayListUnmanaged(ColorStop),
) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < color_stops.len()) : (i += 1) {
        try out.append(allocator, .{
            .offset = color_stops.offset(i),
            .palette_index = color_stops.paletteIndex(i),
            .alpha = color_stops.alpha(i),
        });
    }
    std.mem.sort(ColorStop, out.items, {}, stopLessThan);
}

fn stopLessThan(_: void, a: ColorStop, b: ColorStop) bool {
    return partialCmp(a.offset, b.offset) == .lt;
}

/// `f32::partial_cmp` with NaN mapped to `Equal` (upstream
/// `unwrap_or(Ordering::Equal)`).
fn partialCmp(a: f32, b: f32) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn cross(a: PointF, b: PointF) f32 {
    return a.x * b.y - a.y * b.x;
}

fn dot(a: PointF, b: PointF) f32 {
    return a.x * b.x + a.y * b.y;
}

fn projectOnto(vector: PointF, point: PointF) PointF {
    const length = @sqrt(point.x * point.x + point.y * point.y);
    if (length == 0.0) return PointF.new(0.0, 0.0);
    const normalized_x = point.x / length;
    const normalized_y = point.y / length;
    const scale = dot(vector, point) / length;
    return PointF.new(normalized_x * scale, normalized_y * scale);
}

/// `transform.rs`: convert a resolved transform paint into an affine matrix.
fn transformFromPaint(paint: tables.ResolvedPaint) tables.Error!tables.Affine2x3 {
    return switch (paint) {
        .rotate => |r| blk: {
            const angle_rad = (r.angle * 180.0) * (std.math.pi / 180.0);
            const sin_v = @sin(angle_rad);
            const cos_v = @cos(angle_rad);
            var out = tables.Affine2x3{
                .xx = cos_v,
                .yx = sin_v,
                .xy = -sin_v,
                .yy = cos_v,
                .dx = 0.0,
                .dy = 0.0,
            };
            if (r.around_center) |center| {
                out.dx = sin_v * center[1] + (1.0 - cos_v) * center[0];
                out.dy = -sin_v * center[0] + (1.0 - cos_v) * center[1];
            }
            break :blk out;
        },
        .scale => |s| blk: {
            var out = tables.Affine2x3{
                .xx = s.scale_x,
                .yx = 0.0,
                .xy = 0.0,
                .yy = s.scale_y,
                .dx = 0.0,
                .dy = 0.0,
            };
            if (s.around_center) |center| {
                out.dx = center[0] - s.scale_x * center[0];
                out.dy = center[1] - s.scale_y * center[1];
            }
            break :blk out;
        },
        .skew => |k| blk: {
            const tan_x = @tan((k.x_skew_angle * 180.0) * (std.math.pi / 180.0));
            const tan_y = @tan((k.y_skew_angle * 180.0) * (std.math.pi / 180.0));
            var out = tables.Affine2x3{
                .xx = 1.0,
                .yx = tan_y,
                .xy = -tan_x,
                .yy = 1.0,
                .dx = 0.0,
                .dy = 0.0,
            };
            if (k.around_center) |center| {
                out.dx = tan_x * center[1];
                out.dy = -tan_y * center[0];
            }
            break :blk out;
        },
        .transform => |t| t.affine,
        .translate => |t| .{
            .xx = 1.0,
            .yx = 0.0,
            .xy = 0.0,
            .yy = 1.0,
            .dx = t.dx,
            .dy = t.dy,
        },
        else => error.MalformedFont,
    };
}

/// `ColorPainter::fill_glyph` default implementation.
fn traitFillGlyph(
    painter: anytype,
    glyph_id: u16,
    brush_transform: ?tables.Affine2x3,
    brush: Brush,
) anyerror!void {
    try painter.pushClipGlyph(glyph_id);
    if (brush_transform) |t| {
        try painter.pushTransform(t);
        try painter.fill(brush);
        painter.popTransform();
    } else {
        try painter.fill(brush);
    }
    try painter.popClip();
}

/// `CollectFillGlyphPainter`: try to collapse a `Glyph` subgraph into a single
/// `fill_glyph` call. Sets `optimization_success = false` on any clip/layer
/// operation, at which point the caller re-traverses unoptimized.
///
/// Deliberately concrete (the parent is a type-erased `Painter`), so nested
/// `Glyph` paints re-wrap instead of monomorphizing without bound.
const CollectFillGlyphPainter = struct {
    const Self = @This();

    brush_transform: ?tables.Affine2x3 = null,
    glyph_id: u16,
    parent: *const Painter,
    optimization_success: bool = true,

    /// `ColorPainter::fill_glyph` default: deliberately not a delegation to
    /// `parent`; `pushClipGlyph` marks the optimization unsuccessful, which is
    /// what nested `Glyph` paints must observe.
    pub fn fillGlyph(
        self: *Self,
        glyph_id: u16,
        brush_transform: ?tables.Affine2x3,
        brush: Brush,
    ) anyerror!void {
        return traitFillGlyph(self, glyph_id, brush_transform, brush);
    }

    pub fn pushTransform(self: *Self, t: tables.Affine2x3) anyerror!void {
        if (!self.optimization_success) return;
        if (self.brush_transform) |*existing| {
            existing.* = mulAffine(existing.*, t);
        } else {
            self.brush_transform = t;
        }
    }

    pub fn popTransform(self: *Self) void {
        _ = self;
        // Only fill and transform operations are supported here; a popped
        // transform is ignored so the accumulated brush transform survives.
    }

    pub fn fill(self: *Self, brush: Brush) anyerror!void {
        if (self.optimization_success) {
            try self.parent.fillGlyph(self.glyph_id, self.brush_transform, brush);
        }
    }

    pub fn pushClipGlyph(self: *Self, glyph_id: u16) anyerror!void {
        _ = glyph_id;
        self.optimization_success = false;
    }

    pub fn pushClipBox(self: *Self, clip_box: tables.ClipBox) anyerror!void {
        _ = clip_box;
        self.optimization_success = false;
    }

    pub fn popClip(self: *Self) anyerror!void {
        self.optimization_success = false;
    }

    pub fn pushLayer(self: *Self, mode: tables.CompositeMode) anyerror!void {
        _ = mode;
        self.optimization_success = false;
    }

    pub fn popLayer(self: *Self) anyerror!void {
        self.optimization_success = false;
    }
};

/// `read_fonts::types::Matrix<f32>` multiplication (apply rhs, then self).
fn mulAffine(a: tables.Affine2x3, b: tables.Affine2x3) tables.Affine2x3 {
    return .{
        .xx = a.xx * b.xx + a.xy * b.yx,
        .yx = a.yx * b.xx + a.yy * b.yx,
        .xy = a.xx * b.xy + a.xy * b.yy,
        .yy = a.yx * b.xy + a.yy * b.yy,
        .dx = a.xx * b.dx + a.xy * b.dy + a.dx,
        .dy = a.yx * b.dx + a.yy * b.dy + a.dy,
    };
}

/// `glifo::colr::convert_affine`.
pub fn convertAffine(t: tables.Affine2x3) kurbo.Affine {
    return kurbo.Affine.new(.{
        @as(f64, @floatCast(t.xx)),
        @as(f64, @floatCast(t.yx)),
        @as(f64, @floatCast(t.xy)),
        @as(f64, @floatCast(t.yy)),
        @as(f64, @floatCast(t.dx)),
        @as(f64, @floatCast(t.dy)),
    });
}

/// `glifo::colr::convert_composite_mode`.
pub fn convertCompositeMode(mode: tables.CompositeMode) peniko.BlendMode {
    return switch (mode) {
        .clear => .{ .mix = .normal, .compose = .clear },
        .src => .{ .mix = .normal, .compose = .copy },
        .dest => .{ .mix = .normal, .compose = .dest },
        .src_over => .{ .mix = .normal, .compose = .src_over },
        .dest_over => .{ .mix = .normal, .compose = .dest_over },
        .src_in => .{ .mix = .normal, .compose = .src_in },
        .dest_in => .{ .mix = .normal, .compose = .dest_in },
        .src_out => .{ .mix = .normal, .compose = .src_out },
        .dest_out => .{ .mix = .normal, .compose = .dest_out },
        .src_atop => .{ .mix = .normal, .compose = .src_atop },
        .dest_atop => .{ .mix = .normal, .compose = .dest_atop },
        .xor => .{ .mix = .normal, .compose = .xor },
        .plus => .{ .mix = .normal, .compose = .plus },
        .screen => .{ .mix = .screen, .compose = .src_over },
        .overlay => .{ .mix = .overlay, .compose = .src_over },
        .darken => .{ .mix = .darken, .compose = .src_over },
        .lighten => .{ .mix = .lighten, .compose = .src_over },
        .color_dodge => .{ .mix = .color_dodge, .compose = .src_over },
        .color_burn => .{ .mix = .color_burn, .compose = .src_over },
        .hard_light => .{ .mix = .hard_light, .compose = .src_over },
        .soft_light => .{ .mix = .soft_light, .compose = .src_over },
        .difference => .{ .mix = .difference, .compose = .src_over },
        .exclusion => .{ .mix = .exclusion, .compose = .src_over },
        .multiply => .{ .mix = .multiply, .compose = .src_over },
        .hsl_hue => .{ .mix = .hue, .compose = .src_over },
        .hsl_saturation => .{ .mix = .saturation, .compose = .src_over },
        .hsl_color => .{ .mix = .color, .compose = .src_over },
        .hsl_luminosity => .{ .mix = .luminosity, .compose = .src_over },
        .unknown => peniko.BlendMode.default,
    };
}

/// `glifo::colr::convert_extend`.
pub fn convertExtend(extend: tables.Extend) peniko.Extend {
    return switch (extend) {
        .pad => .pad,
        .repeat => .repeat,
        .reflect => .reflect,
        .unknown => .pad,
    };
}

/// `glifo::colr::convert_point`.
pub fn convertPoint(point: PointF) kurbo.Point {
    return kurbo.Point.new(@as(f64, @floatCast(point.x)), @as(f64, @floatCast(point.y)));
}

/// `glifo::colr::convert_bounding_box`.
pub fn convertBoundingBox(rect: tables.ClipBox) kurbo.Rect {
    return kurbo.Rect.new(
        @as(f64, @floatCast(rect.x_min)),
        @as(f64, @floatCast(rect.y_min)),
        @as(f64, @floatCast(rect.x_max)),
        @as(f64, @floatCast(rect.y_max)),
    );
}

/// `ColrGlyphInfo`: conservative bbox plus non-default-blend flag.
pub const ColrGlyphInfo = struct {
    /// `null` when the glyph has no drawable content.
    bbox: ?kurbo.Rect,
    has_non_default_blend: bool,
};

/// `get_colr_info`: traverse the paint graph with an extractor painter that
/// records the coarse bounding box and whether any non-default blending is
/// used. Paint errors are ignored like upstream (allocation failures are not).
pub fn getColrInfo(
    allocator: std.mem.Allocator,
    color_glyph: ColorGlyph,
    outlines: *const glyf.Outlines,
    outline_cache_ref: *outline_cache.OutlineCache,
    font_info: FontInfo,
) !ColrGlyphInfo {
    var extractor = try GlyphInfoExtractor.init(allocator, outlines, outline_cache_ref, font_info);
    defer extractor.deinit();
    var dynamic = Painter.init(&extractor);
    paintColorGlyph(allocator, &dynamic, color_glyph) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    return .{
        .bbox = extractor.coarse_bbox,
        .has_non_default_blend = extractor.has_non_default_blend,
    };
}

/// `GlyphInfoExtractor`: tracks transforms and a clip-box stack, ignoring
/// fills; used to compute a conservative glyph bounding box.
const GlyphInfoExtractor = struct {
    allocator: std.mem.Allocator,
    transforms: std.ArrayListUnmanaged(kurbo.Affine) = .empty,
    clip_stack: std.ArrayListUnmanaged(kurbo.Rect) = .empty,
    coarse_bbox: ?kurbo.Rect = null,
    has_non_default_blend: bool = false,
    outlines: *const glyf.Outlines,
    outline_cache: *outline_cache.OutlineCache,
    font_info: FontInfo,

    fn init(
        allocator: std.mem.Allocator,
        outlines: *const glyf.Outlines,
        cache: *outline_cache.OutlineCache,
        font_info: FontInfo,
    ) !GlyphInfoExtractor {
        var self = GlyphInfoExtractor{
            .allocator = allocator,
            .outlines = outlines,
            .outline_cache = cache,
            .font_info = font_info,
        };
        try self.transforms.append(allocator, kurbo.Affine.IDENTITY);
        return self;
    }

    fn deinit(self: *GlyphInfoExtractor) void {
        self.transforms.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
    }

    fn curTransform(self: *const GlyphInfoExtractor) kurbo.Affine {
        if (self.transforms.items.len == 0) return kurbo.Affine.IDENTITY;
        return self.transforms.items[self.transforms.items.len - 1];
    }

    fn pushClipBBox(self: *GlyphInfoExtractor, clip_bbox: kurbo.Rect) !void {
        const active = if (self.clip_stack.items.len != 0)
            self.clip_stack.items[self.clip_stack.items.len - 1].intersect(clip_bbox)
        else
            clip_bbox;
        self.coarse_bbox = if (self.coarse_bbox) |coarse| coarse.unionWith(active) else active;
        try self.clip_stack.append(self.allocator, active);
    }

    fn transformRect(self: *const GlyphInfoExtractor, rect: kurbo.Rect) kurbo.Rect {
        return self.curTransform().transformRectBbox(rect);
    }

    fn getOutline(self: *GlyphInfoExtractor, glyph_id: u16) anyerror!?CachedOutline {
        const outlines = self.outlines;
        const glyph = outlines.getGlyph(glyph_id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (glyph == null) return null;
        const outline = self.outline_cache.getOrInsert(
            self.allocator,
            outlines,
            glyph_id,
            self.font_info,
            self.font_info.upem,
            FontEmbolden{},
            &.{},
            null,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        return outline;
    }

    pub fn fillGlyph(
        self: *GlyphInfoExtractor,
        glyph_id: u16,
        brush_transform: ?tables.Affine2x3,
        brush: Brush,
    ) anyerror!void {
        return traitFillGlyph(self, glyph_id, brush_transform, brush);
    }

    pub fn pushTransform(self: *GlyphInfoExtractor, t: tables.Affine2x3) anyerror!void {
        try self.transforms.append(self.allocator, self.curTransform().compose(convertAffine(t)));
    }

    pub fn popTransform(self: *GlyphInfoExtractor) void {
        _ = self.transforms.pop();
    }

    pub fn pushClipGlyph(self: *GlyphInfoExtractor, glyph_id: u16) anyerror!void {
        const outline = (try self.getOutline(glyph_id)) orelse return;
        try self.pushClipBBox(self.transformRect(outline.bbox));
    }

    pub fn pushClipBox(self: *GlyphInfoExtractor, clip_box: tables.ClipBox) anyerror!void {
        try self.pushClipBBox(self.transformRect(convertBoundingBox(clip_box)));
    }

    pub fn popClip(self: *GlyphInfoExtractor) anyerror!void {
        _ = self.clip_stack.pop();
    }

    pub fn fill(self: *GlyphInfoExtractor, brush: Brush) anyerror!void {
        _ = self;
        _ = brush;
    }

    pub fn pushLayer(self: *GlyphInfoExtractor, mode: tables.CompositeMode) anyerror!void {
        self.has_non_default_blend = self.has_non_default_blend or
            !std.meta.eql(convertCompositeMode(mode), peniko.BlendMode.default);
    }

    pub fn popLayer(self: *GlyphInfoExtractor) anyerror!void {
        _ = self;
    }
};

/// `ColrPainter`: draws a COLR glyph into a `DrawSink`.
///
/// `Sink` is either `cpu.RenderContext` (direct rendering) or
/// `atlas.AtlasCommandRecorder` (deferred atlas recording); the emit helpers
/// below dispatch on the sink's method surface at comptime.
pub fn ColrPainter(comptime Sink: type) type {
    return struct {
        const Self = @This();

        /// True when the sink is the atlas command recorder (which clones
        /// owned paths and takes ownership of recorded gradients).
        const is_recorder = @hasDecl(Sink, "setPaintAtlas");

        allocator: std.mem.Allocator,
        transforms: std.ArrayListUnmanaged(kurbo.Affine) = .empty,
        colr_glyph: *const glyph_mod.GlyphColr,
        outline_cache: *outline_cache.OutlineCache,
        clip_outline: kurbo.BezPath = .{},
        context_color: peniko.Color,
        painter: *Sink,
        stack: std.ArrayListUnmanaged(StackEntry) = .empty,
        skip_blend_layers: bool,

        const StackEntry = enum {
            clip_path,
            blend_layer,
        };

        /// `ColrPainter::new`.
        pub fn init(
            allocator: std.mem.Allocator,
            colr_glyph: *const glyph_mod.GlyphColr,
            context_color: peniko.Color,
            painter: *Sink,
            outline_cache_ref: *outline_cache.OutlineCache,
        ) !Self {
            var self = Self{
                .allocator = allocator,
                .colr_glyph = colr_glyph,
                .outline_cache = outline_cache_ref,
                .context_color = context_color,
                .painter = painter,
                .skip_blend_layers = !colr_glyph.has_non_default_blend,
            };
            try self.transforms.append(allocator, colr_glyph.draw_transform);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.transforms.deinit(self.allocator);
            self.stack.deinit(self.allocator);
            self.clip_outline.deinit(self.allocator);
        }

        /// `ColrPainter::paint`: ignore paint graph errors, propagate sink
        /// failures, then unwind any layers/clips left open by a malformed
        /// graph (upstream behavior).
        pub fn paint(self: *Self) !void {
            self.paintInner() catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.MalformedFont,
                error.GlyphNotFound,
                error.PaintCycleDetected,
                error.DepthLimitExceeded,
                => {},
                else => return err,
            };
            while (self.stack.items.len != 0) {
                const entry = self.stack.pop().?;
                switch (entry) {
                    .clip_path => try emitPopClipPath(self.painter, self.allocator),
                    .blend_layer => try emitPopLayer(self.painter, self.allocator),
                }
            }
        }

        fn paintInner(self: *Self) anyerror!void {
            var dynamic = Painter.init(self);
            try paintColorGlyph(self.allocator, &dynamic, self.colr_glyph.color_glyph);
        }

        fn curTransform(self: *const Self) kurbo.Affine {
            if (self.transforms.items.len == 0) return kurbo.Affine.IDENTITY;
            return self.transforms.items[self.transforms.items.len - 1];
        }

        fn getOutline(self: *Self, glyph_id: u16) anyerror!?CachedOutline {
            const outlines = self.colr_glyph.outlines;
            const glyph = outlines.getGlyph(glyph_id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
            if (glyph == null) return null;
            const outline = self.outline_cache.getOrInsert(
                self.allocator,
                outlines,
                glyph_id,
                self.colr_glyph.font_info,
                self.colr_glyph.font_info.upem,
                FontEmbolden{},
                &.{},
                null,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
            return outline;
        }

        fn paletteIndexToColor(self: *const Self, palette_index: u16, alpha: f32) ?peniko.Color {
            if (palette_index != std.math.maxInt(u16)) {
                const cpal = self.colr_glyph.cpal orelse return null;
                const records = cpal.colorRecords() orelse return null;
                if (palette_index >= records.len) return null;
                const record = records[palette_index];
                return peniko.Color
                    .fromRgba8(record.red, record.green, record.blue, record.alpha)
                    .multiplyAlpha(alpha);
            }
            return self.context_color.multiplyAlpha(alpha);
        }

        /// `convert_stops`: resolve palette colors, pad to [0, 1], and drop all
        /// but the last stop at offset 1.0 (COLR spec requirement).
        fn convertStops(
            self: *Self,
            stops_in: []const ColorStop,
            out: *std.ArrayListUnmanaged(peniko.ColorStop),
        ) !void {
            out.clearRetainingCapacity();
            for (stops_in) |stop| {
                const color = self.paletteIndexToColor(stop.palette_index, stop.alpha) orelse
                    peniko.Color.BLACK;
                try out.append(self.allocator, .{ .offset = stop.offset, .color = color });
            }
            if (out.items.len == 0) return;
            const first_stop = out.items[0];
            const last_stop = out.items[out.items.len - 1];

            if (first_stop.offset != 0.0) {
                try out.insert(self.allocator, 0, first_stop);
            }
            if (last_stop.offset != 1.0) {
                try out.append(self.allocator, last_stop);
            }

            while (out.items.len >= 2) {
                const stop_offset = out.items[out.items.len - 2].offset;
                if (util.isNearlyZero(stop_offset - 1.0)) {
                    _ = out.orderedRemove(out.items.len - 2);
                } else {
                    break;
                }
            }
        }

        fn fillSolid(self: *Self, rect: kurbo.Rect, color: peniko.Color) !void {
            try emitPaint(self.painter, self.allocator, .{ .solid = color });
            try self.painter.fillRect(self.allocator, rect);
        }

        fn fillGradient(self: *Self, rect: kurbo.Rect, gradient: peniko.Gradient) !void {
            var grad = gradient;
            defer if (!is_recorder) grad.deinit();
            try emitPaint(self.painter, self.allocator, .{ .gradient = grad });
            try self.painter.fillRect(self.allocator, rect);
        }

        fn pushClip(self: *Self) !void {
            try emitClipPath(self.painter, self.allocator, &self.clip_outline, false);
            try self.stack.append(self.allocator, .clip_path);
        }

        fn popStackEntry(self: *Self, expected: StackEntry) bool {
            if (self.stack.items.len == 0) return false;
            if (self.stack.items[self.stack.items.len - 1] != expected) return false;
            _ = self.stack.pop();
            return true;
        }

        pub fn fillGlyph(
            self: *Self,
            glyph_id: u16,
            brush_transform: ?tables.Affine2x3,
            brush: Brush,
        ) anyerror!void {
            return traitFillGlyph(self, glyph_id, brush_transform, brush);
        }

        pub fn pushTransform(self: *Self, t: tables.Affine2x3) anyerror!void {
            try self.transforms.append(self.allocator, self.curTransform().compose(convertAffine(t)));
        }

        pub fn popTransform(self: *Self) void {
            _ = self.transforms.pop();
        }

        pub fn pushClipGlyph(self: *Self, glyph_id: u16) anyerror!void {
            const outline = (try self.getOutline(glyph_id)) orelse return;
            self.clip_outline.truncate(0);
            for (outline.path.elementsSlice()) |element| {
                try self.clip_outline.append(self.allocator, element);
            }
            self.clip_outline.applyAffine(self.curTransform());
            try self.pushClip();
        }

        pub fn pushClipBox(self: *Self, clip_box: tables.ClipBox) anyerror!void {
            const rect = convertBoundingBox(clip_box);
            const transformed = self.curTransform().transformRectBbox(rect);
            self.clip_outline.truncate(0);
            // `transformed.path_elements(0.1)` for a rectangle.
            try self.clip_outline.append(
                self.allocator,
                kurbo.PathEl.moveTo(kurbo.Point.new(transformed.x0, transformed.y0)),
            );
            try self.clip_outline.append(
                self.allocator,
                kurbo.PathEl.lineTo(kurbo.Point.new(transformed.x1, transformed.y0)),
            );
            try self.clip_outline.append(
                self.allocator,
                kurbo.PathEl.lineTo(kurbo.Point.new(transformed.x1, transformed.y1)),
            );
            try self.clip_outline.append(
                self.allocator,
                kurbo.PathEl.lineTo(kurbo.Point.new(transformed.x0, transformed.y1)),
            );
            try self.clip_outline.append(self.allocator, kurbo.PathEl.closePath());
            try self.pushClip();
        }

        pub fn popClip(self: *Self) anyerror!void {
            if (self.popStackEntry(.clip_path)) {
                try emitPopClipPath(self.painter, self.allocator);
            }
        }

        pub fn fill(self: *Self, brush: Brush) anyerror!void {
            // Ceil so that we don't apply unnecessary anti-aliasing in case
            // the glyph area is at a sub-pixel position.
            const fill_rect = self.colr_glyph.area.ceil();
            var stops: std.ArrayListUnmanaged(peniko.ColorStop) = .empty;
            defer stops.deinit(self.allocator);

            switch (brush) {
                .solid => |solid| {
                    const color = self.paletteIndexToColor(solid.palette_index, solid.alpha) orelse
                        peniko.Color.BLACK;
                    try self.fillSolid(fill_rect, color);
                },
                .linear_gradient => |gradient| {
                    const p0 = convertPoint(gradient.p0);
                    const p1 = convertPoint(gradient.p1);
                    const extend = convertExtend(gradient.extend);
                    try self.convertStops(gradient.color_stops, &stops);

                    if (stops.items.len == 1) {
                        try self.fillSolid(fill_rect, stops.items[0].color);
                    } else {
                        const grad = try (peniko.Gradient{
                            .kind = .{ .linear = .{ .start = p0, .end = p1 } },
                            .extend = extend,
                        }).withStops(self.allocator, stops.items);
                        try emitPaintTransform(self.painter, self.allocator, self.curTransform());
                        try self.fillGradient(fill_rect, grad);
                    }
                },
                .radial_gradient => |gradient| {
                    // TODO: Radial gradients with negative r0.
                    const p0 = convertPoint(gradient.c0);
                    const p1 = convertPoint(gradient.c1);
                    const extend = convertExtend(gradient.extend);
                    try self.convertStops(gradient.color_stops, &stops);

                    if (gradient.r1 <= 0.0 or stops.items.len == 1) {
                        try self.fillSolid(fill_rect, stops.items[0].color);
                        return;
                    }

                    const grad = try (peniko.Gradient{
                        .kind = .{ .radial = .{
                            .start_center = p0,
                            .start_radius = gradient.r0,
                            .end_center = p1,
                            .end_radius = gradient.r1,
                        } },
                        .extend = extend,
                    }).withStops(self.allocator, stops.items);

                    try emitPaintTransform(self.painter, self.allocator, self.curTransform());
                    try self.fillGradient(fill_rect, grad);
                },
                .sweep_gradient => |gradient| {
                    const p0 = convertPoint(gradient.c0);
                    const extend = convertExtend(gradient.extend);
                    try self.convertStops(gradient.color_stops, &stops);

                    if (stops.items.len == 1) {
                        try self.fillSolid(fill_rect, stops.items[0].color);
                        return;
                    }

                    var end_angle = gradient.end_angle;
                    if (gradient.start_angle == end_angle) {
                        switch (extend) {
                            .pad => end_angle += 0.01,
                            // Cannot be reached, see fontations issue #1017.
                            else => unreachable,
                        }
                    }

                    // Invert the direction of the gradient to bridge the gap
                    // between peniko and COLR.
                    const grad = try (peniko.Gradient{
                        .kind = .{ .sweep = .{
                            .center = kurbo.Point.new(p0.x, -p0.y),
                            .start_angle = degreesToRadians(gradient.start_angle),
                            .end_angle = degreesToRadians(end_angle),
                        } },
                        .extend = extend,
                    }).withStops(self.allocator, stops.items);

                    const paint_transform = self.curTransform()
                        .compose(kurbo.Affine.scaleNonUniform(1.0, -1.0));
                    try emitPaintTransform(self.painter, self.allocator, paint_transform);
                    try self.fillGradient(fill_rect, grad);
                },
            }
        }

        pub fn pushLayer(self: *Self, mode: tables.CompositeMode) anyerror!void {
            const blend_mode = convertCompositeMode(mode);
            if (!self.skip_blend_layers) {
                try emitPushBlendLayer(self.painter, self.allocator, blend_mode);
                try self.stack.append(self.allocator, .blend_layer);
            }
        }

        pub fn popLayer(self: *Self) anyerror!void {
            if (!self.skip_blend_layers and self.popStackEntry(.blend_layer)) {
                try emitPopLayer(self.painter, self.allocator);
            }
        }
    };
}

/// `f32::to_radians`.
fn degreesToRadians(degrees: f32) f32 {
    const radians_per_degree: f32 = std.math.pi / 180.0;
    return degrees * radians_per_degree;
}

/// Emit a paint through a sink. The recorder takes ownership of a gradient's
/// stops; the direct `RenderContext` path clones them and the caller keeps the
/// original (`fillGradient` frees it).
fn emitPaint(
    sink: anytype,
    allocator: std.mem.Allocator,
    paint: atlas_commands.AtlasPaint,
) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        return sink.setPaintAtlas(allocator, paint);
    } else {
        const resolved = try paint.toPaintType(allocator);
        sink.setPaint(resolved);
    }
}

/// Push a clip path (or clip layer) through a sink: the recorder clones the
/// path into its command list, the renderer borrows its element slice.
fn emitClipPath(
    sink: anytype,
    allocator: std.mem.Allocator,
    path: *const kurbo.BezPath,
    comptime layer: bool,
) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        if (layer) {
            return sink.pushClipLayer(allocator, path);
        }
        return sink.pushClipPath(allocator, path);
    } else {
        if (layer) {
            return sink.pushClipLayer(allocator, path.elementsSlice());
        }
        return sink.pushClipPath(allocator, path.elementsSlice());
    }
}

/// Set the paint transform through a sink: the recorder records it (with the
/// allocator), the render context stores it directly.
fn emitPaintTransform(sink: anytype, allocator: std.mem.Allocator, t: kurbo.Affine) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        return sink.setPaintTransform(allocator, t);
    } else {
        sink.setPaintTransform(t);
        return;
    }
}

fn emitPopClipPath(sink: anytype, allocator: std.mem.Allocator) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        return sink.popClipPath(allocator);
    } else {
        sink.popClipPath();
        return;
    }
}

fn emitPopLayer(sink: anytype, allocator: std.mem.Allocator) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        return sink.popLayer(allocator);
    } else {
        sink.popLayer();
        return;
    }
}

fn emitPushBlendLayer(
    sink: anytype,
    allocator: std.mem.Allocator,
    blend_mode: peniko.BlendMode,
) !void {
    if (comptime @hasDecl(@TypeOf(sink.*), "setPaintAtlas")) {
        return sink.pushBlendLayer(allocator, blend_mode);
    } else {
        return sink.pushBlendLayer(blend_mode);
    }
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const test_fixture = @import("test_fixture.zig");

test "decycler detects a self-referential node" {
    var decycler = PaintDecycler{};
    try decycler.enter(7);
    try decycler.enter(8);
    try decycler.enter(9);
    decycler.leave();
    decycler.leave();
    decycler.leave();
    try testing.expectEqual(@as(usize, 0), decycler.depth);

    // Floyd half-depth check: the fourth node repeats the second.
    try decycler.enter(1);
    try decycler.enter(2);
    try decycler.enter(1);
    try testing.expectError(error.PaintCycleDetected, decycler.enter(2));
}

test "composite mode conversion covers the full table" {
    try testing.expectEqual(peniko.BlendMode.new(.normal, .clear), convertCompositeMode(.clear));
    try testing.expectEqual(peniko.BlendMode.new(.normal, .copy), convertCompositeMode(.src));
    try testing.expectEqual(peniko.BlendMode.new(.normal, .src_over), convertCompositeMode(.src_over));
    try testing.expectEqual(peniko.BlendMode.new(.multiply, .src_over), convertCompositeMode(.multiply));
    try testing.expectEqual(peniko.BlendMode.new(.luminosity, .src_over), convertCompositeMode(.hsl_luminosity));
    try testing.expectEqual(peniko.BlendMode.default, convertCompositeMode(.unknown));

    // Every non-unknown mode converts to a distinct, expected default-ness.
    var raw: u8 = 0;
    while (raw <= 27) : (raw += 1) {
        const mode = tables.compositeModeFromU8(raw);
        const blend = convertCompositeMode(mode);
        if (mode == .src_over) {
            try testing.expectEqual(peniko.BlendMode.default, blend);
        } else {
            try testing.expect(!std.meta.eql(blend, peniko.BlendMode.default));
        }
    }
}

test "transform conversion matches skrifa transform.rs" {
    // Rotate 0.5 (= 90 degrees, counter-clockwise). `angle_input` is forced
    // through a runtime mutation so `@sin`/`@cos` are the runtime libm calls
    // the implementation uses, not comptime evaluation.
    var angle_input: f32 = 0.5;
    angle_input += 0.0;
    const rotate = try transformFromPaint(.{ .rotate = .{
        .angle = angle_input,
        .around_center = null,
        .paint = .{ .data = &.{}, .abs = 0 },
    } });
    const angle_rad = (angle_input * 180.0) * (std.math.pi / 180.0);
    try testing.expectEqual(@sin(angle_rad), rotate.yx);
    try testing.expectEqual(@cos(angle_rad), rotate.xx);

    // Scale around a center composes the appropriate translation.
    const scale = try transformFromPaint(.{ .scale = .{
        .scale_x = 2.0,
        .scale_y = 3.0,
        .around_center = .{ 10.0, 20.0 },
        .paint = .{ .data = &.{}, .abs = 0 },
    } });
    try testing.expectEqual(@as(f32, 2.0), scale.xx);
    try testing.expectEqual(@as(f32, 3.0), scale.yy);
    try testing.expectEqual(@as(f32, -10.0), scale.dx);
    try testing.expectEqual(@as(f32, -40.0), scale.dy);

    // Translate maps to the identity matrix with a translation.
    const translate = try transformFromPaint(.{ .translate = .{
        .dx = 4.0,
        .dy = -2.0,
        .paint = .{ .data = &.{}, .abs = 0 },
    } });
    try testing.expectEqual(tables.Affine2x3{
        .xx = 1.0,
        .yx = 0.0,
        .xy = 0.0,
        .yy = 1.0,
        .dx = 4.0,
        .dy = -2.0,
    }, translate);
}

test "get_colr_info reports noto clip box and default blending" {
    const allocator = testing.allocator;
    const blob = try test_fixture.notoColor();
    const font = try @import("font.zig").Font.init(blob, 0);
    const outlines = try font.outlines();
    const face = try sfnt.Face.parse(blob, 0);
    const collection = ColorGlyphCollection.init(face);
    const color_glyph = collection.get(2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Format.colr_v1, color_glyph.format());
    try testing.expect(color_glyph.boundingBox() != null);

    var cache = outline_cache.OutlineCache{};
    defer cache.deinit(allocator);
    const info = try getColrInfo(
        allocator,
        color_glyph,
        &outlines,
        &cache,
        .{ .id = @intFromPtr(blob.ptr), .index = 0, .upem = @floatFromInt(font.unitsPerEm()) },
    );
    try testing.expect(!info.has_non_default_blend);
    try testing.expect(info.bbox != null);
    // The Noto subset's COLR glyph is a 136-unit wide triangle-ish shape.
    try testing.expect(info.bbox.?.width() > 0.0);
    try testing.expect(cache.cachedCount() > 0);
}

test "color glyph collection prefers v1 and finds v0" {
    const blob = try test_fixture.colrTestGlyphs();
    const face = try sfnt.Face.parse(blob, 0);
    const collection = ColorGlyphCollection.init(face);
    // Glyph 8 exists in both v0?/v1 only; glyph 168 is v0-only.
    const v1 = collection.get(8) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Format.colr_v1, v1.format());
    try testing.expect(collection.getWithFormat(8, .colr_v0) == null);
    const v0 = collection.get(168) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Format.colr_v0, v0.format());
    try testing.expect(v0.boundingBox() == null);
    try testing.expect(collection.get(7) == null);
}

/// Records the order and shape of painter callbacks (test helper).
const OrderRecorder = struct {
    const Event = union(enum) {
        clip_glyph: u16,
        clip_box,
        fill_solid: u16,
        fill_gradient,
        push_layer: tables.CompositeMode,
        pop_layer,
    };

    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,

    fn deinit(self: *OrderRecorder) void {
        self.events.deinit(self.allocator);
    }

    fn append(self: *OrderRecorder, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    pub fn fillGlyph(
        self: *OrderRecorder,
        glyph_id: u16,
        brush_transform: ?tables.Affine2x3,
        brush: Brush,
    ) anyerror!void {
        return traitFillGlyph(self, glyph_id, brush_transform, brush);
    }

    pub fn pushTransform(self: *OrderRecorder, transform: tables.Affine2x3) anyerror!void {
        _ = self;
        _ = transform;
    }

    pub fn popTransform(self: *OrderRecorder) void {
        _ = self;
    }

    pub fn pushClipGlyph(self: *OrderRecorder, glyph_id: u16) anyerror!void {
        try self.append(.{ .clip_glyph = glyph_id });
    }

    pub fn pushClipBox(self: *OrderRecorder, clip_box: tables.ClipBox) anyerror!void {
        _ = clip_box;
        try self.append(.clip_box);
    }

    pub fn popClip(self: *OrderRecorder) anyerror!void {
        _ = self;
    }

    pub fn fill(self: *OrderRecorder, brush: Brush) anyerror!void {
        switch (brush) {
            .solid => |solid| try self.append(.{ .fill_solid = solid.palette_index }),
            else => try self.append(.fill_gradient),
        }
    }

    pub fn pushLayer(self: *OrderRecorder, mode: tables.CompositeMode) anyerror!void {
        try self.append(.{ .push_layer = mode });
    }

    pub fn popLayer(self: *OrderRecorder) anyerror!void {
        try self.append(.pop_layer);
    }
};

test "composite traversal draws the backdrop before the source" {
    const allocator = testing.allocator;
    const blob = try test_fixture.colrTestGlyphs();
    const font = try @import("font.zig").Font.init(blob, 0);
    const collection = ColorGlyphCollection.init(font.face);
    // Glyph 156 is `Composite(SrcOver) { backdrop: ColrGlyph(166), source:
    // Glyph(161, solid) }`; the backdrop is a radial gradient clipped by
    // glyph 2.
    const color_glyph = collection.get(156) orelse return error.TestUnexpectedResult;

    var recorder = OrderRecorder{ .allocator = allocator };
    defer recorder.deinit();
    var dynamic = Painter.init(&recorder);
    try paintColorGlyph(allocator, &dynamic, color_glyph);

    // The root glyph and both nested ColrGlyphs (166 -> 95) carry clip boxes;
    // dropping the nested ones makes the backdrop cover the whole glyph area
    // (regression: fixtures `glyph_run_colr_test_glyphs*`).
    var clip_boxes: usize = 0;
    var draws: [4]OrderRecorder.Event = undefined;
    var draw_count: usize = 0;
    for (recorder.events.items) |event| {
        switch (event) {
            .clip_box => clip_boxes += 1,
            .push_layer, .pop_layer => {},
            else => {
                draws[draw_count] = event;
                draw_count += 1;
            },
        }
    }
    try testing.expectEqual(@as(usize, 3), clip_boxes);
    try testing.expectEqual(@as(usize, 4), draw_count);
    try testing.expectEqual(OrderRecorder.Event{ .clip_glyph = 2 }, draws[0]);
    try testing.expectEqual(OrderRecorder.Event.fill_gradient, draws[1]);
    try testing.expectEqual(OrderRecorder.Event{ .clip_glyph = 161 }, draws[2]);
    try testing.expectEqual(OrderRecorder.Event{ .fill_solid = 13 }, draws[3]);
}
