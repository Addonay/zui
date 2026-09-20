//! Optional ZUI-scene to Vellz-GPU scene bridge.
//!
//! This module is analyzed only for `-Dgpu=true`. It translates the ordered
//! scene subset whose ownership and rendering semantics are currently proven:
//! solid/gradient quads, rounded paths, rectangular clips, validated image
//! blits backed by caller-owned or cache-owned Vellz atlas IDs, and glyph
//! uploads owned by the optional bounded `BridgeCache`. Unsupported resources
//! return explicit errors instead of disappearing silently.

const std = @import("std");
const vellz = @import("vellz");
const scene_mod = @import("scene.zig");

const gpu_scene = vellz.gpu.scene;
const gpu_renderer = vellz.gpu.backend.renderer;
const gpu_resources = vellz.gpu.resources;
const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const paint = vellz.common.paint;
const pixmap = vellz.common.pixmap;
const filter_effects = vellz.common.filter_effects;

fn penikoColor(color: anytype) peniko.Color {
    return peniko.Color.new(.{ color.r, color.g, color.b, color.a });
}

fn whiteTint(color: anytype) bool {
    return color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1;
}

/// Bounded ownership for bitmap glyph and image uploads made by this bridge.
///
/// Caller-supplied image IDs used by compatibility calls remain borrowed and
/// are never retired here. Image-pool uploads are owned only when the caller
/// supplies this cache together with a renderer and resource set.
pub const BridgeCache = struct {
    /// Keep both tables fixed: atlas churn must not turn frame rendering into
    /// an unbounded resource allocation path.
    pub const max_entries: usize = 64;
    pub const max_image_entries: usize = 64;

    const Key = struct {
        atlas_offset: u32,
        width: u32,
        height: u32,
        is_color: bool,
        bytes_hash: u64,

        fn eql(self: @This(), other: @This()) bool {
            return self.atlas_offset == other.atlas_offset and
                self.width == other.width and
                self.height == other.height and
                self.is_color == other.is_color and
                self.bytes_hash == other.bytes_hash;
        }
    };

    const Entry = struct {
        valid: bool = false,
        key: Key = undefined,
        image_id: paint.ImageId = paint.ImageId.new(0),
    };

    const ImageKey = struct {
        pool_offset: u32,
        width: u32,
        height: u32,
        grayscale: bool,
        bytes_hash: u64,

        fn eql(self: @This(), other: @This()) bool {
            return self.pool_offset == other.pool_offset and
                self.width == other.width and
                self.height == other.height and
                self.grayscale == other.grayscale and
                self.bytes_hash == other.bytes_hash;
        }
    };

    const ImageEntry = struct {
        valid: bool = false,
        key: ImageKey = undefined,
        image_id: paint.ImageId = paint.ImageId.new(0),
    };

    entries: [max_entries]Entry = @splat(.{}),
    image_entries: [max_image_entries]ImageEntry = @splat(.{}),
    next_eviction: usize = 0,
    next_image_eviction: usize = 0,
    uploads: usize = 0,

    /// Number of live, owned glyph and image resources.
    pub fn len(self: *const @This()) usize {
        var count: usize = 0;
        for (self.entries) |entry| count += @intFromBool(entry.valid);
        for (self.image_entries) |entry| count += @intFromBool(entry.valid);
        return count;
    }

    pub fn glyphLen(self: *const @This()) usize {
        var count: usize = 0;
        for (self.entries) |entry| count += @intFromBool(entry.valid);
        return count;
    }

    pub fn imageLen(self: *const @This()) usize {
        var count: usize = 0;
        for (self.image_entries) |entry| count += @intFromBool(entry.valid);
        return count;
    }

    /// Number of uploads performed since initialization or the last full
    /// deinitialization. A stable value of one across repeated bridge calls
    /// is useful for diagnostics and regression tests.
    pub fn uploadCount(self: *const @This()) usize {
        return self.uploads;
    }

    /// Release every glyph and image owned by this cache through Vellz's
    /// pinned image cache. The cache must be deinitialized before `resources`.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, resources: *gpu_resources.Resources) !void {
        var first_error: ?anyerror = null;
        for (&self.entries) |*entry| {
            if (!entry.valid) continue;
            _ = resources.image_cache.deallocate(allocator, entry.image_id) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            entry.valid = false;
        }
        for (&self.image_entries) |*entry| {
            if (!entry.valid) continue;
            _ = resources.image_cache.deallocate(allocator, entry.image_id) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            entry.valid = false;
        }
        if (first_error) |err| return err;
        self.next_eviction = 0;
        self.next_image_eviction = 0;
        self.uploads = 0;
    }

    fn getOrUpload(
        self: *@This(),
        allocator: std.mem.Allocator,
        glyph: scene_mod.Glyph,
        glyph_bytes: []const u8,
        renderer: *gpu_renderer.Renderer,
        resources: *gpu_resources.Resources,
    ) !paint.ImageId {
        const key: Key = .{
            .atlas_offset = glyph.atlas_offset,
            .width = glyph.w,
            .height = glyph.h,
            .is_color = glyph.isColor(),
            .bytes_hash = hashGlyphBytes(glyph_bytes),
        };
        for (self.entries) |entry| {
            if (entry.valid and entry.key.eql(key)) return entry.image_id;
        }

        var slot: usize = 0;
        while (slot < self.entries.len and self.entries[slot].valid) : (slot += 1) {}
        if (slot == self.entries.len) {
            slot = self.next_eviction;
            self.next_eviction = (self.next_eviction + 1) % self.entries.len;
            _ = try resources.image_cache.deallocate(allocator, self.entries[slot].image_id);
            // Retire the old ownership before attempting the replacement so
            // an upload failure cannot leave a cache hit pointing at a freed
            // image slot.
            self.entries[slot].valid = false;
        }

        const image_id = try uploadGlyphImage(allocator, glyph, glyph_bytes, renderer, resources);
        self.entries[slot] = .{ .valid = true, .key = key, .image_id = image_id };
        self.uploads += 1;
        return image_id;
    }

    fn getOrUploadImage(
        self: *@This(),
        allocator: std.mem.Allocator,
        blit: scene_mod.ImageBlit,
        image_bytes: []const u8,
        renderer: *gpu_renderer.Renderer,
        resources: *gpu_resources.Resources,
    ) !paint.ImageId {
        const key: ImageKey = .{
            .pool_offset = blit.pool_offset,
            .width = blit.src_w,
            .height = blit.src_h,
            .grayscale = blit.gray,
            .bytes_hash = hashImageBytes(image_bytes),
        };
        for (self.image_entries) |entry| {
            if (entry.valid and entry.key.eql(key)) return entry.image_id;
        }

        var slot: usize = 0;
        while (slot < self.image_entries.len and self.image_entries[slot].valid) : (slot += 1) {}
        if (slot == self.image_entries.len) {
            slot = self.next_image_eviction;
            self.next_image_eviction = (self.next_image_eviction + 1) % self.image_entries.len;
            _ = try resources.image_cache.deallocate(allocator, self.image_entries[slot].image_id);
            self.image_entries[slot].valid = false;
        }

        const image_id = try uploadImage(allocator, blit, image_bytes, renderer, resources);
        self.image_entries[slot] = .{ .valid = true, .key = key, .image_id = image_id };
        self.uploads += 1;
        return image_id;
    }
};

