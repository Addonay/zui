//! Per-frame scene: the GPU-independent draw list.
//!
//! Why a collector: GPUI's `scene.rs` and Gooey's `scene/scene.zig` both
//! collect one frame of quads/glyphs on the CPU, then hand dense batches
//! to Metal/Vulkan/GL. Backends stay thin; batching and clipping live
//! here once. Storage is a fixed array so frames never allocate.
//!
//! ## Frame overflow policy (gap report §3)
//!
//! Pushes beyond capacity return false and count into `dropped`
//! (cumulative) and `dropped_frame` (this frame only, reset by `clear`).
//! A frame with `overflowed() == true` is REJECTED, never presented
//! partial:
//!
//! - `Window.render` replaces a rejected frame with the diagnostic
//!   placeholder (`renderOverflowPlaceholder`) and counts it in
//!   `rejected_frames`, so what reaches the backend is always complete.
//! - `App.step` counts the rejection in `App.rejected_frames` and logs it
//!   (`ZUI_LOG=1` shows the scope/counts), then presents the placeholder.
//! - Headless producers (`elements.painter.paint`, `tools/bench_text.zig`)
//!   check `overflowed()` directly; the benchmark fails loudly instead of
//!   reporting timings for missing content.
//!
//! Growing the caps is not the fix for unbounded content: shaping 39K
//! glyphs costs a full frame budget whether or not they fit. The fix for
//! large content is virtualization (don't shape invisible rows) plus this
//! reject-instead-of-partial policy. See docs/RENDER_CONTRACT.md.

const std = @import("std");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const geometry = @import("../core/geometry.zig");

pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: color.Color,
    radius: f32 = 0,
    /// Optional horizontal gradient end color (lerped left → right per
    /// pixel). Single-quad gradients keep rounded corners exact and avoid
    /// the banding/overdraw of multi-strip emulation.
    gradient_to: ?color.Color = null,
    /// Ring width in pixels. When > 0 the quad renders as a rounded-rect
    /// outline (outer shape minus the inset inner shape) instead of a fill.
    /// Borders honor `radius` exactly — the old 4-strip emulation drew
    /// square corners that poked past rounded backgrounds.
    border_width: f32 = 0,
    /// Painter clip at emission; the rasterizer tests it per pixel. Null
    /// means unclipped. Geometry is stored UNCUT (unlike the old
    /// pre-intersected pushes) so a partial clip keeps the corner radius;
    /// fully-clipped draws are dropped by the painter before pushing.
    clip: ?geometry.Rect = null,
};

/// One bounded custom-canvas line stroke. Endpoints and width are logical
/// pixels; the renderer applies the window scale exactly once. The payload is
/// deliberately limited to a single segment; multi-segment geometry is carried
/// by `Path`, while this payload remains the cheap line fast path.
pub const Stroke = struct {
    pub const Join = enum(u8) { miter, round, bevel };
    pub const Cap = enum(u8) { butt, round, square };
    from: geometry.Point,
    to: geometry.Point,
    color: color.Color,
    width: f32,
    join: Join = .round,
    cap: Cap = .round,
    miter_limit: f32 = 4,
    /// Painter clip at emission. A zero-area clip is not drawable; Canvas
    /// always supplies its non-empty hook clip.
    clip: geometry.Rect = .{},
};

/// Caller-owned storage for bounded custom line strokes. Window scenes attach
/// one from their heap-owned Window; standalone Scene{} values retain the
/// existing quad/glyph/blit behavior until a caller attaches storage.
pub const StrokeStorage = [limits.MAX_STROKES_PER_FRAME]Stroke;

/// A deliberately bounded path vocabulary.  This is the scene-side subset of
/// GPUI's path primitive: move/line/quad/cubic/close, with a single fill or
/// stroke paint.  The storage is out-of-line for the same hot-frame reason as
/// strokes; arbitrary path builders and retained layers remain higher-level
/// work.
pub const MAX_PATH_SEGMENTS: usize = 32;
pub const PathSegment = union(enum) {
    move_to: geometry.Point,
    line_to: geometry.Point,
    quad_to: struct { ctrl: geometry.Point, to: geometry.Point },
    cubic_to: struct { ctrl1: geometry.Point, ctrl2: geometry.Point, to: geometry.Point },
    close,
};

