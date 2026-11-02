//! Texture atlas types ported from GPUI's platform.rs and gpui_wgpu/src/wgpu_atlas.rs,
//! with a CPU-side implementation that keeps pixels in memory for renderers and uploaders.
const std = @import("std");
const geometry = @import("geometry.zig");

const Bounds = geometry.Bounds;
const Size = geometry.Size;
const DevicePixels = geometry.DevicePixels;
const testing = std.testing;

/// The kind of content stored in an atlas texture; determines bytes per pixel.
pub const AtlasTextureKind = enum(u32) {
    monochrome = 0,
    polychrome = 1,
    subpixel = 2,

    /// Bytes stored per texel for this kind.
    pub fn bytes_per_pixel(self: AtlasTextureKind) u32 {
        return switch (self) {
            .monochrome => 1,
            .polychrome, .subpixel => 4,
        };
    }
};

/// Identifies one atlas texture.
pub const AtlasTextureId = struct {
    /// The index of this texture in the atlas.
    index: u32,
    /// The kind of content stored in this texture.
    kind: AtlasTextureKind,
};

/// The unique ID of a tile within its atlas.
pub const TileId = struct {
    value: u32,
};

/// A rectangle of a texture holding one sprite's pixels.
pub const AtlasTile = struct {
    /// The texture this tile belongs to.
    texture_id: AtlasTextureId,
    /// The unique ID of this tile within the atlas.
    tile_id: TileId,
    /// Padding around the tile content in pixels.
    padding: u32,
    /// The bounds of this tile within the texture.
    bounds: Bounds(DevicePixels),
};

/// Key identifying a cached tile. `id` stands in for the hash of render parameters
/// (glyph, SVG, image) until those parameter types are ported.
pub const AtlasKey = union(enum) {
    glyph: GlyphKey,
    svg: u64,
    image: u64,

    pub const GlyphKey = struct {
        id: u64,
        /// Emoji use polychrome, subpixel-rendered text uses subpixel, otherwise monochrome.
        texture_kind: AtlasTextureKind,
    };

    /// The texture kind this key's tile is stored in.
    pub fn texture_kind(self: AtlasKey) AtlasTextureKind {
        return switch (self) {
            .glyph => |glyph| glyph.texture_kind,
            .svg => .monochrome,
            .image => .polychrome,
        };
    }
};

/// Pixels produced by a tile builder. `bytes` is borrowed and copied into the atlas.
pub const TileData = struct {
    size: Size(DevicePixels),
    bytes: []const u8,
};

/// Lazily produces tile pixels when a key is not cached yet. Returning null means no tile.
pub const TileBuilder = struct {
    context: *anyopaque,
    build_fn: *const fn (context: *anyopaque) anyerror!?TileData,

    pub fn build(self: TileBuilder) anyerror!?TileData {
        return self.build_fn(self.context);
    }
};

/// Type-erased interface implemented by atlases, mirroring GPUI's `PlatformAtlas` trait.
pub const PlatformAtlas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_or_insert_with: *const fn (ptr: *anyopaque, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile,
        remove: *const fn (ptr: *anyopaque, key: AtlasKey) void,
    };

    /// Returns the cached tile for `key`, or builds and inserts it.
    pub fn get_or_insert_with(self: PlatformAtlas, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile {
        return self.vtable.get_or_insert_with(self.ptr, key, build);
    }

    pub fn remove(self: PlatformAtlas, key: AtlasKey) void {
        self.vtable.remove(self.ptr, key);
    }
};

