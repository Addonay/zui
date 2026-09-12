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
//! Supported edge formats:
//! - 16-bit samples are downconverted exactly like `Transformations::STRIP_16`
//!   (`transform_row_strip16` keeps the high byte; the `tRNS`-carrying
//!   grayscale/RGB arms use `expand_trns_and_strip_line16`, whose alpha test
//!   compares the raw 16-bit sample bytes).
//! - Adam7 interlacing is deinterlaced with the default sparse algorithm
//!   (`expand_pass`): filter state resets at each pass line 0, each pass row
//!   is transformed, then scattered to its original positions.
//! - `tRNS` handling outside the indexed path is transcribed from the `png`
//!   0.18 expansion functions, including their byte-slice comparison quirks
//!   for 8-bit grayscale/RGB (a 1-/3-byte sample never equals the longer
//!   `tRNS` buffer, so those pixels stay opaque).
//!
//! The embedded-bitmap fixtures only use 8-bit indexed, non-interlaced PNGs
//! with `PLTE` + `tRNS`, which this decoder reproduces byte-for-byte; the
//! 16-bit and Adam7 paths are covered by unit tests against externally
//! encoded streams.

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
    var interlaced = false;
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
            if (interlace > 1) return error.InvalidData;
            interlaced = interlace == 1;
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
    if (color_type == .indexed and palette.len == 0) return error.InvalidData;

    const w: usize = width;
    const h: usize = height;
    const bits_per_pixel = bitsPerPixel(color_type, bit_depth);
    const expected_len = if (interlaced)
        interlacedRawLength(w, h, bits_per_pixel)
    else
        nonInterlacedRawLength(w, h, bits_per_pixel);
    const expected_raw = expected_len orelse return error.InvalidData;

    var raw = try inflate(allocator, idat.items, expected_raw);
    defer allocator.free(raw);
    if (raw.len < expected_raw) return error.InvalidData;

    const pixels = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(pixels);

    try convert(
        allocator,
        raw[0..expected_raw],
        pixels,
        @intCast(w),
        @intCast(h),
        bit_depth,
        color_type,
        palette,
        trns,
        interlaced,
    );
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

/// Size of the non-interlaced filtered row stream.
fn nonInterlacedRawLength(w: usize, h: usize, bits_per_pixel: usize) ?usize {
    const row_bytes = (w * bits_per_pixel + 7) / 8;
    return std.math.mul(usize, row_bytes + 1, h) catch null;
}

/// Adam7 pass parameters (x/y sampling and offset), 1-indexed upstream.
const Adam7Pass = struct {
    x_sampling: u8,
    x_offset: u8,
    y_sampling: u8,
    y_offset: u8,
};

/// The seven Adam7 passes, in decode order.
const adam7_passes = [7]Adam7Pass{
    .{ .x_sampling = 8, .x_offset = 0, .y_sampling = 8, .y_offset = 0 },
    .{ .x_sampling = 8, .x_offset = 4, .y_sampling = 8, .y_offset = 0 },
    .{ .x_sampling = 4, .x_offset = 0, .y_sampling = 8, .y_offset = 4 },
    .{ .x_sampling = 4, .x_offset = 2, .y_sampling = 4, .y_offset = 0 },
    .{ .x_sampling = 2, .x_offset = 0, .y_sampling = 4, .y_offset = 2 },
    .{ .x_sampling = 2, .x_offset = 1, .y_sampling = 2, .y_offset = 0 },
    .{ .x_sampling = 1, .x_offset = 0, .y_sampling = 2, .y_offset = 1 },
};

fn countSamples(width: usize, pass: Adam7Pass) usize {
    if (width <= pass.x_offset) return 0;
    return (width - pass.x_offset + pass.x_sampling - 1) / pass.x_sampling;
}

fn countLines(height: usize, pass: Adam7Pass) usize {
    if (height <= pass.y_offset) return 0;
    return (height - pass.y_offset + pass.y_sampling - 1) / pass.y_sampling;
}