pub const Path = struct {
    segments: [MAX_PATH_SEGMENTS]PathSegment = undefined,
    segment_len: usize = 0,
    color: color.Color = .white,
    stroke_width: f32 = 0,
    join: Stroke.Join = .round,
    cap: Stroke.Cap = .round,
    miter_limit: f32 = 4,
    clip: geometry.Rect = .{},
    /// Affine coefficients in kurbo order: [a, b, c, d, e, f].
    transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },

    pub fn isStroke(self: *const @This()) bool {
        return self.stroke_width > 0;
    }
};

/// A bounded clip geometry. Path clips use the same segment vocabulary as a
/// draw path, which keeps clipping deterministic and lets CPU/WGPU share the
/// exact command payload instead of inventing backend-specific clip objects.
pub const ClipShape = union(enum) {
    rect: geometry.Rect,
    rounded: struct { rect: geometry.Rect, radius: f32 },
    path: Path,
};

pub const Group = struct {
    opacity: f32 = 1,
    /// Affine coefficients in kurbo order: [a, b, c, d, e, f].
    transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    clip: ?ClipShape = null,
};

pub const GroupStorage = [64]Group;

pub const PathStorage = [limits.MAX_PATHS_PER_FRAME]Path;

/// GPUI-style rounded rectangle shadow primitive.  Vellz owns the actual
/// Gaussian filter; the scene only carries the bounded declarative payload.
pub const Shadow = struct {
    bounds: geometry.Rect,
    radius: f32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    spread: f32 = 0,
    blur_radius: f32 = 0,
    color: color.Color = .black,
    inset: bool = false,
    clip: ?geometry.Rect = null,
};

pub const ShadowStorage = [limits.MAX_SHADOWS_PER_FRAME]Shadow;

/// Fixed-capacity invalidation accumulator.  GPUI tracks primitive bounds and
/// can repaint only changed regions; this small contract is renderer-neutral
/// and safe for CPU, WGPU, and headless producers.
pub const DamageSet = struct {
    pub const max_rects: usize = 64;
    rects: [max_rects]geometry.Rect = undefined,
    len: usize = 0,
    full: bool = false,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.full = false;
    }

    pub fn invalidate(self: *@This(), rect: geometry.Rect) void {
        if (rect.w <= 0 or rect.h <= 0 or self.full) return;
        if (self.len >= self.rects.len) {
            self.full = true;
            self.len = 0;
            return;
        }
        self.rects[self.len] = rect;
        self.len += 1;
    }

    pub fn invalidateFull(self: *@This(), viewport: geometry.Rect) void {
        self.clear();
        self.full = true;
        self.rects[0] = viewport;
        self.len = 1;
    }

    pub fn slice(self: *const @This()) []const geometry.Rect {
        return self.rects[0..self.len];
    }
};

/// Total draw cap per frame. Every push records one command, so this also
/// bounds total pushes. Sized >= MAX_SCENE_GLYPHS (see limits.zig) so a
/// glyph-only frame is bound by the payload arrays, never by the command
/// stream first; virtualized lists (plan M7) bound content before either
/// is reachable in ordinary UI.
pub const MAX_COMMANDS_PER_FRAME: u32 = limits.MAX_RENDER_COMMANDS;

/// One entry in the paint-order stream: which payload array and which slot.
/// The rasterizer (and any future GPU driver) must draw commands in order;
/// batching may only fuse ADJACENT same-kind commands. Reordering across
/// kinds is a correctness bug (a later panel must cover earlier text).
pub const Command = struct {
    kind: CommandKind,
    index: u32,
};

pub const CommandKind = enum(u8) {
    begin_group,
    end_group,
    quad,
    glyph,
    blit,
    stroke,
    path,
    shadow,
};

