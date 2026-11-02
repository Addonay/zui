//! Port of GPUI `assets.rs` and `asset_cache.rs`: the `AssetSource` interface,
//! `Resource`, encoded `Image`s and `ImageFormat`, decoded `RenderImage`s, and
//! the per-app `AssetCache` that decodes every image source once.
//!
//! Loading is synchronous: the first frame that asks for a source decodes it
//! inline (GPUI loads on a background task and re-renders when done).
//! Image pixels use GPUI's layout: BGRA, row-major, straight (non-premultiplied)
//! alpha, which is what the renderers blend.

const std = @import("std");
const geometry = @import("geometry.zig");
const svg_mod = @import("svg_renderer.zig");

const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;

// -- stb_image (third_party/stb/stb_image.h, compiled by third_party/images.c) --

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_load_gif_from_memory(buffer: [*]const u8, len: c_int, delays: *?[*]c_int, x: *c_int, y: *c_int, z: *c_int, comp: *c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(ptr: ?*anyopaque) void;

/// Errors produced while loading an image source.
pub const ImageCacheError = error{
    /// The embedded name is not known to the app's `AssetSource`.
    AssetNotFound,
    /// URLs are not fetched yet; only paths and embedded assets load.
    UnsupportedUri,
    /// A file could not be read.
    ReadFailed,
    /// The format is recognized but has no decoder (WebP, TIFF, ICO, PNM).
    UnsupportedFormat,
    /// The bytes did not decode as the claimed format.
    DecodeFailed,
    /// The SVG document could not be parsed or has no size.
    InvalidSvg,
    OutOfMemory,
};

/// A source of named assets (GPUI `AssetSource`), type-erased.
pub const AssetSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (ptr: *anyopaque, path: []const u8) ?[]const u8,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const []const u8,
    };

    /// Wraps a pointer to a type with `fn load(*T, []const u8) ?[]const u8`
    /// and, optionally, `fn list(*T, Allocator, []const u8) ![]const []const u8`.
    /// The pointee must outlive the app.
    pub fn from(pointer: anytype) AssetSource {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        const S = struct {
            fn load_fn(ptr: *anyopaque, path: []const u8) ?[]const u8 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.load(path);
            }
            fn list_fn(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const []const u8 {
                if (!@hasDecl(T, "list")) return &.{};
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.list(allocator, path);
            }
            const vtable: VTable = .{ .load = load_fn, .list = list_fn };
        };
        return .{ .ptr = @ptrCast(pointer), .vtable = &S.vtable };
    }

    /// Loads `path`, or null if the source has no such asset (GPUI `load`).
    pub fn load(self: AssetSource, path: []const u8) ?[]const u8 {
        return self.vtable.load(self.ptr, path);
    }

    /// Lists the assets under `path`; the slice is allocated with `allocator`.
    pub fn list(self: AssetSource, allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const []const u8 {
        return self.vtable.list(self.ptr, allocator, path);
    }

    const empty_state: u8 = 0;
    const empty_vtable: VTable = .{
        .load = struct {
            fn f(_: *anyopaque, _: []const u8) ?[]const u8 {
                return null;
            }
        }.f,
        .list = struct {
            fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8) error{OutOfMemory}![]const []const u8 {
                return &.{};
            }
        }.f,
    };
    /// An asset source with no assets (GPUI `impl AssetSource for ()`).
    pub const empty: AssetSource = .{ .ptr = @constCast(&empty_state), .vtable = &empty_vtable };
};

/// A location an image is read from.
pub const Resource = union(enum) {
    /// A file on disk.
    path: []const u8,
    /// A URL. Fetching is not implemented; loading fails with `UnsupportedUri`.
    uri: []const u8,
    /// A name resolved through the app's `AssetSource`.
    embedded: []const u8,
};

