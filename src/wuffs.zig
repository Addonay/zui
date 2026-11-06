//! Image decoding through Google's Wuffs (third_party/wuffs), for files from untrusted sources.
//!
//! Wuffs decodes BMP, GIF, JPEG, netpbm, PNG, QOI, TGA and WebP. Its decoders are checked by the Wuffs
//! compiler, so malformed input cannot write out of bounds. Frames come out as BGRA, row-major,
//! straight alpha: GPUI's layout, so nothing converts them.
//!
//! Animation is composited here, because Wuffs gives each frame's rectangle, disposal and blend mode
//! but leaves the canvas to the caller:
//! - GIF and APNG as Wuffs' example/gifplayer does it.
//! - WebP by walking the RIFF chunks (VP8X, ANIM, ANMF), since Wuffs decodes one frame of an animated
//!   WebP and reports no loops. Each ANMF payload is decoded as a standalone WebP and composited with
//!   its offset, blend and disposal flags on a transparent canvas, as GPUI's image crate does.
//!
//! Every size is checked before it is allocated. There is no global state, so decoding is safe on any
//! thread.

const std = @import("std");
const log = std.log.scoped(.zui_wuffs);

/// The codecs Wuffs decodes here. The order matches the C shim's `ZUI_CODEC_*` ids.
pub const Codec = enum(c_int) {
    bmp,
    gif,
    jpeg,
    netpbm,
    png,
    qoi,
    targa,
    webp,
};

/// One decoded frame: BGRA, row-major, straight alpha.
pub const Frame = struct {
    width: u32,
    height: u32,
    /// Delay before the next frame, in milliseconds.
    delay_ms: u32 = 100,
    pixels: []u8,
};

/// Limits on what a decode may allocate. The defaults are what ZUI accepts from any source.
pub const Limits = struct {
    /// Largest width or height, in pixels.
    max_side: u32 = 16384,
    /// Largest number of pixel bytes for one image: its canvas and every frame together.
    max_total_bytes: u64 = 1 << 30,
    /// Most frames one animation may have.
    max_frames: usize = 1 << 16,
    /// Largest work buffer a decoder may ask for. A 48-megapixel JPEG asks for 68 MB, or 205 MB if
    /// it is progressive, so this scales like the image itself.
    max_workbuf: u64 = 1 << 30,
};

pub const Error = error{
    OutOfMemory,
    /// The bytes are not a valid image of the codec.
    DecodeFailed,
    /// The image is over one of the `Limits`.
    ImageTooLarge,
};

/// Decodes every frame of `bytes` as `codec`, with the default limits. The caller owns the result:
/// each frame's pixels and the slice.
pub fn decode(allocator: std.mem.Allocator, codec: Codec, bytes: []const u8) Error![]Frame {
    return decode_with(allocator, codec, bytes, .{});
}

/// `decode` with explicit limits.
pub fn decode_with(allocator: std.mem.Allocator, codec: Codec, bytes: []const u8, limits: Limits) Error![]Frame {
    if (codec == .webp and is_animated_webp(bytes)) return decode_webp_animation(allocator, bytes, limits);
    return decode_sequence(allocator, codec, bytes, limits);
}

// -- the C shim (third_party/wuffs/zui_wuffs.c) --------------------------------------------------

const ok: c_int = 0;
const end: c_int = 1;

const disposal_none: u8 = 0;
const disposal_background: u8 = 1;
const disposal_previous: u8 = 2;

/// Layout must match `zui_frame_info` in the C shim.
const FrameInfo = extern struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    duration_ms: u32,
    /// ARGB, premultiplied.
    background: u32,
    disposal: u8,
    overwrite: u8,
    reserved: [2]u8,
};

const ffi = struct {
    extern fn zui_wuffs_session_size(codec: c_int) usize;
    extern fn zui_wuffs_session_init(mem: *anyopaque, codec: c_int, data: [*]const u8, len: usize) c_int;
    extern fn zui_wuffs_session_error(mem: *anyopaque) [*:0]const u8;
    extern fn zui_wuffs_image_config(mem: *anyopaque, width: *u32, height: *u32) c_int;
    extern fn zui_wuffs_frame_config(mem: *anyopaque, info: *FrameInfo) c_int;
    extern fn zui_wuffs_workbuf_len(mem: *anyopaque, out: *u64) c_int;
    extern fn zui_wuffs_decode_frame(mem: *anyopaque, pixels: [*]u8, pixels_len: usize, work: [*]u8, work_len: usize, overwrite: c_int) c_int;
};