/// Ordered draw payload for one frame (quads + glyph runs + image blits +
/// bounded line strokes).
/// Multi-MB inline storage (~5.9MB: quads carry their clip): heap-allocate
/// or embed in a heap owner (e.g. `Window`). Never hold more than one of
/// Scene/Frame/Engine on a single stack — combined Debug frames force
/// deep stack growth that collides with heap mmaps (flaky segfault, order
/// and ASLR dependent). See the "hot frame structs stay within stack
/// budget" test.
pub const Scene = struct {
    quads: [limits.MAX_QUADS_PER_FRAME]Quad = undefined,
    len: usize = 0,
    glyphs: [limits.MAX_SCENE_GLYPHS]Glyph = undefined,
    glyph_len: usize = 0,
    blits: [limits.MAX_IMAGE_BLITS_PER_FRAME]ImageBlit = undefined,
    blit_len: usize = 0,
    /// Out-of-line so adding bounded custom strokes does not enlarge the hot
    /// Frame + Scene stack pair. The storage must outlive this Scene.
    strokes: []Stroke = &.{},
    stroke_len: usize = 0,
    paths: []Path = &.{},
    path_len: usize = 0,
    shadows: []Shadow = &.{},
    shadow_len: usize = 0,
    groups: GroupStorage = undefined,
    group_len: usize = 0,
    group_depth: usize = 0,
    commands: [MAX_COMMANDS_PER_FRAME]Command = undefined,
    command_len: usize = 0,
    /// Cumulative push failures (payload OR command stream full). The
    /// painter drops instead of growing; this counter makes the drop
    /// observable instead of silent (plan M10). Never reset by clear().
    dropped: u64 = 0,
    /// Push failures since the last `clear()`: the per-frame overflow
    /// signal. `overflowed()` reads this; present paths reject the frame
    /// when it is nonzero (see the module policy above).
    dropped_frame: u64 = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.glyph_len = 0;
        self.blit_len = 0;
        self.stroke_len = 0;
        self.path_len = 0;
        self.shadow_len = 0;
        self.group_len = 0;
        self.group_depth = 0;
        self.command_len = 0;
        self.dropped_frame = 0;
    }

    /// Attach caller-owned fixed stroke storage before emitting strokes.
    /// Existing Scene{} callers that do not use strokes need no setup.
    pub fn attachStrokeStorage(self: *@This(), storage: []Stroke) void {
        self.strokes = storage;
        self.stroke_len = 0;
    }

    pub fn attachPathStorage(self: *@This(), storage: []Path) void {
        self.paths = storage;
        self.path_len = 0;
    }

    pub fn attachShadowStorage(self: *@This(), storage: []Shadow) void {
        self.shadows = storage;
        self.shadow_len = 0;
    }

    pub fn pushGroup(self: *@This(), group: Group) bool {
        if (self.group_len >= self.groups.len or self.command_len >= self.commands.len or
            !std.math.isFinite(group.opacity) or group.opacity < 0 or group.opacity > 1)
        {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.groups[self.group_len] = group;
        self.group_len += 1;
        self.group_depth += 1;
        _ = self.pushCommand(.begin_group, @intCast(self.group_len - 1));
        return true;
    }

    pub fn popGroup(self: *@This()) bool {
        if (self.group_depth == 0 or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.group_depth -= 1;
        _ = self.pushCommand(.end_group, @intCast(self.group_depth));
        return true;
    }

    pub fn groupSlice(self: *const @This()) []const Group {
        return self.groups[0..self.group_len];
    }

    /// True when any push failed since the last `clear()`. A true frame
    /// must not be presented as-is; see `Window.render` (placeholder
    /// substitution) and the benchmark gates.
    pub fn overflowed(self: *const @This()) bool {
        return self.dropped_frame > 0;
    }

    /// Alias for callers that read `hasOverflow` more naturally.
    pub fn hasOverflow(self: *const @This()) bool {
        return self.overflowed();
    }

    /// Replace a rejected frame with a complete diagnostic placeholder:
    /// clears all payloads, then emits an unmissable full-viewport quad
    /// (magenta) with a dark inset so "overflow" is visible instead of
    /// blank. Cumulative `dropped` is preserved as evidence;
    /// `dropped_frame` restarts for the placeholder itself (a placeholder
    /// that itself overflows is a capacity bug, and `overflowed()` stays
    /// honest about it).
    pub fn renderOverflowPlaceholder(self: *@This(), viewport: geometry.Rect) void {
        const dropped_total = self.dropped;
        const dropped_this_frame = self.dropped_frame;
        self.clear();
        self.dropped = dropped_total;
        // A zero-area viewport still gets one sentinel quad at the origin
        // so the frame is never empty-by-accident.
        const w = if (viewport.w > 0) viewport.w else 64;
        const h = if (viewport.h > 0) viewport.h else 64;
        const x = viewport.x;
        const y = viewport.y;
        const magenta = color.Color{ .r = 1, .g = 0, .b = 1, .a = 1 };
        const dark = color.Color{ .r = 0.1, .g = 0, .b = 0.1, .a = 1 };
        const ok_outer = self.push(.{ .x = x, .y = y, .w = w, .h = h, .color = magenta, .clip = null });
        const ok_inner = self.push(.{
            .x = x + 8,
            .y = y + 8,
            .w = @max(0, w - 16),
            .h = @max(0, h - 16),
            .color = dark,
            .clip = null,
        });
        // Restore the evidence the clear() above reset: the placeholder
        // documents the rejection it replaced.
        self.dropped_frame += dropped_this_frame;
        if (!ok_outer or !ok_inner) self.dropped_frame += 1;
    }

    fn pushCommand(self: *@This(), kind: CommandKind, index: u32) bool {
        if (self.command_len >= self.commands.len) return false;
        self.commands[self.command_len] = .{ .kind = kind, .index = index };
        self.command_len += 1;
        return true;
    }

    /// Returns false when full so callers drop instead of growing. Push and
    /// command record are atomic: on false NOTHING was recorded.
    pub fn push(self: *@This(), q: Quad) bool {
        std.debug.assert(q.w >= 0);
        std.debug.assert(q.h >= 0);
        if (self.len >= self.quads.len or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.quads[self.len] = q;
        self.len += 1;
        _ = self.pushCommand(.quad, @intCast(self.len - 1));
        return true;
    }

    pub fn slice(self: *const @This()) []const Quad {
        return self.quads[0..self.len];
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn pushGlyph(self: *@This(), g: Glyph) bool {
        std.debug.assert(g.w >= 0);
        std.debug.assert(g.h >= 0);
        if (self.glyph_len >= self.glyphs.len or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.glyphs[self.glyph_len] = g;
        self.glyph_len += 1;
        _ = self.pushCommand(.glyph, @intCast(self.glyph_len - 1));
        return true;
    }

    pub fn glyphSlice(self: *const @This()) []const Glyph {
        return self.glyphs[0..self.glyph_len];
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn pushImage(self: *@This(), b: ImageBlit) bool {
        std.debug.assert(b.w >= 0);
        std.debug.assert(b.h >= 0);
        if (self.blit_len >= self.blits.len or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.blits[self.blit_len] = b;
        self.blit_len += 1;
        _ = self.pushCommand(.blit, @intCast(self.blit_len - 1));
        return true;
    }

    pub fn imageSlice(self: *const @This()) []const ImageBlit {
        return self.blits[0..self.blit_len];
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn pushStroke(self: *@This(), stroke: Stroke) bool {
        std.debug.assert(stroke.width >= 0);
        if (self.stroke_len >= self.strokes.len or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.strokes[self.stroke_len] = stroke;
        self.stroke_len += 1;
        _ = self.pushCommand(.stroke, @intCast(self.stroke_len - 1));
        return true;
    }

    pub fn strokeSlice(self: *const @This()) []const Stroke {
        return self.strokes[0..self.stroke_len];
    }

    pub fn pushPath(self: *@This(), path: Path) bool {
        if (path.segment_len == 0 or path.segment_len > MAX_PATH_SEGMENTS or
            self.path_len >= self.paths.len or self.command_len >= self.commands.len)
        {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.paths[self.path_len] = path;
        self.path_len += 1;
        _ = self.pushCommand(.path, @intCast(self.path_len - 1));
        return true;
    }

    pub fn pathSlice(self: *const @This()) []const Path {
        return self.paths[0..self.path_len];
    }

    pub fn pushShadow(self: *@This(), shadow: Shadow) bool {
        if (self.shadow_len >= self.shadows.len or self.command_len >= self.commands.len) {
            self.dropped += 1;
            self.dropped_frame += 1;
            return false;
        }
        self.shadows[self.shadow_len] = shadow;
        self.shadow_len += 1;
        _ = self.pushCommand(.shadow, @intCast(self.shadow_len - 1));
        return true;
    }

    pub fn shadowSlice(self: *const @This()) []const Shadow {
        return self.shadows[0..self.shadow_len];
    }

    /// Paint-order stream for renderers. Payload slices stay available for
    /// tests/debug, but drawing MUST follow this order.
    pub fn commandSlice(self: *const @This()) []const Command {
        return self.commands[0..self.command_len];
    }
};

/// One rasterized image instance (decoded photo, icon, or SVG render).
/// Pixels live in the App image-cache pool; `pool_offset` indexes RGBA8
/// bytes (`src_w` x `src_h`). Pool bytes survive until present because pool
/// reset refuses while current-frame entries are pinned, and retained
/// `Handle`s validate by generation (see images/cache.zig); each window
/// renders and presents adjacently within `App.step`.
pub const ImageBlit = struct {
    /// Dest rect in logical pixels (object-fit already applied).
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Byte offset into the image pool.
    pool_offset: u32,
    /// Source dimensions (row stride is `src_w * 4`).
    src_w: u32,
    src_h: u32,
    /// Source sub-rect in pixels (cover-crop window; full image by default).
    src_x: f32 = 0,
    src_y: f32 = 0,
    src_crop_w: f32 = 0, // 0 = full src_w
    src_crop_h: f32 = 0, // 0 = full src_h
    /// Multiply tint; white is identity.
    tint: color.Color = .white,
    /// Clockwise rotation in radians around the destination rect's center.
    rotation: f32 = 0,
    /// Centered image transform. Translation is in logical pixels before the
    /// renderer applies the window's physical scale.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    /// Grayscale (luma) conversion, GPUI `img().grayscale()`.
    gray: bool = false,
    radius: f32 = 0,
    /// Painter clip at emission; the blit honors it per pixel.
    clip: geometry.Rect,
};

/// One rasterized glyph instance. Coverage bytes live in the engine's atlas
/// pixel pool (`Engine.glyphs`); `atlas_offset` indexes it.
/// The atlas entry is COPIED here (offset + dims), never referenced, and
/// mid-frame eviction is deferred past emitted glyphs (see fonts/atlas.zig),
/// so the pool bytes stay valid through present. Each window renders and
/// presents adjacently within `App.step`.
pub const Glyph = struct {
    /// Top-left of the coverage box in logical pixels (fractional ok).
    x: f32,
    y: f32,
    /// Coverage dimensions in pixels (integers by construction).
    w: u32,
    h: u32,
    color: color.Color,
    /// Byte offset into the atlas pixel pool.
    atlas_offset: u32,
    /// Raster density of the mask this entry references: 1 for the
    /// painter's logical 1x atlas, `window.scale_factor` after
    /// `Engine.scaleScene` re-rasterized it for a high-DPI present. The
    /// rasterizer divides target scale by this per glyph, so a mask that
    /// failed to upgrade stretches instead of leaving a hole, and an
    /// upgraded mask is never scaled twice. Scene x/y stay LOGICAL either
    /// way; only mask bytes/placement carry density.
    density: f32 = 1,
    /// Painter clip at emission; the blit honors it per pixel.
    clip: geometry.Rect,

    pub fn isColor(self: Glyph) bool {
        return self.atlas_offset >= limits.MAX_ATLAS_PIXELS;
    }
};

test "scene pushes in order and reports overflow" {
    var s = Scene{};
    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expect(s.push(.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = .white }));
    try std.testing.expectEqual(@as(usize, 1), s.slice().len);
    s.len = s.quads.len;
    try std.testing.expect(!s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .black }));
}

test "scene pushes glyphs and clears both lists" {
    var s = Scene{};
    try std.testing.expect(s.pushGlyph(.{
        .x = 1.5,
        .y = 2.5,
        .w = 8,
        .h = 12,
        .color = .white,
        .atlas_offset = 64,
        .clip = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    }));
    try std.testing.expectEqual(@as(usize, 1), s.glyphSlice().len);
    try std.testing.expectEqual(@as(f32, 1.5), s.glyphSlice()[0].x);
    s.glyph_len = s.glyphs.len;
    try std.testing.expect(!s.pushGlyph(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .color = .black,
        .atlas_offset = 0,
        .clip = .{},
    }));
    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.slice().len);
    try std.testing.expectEqual(@as(usize, 0), s.glyphSlice().len);
    try std.testing.expectEqual(@as(usize, 0), s.imageSlice().len);
}

test "scene pushes blits and reports overflow" {
    var s = Scene{};
    try std.testing.expect(s.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .pool_offset = 0,
        .src_w = 4,
        .src_h = 4,
        .clip = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    }));
    try std.testing.expectEqual(@as(usize, 1), s.imageSlice().len);
    s.blit_len = s.blits.len;
    try std.testing.expect(!s.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .pool_offset = 0,
        .src_w = 1,
        .src_h = 1,
        .clip = .{},
    }));
}