fn hashGlyphBytes(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn hashImageBytes(bytes: []const u8) u64 {
    return hashGlyphBytes(bytes);
}

fn glyphPoolSlice(glyph: scene_mod.Glyph, glyph_pool: []const u8) ![]const u8 {
    const pixel_count = std.math.mul(usize, @intCast(glyph.w), @intCast(glyph.h)) catch return error.InvalidGlyphPoolReference;
    const bytes_per_pixel: usize = if (glyph.isColor()) 4 else 1;
    const source_len = std.math.mul(usize, pixel_count, bytes_per_pixel) catch return error.InvalidGlyphPoolReference;
    const start: usize = glyph.atlas_offset;
    const end = std.math.add(usize, start, source_len) catch return error.InvalidGlyphPoolReference;
    if (glyph.w == 0 or glyph.h == 0 or end > glyph_pool.len) return error.InvalidGlyphPoolReference;
    return glyph_pool[start..end];
}

fn imagePoolSlice(blit: scene_mod.ImageBlit, image_pool: []const u8) ![]const u8 {
    const pixel_count = std.math.mul(usize, @intCast(blit.src_w), @intCast(blit.src_h)) catch return error.InvalidImagePoolReference;
    const source_len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidImagePoolReference;
    const start: usize = blit.pool_offset;
    const end = std.math.add(usize, start, source_len) catch return error.InvalidImagePoolReference;
    if (blit.src_w == 0 or blit.src_h == 0 or end > image_pool.len) return error.InvalidImagePoolReference;
    return image_pool[start..end];
}

fn uploadGlyphImage(
    allocator: std.mem.Allocator,
    glyph: scene_mod.Glyph,
    glyph_bytes: []const u8,
    renderer: *gpu_renderer.Renderer,
    resources: *gpu_resources.Resources,
) !paint.ImageId {
    const pixel_count = @as(usize, glyph.w) * glyph.h;
    const rgba = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(rgba);
    if (glyph.isColor()) {
        @memcpy(rgba, glyph_bytes);
    } else {
        for (0..pixel_count) |i| {
            rgba[i * 4 + 0] = 255;
            rgba[i * 4 + 1] = 255;
            rgba[i * 4 + 2] = 255;
            rgba[i * 4 + 3] = glyph_bytes[i];
        }
    }
    var image = try pixmap.Pixmap.fromParts(allocator, rgba, @intCast(glyph.w), @intCast(glyph.h), .{
        .alpha_type = .alpha,
        .may_have_transparency = true,
    });
    defer image.deinit(allocator);
    return renderer.uploadImage(resources, &image);
}

fn uploadImage(
    allocator: std.mem.Allocator,
    blit: scene_mod.ImageBlit,
    image_bytes: []const u8,
    renderer: *gpu_renderer.Renderer,
    resources: *gpu_resources.Resources,
) !paint.ImageId {
    const bytes = try allocator.alloc(u8, image_bytes.len);
    defer allocator.free(bytes);
    @memcpy(bytes, image_bytes);
    if (blit.gray) {
        const pixel_count = @as(usize, blit.src_w) * blit.src_h;
        for (0..pixel_count) |i| {
            const offset = i * 4;
            const r = @as(u32, bytes[offset]);
            const g = @as(u32, bytes[offset + 1]);
            const b = @as(u32, bytes[offset + 2]);
            const luma: u8 = @intCast((r * 77 + g * 150 + b * 29) >> 8);
            bytes[offset] = luma;
            bytes[offset + 1] = luma;
            bytes[offset + 2] = luma;
        }
    }
    var image = try pixmap.Pixmap.fromParts(allocator, bytes, @intCast(blit.src_w), @intCast(blit.src_h), .{
        .alpha_type = .alpha,
        .may_have_transparency = true,
    });
    defer image.deinit(allocator);
    return renderer.uploadImage(resources, &image);
}

/// Translate the supported ordered subset of a ZUI scene into a Vellz GPU
/// scene. With a `BridgeCache`, image bytes are uploaded and cached by pool
/// identity, dimensions, grayscale mode, and source-byte hash. Without one,
/// the supplied image IDs are borrowed compatibility resources.
pub fn bridgeScene(
    allocator: std.mem.Allocator,
    source: *const scene_mod.Scene,
    target: *gpu_scene.Scene,
    image_id: ?paint.ImageId,
    gray_image_id: ?paint.ImageId,
    image_pool: []const u8,
    glyph_pool: []const u8,
    renderer: ?*gpu_renderer.Renderer,
    resources: ?*gpu_resources.Resources,
    cache: ?*BridgeCache,
) !void {
    const GroupState = struct { transform: kurbo.Affine, opacity_layer: bool, clip_layer: bool };
    var group_stack: [64]GroupState = undefined;
    var group_len: usize = 0;
    for (source.commandSlice()) |command| {
        if (command.kind == .begin_group) {
            if (group_len >= group_stack.len or command.index >= source.groupSlice().len) return error.UnsupportedSceneGroup;
            const group = source.groupSlice()[command.index];
            const local = kurbo.Affine.new(.{
                @floatCast(group.transform[0]), @floatCast(group.transform[1]),
                @floatCast(group.transform[2]), @floatCast(group.transform[3]),
                @floatCast(group.transform[4]), @floatCast(group.transform[5]),
            });
            const parent = if (group_len == 0) kurbo.Affine.IDENTITY else group_stack[group_len - 1].transform;
            const combined = parent.compose(local);
            target.setTransform(combined);
            var clip_layer = false;
            if (group.clip) |shape| {
                var clip = std.ArrayListUnmanaged(kurbo.PathEl).empty;
                defer clip.deinit(allocator);
                try appendClipShape(&clip, allocator, shape);
                try target.pushClipLayer(clip.items);
                clip_layer = true;
            }
            var opacity_layer = false;
            if (group.opacity < 1) {
                try target.pushOpacityLayer(group.opacity);
                opacity_layer = true;
            }
            group_stack[group_len] = .{ .transform = combined, .opacity_layer = opacity_layer, .clip_layer = clip_layer };
            group_len += 1;
            continue;
        }
        if (command.kind == .end_group) {
            if (group_len == 0) return error.UnsupportedSceneGroup;
            group_len -= 1;
            const state = group_stack[group_len];
            if (state.opacity_layer) try target.popLayer();
            if (state.clip_layer) try target.popLayer();
            target.resetTransform();
            if (group_len > 0) target.setTransform(group_stack[group_len - 1].transform);
            continue;
        }
        if (command.kind == .glyph) {
            const glyph = source.glyphSlice()[command.index];
            const is_color = glyph.isColor();
            const glyph_bytes = try glyphPoolSlice(glyph, glyph_pool);
            if (glyph.clip.w <= 0 or glyph.clip.h <= 0) continue;
            const upload = renderer orelse return error.UnsupportedGlyphResource;
            const resource_state = resources orelse return error.UnsupportedGlyphResource;
            const uploaded_image_id = if (cache) |glyph_cache|
                try glyph_cache.getOrUpload(allocator, glyph, glyph_bytes, upload, resource_state)
            else
                try uploadGlyphImage(allocator, glyph, glyph_bytes, upload, resource_state);
            if (!is_color) target.setTint(.{ .color = penikoColor(glyph.color), .mode = .alpha_mask });
            target.setPaint(paint.PaintType.fromImage(.{
                .image = paint.ImageSource.initOpaqueIdWithTransparencyHint(uploaded_image_id, true),
                .sampler = .{ .quality = .low },
            }));
            const ratio = 1.0 / glyph.density;
            target.setPaintTransform(kurbo.Affine.new(.{ ratio, 0, 0, ratio, glyph.x, glyph.y }));
            var rect = kurbo.Rect.new(glyph.x, glyph.y, glyph.x + @as(f32, @floatFromInt(glyph.w)) * ratio, glyph.y + @as(f32, @floatFromInt(glyph.h)) * ratio);
            try target.fillRect(&rect);
            target.resetPaintTransform();
            target.resetTint();
            continue;
        }
        if (command.kind == .blit) {
            const blit = source.imageSlice()[command.index];
            const source_bytes = try imagePoolSlice(blit, image_pool);
            const selected_image_id = if (cache) |image_cache| blk: {
                const upload = renderer orelse return error.UnsupportedImageBlit;
                const resource_state = resources orelse return error.UnsupportedImageBlit;
                break :blk try image_cache.getOrUploadImage(allocator, blit, source_bytes, upload, resource_state);
            } else if (blit.gray) gray_image_id else image_id;
            if (selected_image_id == null) return error.UnsupportedImageBlit;
            if (!std.math.isFinite(blit.x) or !std.math.isFinite(blit.y) or
                !std.math.isFinite(blit.w) or !std.math.isFinite(blit.h) or
                !std.math.isFinite(blit.src_x) or !std.math.isFinite(blit.src_y) or
                !std.math.isFinite(blit.src_crop_w) or !std.math.isFinite(blit.src_crop_h) or
                !std.math.isFinite(blit.rotation) or !std.math.isFinite(blit.scale_x) or
                !std.math.isFinite(blit.scale_y) or !std.math.isFinite(blit.translate_x) or
                !std.math.isFinite(blit.translate_y) or !std.math.isFinite(blit.radius))
            {
                return error.InvalidImageBlit;
            }
            if (blit.w <= 0 or blit.h <= 0 or blit.scale_x == 0 or blit.scale_y == 0) continue;

            const swf: f32 = @floatFromInt(blit.src_w);
            const shf: f32 = @floatFromInt(blit.src_h);
            const crop_w = if (blit.src_crop_w > 0) @min(blit.src_crop_w, swf) else swf;
            const crop_h = if (blit.src_crop_h > 0) @min(blit.src_crop_h, shf) else shf;
            const crop_x = std.math.clamp(blit.src_x, 0, swf - crop_w);
            const crop_y = std.math.clamp(blit.src_y, 0, shf - crop_h);
            const sx = blit.w / crop_w;
            const sy = blit.h / crop_h;
            const tx = blit.x - crop_x * sx;
            const ty = blit.y - crop_y * sy;

            var clip_path: ?kurbo.BezPath = null;
            var draw_path: std.ArrayListUnmanaged(kurbo.PathEl) = .empty;
            defer draw_path.deinit(allocator);
            var clip_pushed = false;
            defer if (clip_pushed) target.popClipPath() catch {};
            defer if (clip_path) |*path| path.deinit(allocator);
            if (blit.clip.w <= 0 or blit.clip.h <= 0) continue;
            const clip_rect = blit.clip;
            var clip = try kurbo.Rect.new(clip_rect.x, clip_rect.y, clip_rect.x + clip_rect.w, clip_rect.y + clip_rect.h).toPath(0.1, allocator);
            clip_path = clip;
            try target.pushClipPath(clip.elementsSlice());
            clip_pushed = true;

            if (blit.rotation != 0 or blit.scale_x != 1 or blit.scale_y != 1 or blit.translate_x != 0 or blit.translate_y != 0) {
                const center = kurbo.Point.new(blit.x + blit.w / 2, blit.y + blit.h / 2);
                const image_transform =
                    kurbo.Affine.translate(kurbo.Vec2.new(center.x + blit.translate_x, center.y + blit.translate_y))
                        .compose(kurbo.Affine.rotate(blit.rotation))
                        .compose(kurbo.Affine.scaleNonUniform(blit.scale_x, blit.scale_y))
                        .compose(kurbo.Affine.translate(kurbo.Vec2.new(-center.x, -center.y)));
                const parent_transform = if (group_len > 0) group_stack[group_len - 1].transform else kurbo.Affine.IDENTITY;
                target.setTransform(parent_transform.compose(image_transform));
            }
            target.setPaintTransform(kurbo.Affine.new(.{ sx, 0, 0, sy, tx, ty }));
            if (!whiteTint(blit.tint)) target.setTint(.{ .color = penikoColor(blit.tint), .mode = .multiply });
            target.setPaint(paint.PaintType.fromImage(.{
                .image = paint.ImageSource.initOpaqueIdWithTransparencyHint(selected_image_id.?, true),
                .sampler = .{ .quality = .low },
            }));
            if (blit.radius > 0) {
                try appendRoundedRect(&draw_path, allocator, blit.x, blit.y, blit.w, blit.h, blit.radius);
                try target.fillPath(draw_path.items);
            } else {
                var rect = kurbo.Rect.new(blit.x, blit.y, blit.x + blit.w, blit.y + blit.h);
                try target.fillRect(&rect);
            }
            target.resetPaintTransform();
            target.resetTransform();
            if (group_len > 0) target.setTransform(group_stack[group_len - 1].transform);
            target.resetTint();
            try target.popClipPath();
            clip_pushed = false;
            continue;
        }

        if (command.kind == .stroke) {
            const stroke = source.strokeSlice()[command.index];
            if (!std.math.isFinite(stroke.from.x) or !std.math.isFinite(stroke.from.y) or
                !std.math.isFinite(stroke.to.x) or !std.math.isFinite(stroke.to.y) or
                !std.math.isFinite(stroke.width) or
                !std.math.isFinite(stroke.color.r) or !std.math.isFinite(stroke.color.g) or
                !std.math.isFinite(stroke.color.b) or !std.math.isFinite(stroke.color.a) or
                stroke.color.r < 0 or stroke.color.r > 1 or stroke.color.g < 0 or stroke.color.g > 1 or
                stroke.color.b < 0 or stroke.color.b > 1 or stroke.color.a < 0 or stroke.color.a > 1)
            {
                return error.InvalidStroke;
            }
            if (stroke.width <= 0 or stroke.color.a == 0 or stroke.from.eql(stroke.to)) continue;
            if (stroke.clip.w <= 0 or stroke.clip.h <= 0) continue;

            var clip_path: ?kurbo.BezPath = null;
            var line_path: std.ArrayListUnmanaged(kurbo.PathEl) = .empty;
            defer line_path.deinit(allocator);
            var clip_pushed = false;
            defer if (clip_pushed) target.popClipPath() catch {};
            defer if (clip_path) |*path| path.deinit(allocator);

            const clip = stroke.clip;
            const path = try kurbo.Rect.new(clip.x, clip.y, clip.x + clip.w, clip.y + clip.h).toPath(0.1, allocator);
            clip_path = path;
            try target.pushClipPath(path.elementsSlice());
            clip_pushed = true;
            try line_path.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(stroke.from.x, stroke.from.y)));
            try line_path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(stroke.to.x, stroke.to.y)));
            target.setPaint(paint.PaintType.fromAlphaColor(penikoColor(stroke.color)));
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
            target.setStroke(style);
            try target.strokePath(line_path.items);
            if (clip_pushed) {
                try target.popClipPath();
                clip_pushed = false;
            }
            continue;
        }

        if (command.kind == .path) {
            const scene_path = source.pathSlice()[command.index];
            if (scene_path.segment_len == 0 or scene_path.clip.w <= 0 or scene_path.clip.h <= 0 or scene_path.color.a <= 0) continue;
            var path: std.ArrayListUnmanaged(kurbo.PathEl) = .empty;
            defer path.deinit(allocator);
            try appendScenePath(&path, allocator, scene_path);
            var clip = try kurbo.Rect.new(scene_path.clip.x, scene_path.clip.y, scene_path.clip.x + scene_path.clip.w, scene_path.clip.y + scene_path.clip.h).toPath(0.1, allocator);
            defer clip.deinit(allocator);
            try target.pushClipPath(clip.elementsSlice());
            target.setPaint(paint.PaintType.fromAlphaColor(penikoColor(scene_path.color)));
            const parent_transform = if (group_len > 0) group_stack[group_len - 1].transform else kurbo.Affine.IDENTITY;
            target.setTransform(parent_transform.compose(kurbo.Affine.new(.{
                @floatCast(scene_path.transform[0]),
                @floatCast(scene_path.transform[1]),
                @floatCast(scene_path.transform[2]),
                @floatCast(scene_path.transform[3]),
                @floatCast(scene_path.transform[4]),
                @floatCast(scene_path.transform[5]),
            })));
            if (scene_path.isStroke()) {
                var style = kurbo.Stroke.new(@as(f64, scene_path.stroke_width));
                style = style.withJoin(switch (scene_path.join) {
                    .miter => .miter,
                    .round => .round,
                    .bevel => .bevel,
                });
                style = style.withMiterLimit(@as(f64, scene_path.miter_limit));
                style = style.withCaps(switch (scene_path.cap) {
                    .butt => .butt,
                    .round => .round,
                    .square => .square,
                });
                target.setStroke(style);
                try target.strokePath(path.items);
            } else try target.fillPath(path.items);
            target.resetTransform();
            if (group_len > 0) target.setTransform(parent_transform);
            try target.popClipPath();
            continue;
        }

        if (command.kind == .shadow) {
            const shadow = source.shadowSlice()[command.index];
            if (shadow.bounds.w <= 0 or shadow.bounds.h <= 0 or shadow.color.a <= 0) continue;
            var clip_pushed = false;
            if (shadow.clip) |clip_rect| {
                if (clip_rect.w <= 0 or clip_rect.h <= 0) continue;
                var clip = try kurbo.Rect.new(clip_rect.x, clip_rect.y, clip_rect.x + clip_rect.w, clip_rect.y + clip_rect.h).toPath(0.1, allocator);
                defer clip.deinit(allocator);
                try target.pushClipPath(clip.elementsSlice());
                clip_pushed = true;
            }
            defer if (clip_pushed) target.popClipPath() catch {};
            const rect = kurbo.Rect.new(
                shadow.bounds.x + shadow.offset_x - shadow.spread,
                shadow.bounds.y + shadow.offset_y - shadow.spread,
                shadow.bounds.x + shadow.bounds.w + shadow.offset_x + shadow.spread,
                shadow.bounds.y + shadow.bounds.h + shadow.offset_y + shadow.spread,
            );
            target.setPaint(paint.PaintType.fromAlphaColor(penikoColor(shadow.color)));
            if (shadow.inset) {
                try target.fillBlurredRoundedRect(rect, shadow.radius, @max(0, shadow.blur_radius), true);
            } else {
                const filter = try filter_effects.Filter.fromPrimitive(allocator, .{ .drop_shadow = .{
                    .dx = 0,
                    .dy = 0,
                    .std_deviation = @max(0, shadow.blur_radius),
                    .color = penikoColor(shadow.color),
                    .edge_mode = .default,
                } });
                target.setFilterEffect(filter);
                var rounded: std.ArrayListUnmanaged(kurbo.PathEl) = .empty;
                defer rounded.deinit(allocator);
                try appendRoundedRect(&rounded, allocator, @floatCast(rect.x0), @floatCast(rect.y0), @floatCast(rect.width()), @floatCast(rect.height()), shadow.radius);
                try target.fillPath(rounded.items);
                target.resetFilterEffect();
            }
            continue;
        }

        const quad = source.slice()[command.index];
        if (!std.math.isFinite(quad.x) or !std.math.isFinite(quad.y) or
            !std.math.isFinite(quad.w) or !std.math.isFinite(quad.h) or
            !std.math.isFinite(quad.color.r) or !std.math.isFinite(quad.color.g) or
            !std.math.isFinite(quad.color.b) or !std.math.isFinite(quad.color.a) or
            quad.color.r < 0 or quad.color.r > 1 or quad.color.g < 0 or quad.color.g > 1 or
            quad.color.b < 0 or quad.color.b > 1 or quad.color.a < 0 or quad.color.a > 1)
        {
            return error.InvalidSceneColor;
        }
        if (quad.w <= 0 or quad.h <= 0 or quad.color.a == 0) continue;
        const color = penikoColor(quad.color);
        var clip_path: ?kurbo.BezPath = null;
        var draw_path: std.ArrayListUnmanaged(kurbo.PathEl) = .empty;
        defer draw_path.deinit(allocator);
        var clip_pushed = false;
        defer if (clip_pushed) target.popClipPath() catch {};
        defer if (clip_path) |*path| path.deinit(allocator);
        if (quad.clip) |clip| {
            const path = try kurbo.Rect.new(clip.x, clip.y, clip.x + clip.w, clip.y + clip.h).toPath(0.1, allocator);
            clip_path = path;
            try target.pushClipPath(path.elementsSlice());
            clip_pushed = true;
        }
        if (quad.gradient_to) |end| {
            const stops = try peniko.ColorStops.fromSlice(allocator, &.{
                .{ .offset = 0, .color = color },
                .{ .offset = 1, .color = penikoColor(end) },
            });
            var gradient = peniko.Gradient.newLinear(.{ .x = quad.x, .y = quad.y }, .{ .x = quad.x + quad.w, .y = quad.y });
            gradient.stops = stops;
            target.setPaint(paint.PaintType.fromGradient(gradient));
        } else target.setPaint(paint.PaintType.fromAlphaColor(color));
        if (quad.border_width > 0) {
            const inner_w = quad.w - quad.border_width * 2;
            const inner_h = quad.h - quad.border_width * 2;
            if (inner_w > 0 and inner_h > 0) {
                try appendRoundedRect(&draw_path, allocator, quad.x, quad.y, quad.w, quad.h, quad.radius);
                try appendRoundedRect(
                    &draw_path,
                    allocator,
                    quad.x + quad.border_width,
                    quad.y + quad.border_width,
                    inner_w,
                    inner_h,
                    @max(0, quad.radius - quad.border_width),
                );
                target.setFillRule(.even_odd);
                try target.fillPath(draw_path.items);
                target.setFillRule(.non_zero);
            } else {
                var rect = kurbo.Rect.new(quad.x, quad.y, quad.x + quad.w, quad.y + quad.h);
                try target.fillRect(&rect);
            }
        } else if (quad.radius > 0) {
            try appendRoundedRect(&draw_path, allocator, quad.x, quad.y, quad.w, quad.h, quad.radius);
            try target.fillPath(draw_path.items);
        } else {
            var rect = kurbo.Rect.new(quad.x, quad.y, quad.x + quad.w, quad.y + quad.h);
            try target.fillRect(&rect);
        }
        if (clip_pushed) {
            try target.popClipPath();
            clip_pushed = false;
        }
    }
}

