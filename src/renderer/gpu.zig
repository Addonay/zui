//! GPU renderer on the vendored `gpu` layer: a port of gpui_wgpu/src/wgpu_renderer.rs and wgpu_atlas.rs.
//! The batching, draw order, instance packing and path compositing follow the wgpu
//! renderer; shader math lives in shaders.glsl (a port of shaders.wgsl). Instances are
//! per-instance vertex attributes, so the renderer needs no storage buffers.
const std = @import("std");
const gpu = @import("../gpu/root.zig");
const shaders = @import("shaders_gen.zig");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Bounds = geometry.Bounds;
const Corners = geometry.Corners;
const Edges = geometry.Edges;
const ScaledPixels = geometry.ScaledPixels;
const DevicePixels = geometry.DevicePixels;
const Scene = scene.Scene;
const Hsla = color.Hsla;
const Background = color.Background;
const AtlasTextureId = atlas.AtlasTextureId;
const AtlasTextureKind = atlas.AtlasTextureKind;
const AtlasKey = atlas.AtlasKey;
const AtlasTile = atlas.AtlasTile;
const TileBuilder = atlas.TileBuilder;
const PlatformAtlas = atlas.PlatformAtlas;

const TargetSize = struct { width: u32, height: u32 };

/// Where a frame is drawn.
pub const Target = union(enum) {
    /// A swapchain image acquired for this frame. Its depth format is ignored: the renderer draws without depth.
    swapchain: gpu.Swapchain,
    /// An offscreen color attachment and its size in pixels.
    attachment: Attachment,

    pub const Attachment = struct {
        view: gpu.View,
        width: u32,
        height: u32,
    };

    fn size(self: Target) TargetSize {
        return switch (self) {
            .swapchain => |sc| .{ .width = sc.width, .height = sc.height },
            .attachment => |a| .{ .width = a.width, .height = a.height },
        };
    }
};

/// Renderer settings that do not change per frame.
pub const Options = struct {
    /// Output alpha is premultiplied (the window's composite mode).
    premultiplied_alpha: bool = false,
    /// Gamma used for the monochrome text contrast curve, as in GPUI's rendering parameters.
    gamma: f64 = 1.8,
    /// Enhanced contrast for grayscale glyphs.
    grayscale_enhanced_contrast: f32 = 1.0,
    /// Requested MSAA sample count for path rasterization; falls back to 1 when unsupported.
    path_sample_count: u32 = 4,
    /// The device's per-frame transient upload capacity. A frame needing more is refused.
    max_frame_upload_bytes: usize = 32 * 1024 * 1024,
};

/// Counters for the last `draw` call.
pub const Stats = struct {
    quads: usize = 0,
    shadows: usize = 0,
    underlines: usize = 0,
    sprites: usize = 0,
    paths: usize = 0,
    draw_calls: usize = 0,
    /// Instance bytes uploaded for the frame.
    upload_bytes: usize = 0,
};

// ---------------------------------------------------------------------------
// Instance layouts. Each struct field is one per-instance vertex attribute (vec4),
// in shader location order; the shader names are in shaders.glsl.
// ---------------------------------------------------------------------------

pub const QuadInstance = extern struct {
    bounds: [4]f32,
    clip: [4]f32,
    radii: [4]f32,
    widths: [4]f32,
    border: [4]f32,
    solid: [4]f32,
    color0: [4]f32,
    color1: [4]f32,
    /// Background tag, color space, angle or pattern height, first stop percentage.
    bg: [4]f32,
    /// Second stop percentage, border style (0 solid, 1 dashed), exact pattern remainder.
    bg2: [4]f32,
};

pub const ShadowInstance = extern struct {
    bounds: [4]f32,
    radii: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    element_bounds: [4]f32,
    element_radii: [4]f32,
    /// Blur radius, inset flag.
    params: [4]f32,
};

pub const UnderlineInstance = extern struct {
    bounds: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    /// Thickness, wavy flag.
    params: [4]f32,
};

pub const MonoSpriteInstance = extern struct {
    /// Tile origin and size in normalized atlas coordinates.
    uv: [4]f32,
    bounds: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    /// Row-major rotation and scale of the sprite transform.
    rotation_scale: [4]f32,
    translation: [4]f32,
};

pub const PolySpriteInstance = extern struct {
    uv: [4]f32,
    bounds: [4]f32,
    clip: [4]f32,
    radii: [4]f32,
    /// Grayscale flag, opacity.
    params: [4]f32,
};

/// One vertex of a path triangle, with the clipped path bounds and its background.
pub const PathVertex = extern struct {
    xy_st: [4]f32,
    bounds: [4]f32,
    bg: [4]f32,
    solid: [4]f32,
    color0: [4]f32,
    color1: [4]f32,
    bg2: [4]f32,
};

pub const PathSpriteInstance = extern struct {
    bounds: [4]f32,
};

const VsParams = extern struct {
    /// Viewport width and height, 1 when sampled rows are flipped, unused.
    viewport: [4]f32,
};

const FsParams = extern struct {
    gamma_ratios: [4]f32,
    /// Premultiplied flag, grayscale enhanced contrast.
    settings: [4]f32,
};

/// Attributes for a struct of vec4 fields, one per shader location.
fn vertexAttrs(comptime T: type) [@typeInfo(T).@"struct".field_names.len]gpu.VertexAttr {
    comptime {
        const names = @typeInfo(T).@"struct".field_names;
        var out: [names.len]gpu.VertexAttr = undefined;
        for (names, 0..) |name, i| out[i] = .{ .format = .float4, .buffer = 0, .offset = @offsetOf(T, name) };
        return out;
    }
}

const quad_attrs = vertexAttrs(QuadInstance);
const shadow_attrs = vertexAttrs(ShadowInstance);
const underline_attrs = vertexAttrs(UnderlineInstance);
const mono_attrs = vertexAttrs(MonoSpriteInstance);
const poly_attrs = vertexAttrs(PolySpriteInstance);
const path_vertex_attrs = vertexAttrs(PathVertex);
const path_sprite_attrs = vertexAttrs(PathSpriteInstance);