/// The encoded formats GPUI recognizes (GPUI `ImageFormat`).
pub const ImageFormat = enum {
    png,
    jpeg,
    webp,
    gif,
    svg,
    bmp,
    tiff,
    ico,
    pnm,

    pub fn mime_type(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
            .svg => "image/svg+xml",
            .bmp => "image/bmp",
            .tiff => "image/tiff",
            .ico => "image/ico",
            .pnm => "image/x-portable-anymap",
        };
    }

    /// File extension without the leading dot.
    pub fn extension(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
            .gif => "gif",
            .svg => "svg",
            .bmp => "bmp",
            .tiff => "tiff",
            .ico => "ico",
            .pnm => "pnm",
        };
    }

    /// Detects the format from magic bytes (GPUI `image::guess_format`).
    /// SVG has no magic number, so it is never returned here.
    pub fn guess(bytes: []const u8) ?ImageFormat {
        if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
        if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return .jpeg;
        if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
        if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
        if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "BM")) return .bmp;
        if (bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "II*\x00") or std.mem.eql(u8, bytes[0..4], "MM\x00*"))) return .tiff;
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x00\x00\x01\x00")) return .ico;
        if (bytes.len >= 2 and bytes[0] == 'P' and bytes[1] >= '1' and bytes[1] <= '7') return .pnm;
        return null;
    }
};

/// An encoded image held in memory (GPUI `Image`). `bytes` is borrowed.
pub const Image = struct {
    format: ImageFormat,
    bytes: []const u8,
    /// Hash of `bytes`, used as the cache key.
    id: u64,

    pub fn from_bytes(format: ImageFormat, bytes: []const u8) Image {
        return .{ .format = format, .bytes = bytes, .id = std.hash.Wyhash.hash(0, bytes) };
    }
};

/// One decoded frame: BGRA, row-major, straight alpha.
pub const Frame = struct {
    width: u32,
    height: u32,
    /// Delay before the next frame, in milliseconds.
    delay_ms: u32 = 100,
    pixels: []u8,
};

var next_render_image_id: std.atomic.Value(u64) = .init(1);

/// A decoded image ready for the sprite atlas (GPUI `RenderImage`).
/// Created by `new`, released by `deinit`.
pub const RenderImage = struct {
    /// Unique per image; the atlas key is derived from it.
    id: u64,
    /// Device pixels per logical pixel. SVGs rasterized at smooth scale use 2.
    scale_factor: f32 = 1,
    frames: []Frame,
    allocator: std.mem.Allocator,

    /// Takes ownership of `frames` and of each frame's pixels; they must come from `allocator`.
    pub fn new(allocator: std.mem.Allocator, frames: []Frame) error{OutOfMemory}!*RenderImage {
        const self = try allocator.create(RenderImage);
        self.* = .{
            .id = next_render_image_id.fetchAdd(1, .monotonic),
            .frames = frames,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *RenderImage) void {
        for (self.frames) |f| self.allocator.free(f.pixels);
        self.allocator.free(self.frames);
        self.allocator.destroy(self);
    }

    pub fn frame_count(self: *const RenderImage) usize {
        return self.frames.len;
    }

    /// Size of `frame_index` in device pixels (zero if out of range).
    pub fn size(self: *const RenderImage, frame_index: usize) Size(DevicePixels) {
        if (frame_index >= self.frames.len) return .{};
        const f = self.frames[frame_index];
        return .{ .width = @intCast(f.width), .height = @intCast(f.height) };
    }

    /// Size in logical pixels: device size divided by `scale_factor` (GPUI `render_size`).
    pub fn render_size(self: *const RenderImage, frame_index: usize) Size(Pixels) {
        const s = self.size(frame_index);
        return .{
            .width = @as(f32, @floatFromInt(s.width)) / self.scale_factor,
            .height = @as(f32, @floatFromInt(s.height)) / self.scale_factor,
        };
    }

    pub fn as_bytes(self: *const RenderImage, frame_index: usize) ?[]const u8 {
        if (frame_index >= self.frames.len) return null;
        return self.frames[frame_index].pixels;
    }

    /// Delay of `frame_index` in milliseconds (GPUI `delay`, default 100).
    pub fn delay(self: *const RenderImage, frame_index: usize) u32 {
        if (frame_index >= self.frames.len) return 100;
        return self.frames[frame_index].delay_ms;
    }
};

/// Converts RGBA pixels to BGRA in place and wraps them as a frame.
/// Takes ownership of `rgba`, which must come from the caller's allocator.
pub fn frame_from_rgba_owned(rgba: []u8, width: u32, height: u32, delay_ms: u32) Frame {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) std.mem.swap(u8, &rgba[i], &rgba[i + 2]);
    return .{ .width = width, .height = height, .delay_ms = delay_ms, .pixels = rgba };
}

