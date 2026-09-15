//! Vellz-backed CPU renderer: translates the ordered frame `Scene` into
//! vellz (Vello-derived) draw commands, rasterizes premultiplied RGBA8, and
//! converts the result into the platform pixel format in the caller's frame
//! buffer.
//!
//! One `Renderer` is owned per presenting window. The vellz render context,
//! resources and pixmap persist across frames and are recreated only on
//! resize (`RenderContext.reset` between frames). Glyph coverage masks are
//! cached as white premultiplied images keyed by atlas slot plus atlas
//! generation; decoded images are registered for one frame and released at
//! its end.
//!
//! This is the default zui renderer. The old binary-coverage CPU rasterizer
//! (`software.zig`) is gone; quad corners, clips, gradients and glyph edges
//! are now analytically antialiased by vellz.

const std = @import("std");
const vellz = @import("vellz");
const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const common = vellz.common;
const cpu = vellz.cpu;

const scene_mod = @import("scene.zig");
const color_mod = @import("../core/color.zig");
const geometry = @import("../core/geometry.zig");

pub const Color = color_mod.Color;

/// Memory layouts accepted for the output frame buffer, matching the old
/// `software.Target` formats. `bgra32` and `argb32` both land as
/// `[B, G, R, A]` little-endian (WL_SHM_FORMAT_ARGB8888 / X11 BGRA).
pub const PixelFormat = enum { rgba32, bgra32, argb32 };

const GlyphEntry = struct {
    w: u32,
    h: u32,
    /// Content hash of the coverage bytes, so a reused atlas slot with new
    /// pixels invalidates the cached mask without an atlas generation API.
    hash: u64,
    id: common.paint.ImageId,
};

const BlitKey = struct {
    offset: u32,
    w: u32,
    h: u32,
    gray: bool,
};

const RoundedClip = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
};

const ClipKey = union(enum) {
    rect: geometry.Rect,
    rounded: RoundedClip,
};