// ---------------------------------------------------------------------------
// Packing helpers
// ---------------------------------------------------------------------------

inline fn hsla4(c: Hsla) [4]f32 {
    return .{ c.h, c.s, c.l, c.a };
}

inline fn bounds4(b: Bounds(ScaledPixels)) [4]f32 {
    return .{ b.origin.x, b.origin.y, b.size.width, b.size.height };
}

inline fn corners4(c: Corners(ScaledPixels)) [4]f32 {
    return .{ c.top_left, c.top_right, c.bottom_right, c.bottom_left };
}

inline fn edges4(e: Edges(ScaledPixels)) [4]f32 {
    return .{ e.top, e.right, e.bottom, e.left };
}

const BackgroundFields = struct {
    meta: [4]f32,
    solid: [4]f32,
    color0: [4]f32,
    color1: [4]f32,
    extra: [4]f32,
};

fn backgroundFields(bg: Background) BackgroundFields {
    return .{
        .meta = .{
            @floatFromInt(@intFromEnum(bg.tag)),
            @floatFromInt(@intFromEnum(bg.color_space_)),
            bg.gradient_angle_or_pattern_height,
            bg.colors[0].percentage,
        },
        .solid = hsla4(bg.solid),
        .color0 = hsla4(bg.colors[0].color),
        .color1 = hsla4(bg.colors[1].color),
        .extra = .{
            bg.colors[1].percentage,
            0,
            if (bg.tag == .pattern_slash) @rem(bg.gradient_angle_or_pattern_height, 65535.0) else 0,
            0,
        },
    };
}

fn packQuad(q: *const scene.Quad) QuadInstance {
    const bg = backgroundFields(q.background);
    return .{
        .bounds = bounds4(q.bounds),
        .clip = bounds4(q.content_mask.bounds),
        .radii = corners4(q.corner_radii),
        .widths = edges4(q.border_widths),
        .border = hsla4(q.border_color),
        .solid = bg.solid,
        .color0 = bg.color0,
        .color1 = bg.color1,
        .bg = bg.meta,
        .bg2 = .{ bg.extra[0], @floatFromInt(@intFromEnum(q.border_style)), bg.extra[2], 0 },
    };
}

fn packShadow(s: *const scene.Shadow) ShadowInstance {
    return .{
        .bounds = bounds4(s.bounds),
        .radii = corners4(s.corner_radii),
        .clip = bounds4(s.content_mask.bounds),
        .color = hsla4(s.color),
        .element_bounds = bounds4(s.element_bounds),
        .element_radii = corners4(s.element_corner_radii),
        .params = .{ s.blur_radius, @floatFromInt(s.inset), 0, 0 },
    };
}

fn packUnderline(u: *const scene.Underline) UnderlineInstance {
    return .{
        .bounds = bounds4(u.bounds),
        .clip = bounds4(u.content_mask.bounds),
        .color = hsla4(u.color),
        .params = .{ u.thickness, @floatFromInt(u.wavy.value), 0, 0 },
    };
}

fn packMono(s: *const scene.MonochromeSprite, texture_w: f32, texture_h: f32) MonoSpriteInstance {
    const t = s.transformation;
    return .{
        .uv = tileUv(s.tile, texture_w, texture_h),
        .bounds = bounds4(s.bounds),
        .clip = bounds4(s.content_mask.bounds),
        .color = hsla4(s.color),
        .rotation_scale = .{ t.rotation_scale[0][0], t.rotation_scale[0][1], t.rotation_scale[1][0], t.rotation_scale[1][1] },
        .translation = .{ t.translation[0], t.translation[1], 0, 0 },
    };
}

fn packPoly(s: *const scene.PolychromeSprite, texture_w: f32, texture_h: f32) PolySpriteInstance {
    return .{
        .uv = tileUv(s.tile, texture_w, texture_h),
        .bounds = bounds4(s.bounds),
        .clip = bounds4(s.content_mask.bounds),
        .radii = corners4(s.corner_radii),
        .params = .{ @floatFromInt(s.grayscale.value), s.opacity, 0, 0 },
    };
}

/// Normalized (origin.xy, size.zw) of a tile within a texture of the given size.
fn tileUv(tile: AtlasTile, texture_w: f32, texture_h: f32) [4]f32 {
    const b = tile.bounds;
    return .{
        @as(f32, @floatFromInt(b.origin.x)) / texture_w,
        @as(f32, @floatFromInt(b.origin.y)) / texture_h,
        @as(f32, @floatFromInt(b.size.width)) / texture_w,
        @as(f32, @floatFromInt(b.size.height)) / texture_h,
    };
}

/// Gamma correction ratios for `gamma`, from GPUI's get_gamma_correction_ratios (gamma 1.0..2.2).
fn gammaCorrectionRatios(gamma: f64) [4]f32 {
    const table = [13][4]f64{
        .{ 0.0000, 0.0000, 0.0000, 0.0000 },
        .{ 0.0166, -0.0807, 0.2227, -0.0751 },
        .{ 0.0350, -0.1760, 0.4325, -0.1370 },
        .{ 0.0543, -0.2821, 0.6302, -0.1876 },
        .{ 0.0739, -0.3963, 0.8167, -0.2287 },
        .{ 0.0933, -0.5161, 0.9926, -0.2616 },
        .{ 0.1121, -0.6395, 1.1588, -0.2877 },
        .{ 0.1300, -0.7649, 1.3159, -0.3080 },
        .{ 0.1469, -0.8911, 1.4644, -0.3234 },
        .{ 0.1627, -1.0170, 1.6051, -0.3347 },
        .{ 0.1773, -1.1420, 1.7385, -0.3426 },
        .{ 0.1908, -1.2652, 1.8650, -0.3476 },
        .{ 0.2031, -1.3864, 1.9851, -0.3501 },
    };
    const norm13: f64 = (65536.0 / (255.0 * 255.0)) * 4.0;
    const norm24: f64 = (256.0 / 255.0) * 4.0;
    const index: usize = @intFromFloat(@round(gamma * 10.0) - 10.0);
    const r = table[index];
    return .{
        @floatCast(r[0] / 4.0 * norm13),
        @floatCast(r[1] / 4.0 * norm24),
        @floatCast(r[2] / 4.0 * norm13),
        @floatCast(r[3] / 4.0 * norm24),
    };
}