/// One decoder, its input and its state, in memory the caller owns.
const Session = struct {
    allocator: std.mem.Allocator,
    codec: Codec,
    mem: []align(16) u8,

    /// `data` must outlive the session.
    fn open(allocator: std.mem.Allocator, codec: Codec, data: []const u8) Error!Session {
        const mem = allocator.alignedAlloc(u8, .@"16", ffi.zui_wuffs_session_size(@intFromEnum(codec))) catch return error.OutOfMemory;
        errdefer allocator.free(mem);
        if (ffi.zui_wuffs_session_init(mem.ptr, @intFromEnum(codec), data.ptr, data.len) != ok) {
            return report(codec, mem.ptr);
        }
        return .{ .allocator = allocator, .codec = codec, .mem = mem };
    }

    fn close(self: *Session) void {
        self.allocator.free(self.mem);
    }

    fn fail(self: *const Session) error{DecodeFailed} {
        return report(self.codec, self.mem.ptr);
    }

    fn image_size(self: *Session, limits: Limits) Error!Size {
        var w: u32 = 0;
        var h: u32 = 0;
        if (ffi.zui_wuffs_image_config(self.mem.ptr, &w, &h) != ok) return self.fail();
        if (w == 0 or h == 0) return error.DecodeFailed;
        if (w > limits.max_side or h > limits.max_side) return error.ImageTooLarge;
        return .{ .width = w, .height = h };
    }

    /// The next frame's header, or null after the last frame.
    fn next_frame(self: *Session) Error!?FrameInfo {
        var info: FrameInfo = undefined;
        return switch (ffi.zui_wuffs_frame_config(self.mem.ptr, &info)) {
            ok => info,
            end => null,
            else => self.fail(),
        };
    }

    fn workbuf(self: *Session, limits: Limits) Error![]u8 {
        var n: u64 = 0;
        if (ffi.zui_wuffs_workbuf_len(self.mem.ptr, &n) != ok) return self.fail();
        if (n > limits.max_workbuf) return error.ImageTooLarge;
        const len = std.math.cast(usize, n) orelse return error.ImageTooLarge;
        // Never zero: a zero-length buffer may have no address to pass.
        return self.allocator.alloc(u8, @max(len, 1)) catch error.OutOfMemory;
    }

    /// Decodes the current frame into `pixels`, which must hold the whole image. `overwrite` replaces
    /// the pixels; otherwise the frame is blended over them.
    fn decode_frame(self: *Session, pixels: []u8, work: []u8, overwrite: bool) Error!void {
        if (ffi.zui_wuffs_decode_frame(self.mem.ptr, pixels.ptr, pixels.len, work.ptr, work.len, @intFromBool(overwrite)) != ok) {
            return self.fail();
        }
    }
};

fn report(codec: Codec, mem: *anyopaque) error{DecodeFailed} {
    log.debug("wuffs {s}: {s}", .{ @tagName(codec), std.mem.span(ffi.zui_wuffs_session_error(mem)) });
    return error.DecodeFailed;
}

// -- sizes and budget ---------------------------------------------------------------------------

const Size = struct { width: u32, height: u32 };

const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn of_info(info: FrameInfo) Rect {
        return .{ .x0 = info.x0, .y0 = info.y0, .x1 = info.x1, .y1 = info.y1 };
    }

    fn full(size: Size) Rect {
        return .{ .x0 = 0, .y0 = 0, .x1 = size.width, .y1 = size.height };
    }
};

/// Counts the bytes an image may hold, and refuses past the limit before anything is allocated.
const Budget = struct {
    used: u64 = 0,
    limits: Limits,

    /// Reserves one image-sized buffer and returns its length in bytes.
    fn reserve(self: *Budget, width: u32, height: u32) Error!usize {
        if (width == 0 or height == 0) return error.DecodeFailed;
        if (width > self.limits.max_side or height > self.limits.max_side) return error.ImageTooLarge;
        const bytes = @as(u64, width) * @as(u64, height) * 4;
        if (bytes > self.limits.max_total_bytes - self.used) return error.ImageTooLarge;
        self.used += bytes;
        return std.math.cast(usize, bytes) orelse error.ImageTooLarge;
    }
};

fn check_rect(rect: Rect, size: Size) Error!void {
    if (rect.x0 > rect.x1 or rect.y0 > rect.y1) return error.DecodeFailed;
    if (rect.x1 > size.width or rect.y1 > size.height) return error.DecodeFailed;
}

/// Sets every pixel of `rect` to `background` (ARGB, premultiplied), as BGRA straight alpha.
fn fill_rect(pixels: []u8, width: u32, rect: Rect, background: u32) void {
    const px = straight_bgra(background);
    var y = rect.y0;
    while (y < rect.y1) : (y += 1) {
        var x = rect.x0;
        while (x < rect.x1) : (x += 1) {
            const i = (@as(usize, y) * width + x) * 4;
            pixels[i..][0..4].* = px;
        }
    }
}

fn straight_bgra(argb_premul: u32) [4]u8 {
    const a: u32 = argb_premul >> 24;
    const r: u32 = (argb_premul >> 16) & 0xff;
    const g: u32 = (argb_premul >> 8) & 0xff;
    const b: u32 = argb_premul & 0xff;
    if (a == 0) return .{ 0, 0, 0, 0 };
    if (a == 255) return .{ @intCast(b), @intCast(g), @intCast(r), 255 };
    const unpremul = struct {
        fn f(c: u32, alpha: u32) u8 {
            return @intCast(@min(255, (c * 255 + alpha / 2) / alpha));
        }
    }.f;
    return .{ unpremul(b, a), unpremul(g, a), unpremul(r, a), @intCast(a) };
}

/// Whether an animation that fails partway keeps the frames it has, as GPUI's does. A truncated
/// download of a GIF should play what arrived. Being over a limit stays an error.
fn keeps_frames(err: Error, frame_count: usize) bool {
    return err == error.DecodeFailed and frame_count > 0;
}

// -- sequences: GIF, APNG and everything Wuffs decodes as one or more frames ---------------------