const ClipState = struct {
    keys: [2]ClipKey = undefined,
    len: usize = 0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,

    width: u16 = 0,
    height: u16 = 0,
    ctx: ?cpu.RenderContext = null,
    resources: cpu.Resources = .{},
    pixmap: ?common.pixmap.Pixmap = null,

    /// Glyph coverage masks (premultiplied white), keyed by atlas slot.
    /// Each entry stores a content hash so reused pool bytes invalidate the
    /// cached mask.
    glyph_images: std.AutoHashMapUnmanaged(u32, GlyphEntry) = .empty,

    /// Decoded images registered for the current frame, released at frame end.
    blit_images: std.AutoHashMapUnmanaged(BlitKey, common.paint.ImageId) = .empty,
    frame_images: std.ArrayListUnmanaged(common.paint.ImageId) = .empty,

    /// Path scratch for rounded rects, rings and clip paths.
    path: std.ArrayListUnmanaged(kurbo.PathEl) = .empty,

    /// Clip paths currently open on the vellz context.
    clip: ClipState = .{},

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        self.clearGlyphImages();
        self.glyph_images.deinit(self.allocator);
        self.destroyFrameImages();
        self.blit_images.deinit(self.allocator);
        self.frame_images.deinit(self.allocator);
        self.path.deinit(self.allocator);
        if (self.pixmap) |*pixmap| pixmap.deinit(self.allocator);
        self.pixmap = null;
        self.resources.deinit(self.allocator);
        if (self.ctx) |*ctx| ctx.deinit(self.allocator);
        self.ctx = null;
    }

    /// Rasterize one frame into `pixels` (the platform frame buffer).
    ///
    /// `glyph_pixels` is the engine atlas pool; `glyph_generation` changes
    /// whenever that pool resets (see `fonts/atlas.zig`). `image_pixels` is
    /// the decoded-image pool addressed by `ImageBlit.pool_offset`.
    pub fn render(
        self: *Renderer,
        pixels: []u8,
        width: u32,
        height: u32,
        format: PixelFormat,
        clear: Color,
        scene: *const scene_mod.Scene,
        glyph_pixels: []const u8,
        image_pixels: []const u8,
    ) !void {
        if (width == 0 or height == 0) return;
        const needed = @as(usize, width) * height * 4;
        if (pixels.len < needed) return error.FrameBufferTooSmall;
        if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.FrameTooLarge;

        try self.ensureSize(@intCast(width), @intCast(height));
        const ctx = &self.ctx.?;
        ctx.reset();
        self.clip.len = 0;
        self.destroyFrameImages();

        var clip_buf: [2]ClipKey = undefined;
        for (scene.commandSlice()) |cmd| {
            switch (cmd.kind) {
                .quad => {
                    const q = scene.slice()[cmd.index];
                    if (q.w <= 0 or q.h <= 0 or q.color.a <= 0) continue;
                    if (q.clip) |clip| {
                        if (clip.w <= 0 or clip.h <= 0) continue;
                    }
                    const keys = clipKeysFor(q.x, q.y, q.w, q.h, q.clip, 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawQuad(q);
                },
                .glyph => {
                    const g = scene.glyphSlice()[cmd.index];
                    if (g.w == 0 or g.h == 0 or g.color.a <= 0) continue;
                    if (g.clip.w <= 0 or g.clip.h <= 0) continue;
                    const gx = @round(g.x);
                    const gy = @round(g.y);
                    const keys = clipKeysFor(gx, gy, @floatFromInt(g.w), @floatFromInt(g.h), g.clip, 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawGlyph(g, gx, gy, glyph_pixels);
                },
                .blit => {
                    const b = scene.imageSlice()[cmd.index];
                    if (b.w <= 0 or b.h <= 0 or b.src_w == 0 or b.src_h == 0) continue;
                    if (b.clip.w <= 0 or b.clip.h <= 0) continue;
                    const keys = clipKeysFor(b.x, b.y, b.w, b.h, b.clip, b.radius, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawBlit(b, image_pixels);
                },
            }
        }
        while (self.clip.len > 0) {
            ctx.popClipPath();
            self.clip.len -= 1;
        }

        try ctx.flush();
        try ctx.renderWith(&self.pixmap.?, &self.resources, .{
            .render_mode = .optimize_quality,
            .target_init = .{ .clear = penikoColor(clear) },
            .pixel_format = .rgba8,
            .offset = .{},
        });

        self.copyOut(pixels[0..needed], format);
        self.destroyFrameImages();
    }

    fn ensureSize(self: *Renderer, width: u16, height: u16) !void {
        if (self.ctx == null) {
            self.ctx = try cpu.RenderContext.init(self.allocator, width, height, .{
                .level = vellz.simd.Level.detect(),
                .num_threads = 0,
            });
            self.pixmap = try common.pixmap.Pixmap.init(self.allocator, width, height);
            self.width = width;
            self.height = height;
            return;
        }
        if (self.width == width and self.height == height) return;
        try self.ctx.?.resetAndResize(self.allocator, width, height);
        if (self.pixmap) |*pixmap| pixmap.deinit(self.allocator);
        self.pixmap = try common.pixmap.Pixmap.init(self.allocator, width, height);
        self.width = width;
        self.height = height;
    }

    fn copyOut(self: *Renderer, out: []u8, format: PixelFormat) void {
        const src = self.pixmap.?.dataAsU8SliceMut();
        std.debug.assert(src.len == out.len);
        switch (format) {
            .rgba32 => @memcpy(out, src),
            .bgra32, .argb32 => {
                var i: usize = 0;
                while (i < src.len) : (i += 4) {
                    out[i + 0] = src[i + 2];
                    out[i + 1] = src[i + 1];
                    out[i + 2] = src[i + 0];
                    out[i + 3] = src[i + 3];
                }
            },
        }
    }

    // ------------------------------------------------------------- drawing

    fn drawQuad(self: *Renderer, q: scene_mod.Quad) !void {
        const ctx = &self.ctx.?;
        const radius = @min(q.radius, @min(q.w, q.h) / 2.0);

        if (q.gradient_to) |end| {
            try self.setGradientPaint(q, end);
        } else {
            ctx.setPaint(penikoColor(q.color));
        }

        if (q.border_width > 0) {
            const bw = q.border_width;
            const iw = q.w - bw * 2;
            const ih = q.h - bw * 2;
            if (iw > 0 and ih > 0) {
                self.path.clearRetainingCapacity();
                try appendRoundedRect(&self.path, self.allocator, q.x, q.y, q.w, q.h, radius);
                try appendRoundedRect(&self.path, self.allocator, q.x + bw, q.y + bw, iw, ih, @max(0, radius - bw));
                ctx.setFillRule(.even_odd);
                try ctx.fillPath(self.allocator, self.path.items);
                ctx.setFillRule(.non_zero);
                return;
            }
        }

        if (radius > 0) {
            self.path.clearRetainingCapacity();
            try appendRoundedRect(&self.path, self.allocator, q.x, q.y, q.w, q.h, radius);
            try ctx.fillPath(self.allocator, self.path.items);
        } else {
            try ctx.fillRect(self.allocator, kurbo.Rect.new(q.x, q.y, q.x + q.w, q.y + q.h));
        }
    }

    fn drawGlyph(self: *Renderer, g: scene_mod.Glyph, gx: f32, gy: f32, glyph_pixels: []const u8) !void {
        const id = try self.glyphImage(g, glyph_pixels);
        const ctx = &self.ctx.?;
        ctx.setTint(.{ .color = penikoColor(g.color), .mode = .alpha_mask });
        self.setImagePaint(id, .low);
        // Image paints live in image pixel space; place the mask at the
        // glyph origin.
        ctx.setPaintTransform(kurbo.Affine.new(.{ 1, 0, 0, 1, gx, gy }));
        try ctx.fillRect(self.allocator, kurbo.Rect.new(gx, gy, gx + @as(f32, @floatFromInt(g.w)), gy + @as(f32, @floatFromInt(g.h))));
        ctx.resetPaintTransform();
        ctx.setTint(null);
    }

    fn drawBlit(self: *Renderer, b: scene_mod.ImageBlit, image_pixels: []const u8) !void {
        const sw: usize = b.src_w;
        const sh: usize = b.src_h;
        const start: usize = b.pool_offset;
        if (start + sw * sh * 4 > image_pixels.len) return;

        const id = try self.blitImage(b, image_pixels);
        const ctx = &self.ctx.?;

        const swf: f32 = @floatFromInt(b.src_w);
        const shf: f32 = @floatFromInt(b.src_h);
        const crop_w: f32 = if (b.src_crop_w > 0) @min(b.src_crop_w, swf) else swf;
        const crop_h: f32 = if (b.src_crop_h > 0) @min(b.src_crop_h, shf) else shf;
        const crop_x = std.math.clamp(b.src_x, 0, swf - crop_w);
        const crop_y = std.math.clamp(b.src_y, 0, shf - crop_h);
        const sx = b.w / crop_w;
        const sy = b.h / crop_h;
        const tx = b.x - crop_x * sx;
        const ty = b.y - crop_y * sy;
        ctx.setPaintTransform(kurbo.Affine.new(.{ sx, 0, 0, sy, tx, ty }));

        if (b.tint.r < 1 or b.tint.g < 1 or b.tint.b < 1 or b.tint.a < 1) {
            ctx.setTint(.{ .color = penikoColor(b.tint), .mode = .multiply });
        }
        self.setImagePaint(id, .low);
        try ctx.fillRect(self.allocator, kurbo.Rect.new(b.x, b.y, b.x + b.w, b.y + b.h));
        ctx.setTint(null);
        ctx.resetPaintTransform();
    }

    fn setGradientPaint(self: *Renderer, q: scene_mod.Quad, end: Color) !void {
        const stops = try peniko.ColorStops.fromSlice(self.allocator, &.{
            .{ .offset = 0, .color = penikoColor(q.color) },
            .{ .offset = 1, .color = penikoColor(end) },
        });
        var gradient = peniko.Gradient.newLinear(
            .{ .x = q.x, .y = q.y },
            .{ .x = q.x + q.w, .y = q.y },
        );
        gradient.stops = stops;
        self.ctx.?.setPaint(common.paint.PaintType.fromGradient(gradient));
    }

    fn setImagePaint(self: *Renderer, id: common.paint.ImageId, quality: peniko.ImageQuality) void {
        self.ctx.?.setPaint(common.paint.PaintType.fromImage(.{
            .image = common.paint.ImageSource.initOpaqueIdWithTransparencyHint(id, true),
            .sampler = .{ .quality = quality },
        }));
    }

    // -------------------------------------------------------------- images

    fn registerPixmap(self: *Renderer, pixmap: common.pixmap.Pixmap) !common.paint.ImageId {
        const handle = try common.shared.Shared(common.pixmap.Pixmap).create(self.allocator, pixmap);
        errdefer handle.release(self.allocator);
        return try self.resources.registerImage(self.allocator, handle);
    }

    fn glyphImage(self: *Renderer, g: scene_mod.Glyph, glyph_pixels: []const u8) !common.paint.ImageId {
        const count = @as(usize, g.w) * g.h;
        const hash = coverageHash(glyph_pixels, g.atlas_offset, count);
        if (self.glyph_images.get(g.atlas_offset)) |entry| {
            if (entry.w == g.w and entry.h == g.h and entry.hash == hash) return entry.id;
            _ = self.resources.destroyImage(self.allocator, entry.id);
            _ = self.glyph_images.remove(g.atlas_offset);
        }

        const bytes = try self.allocator.alloc(u8, count * 4);
        defer self.allocator.free(bytes);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const src = @as(usize, g.atlas_offset) + i;
            const coverage: u8 = if (src < glyph_pixels.len) glyph_pixels[src] else 0;
            bytes[i * 4 + 0] = coverage;
            bytes[i * 4 + 1] = coverage;
            bytes[i * 4 + 2] = coverage;
            bytes[i * 4 + 3] = coverage;
        }
        const pixmap = try common.pixmap.Pixmap.fromParts(self.allocator, bytes, @intCast(g.w), @intCast(g.h), .{
            .may_have_transparency = true,
            .alpha_type = .alpha_premultiplied,
        });
        const id = try self.registerPixmap(pixmap);
        errdefer _ = self.resources.destroyImage(self.allocator, id);
        try self.glyph_images.put(self.allocator, g.atlas_offset, .{ .w = g.w, .h = g.h, .hash = hash, .id = id });
        return id;
    }

    fn blitImage(self: *Renderer, b: scene_mod.ImageBlit, image_pixels: []const u8) !common.paint.ImageId {
        const key = BlitKey{ .offset = b.pool_offset, .w = b.src_w, .h = b.src_h, .gray = b.gray };
        if (self.blit_images.get(key)) |id| return id;

        const count = @as(usize, b.src_w) * b.src_h;
        const bytes = try self.allocator.alloc(u8, count * 4);
        defer self.allocator.free(bytes);
        const start: usize = b.pool_offset;
        @memcpy(bytes, image_pixels[start..][0 .. count * 4]);

        if (b.gray) {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const r = @as(u32, bytes[i * 4 + 0]);
                const g = @as(u32, bytes[i * 4 + 1]);
                const bl = @as(u32, bytes[i * 4 + 2]);
                const luma: u8 = @intCast((r * 77 + g * 150 + bl * 29) >> 8);
                bytes[i * 4 + 0] = luma;
                bytes[i * 4 + 1] = luma;
                bytes[i * 4 + 2] = luma;
            }
        }

        // `.alpha` premultiplies `bytes` in place (ours to mutate) and then
        // copies into the owned pixmap.
        const pixmap = try common.pixmap.Pixmap.fromParts(self.allocator, bytes, @intCast(b.src_w), @intCast(b.src_h), .{
            .may_have_transparency = true,
            .alpha_type = .alpha,
        });
        const id = try self.registerPixmap(pixmap);
        errdefer _ = self.resources.destroyImage(self.allocator, id);
        try self.blit_images.put(self.allocator, key, id);
        try self.frame_images.append(self.allocator, id);
        return id;
    }

    fn clearGlyphImages(self: *Renderer) void {
        var it = self.glyph_images.valueIterator();
        while (it.next()) |entry| _ = self.resources.destroyImage(self.allocator, entry.id);
        self.glyph_images.clearRetainingCapacity();
    }

    fn destroyFrameImages(self: *Renderer) void {
        for (self.frame_images.items) |id| _ = self.resources.destroyImage(self.allocator, id);
        self.frame_images.clearRetainingCapacity();
        self.blit_images.clearRetainingCapacity();
    }

    // --------------------------------------------------------------- clips

    fn updateClip(self: *Renderer, keys: []const ClipKey) !void {
        if (keys.len == self.clip.len) {
            var same = true;
            for (keys, 0..) |key, i| {
                if (!clipKeyEql(key, self.clip.keys[i])) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }
        const ctx = &self.ctx.?;
        while (self.clip.len > 0) {
            ctx.popClipPath();
            self.clip.len -= 1;
        }
        for (keys) |key| {
            self.path.clearRetainingCapacity();
            switch (key) {
                .rect => |rect| try appendRect(&self.path, self.allocator, rect.x, rect.y, rect.w, rect.h),
                .rounded => |rr| try appendRoundedRect(&self.path, self.allocator, rr.x, rr.y, rr.w, rr.h, rr.r),
            }
            try ctx.pushClipPath(self.allocator, self.path.items);
            self.clip.keys[self.clip.len] = key;
            self.clip.len += 1;
        }
    }
};

fn penikoColor(c: Color) peniko.Color {
    return peniko.Color.fromRgba8(u8c(c.r), u8c(c.g), u8c(c.b), u8c(c.a));
}

fn u8c(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v * 255.0, 0.0, 255.0));
}