test "scene pushes bounded strokes and records paint order" {
    var s = Scene{};
    var storage: StrokeStorage = undefined;
    s.attachStrokeStorage(&storage);
    try std.testing.expect(s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white }));
    try std.testing.expect(s.pushStroke(.{
        .from = .{ .x = 1, .y = 2 },
        .to = .{ .x = 8, .y = 9 },
        .color = .black,
        .width = 2,
        .clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
    }));
    try std.testing.expect(s.pushGlyph(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .color = .white,
        .atlas_offset = 0,
        .clip = .{},
    }));
    try std.testing.expectEqual(@as(usize, 1), s.strokeSlice().len);
    try std.testing.expectEqual(CommandKind.quad, s.commandSlice()[0].kind);
    try std.testing.expectEqual(CommandKind.stroke, s.commandSlice()[1].kind);
    try std.testing.expectEqual(@as(u32, 0), s.commandSlice()[1].index);
    try std.testing.expectEqual(CommandKind.glyph, s.commandSlice()[2].kind);
}

test "stroke overflow is atomic and counted" {
    var s = Scene{};
    var storage: StrokeStorage = undefined;
    s.attachStrokeStorage(&storage);
    s.stroke_len = s.strokes.len;
    try std.testing.expect(!s.pushStroke(.{
        .from = .{},
        .to = .{ .x = 1, .y = 1 },
        .color = .white,
        .width = 1,
    }));
    try std.testing.expectEqual(@as(usize, s.strokes.len), s.stroke_len);
    try std.testing.expectEqual(@as(usize, 0), s.commandSlice().len);
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    try std.testing.expect(s.overflowed());
}