/// Decodes frames the way Wuffs' example/gifplayer does: a canvas that starts transparent, each frame
/// blended or overwritten into its rectangle, a copy of the canvas kept per frame, and the frame's
/// disposal applied afterwards.
fn decode_sequence(allocator: std.mem.Allocator, codec: Codec, bytes: []const u8, limits: Limits) Error![]Frame {
    var session = try Session.open(allocator, codec, bytes);
    defer session.close();
    const size = try session.image_size(limits);
    var budget: Budget = .{ .limits = limits };

    const canvas = try allocator.alloc(u8, try budget.reserve(size.width, size.height));
    defer allocator.free(canvas);
    @memset(canvas, 0);

    var previous: ?[]u8 = null;
    defer if (previous) |p| allocator.free(p);

    const work = try session.workbuf(limits);
    defer allocator.free(work);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| allocator.free(f.pixels);
        frames.deinit(allocator);
    }

    while (true) {
        const info = (session.next_frame() catch |err| {
            if (keeps_frames(err, frames.items.len)) break;
            return err;
        }) orelse break;
        const rect = Rect.of_info(info);
        check_rect(rect, size) catch |err| {
            if (keeps_frames(err, frames.items.len)) break;
            return err;
        };
        if (frames.items.len >= limits.max_frames) return error.ImageTooLarge;
        if (frames.items.len == 0) fill_rect(canvas, size.width, Rect.full(size), info.background);

        if (info.disposal == disposal_previous) {
            if (previous == null) previous = try allocator.alloc(u8, try budget.reserve(size.width, size.height));
            @memcpy(previous.?, canvas);
        }

        session.decode_frame(canvas, work, info.overwrite != 0) catch |err| {
            if (keeps_frames(err, frames.items.len)) break;
            return err;
        };

        const copy_len = try budget.reserve(size.width, size.height);
        const pixels = try allocator.alloc(u8, copy_len);
        @memcpy(pixels, canvas);
        frames.append(allocator, .{ .width = size.width, .height = size.height, .delay_ms = info.duration_ms, .pixels = pixels }) catch {
            allocator.free(pixels);
            return error.OutOfMemory;
        };

        switch (info.disposal) {
            disposal_background => fill_rect(canvas, size.width, rect, info.background),
            disposal_previous => @memcpy(canvas, previous.?),
            else => {},
        }
    }
    if (frames.items.len == 0) return error.DecodeFailed;
    return frames.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// -- animated WebP -----------------------------------------------------------------------------

/// One RIFF chunk: its FourCC and its payload, without the padding byte.
const Chunk = struct {
    fourcc: [4]u8,
    payload: []const u8,
};

/// Walks the chunks of a RIFF body. Every size is checked against the bytes that remain.
const ChunkIterator = struct {
    rest: []const u8,

    fn next(self: *ChunkIterator) error{DecodeFailed}!?Chunk {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 8) return error.DecodeFailed;
        const fourcc = self.rest[0..4].*;
        const size: usize = std.mem.readInt(u32, self.rest[4..8], .little);
        if (size > self.rest.len - 8) return error.DecodeFailed;
        const payload = self.rest[8..][0..size];
        // The last chunk may lack its padding byte.
        const skip = @min(8 + size + (size & 1), self.rest.len);
        self.rest = self.rest[skip..];
        return .{ .fourcc = fourcc, .payload = payload };
    }
};

/// The chunks of a `RIFF <size> WEBP` file, or null if the header is not one. The RIFF size bounds
/// the chunks, and a file shorter than it claims is read to its end.
fn webp_body(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP")) return null;
    // In 64 bits: on a 32-bit target, a size near 4 GiB from the file would overflow `usize`.
    const riff_end = @as(u64, std.mem.readInt(u32, bytes[4..8], .little)) + 8;
    const end_at: usize = @intCast(@min(bytes.len, riff_end));
    if (end_at < 12) return null;
    return bytes[12..end_at];
}

/// True if the file is a WebP whose VP8X header sets the animation flag.
fn is_animated_webp(bytes: []const u8) bool {
    const body = webp_body(bytes) orelse return false;
    var it: ChunkIterator = .{ .rest = body };
    const first = (it.next() catch return false) orelse return false;
    return std.mem.eql(u8, &first.fourcc, "VP8X") and first.payload.len >= 1 and (first.payload[0] & 0x02) != 0;
}

fn read_u24(bytes: *const [3]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}

/// One ANMF chunk: where its frame goes, how long it shows, and how it is blended and disposed.
const AnimFrame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    duration_ms: u32,
    blend: bool,
    dispose: bool,
    /// The frame's own chunks: ALPH (optional), then VP8 or VP8L.
    data: []const u8,

    fn parse(payload: []const u8) error{DecodeFailed}!AnimFrame {
        if (payload.len < 16) return error.DecodeFailed;
        const flags = payload[15];
        return .{
            .x = read_u24(payload[0..3]) * 2,
            .y = read_u24(payload[3..6]) * 2,
            .width = read_u24(payload[6..9]) + 1,
            .height = read_u24(payload[9..12]) + 1,
            .duration_ms = read_u24(payload[12..15]),
            // Bit 1 set means "do not blend"; bit 0 set means "dispose to background".
            .blend = (flags & 0x02) == 0,
            .dispose = (flags & 0x01) != 0,
            .data = payload[16..],
        };
    }
};