/// Copies RGBA pixels into a new BGRA frame.
fn frame_from_rgba_copy(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, delay_ms: u32) ImageCacheError!Frame {
    const out = allocator.alloc(u8, rgba.len) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        out[i] = rgba[i + 2];
        out[i + 1] = rgba[i + 1];
        out[i + 2] = rgba[i];
        out[i + 3] = rgba[i + 3];
    }
    return .{ .width = width, .height = height, .delay_ms = delay_ms, .pixels = out };
}

/// Decodes `bytes` as `format` into a new `RenderImage` (GPUI `Image::to_image_data`).
/// SVG documents are rasterized by `renderer`.
pub fn decode(allocator: std.mem.Allocator, renderer: *svg_mod.SvgRenderer, format: ImageFormat, bytes: []const u8) ImageCacheError!*RenderImage {
    if (format == .svg) return renderer.render_single_frame(allocator, bytes, 1.0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSvg,
    };
    const frames: []Frame = switch (format) {
        .gif => try decode_gif(allocator, bytes),
        .png, .jpeg, .bmp => try decode_static(allocator, bytes),
        .webp, .tiff, .ico, .pnm => return error.UnsupportedFormat,
        .svg => unreachable,
    };
    return RenderImage.new(allocator, frames) catch error.OutOfMemory;
}

fn decode_static(allocator: std.mem.Allocator, bytes: []const u8) ImageCacheError![]Frame {
    const len = std.math.cast(c_int, bytes.len) orelse return error.DecodeFailed;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = stbi_load_from_memory(bytes.ptr, len, &w, &h, &comp, 4) orelse return error.DecodeFailed;
    defer stbi_image_free(px);
    if (w <= 0 or h <= 0) return error.DecodeFailed;
    const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const frames = allocator.alloc(Frame, 1) catch return error.OutOfMemory;
    errdefer allocator.free(frames);
    frames[0] = try frame_from_rgba_copy(allocator, px[0..n], @intCast(w), @intCast(h), 0);
    return frames;
}

fn decode_gif(allocator: std.mem.Allocator, bytes: []const u8) ImageCacheError![]Frame {
    const len = std.math.cast(c_int, bytes.len) orelse return error.DecodeFailed;
    var delays: ?[*]c_int = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var layers: c_int = 0;
    var comp: c_int = 0;
    const px = stbi_load_gif_from_memory(bytes.ptr, len, &delays, &w, &h, &layers, &comp, 4) orelse return error.DecodeFailed;
    defer stbi_image_free(px);
    defer if (delays) |d| std.c.free(d);
    if (w <= 0 or h <= 0 or layers <= 0) return error.DecodeFailed;

    const count: usize = @intCast(layers);
    const per_frame = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const frames = allocator.alloc(Frame, count) catch return error.OutOfMemory;
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |f| allocator.free(f.pixels);
        allocator.free(frames);
    }
    while (built < count) : (built += 1) {
        const delay_ms: u32 = if (delays) |d| @intCast(@max(d[built], 0)) else 100;
        frames[built] = try frame_from_rgba_copy(allocator, px[built * per_frame ..][0..per_frame], @intCast(w), @intCast(h), delay_ms);
    }
    return frames;
}

/// Reads a whole file into `allocator`-owned memory.
pub fn read_file(allocator: std.mem.Allocator, path: []const u8) ImageCacheError![]u8 {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.ReadFailed;
    defer _ = std.c.fclose(file);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, file);
        if (n == 0) break;
        out.appendSlice(allocator, chunk[0..n]) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Decoded images for the app, keyed by source; each source decodes once (GPUI `AssetCache`).