test "scene records paint order across kinds" {
    var s = Scene{};
    try std.testing.expect(s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white }));
    try std.testing.expect(s.pushGlyph(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .color = .white,
        .atlas_offset = 0,
        .clip = .{},
    }));
    try std.testing.expect(s.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .pool_offset = 0,
        .src_w = 1,
        .src_h = 1,
        .clip = .{},
    }));
    try std.testing.expect(s.push(.{ .x = 2, .y = 2, .w = 1, .h = 1, .color = .black }));
    const cmds = s.commandSlice();
    try std.testing.expectEqual(@as(usize, 4), cmds.len);
    try std.testing.expectEqual(CommandKind.quad, cmds[0].kind);
    try std.testing.expectEqual(@as(u32, 0), cmds[0].index);
    try std.testing.expectEqual(CommandKind.glyph, cmds[1].kind);
    try std.testing.expectEqual(@as(u32, 0), cmds[1].index);
    try std.testing.expectEqual(CommandKind.blit, cmds[2].kind);
    try std.testing.expectEqual(CommandKind.quad, cmds[3].kind);
    try std.testing.expectEqual(@as(u32, 1), cmds[3].index);
    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.commandSlice().len);
}

test "scene retains nested groups and preserves explicit command order" {
    var s = Scene{};
    var clip_path = Path{};
    clip_path.segments[0] = .{ .move_to = .{ .x = 0, .y = 0 } };
    clip_path.segments[1] = .{ .line_to = .{ .x = 10, .y = 0 } };
    clip_path.segments[2] = .{ .line_to = .{ .x = 0, .y = 10 } };
    clip_path.segments[3] = .close;
    clip_path.segment_len = 4;
    try std.testing.expect(s.pushGroup(.{
        .opacity = 0.5,
        .transform = .{ 1, 0, 0, 1, 10, 20 },
        .clip = .{ .rounded = .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .radius = 6 } },
    }));
    try std.testing.expect(s.push(.{ .x = 0, .y = 0, .w = 4, .h = 4, .color = .white }));
    try std.testing.expect(s.pushGroup(.{
        .opacity = 1,
        .transform = .{ 0, 1, -1, 0, 4, 5 },
        .clip = .{ .path = clip_path },
    }));
    try std.testing.expect(s.pushGlyph(.{ .x = 1, .y = 1, .w = 1, .h = 1, .color = .white, .atlas_offset = 0, .clip = .{} }));
    try std.testing.expect(s.popGroup());
    try std.testing.expect(s.popGroup());
    try std.testing.expectEqual(@as(usize, 2), s.groupSlice().len);
    try std.testing.expectEqual(@as(usize, 6), s.commandSlice().len);
    try std.testing.expectEqual(CommandKind.begin_group, s.commandSlice()[0].kind);
    try std.testing.expectEqual(CommandKind.quad, s.commandSlice()[1].kind);
    try std.testing.expectEqual(CommandKind.begin_group, s.commandSlice()[2].kind);
    try std.testing.expectEqual(CommandKind.glyph, s.commandSlice()[3].kind);
    try std.testing.expectEqual(CommandKind.end_group, s.commandSlice()[4].kind);
    try std.testing.expectEqual(CommandKind.end_group, s.commandSlice()[5].kind);
    try std.testing.expectEqual(@as(usize, 0), s.group_depth);
}