fn clipKeyEql(a: ClipKey, b: ClipKey) bool {
    return std.meta.eql(a, b);
}

/// FNV-1a over the coverage bytes a glyph references (zero-padded when the
/// pool slice is shorter, e.g. tests that pass no glyph pixels).
fn coverageHash(pool: []const u8, offset: u32, count: usize) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const src = @as(usize, offset) + i;
        const byte: u8 = if (src < pool.len) pool[src] else 0;
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}

/// Build the desired clip stack for a draw. A clip that already contains the
/// whole draw is skipped; a rounded blit corner adds a second clip key.
fn clipKeysFor(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    clip: ?geometry.Rect,
    radius: f32,
    out: *[2]ClipKey,
) []const ClipKey {
    var len: usize = 0;
    if (clip) |rect| {
        if (!clipContains(rect, x, y, w, h)) {
            out[len] = .{ .rect = rect };
            len += 1;
        }
    }
    if (radius > 0) {
        out[len] = .{ .rounded = .{ .x = x, .y = y, .w = w, .h = h, .r = radius } };
        len += 1;
    }
    return out[0..len];
}

fn clipContains(clip: geometry.Rect, x: f32, y: f32, w: f32, h: f32) bool {
    return clip.x <= x and clip.y <= y and clip.x + clip.w >= x + w and clip.y + clip.h >= y + h;
}