fn decode_webp_animation(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error![]Frame {
    const body = webp_body(bytes) orelse return error.DecodeFailed;
    var it: ChunkIterator = .{ .rest = body };
    var budget: Budget = .{ .limits = limits };

    var canvas: ?[]u8 = null;
    var canvas_size: Size = undefined;
    defer if (canvas) |c| allocator.free(c);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| allocator.free(f.pixels);
        frames.deinit(allocator);
    }

    var pending_dispose: ?Rect = null;
    while (true) {
        const chunk = (it.next() catch |err| {
            if (keeps_frames(err, frames.items.len)) break;
            return err;
        }) orelse break;
        if (std.mem.eql(u8, &chunk.fourcc, "VP8X")) {
            if (canvas != null) return error.DecodeFailed;
            if (chunk.payload.len < 10) return error.DecodeFailed;
            canvas_size = .{
                .width = read_u24(chunk.payload[4..7]) + 1,
                .height = read_u24(chunk.payload[7..10]) + 1,
            };
            canvas = try allocator.alloc(u8, try budget.reserve(canvas_size.width, canvas_size.height));
            @memset(canvas.?, 0);
        } else if (std.mem.eql(u8, &chunk.fourcc, "ANMF")) {
            const pixels_canvas = canvas orelse return error.DecodeFailed;
            if (frames.items.len >= limits.max_frames) return error.ImageTooLarge;
            // The previous frame's disposal applies before this one is drawn.
            if (pending_dispose) |rect| {
                clear_rect(pixels_canvas, canvas_size.width, rect);
                pending_dispose = null;
            }

            const frame = AnimFrame.parse(chunk.payload) catch |err| {
                if (keeps_frames(err, frames.items.len)) break;
                return err;
            };
            const rect: Rect = .{ .x0 = frame.x, .y0 = frame.y, .x1 = frame.x + frame.width, .y1 = frame.y + frame.height };
            check_rect(rect, canvas_size) catch |err| {
                if (keeps_frames(err, frames.items.len)) break;
                return err;
            };

            const source = decode_anim_frame(allocator, frame, limits) catch |err| {
                if (keeps_frames(err, frames.items.len)) break;
                return err;
            };
            defer allocator.free(source);
            composite(pixels_canvas, canvas_size.width, rect, source, frame.blend);

            const copy_len = try budget.reserve(canvas_size.width, canvas_size.height);
            const pixels = try allocator.alloc(u8, copy_len);
            @memcpy(pixels, pixels_canvas);
            frames.append(allocator, .{ .width = canvas_size.width, .height = canvas_size.height, .delay_ms = frame.duration_ms, .pixels = pixels }) catch {
                allocator.free(pixels);
                return error.OutOfMemory;
            };

            if (frame.dispose) pending_dispose = rect;
        }
        // ANIM (the background colour and loop count, which viewers may ignore), ICCP, EXIF, XMP and
        // unknown chunks are skipped.
    }
    if (frames.items.len == 0) return error.DecodeFailed;
    return frames.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Decodes one ANMF frame, wrapped as a standalone WebP, into BGRA straight alpha.
fn decode_anim_frame(allocator: std.mem.Allocator, frame: AnimFrame, limits: Limits) Error![]u8 {
    const wrapped = try wrap_webp(allocator, frame);
    defer allocator.free(wrapped);
    var session = try Session.open(allocator, .webp, wrapped);
    defer session.close();
    const size = try session.image_size(limits);
    if (size.width != frame.width or size.height != frame.height) return error.DecodeFailed;
    var budget: Budget = .{ .limits = limits };
    const pixels = try allocator.alloc(u8, try budget.reserve(size.width, size.height));
    errdefer allocator.free(pixels);
    const work = try session.workbuf(limits);
    defer allocator.free(work);
    try session.decode_frame(pixels, work, true);
    return pixels;
}

/// A standalone WebP file holding one frame's chunks. An ALPH chunk needs a VP8X header that sets the
/// alpha flag, so one is added when the frame has it.
fn wrap_webp(allocator: std.mem.Allocator, frame: AnimFrame) Error![]u8 {
    const has_alpha = has_chunk(frame.data, "ALPH");
    const header_len: usize = if (has_alpha) 18 else 0;
    const riff_size = 4 + header_len + frame.data.len;
    if (riff_size > std.math.maxInt(u32)) return error.ImageTooLarge;
    const out = try allocator.alloc(u8, 12 + header_len + frame.data.len);
    errdefer allocator.free(out);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(riff_size), .little);
    @memcpy(out[8..12], "WEBP");
    if (has_alpha) {
        @memcpy(out[12..16], "VP8X");
        std.mem.writeInt(u32, out[16..20], 10, .little);
        out[20] = 0x10; // alpha
        @memset(out[21..24], 0);
        const w: u32 = frame.width - 1;
        const h: u32 = frame.height - 1;
        out[24] = @truncate(w);
        out[25] = @truncate(w >> 8);
        out[26] = @truncate(w >> 16);
        out[27] = @truncate(h);
        out[28] = @truncate(h >> 8);
        out[29] = @truncate(h >> 16);
    }
    @memcpy(out[12 + header_len ..], frame.data);
    return out;
}

fn has_chunk(data: []const u8, fourcc: *const [4]u8) bool {
    var it: ChunkIterator = .{ .rest = data };
    while (it.next() catch return false) |chunk| {
        if (std.mem.eql(u8, &chunk.fourcc, fourcc)) return true;
    }
    return false;
}

fn clear_rect(pixels: []u8, width: u32, rect: Rect) void {
    var y = rect.y0;
    while (y < rect.y1) : (y += 1) {
        const row = (@as(usize, y) * width + rect.x0) * 4;
        const n = (rect.x1 - rect.x0) * 4;
        @memset(pixels[row..][0..n], 0);
    }
}