test "scene rejects unbalanced group pops" {
    var s = Scene{};
    try std.testing.expect(!s.popGroup());
    try std.testing.expect(s.overflowed());
}

test "scene command overflow drops atomically and counts" {
    var s = Scene{};
    try std.testing.expect(!s.overflowed());
    try std.testing.expect(!s.hasOverflow());
    s.command_len = s.commands.len;
    const quads_before = s.len;
    try std.testing.expect(!s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white }));
    // Nothing recorded: no orphan payload without a command.
    try std.testing.expectEqual(quads_before, s.len);
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    try std.testing.expectEqual(@as(u64, 1), s.dropped_frame);
    try std.testing.expect(s.overflowed());
    try std.testing.expect(s.hasOverflow());
    // Counter survives clear (cumulative, like atlas hits/misses); the
    // per-frame signal resets so the next frame starts clean.
    s.clear();
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    try std.testing.expectEqual(@as(u64, 0), s.dropped_frame);
    try std.testing.expect(!s.overflowed());
}

test "overflow placeholder replaces a rejected frame with complete ink" {
    var s = Scene{};
    // Fill the command stream, then overflow once.
    s.command_len = s.commands.len;
    try std.testing.expect(!s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white }));
    try std.testing.expect(s.overflowed());
    s.renderOverflowPlaceholder(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    // Complete replacement ink: two quads, two commands, nothing partial.
    try std.testing.expectEqual(@as(usize, 2), s.slice().len);
    try std.testing.expectEqual(@as(usize, 2), s.commandSlice().len);
    try std.testing.expectEqual(@as(f32, 800), s.slice()[0].w);
    try std.testing.expectEqual(@as(f32, 600), s.slice()[0].h);
    // Evidence preserved: cumulative total kept, and the frame still
    // reports the rejection it replaced (consumers must not mistake the
    // placeholder for a clean render).
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    try std.testing.expect(s.overflowed());
    // A fresh clear starts a genuinely clean frame.
    s.clear();
    try std.testing.expect(!s.overflowed());
}