/// Size of the interlaced filtered row stream: one filtered pass row per
/// `count_lines` for each pass whose `count_samples` is non-zero.
fn interlacedRawLength(w: usize, h: usize, bits_per_pixel: usize) ?usize {
    var total: usize = 0;
    for (adam7_passes) |pass| {
        const samples = countSamples(w, pass);
        const lines = countLines(h, pass);
        if (samples == 0 or lines == 0) continue;
        const pass_row_bytes = (samples * bits_per_pixel + 7) / 8;
        const pass_total = std.math.mul(usize, pass_row_bytes + 1, lines) catch return null;
        total = std.math.add(usize, total, pass_total) catch return null;
    }
    return total;
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
///
/// The decompressed size is capped at the row stream's exact size, so a
/// malformed (or bomb) stream cannot allocate beyond the image it describes.
fn inflate(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    expected_len: usize,
) Error![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &.{});
    return decompress.reader.allocRemaining(
        allocator,
        // One extra byte of headroom: `allocRemaining` reports `StreamTooLong`
        // when the limit is *reached*, and a valid stream is exactly
        // `expected_len` long.
        .limited(expected_len + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
}

/// Unfilter `raw` in place and convert each row into `pixels` (straight
/// RGBA8). The filter and expansion rules mirror `png` 0.18; see the module
/// docs for the exact quirks that are preserved.
fn convert(
    allocator: std.mem.Allocator,
    raw: []u8,
    pixels: []u8,
    width: u16,
    height: u16,
    bit_depth: u8,
    color_type: ColorType,
    palette: []const u8,
    trns: []const u8,
    interlaced: bool,
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

    if (!interlaced) {
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
            try transformRow(
                row,
                pixels[row_index * w * 4 ..][0 .. w * 4],
                w,
                bit_depth,
                color_type,
                &rgba_palette,
                trns,
            );
        }
        return;
    }

    // Adam7, `png`'s default sparse variant (`expand_pass`): each pass row is
    // unfiltered against the previous row *of the same pass* (reset at pass
    // line 0), transformed to RGBA8, then scattered back to its pixels.
    const scratch = try allocator.alloc(u8, w * 4);
    defer allocator.free(scratch);
    var pos: usize = 0;
    for (adam7_passes) |pass| {
        const samples = countSamples(w, pass);
        const lines = countLines(h, pass);
        if (samples == 0 or lines == 0) continue;
        const pass_row_bytes = (samples * bits_per_pixel + 7) / 8;
        var line: usize = 0;
        while (line < lines) : (line += 1) {
            const filter = raw[pos];
            pos += 1;
            const row = raw[pos .. pos + pass_row_bytes];
            pos += pass_row_bytes;
            const prev: ?[]const u8 = if (line == 0)
                null
            else
                raw[pos - 2 * pass_row_bytes - 1 .. pos - pass_row_bytes - 1];
            try unfilter(filter, row, prev, filter_bpp);
            try transformRow(
                row,
                scratch[0 .. samples * 4],
                samples,
                bit_depth,
                color_type,
                &rgba_palette,
                trns,
            );
            const y = line * pass.y_sampling + pass.y_offset;
            for (0..samples) |i| {
                const x = i * pass.x_sampling + pass.x_offset;
                @memcpy(
                    pixels[(y * w + x) * 4 ..][0..4],
                    scratch[i * 4 ..][0..4],
                );
            }
        }
    }
}

/// Expand one (unfiltered) input row of `count` pixels into straight RGBA8.
///
/// The case split follows `png` 0.18's row transform functions for the
/// `normalize_to_color8() | ALPHA` configuration: `create_expansion_into_rgba8`
/// (indexed), `expand_gray_u8[_with_trns]` (sub-byte grayscale),
/// `expand_trns_line` (8-bit grayscale/RGB), `expand_trns_and_strip_line16`
/// (16-bit grayscale/RGB) and `transform_row_strip16` (16-bit gray-alpha/RGBA).
fn transformRow(
    row: []const u8,
    out: []u8,
    count: usize,
    bit_depth: u8,
    color_type: ColorType,
    rgba_palette: *const [256][4]u8,
    trns: []const u8,
) Error!void {
    switch (color_type) {
        .indexed => {
            for (0..count) |x| {
                const index = sampleAt(row, x, bit_depth);
                out[x * 4 ..][0..4].* = rgba_palette[index];
            }
        },
        .grayscale => {
            if (bit_depth < 8) {
                const max_sample: u16 = (@as(u16, 1) << @intCast(bit_depth)) - 1;
                const scale: u8 = @intCast(255 / max_sample);
                for (0..count) |x| {
                    const sample = sampleAt(row, x, bit_depth);
                    const alpha: u8 = if (trns.len >= 1 and trns[0] == sample) 0 else 255;
                    const gray = sample * scale;
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, alpha };
                }
            } else if (bit_depth == 8) {
                // `expand_trns_line` compares the 1-byte sample against the
                // (2-byte) grayscale tRNS buffer, so it never matches.
                for (0..count) |x| {
                    const gray = row[x];
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, 255 };
                }
            } else {
                for (0..count) |x| {
                    const gray = row[x * 2];
                    const alpha: u8 = if (trns.len == 2 and
                        std.mem.eql(u8, row[x * 2 ..][0..2], trns[0..2]))
                        0
                    else
                        255;
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, alpha };
                }
            }
        },
        .rgb => {
            if (bit_depth == 8) {
                // `expand_trns_line` compares the 3-byte pixel against the
                // 6-byte tRNS buffer, so RGB tRNS never matches.
                for (0..count) |x| {
                    const pixel = row[x * 3 ..][0..3];
                    out[x * 4 ..][0..4].* = .{ pixel[0], pixel[1], pixel[2], 255 };
                }
            } else {
                for (0..count) |x| {
                    const pixel = row[x * 6 ..][0..6];
                    const alpha: u8 = if (trns.len == 6 and std.mem.eql(u8, pixel, trns[0..6]))
                        0
                    else
                        255;
                    out[x * 4 ..][0..4].* = .{ pixel[0], pixel[2], pixel[4], alpha };
                }
            }
        },
        .grayscale_alpha => {
            if (bit_depth == 8) {
                for (0..count) |x| {
                    const gray = row[x * 2];
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, row[x * 2 + 1] };
                }
            } else {
                // `transform_row_strip16`.
                for (0..count) |x| {
                    const gray = row[x * 4];
                    out[x * 4 ..][0..4].* = .{ gray, gray, gray, row[x * 4 + 2] };
                }
            }
        },
        .rgba => {
            if (bit_depth == 8) {
                @memcpy(out[0 .. count * 4], row[0 .. count * 4]);
            } else {
                // `transform_row_strip16`.
                for (0..count) |x| {
                    out[x * 4 ..][0..4].* = .{
                        row[x * 8],
                        row[x * 8 + 2],
                        row[x * 8 + 4],
                        row[x * 8 + 6],
                    };
                }
            }
        },
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

