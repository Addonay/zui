//! Minimal PNG decoder for embedded bitmap glyphs.
//!
//! Port of the `png 0.18` decode path that `vello_common::Pixmap::from_png`
//! uses (`Decoder::new` with
//! `Transformations::normalize_to_color8() | Transformations::ALPHA`):
//! indexed palettes expand through `PLTE`/`tRNS` to straight RGBA8, grayscale
//! and RGB gain an alpha channel (`GrayAlpha`/`RGBA`), 1/2/4-bit samples are
//! scaled to 8 bits, and filters 0–4 are applied. The result is *straight*
//! (non-premultiplied) RGBA8; `Pixmap.fromParts` performs the upstream
//! `premultiply_rgba8` step and computes the transparency hint.
//!
//! Explicit typed gaps (upstream `png` would decode them):
//! - 16-bit samples (`error.Unsupported`; `normalize_to_color8` strips them).
//! - Adam7 interlacing (`error.Unsupported`).
//! - `tRNS` handling outside the indexed path is transcribed from the `png`
//!   0.18 expansion functions, including their byte-slice comparison quirks
//!   for 8-bit grayscale/RGB.
//!
//! The embedded-bitmap fixtures only use 8-bit indexed, non-interlaced PNGs
//! with `PLTE` + `tRNS`, which this decoder reproduces byte-for-byte.

const std = @import("std");

/// Errors from `decode`.
pub const Error = error{
    /// The 8-byte PNG signature is missing.
    InvalidSignature,
    /// A chunk extends past the end of the data.
    Truncated,
    /// A chunk is malformed (bad CRC, impossible dimensions, missing palette,
    /// ...).
    InvalidData,
    /// A valid PNG feature this port does not decode yet.
    Unsupported,
    /// A dimension does not fit the `u16` pixmap size.
    ImageTooLarge,
    OutOfMemory,
};

/// A decoded PNG: straight (non-premultiplied) RGBA8 pixels, row-major.
pub const Decoded = struct {
    width: u16,
    height: u16,
    pixels: []u8,
};

const signature = "\x89PNG\r\n\x1a\n";

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

const max_chunk_len: usize = 64 * 1024 * 1024;

/// Decodes a PNG into straight RGBA8 pixels. The caller owns `pixels`.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len < signature.len or
        !std.mem.eql(u8, data[0..signature.len], signature))
    {
        return error.InvalidSignature;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: ColorType = .grayscale;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    var pos: usize = signature.len;
    var saw_ihdr = false;
    var saw_iend = false;
    while (pos + 8 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (len > max_chunk_len) return error.InvalidData;
        const chunk_type = data[pos + 4 ..][0..4];
        const body_start = pos + 8;
        const body_end = std.math.add(usize, body_start, len) catch return error.Truncated;
        const crc_end = std.math.add(usize, body_end, 4) catch return error.Truncated;
        if (crc_end > data.len) return error.Truncated;
        const body = data[body_start..body_end];
        const stored_crc = std.mem.readInt(u32, data[body_end..][0..4], .big);
        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(body);
        if (crc.final() != stored_crc) return error.InvalidData;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (saw_ihdr or body.len != 13) return error.InvalidData;
            saw_ihdr = true;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            bit_depth = body[8];
            color_type = switch (body[9]) {
                0 => .grayscale,
                2 => .rgb,
                3 => .indexed,
                4 => .grayscale_alpha,
                6 => .rgba,
                else => return error.InvalidData,
            };
            const compression = body[10];
            const filter_method = body[11];
            const interlace = body[12];
            if (width == 0 or height == 0) return error.InvalidData;
            if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) {
                return error.ImageTooLarge;
            }
            if (compression != 0 or filter_method != 0) return error.InvalidData;
            if (interlace != 0) return error.Unsupported;
            const valid_depth = switch (color_type) {
                .grayscale => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or
                    bit_depth == 8 or bit_depth == 16,
                .rgb, .grayscale_alpha, .rgba => bit_depth == 8 or bit_depth == 16,
                .indexed => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or
                    bit_depth == 8,
            };
            if (!valid_depth) return error.InvalidData;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (!saw_ihdr or body.len % 3 != 0 or body.len > 256 * 3) {
                return error.InvalidData;
            }
            palette = body;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (!saw_ihdr) return error.InvalidData;
            trns = body;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (!saw_ihdr) return error.InvalidData;
            try idat.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            saw_iend = true;
            break;
        }
        pos = crc_end;
    }

    if (!saw_ihdr or !saw_iend or idat.items.len == 0) return error.InvalidData;
    if (bit_depth == 16) return error.Unsupported;
    if (color_type == .indexed and palette.len == 0) return error.InvalidData;

    const w: usize = width;
    const h: usize = height;
    const bits_per_pixel = bitsPerPixel(color_type, bit_depth);
    const row_bytes = (w * bits_per_pixel + 7) / 8;
    const expected_raw = std.math.mul(usize, row_bytes + 1, h) catch return error.InvalidData;

    var raw = try inflate(allocator, idat.items);
    defer allocator.free(raw);
    if (raw.len < expected_raw) return error.InvalidData;

    const pixels = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(pixels);

    try convert(
        raw[0..expected_raw],
        pixels,
        @intCast(w),
        @intCast(h),
        bit_depth,
        color_type,
        palette,
        trns,
    );
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