test "command capacity covers a glyph-only frame" {
    // Coherence pin for gap report §3: the command stream must not bind
    // before the glyph payload does, or glyph-heavy frames drop while
    // payload space sits empty.
    try std.testing.expect(MAX_COMMANDS_PER_FRAME >= limits.MAX_SCENE_GLYPHS);
}

test "bounded paths and shadows remain ordered scene primitives" {
    var s = Scene{};
    var paths: PathStorage = undefined;
    var shadows: ShadowStorage = undefined;
    s.attachPathStorage(&paths);
    s.attachShadowStorage(&shadows);
    var path = Path{ .color = .white, .clip = .{ .x = 0, .y = 0, .w = 20, .h = 20 } };
    path.segments[0] = .{ .move_to = .{ .x = 1, .y = 1 } };
    path.segments[1] = .{ .line_to = .{ .x = 10, .y = 1 } };
    path.segments[2] = .close;
    path.segment_len = 3;
    try std.testing.expect(s.pushPath(path));
    try std.testing.expect(s.pushShadow(.{ .bounds = .{ .x = 1, .y = 1, .w = 10, .h = 10 }, .blur_radius = 2 }));
    try std.testing.expectEqual(CommandKind.path, s.commandSlice()[0].kind);
    try std.testing.expectEqual(CommandKind.shadow, s.commandSlice()[1].kind);
}

test "damage set falls back to full repaint at its fixed bound" {
    var damage = DamageSet{};
    var i: usize = 0;
    while (i < DamageSet.max_rects + 1) : (i += 1) {
        damage.invalidate(.{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 });
    }
    try std.testing.expect(damage.full);
    try std.testing.expectEqual(@as(usize, 0), damage.slice().len);
}