const png_oversized = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x03, 0x00, 0x00, 0x00, 0x48, 0x76, 0x8d, 0x51, 0x00, 0x00, 0x00,
    0x09, 0x50, 0x4c, 0x54, 0x45, 0x0a, 0x14, 0x1e, 0x28, 0x32, 0x3c, 0x46,
    0x50, 0x5a, 0x16, 0xac, 0x84, 0x74, 0x00, 0x00, 0x00, 0x03, 0x74, 0x52,
    0x4e, 0x53, 0x00, 0x80, 0xff, 0xec, 0xf7, 0xb3, 0x18, 0x00, 0x00, 0x00,
    0x1a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x64, 0x62,
    0x60, 0x60, 0x62, 0x62, 0x64, 0x70, 0x8d, 0x08, 0x09, 0x72, 0x54, 0x54,
    0x54, 0x04, 0x00, 0x0a, 0x64, 0x01, 0xf0, 0x32, 0x5c, 0x16, 0x79, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

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

// The streams below were produced with Python's zlib (an external encoder),
// not with this decoder, so they exercise the 16-bit and Adam7 paths
// independently of one another. Pixel contents are noted per test.

/// 5x3 8-bit grayscale, Adam7, pixels row-major 1..15.
const adam7_gray8_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x00, 0x01, 0x09, 0x5a, 0xaa, 0xb2, 0x00, 0x00, 0x00, 0x1e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x64, 0x60, 0x65, 0x60, 0x66, 0xe0, 0xe6, 0xe5, 0x67, 0x60, 0x62, 0x61, 0xe0, 0xe1, 0x63, 0x60, 0x63, 0xe7, 0xe0, 0xe4, 0x02, 0x00, 0x04, 0x49, 0x00, 0x79, 0x2f, 0xed, 0xc4, 0x38, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