/// Failures are cached too, so a missing file is not re-read every frame.
pub const AssetCache = struct {
    allocator: std.mem.Allocator,
    images: std.AutoHashMapUnmanaged(u64, ImageCacheError!*RenderImage) = .empty,
    svg: ?svg_mod.SvgRenderer = null,

    pub fn init(allocator: std.mem.Allocator) AssetCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AssetCache) void {
        var it = self.images.valueIterator();
        while (it.next()) |entry| {
            if (entry.*) |img| img.deinit() else |_| {}
        }
        self.images.deinit(self.allocator);
        if (self.svg) |*r| r.deinit();
    }

    /// The app's SVG rasterizer, created on first use.
    pub fn svg_renderer(self: *AssetCache) ImageCacheError!*svg_mod.SvgRenderer {
        if (self.svg == null) self.svg = svg_mod.SvgRenderer.init() catch return error.OutOfMemory;
        return &self.svg.?;
    }

    /// Loads (or returns the cached) image for `resource`.
    pub fn load_resource(self: *AssetCache, source: AssetSource, resource: Resource) ImageCacheError!*RenderImage {
        const key = resource_key(resource);
        if (self.images.get(key)) |cached| return cached;
        const result = self.decode_resource(source, resource);
        self.store(key, result) catch |err| {
            if (result) |img| img.deinit() else |_| {}
            return err;
        };
        return result;
    }

    /// Decodes (or returns the cached) image for an encoded `Image`.
    pub fn load_image(self: *AssetCache, image: *const Image) ImageCacheError!*RenderImage {
        const key = std.hash.Wyhash.hash(0x696d6167, std.mem.asBytes(&image.id));
        if (self.images.get(key)) |cached| return cached;
        const result = decode(self.allocator, try self.svg_renderer(), image.format, image.bytes);
        self.store(key, result) catch |err| {
            if (result) |img| img.deinit() else |_| {}
            return err;
        };
        return result;
    }

    fn store(self: *AssetCache, key: u64, result: ImageCacheError!*RenderImage) ImageCacheError!void {
        self.images.put(self.allocator, key, result) catch return error.OutOfMemory;
    }

    fn decode_resource(self: *AssetCache, source: AssetSource, resource: Resource) ImageCacheError!*RenderImage {
        switch (resource) {
            .uri => return error.UnsupportedUri,
            .embedded => |name| {
                const bytes = source.load(name) orelse return error.AssetNotFound;
                return decode_guessed(self, bytes);
            },
            .path => |path| {
                const bytes = try read_file(self.allocator, path);
                defer self.allocator.free(bytes);
                return decode_guessed(self, bytes);
            },
        }
    }

    /// Format by magic bytes; anything unrecognized is treated as SVG (GPUI behavior).
    fn decode_guessed(self: *AssetCache, bytes: []const u8) ImageCacheError!*RenderImage {
        const format = ImageFormat.guess(bytes) orelse .svg;
        return decode(self.allocator, try self.svg_renderer(), format, bytes);
    }
};

fn resource_key(resource: Resource) u64 {
    return switch (resource) {
        .path => |p| std.hash.Wyhash.hash(0x70617468, p),
        .uri => |u| std.hash.Wyhash.hash(0x75726900, u),
        .embedded => |e| std.hash.Wyhash.hash(0x656d6264, e),
    };
}