fn bitsPerPixel(color_type: ColorType, bit_depth: u8) usize {
    const samples: usize = switch (color_type) {
        .grayscale, .indexed => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
    };
    return samples * bit_depth;
}

/// Inflate the concatenated `IDAT` payload (zlib stream) into `raw`.
fn inflate(allocator: std.mem.Allocator, compressed: []const u8) Error![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &.{});
    return decompress.reader.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
}

/// Unfilter `raw` in place and convert each row into `pixels` (straight
/// RGBA8). The filter and expansion rules mirror `png` 0.18; see the module
/// docs for the exact quirks that are preserved.
fn convert(
    raw: []u8,
    pixels: []u8,
    width: u16,
    height: u16,
    bit_depth: u8,
    color_type: ColorType,
    palette: []const u8,
    trns: []const u8,
) Error!void {
    const w: usize = width;
    const h: usize = height;
    const bits_per_pixel = bitsPerPixel(color_type, bit_depth);
    const row_bytes = (w * bits_per_pixel + 7) / 8;
    const filter_bpp = @max(1, (bits_per_pixel + 7) / 8);

    // `png` 0.18's `create_rgba_palette`: default entries are opaque black,
    // `PLTE` fills RGB, `tRNS` fills the first entries' alpha, and the
    // remaining palette entries are forced opaque. A `tRNS` longer than the
    // palette is ignored entirely.
    var rgba_palette: [256][4]u8 = @splat(.{ 0, 0, 0, 0xFF });
    for (0..palette.len / 3) |i| {
        rgba_palette[i][0] = palette[3 * i];
        rgba_palette[i][1] = palette[3 * i + 1];
        rgba_palette[i][2] = palette[3 * i + 2];
    }
    const effective_trns: []const u8 = if (trns.len <= palette.len / 3) trns else &.{};
    for (effective_trns, 0..) |alpha, i| rgba_palette[i][3] = alpha;

    var row_index: usize = 0;
    while (row_index < h) : (row_index += 1) {
        const row_start = row_index * (row_bytes + 1);
        const filter = raw[row_start];
        const row = raw[row_start + 1 .. row_start + 1 + row_bytes];
        const prev: ?[]const u8 = if (row_index == 0)
            null
        else
            raw[row_start - row_bytes .. row_start];
        try unfilter(filter, row, prev, filter_bpp);

        const out = pixels[row_index * w * 4 ..][0 .. w * 4];
        switch (color_type) {
            .indexed => {
                for (0..w) |x| {
                    const index = sampleAt(row, x, bit_depth);
                    out[x * 4 ..][0..4].* = rgba_palette[index];
                }
            },
            .grayscale => {
                const max_sample: u16 = (@as(u16, 1) << @intCast(bit_depth)) - 1;
                const scale: u8 = @intCast(255 / max_sample);
                const transparent: ?u8 = if (bit_depth < 8 and trns.len >= 1) trns[0] else null;
                for (0..w) |x| {
                    const sample = sampleAt(row, x, bit_depth);
                    const gray: u8 = if (bit_depth == 8) sample else sample * scale;
                    const alpha: u8 = if (transparent) |value|
                        (if (value == sample) @as(u8, 0) else 255)
                    else
                        255;
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, alpha };
                }
            },
            .rgb => {
                for (0..w) |x| {
                    const pixel = row[x * 3 ..][0..3];
                    // `png` 0.18 compares the 3-byte RGB chunk against the
                    // 6-byte tRNS buffer, so RGB tRNS never matches.
                    out[x * 4 ..][0..4].* = .{ pixel[0], pixel[1], pixel[2], 255 };
                }
            },
            .grayscale_alpha => {
                for (0..w) |x| {
                    const gray = row[x * 2];
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, row[x * 2 + 1] };
                }
            },
            .rgba => {
                @memcpy(out, row[0 .. w * 4]);
            },
        }
    }
}

