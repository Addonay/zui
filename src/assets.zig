//! Port of GPUI `assets.rs` and `asset_cache.rs`: the `AssetSource` interface,
//! `Resource`, encoded `Image`s and `ImageFormat`, decoded `RenderImage`s, and
//! the per-app `AssetCache` that decodes every image source once.
//!
//! Paths and embedded assets load synchronously: the first frame that asks decodes them inline.
//! URLs load in the background and the windows redraw when they arrive, showing a copy saved on
//! disk meanwhile if there is one. GPUI does all of them in the background, and saves nothing.
//! Image pixels use GPUI's layout: BGRA, row-major, straight (non-premultiplied)
//! alpha, which is what the renderers blend.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const executor_mod = @import("executor.zig");
const http_client_mod = @import("http_client.zig");
const disk_cache = @import("image_disk_cache.zig");
const log = std.log.scoped(.zui_assets);
const geometry = @import("geometry.zig");
const wuffs = @import("wuffs.zig");
const svg_mod = @import("svg_renderer.zig");
const window_mod = @import("window.zig");
const app_mod = @import("app.zig");

const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;

/// Errors produced while loading an image source.
pub const ImageCacheError = error{
    /// The embedded name is not known to the app's `AssetSource`.
    AssetNotFound,
    /// This cache cannot fetch URLs, because it does not belong to an app.
    UnsupportedUri,
    /// A URL is still being fetched; the windows redraw when it arrives.
    Loading,
    /// A URL could not be fetched. The reason is in the log.
    FetchFailed,
    /// A file could not be read.
    ReadFailed,
    /// The format is recognized but has no decoder (TIFF, ICO).
    UnsupportedFormat,
    /// The bytes did not decode as the claimed format.
    DecodeFailed,
    /// The image is larger than the decoder accepts (see `wuffs.Limits`).
    ImageTooLarge,
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
    /// A URL, fetched in the background. `file://` is read directly.
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
    qoi,
    tga,

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
            .qoi => "image/qoi",
            .tga => "image/x-tga",
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
            .qoi => "qoi",
            .tga => "tga",
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
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif")) return .qoi;
        return null;
    }

    /// The format a file name claims, for the formats that have no magic number (TGA). Used only
    /// when `guess` finds nothing.
    pub fn from_extension(name: []const u8) ?ImageFormat {
        const ext = std.fs.path.extension(name);
        if (ext.len < 2) return null;
        if (std.ascii.eqlIgnoreCase(ext[1..], "tga")) return .tga;
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
pub const Frame = wuffs.Frame;

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

/// Decodes `bytes` as `format` into a new `RenderImage` (GPUI `Image::to_image_data`).
/// SVG documents are rasterized by `renderer`.
pub fn decode(allocator: std.mem.Allocator, renderer: *svg_mod.SvgRenderer, format: ImageFormat, bytes: []const u8) ImageCacheError!*RenderImage {
    if (format == .svg) return renderer.render_single_frame(allocator, bytes, 1.0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSvg,
    };
    const frames = try decode_raster(allocator, format, bytes);
    const image = RenderImage.new(allocator, frames) catch |err| {
        free_frames(allocator, frames);
        return err;
    };
    return image;
}

fn free_frames(allocator: std.mem.Allocator, frames: []Frame) void {
    for (frames) |f| allocator.free(f.pixels);
    allocator.free(frames);
}

/// The Wuffs codec for a raster format, or null for formats Wuffs does not decode.
fn codec_of(format: ImageFormat) ?wuffs.Codec {
    return switch (format) {
        .png => .png,
        .jpeg => .jpeg,
        .gif => .gif,
        .bmp => .bmp,
        .webp => .webp,
        .qoi => .qoi,
        .tga => .targa,
        .pnm => .netpbm,
        .svg, .tiff, .ico => null,
    };
}

/// Decodes every frame of a raster image. The caller owns the frames.
fn decode_raster(allocator: std.mem.Allocator, format: ImageFormat, bytes: []const u8) ImageCacheError![]Frame {
    const codec = codec_of(format) orelse return error.UnsupportedFormat;
    const frames = try wuffs.decode(allocator, codec, bytes);
    if (format == .jpeg) {
        // Wuffs does not apply EXIF orientation. JPEG has one frame.
        apply_jpeg_orientation(allocator, &frames[0], jpeg_orientation(bytes)) catch |err| {
            free_frames(allocator, frames);
            return err;
        };
    }
    return frames;
}

/// Turns `frame` upright for an EXIF orientation, in a new buffer.
fn apply_jpeg_orientation(allocator: std.mem.Allocator, frame: *Frame, orientation: u8) error{OutOfMemory}!void {
    if (orientation <= 1 or orientation > 8) return;
    const upright = try allocator.alloc(u8, frame.pixels.len);
    const size = apply_orientation(frame.pixels, upright, frame.width, frame.height, orientation);
    allocator.free(frame.pixels);
    frame.* = .{ .width = size[0], .height = size[1], .delay_ms = frame.delay_ms, .pixels = upright };
}

/// The EXIF orientation of a JPEG, 1 (upright) if it has none. Tolerates truncated or malformed
/// data, since it comes from untrusted files.
fn jpeg_orientation(bytes: []const u8) u8 {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return 1;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) return 1;
        const marker = bytes[i + 1];
        // Start of scan: the metadata is over.
        if (marker == 0xDA or marker == 0xD9) return 1;
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + len > bytes.len) return 1;
        const body = bytes[i + 4 .. i + 2 + len];
        if (marker == 0xE1 and std.mem.startsWith(u8, body, "Exif\x00\x00")) return tiff_orientation(body[6..]);
        i += 2 + @as(usize, len);
    }
    return 1;
}