/// 4x4 RGBA 16-bit, Adam7; every 16-bit sample distinct.
const adam7_rgba16_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x10, 0x06, 0x00, 0x00, 0x01, 0x8e, 0x66, 0x72, 0xab, 0x00, 0x00, 0x00, 0x73, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x0d, 0x8c, 0x41, 0x11, 0x83, 0x50, 0x10, 0x43, 0xbf, 0x04, 0xbe, 0x03, 0x26, 0x0a, 0x98, 0x59, 0x03, 0xff, 0x10, 0x01, 0x48, 0xe0, 0xb4, 0x67, 0x64, 0xac, 0x38, 0xa0, 0x06, 0x0a, 0x35, 0xd0, 0x16, 0x03, 0xb4, 0x4b, 0x72, 0xca, 0x64, 0xde, 0x4b, 0xa9, 0x15, 0xe8, 0xba, 0xcc, 0x62, 0x06, 0x0c, 0x43, 0xbe, 0x4a, 0xad, 0xee, 0x2a, 0x3f, 0x33, 0xf7, 0x71, 0xcc, 0xbd, 0x40, 0xe9, 0xfb, 0x3c, 0x49, 0xa0, 0xb5, 0x7c, 0x68, 0x70, 0x57, 0xf9, 0x90, 0xee, 0xd3, 0x94, 0xab, 0x14, 0x52, 0xc4, 0x1f, 0x20, 0xa5, 0x7e, 0xcd, 0x48, 0x01, 0x07, 0x15, 0x5d, 0x6c, 0x02, 0x22, 0x34, 0x5c, 0x40, 0x84, 0x86, 0xb7, 0x59, 0x84, 0xcc, 0x27, 0x19, 0x31, 0xcf, 0xb9, 0xdc, 0xf9, 0xab, 0x36, 0x39, 0x30, 0x8e, 0x59, 0x61, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

/// 2x2 grayscale 16-bit with `tRNS` 0x5678 (row-major samples 0x1234,
/// 0x5678, 0x9ABC, 0xDEF0).
const gray16_trns_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x07, 0x4d, 0x8e, 0xbb, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0x56, 0x78, 0xc4, 0xac, 0xce, 0xe4, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x10, 0x32, 0x09, 0xab, 0x60, 0x98, 0xb5, 0xe7, 0xde, 0x07, 0x00, 0x0e, 0xbe, 0x04, 0x39, 0xba, 0x44, 0x60, 0x96, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

/// 3x1 RGB 16-bit with `tRNS` equal to the first pixel's 6 raw sample bytes.
const rgb16_trns_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x10, 0x02, 0x00, 0x00, 0x00, 0xc4, 0x12, 0x5f, 0xa0, 0x00, 0x00, 0x00, 0x06, 0x74, 0x52, 0x4e, 0x53, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0x69, 0x8c, 0xad, 0x28, 0x00, 0x00, 0x00, 0x1b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x54, 0x76, 0x4d, 0xef, 0x5c, 0x2d, 0x28, 0xa8, 0xa4, 0x64, 0x6c, 0xec, 0xe2, 0x12, 0x1a, 0x9a, 0x96, 0x06, 0x00, 0x2a, 0x79, 0x04, 0xcf, 0xe8, 0xb5, 0xe3, 0xc1, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

/// 9x9 1-bit grayscale, Adam7, white where `(x + y)` is odd.
const adam7_gray1_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x01, 0xbf, 0xed, 0x0b, 0x2b, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0xc0, 0x02, 0x3e, 0xc0, 0xe1, 0xaa, 0x06, 0x38, 0x02, 0x00, 0x6c, 0x1e, 0x09, 0x59, 0x60, 0x0b, 0xab, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

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

test "decodes 16-bit RGB by stripping to the high byte" {
    const decoded = try decode(testing.allocator, &png_16bit);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 1), decoded.width);
    try testing.expectEqual(@as(u16, 1), decoded.height);
    // Raw samples are 0x0102, 0x0304, 0x0506; STRIP_16 keeps the high bytes.
    try testing.expectEqualSlices(u8, &.{ 1, 3, 5, 255 }, decoded.pixels);
}