/// Draws `source` (a frame of the rectangle's size, straight alpha) onto `canvas` at `rect`. Blended
/// frames use the source-over operator on straight alpha; other frames replace the rectangle.
fn composite(canvas: []u8, width: u32, rect: Rect, source: []const u8, blend: bool) void {
    const src_w = rect.x1 - rect.x0;
    var y = rect.y0;
    while (y < rect.y1) : (y += 1) {
        var x = rect.x0;
        while (x < rect.x1) : (x += 1) {
            const s_i = (@as(usize, y - rect.y0) * src_w + (x - rect.x0)) * 4;
            const d_i = (@as(usize, y) * width + x) * 4;
            const s = source[s_i..][0..4];
            const d = canvas[d_i..][0..4];
            if (!blend or s[3] == 255) {
                d.* = s.*;
                continue;
            }
            if (s[3] == 0) continue;
            blend_over(d, s);
        }
    }
}

/// Source-over on straight alpha: `d` becomes `s` over `d`.
fn blend_over(d: *[4]u8, s: *const [4]u8) void {
    const sa: u32 = s[3];
    const da: u32 = d[3];
    // The part of the destination that shows through the source.
    const da_visible = da * (255 - sa) / 255;
    const out_a = sa + da_visible;
    if (out_a == 0) {
        d.* = .{ 0, 0, 0, 0 };
        return;
    }
    for (0..3) |c| {
        const num = @as(u32, s[c]) * sa + @as(u32, d[c]) * da_visible;
        d[c] = @intCast((num + out_a / 2) / out_a);
    }
    d[3] = @intCast(out_a);
}

// -- tests ---------------------------------------------------------------------------------------

const testing = std.testing;

test "chunk iterator reads sizes, padding and rejects overruns" {
    // "abcd" with 3 bytes (padded), then "efgh" with 0 bytes.
    const data = "abcd\x03\x00\x00\x00xyz\x00efgh\x00\x00\x00\x00";
    var it: ChunkIterator = .{ .rest = data };
    const a = (try it.next()).?;
    try testing.expectEqualStrings("abcd", &a.fourcc);
    try testing.expectEqualStrings("xyz", a.payload);
    const b = (try it.next()).?;
    try testing.expectEqualStrings("efgh", &b.fourcc);
    try testing.expectEqual(@as(usize, 0), b.payload.len);
    try testing.expect((try it.next()) == null);

    var bad: ChunkIterator = .{ .rest = "abcd\xff\x00\x00\x00xyz" };
    try testing.expectError(error.DecodeFailed, bad.next());
    var short: ChunkIterator = .{ .rest = "abc" };
    try testing.expectError(error.DecodeFailed, short.next());
}

test "blend_over: transparent and opaque sources, and half alpha" {
    var d: [4]u8 = .{ 10, 20, 30, 255 };
    blend_over(&d, &.{ 0, 0, 0, 0 });
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, &d);
    blend_over(&d, &.{ 1, 2, 3, 255 });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &d);

    // Half-transparent white over opaque black: half grey, still opaque.
    var e: [4]u8 = .{ 0, 0, 0, 255 };
    blend_over(&e, &.{ 255, 255, 255, 128 });
    try testing.expectEqual(@as(u8, 255), e[3]);
    try testing.expect(e[0] >= 127 and e[0] <= 129);

    // Over a transparent destination the source keeps its colour and alpha.
    var f: [4]u8 = .{ 0, 0, 0, 0 };
    blend_over(&f, &.{ 9, 8, 7, 100 });
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7, 100 }, &f);
}

test "straight_bgra converts premultiplied backgrounds" {
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &straight_bgra(0));
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, &straight_bgra(0xff010203));
    // Half alpha: premultiplied red 128 is straight red 255.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, &straight_bgra(0x80800000));
}

test "budget refuses images over the limit before allocating" {
    var budget: Budget = .{ .limits = .{ .max_total_bytes = 64 } };
    try testing.expectEqual(@as(usize, 16), try budget.reserve(2, 2));
    try testing.expectError(error.ImageTooLarge, budget.reserve(4, 4));
    var roomy: Budget = .{ .limits = .{} };
    try testing.expectError(error.ImageTooLarge, roomy.reserve(16385, 1));
    try testing.expectError(error.DecodeFailed, budget.reserve(0, 4));
}

const LOSSY_TOLERANCE: u8 = 2;
const JPEG_TOLERANCE: u8 = 2;

// Fixtures come from Wuffs' test/data (https://github.com/google/wuffs, commit b36a81d, Apache-2.0
// OR MIT). Expected pixels are ImageMagick's output for the same files, see src/testdata/images/SOURCES.txt.

const fixture = struct {
    const lossless_webp = @embedFile("testdata/images/hippopotamus.lossless.webp");
    const lossy_webp = @embedFile("testdata/images/hippopotamus.lossy.webp");
    const animated_webp = @embedFile("testdata/images/animated-red-blue.webp");
    const animated_gif = @embedFile("testdata/images/animated-red-blue.gif");
    const apng = @embedFile("testdata/images/animated-red-blue.apng");
    const alpha_png = @embedFile("testdata/images/hippopotamus.masked-with-muybridge.png");
    const jpeg = @embedFile("testdata/images/hippopotamus.jpeg");
    const qoi = @embedFile("testdata/images/mona-lisa.21x32.qoi");
    const tga = @embedFile("testdata/images/bricks-gray.tga");
    const bmp = @embedFile("testdata/images/hippopotamus.bmp");
    const ppm = @embedFile("testdata/images/hippopotamus.ppm");
    const static_gif = @embedFile("testdata/images/hippopotamus.regular.gif");

    const lossless_webp_rgba = @embedFile("testdata/images/hippopotamus.lossless.webp.rgba");
    const lossy_webp_rgba = @embedFile("testdata/images/hippopotamus.lossy.webp.rgba");
    const alpha_png_rgba = @embedFile("testdata/images/hippopotamus.masked-with-muybridge.png.rgba");
    const jpeg_rgba = @embedFile("testdata/images/hippopotamus.jpeg.rgba");
    const qoi_rgba = @embedFile("testdata/images/mona-lisa.21x32.qoi.rgba");
    const bmp_rgba = @embedFile("testdata/images/hippopotamus.bmp.rgba");
    const ppm_rgba = @embedFile("testdata/images/hippopotamus.ppm.rgba");
    const static_gif_rgba = @embedFile("testdata/images/hippopotamus.regular.gif.rgba");
};