fn tiff_orientation(tiff: []const u8) u8 {
    if (tiff.len < 8) return 1;
    const endian: std.lang.Endian = if (std.mem.eql(u8, tiff[0..2], "II"))
        .little
    else if (std.mem.eql(u8, tiff[0..2], "MM"))
        .big
    else
        return 1;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return 1;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    var entry = @as(usize, ifd) + 2;
    for (0..count) |_| {
        if (entry + 12 > tiff.len) return 1;
        if (std.mem.readInt(u16, tiff[entry..][0..2], endian) == 0x0112) {
            const value = std.mem.readInt(u16, tiff[entry + 8 ..][0..2], endian);
            return if (value >= 1 and value <= 8) @intCast(value) else 1;
        }
        entry += 12;
    }
    return 1;
}

/// Writes `src` to `dst` turned upright for an EXIF orientation, and returns the new size.
fn apply_orientation(src: []const u8, dst: []u8, w: u32, h: u32, orientation: u8) [2]u32 {
    const swaps = orientation >= 5;
    const out_w = if (swaps) h else w;
    const out_h = if (swaps) w else h;
    for (0..h) |y| for (0..w) |x| {
        const ox: usize, const oy: usize = switch (orientation) {
            2 => .{ w - 1 - x, y },
            3 => .{ w - 1 - x, h - 1 - y },
            4 => .{ x, h - 1 - y },
            5 => .{ y, x },
            6 => .{ h - 1 - y, x },
            7 => .{ h - 1 - y, w - 1 - x },
            8 => .{ y, w - 1 - x },
            else => .{ x, y },
        };
        @memcpy(dst[(oy * out_w + ox) * 4..][0..4], src[(y * w + x) * 4..][0..4]);
    };
    return .{ out_w, out_h };
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
    /// Set by the app; without it URLs fail with `UnsupportedUri`.
    fetch_config: ?FetchConfig = null,
    remote: ?*RemoteImages = null,
    /// Images a newer download replaced. A frame may still refer to them, so they stay until the
    /// end. Only a URL whose content changed adds one, at most once per launch.
    replaced: std.ArrayList(*RenderImage) = .empty,

    pub fn init(allocator: std.mem.Allocator) AssetCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AssetCache) void {
        // First: it cancels downloads, which could otherwise outlive what they write to.
        if (self.remote) |remote| remote.destroy();
        var it = self.images.valueIterator();
        while (it.next()) |entry| {
            if (entry.*) |img| img.deinit() else |_| {}
        }
        self.images.deinit(self.allocator);
        for (self.replaced.items) |image| image.deinit();
        self.replaced.deinit(self.allocator);
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
        const result = if (is_remote(resource)) self.start_fetch(key, resource.uri) else self.decode_resource(source, resource);
        self.store(key, result) catch |err| {
            if (result) |img| img.deinit() else |_| {}
            return err;
        };
        return result;
    }

    fn start_fetch(self: *AssetCache, key: u64, uri: []const u8) ImageCacheError!*RenderImage {
        if (self.remote == null) {
            const config = self.fetch_config orelse return error.UnsupportedUri;
            self.remote = RemoteImages.create(self, config) catch return error.OutOfMemory;
        }
        try self.remote.?.fetch(key, uri);
        return error.Loading;
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
            .uri => |uri| {
                if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedUri;
                const path = uri["file://".len..];
                const bytes = try read_file(self.allocator, path);
                defer self.allocator.free(bytes);
                return decode_guessed(self, bytes, path);
            },
            .embedded => |name| {
                const bytes = source.load(name) orelse return error.AssetNotFound;
                return decode_guessed(self, bytes, name);
            },
            .path => |path| {
                const bytes = try read_file(self.allocator, path);
                defer self.allocator.free(bytes);
                return decode_guessed(self, bytes, path);
            },
        }
    }

    /// Format by magic bytes, then by the name's extension; anything unrecognized is treated as SVG
    /// (GPUI behavior).
    fn decode_guessed(self: *AssetCache, bytes: []const u8, name: []const u8) ImageCacheError!*RenderImage {
        const format = guess_format(bytes, name);
        return decode(self.allocator, try self.svg_renderer(), format, bytes);
    }
};