/// A CPU texture with row-major pixels, `bytes_per_pixel` bytes per texel.
pub const CpuTexture = struct {
    id: AtlasTextureId,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    /// Pixel storage of `width * height * bytes_per_pixel` bytes.
    bytes: []u8,
    /// Set when pixels changed since the last upload; cleared with `CpuAtlas.clear_dirty`.
    dirty: bool = true,
    /// Number of live tiles in this texture; the texture is freed when it reaches zero.
    ref_count: u32 = 0,
    shelves: std.ArrayList(Shelf) = .empty,
    /// Released tile rectangles available for reuse.
    free_slots: std.ArrayList(Bounds(DevicePixels)) = .empty,

    const Shelf = struct {
        y: i32,
        height: i32,
        cursor_x: i32,
    };

    fn deinit(self: *CpuTexture, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.shelves.deinit(allocator);
        self.free_slots.deinit(allocator);
    }

    /// Finds room for `size`: reuses a released slot, then a shelf with enough height, then opens a new shelf.
    /// Released slots are reused whole, so a larger slot can waste some space until the texture is freed.
    fn allocate(self: *CpuTexture, allocator: std.mem.Allocator, size: Size(DevicePixels)) !?Bounds(DevicePixels) {
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

    fn write_tile(self: *CpuTexture, bounds: Bounds(DevicePixels), bytes: []const u8) error{InvalidTileData}!void {
        const bpp: usize = self.bytes_per_pixel;
        const tile_width: usize = @intCast(bounds.size.width);
        const tile_height: usize = @intCast(bounds.size.height);
        if (bytes.len != tile_width * tile_height * bpp) return error.InvalidTileData;

        const row_bytes = tile_width * bpp;
        const texture_row_bytes = @as(usize, self.width) * bpp;
        const x_offset: usize = @as(usize, @intCast(bounds.origin.x)) * bpp;
        for (0..tile_height) |row| {
            const source_start = row * row_bytes;
            const destination_start = (@as(usize, @intCast(bounds.origin.y)) + row) * texture_row_bytes + x_offset;
            @memcpy(self.bytes[destination_start .. destination_start + row_bytes], bytes[source_start .. source_start + row_bytes]);
        }
        self.dirty = true;
    }
};

/// CPU-side atlas implementing `PlatformAtlas` with shelf packing and per-texture reference counts.
pub const CpuAtlas = struct {
    allocator: std.mem.Allocator,
    tiles_by_key: std.AutoHashMapUnmanaged(AtlasKey, AtlasTile) = .empty,
    /// Textures indexed by `@intFromEnum(AtlasTextureKind)`; freed slots are null.
    storage: [3]std.ArrayList(?CpuTexture) = .{ .empty, .empty, .empty },
    free_indices: [3]std.ArrayList(u32) = .{ .empty, .empty, .empty },
    next_tile_id: u32 = 1,
    /// Default side length for newly created textures.
    pub const default_texture_size: i32 = 1024;
    /// Largest side length a texture may have.
    pub const max_texture_size: i32 = 16384;

    pub fn init(allocator: std.mem.Allocator) CpuAtlas {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CpuAtlas) void {
        for (&self.storage, &self.free_indices) |*textures, *free_indices| {
            for (textures.items) |*maybe_texture| {
                if (maybe_texture.*) |*slot| slot.deinit(self.allocator);
            }
            textures.deinit(self.allocator);
            free_indices.deinit(self.allocator);
        }
        self.tiles_by_key.deinit(self.allocator);
    }

    /// Returns the cached tile for `key`, or builds, uploads and caches it.
    pub fn get_or_insert_with(self: *CpuAtlas, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile {
        if (self.tiles_by_key.get(key)) |tile| return tile;

        const data = (try build.build()) orelse return null;
        if (data.size.width <= 0 or data.size.height <= 0) return null;

        const tile = try self.insert(key.texture_kind(), data.size, data.bytes);
        try self.tiles_by_key.put(self.allocator, key, tile);
        return tile;
    }

    /// Removes the tile cached under `key`, freeing its texture if it was the last tile.
    pub fn remove(self: *CpuAtlas, key: AtlasKey) void {
        const entry = self.tiles_by_key.fetchRemove(key) orelse return;
        self.release(entry.value);
    }

    /// Returns the texture for `id`, or null once it has been freed.
    pub fn texture(self: *const CpuAtlas, id: AtlasTextureId) ?*const CpuTexture {
        const textures = self.storage[@intFromEnum(id.kind)].items;
        if (id.index >= textures.len) return null;
        return if (textures[id.index]) |*slot| slot else null;
    }

    /// Clears the dirty flag of a texture after its pixels were uploaded.
    pub fn clear_dirty(self: *CpuAtlas, id: AtlasTextureId) void {
        const textures = self.storage[@intFromEnum(id.kind)].items;
        if (id.index >= textures.len) return;
        if (textures[id.index]) |*slot| slot.dirty = false;
    }

    /// Copies `bytes` into a newly allocated tile of `size` in a texture of `kind`.
    pub fn insert(self: *CpuAtlas, kind: AtlasTextureKind, size: Size(DevicePixels), bytes: []const u8) !AtlasTile {
        if (size.width <= 0 or size.height <= 0) return error.EmptyTile;

        const kind_index = @intFromEnum(kind);
        const textures = &self.storage[kind_index];

        var found: ?struct { index: u32, bounds: Bounds(DevicePixels) } = null;
        var index = textures.items.len;
        while (index > 0) {
            index -= 1;
            if (textures.items[index]) |*slot| {
                if (try slot.allocate(self.allocator, size)) |bounds| {
                    found = .{ .index = @intCast(index), .bounds = bounds };
                    break;
                }
            }
        }

        if (found == null) {
            const texture_index = try self.push_texture(kind, size);
            const texture_slot = &textures.items[texture_index].?;
            const bounds = (try texture_slot.allocate(self.allocator, size)) orelse return error.TileTooLarge;
            found = .{ .index = texture_index, .bounds = bounds };
        }

        const placed = found.?;
        const slot = &textures.items[placed.index].?;
        try slot.write_tile(placed.bounds, bytes);
        slot.ref_count += 1;

        const tile_id: TileId = .{ .value = self.next_tile_id };
        self.next_tile_id += 1;
        return .{
            .texture_id = .{ .index = placed.index, .kind = kind },
            .tile_id = tile_id,
            .padding = 0,
            .bounds = placed.bounds,
        };
    }

    /// Adds a texture able to hold `min_size` and returns its index.
    fn push_texture(self: *CpuAtlas, kind: AtlasTextureKind, min_size: Size(DevicePixels)) !u32 {
        const width: i32 = @min(@max(min_size.width, default_texture_size), max_texture_size);
        const height: i32 = @min(@max(min_size.height, default_texture_size), max_texture_size);
        const bpp = kind.bytes_per_pixel();
        const byte_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * bpp;

        const bytes = try self.allocator.alloc(u8, byte_count);
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);

        const kind_index = @intFromEnum(kind);
        const textures = &self.storage[kind_index];
        const free_indices = &self.free_indices[kind_index];

        const index: u32 = if (free_indices.pop()) |reused| reused else @intCast(textures.items.len);
        const texture_value: CpuTexture = .{
            .id = .{ .index = index, .kind = kind },
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes_per_pixel = bpp,
            .bytes = bytes,
        };
        if (index == textures.items.len) {
            try textures.append(self.allocator, texture_value);
        } else {
            textures.items[index] = texture_value;
        }
        return index;
    }

    /// Frees a tile's rectangle; when the texture has no tiles left, the texture itself is freed.
    fn release(self: *CpuAtlas, tile: AtlasTile) void {
        const kind_index = @intFromEnum(tile.texture_id.kind);
        const textures = self.storage[kind_index].items;
        if (tile.texture_id.index >= textures.len) return;
        const slot = &(textures[tile.texture_id.index] orelse return);

        slot.free_slots.append(self.allocator, tile.bounds) catch {};
        slot.ref_count -= 1;
        if (slot.ref_count == 0) {
            slot.deinit(self.allocator);
            textures[tile.texture_id.index] = null;
            self.free_indices[kind_index].append(self.allocator, tile.texture_id.index) catch {};
        }
    }

    /// Returns the type-erased `PlatformAtlas` view of this atlas.
    pub fn platform_atlas(self: *CpuAtlas) PlatformAtlas {
        return .{ .ptr = self, .vtable = &platform_atlas_vtable };
    }

    const platform_atlas_vtable: PlatformAtlas.VTable = .{
        .get_or_insert_with = struct {
            fn call(ptr: *anyopaque, key: AtlasKey, build: TileBuilder) anyerror!?AtlasTile {
                const atlas: *CpuAtlas = @ptrCast(@alignCast(ptr));
                return atlas.get_or_insert_with(key, build);
            }
        }.call,
        .remove = struct {
            fn call(ptr: *anyopaque, key: AtlasKey) void {
                const atlas: *CpuAtlas = @ptrCast(@alignCast(ptr));
                atlas.remove(key);
            }
        }.call,
    };
};

const SolidBuilder = struct {
    size: Size(DevicePixels),
    bytes: []const u8,

    fn build(context: *anyopaque) anyerror!?TileData {
        const self: *const SolidBuilder = @ptrCast(@alignCast(context));
        return .{ .size = self.size, .bytes = self.bytes };
    }

    fn tile_builder(self: *const SolidBuilder) TileBuilder {
        return .{ .context = @constCast(self), .build_fn = build };
    }
};

test "insert and fetch a monochrome tile" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const pixels = [_]u8{ 1, 2, 3, 4 };
    const builder: SolidBuilder = .{ .size = .{ .width = 2, .height = 2 }, .bytes = &pixels };
    const key: AtlasKey = .{ .glyph = .{ .id = 7, .texture_kind = .monochrome } };

    const tile = (try atlas.get_or_insert_with(key, builder.tile_builder())).?;
    try testing.expectEqual(AtlasTextureKind.monochrome, tile.texture_id.kind);
    try testing.expectEqual(@as(i32, 0), tile.bounds.origin.x);

    const texture = atlas.texture(tile.texture_id).?;
    try testing.expectEqual(@as(u32, 1), texture.bytes_per_pixel);
    try testing.expect(texture.dirty);
    try testing.expectEqualSlices(u8, pixels[0..2], texture.bytes[0..2]);
    try testing.expectEqualSlices(u8, pixels[2..4], texture.bytes[texture.width .. texture.width + 2]);

    atlas.clear_dirty(tile.texture_id);
    try testing.expect(!atlas.texture(tile.texture_id).?.dirty);
}

