//! Canonical dump writers for the oracle comparison.
//!
//! The text format is shared byte-for-byte with
//! `tools/oracle-rs --dump-glyphs` / `--dump-cmap` (see its module docs):
//! coordinates are f32 bit patterns in lowercase hex, integers are decimal.
//! `tools/compare_glyphs.sh` diffs the two outputs and
//! `tests/fixtures/glyphs/manifest.zig` stores SHA-256 hashes of the pinned
//! oracle dumps so `zig build test` can guard the port without a Rust
//! toolchain.

const std = @import("std");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const outlines_mod = @import("outlines.zig");
const pen_mod = @import("pen.zig");

pub const Error = outlines_mod.DrawError || std.Io.Writer.Error;

fn optF32Hex(value: ?f32, buf: *[8]u8) []const u8 {
    const bits = @as(u32, @bitCast(value orelse return "none"));
    return std.fmt.bufPrint(buf, "{x:0>8}", .{bits}) catch unreachable;
}

/// Writes the canonical `--dump-glyphs` text for `gids`.
///
/// `hint` runs the TrueType interpreter (`glifo`'s `HintingOptions`) instead
/// of the unhinted scaler and emits the extra `hint 1` marker line.
pub fn writeGlyphDump(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    outlines: *const outlines_mod.Outlines,
    font_index: u32,
    size: f32,
    hint: bool,
    gids: []const u32,
) Error!void {
    try writer.print("vellz-glyph-dump v1\n", .{});
    try writer.print("face {d}\n", .{font_index});
    try writer.print("size {x:0>8}\n", .{@as(u32, @bitCast(size))});
    if (hint) try writer.print("hint 1\n", .{});

    var instance: ?glyf.HintInstance = null;
    defer if (instance) |*inst| inst.deinit();
    if (hint) {
        instance = try outlines.createHintInstance(allocator, size, glyf.glifo_hint_target);
    }

    var pen = pen_mod.PathElementPen.init(allocator);
    defer pen.deinit();
    for (gids) |gid| {
        pen.clearRetainingCapacity();
        const metrics = try outlines.draw(allocator, gid, .{
            .size = size,
            .hint_instance = if (instance) |*inst| inst else null,
        }, &pen);
        var lsb_buf: [8]u8 = undefined;
        var advance_buf: [8]u8 = undefined;
        try writer.print("gid {d} format {s} elems {d} lsb {s} advance {s}\n", .{
            gid,
            outlines.formatName(),
            pen.elements.items.len,
            optF32Hex(metrics.lsb, &lsb_buf),
            optF32Hex(metrics.advance_width, &advance_buf),
        });
        for (pen.elements.items) |element| {
            switch (element) {
                .move_to => |p| try writer.print("M {x:0>8} {x:0>8}\n", .{
                    @as(u32, @bitCast(p[0])),
                    @as(u32, @bitCast(p[1])),
                }),
                .line_to => |p| try writer.print("L {x:0>8} {x:0>8}\n", .{
                    @as(u32, @bitCast(p[0])),
                    @as(u32, @bitCast(p[1])),
                }),
                .quad_to => |q| try writer.print("Q {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
                    @as(u32, @bitCast(q.c0[0])),
                    @as(u32, @bitCast(q.c0[1])),
                    @as(u32, @bitCast(q.p[0])),
                    @as(u32, @bitCast(q.p[1])),
                }),
                .curve_to => |c| try writer.print(
                    "C {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n",
                    .{
                        @as(u32, @bitCast(c.c0[0])),
                        @as(u32, @bitCast(c.c0[1])),
                        @as(u32, @bitCast(c.c1[0])),
                        @as(u32, @bitCast(c.c1[1])),
                        @as(u32, @bitCast(c.p[0])),
                        @as(u32, @bitCast(c.p[1])),
                    },
                ),
                .close => try writer.print("Z\n", .{}),
            }
        }
    }
    try writer.print("end\n", .{});
}

/// Writes the canonical `--dump-cmap` text for `codepoints`.
pub fn writeCmapDump(
    writer: *std.Io.Writer,
    font_index: u32,
    charmap: font_mod.Charmap,
    codepoints: []const u32,
) std.Io.Writer.Error!void {
    try writer.print("vellz-cmap-dump v1\n", .{});
    try writer.print("face {d}\n", .{font_index});
    try writer.print("has_map {d} is_symbol {d}\n", .{
        @intFromBool(charmap.hasMap()),
        @intFromBool(charmap.isSymbol()),
    });
    for (codepoints) |codepoint| {
        if (charmap.map(codepoint)) |gid| {
            try writer.print("cp {d} gid {d}\n", .{ codepoint, gid });
        } else {
            try writer.print("cp {d} gid none\n", .{codepoint});
        }
    }
    try writer.print("end\n", .{});
}