/// Where an image's pixels come from (GPUI `ImageSource`).
pub const ImageSource = union(enum) {
    /// Loaded from a path, a URL, or the app's `AssetSource`.
    resource: Resource,
    /// Already decoded; the caller keeps it alive.
    render: *RenderImage,
    /// Encoded bytes held in memory; the caller keeps them alive.
    image: *const Image,

    /// Converts strings (URL if it starts with `http://`, `https://` or `file://`,
    /// otherwise an embedded asset name), `Resource`, `*RenderImage`, and `*Image`.
    pub fn from(value: anytype) ImageSource {
        const T = @TypeOf(value);
        if (T == ImageSource) return value;
        if (T == Resource) return .{ .resource = value };
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return from_string(value);
                if (p.size == .one) {
                    if (p.child == RenderImage) return .{ .render = value };
                    if (p.child == Image) return .{ .image = value };
                    if (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return from_string(value);
                }
            },
            else => {},
        }
        @compileError("cannot use " ++ @typeName(T) ++ " as an image source");
    }

    fn from_string(s: []const u8) ImageSource {
        const is_url = std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "file://");
        return .{ .resource = if (is_url) .{ .uri = s } else .{ .embedded = s } };
    }

    /// Returns the decoded image, loading it through `cache` if needed (GPUI `use_data`).
    pub fn use_data(self: ImageSource, cache: *AssetCache, source: AssetSource) ImageCacheError!*RenderImage {
        return switch (self) {
            .resource => |r| cache.load_resource(source, r),
            .render => |r| r,
            .image => |i| cache.load_image(i),
        };
    }
};

/// Extensions the `img` element accepts (GPUI `Img::extensions`).
pub fn supported_extensions() []const []const u8 {
    return &.{ "avif", "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "tga", "dds", "bmp", "ico", "hdr", "exr", "pbm", "pam", "ppm", "pgm", "ff", "farbfeld", "qoi", "svg" };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn append_be32(list: *std.ArrayList(u8), v: u32) !void {
    try list.appendSlice(testing.allocator, &.{ @intCast(v >> 24), @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) });
}

fn append_png_chunk(list: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    try append_be32(list, @intCast(data.len));
    const crc_input = try testing.allocator.alloc(u8, 4 + data.len);
    defer testing.allocator.free(crc_input);
    @memcpy(crc_input[0..4], kind);
    @memcpy(crc_input[4..], data);
    try list.appendSlice(testing.allocator, crc_input);
    try append_be32(list, std.hash.Crc32.hash(crc_input));
}

/// A 2x1 RGBA PNG: opaque red, then half-transparent green. Uses a stored (uncompressed) deflate block.
fn make_test_png() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "\x89PNG\r\n\x1a\n");

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(testing.allocator);
    try append_be32(&ihdr, 2);
    try append_be32(&ihdr, 1);
    try ihdr.appendSlice(testing.allocator, &.{ 8, 6, 0, 0, 0 }); // 8-bit RGBA, no compression/filter/interlace
    try append_png_chunk(&list, "IHDR", ihdr.items);

    // Raw scanlines: filter byte 0, then the pixels.
    const raw = [_]u8{ 0, 255, 0, 0, 255, 0, 255, 0, 128 };
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(testing.allocator);
    try zlib.appendSlice(testing.allocator, &.{ 0x78, 0x01, 0x01, raw.len, 0, ~@as(u8, raw.len), ~@as(u8, 0) });
    try zlib.appendSlice(testing.allocator, &raw);
    try append_be32(&zlib, std.hash.Adler32.hash(&raw));
    try append_png_chunk(&list, "IDAT", zlib.items);
    try append_png_chunk(&list, "IEND", "");
    return list.toOwnedSlice(testing.allocator);
}

test "guess_format recognizes magic numbers" {
    try testing.expectEqual(ImageFormat.png, ImageFormat.guess("\x89PNG\r\n\x1a\nxxxx").?);
    try testing.expectEqual(ImageFormat.jpeg, ImageFormat.guess("\xff\xd8\xff\xe0").?);
    try testing.expectEqual(ImageFormat.gif, ImageFormat.guess("GIF89a....").?);
    try testing.expectEqual(ImageFormat.bmp, ImageFormat.guess("BM\x00\x00").?);
    try testing.expectEqual(@as(?ImageFormat, null), ImageFormat.guess("<svg xmlns=\"http://www.w3.org/2000/svg\"/>"));
}