test "same key returns the cached tile" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const pixels = [_]u8{ 9, 9, 9, 9 };
    const builder: SolidBuilder = .{ .size = .{ .width = 2, .height = 2 }, .bytes = &pixels };
    const key: AtlasKey = .{ .svg = 42 };

    const first = (try atlas.get_or_insert_with(key, builder.tile_builder())).?;
    const second = (try atlas.get_or_insert_with(key, builder.tile_builder())).?;
    try testing.expectEqual(first.tile_id, second.tile_id);
}

test "polychrome tiles pack onto shelves" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const pixels: [64]u8 = @splat(0);
    const builder: SolidBuilder = .{ .size = .{ .width = 4, .height = 4 }, .bytes = &pixels };
    const first = (try atlas.get_or_insert_with(.{ .image = 1 }, builder.tile_builder())).?;
    const second = (try atlas.get_or_insert_with(.{ .image = 2 }, builder.tile_builder())).?;

    try testing.expectEqual(first.texture_id, second.texture_id);
    try testing.expectEqual(@as(i32, 4), second.bounds.origin.x);
    try testing.expectEqual(@as(i32, 0), second.bounds.origin.y);
}

test "removing the last tile frees its texture" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const pixels = [_]u8{0};
    const builder: SolidBuilder = .{ .size = .{ .width = 1, .height = 1 }, .bytes = &pixels };
    const key: AtlasKey = .{ .glyph = .{ .id = 3, .texture_kind = .monochrome } };
    const tile = (try atlas.get_or_insert_with(key, builder.tile_builder())).?;

    atlas.remove(key);
    try testing.expect(atlas.texture(tile.texture_id) == null);

    const reused = (try atlas.get_or_insert_with(.{ .svg = 5 }, builder.tile_builder())).?;
    try testing.expectEqual(tile.texture_id.index, reused.texture_id.index);
}