/// Number of f32 coordinates in a canonical glyph dump.
pub fn countCoordinates(text: []const u8) usize {
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        total += switch (line[0]) {
            'M', 'L' => 2,
            'Q' => 4,
            'C' => 6,
            else => 0,
        };
    }
    return total;
}

// --------------------------------------------------------------------- tests

const fixture = @import("test_fixture.zig");
const manifest = @import("glyph_manifest");

fn fontBlob(font_id: u8) ![]const u8 {
    return switch (font_id) {
        manifest.font_roboto => try fixture.roboto(),
        manifest.font_noto => try fixture.notoColor(),
        manifest.font_noto_cbtf => try fixture.notoCbtf(),
        manifest.font_source_serif => try fixture.sourceSerif(),
        manifest.font_source_serif_variable => try fixture.sourceSerifVariable(),
        else => error.TestUnexpectedResult,
    };
}

fn dumpGlyphVector(allocator: std.mem.Allocator, vector: manifest.GlyphVector) ![]u8 {
    const blob = try fontBlob(vector.font);
    const font = try font_mod.Font.init(blob, 0);
    const outlines = try font.outlines();
    var gids: std.ArrayList(u32) = .empty;
    defer gids.deinit(allocator);
    var gid = vector.gid_start;
    while (gid <= vector.gid_end) : (gid += 1) try gids.append(allocator, gid);
    var allocating = std.Io.Writer.Allocating.init(allocator);
    errdefer allocating.deinit();
    try writeGlyphDump(
        &allocating.writer,
        allocator,
        &outlines,
        0,
        @bitCast(vector.size_bits),
        vector.hint,
        gids.items,
    );
    return allocating.toOwnedSlice();
}

fn dumpCmapVector(allocator: std.mem.Allocator, vector: manifest.CmapVector) ![]u8 {
    const blob = try fontBlob(vector.font);
    const font = try font_mod.Font.init(blob, 0);
    var codepoints: std.ArrayList(u32) = .empty;
    defer codepoints.deinit(allocator);
    var codepoint = vector.cp_start;
    while (codepoint <= vector.cp_end) : (codepoint += 1) {
        try codepoints.append(allocator, codepoint);
    }
    var allocating = std.Io.Writer.Allocating.init(allocator);
    errdefer allocating.deinit();
    try writeCmapDump(&allocating.writer, 0, font.charmap(), codepoints.items);
    return allocating.toOwnedSlice();
}

fn sha256(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

test "oracle glyph dump hashes match the committed manifest" {
    try std.testing.expect(manifest.glyph_vectors.len >= 6);
    var total_coordinates: usize = 0;
    var total_elements: usize = 0;
    for (manifest.glyph_vectors) |vector| {
        const text = try dumpGlyphVector(std.testing.allocator, vector);
        defer std.testing.allocator.free(text);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        std.testing.expectEqualSlices(u8, &vector.sha256, &digest) catch |err| {
            std.debug.print(
                "glyph dump mismatch for font {d} size_bits {x} gids {d}-{d}\n",
                .{ vector.font, vector.size_bits, vector.gid_start, vector.gid_end },
            );
            return err;
        };
        const coordinates = countCoordinates(text);
        try std.testing.expectEqual(vector.coordinates, coordinates);
        total_coordinates += coordinates;
        total_elements += vector.elements;
    }
    // The committed corpus must stay substantial: the point of T2 is bit
    // exactness over thousands of coordinates, not a handful.
    try std.testing.expect(total_coordinates >= 100_000);
    try std.testing.expect(total_elements >= 30_000);
}

test "oracle cmap dump hashes match the committed manifest" {
    try std.testing.expect(manifest.cmap_vectors.len >= 2);
    for (manifest.cmap_vectors) |vector| {
        const text = try dumpCmapVector(std.testing.allocator, vector);
        defer std.testing.allocator.free(text);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        std.testing.expectEqualSlices(u8, &vector.sha256, &digest) catch |err| {
            std.debug.print(
                "cmap dump mismatch for font {d} codepoints {d}-{d}\n",
                .{ vector.font, vector.cp_start, vector.cp_end },
            );
            return err;
        };
        try std.testing.expectEqual(vector.count, (vector.cp_end - vector.cp_start + 1));
    }
}