/// PNG filter reconstruction, in place (`png` 0.18 `filter` module).
fn unfilter(
    filter: u8,
    row: []u8,
    prev: ?[]const u8,
    bpp: usize,
) Error!void {
    switch (filter) {
        0 => {},
        1 => {
            for (row, 0..) |*byte, i| {
                const a: u8 = if (i >= bpp) row[i - bpp] else 0;
                byte.* +%= a;
            }
        },
        2 => {
            for (row, 0..) |*byte, i| {
                const b: u8 = if (prev) |p| p[i] else 0;
                byte.* +%= b;
            }
        },
        3 => {
            for (row, 0..) |*byte, i| {
                const a: u8 = if (i >= bpp) row[i - bpp] else 0;
                const b: u8 = if (prev) |p| p[i] else 0;
                byte.* +%= @intCast((@as(u16, a) + @as(u16, b)) / 2);
            }
        },
        4 => {
            for (row, 0..) |*byte, i| {
                const a: u8 = if (i >= bpp) row[i - bpp] else 0;
                const b: u8 = if (prev) |p| p[i] else 0;
                const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                byte.* +%= paeth(a, b, c);
            }
        },
        else => return error.InvalidData,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const ai: i16 = a;
    const bi: i16 = b;
    const ci: i16 = c;
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Extracts one sample from a packed row (1/2/4/8 bits per sample).
fn sampleAt(row: []const u8, x: usize, bit_depth: u8) u8 {
    const bit = x * bit_depth;
    const byte = row[bit >> 3];
    if (bit_depth == 8) return byte;
    const shift: u3 = @intCast(8 - bit_depth - @as(u8, @intCast(bit & 7)));
    const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
    return (byte >> shift) & mask;
}

// --------------------------------------------------------------------- tests
const testing = std.testing;

const indexed_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x03, 0x00, 0x00, 0x00, 0x48, 0x76, 0x8d, 0x51, 0x00, 0x00, 0x00,
    0x09, 0x50, 0x4c, 0x54, 0x45, 0x0a, 0x14, 0x1e, 0x28, 0x32, 0x3c, 0x46,
    0x50, 0x5a, 0x16, 0xac, 0x84, 0x74, 0x00, 0x00, 0x00, 0x03, 0x74, 0x52,
    0x4e, 0x53, 0x00, 0x80, 0xff, 0xec, 0xf7, 0xb3, 0x18, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x64, 0x62,
    0x60, 0x60, 0x62, 0x62, 0x64, 0x00, 0x00, 0x00, 0x30, 0x00, 0x09, 0x46,
    0x48, 0x12, 0xcf, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
};
const rgb_filtered_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x12, 0x16, 0xf1, 0x4d, 0x00, 0x00, 0x00,
    0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0x64, 0x62, 0x86,
    0x00, 0x16, 0x4e, 0x21, 0x69, 0x39, 0x30, 0x00, 0x00, 0x05, 0xc1, 0x01,
    0x08, 0x8c, 0x61, 0xdd, 0x81, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
};
const gray_1bit_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x4d, 0xef, 0xa0, 0x40, 0x00, 0x00, 0x00,
    0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x58, 0xc5, 0x10, 0x0a,
    0x00, 0x02, 0x57, 0x01, 0x00, 0x58, 0xb2, 0xca, 0x23, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};
const trns_too_long_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x03, 0x00, 0x00, 0x00, 0x28, 0xcb, 0x34, 0xbb, 0x00, 0x00, 0x00,
    0x03, 0x50, 0x4c, 0x54, 0x45, 0x01, 0x02, 0x03, 0x0d, 0x87, 0x64, 0xd5,
    0x00, 0x00, 0x00, 0x04, 0x74, 0x52, 0x4e, 0x53, 0x00, 0x00, 0x00, 0x00,
    0xb3, 0x93, 0x66, 0x9a, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54,
    0x78, 0xda, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xe5, 0x27,
    0xde, 0xfc, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};