fn appendRect(list: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32) !void {
    const x1 = x + w;
    const y1 = y + h;
    try list.append(allocator, .{ .MoveTo = kurbo.Point.new(x, y) });
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x1, y) });
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x1, y1) });
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x, y1) });
    try list.append(allocator, kurbo.PathEl.ClosePath);
}

/// Rounded rectangle as a cubic path (circle approximation constant). The
/// radius is clamped to half the smaller side, matching the old rasterizer.
fn appendRoundedRect(
    list: *std.ArrayListUnmanaged(kurbo.PathEl),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
) !void {
    const r = std.math.clamp(radius, 0, @min(w, h) / 2.0);
    if (r <= 0) return appendRect(list, allocator, x, y, w, h);
    const k = r * 0.552_284_75;
    const x1 = x + w;
    const y1 = y + h;
    try list.append(allocator, .{ .MoveTo = kurbo.Point.new(x + r, y) });
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x1 - r, y) });
    try appendCubic(list, allocator, x1 - r + k, y, x1, y + r - k, x1, y + r);
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x1, y1 - r) });
    try appendCubic(list, allocator, x1, y1 - r + k, x1 - r + k, y1, x1 - r, y1);
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x + r, y1) });
    try appendCubic(list, allocator, x + r - k, y1, x, y1 - r + k, x, y1 - r);
    try list.append(allocator, .{ .LineTo = kurbo.Point.new(x, y + r) });
    try appendCubic(list, allocator, x, y + r - k, x + r - k, y, x + r, y);
    try list.append(allocator, kurbo.PathEl.ClosePath);
}