/// Compatibility wrapper for callers that do not retain glyph resources
/// across frames. New GPU integrations should pass a `BridgeCache` to
/// `bridgeScene` instead.
pub fn bridgeSceneCompat(
    allocator: std.mem.Allocator,
    source: *const scene_mod.Scene,
    target: *gpu_scene.Scene,
    image_id: ?paint.ImageId,
    gray_image_id: ?paint.ImageId,
    image_pool: []const u8,
    glyph_pool: []const u8,
    renderer: ?*gpu_renderer.Renderer,
    resources: ?*gpu_resources.Resources,
) !void {
    return bridgeScene(
        allocator,
        source,
        target,
        image_id,
        gray_image_id,
        image_pool,
        glyph_pool,
        renderer,
        resources,
        null,
    );
}

fn appendRoundedRect(path: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, radius: f32) !void {
    const r = std.math.clamp(radius, 0, @min(w, h) / 2);
    if (r <= 0) {
        try path.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(x, y)));
        try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x + w, y)));
        try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x + w, y + h)));
        try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x, y + h)));
        try path.append(allocator, kurbo.PathEl.closePath());
        return;
    }
    const k = r * 0.55228475;
    const x1 = x + w;
    const y1 = y + h;
    try path.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(x + r, y)));
    try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x1 - r, y)));
    try appendCubic(path, allocator, x1 - r + k, y, x1, y + r - k, x1, y + r);
    try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x1, y1 - r)));
    try appendCubic(path, allocator, x1, y1 - r + k, x1 - r + k, y1, x1 - r, y1);
    try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x + r, y1)));
    try appendCubic(path, allocator, x + r - k, y1, x, y1 - r + k, x, y1 - r);
    try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(x, y + r)));
    try appendCubic(path, allocator, x, y + r - k, x + r - k, y, x + r, y);
    try path.append(allocator, kurbo.PathEl.closePath());
}

