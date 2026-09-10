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
};

pub const Scene = struct {
    quads: [limits.MAX_QUADS_PER_FRAME]Quad = undefined,
    len: usize = 0,
    glyphs: [limits.MAX_SCENE_GLYPHS]Glyph = undefined,
    glyph_len: usize = 0,
    blits: [limits.MAX_IMAGE_BLITS_PER_FRAME]ImageBlit = undefined,
    blit_len: usize = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.glyph_len = 0;
        self.blit_len = 0;
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn push(self: *@This(), q: Quad) bool {
        std.debug.assert(q.w >= 0);
        std.debug.assert(q.h >= 0);
        if (self.len >= self.quads.len) return false;
        self.quads[self.len] = q;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const @This()) []const Quad {
        return self.quads[0..self.len];
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn pushGlyph(self: *@This(), g: Glyph) bool {
        std.debug.assert(g.w >= 0);
        std.debug.assert(g.h >= 0);
        if (self.glyph_len >= self.glyphs.len) return false;
        self.glyphs[self.glyph_len] = g;
        self.glyph_len += 1;
        return true;
    }

    pub fn glyphSlice(self: *const @This()) []const Glyph {
        return self.glyphs[0..self.glyph_len];
    }

    /// Returns false when full so callers drop instead of growing.
    pub fn pushImage(self: *@This(), b: ImageBlit) bool {
        std.debug.assert(b.w >= 0);
        std.debug.assert(b.h >= 0);
        if (self.blit_len >= self.blits.len) return false;
        self.blits[self.blit_len] = b;
        self.blit_len += 1;
        return true;
    }

    pub fn imageSlice(self: *const @This()) []const ImageBlit {
        return self.blits[0..self.blit_len];
    }
};

/// One rasterized image instance (decoded photo, icon, or SVG render).
/// Pixels live in the App image-cache pool; `pool_offset` indexes RGBA8
/// bytes (`src_w` x `src_h`). Same lifetime rule as glyphs: the pool must
/// survive until present, so windows render+present adjacently in App.step.
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

/// One rasterized glyph instance. Coverage bytes live in the font atlas
/// pixel pool (owned by `fonts.Collection`); `atlas_offset` indexes it.
/// The atlas entry is COPIED here (offset + dims), never referenced, so a
/// later eviction cannot corrupt an already-emitted frame — but the pool
/// bytes themselves must survive until present, so each window renders and
/// presents adjacently within `App.step` (which it does).
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