test "decodes 1x1 interlaced grayscale" {
    const decoded = try decode(testing.allocator, &png_interlaced);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 255 }, decoded.pixels);
}

test "deinterlaces Adam7 grayscale across passes and partial edges" {
    const decoded = try decode(testing.allocator, &adam7_gray8_png);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 5), decoded.width);
    try testing.expectEqual(@as(u16, 3), decoded.height);
    const values = [3][5]u8{
        .{ 1, 2, 3, 4, 5 },
        .{ 6, 7, 8, 9, 10 },
        .{ 11, 12, 13, 14, 15 },
    };
    for (values, 0..) |row, y| {
        for (row, 0..) |gray, x| {
            const pixel = decoded.pixels[(y * 5 + x) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, &.{ gray, gray, gray, 255 }, pixel);
        }
    }
}

test "deinterlaces Adam7 16-bit RGBA with strip16" {
    const decoded = try decode(testing.allocator, &adam7_rgba16_png);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 4), decoded.width);
    try testing.expectEqual(@as(u16, 4), decoded.height);
    // Full 16-bit samples are (x+1)*0x1111, (y+1)*0x2222, (x+y+1)*0x1010,
    // 0xFFFF-(16x+y); the decoder keeps the high byte of each.
    const expected = [64]u8{
        0x11, 0x22, 0x10, 0xff, 0x22, 0x22, 0x20, 0xff, 0x33, 0x22, 0x30, 0xff, 0x44, 0x22, 0x40, 0xff,
        0x11, 0x44, 0x20, 0xff, 0x22, 0x44, 0x30, 0xff, 0x33, 0x44, 0x40, 0xff, 0x44, 0x44, 0x50, 0xff,
        0x11, 0x66, 0x30, 0xff, 0x22, 0x66, 0x40, 0xff, 0x33, 0x66, 0x50, 0xff, 0x44, 0x66, 0x60, 0xff,
        0x11, 0x88, 0x40, 0xff, 0x22, 0x88, 0x50, 0xff, 0x33, 0x88, 0x60, 0xff, 0x44, 0x88, 0x70, 0xff,
    };
    try testing.expectEqualSlices(u8, &expected, decoded.pixels);
}

test "16-bit grayscale tRNS compares the raw 16-bit sample" {
    const decoded = try decode(testing.allocator, &gray16_trns_png);
    defer testing.allocator.free(decoded.pixels);
    const expected = [_]u8{
        0x12, 0x12, 0x12, 0xff,
        0x56, 0x56, 0x56, 0x00,
        0x9a, 0x9a, 0x9a, 0xff,
        0xde, 0xde, 0xde, 0xff,
    };
    try testing.expectEqualSlices(u8, &expected, decoded.pixels);
}

test "16-bit RGB tRNS matches the full 6-byte sample" {
    const decoded = try decode(testing.allocator, &rgb16_trns_png);
    defer testing.allocator.free(decoded.pixels);
    try testing.expectEqual(@as(u16, 3), decoded.width);
    const expected = [_]u8{
        0x01, 0x45, 0x89, 0x00,
        0x11, 0x22, 0x33, 0xff,
        0x44, 0x55, 0x66, 0xff,
    };
    try testing.expectEqualSlices(u8, &expected, decoded.pixels);
}

test "deinterlaces sub-byte grayscale Adam7" {
    const decoded = try decode(testing.allocator, &adam7_gray1_png);
    defer testing.allocator.free(decoded.pixels);
    var y: usize = 0;
    while (y < 9) : (y += 1) {
        var x: usize = 0;
        while (x < 9) : (x += 1) {
            const gray: u8 = if ((x + y) % 2 == 1) 255 else 0;
            const pixel = decoded.pixels[(y * 9 + x) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, &.{ gray, gray, gray, 255 }, pixel);
        }
    }
}

test "typed errors for malformed PNGs" {
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

    // A stream that inflates beyond the image's row data is rejected by the
    // decompression cap instead of being silently truncated.
    try testing.expectError(error.InvalidData, decode(testing.allocator, &png_oversized));
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