fn is_remote(resource: Resource) bool {
    return switch (resource) {
        .uri => |uri| !std.mem.startsWith(u8, uri, "file://"),
        else => false,
    };
}

/// What an app gives its cache so URLs can load.
pub const FetchConfig = struct {
    foreground: *executor_mod.ForegroundExecutor,
    /// Runs on the main thread when an image arrived or failed.
    on_settled_ctx: *anyopaque,
    on_settled: *const fn (*anyopaque) void,
    /// Null means the built-in client.
    http_client: ?http_client_mod.HttpClient = null,
    disk_cache: DiskCache = .default,
    disk_cache_max_bytes: u64 = disk_cache.MAX_TOTAL_BYTES,
};

/// Where downloaded images are saved (`Application.with_image_cache`).
pub const DiskCache = union(enum) {
    /// The platform's per-user cache directory. Tests get no disk cache by default.
    default,
    off,
    dir: []const u8,
};

/// Fetches URLs on their own threads and hands the results to the main thread (GPUI's
/// `ImageAssetLoader`). The threads belong to a `std.Io` of their own so that quitting can cancel a
/// download stuck on a slow server, which a thread of the background executor could not.
const RemoteImages = struct {
    cache: *AssetCache,
    config: FetchConfig,
    threaded: Io.Threaded,
    group: Io.Group = .init,
    client: http_client_mod.StdClient,
    mutex: Io.Mutex = .init,
    finished: std.ArrayList(Finished) = .empty,
    /// Where downloads are saved, if anywhere.
    disk_dir: ?[]const u8 = null,

    const Finished = struct {
        key: u64,
        uri: []u8,
        result: FetchedImage,
    };

    /// Raster images are decoded on the download's thread. SVG waits for the main thread,
    /// because the renderer is not thread-safe.
    const FetchedImage = union(enum) {
        decoded: *RenderImage,
        svg: []u8,
        failed: anyerror,
    };

    fn create(cache: *AssetCache, config: FetchConfig) error{OutOfMemory}!*RemoteImages {
        const self = try cache.allocator.create(RemoteImages);
        self.* = .{
            .cache = cache,
            .config = config,
            .threaded = Io.Threaded.init(cache.allocator, .{}),
            .client = undefined,
        };
        self.client = .shared();
        self.disk_dir = switch (config.disk_cache) {
            .off => null,
            .dir => |dir| try cache.allocator.dupe(u8, dir),
            .default => if (builtin.is_test) null else try disk_cache.default_dir(cache.allocator),
        };
        return self;
    }

    fn destroy(self: *RemoteImages) void {
        const io = self.threaded.io();
        self.group.cancel(io);
        for (self.finished.items) |*f| self.free_finished(f);
        self.finished.deinit(self.cache.allocator);
        self.threaded.deinit();
        if (self.disk_dir) |dir| self.cache.allocator.free(dir);
        self.cache.allocator.destroy(self);
    }

    fn free_finished(self: *RemoteImages, f: *Finished) void {
        const a = self.cache.allocator;
        a.free(f.uri);
        switch (f.result) {
            .decoded => |image| image.deinit(),
            .svg => |bytes| a.free(bytes),
            .failed => {},
        }
    }

    fn fetch(self: *RemoteImages, key: u64, uri: []const u8) ImageCacheError!void {
        // The caller's string may live only for this frame.
        const owned = self.cache.allocator.dupe(u8, uri) catch return error.OutOfMemory;
        errdefer self.cache.allocator.free(owned);
        self.group.concurrent(self.threaded.io(), run, .{ self, key, owned }) catch return error.OutOfMemory;
    }

    fn run(self: *RemoteImages, key: u64, uri: []u8) Io.Cancelable!void {
        const io = self.threaded.io();
        const a = self.cache.allocator;
        defer a.free(uri);

        // The saved copy first, so the window has something while the network takes its second.
        const saved = self.read_saved(key);
        defer if (saved) |bytes| a.free(bytes);
        if (saved) |bytes| show_saved: {
            const copy = a.dupe(u8, bytes) catch break :show_saved;
            const result = decode_fetched(a, copy);
            // A damaged entry just does not count: the download below replaces it.
            if (result != .failed) self.publish(key, uri, result);
        }

        const fetched = if (self.config.http_client) |client|
            client.get(a, io, uri)
        else
            self.client.get(a, io, uri);
        const body = fetched catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.publish(key, uri, .{ .failed = err });
            return;
        };
        if (saved) |bytes| if (std.mem.eql(u8, bytes, body)) {
            a.free(body);
            return;
        };
        if (self.disk_dir) |dir| disk_cache.write(io, dir, key, body, self.config.disk_cache_max_bytes);
        self.publish(key, uri, decode_fetched(a, body));
    }

    fn read_saved(self: *RemoteImages, key: u64) ?[]u8 {
        const dir = self.disk_dir orelse return null;
        const a = self.cache.allocator;
        const path = disk_cache.entry_path(a, dir, key) catch return null;
        defer a.free(path);
        return read_file(a, path) catch null;
    }

    /// Decodes `body`, which it takes ownership of.
    fn decode_fetched(a: std.mem.Allocator, body: []u8) FetchedImage {
        // Anything unrecognized is treated as SVG, as for local files.
        const format = ImageFormat.guess(body) orelse .svg;
        if (format == .svg) return .{ .svg = body };
        defer a.free(body);
        const frames = decode_raster(a, format, body) catch |err| return .{ .failed = err };
        return .{ .decoded = RenderImage.new(a, frames) catch |err| {
            free_frames(a, frames);
            return .{ .failed = err };
        } };
    }

    /// Hands a result to the main thread. Takes ownership of `result`.
    fn publish(self: *RemoteImages, key: u64, uri: []const u8, result: FetchedImage) void {
        const io = self.threaded.io();
        const a = self.cache.allocator;
        var entry: Finished = .{ .key = key, .uri = a.dupe(u8, uri) catch &.{}, .result = result };
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.finished.append(a, entry) catch {
                self.free_finished(&entry);
                return;
            };
        }
        // The task handle is not needed: the queue, not the arguments, holds the data.
        var task = self.config.foreground.spawn(settle, .{self});
        task.detach();
    }

    /// Main thread.
    fn settle(self: *RemoteImages) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        var finished = self.finished;
        self.finished = .empty;
        self.mutex.unlock(io);
        const a = self.cache.allocator;
        defer finished.deinit(a);
        for (finished.items) |*f| {
            defer a.free(f.uri);
            const result: ImageCacheError!*RenderImage = switch (f.result) {
                .decoded => |image| image,
                .svg => |bytes| svg: {
                    defer a.free(bytes);
                    const renderer = self.cache.svg_renderer() catch |err| break :svg err;
                    break :svg decode(a, renderer, .svg, bytes);
                },
                .failed => |err| failed: {
                    log.warn("could not load image {s}: {s}", .{ f.uri, @errorName(err) });
                    break :failed error.FetchFailed;
                },
            };
            if (result) |_| {} else |err| if (err != error.FetchFailed) {
                log.warn("could not decode image {s}: {s}", .{ f.uri, @errorName(err) });
            }
            const previous: ?*RenderImage = if (self.cache.images.get(f.key)) |entry| (entry catch null) else null;
            if (previous) |old| {
                // A saved copy on screen beats nothing, if the download behind it failed.
                _ = result catch continue;
                self.cache.replaced.append(a, old) catch {
                    if (result) |image| image.deinit() else |_| {}
                    continue;
                };
            }
            self.cache.store(f.key, result) catch {
                if (result) |image| image.deinit() else |_| {}
            };
        }
        self.config.on_settled(self.config.on_settled_ctx);
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
    /// Asked for each time the element is laid out (GPUI `ImageSource::Custom`). Built by `from`
    /// from a pointer to a type with `use_image(self, *Window, *App) ?ImageCacheError!*RenderImage`.
    custom: Custom,

    pub const Custom = struct {
        ptr: *anyopaque,
        load_fn: *const fn (ptr: *anyopaque, window: *window_mod.Window, cx: *app_mod.App) ?ImageCacheError!*RenderImage,
    };

    /// Converts strings (URL if it starts with `http://`, `https://` or `file://`,
    /// otherwise an embedded asset name), `Resource`, `*RenderImage`, `*Image`, and pointers to
    /// types with `use_image` (see `custom`).
    pub fn from(value: anytype) ImageSource {
        const T = @TypeOf(value);
        if (T == ImageSource) return value;
        if (T == Resource) return .{ .resource = value };
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return from_string(value);
                // The loader is asked through a mutable pointer, so a `*const` one is cast back; its
                // `use_image` must not write through it unless it was given a mutable pointer.
                if (comptime (p.size == .one and has_use_image(p.child))) return .{ .custom = .{ .ptr = @constCast(value), .load_fn = struct {
                    fn call(ptr: *anyopaque, window: *window_mod.Window, cx: *app_mod.App) ?ImageCacheError!*RenderImage {
                        const self: *p.child = @ptrCast(@alignCast(ptr));
                        return self.use_image(window, cx);
                    }
                }.call } };
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
    /// `custom` sources need a window, so `img` calls them itself: this is `unreachable` for them.
    pub fn use_data(self: ImageSource, cache: *AssetCache, source: AssetSource) ImageCacheError!*RenderImage {
        return switch (self) {
            .resource => |r| cache.load_resource(source, r),
            .render => |r| r,
            .image => |i| cache.load_image(i),
            .custom => unreachable,
        };
    }

    fn has_use_image(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "use_image"),
            else => false,
        };
    }
};