const gpui_animated_webp = [_]u8{
    82, 73, 70, 70, 192, 0, 0, 0, 87, 69, 66, 80, 86, 80, 56, 88,
    10, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 65, 78,
    73, 77, 6, 0, 0, 0, 255, 255, 255, 255, 0, 0, 65, 78, 77, 70,
    72, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    100, 0, 0, 2, 86, 80, 56, 32, 48, 0, 0, 0, 208, 1, 0, 157,
    1, 42, 1, 0, 1, 0, 2, 0, 52, 37, 160, 2, 116, 186, 1, 248,
    0, 3, 176, 0, 254, 240, 196, 11, 255, 32, 185, 97, 117, 200, 215, 255,
    32, 63, 228, 7, 252, 128, 255, 248, 242, 0, 0, 0, 65, 78, 77, 70,
    68, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    100, 0, 0, 0, 86, 80, 56, 32, 44, 0, 0, 0, 148, 1, 0, 157,
    1, 42, 1, 0, 1, 0, 0, 0, 52, 37, 160, 2, 116, 186, 0, 3,
    152, 0, 254, 249, 147, 111, 255, 144, 31, 255, 144, 31, 255, 144, 31, 255,
    32, 63, 226, 23, 123, 32, 48, 0,
};


fn free_frames_for_test(frames: []Frame) void {
    for (frames) |f| testing.allocator.free(f.pixels);
    testing.allocator.free(frames);
}

/// Checks a BGRA frame against ImageMagick's RGBA dump of the same image, channel by channel.
fn expect_matches_rgba(expected: []const u8, frame: Frame, tolerance: u8) !void {
    try testing.expectEqual(@as(usize, frame.width) * frame.height * 4, expected.len);
    try testing.expectEqual(expected.len, frame.pixels.len);
    var worst: u8 = 0;
    var worst_pixel: usize = 0;
    var i: usize = 0;
    while (i < expected.len) : (i += 4) {
        // The dump is RGBA; the frame is BGRA.
        const want = [4]i16{ expected[i + 2], expected[i + 1], expected[i], expected[i + 3] };
        for (0..4) |c| {
            const got: i16 = frame.pixels[i + c];
            const diff: u8 = @intCast(@abs(got - want[c]));
            if (diff > worst) {
                worst = diff;
                worst_pixel = i / 4;
            }
        }
    }
    if (worst > tolerance) {
        std.debug.print("pixel {d} differs by {d} (tolerance {d})\n", .{ worst_pixel, worst, tolerance });
        return error.TestExpectedEqual;
    }
}

test "wuffs: lossless WebP matches ImageMagick exactly" {
    const frames = try decode(testing.allocator, .webp, fixture.lossless_webp);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqual(@as(u32, 36), frames[0].width);
    try testing.expectEqual(@as(u32, 28), frames[0].height);
    try expect_matches_rgba(fixture.lossless_webp_rgba, frames[0], 0);
}

test "wuffs: lossy WebP matches ImageMagick within libwebp rounding" {
    const frames = try decode(testing.allocator, .webp, fixture.lossy_webp);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try expect_matches_rgba(fixture.lossy_webp_rgba, frames[0], LOSSY_TOLERANCE);
}

test "wuffs: PNG with alpha matches ImageMagick exactly, straight alpha" {
    const frames = try decode(testing.allocator, .png, fixture.alpha_png);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try expect_matches_rgba(fixture.alpha_png_rgba, frames[0], 0);
}

test "wuffs: JPEG matches ImageMagick within IDCT rounding" {
    const frames = try decode(testing.allocator, .jpeg, fixture.jpeg);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try expect_matches_rgba(fixture.jpeg_rgba, frames[0], JPEG_TOLERANCE);
}

test "wuffs: QOI, BMP, PPM and static GIF match ImageMagick exactly" {
    const cases = [_]struct { codec: Codec, bytes: []const u8, rgba: []const u8, width: u32, height: u32 }{
        .{ .codec = .qoi, .bytes = fixture.qoi, .rgba = fixture.qoi_rgba, .width = 21, .height = 32 },
        .{ .codec = .bmp, .bytes = fixture.bmp, .rgba = fixture.bmp_rgba, .width = 36, .height = 28 },
        .{ .codec = .netpbm, .bytes = fixture.ppm, .rgba = fixture.ppm_rgba, .width = 36, .height = 28 },
        .{ .codec = .gif, .bytes = fixture.static_gif, .rgba = fixture.static_gif_rgba, .width = 36, .height = 28 },
    };
    for (cases) |case| {
        const frames = try decode(testing.allocator, case.codec, case.bytes);
        defer free_frames_for_test(frames);
        try testing.expectEqual(@as(usize, 1), frames.len);
        try testing.expectEqual(case.width, frames[0].width);
        try testing.expectEqual(case.height, frames[0].height);
        try expect_matches_rgba(case.rgba, frames[0], 0);
    }
}