test "png decodes to BGRA with straight alpha" {
    const png = try make_test_png();
    defer testing.allocator.free(png);
    var renderer = try svg_mod.SvgRenderer.init();
    defer renderer.deinit();

    const img = try decode(testing.allocator, &renderer, .png, png);
    defer img.deinit();
    try testing.expectEqual(@as(usize, 1), img.frame_count());
    try testing.expectEqual(@as(DevicePixels, 2), img.size(0).width);
    try testing.expectEqual(@as(DevicePixels, 1), img.size(0).height);
    try testing.expectEqualSlices(u8, &.{
        0, 0, 255, 255, // red -> BGRA
        0, 255, 0, 128, // green, half alpha
    }, img.as_bytes(0).?);
}

fn append_le(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try list.appendSlice(testing.allocator, &buf);
}

test "bmp decodes 24-bit rows with padding" {
    // 2x1, 24-bit, bottom-up. Each row is 6 bytes of pixels padded to 8.
    var bmp: std.ArrayList(u8) = .empty;
    defer bmp.deinit(testing.allocator);
    try bmp.appendSlice(testing.allocator, "BM");
    try append_le(&bmp, u32, 54 + 8); // file size
    try append_le(&bmp, u32, 0); // reserved
    try append_le(&bmp, u32, 54); // pixel data offset
    try append_le(&bmp, u32, 40); // BITMAPINFOHEADER size
    try append_le(&bmp, i32, 2); // width
    try append_le(&bmp, i32, 1); // height (positive: bottom-up)
    try append_le(&bmp, u16, 1); // planes
    try append_le(&bmp, u16, 24); // bits per pixel
    try append_le(&bmp, u32, 0); // compression
    try append_le(&bmp, u32, 8); // image size
    try append_le(&bmp, i32, 2835); // x pixels per meter
    try append_le(&bmp, i32, 2835); // y pixels per meter
    try append_le(&bmp, u32, 0); // colors used
    try append_le(&bmp, u32, 0); // important colors
    try bmp.appendSlice(testing.allocator, &.{ 0, 0, 255, 0, 255, 0, 0, 0 }); // red, green (BGR), padding

    var renderer = try svg_mod.SvgRenderer.init();
    defer renderer.deinit();

    const img = try decode(testing.allocator, &renderer, .bmp, bmp.items);
    defer img.deinit();
    try testing.expectEqual(@as(DevicePixels, 2), img.size(0).width);
    try testing.expectEqual(@as(DevicePixels, 1), img.size(0).height);
    try testing.expectEqualSlices(u8, &.{
        0, 0,   255, 255,
        0, 255, 0,   255,
    }, img.as_bytes(0).?);
}

test "unsupported formats are reported, not decoded" {
    var renderer = try svg_mod.SvgRenderer.init();
    defer renderer.deinit();
    try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, &renderer, .webp, "RIFF....WEBP"));
}

test "empty asset source has no assets" {
    try testing.expect(AssetSource.empty.load("anything.png") == null);
    const names = try AssetSource.empty.list(testing.allocator, "");
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "asset cache decodes each embedded source once" {
    const png = try make_test_png();
    defer testing.allocator.free(png);

    const Assets = struct {
        bytes: []const u8,
        calls: usize = 0,
        pub fn load(self: *@This(), path: []const u8) ?[]const u8 {
            self.calls += 1;
            if (std.mem.eql(u8, path, "pixel.png")) return self.bytes;
            return null;
        }
    };
    var assets: Assets = .{ .bytes = png };
    const source = AssetSource.from(&assets);

    var cache = AssetCache.init(testing.allocator);
    defer cache.deinit();
    const a = try ImageSource.from("pixel.png").use_data(&cache, source);
    const b = try ImageSource.from("pixel.png").use_data(&cache, source);
    try testing.expect(a == b);
    try testing.expectEqual(@as(usize, 1), assets.calls);
    try testing.expectError(error.AssetNotFound, ImageSource.from("missing.png").use_data(&cache, source));
}

test "frame_from_rgba_owned swaps red and blue in place" {
    const buf = try testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 });
    const f = frame_from_rgba_owned(buf, 1, 1, 0);
    defer testing.allocator.free(f.pixels);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, f.pixels);
}