/// The atlas key of one frame of a decoded image: a hash of the image id and frame index.
pub fn image_atlas_key(id: u64, frame: usize) u64 {
    const parts = [_]u64{ id, frame };
    return std.hash.Wyhash.hash(0x696d6720, std.mem.sliceAsBytes(&parts));
}

/// Loads and decodes `resource` without touching any shared state, so it can run on a worker
/// thread (GPUI `ImageAssetLoader`). URLs go through `http` if set, otherwise through a new client
/// on `io`. Unlike `AssetCache`, nothing is saved to disk and nothing is kept.
pub fn load_detached(allocator: std.mem.Allocator, io: Io, source: AssetSource, http: ?http_client_mod.HttpClient, resource: Resource) ImageCacheError!*RenderImage {
    switch (resource) {
        .embedded => |name| {
            const bytes = source.load(name) orelse return error.AssetNotFound;
            return decode_detached(allocator, bytes, name);
        },
        .path => |path| {
            const bytes = try read_file(allocator, path);
            defer allocator.free(bytes);
            return decode_detached(allocator, bytes, path);
        },
        .uri => |uri| {
            if (std.mem.startsWith(u8, uri, "file://")) {
                const path = uri["file://".len..];
                const bytes = try read_file(allocator, path);
                defer allocator.free(bytes);
                return decode_detached(allocator, bytes, path);
            }
            const bytes = fetch_detached(allocator, io, http, uri) catch |err| {
                log.warn("could not fetch image {s}: {s}", .{ uri, @errorName(err) });
                return error.FetchFailed;
            };
            defer allocator.free(bytes);
            return decode_detached(allocator, bytes, uri);
        },
    }
}