test "released tile space is reused" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const pixels: [16]u8 = @splat(0);
    const builder: SolidBuilder = .{ .size = .{ .width = 4, .height = 4 }, .bytes = &pixels };
    const keep = (try atlas.get_or_insert_with(.{ .svg = 1 }, builder.tile_builder())).?;
    const drop_key: AtlasKey = .{ .svg = 2 };
    const dropped = (try atlas.get_or_insert_with(drop_key, builder.tile_builder())).?;

    atlas.remove(drop_key);
    const replacement = (try atlas.get_or_insert_with(.{ .svg = 3 }, builder.tile_builder())).?;
    try testing.expectEqual(dropped.bounds, replacement.bounds);
    try testing.expectEqual(keep.texture_id, replacement.texture_id);
}

test "empty and mismatched tiles" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();

    const empty_builder: SolidBuilder = .{ .size = .{ .width = 0, .height = 0 }, .bytes = &.{} };
    try testing.expectEqual(@as(?AtlasTile, null), try atlas.get_or_insert_with(.{ .svg = 10 }, empty_builder.tile_builder()));

    const short: SolidBuilder = .{ .size = .{ .width = 2, .height = 2 }, .bytes = &[_]u8{1} };
    try testing.expectError(error.InvalidTileData, atlas.get_or_insert_with(.{ .svg = 11 }, short.tile_builder()));
}

test "platform atlas vtable" {
    var atlas = CpuAtlas.init(testing.allocator);
    defer atlas.deinit();
    const platform = atlas.platform_atlas();

    const pixels = [_]u8{5};
    const builder: SolidBuilder = .{ .size = .{ .width = 1, .height = 1 }, .bytes = &pixels };
    const key: AtlasKey = .{ .svg = 99 };
    const tile = (try platform.get_or_insert_with(key, builder.tile_builder())).?;
    try testing.expect(atlas.texture(tile.texture_id) != null);

    platform.remove(key);
    try testing.expect(atlas.texture(tile.texture_id) == null);
}