// ---------------------------------------------------------------------------
// Atlas
// ---------------------------------------------------------------------------

/// A GPU atlas texture with shelf packing; its pixels are uploaded from a staging buffer.
const GpuTexture = struct {
    image: gpu.Image,
    view: gpu.View,
    width: u32,
    height: u32,
    ref_count: u32 = 0,
    shelves: std.ArrayList(Shelf) = .empty,
    free_slots: std.ArrayList(Bounds(DevicePixels)) = .empty,

    const Shelf = struct { y: i32, height: i32, cursor_x: i32 };

    /// Finds room for `size`: a released slot, then a shelf with enough height, then a new shelf.
    fn allocate(self: *GpuTexture, allocator: std.mem.Allocator, size: geometry.Size(DevicePixels)) !?Bounds(DevicePixels) {
        const texture_width: i32 = @intCast(self.width);
        const texture_height: i32 = @intCast(self.height);
        if (size.width > texture_width or size.height > texture_height) return null;

        for (self.free_slots.items, 0..) |slot, index| {
            if (slot.size.width >= size.width and slot.size.height >= size.height) {
                _ = self.free_slots.swapRemove(index);
                return .{ .origin = slot.origin, .size = size };
            }
        }
        for (self.shelves.items) |*shelf| {
            if (shelf.height >= size.height and shelf.cursor_x + size.width <= texture_width) {
                const origin: geometry.Point(DevicePixels) = .{ .x = shelf.cursor_x, .y = shelf.y };
                shelf.cursor_x += size.width;
                return .{ .origin = origin, .size = size };
            }
        }
        const next_y = if (self.shelves.items.len == 0) 0 else blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height;
        };
        if (next_y + size.height > texture_height) return null;
        try self.shelves.append(allocator, .{ .y = next_y, .height = size.height, .cursor_x = size.width });
        return .{ .origin = .{ .x = 0, .y = next_y }, .size = size };
    }

    fn deinit(self: *GpuTexture, allocator: std.mem.Allocator, device: *gpu.Device) void {
        device.destroy(self.view);
        device.destroy(self.image);
        self.shelves.deinit(allocator);
        self.free_slots.deinit(allocator);
    }
};

/// One pending tile upload: a rectangle of a texture and its bytes in the frame's staging data.
const Upload = struct {
    texture: AtlasTextureId,
    bounds: Bounds(DevicePixels),
    offset: usize,
    /// Distance between rows in the staging data, including padding.
    row_bytes: u32,
};