test "wuffs: TGA samples match ImageMagick" {
    const frames = try decode(testing.allocator, .targa, fixture.tga);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqual(@as(u32, 160), frames[0].width);
    try testing.expectEqual(@as(u32, 120), frames[0].height);
    // Grey pixels: BGRA with equal channels, as ImageMagick reports.
    const at = struct {
        fn f(frame: Frame, x: usize, y: usize) [4]u8 {
            return frame.pixels[(y * frame.width + x) * 4 ..][0..4].*;
        }
    }.f;
    try testing.expectEqualSlices(u8, &.{ 85, 85, 85, 255 }, &at(frames[0], 0, 0));
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 255 }, &at(frames[0], 80, 60));
    try testing.expectEqualSlices(u8, &.{ 6, 6, 6, 255 }, &at(frames[0], 159, 119));
}

/// Counts the pixels of `frame` that equal `color` (BGRA).
fn count_pixels(frame: Frame, color: [4]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < frame.pixels.len) : (i += 4) {
        if (std.mem.eql(u8, frame.pixels[i..][0..4], &color)) n += 1;
    }
    return n;
}

fn expect_animation_red_blue(frames: []const Frame) !void {
    try testing.expectEqual(@as(usize, 4), frames.len);
    const delays = [_]u32{ 100, 200, 300, 400 };
    for (frames, delays, 0..) |frame, delay, i| {
        try testing.expectEqual(@as(u32, 64), frame.width);
        try testing.expectEqual(@as(u32, 48), frame.height);
        try testing.expectEqual(delay, frame.delay_ms);
        // Per frame counts that ImageMagick gives for the coalesced animation.
        const red = count_pixels(frame, .{ 0, 0, 255, 255 });
        const blue = count_pixels(frame, .{ 255, 0, 0, 255 });
        const white = count_pixels(frame, .{ 255, 255, 255, 255 });
        switch (i) {
            0, 1, 3 => {
                try testing.expectEqual(@as(usize, 71), red);
                try testing.expectEqual(@as(usize, 0), blue);
            },
            2 => {
                try testing.expectEqual(@as(usize, 0), red);
                try testing.expectEqual(@as(usize, 83), blue);
            },
            else => unreachable,
        }
        try testing.expect(white > 2600);
    }
}

test "wuffs: animated GIF composites four frames with delays from the file" {
    const frames = try decode(testing.allocator, .gif, fixture.animated_gif);
    defer free_frames_for_test(frames);
    try expect_animation_red_blue(frames);
}

test "wuffs: animated WebP is composited by the RIFF walker into four frames" {
    try testing.expect(is_animated_webp(fixture.animated_webp));
    const frames = try decode(testing.allocator, .webp, fixture.animated_webp);
    defer free_frames_for_test(frames);
    try expect_animation_red_blue(frames);
}

/// Checks a pixel against an expected one, each channel within `tolerance`.
fn expect_close(expected: []const u8, actual: []const u8, tolerance: u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        const diff: u8 = @intCast(@abs(@as(i16, e) - @as(i16, a)));
        if (diff > tolerance) {
            std.debug.print("expected {any}, got {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
        }
    }
}

test "wuffs: the GPUI animated WebP gives two 1x1 frames of 100 ms" {
    const frames = try decode(testing.allocator, .webp, &gpui_animated_webp);
    defer free_frames_for_test(frames);
    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expectEqual(@as(u32, 1), frames[0].width);
    try testing.expectEqual(@as(u32, 1), frames[0].height);
    try testing.expectEqual(@as(u32, 100), frames[0].delay_ms);
    try testing.expectEqual(@as(u32, 100), frames[1].delay_ms);
    // Frame 0 is red and frame 1 is blue, in BGRA. The frames are lossy, so the colours are close.
    try expect_close(&.{ 0, 0, 255, 255 }, frames[0].pixels, 4);
    try expect_close(&.{ 255, 0, 0, 255 }, frames[1].pixels, 4);
}

test "wuffs: APNG decodes frames" {
    const frames = try decode(testing.allocator, .png, fixture.apng);
    defer free_frames_for_test(frames);
    try testing.expect(frames.len >= 1);
    try testing.expectEqual(@as(u32, 64), frames[0].width);
    try testing.expectEqual(@as(u32, 48), frames[0].height);
}

test "wuffs: limits refuse oversize images and too many frames" {
    try testing.expectError(error.ImageTooLarge, decode_with(testing.allocator, .png, fixture.alpha_png, .{ .max_total_bytes = 1000 }));
    try testing.expectError(error.ImageTooLarge, decode_with(testing.allocator, .png, fixture.alpha_png, .{ .max_side = 30 }));
    try testing.expectError(error.ImageTooLarge, decode_with(testing.allocator, .gif, fixture.animated_gif, .{ .max_frames = 2 }));
    try testing.expectError(error.ImageTooLarge, decode_with(testing.allocator, .webp, fixture.animated_webp, .{ .max_frames = 2 }));
    try testing.expectError(error.ImageTooLarge, decode_with(testing.allocator, .webp, fixture.animated_webp, .{ .max_total_bytes = 4 * 64 * 48 * 4 }));
}

test "wuffs: wrong codec and garbage are errors, not crashes" {
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, .png, fixture.jpeg));
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, .webp, "RIFF\x04\x00\x00\x00WEBP"));
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, .gif, ""));
}