fn appendCubic(
    list: *std.ArrayListUnmanaged(kurbo.PathEl),
    allocator: std.mem.Allocator,
    p1x: f32,
    p1y: f32,
    p2x: f32,
    p2y: f32,
    p3x: f32,
    p3y: f32,
) !void {
    try list.append(allocator, .{ .CurveTo = .{
        .p1 = kurbo.Point.new(p1x, p1y),
        .p2 = kurbo.Point.new(p2x, p2y),
        .p3 = kurbo.Point.new(p3x, p3y),
    } });
}

// ------------------------------------------------------------------ tests

test "vellz renders a rounded quad with antialiased corners" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var buf: [32 * 32 * 4]u8 = undefined;
    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.push(.{
        .x = 4,
        .y = 4,
        .w = 24,
        .h = 24,
        .radius = 8,
        .color = Color.hex(0xFF0000),
        .clip = .{ .x = 0, .y = 0, .w = 32, .h = 32 },
    }));
    try renderer.render(&buf, 32, 32, .rgba32, Color.hex(0x000000), &scene, &.{}, &.{});

    const center = (16 * 32 + 16) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[center]);
    try std.testing.expectEqual(@as(u8, 0), buf[center + 1]);

    // An 8px corner arc must produce partial coverage somewhere: the old
    // binary rasterizer could only write 0 or 255 here.
    var partial = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        const r = buf[i];
        if (r > 0 and r < 255) partial = true;
    }
    try std.testing.expect(partial);

    // The rounded corner cuts the square corner away entirely.
    const corner = (4 * 32 + 4) * 4;
    try std.testing.expect(buf[corner] < 128);
}