fn appendClipShape(path: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, shape: scene_mod.ClipShape) !void {
    switch (shape) {
        .rect => |rect| {
            try path.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(rect.x, rect.y)));
            try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(rect.x + rect.w, rect.y)));
            try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(rect.x + rect.w, rect.y + rect.h)));
            try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(rect.x, rect.y + rect.h)));
            try path.append(allocator, kurbo.PathEl.closePath());
        },
        .rounded => |rounded| try appendRoundedRect(path, allocator, rounded.rect.x, rounded.rect.y, rounded.rect.w, rounded.rect.h, rounded.radius),
        .path => |clip_path| try appendScenePath(path, allocator, clip_path),
    }
}

fn appendScenePath(path: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, scene_path: scene_mod.Path) !void {
    for (scene_path.segments[0..scene_path.segment_len]) |segment| switch (segment) {
        .move_to => |p| try path.append(allocator, kurbo.PathEl.moveTo(kurbo.Point.new(p.x, p.y))),
        .line_to => |p| try path.append(allocator, kurbo.PathEl.lineTo(kurbo.Point.new(p.x, p.y))),
        .quad_to => |q| try path.append(allocator, kurbo.PathEl.quadTo(kurbo.Point.new(q.ctrl.x, q.ctrl.y), kurbo.Point.new(q.to.x, q.to.y))),
        .cubic_to => |c| try path.append(allocator, kurbo.PathEl.curveTo(kurbo.Point.new(c.ctrl1.x, c.ctrl1.y), kurbo.Point.new(c.ctrl2.x, c.ctrl2.y), kurbo.Point.new(c.to.x, c.to.y))),
        .close => try path.append(allocator, kurbo.PathEl.closePath()),
    };
}

fn appendCubic(path: *std.ArrayListUnmanaged(kurbo.PathEl), allocator: std.mem.Allocator, p1x: f32, p1y: f32, p2x: f32, p2y: f32, p3x: f32, p3y: f32) !void {
    try path.append(allocator, kurbo.PathEl.curveTo(kurbo.Point.new(p1x, p1y), kurbo.Point.new(p2x, p2y), kurbo.Point.new(p3x, p3y)));
}