const png_16bit = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x10, 0x02, 0x00, 0x00, 0x00, 0xc0, 0xe7, 0x8f, 0x9d, 0x00, 0x00, 0x00,
    0x0f, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x64, 0x62, 0x66,
    0x61, 0x65, 0x03, 0x00, 0x00, 0x3f, 0x00, 0x16, 0x98, 0xc1, 0x68, 0x13,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};
const png_interlaced = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x00, 0x00, 0x00, 0x01, 0x4d, 0x79, 0xab, 0xc3, 0x00, 0x00, 0x00,
    0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x07, 0x00, 0x00,
    0x09, 0x00, 0x08, 0x8d, 0xab, 0xb9, 0x01, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const test_fixture = @import("test_fixture.zig");
const bitmap = @import("tables/bitmap.zig");
const font_mod = @import("font.zig");

test "decodes indexed 8-bit with PLTE and tRNS" {
    const decoded = try decode(testing.allocator, &indexed_png);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 4), decoded.width);
    try testing.expectEqual(@as(u16, 2), decoded.height);
    const expected = [_]u8{
        10, 20, 30, 0,   40, 50, 60, 128, 70, 80, 90, 255, 10, 20, 30, 0,
        70, 80, 90, 255, 70, 80, 90, 255, 40, 50, 60, 128, 10, 20, 30, 0,
    };
    try testing.expectEqualSlices(u8, &expected, decoded.pixels);
}

test "decodes rgb 8-bit through Sub and Paeth filters" {
    const decoded = try decode(testing.allocator, &rgb_filtered_png);
    defer testing.allocator.free(decoded.pixels);
    const expected = [_]u8{
        1,  2,  3,  255, 4,  5,  6,  255, 7,  8,  9,  255,
        10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
    };
    try testing.expectEqualSlices(u8, &expected, decoded.pixels);
}

test "decodes 1-bit grayscale by scaling to 8 bits" {
    const decoded = try decode(testing.allocator, &gray_1bit_png);
    defer testing.allocator.free(decoded.pixels);
    const rows = [2][8]u8{
        .{ 255, 0, 255, 0, 255, 0, 255, 0 },
        .{ 0, 255, 0, 255, 0, 255, 0, 255 },
    };
    for (rows, 0..) |row, y| {
        for (row, 0..) |gray, x| {
            const pixel = decoded.pixels[(y * 8 + x) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, &.{ gray, gray, gray, 255 }, pixel);
        }
    }
}

test "tRNS longer than the palette is ignored" {
    const decoded = try decode(testing.allocator, &trns_too_long_png);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, decoded.pixels);
}

test "typed errors for unsupported and malformed PNGs" {
    try testing.expectError(error.Unsupported, decode(testing.allocator, &png_16bit));
    try testing.expectError(error.Unsupported, decode(testing.allocator, &png_interlaced));
    try testing.expectError(error.InvalidSignature, decode(testing.allocator, "nope"));

    // Flip one byte inside the IDAT payload: the chunk CRC no longer matches.
    var corrupted: [indexed_png.len]u8 = indexed_png;
    corrupted[85] ^= 0xFF;
    try testing.expectError(error.InvalidData, decode(testing.allocator, &corrupted));

    // Truncating inside a chunk body is a hard error.
    try testing.expectError(
        error.Truncated,
        decode(testing.allocator, indexed_png[0..92]),
    );
}

test "decodes the CBDT fixture glyph PNGs" {
    const font = try font_mod.Font.init(try test_fixture.notoCbtf(), 0);
    const strikes = bitmap.Strikes.init(font);
    const strike = strikes.get(0).?;
    const glyph = strike.get(1).?;
    const png_data = switch (glyph.data) {
        .png => |data| data,
        else => return error.TestUnexpectedResult,
    };
    const decoded = try decode(testing.allocator, png_data);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 136), decoded.width);
    try testing.expectEqual(@as(u16, 128), decoded.height);

    // The fixture's first palette entry is transparent; the glyph is a
    // colour bitmap, so some pixels must be opaque and non-black.
    var opaque_color: usize = 0;
    var transparent: usize = 0;
    var i: usize = 0;
    while (i < decoded.pixels.len) : (i += 4) {
        const alpha = decoded.pixels[i + 3];
        if (alpha == 0) transparent += 1;
        if (alpha != 0 and (decoded.pixels[i] != 0 or decoded.pixels[i + 1] != 0 or
            decoded.pixels[i + 2] != 0))
        {
            opaque_color += 1;
        }
    }
    try testing.expect(transparent > 0);
    try testing.expect(opaque_color > 0);
}