fn fetch_detached(allocator: std.mem.Allocator, io: Io, http: ?http_client_mod.HttpClient, url: []const u8) anyerror![]u8 {
    if (http) |client| return client.get(allocator, io, url);
    var client = http_client_mod.StdClient.shared();
    return client.get(allocator, io, url);
}

/// The format of `bytes`: by magic number, else by the name's extension (TGA has no magic number),
/// else SVG.
fn guess_format(bytes: []const u8, name: []const u8) ImageFormat {
    return ImageFormat.guess(bytes) orelse ImageFormat.from_extension(name) orelse .svg;
}

/// Decodes `bytes` with a rasterizer of its own, so it is safe on any thread.
fn decode_detached(allocator: std.mem.Allocator, bytes: []const u8, name: []const u8) ImageCacheError!*RenderImage {
    const format = guess_format(bytes, name);
    var renderer = svg_mod.SvgRenderer.init() catch return error.OutOfMemory;
    defer renderer.deinit();
    return decode(allocator, &renderer, format, bytes);
}

/// Extensions the `img` element accepts (GPUI `Img::extensions`).
pub fn supported_extensions() []const []const u8 {
    return &.{ "avif", "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "tga", "dds", "bmp", "ico", "hdr", "exr", "pbm", "pam", "ppm", "pgm", "ff", "farbfeld", "qoi", "svg" };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "EXIF orientation: read from JPEG and TIFF headers, with bad data ignored" {
    const big = "\xFF\xD8\xFF\xE1\x00\x1EExif\x00\x00MM\x00\x2A\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x03\x00\x00\xFF\xDA";
    try testing.expectEqual(@as(u8, 3), jpeg_orientation(big));
    const little = "\xFF\xD8\xFF\xE1\x00\x1EExif\x00\x00II\x2A\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00\xFF\xDA";
    try testing.expectEqual(@as(u8, 6), jpeg_orientation(little));
    // Every prefix is safe, and none finds a value it should not.
    for (0..big.len) |n| {
        const found = jpeg_orientation(big[0..n]);
        try testing.expect(found == 1 or found == 3);
    }
    try testing.expectEqual(@as(u8, 1), jpeg_orientation("\xFF\xD8\xFF\xDA"));
    try testing.expectEqual(@as(u8, 1), jpeg_orientation("not a jpeg"));
}

test "EXIF orientation: all eight transforms" {
    // A B C
    // D E F, one byte standing for each pixel.
    const source = "ABCDEF";
    var src: [24]u8 = undefined;
    for (source, 0..) |c, i| src[i * 4] = c;
    const expected = [_]struct { o: u8, w: u32, text: []const u8 }{
        .{ .o = 1, .w = 3, .text = "ABCDEF" },
        .{ .o = 2, .w = 3, .text = "CBAFED" },
        .{ .o = 3, .w = 3, .text = "FEDCBA" },
        .{ .o = 4, .w = 3, .text = "DEFABC" },
        .{ .o = 5, .w = 2, .text = "ADBECF" },
        .{ .o = 6, .w = 2, .text = "DAEBFC" },
        .{ .o = 7, .w = 2, .text = "FCEBDA" },
        .{ .o = 8, .w = 2, .text = "CFBEAD" },
    };
    for (expected) |e| {
        var dst: [24]u8 = undefined;
        const out = apply_orientation(&src, &dst, 3, 2, e.o);
        try testing.expectEqual(e.w, out[0]);
        for (e.text, 0..) |c, i| try testing.expectEqual(c, dst[i * 4]);
    }
}

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
    try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, &renderer, .tiff, "II*\x00...."));
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