test "vellz clips draws to the payload clip rect" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var buf: [16 * 16 * 4]u8 = undefined;
    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.push(.{
        .x = 0,
        .y = 0,
        .w = 16,
        .h = 16,
        .color = Color.hex(0x00FF00),
        .clip = .{ .x = 0, .y = 0, .w = 8, .h = 16 },
    }));
    try renderer.render(&buf, 16, 16, .rgba32, Color.hex(0x000000), &scene, &.{}, &.{});

    const inside = (8 * 16 + 4) * 4;
    const outside = (8 * 16 + 12) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[inside + 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[outside + 1]);
}

test "vellz tints cached glyph masks per draw color" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    const coverage = [_]u8{ 0, 255, 255, 0 };
    var buf: [8 * 8 * 4]u8 = undefined;
    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.pushGlyph(.{
        .x = 2,
        .y = 2,
        .w = 2,
        .h = 2,
        .color = Color.hex(0xFF0000),
        .atlas_offset = 0,
        .clip = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
    }));
    try renderer.render(&buf, 8, 8, .rgba32, Color.hex(0x000000), &scene, &coverage, &.{});
    const covered = (2 * 8 + 3) * 4; // coverage[1] = 255
    const uncovered = (2 * 8 + 2) * 4; // coverage[0] = 0
    try std.testing.expectEqual(@as(u8, 255), buf[covered]);
    try std.testing.expectEqual(@as(u8, 0), buf[covered + 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[uncovered]);
}

test "vellz blits pool images and maps crops to the dest rect" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    // 2x1 source: one red pixel, one blue pixel (straight RGBA8).
    const pool = [_]u8{
        255, 0, 0, 255,
        0, 0, 255, 255,
    };
    var buf: [8 * 4 * 4]u8 = undefined;
    var scene = scene_mod.Scene{};
    // Crop the red pixel and stretch it across an 8x4 dest.
    try std.testing.expect(scene.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 4,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 1,
        .src_crop_w = 1,
        .src_crop_h = 1,
        .clip = .{ .x = 0, .y = 0, .w = 8, .h = 4 },
    }));
    try renderer.render(&buf, 8, 4, .rgba32, Color.hex(0x000000), &scene, &.{}, &pool);

    const left = (2 * 8 + 1) * 4;
    try std.testing.expect(buf[left] > 200);
    try std.testing.expect(buf[left + 2] < 40);
}

test "vellz emits bgra32 byte order" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var buf: [4 * 4 * 4]u8 = undefined;
    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.push(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .color = Color.hex(0x112233),
        .clip = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    }));
    try renderer.render(&buf, 4, 4, .bgra32, Color.hex(0x000000), &scene, &.{}, &.{});
    const px = (2 * 4 + 2) * 4;
    try std.testing.expectEqual(@as(u8, 0x33), buf[px + 0]);
    try std.testing.expectEqual(@as(u8, 0x22), buf[px + 1]);
    try std.testing.expectEqual(@as(u8, 0x11), buf[px + 2]);
}