// Every prefix of each fixture must decode or fail cleanly, with nothing leaked.
test "wuffs: every truncated prefix of each fixture decodes or fails without leaking" {
    const small: Limits = .{ .max_total_bytes = 1 << 20 };
    const cases = [_]struct { codec: Codec, bytes: []const u8 }{
        .{ .codec = .webp, .bytes = fixture.lossless_webp },
        .{ .codec = .webp, .bytes = fixture.lossy_webp },
        .{ .codec = .webp, .bytes = fixture.animated_webp },
        .{ .codec = .gif, .bytes = fixture.animated_gif },
        .{ .codec = .png, .bytes = fixture.apng },
        .{ .codec = .png, .bytes = fixture.alpha_png },
        .{ .codec = .jpeg, .bytes = fixture.jpeg },
        .{ .codec = .qoi, .bytes = fixture.qoi },
        .{ .codec = .targa, .bytes = fixture.tga },
        .{ .codec = .bmp, .bytes = fixture.bmp },
        .{ .codec = .netpbm, .bytes = fixture.ppm },
        .{ .codec = .gif, .bytes = fixture.static_gif },
    };
    for (cases) |case| {
        for (0..case.bytes.len + 1) |n| {
            if (decode_with(testing.allocator, case.codec, case.bytes[0..n], small)) |frames| {
                free_frames_for_test(frames);
            } else |_| {}
        }
    }
}

// Random corruption at fixed seeds: every result is an error or a valid image, and nothing leaks.
test "wuffs: corrupted fixtures decode or fail without crashing or leaking" {
    const small: Limits = .{ .max_total_bytes = 1 << 20 };
    const cases = [_]struct { codec: Codec, bytes: []const u8 }{
        .{ .codec = .webp, .bytes = fixture.lossless_webp },
        .{ .codec = .webp, .bytes = fixture.lossy_webp },
        .{ .codec = .webp, .bytes = fixture.animated_webp },
        .{ .codec = .gif, .bytes = fixture.animated_gif },
        .{ .codec = .png, .bytes = fixture.apng },
        .{ .codec = .png, .bytes = fixture.alpha_png },
        .{ .codec = .jpeg, .bytes = fixture.jpeg },
        .{ .codec = .qoi, .bytes = fixture.qoi },
        .{ .codec = .targa, .bytes = fixture.tga },
        .{ .codec = .bmp, .bytes = fixture.bmp },
        .{ .codec = .netpbm, .bytes = fixture.ppm },
    };
    var prng = std.Random.DefaultPrng.init(0x7a75695f77756666);
    const random = prng.random();
    var buffer: [fixture.tga.len]u8 = undefined;
    for (cases) |case| {
        for (0..400) |_| {
            const copy = buffer[0..case.bytes.len];
            @memcpy(copy, case.bytes);
            const edits = random.uintLessThan(usize, 4) + 1;
            for (0..edits) |_| {
                copy[random.uintLessThan(usize, copy.len)] = random.int(u8);
            }
            // A cut at a random point as well.
            const len = if (random.boolean()) copy.len else random.uintLessThan(usize, copy.len + 1);
            if (decode_with(testing.allocator, case.codec, copy[0..len], small)) |frames| {
                free_frames_for_test(frames);
            } else |_| {}
        }
    }
}

test "wuffs: WebP walker rejects chunk sizes that overrun the file" {
    // An ANMF whose size claims more bytes than the file has.
    var bad: [fixture.animated_webp.len]u8 = undefined;
    @memcpy(&bad, fixture.animated_webp);
    const anmf = std.mem.indexOf(u8, &bad, "ANMF").?;
    std.mem.writeInt(u32, bad[anmf + 4 ..][0..4], 0x7fff_0000, .little);
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, .webp, &bad));
}

test "wuffs: a RIFF size near 4 GiB does not overflow" {
    var bytes: [fixture.lossless_webp.len]u8 = undefined;
    @memcpy(&bytes, fixture.lossless_webp);
    std.mem.writeInt(u32, bytes[4..8], 0xffff_ffff, .little);
    try testing.expect(webp_body(&bytes) != null);
    try testing.expectEqual(bytes.len - 12, webp_body(&bytes).?.len);
}

test "wuffs: an animation cut short keeps the frames before the cut" {
    // Cut inside the last frame of each: the earlier ones must survive, unchanged.
    const cases = [_]struct { codec: Codec, bytes: []const u8 }{
        .{ .codec = .gif, .bytes = fixture.animated_gif },
        .{ .codec = .webp, .bytes = fixture.animated_webp },
    };
    for (cases) |case| {
        const whole = try decode(testing.allocator, case.codec, case.bytes);
        defer free_frames_for_test(whole);
        var cut = case.bytes.len - 1;
        const kept = while (cut > 0) : (cut -= 1) {
            const frames = decode(testing.allocator, case.codec, case.bytes[0..cut]) catch continue;
            if (frames.len < whole.len) break frames;
            free_frames_for_test(frames);
        } else return error.TestExpectedEqual;
        defer free_frames_for_test(kept);
        try testing.expect(kept.len >= 1);
        for (kept, whole[0..kept.len]) |a, b| try testing.expectEqualSlices(u8, b.pixels, a.pixels);
    }
    // A file with no complete frame is still an error.
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, .gif, fixture.animated_gif[0..20]));
}

test "wuffs: the default limits leave room for the work buffer of a 48-megapixel progressive JPEG" {
    const limits: Limits = .{};
    try testing.expect(limits.max_workbuf >= 205 << 20);
}
