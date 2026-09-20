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
const filter_effects = common.filter_effects;

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
    is_color: bool = false,
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

fn pathBounds(path: scene_mod.Path) geometry.Rect {
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (path.segments[0..path.segment_len]) |segment| {
        const points: [3]geometry.Point = switch (segment) {
            .move_to => |p| .{ p, p, p },
            .line_to => |p| .{ p, p, p },
            .quad_to => |q| .{ q.ctrl, q.to, q.to },
            .cubic_to => |c| .{ c.ctrl1, c.ctrl2, c.to },
            .close => continue,
        };
        for (points) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
    }
    if (!std.math.isFinite(min_x)) return .{};
    return .{ .x = min_x, .y = min_y, .w = @max(0, max_x - min_x), .h = @max(0, max_y - min_y) };
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,

    /// Scene geometry is logical f32; target dimensions are physical pixels.
    /// Set by the window backend, never by layout. Glyph mask density
    /// travels per glyph (`Scene.Glyph.density`); this renderer field
    /// remains for callers that rasterize whole scenes at a fixed density.
    scale_factor: f32 = 1,
    glyph_scale: f32 = 1,
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
        const GroupState = struct { transform: kurbo.Affine, layered: bool };
        var group_stack: [64]GroupState = undefined;
        var group_len: usize = 0;
        for (scene.commandSlice()) |cmd| {
            switch (cmd.kind) {
                .begin_group => {
                    if (group_len >= group_stack.len or cmd.index >= scene.groupSlice().len) return error.SceneGroupOverflow;
                    const group = scene.groupSlice()[cmd.index];
                    const previous = ctx.transform();
                    const local = kurbo.Affine.new(.{
                        @floatCast(group.transform[0]),                     @floatCast(group.transform[1]),
                        @floatCast(group.transform[2]),                     @floatCast(group.transform[3]),
                        @floatCast(group.transform[4] * self.scale_factor), @floatCast(group.transform[5] * self.scale_factor),
                    });
                    const combined = previous.compose(local);
                    ctx.setTransform(combined);
                    var layered = false;
                    if (group.opacity < 1 or group.clip != null) {
                        var clip_elements: ?std.ArrayListUnmanaged(kurbo.PathEl) = null;
                        defer if (clip_elements) |*path| path.deinit(self.allocator);
                        if (group.clip) |shape| {
                            clip_elements = .empty;
                            try appendClipShape(&clip_elements.?, self.allocator, shape);
                        }
                        try ctx.pushLayer(self.allocator, if (clip_elements) |*path| path.items else null, null, group.opacity, null, null);
                        layered = true;
                    }
                    group_stack[group_len] = .{ .transform = previous, .layered = layered };
                    group_len += 1;
                },
                .end_group => {
                    if (group_len == 0) return error.SceneGroupUnderflow;
                    group_len -= 1;
                    const state = group_stack[group_len];
                    if (state.layered) ctx.popLayer();
                    ctx.setTransform(state.transform);
                },
                .quad => {
                    var q = scene.slice()[cmd.index];
                    q.x *= self.scale_factor;
                    q.y *= self.scale_factor;
                    q.w *= self.scale_factor;
                    q.h *= self.scale_factor;
                    q.radius *= self.scale_factor;
                    q.border_width *= self.scale_factor;
                    if (q.clip) |clip| q.clip = scaledRect(clip, self.scale_factor);
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
                    // One logical→physical mapping per glyph: target scale
                    // over this mask's raster density. An upgraded mask
                    // (density == scale) renders 1:1; a 1x mask stretches
                    // by the full factor.
                    const ratio = self.scale_factor / g.density;
                    const gx = @round(g.x * self.scale_factor);
                    const gy = @round(g.y * self.scale_factor);
                    var physical = g;
                    physical.x = gx;
                    physical.y = gy;
                    physical.clip = scaledRect(g.clip, self.scale_factor);
                    const keys = clipKeysFor(gx, gy, @as(f32, @floatFromInt(g.w)) * ratio, @as(f32, @floatFromInt(g.h)) * ratio, physical.clip, 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawGlyph(physical, gx, gy, glyph_pixels, ratio);
                },
                .blit => {
                    var b = scene.imageSlice()[cmd.index];
                    b.x *= self.scale_factor;
                    b.y *= self.scale_factor;
                    b.w *= self.scale_factor;
                    b.h *= self.scale_factor;
                    b.translate_x *= self.scale_factor;
                    b.translate_y *= self.scale_factor;
                    b.radius *= self.scale_factor;
                    b.clip = scaledRect(b.clip, self.scale_factor);
                    if (b.w <= 0 or b.h <= 0 or b.src_w == 0 or b.src_h == 0) continue;
                    if (b.clip.w <= 0 or b.clip.h <= 0) continue;
                    const keys = clipKeysFor(b.x, b.y, b.w, b.h, b.clip, b.radius, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawBlit(b, image_pixels);
                },
                .stroke => {
                    var stroke = scene.strokeSlice()[cmd.index];
                    stroke.from.x *= self.scale_factor;
                    stroke.from.y *= self.scale_factor;
                    stroke.to.x *= self.scale_factor;
                    stroke.to.y *= self.scale_factor;
                    stroke.width *= self.scale_factor;
                    stroke.clip = scaledRect(stroke.clip, self.scale_factor);
                    if (stroke.width <= 0 or stroke.color.a <= 0 or
                        !std.math.isFinite(stroke.width) or
                        !std.math.isFinite(stroke.from.x) or !std.math.isFinite(stroke.from.y) or
                        !std.math.isFinite(stroke.to.x) or !std.math.isFinite(stroke.to.y) or
                        stroke.from.eql(stroke.to)) continue;
                    if (stroke.clip.w <= 0 or stroke.clip.h <= 0) continue;
                    const half = stroke.width / 2;
                    const min_x = @min(stroke.from.x, stroke.to.x) - half;
                    const min_y = @min(stroke.from.y, stroke.to.y) - half;
                    const line_w = @max(stroke.from.x, stroke.to.x) - @min(stroke.from.x, stroke.to.x) + stroke.width;
                    const line_h = @max(stroke.from.y, stroke.to.y) - @min(stroke.from.y, stroke.to.y) + stroke.width;
                    const keys = clipKeysFor(min_x, min_y, line_w, line_h, @as(?geometry.Rect, stroke.clip), 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawStroke(stroke);
                },
                .path => {
                    var path = scene.pathSlice()[cmd.index];
                    path.clip = scaledRect(path.clip, self.scale_factor);
                    if (path.clip.w <= 0 or path.clip.h <= 0 or path.segment_len == 0 or path.color.a <= 0) continue;
                    var bounds = pathBounds(path);
                    bounds = scaledRect(bounds, self.scale_factor);
                    const keys = clipKeysFor(bounds.x, bounds.y, bounds.w, bounds.h, path.clip, 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawPath(path);
                },
                .shadow => {
                    var shadow = scene.shadowSlice()[cmd.index];
                    if (shadow.bounds.w <= 0 or shadow.bounds.h <= 0 or shadow.color.a <= 0) continue;
                    shadow.bounds = scaledRect(shadow.bounds, self.scale_factor);
                    shadow.offset_x *= self.scale_factor;
                    shadow.offset_y *= self.scale_factor;
                    shadow.spread *= self.scale_factor;
                    shadow.radius *= self.scale_factor;
                    shadow.blur_radius *= self.scale_factor;
                    if (shadow.clip) |clip| shadow.clip = scaledRect(clip, self.scale_factor);
                    if (shadow.clip) |clip| if (clip.w <= 0 or clip.h <= 0) continue;
                    const keys = clipKeysFor(shadow.bounds.x + shadow.offset_x - shadow.spread - shadow.blur_radius * 3, shadow.bounds.y + shadow.offset_y - shadow.spread - shadow.blur_radius * 3, shadow.bounds.w + shadow.spread * 2 + shadow.blur_radius * 6, shadow.bounds.h + shadow.spread * 2 + shadow.blur_radius * 6, shadow.clip, 0, &clip_buf);
                    try self.updateClip(keys);
                    try self.drawShadow(shadow);
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

    fn drawGlyph(self: *Renderer, g: scene_mod.Glyph, gx: f32, gy: f32, glyph_pixels: []const u8, ratio: f32) !void {
        const id = try self.glyphImage(g, glyph_pixels);
        const ctx = &self.ctx.?;
        if (!g.isColor()) ctx.setTint(.{ .color = penikoColor(g.color), .mode = .alpha_mask });
        self.setImagePaint(id, .low);
        // Image paints live in image pixel space; place the mask at the
        // glyph origin, stretched by the target scale over the mask's own
        // raster density (1 for an unupgraded 1x mask).
        ctx.setPaintTransform(kurbo.Affine.new(.{ ratio, 0, 0, ratio, gx, gy }));
        try ctx.fillRect(self.allocator, kurbo.Rect.new(gx, gy, gx + @as(f32, @floatFromInt(g.w)) * ratio, gy + @as(f32, @floatFromInt(g.h)) * ratio));
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
        const transformed = b.rotation != 0 or b.scale_x != 1 or b.scale_y != 1 or b.translate_x != 0 or b.translate_y != 0;
        const previous_transform = ctx.transform();
        if (transformed) {
            const center = kurbo.Point.new(b.x + b.w / 2, b.y + b.h / 2);
            const image_transform = kurbo.Affine.translate(kurbo.Vec2.new(center.x + b.translate_x, center.y + b.translate_y))
                .compose(kurbo.Affine.rotate(b.rotation))
                .compose(kurbo.Affine.scaleNonUniform(b.scale_x, b.scale_y))
                .compose(kurbo.Affine.translate(kurbo.Vec2.new(-center.x, -center.y)));
            ctx.setTransform(previous_transform.compose(image_transform));
        }
        ctx.setPaintTransform(kurbo.Affine.new(.{ sx, 0, 0, sy, tx, ty }));

        if (b.tint.r < 1 or b.tint.g < 1 or b.tint.b < 1 or b.tint.a < 1) {
            ctx.setTint(.{ .color = penikoColor(b.tint), .mode = .multiply });
        }
        self.setImagePaint(id, .low);
        try ctx.fillRect(self.allocator, kurbo.Rect.new(b.x, b.y, b.x + b.w, b.y + b.h));
        ctx.setTint(null);
        ctx.resetPaintTransform();
        if (transformed) ctx.setTransform(previous_transform);
    }

    fn drawStroke(self: *Renderer, stroke: scene_mod.Stroke) !void {
        const ctx = &self.ctx.?;
        ctx.setPaint(penikoColor(stroke.color));
        var style = kurbo.Stroke.new(@as(f64, stroke.width));
        style = style.withJoin(switch (stroke.join) {
            .miter => .miter,
            .round => .round,
            .bevel => .bevel,
        });
        style = style.withMiterLimit(@as(f64, stroke.miter_limit));
        style = style.withCaps(switch (stroke.cap) {
            .butt => .butt,
            .round => .round,
            .square => .square,
        });
        ctx.setStroke(style);
        self.path.clearRetainingCapacity();
        try self.path.append(self.allocator, kurbo.PathEl.moveTo(kurbo.Point.new(stroke.from.x, stroke.from.y)));
        try self.path.append(self.allocator, kurbo.PathEl.lineTo(kurbo.Point.new(stroke.to.x, stroke.to.y)));
        try ctx.strokePath(self.allocator, self.path.items);
    }

    fn drawPath(self: *Renderer, path: scene_mod.Path) !void {
        const ctx = &self.ctx.?;
        self.path.clearRetainingCapacity();
        for (path.segments[0..path.segment_len]) |segment| switch (segment) {
            .move_to => |p| try self.path.append(self.allocator, kurbo.PathEl.moveTo(kurbo.Point.new(p.x, p.y))),
            .line_to => |p| try self.path.append(self.allocator, kurbo.PathEl.lineTo(kurbo.Point.new(p.x, p.y))),
            .quad_to => |q| try self.path.append(self.allocator, kurbo.PathEl.quadTo(kurbo.Point.new(q.ctrl.x, q.ctrl.y), kurbo.Point.new(q.to.x, q.to.y))),
            .cubic_to => |c| try self.path.append(self.allocator, kurbo.PathEl.curveTo(kurbo.Point.new(c.ctrl1.x, c.ctrl1.y), kurbo.Point.new(c.ctrl2.x, c.ctrl2.y), kurbo.Point.new(c.to.x, c.to.y))),
            .close => try self.path.append(self.allocator, kurbo.PathEl.closePath()),
        };
        ctx.setPaint(penikoColor(path.color));
        const previous_transform = ctx.transform();
        const path_transform = kurbo.Affine.new(.{
            @floatCast(path.transform[0] * self.scale_factor),
            @floatCast(path.transform[1] * self.scale_factor),
            @floatCast(path.transform[2] * self.scale_factor),
            @floatCast(path.transform[3] * self.scale_factor),
            @floatCast(path.transform[4] * self.scale_factor),
            @floatCast(path.transform[5] * self.scale_factor),
        });
        ctx.setTransform(previous_transform.compose(path_transform));
        if (path.isStroke()) {
            var style = kurbo.Stroke.new(@as(f64, path.stroke_width));
            style = style.withJoin(switch (path.join) {
                .miter => .miter,
                .round => .round,
                .bevel => .bevel,
            });
            style = style.withMiterLimit(@as(f64, path.miter_limit));
            style = style.withCaps(switch (path.cap) {
                .butt => .butt,
                .round => .round,
                .square => .square,
            });
            ctx.setStroke(style);
            try ctx.strokePath(self.allocator, self.path.items);
        } else try ctx.fillPath(self.allocator, self.path.items);
        ctx.setTransform(previous_transform);
    }

    fn drawShadow(self: *Renderer, shadow: scene_mod.Shadow) !void {
        const ctx = &self.ctx.?;
        const rect = kurbo.Rect.new(
            shadow.bounds.x + shadow.offset_x - shadow.spread,
            shadow.bounds.y + shadow.offset_y - shadow.spread,
            shadow.bounds.x + shadow.bounds.w + shadow.offset_x + shadow.spread,
            shadow.bounds.y + shadow.bounds.h + shadow.offset_y + shadow.spread,
        );
        ctx.setPaint(penikoColor(shadow.color));
        if (shadow.inset) {
            try ctx.fillBlurredRoundedRect(self.allocator, rect, shadow.radius, @max(0, shadow.blur_radius), true);
            return;
        }
        var filter = try filter_effects.Filter.fromPrimitive(self.allocator, .{ .drop_shadow = .{
            .dx = 0,
            .dy = 0,
            .std_deviation = @max(0, shadow.blur_radius),
            .color = penikoColor(shadow.color),
            .edge_mode = .default,
        } });
        defer filter.deinit(self.allocator);
        ctx.setFilterEffect(filter.clone());
        defer ctx.resetFilterEffect();
        self.path.clearRetainingCapacity();
        try appendRoundedRect(&self.path, self.allocator, @floatCast(rect.x0), @floatCast(rect.y0), @floatCast(rect.width()), @floatCast(rect.height()), shadow.radius);
        try ctx.fillPath(self.allocator, self.path.items);
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
        const pixel_stride: usize = if (g.isColor()) 4 else 1;
        const source_bytes = count * pixel_stride;
        const hash = coverageHash(glyph_pixels, g.atlas_offset, source_bytes);
        if (self.glyph_images.get(g.atlas_offset)) |entry| {
            if (entry.w == g.w and entry.h == g.h and entry.hash == hash and entry.is_color == g.isColor()) return entry.id;
            _ = self.resources.destroyImage(self.allocator, entry.id);
            _ = self.glyph_images.remove(g.atlas_offset);
        }

        const bytes = try self.allocator.alloc(u8, count * 4);
        defer self.allocator.free(bytes);
        if (g.isColor()) {
            const start = @as(usize, g.atlas_offset);
            const available = @min(source_bytes, glyph_pixels.len -| start);
            if (available > 0) @memcpy(bytes[0..available], glyph_pixels[start..][0..available]);
            if (available < source_bytes) @memset(bytes[available..source_bytes], 0);
        } else {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const src = @as(usize, g.atlas_offset) + i;
                const coverage: u8 = if (src < glyph_pixels.len) glyph_pixels[src] else 0;
                bytes[i * 4 + 0] = coverage;
                bytes[i * 4 + 1] = coverage;
                bytes[i * 4 + 2] = coverage;
                bytes[i * 4 + 3] = coverage;
            }
        }
        const pixmap = try common.pixmap.Pixmap.fromParts(self.allocator, bytes, @intCast(g.w), @intCast(g.h), .{
            .may_have_transparency = true,
            .alpha_type = if (g.isColor()) .alpha else .alpha_premultiplied,
        });
        const id = try self.registerPixmap(pixmap);
        errdefer _ = self.resources.destroyImage(self.allocator, id);
        try self.glyph_images.put(self.allocator, g.atlas_offset, .{ .w = g.w, .h = g.h, .hash = hash, .is_color = g.isColor(), .id = id });
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

test "logical rectangle rasterizes at physical window density" {
    const t = std.testing;
    const scene = try t.allocator.create(scene_mod.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    try t.expect(scene.push(.{ .x = 0, .y = 0, .w = 100, .h = 50, .color = Color.white }));
    var renderer = Renderer.init(t.allocator);
    defer renderer.deinit();
    const pixels = try t.allocator.alloc(u8, 202 * 102 * 4);
    defer t.allocator.free(pixels);
    for ([_]f32{ 1, 2, 1.5 }) |scale| {
        renderer.scale_factor = scale;
        const width: usize = @intFromFloat(100 * scale);
        const height: usize = @intFromFloat(50 * scale);
        try renderer.render(pixels, 202, 102, .rgba32, Color.black, scene, &.{}, &.{});
        var ink: usize = 0;
        for (0..102) |y| {
            for (0..202) |x| {
                const expected: u8 = if (x < width and y < height) 255 else 0;
                try t.expectEqual(expected, pixels[(y * 202 + x) * 4]);
                if (expected != 0) ink += 1;
            }
        }
        try t.expectEqual(width * height, ink);
        std.debug.print("dpi raster: {d}x: 100x50 logical -> {d}x{d} physical ({d} pixels)\n", .{ scale, width, height, ink });
    }
    try t.expectEqual(@as(f32, 100), scene.slice()[0].w);
}

test "glyph mask stretches or renders 1:1 by its own density" {
    const t = std.testing;
    const scene = try t.allocator.create(scene_mod.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    // One opaque mask pixel at logical (0,0), 1x-rasterized.
    const glyph = scene_mod.Glyph{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .color = Color.white,
        .atlas_offset = 0,
        .clip = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    };
    try t.expect(scene.pushGlyph(glyph));
    var pool = [_]u8{ 255, 255, 255, 255 };
    var renderer = Renderer.init(t.allocator);
    defer renderer.deinit();
    const pixels = try t.allocator.alloc(u8, 10 * 10 * 4);
    defer t.allocator.free(pixels);

    // Density 1 at scale 2: the 1x mask stretches to 2x2 physical pixels.
    // (Single heap scene, mutated in place: Scene is multi-MB and must
    // never be stack-copied — see the hot-frame-structs stack budget test.)
    scene.glyphs[0].density = 1;
    renderer.scale_factor = 2;
    try renderer.render(pixels, 10, 10, .rgba32, Color.black, scene, &pool, &.{});
    try t.expectEqual(@as(u8, 255), pixels[0]);
    try t.expectEqual(@as(u8, 255), pixels[(1 * 10 + 1) * 4]); // (1,1) covered
    try t.expectEqual(@as(u8, 0), pixels[(2 * 10 + 2) * 4]); // (2,2) clear

    // Density 2 at scale 2 (the upgraded 2x2 mask): renders 1:1, same ink.
    scene.glyphs[0] = .{ .x = 0, .y = 0, .w = 2, .h = 2, .color = Color.white, .atlas_offset = 0, .density = 2, .clip = glyph.clip };
    try renderer.render(pixels, 10, 10, .rgba32, Color.black, scene, &pool, &.{});
    try t.expectEqual(@as(u8, 255), pixels[0]);
    try t.expectEqual(@as(u8, 255), pixels[(1 * 10 + 1) * 4]);
    try t.expectEqual(@as(u8, 0), pixels[(2 * 10 + 2) * 4]);

    // Density 2 at scale 1 (window moved to an unscaled monitor): the
    // higher-density mask compacts to the original 1x1 logical pixel.
    renderer.scale_factor = 1;
    try renderer.render(pixels, 10, 10, .rgba32, Color.black, scene, &pool, &.{});
    try t.expectEqual(@as(u8, 255), pixels[0]);
    try t.expectEqual(@as(u8, 0), pixels[(1 * 10 + 1) * 4]);
    try t.expectEqual(@as(u8, 0), pixels[(9 * 10 + 9) * 4]);
    std.debug.print("dpi glyph density: stretch/1:1/compact paths all render\n", .{});
}

fn scaledRect(r: geometry.Rect, scale: f32) geometry.Rect {
    return .{ .x = r.x * scale, .y = r.y * scale, .w = r.w * scale, .h = r.h * scale };
}

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

fn appendClipShape(list: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, shape: scene_mod.ClipShape) !void {
    switch (shape) {
        .rect => |rect| try appendRect(list, allocator, rect.x, rect.y, rect.w, rect.h),
        .rounded => |rounded| try appendRoundedRect(list, allocator, rounded.rect.x, rounded.rect.y, rounded.rect.w, rounded.rect.h, rounded.radius),
        .path => |path| {
            for (path.segments[0..path.segment_len]) |segment| switch (segment) {
                .move_to => |p| try list.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(p.x, p.y))),
                .line_to => |p| try list.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(p.x, p.y))),
                .quad_to => |q| try list.append(allocator, kurbo.PathEl.quadTo(kurbo.Point.new(q.ctrl.x, q.ctrl.y), kurbo.Point.new(q.to.x, q.to.y))),
                .cubic_to => |c| try list.append(allocator, kurbo.PathEl.curveTo(kurbo.Point.new(c.ctrl1.x, c.ctrl1.y), kurbo.Point.new(c.ctrl2.x, c.ctrl2.y), kurbo.Point.new(c.to.x, c.to.y))),
                .close => try list.append(allocator, kurbo.PathEl.closePath()),
            };
        },
    }
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

test "color glyph uses RGBA atlas bytes instead of a tint mask" {
    const t = std.testing;
    const scene = try t.allocator.create(scene_mod.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    const color_base: usize = @import("../core/limits.zig").MAX_ATLAS_PIXELS;
    const pool = try t.allocator.alloc(u8, color_base + 4);
    defer t.allocator.free(pool);
    pool[color_base + 0] = 0;
    pool[color_base + 1] = 255;
    pool[color_base + 2] = 0;
    pool[color_base + 3] = 255;
    try t.expect(scene.pushGlyph(.{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .color = Color.white,
        .atlas_offset = @intCast(color_base),
        .clip = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    }));
    var renderer = Renderer.init(t.allocator);
    defer renderer.deinit();
    const pixels = try t.allocator.alloc(u8, 4 * 4 * 4);
    defer t.allocator.free(pixels);
    try renderer.render(pixels, 4, 4, .rgba32, Color.black, scene, pool, &.{});
    try t.expect(pixels[1] > pixels[0]);
    try t.expect(pixels[1] > pixels[2]);
}

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

test "vellz strokes logical lines with physical scaling and clipping" {
    const t = std.testing;
    const scene = try t.allocator.create(scene_mod.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    var stroke_storage: scene_mod.StrokeStorage = undefined;
    scene.attachStrokeStorage(&stroke_storage);
    try t.expect(scene.pushStroke(.{
        .from = .{ .x = 0, .y = 5 },
        .to = .{ .x = 10, .y = 5 },
        .color = Color.white,
        .width = 2,
        .clip = .{ .x = 3, .y = 0, .w = 4, .h = 10 },
    }));

    var renderer = Renderer.init(t.allocator);
    defer renderer.deinit();
    renderer.scale_factor = 2;
    var pixels: [40 * 24 * 4]u8 = undefined;
    try renderer.render(&pixels, 40, 24, .rgba32, Color.black, scene, &.{}, &.{});

    var inside_ink = false;
    for (0..24) |y| {
        for (0..40) |x| {
            const red = pixels[(y * 40 + x) * 4];
            if (red != 0) {
                // Logical clip x=[3,7] becomes physical x=[6,14].
                try t.expect(x >= 6 and x < 14);
                inside_ink = true;
            }
        }
    }
    try t.expect(inside_ink);
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
        255, 0, 0,   255,
        0,   0, 255, 255,
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