/// GPU-resident atlas implementing `PlatformAtlas`. Tiles are packed on shelves like `CpuAtlas`.
/// New pixels are queued and copied into their texture rectangles by `before_frame`, which
/// writes all pending bytes to one staging buffer per frame.
pub const GpuAtlas = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Device,
    tiles_by_key: std.AutoHashMapUnmanaged(AtlasKey, AtlasTile) = .empty,
    /// Textures indexed by `@intFromEnum(AtlasTextureKind)`; textures are kept alive once created.
    storage: [3]std.ArrayList(GpuTexture) = .{ .empty, .empty, .empty },
    max_texture_size: u32,
    next_tile_id: u32 = 1,
    pending: std.ArrayList(Upload) = .empty,
    pending_bytes: std.ArrayList(u8) = .empty,
    staging: gpu.Buffer = .invalid,
    staging_capacity: usize = 0,
    /// Default side length for newly created textures.
    pub const default_texture_size: u32 = 1024;

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Device) GpuAtlas {
        return .{ .allocator = allocator, .device = device, .max_texture_size = @min(device.limits().max_image_size_2d, 16384) };
    }

    pub fn deinit(self: *GpuAtlas) void {
        for (&self.storage) |*textures| {
            for (textures.items) |*texture| texture.deinit(self.allocator, self.device);
            textures.deinit(self.allocator);
        }
        self.tiles_by_key.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_bytes.deinit(self.allocator);
        if (self.staging != .invalid) self.device.destroy(self.staging);
        self.* = undefined;
    }

    /// Returns the cached tile for `key`, or builds, packs and queues its upload.
    pub fn get_or_insert_with(self: *GpuAtlas, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile {
        if (self.tiles_by_key.get(key)) |tile| return tile;
        const data = (try build.build()) orelse return null;
        if (data.size.width <= 0 or data.size.height <= 0) return null;
        const tile = try self.insert(key.texture_kind(), data.size, data.bytes);
        try self.tiles_by_key.put(self.allocator, key, tile);
        return tile;
    }

    /// Drops the tile cached under `key`; its space is reused by later tiles of the same texture.
    pub fn remove(self: *GpuAtlas, key: AtlasKey) void {
        const entry = self.tiles_by_key.fetchRemove(key) orelse return;
        const tile = entry.value;
        const textures = self.storage[@intFromEnum(tile.texture_id.kind)].items;
        if (tile.texture_id.index >= textures.len) return;
        const texture = &textures[tile.texture_id.index];
        texture.free_slots.append(self.allocator, tile.bounds) catch return;
        texture.ref_count -= 1;
    }

    /// Packs `bytes` (tightly packed rows) into a tile of `size` and queues the upload.
    pub fn insert(self: *GpuAtlas, kind: AtlasTextureKind, size: geometry.Size(DevicePixels), bytes: []const u8) !AtlasTile {
        if (size.width <= 0 or size.height <= 0) return error.EmptyTile;
        const bpp = kind.bytes_per_pixel();
        if (bytes.len != @as(usize, @intCast(size.width)) * @as(usize, @intCast(size.height)) * bpp) return error.InvalidTileData;

        const kind_index = @intFromEnum(kind);
        const textures = &self.storage[kind_index];
        var found: ?struct { index: u32, bounds: Bounds(DevicePixels) } = null;
        var index = textures.items.len;
        while (index > 0) {
            index -= 1;
            if (try textures.items[index].allocate(self.allocator, size)) |bounds| {
                found = .{ .index = @intCast(index), .bounds = bounds };
                break;
            }
        }
        if (found == null) {
            const texture_index = try self.push_texture(kind, size);
            const bounds = (try textures.items[texture_index].allocate(self.allocator, size)) orelse return error.TileTooLarge;
            found = .{ .index = texture_index, .bounds = bounds };
        }

        const placed = found.?;
        const texture_id: AtlasTextureId = .{ .index = placed.index, .kind = kind };
        textures.items[placed.index].ref_count += 1;

        // Queue the rows, each padded to 4 bytes so every upload offset is aligned.
        const row_bytes: usize = @as(usize, @intCast(size.width)) * bpp;
        const padded_row = std.mem.alignForward(usize, row_bytes, 4);
        const offset = std.mem.alignForward(usize, self.pending_bytes.items.len, 4);
        try self.pending_bytes.appendNTimes(self.allocator, 0, offset - self.pending_bytes.items.len);
        try self.pending_bytes.ensureUnusedCapacity(self.allocator, padded_row * @as(usize, @intCast(size.height)));
        for (0..@intCast(size.height)) |row| {
            self.pending_bytes.appendSliceAssumeCapacity(bytes[row * row_bytes ..][0..row_bytes]);
            self.pending_bytes.appendNTimesAssumeCapacity(0, padded_row - row_bytes);
        }
        try self.pending.append(self.allocator, .{ .texture = texture_id, .bounds = placed.bounds, .offset = offset, .row_bytes = @intCast(padded_row) });

        const tile_id: u32 = self.next_tile_id;
        self.next_tile_id += 1;
        return .{ .texture_id = texture_id, .tile_id = .{ .value = tile_id }, .padding = 0, .bounds = placed.bounds };
    }

    fn push_texture(self: *GpuAtlas, kind: AtlasTextureKind, min_size: geometry.Size(DevicePixels)) !u32 {
        const width: u32 = @min(@max(@as(u32, @intCast(min_size.width)), default_texture_size), self.max_texture_size);
        const height: u32 = @min(@max(@as(u32, @intCast(min_size.height)), default_texture_size), self.max_texture_size);
        const format: gpu.PixelFormat = if (kind == .monochrome) .r8 else .rgba8;
        const image = try self.device.createImage(.{
            .width = width,
            .height = height,
            .format = format,
            .usage = .{ .writes = .copy },
            .label = "zui atlas texture",
        });
        errdefer self.device.destroy(image);
        const texture_view = try self.device.createView(.{ .texture = .{ .image = image } });
        errdefer self.device.destroy(texture_view);

        const textures = &self.storage[@intFromEnum(kind)];
        const index: u32 = @intCast(textures.items.len);
        try textures.append(self.allocator, .{ .image = image, .view = texture_view, .width = width, .height = height });
        return index;
    }

    /// The texture of `id` as a sampled view, or null when the id is unknown.
    pub fn view(self: *const GpuAtlas, id: AtlasTextureId) ?gpu.View {
        const textures = self.storage[@intFromEnum(id.kind)].items;
        if (id.index >= textures.len) return null;
        return textures[id.index].view;
    }

    /// Pixel size of the texture of `id`, or null when the id is unknown.
    pub fn texture_size(self: *const GpuAtlas, id: AtlasTextureId) ?[2]u32 {
        const textures = self.storage[@intFromEnum(id.kind)].items;
        if (id.index >= textures.len) return null;
        return .{ textures[id.index].width, textures[id.index].height };
    }

    /// Writes the queued tile bytes to the staging buffer and copies each rectangle into its texture.
    /// Call once per frame before drawing; copies are recorded outside any pass.
    pub fn before_frame(self: *GpuAtlas) !void {
        if (self.pending.items.len == 0) return;
        const needed = self.pending_bytes.items.len;
        if (needed > self.staging_capacity or self.staging == .invalid) {
            const capacity = @max(needed, 2 * self.staging_capacity, 64 * 1024);
            const buffer = try self.device.createBuffer(.{
                .size = capacity,
                .usage = .{ .staging = true, .copy_src = true, .writes = .transient },
                .label = "zui atlas staging",
            });
            if (self.staging != .invalid) self.device.destroy(self.staging);
            self.staging = buffer;
            self.staging_capacity = capacity;
        }
        self.device.writeBuffer(self.staging, 0, self.pending_bytes.items);
        for (self.pending.items) |upload| {
            const texture = &self.storage[@intFromEnum(upload.texture.kind)].items[upload.texture.index];
            self.device.copyBufferToImage(.{
                .src = self.staging,
                .src_offset = upload.offset,
                .layout = .{ .bytes_per_row = upload.row_bytes },
                .dst = texture.image,
                .region = .{
                    .x = @intCast(upload.bounds.origin.x),
                    .y = @intCast(upload.bounds.origin.y),
                    .width = @intCast(upload.bounds.size.width),
                    .height = @intCast(upload.bounds.size.height),
                },
            });
        }
        self.pending.clearRetainingCapacity();
        self.pending_bytes.clearRetainingCapacity();
    }

    /// Type-erased `PlatformAtlas` view. The atlas must not move while it is in use.
    pub fn platform_atlas(self: *GpuAtlas) PlatformAtlas {
        return .{ .ptr = self, .vtable = &platform_atlas_vtable };
    }

    const platform_atlas_vtable: PlatformAtlas.VTable = .{
        .get_or_insert_with = struct {
            fn call(ptr: *anyopaque, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile {
                const self: *GpuAtlas = @ptrCast(@alignCast(ptr));
                return self.get_or_insert_with(key, build);
            }
        }.call,
        .remove = struct {
            fn call(ptr: *anyopaque, key: AtlasKey) void {
                const self: *GpuAtlas = @ptrCast(@alignCast(ptr));
                self.remove(key);
            }
        }.call,
    };
};

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

const Programs = struct {
    quads: gpu.Pipeline = .invalid,
    shadows: gpu.Pipeline = .invalid,
    underlines: gpu.Pipeline = .invalid,
    mono: gpu.Pipeline = .invalid,
    poly: gpu.Pipeline = .invalid,
    path_raster: gpu.Pipeline = .invalid,
    path_composite: gpu.Pipeline = .invalid,
};

/// Intermediate target for path coverage: multisampled when supported, resolved for sampling.
const PathTarget = struct {
    width: u32,
    height: u32,
    /// Only when multisampled.
    msaa_image: gpu.Image = .invalid,
    msaa_view: gpu.View = .invalid,
    image: gpu.Image,
    /// Color attachment of `image` (single-sampled) or the resolve attachment.
    attachment: gpu.View,
    sampled: gpu.View,
    sample_count: u32,

    fn deinit(self: *PathTarget, device: *gpu.Device) void {
        device.destroy(self.sampled);
        device.destroy(self.attachment);
        device.destroy(self.image);
        if (self.msaa_view != .invalid) device.destroy(self.msaa_view);
        if (self.msaa_image != .invalid) device.destroy(self.msaa_image);
    }
};

/// Draws scenes with zicr. Create one per device and color format; the device must outlive it.
pub const GpuRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Device,
    color_format: gpu.PixelFormat,
    options: Options,
    shader_descs: [7]gpu.Shader = @splat(.invalid),
    programs: Programs = .{},
    sampler: gpu.Sampler = .invalid,
    /// Per-frame instance bytes; one transient vertex buffer holds them all.
    instances: gpu.Buffer = .invalid,
    instance_capacity: usize = 0,
    frame_bytes: std.ArrayList(u8) = .empty,
    commands: std.ArrayList(Command) = .empty,
    path_target: ?PathTarget = null,
    path_sample_count: u32 = 1,
    stats: Stats = .{},
    gamma_ratios: [4]f32,

    const Range = struct { offset: usize, count: usize };
    const Command = union(enum) {
        quads: Range,
        shadows: Range,
        underlines: Range,
        sprites: struct { range: Range, texture: AtlasTextureId, poly: bool },
        paths: struct { raster: Range, composite: Range },
    };
    const initial_instance_bytes = 64 * 1024;

    /// Creates a renderer with the default options.
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Device, color_format: gpu.PixelFormat) !GpuRenderer {
        return initWithOptions(allocator, device, color_format, .{});
    }

    /// Creates the pipelines and buffers. Destroy with `deinit` before the device.
    pub fn initWithOptions(allocator: std.mem.Allocator, device: *gpu.Device, color_format: gpu.PixelFormat, options: Options) !GpuRenderer {
        const backend = device.backend();
        var self: GpuRenderer = .{
            .allocator = allocator,
            .device = device,
            .color_format = color_format,
            .options = options,
            .gamma_ratios = gammaCorrectionRatios(options.gamma),
        };
        errdefer self.deinit();

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_u = .clamp_to_edge,
            .wrap_v = .clamp_to_edge,
            .label = "zui sprite sampler",
        });

        // Multisampling for path coverage, when the format supports it.
        self.path_sample_count = 1;
        if (device.formatInfo(color_format).msaa) {
            for ([_]u32{ 4, 2 }) |count| {
                if (options.path_sample_count >= count) {
                    self.path_sample_count = count;
                    break;
                }
            }
        }

        const blend_premul: gpu.Blend = .{ .src_rgb = .one, .dst_rgb = .one_minus_src_alpha, .op_rgb = .add, .src_alpha = .one, .dst_alpha = .one_minus_src_alpha };
        const blend_straight: gpu.Blend = .{ .src_rgb = .src_alpha, .dst_rgb = .one_minus_src_alpha, .op_rgb = .add, .src_alpha = .one, .dst_alpha = .one_minus_src_alpha };
        const window_blend = if (options.premultiplied_alpha) blend_premul else blend_straight;

        self.shader_descs[0] = try self.createShader(shaders.quads.desc(backend));
        self.programs.quads = try self.createPipeline(self.shader_descs[0], .{
            .stride = @sizeOf(QuadInstance),
            .step = .per_instance,
            .attrs = &quad_attrs,
            .blend = window_blend,
            .label = "zui quads",
        });
        self.shader_descs[1] = try self.createShader(shaders.shadows.desc(backend));
        self.programs.shadows = try self.createPipeline(self.shader_descs[1], .{
            .stride = @sizeOf(ShadowInstance),
            .step = .per_instance,
            .attrs = &shadow_attrs,
            .blend = window_blend,
            .label = "zui shadows",
        });
        self.shader_descs[2] = try self.createShader(shaders.underlines.desc(backend));
        self.programs.underlines = try self.createPipeline(self.shader_descs[2], .{
            .stride = @sizeOf(UnderlineInstance),
            .step = .per_instance,
            .attrs = &underline_attrs,
            .blend = window_blend,
            .label = "zui underlines",
        });
        self.shader_descs[3] = try self.createShader(shaders.mono_sprites.desc(backend));
        self.programs.mono = try self.createPipeline(self.shader_descs[3], .{
            .stride = @sizeOf(MonoSpriteInstance),
            .step = .per_instance,
            .attrs = &mono_attrs,
            .blend = window_blend,
            .label = "zui monochrome sprites",
            .views = 1,
        });
        self.shader_descs[4] = try self.createShader(shaders.poly_sprites.desc(backend));
        self.programs.poly = try self.createPipeline(self.shader_descs[4], .{
            .stride = @sizeOf(PolySpriteInstance),
            .step = .per_instance,
            .attrs = &poly_attrs,
            .blend = window_blend,
            .label = "zui polychrome sprites",
            .views = 1,
        });
        self.shader_descs[5] = try self.createShader(shaders.path_raster.desc(backend));
        self.programs.path_raster = try self.createPipeline(self.shader_descs[5], .{
            .stride = @sizeOf(PathVertex),
            .step = .per_vertex,
            .attrs = &path_vertex_attrs,
            .blend = blend_premul,
            .label = "zui path rasterization",
            .sample_count = self.path_sample_count,
        });
        self.shader_descs[6] = try self.createShader(shaders.path_composite.desc(backend));
        self.programs.path_composite = try self.createPipeline(self.shader_descs[6], .{
            .stride = @sizeOf(PathSpriteInstance),
            .step = .per_instance,
            .attrs = &path_sprite_attrs,
            .blend = blend_premul,
            .label = "zui path composite",
            .views = 1,
        });
        return self;
    }

    /// Releases pipelines, shaders, sampler and buffers. The device must still exist.
    pub fn deinit(self: *GpuRenderer) void {
        const device = self.device;
        inline for (@typeInfo(Programs).@"struct".field_names) |name| {
            const pipeline = @field(self.programs, name);
            if (pipeline != .invalid) device.destroy(pipeline);
        }
        for (self.shader_descs) |shader| if (shader != .invalid) device.destroy(shader);
        if (self.sampler != .invalid) device.destroy(self.sampler);
        if (self.instances != .invalid) device.destroy(self.instances);
        if (self.path_target) |*target| target.deinit(device);
        self.frame_bytes.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    fn createShader(self: *GpuRenderer, desc: ?gpu.ShaderDesc) !gpu.Shader {
        return self.device.createShader(desc orelse return error.UnsupportedBackend);
    }

    const PipelineOptions = struct {
        stride: u32,
        step: gpu.VertexStep,
        attrs: []const gpu.VertexAttr,
        blend: gpu.Blend,
        label: [:0]const u8,
        /// Texture bindings: 1 for sprite and path composite programs.
        views: u32 = 0,
        sample_count: u32 = 1,
    };

    fn createPipeline(self: *GpuRenderer, shader: gpu.Shader, opts: PipelineOptions) !gpu.Pipeline {
        return self.device.createPipeline(.{
            .shader = shader,
            .vertex_buffers = &.{.{ .stride = opts.stride, .step = opts.step }},
            .vertex_attrs = opts.attrs,
            .primitive = if (opts.attrs.len == 0) .triangles else if (opts.step == .per_vertex) .triangles else .triangle_strip,
            .colors = &.{.{ .format = self.color_format, .blend = opts.blend }},
            .depth = .{ .format = .none },
            .sample_count = opts.sample_count,
            .label = opts.label,
        });
    }

    /// Draws `sc` into `target` after clearing it to `clear`. Atlas uploads are queued in `atlas`.
    /// The caller commits the device afterwards.
    pub fn draw(self: *GpuRenderer, sc: *const Scene, sprite_atlas: *GpuAtlas, target: Target, clear: Hsla) !void {
        const size = target.size();
        if (size.width == 0 or size.height == 0) return error.InvalidTargetSize;
        self.stats = .{};

        try self.pack(sc, sprite_atlas, size.width, size.height);
        if (self.frame_bytes.items.len + sprite_atlas.pending_bytes.items.len > self.options.max_frame_upload_bytes) return error.FrameTooLarge;
        try sprite_atlas.before_frame();
        if (self.frame_bytes.items.len > 0) try self.uploadFrame();
        if (self.commands.items.len > 0) {
            var needs_paths = false;
            for (self.commands.items) |command| needs_paths = needs_paths or command == .paths;
            if (needs_paths) try self.ensurePathTarget(size.width, size.height);
        }
        self.record(target, sprite_atlas, size, clear);
    }

    /// Packs the scene in batch order into `frame_bytes` and records one command per batch.
    fn pack(self: *GpuRenderer, sc: *const Scene, sprite_atlas: *GpuAtlas, width: u32, height: u32) !void {
        _ = width;
        _ = height;
        self.frame_bytes.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
        var batches = sc.batches();
        while (batches.next()) |batch| switch (batch) {
            .quads => |items| {
                const range = try self.appendItems(QuadInstance, items, packQuad);
                self.stats.quads += items.len;
                try self.commands.append(self.allocator, .{ .quads = range });
            },
            .shadows => |items| {
                const range = try self.appendItems(ShadowInstance, items, packShadow);
                self.stats.shadows += items.len;
                try self.commands.append(self.allocator, .{ .shadows = range });
            },
            .underlines => |items| {
                const range = try self.appendItems(UnderlineInstance, items, packUnderline);
                self.stats.underlines += items.len;
                try self.commands.append(self.allocator, .{ .underlines = range });
            },
            .monochrome_sprites => |b| {
                const texture_size = sprite_atlas.texture_size(b.texture_id) orelse continue;
                const range = try self.appendSprites(MonoSpriteInstance, b.sprites, texture_size, packMono);
                self.stats.sprites += b.sprites.len;
                try self.commands.append(self.allocator, .{ .sprites = .{ .range = range, .texture = b.texture_id, .poly = false } });
            },
            .polychrome_sprites => |b| {
                const texture_size = sprite_atlas.texture_size(b.texture_id) orelse continue;
                const range = try self.appendSprites(PolySpriteInstance, b.sprites, texture_size, packPoly);
                self.stats.sprites += b.sprites.len;
                try self.commands.append(self.allocator, .{ .sprites = .{ .range = range, .texture = b.texture_id, .poly = true } });
            },
            .paths => |paths| try self.packPaths(paths),
            // Subpixel sprites need dual-source blending, which is not ported yet; GPUI's wgpu
            // renderer also skips them without that feature. Surfaces are platform video frames.
            .subpixel_sprites, .surfaces => {},
        };
    }

    /// Appends a batch of instances; returns its byte range.
    fn appendItems(self: *GpuRenderer, comptime T: type, items: anytype, comptime pack_fn: anytype) !Range {
        const offset = self.frame_bytes.items.len;
        try self.frame_bytes.ensureUnusedCapacity(self.allocator, items.len * @sizeOf(T));
        for (items) |*item| {
            const instance: T = pack_fn(item);
            self.frame_bytes.appendSliceAssumeCapacity(std.mem.asBytes(&instance));
        }
        return .{ .offset = offset, .count = items.len };
    }

    fn appendSprites(self: *GpuRenderer, comptime T: type, sprites: anytype, texture_size: [2]u32, comptime pack_fn: anytype) !Range {
        const w: f32 = @floatFromInt(texture_size[0]);
        const h: f32 = @floatFromInt(texture_size[1]);
        const offset = self.frame_bytes.items.len;
        try self.frame_bytes.ensureUnusedCapacity(self.allocator, sprites.len * @sizeOf(T));
        for (sprites) |*sprite| {
            const instance: T = pack_fn(sprite, w, h);
            self.frame_bytes.appendSliceAssumeCapacity(std.mem.asBytes(&instance));
        }
        return .{ .offset = offset, .count = sprites.len };
    }

    /// Path batches: every vertex of every path is rasterized into one intermediate target, then
    /// one sprite (or one per path, when orders match) composites it. Mirrors draw_paths_*.
    fn packPaths(self: *GpuRenderer, paths: []const scene.Path(ScaledPixels)) !void {
        var vertex_count: usize = 0;
        for (paths) |path| vertex_count += path.vertices.items.len;
        if (vertex_count == 0) return;

        const raster_offset = self.frame_bytes.items.len;
        try self.frame_bytes.ensureUnusedCapacity(self.allocator, vertex_count * @sizeOf(PathVertex));
        for (paths) |*path| {
            const clipped = path.clipped_bounds();
            const bounds = bounds4(clipped);
            const bg = backgroundFields(path.color);
            for (path.vertices.items) |v| {
                const vertex: PathVertex = .{
                    .xy_st = .{ v.xy_position.x, v.xy_position.y, v.st_position.x, v.st_position.y },
                    .bounds = bounds,
                    .bg = bg.meta,
                    .solid = bg.solid,
                    .color0 = bg.color0,
                    .color1 = bg.color1,
                    .bg2 = bg.extra,
                };
                self.frame_bytes.appendSliceAssumeCapacity(std.mem.asBytes(&vertex));
            }
        }
        const raster: Range = .{ .offset = raster_offset, .count = vertex_count };

        // Sprites: one per path when the batch has a single order, else their union.
        const sprite_offset = self.frame_bytes.items.len;
        if (paths.len > 0 and paths[paths.len - 1].order == paths[0].order) {
            for (paths) |*path| {
                const sprite: PathSpriteInstance = .{ .bounds = bounds4(path.clipped_bounds()) };
                try self.frame_bytes.appendSlice(self.allocator, std.mem.asBytes(&sprite));
            }
        } else {
            var bounds = paths[0].clipped_bounds();
            for (paths[1..]) |*path| bounds = bounds.@"union"(path.clipped_bounds());
            const sprite: PathSpriteInstance = .{ .bounds = bounds4(bounds) };
            try self.frame_bytes.appendSlice(self.allocator, std.mem.asBytes(&sprite));
        }
        const composite: Range = .{ .offset = sprite_offset, .count = self.frame_bytes.items.len - sprite_offset };
        self.stats.paths += paths.len;
        try self.commands.append(self.allocator, .{ .paths = .{ .raster = raster, .composite = composite } });
    }

    /// Writes the frame's instance bytes to the transient vertex buffer, growing it when needed.
    fn uploadFrame(self: *GpuRenderer) !void {
        const needed = self.frame_bytes.items.len;
        if (self.instances == .invalid or needed > self.instance_capacity) {
            const capacity = @max(needed, 2 * self.instance_capacity, initial_instance_bytes);
            const buffer = try self.device.createBuffer(.{
                .size = capacity,
                .usage = .{ .vertex = true, .writes = .transient },
                .label = "zui instances",
            });
            if (self.instances != .invalid) self.device.destroy(self.instances);
            self.instances = buffer;
            self.instance_capacity = capacity;
        }
        self.device.writeBuffer(self.instances, 0, self.frame_bytes.items);
        self.stats.upload_bytes = needed;
    }

    fn ensurePathTarget(self: *GpuRenderer, width: u32, height: u32) !void {
        if (self.path_target) |target| {
            if (target.width == width and target.height == height) return;
            var old = target;
            old.deinit(self.device);
            self.path_target = null;
        }
        const samples = self.path_sample_count;
        var target: PathTarget = .{ .width = width, .height = height, .sample_count = samples, .image = .invalid, .attachment = .invalid, .sampled = .invalid };
        errdefer target.deinit(self.device);
        if (samples > 1) {
            target.msaa_image = try self.device.createImage(.{
                .width = width,
                .height = height,
                .format = self.color_format,
                .sample_count = samples,
                .usage = .{ .color_attachment = true },
                .label = "zui path msaa",
            });
            target.msaa_view = try self.device.createView(.{ .color_attachment = .{ .image = target.msaa_image } });
        }
        target.image = try self.device.createImage(.{
            .width = width,
            .height = height,
            .format = self.color_format,
            .usage = .{ .color_attachment = samples == 1, .resolve_attachment = samples > 1 },
            .label = "zui path coverage",
        });
        target.attachment = if (samples > 1)
            try self.device.createView(.{ .resolve_attachment = .{ .image = target.image } })
        else
            try self.device.createView(.{ .color_attachment = .{ .image = target.image } });
        target.sampled = try self.device.createView(.{ .texture = .{ .image = target.image } });
        self.path_target = target;
    }

    /// Records every command into one pass; path batches end it, render their coverage, and resume.
    fn record(self: *GpuRenderer, target: Target, sprite_atlas: *GpuAtlas, size: TargetSize, clear: Hsla) void {
        const rgba = clear.to_rgb();
        // Premultiplied targets clear to premultiplied colors, as the CPU canvas does (see cpu.premultiply).
        const scale: f32 = if (self.options.premultiplied_alpha) rgba.a else 1;
        var pass = self.beginFramePass(target, .{ .load = .{ .clear = .{ rgba.r * scale, rgba.g * scale, rgba.b * scale, rgba.a } }, .store = .store });
        pass.setViewport(.{ .width = @intCast(size.width), .height = @intCast(size.height) }, .top_left);
        const flip: f32 = if (self.device.features().origin_top_left) 0 else 1;
        const vs: VsParams = .{ .viewport = .{ @floatFromInt(size.width), @floatFromInt(size.height), 0, 0 } };
        const fs: FsParams = .{
            .gamma_ratios = self.gamma_ratios,
            .settings = .{ if (self.options.premultiplied_alpha) 1 else 0, self.options.grayscale_enhanced_contrast, 0, 0 },
        };

        for (self.commands.items) |command| switch (command) {
            .quads => |r| self.drawInstances(&pass, self.programs.quads, r, 4, &vs, &fs, &.{}),
            .shadows => |r| self.drawInstances(&pass, self.programs.shadows, r, 4, &vs, &fs, &.{}),
            .underlines => |r| self.drawInstances(&pass, self.programs.underlines, r, 4, &vs, &fs, &.{}),
            .sprites => |s| {
                const view = sprite_atlas.view(s.texture) orelse continue;
                const pipeline = if (s.poly) self.programs.poly else self.programs.mono;
                self.drawInstances(&pass, pipeline, s.range, 4, &vs, &fs, &.{view});
            },
            .paths => |p| {
                pass.end();
                self.rasterizePaths(p.raster, size, &vs);
                pass = self.beginFramePass(target, .{ .load = .load, .store = .store });
                pass.setViewport(.{ .width = @intCast(size.width), .height = @intCast(size.height) }, .top_left);
                self.compositePaths(&pass, p.composite, size, flip);
            },
        };
        pass.end();
    }

    fn beginFramePass(self: *GpuRenderer, target: Target, load: gpu.ColorAction) gpu.Pass {
        return switch (target) {
            .swapchain => |sc| blk: {
                var swapchain = sc;
                // The renderer's pipelines have no depth attachment.
                swapchain.depth_format = .none;
                break :blk self.device.beginPass(.{ .target = .{ .swapchain = swapchain }, .colors = &.{load} });
            },
            .attachment => |a| self.device.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{a.view} } }, .colors = &.{load} }),
        };
    }

    /// Draws `range` instances of a per-instance pipeline; `count` vertices per instance.
    fn drawInstances(self: *GpuRenderer, pass: *gpu.Pass, pipeline: gpu.Pipeline, range: Range, count: u32, vs: *const VsParams, fs: *const FsParams, views: []const gpu.View) void {
        if (range.count == 0) return;
        pass.setPipeline(pipeline);
        pass.setUniforms(0, vs);
        if (fs.settings[0] >= 0) pass.setUniforms(1, fs);
        pass.setBindings(.{
            .vertex_buffers = &.{.{ .buffer = self.instances, .offset = @intCast(range.offset) }},
            .views = views,
            .samplers = if (views.len > 0) &.{self.sampler} else &.{},
        });
        pass.draw(.{ .count = count, .instances = @intCast(range.count) });
        self.stats.draw_calls += 1;
    }

    fn rasterizePaths(self: *GpuRenderer, raster: Range, size: TargetSize, vs: *const VsParams) void {
        const target = self.path_target orelse return;
        const color_view = if (target.sample_count > 1) target.msaa_view else target.attachment;
        const resolves: []const gpu.View = if (target.sample_count > 1) &.{target.attachment} else &.{};
        var pass = self.device.beginPass(.{
            .target = .{ .attachments = .{ .colors = &.{color_view}, .resolves = resolves } },
            .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 0 } }, .store = .store }},
        });
        pass.setViewport(.{ .width = @intCast(size.width), .height = @intCast(size.height) }, .top_left);
        var raster_vs = vs.*;
        raster_vs.viewport[2] = 0;
        pass.setPipeline(self.programs.path_raster);
        pass.setUniforms(0, &raster_vs);
        pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = self.instances, .offset = @intCast(raster.offset) }} });
        pass.draw(.{ .count = @intCast(raster.count) });
        pass.end();
        self.stats.draw_calls += 1;
    }

    fn compositePaths(self: *GpuRenderer, pass: *gpu.Pass, composite: Range, size: TargetSize, flip: f32) void {
        const target = self.path_target orelse return;
        if (composite.count == 0) return;
        const vs: VsParams = .{ .viewport = .{ @floatFromInt(size.width), @floatFromInt(size.height), flip, 0 } };
        pass.setPipeline(self.programs.path_composite);
        pass.setUniforms(0, &vs);
        pass.setBindings(.{
            .vertex_buffers = &.{.{ .buffer = self.instances, .offset = @intCast(composite.offset) }},
            .views = &.{target.sampled},
            .samplers = &.{self.sampler},
        });
        pass.draw(.{ .count = 4, .instances = @intCast(composite.count) });
        self.stats.draw_calls += 1;
    }
};

test "instance layouts match the attribute counts in shaders.glsl" {
    const testing = std.testing;
    try testing.expectEqual(10, quad_attrs.len);
    try testing.expectEqual(7, shadow_attrs.len);
    try testing.expectEqual(4, underline_attrs.len);
    try testing.expectEqual(6, mono_attrs.len);
    try testing.expectEqual(5, poly_attrs.len);
    try testing.expectEqual(7, path_vertex_attrs.len);
    try testing.expectEqual(1, path_sprite_attrs.len);
    try testing.expectEqual(160, @sizeOf(QuadInstance));
    try testing.expectEqual(@as(usize, 16), @sizeOf(VsParams));
    try testing.expectEqual(@as(usize, 32), @sizeOf(FsParams));
}

test "gamma ratios match GPUI at 1.8" {
    const ratios = gammaCorrectionRatios(1.8);
    try std.testing.expect(ratios[0] > 0);
    try std.testing.expect(ratios[1] < 0);
}
