//! Per-frame scene: the GPU-independent draw list.
//!
//! Why a collector: GPUI's `scene.rs` and Gooey's `scene/scene.zig` both
//! collect one frame of quads/glyphs on the CPU, then hand dense batches
//! to Metal/Vulkan/GL. Backends stay thin; batching and clipping live
//! here once. Storage is a fixed array so frames never allocate.

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

/// Total draw cap per frame. Every push records one command, so this also
/// bounds total pushes; 8K ordered draws far exceed what the software
/// rasterizer can shade per frame, and virtualized lists (plan M7) bound
/// content before this is reachable.
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
    quad,
    glyph,
    blit,
};

/// Ordered draw payload for one frame (quads + glyph runs + image blits).
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
    commands: [MAX_COMMANDS_PER_FRAME]Command = undefined,
    command_len: usize = 0,
    /// Cumulative push failures (payload OR command stream full). The
    /// painter drops instead of growing; this counter makes the drop
    /// observable instead of silent (plan M10). Never reset by clear().
    dropped: u64 = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.glyph_len = 0;
        self.blit_len = 0;
        self.command_len = 0;
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
    /// Painter clip at emission; the blit honors it per pixel.
    clip: geometry.Rect,
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

test "scene command overflow drops atomically and counts" {
    var s = Scene{};
    s.command_len = s.commands.len;
    const quads_before = s.len;
    try std.testing.expect(!s.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white }));
    // Nothing recorded: no orphan payload without a command.
    try std.testing.expectEqual(quads_before, s.len);
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    // Counter survives clear (cumulative, like atlas hits/misses).
    s.clear();
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
}
