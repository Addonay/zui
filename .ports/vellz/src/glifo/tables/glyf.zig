//! The `glyf` (glyph data) table: raw glyph parsing.
//!
//! Port of the `read-fonts` 0.41.0 generated `Glyph`/`SimpleGlyph`/
//! `CompositeGlyph` accessors. Degenerate ranges read as empty instead of
//! erroring, exactly like the upstream generated `read_array(..).ok()
//! .unwrap_or_default()` accessors; the outline scaler in `glifo/glyf.zig`
//! then decides what a malformed glyph means.

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const flag_on_curve_point: u8 = 0x01;
pub const flag_x_short_vector: u8 = 0x02;
pub const flag_y_short_vector: u8 = 0x04;
pub const flag_repeat: u8 = 0x08;
pub const flag_x_same_or_positive: u8 = 0x10;
pub const flag_y_same_or_positive: u8 = 0x20;
pub const flag_overlap_simple: u8 = 0x40;
pub const flag_cubic: u8 = 0x80;

pub const composite_arg_1_and_2_are_words: u16 = 0x0001;
pub const composite_args_are_xy_values: u16 = 0x0002;
pub const composite_round_xy_to_grid: u16 = 0x0004;
pub const composite_we_have_a_scale: u16 = 0x0008;
pub const composite_more_components: u16 = 0x0020;
pub const composite_we_have_an_x_and_y_scale: u16 = 0x0040;
pub const composite_we_have_a_two_by_two: u16 = 0x0080;
pub const composite_we_have_instructions: u16 = 0x0100;
pub const composite_use_my_metrics: u16 = 0x0200;
pub const composite_overlap_compound: u16 = 0x0400;
pub const composite_scaled_component_offset: u16 = 0x0800;
pub const composite_unscaled_component_offset: u16 = 0x1000;

/// The `glyf` table.
pub const Glyf = struct {
    data: []const u8,

    pub fn parse(data: []const u8) Glyf {
        return .{ .data = data };
    }
};

pub const GlyphKind = enum { simple, composite };

/// A parsed glyph header plus its raw bytes.
pub const Glyph = struct {
    kind: GlyphKind,
    data: []const u8,

    pub fn parse(data: []const u8) sfnt.Error!Glyph {
        if (data.len < 10) return error.Truncated;
        const number_of_contours = sfnt.readI16(data, 0).?;
        return .{
            .kind = if (number_of_contours >= 0) .simple else .composite,
            .data = data,
        };
    }

    pub fn numberOfContours(self: Glyph) i16 {
        return sfnt.readI16(self.data, 0).?;
    }

    pub fn xMin(self: Glyph) i16 {
        return sfnt.readI16(self.data, 2).?;
    }

    pub fn yMin(self: Glyph) i16 {
        return sfnt.readI16(self.data, 4).?;
    }

    pub fn xMax(self: Glyph) i16 {
        return sfnt.readI16(self.data, 6).?;
    }

    pub fn yMax(self: Glyph) i16 {
        return sfnt.readI16(self.data, 8).?;
    }

    pub fn bounds(self: Glyph) [4]i16 {
        return .{ self.xMin(), self.xMax(), self.yMin(), self.yMax() };
    }

    pub fn simple(self: Glyph) SimpleGlyph {
        return .{ .data = self.data };
    }

    pub fn composite(self: Glyph) CompositeGlyph {
        return .{ .data = self.data };
    }
};

pub const SimpleGlyph = struct {
    data: []const u8,

    pub fn numberOfContours(self: SimpleGlyph) i16 {
        return sfnt.readI16(self.data, 0).?;
    }

    /// End of the end-point array (whether or not those bytes exist).
    fn endPtsEnd(self: SimpleGlyph) usize {
        const contours: usize = @intCast(self.numberOfContours());
        return 10 + 2 * contours;
    }

    /// Number of contour end points that are actually present.
    pub fn contourCount(self: SimpleGlyph) usize {
        const end = self.endPtsEnd();
        if (end > self.data.len) return 0;
        return @intCast(self.numberOfContours());
    }

    pub fn endPoint(self: SimpleGlyph, i: usize) ?u16 {
        if (i >= self.contourCount()) return null;
        return sfnt.readU16(self.data, 10 + 2 * i);
    }

    /// Total number of points, matching upstream `num_points`.
    pub fn numPoints(self: SimpleGlyph) usize {
        const count = self.contourCount();
        if (count == 0) return 0;
        const last = self.endPoint(count - 1) orelse return 0;
        return @as(usize, last) + 1;
    }

    pub fn instructionLength(self: SimpleGlyph) u16 {
        return sfnt.readU16(self.data, self.endPtsEnd()) orelse 0;
    }

    pub fn instructions(self: SimpleGlyph) []const u8 {
        const start = self.endPtsEnd() + 2;
        const len = @as(usize, self.instructionLength());
        if (start > self.data.len or start + len > self.data.len) return &.{};
        return self.data[start .. start + len];
    }

    fn glyphDataStart(self: SimpleGlyph) usize {
        return self.endPtsEnd() + 2 + @as(usize, self.instructionLength());
    }

    /// Raw flags/x/y bytes after the instructions.
    pub fn glyphData(self: SimpleGlyph) []const u8 {
        const start = self.glyphDataStart();
        if (start >= self.data.len) return &.{};
        return self.data[start..];
    }

    pub fn hasOverlappingContours(self: SimpleGlyph) bool {
        const data = self.glyphData();
        if (data.len == 0) return false;
        return (data[0] & flag_overlap_simple) != 0;
    }
};

pub const Anchor = union(enum) {
    offset: struct { x: i16, y: i16 },
    point: struct { base: u16, component: u16 },
};

/// F2Dot14 bits; the default is the identity matrix.
pub const Transform = struct {
    xx: i16 = 0x4000,
    yx: i16 = 0,
    xy: i16 = 0,
    yy: i16 = 0x4000,
};

pub const Component = struct {
    flags: u16,
    glyph: u16,
    anchor: Anchor,
    transform: Transform,
};

pub const CompositeGlyph = struct {
    data: []const u8,

    pub fn numberOfContours(self: CompositeGlyph) i16 {
        return sfnt.readI16(self.data, 0).?;
    }

    pub fn componentData(self: CompositeGlyph) []const u8 {
        if (self.data.len <= 10) return &.{};
        return self.data[10..];
    }

    pub fn componentIterator(self: CompositeGlyph) ComponentIterator {
        return .{ .data = self.componentData() };
    }

    pub const CountAndInstructions = struct {
        count: usize,
        instructions: ?[]const u8,
    };

    /// Component count plus the trailing instructions, mirroring upstream
    /// `count_and_instructions` (single pass, instructions read after the last
    /// component when `WE_HAVE_INSTRUCTIONS` is set).
    pub fn countAndInstructions(self: CompositeGlyph) CountAndInstructions {
        var it = self.componentIterator();
        var count: usize = 0;
        while (it.next() != null) count += 1;
        var instructions: ?[]const u8 = null;
        if ((it.last_flags & composite_we_have_instructions) != 0) {
            if (sfnt.readU16(it.data, it.cursor)) |len| {
                const start = it.cursor + 2;
                const end = start + @as(usize, len);
                if (end <= it.data.len) instructions = it.data[start..end];
            }
        }
        return .{ .count = count, .instructions = instructions };
    }
};

pub const ComponentIterator = struct {
    data: []const u8,
    cursor: usize = 0,
    done: bool = false,
    last_flags: u16 = 0,

    pub fn next(self: *ComponentIterator) ?Component {
        if (self.done) return null;
        const flags = sfnt.readU16(self.data, self.cursor) orelse {
            self.done = true;
            return null;
        };
        self.last_flags = flags;
        self.cursor += 2;
        const glyph = sfnt.readU16(self.data, self.cursor) orelse {
            self.done = true;
            return null;
        };
        self.cursor += 2;
        const words = (flags & composite_arg_1_and_2_are_words) != 0;
        const xy = (flags & composite_args_are_xy_values) != 0;
        var anchor: Anchor = undefined;
        if (xy) {
            if (words) {
                const x = sfnt.readI16(self.data, self.cursor) orelse {
                    self.done = true;
                    return null;
                };
                const y = sfnt.readI16(self.data, self.cursor + 2) orelse {
                    self.done = true;
                    return null;
                };
                self.cursor += 4;
                anchor = .{ .offset = .{ .x = x, .y = y } };
            } else {
                if (self.cursor + 2 > self.data.len) {
                    self.done = true;
                    return null;
                }
                const x: i16 = @as(i8, @bitCast(self.data[self.cursor]));
                const y: i16 = @as(i8, @bitCast(self.data[self.cursor + 1]));
                self.cursor += 2;
                anchor = .{ .offset = .{ .x = x, .y = y } };
            }
        } else {
            if (words) {
                const base = sfnt.readU16(self.data, self.cursor) orelse {
                    self.done = true;
                    return null;
                };
                const component = sfnt.readU16(self.data, self.cursor + 2) orelse {
                    self.done = true;
                    return null;
                };
                self.cursor += 4;
                anchor = .{ .point = .{ .base = base, .component = component } };
            } else {
                if (self.cursor + 2 > self.data.len) {
                    self.done = true;
                    return null;
                }
                const base: u16 = self.data[self.cursor];
                const component: u16 = self.data[self.cursor + 1];
                self.cursor += 2;
                anchor = .{ .point = .{ .base = base, .component = component } };
            }
        }
        var transform = Transform{};
        if ((flags & composite_we_have_a_scale) != 0) {
            const xx = sfnt.readI16(self.data, self.cursor) orelse {
                self.done = true;
                return null;
            };
            self.cursor += 2;
            transform.xx = xx;
            transform.yy = xx;
        } else if ((flags & composite_we_have_an_x_and_y_scale) != 0) {
            const xx = sfnt.readI16(self.data, self.cursor) orelse {
                self.done = true;
                return null;
            };
            const yy = sfnt.readI16(self.data, self.cursor + 2) orelse {
                self.done = true;
                return null;
            };
            self.cursor += 4;
            transform.xx = xx;
            transform.yy = yy;
        } else if ((flags & composite_we_have_a_two_by_two) != 0) {
            const t_xx = sfnt.readI16(self.data, self.cursor) orelse {
                self.done = true;
                return null;
            };
            const t_yx = sfnt.readI16(self.data, self.cursor + 2) orelse {
                self.done = true;
                return null;
            };
            const t_xy = sfnt.readI16(self.data, self.cursor + 4) orelse {
                self.done = true;
                return null;
            };
            const t_yy = sfnt.readI16(self.data, self.cursor + 6) orelse {
                self.done = true;
                return null;
            };
            self.cursor += 8;
            transform.xx = t_xx;
            transform.yx = t_yx;
            transform.xy = t_xy;
            transform.yy = t_yy;
        }
        self.done = (flags & composite_more_components) == 0;
        return .{
            .flags = flags,
            .glyph = glyph,
            .anchor = anchor,
            .transform = transform,
        };
    }
};

test "simple glyph 37 ('A') of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const head = try @import("head.zig").Head.parse(face.table(sfnt.tag_head).?);
    const loca = @import("loca.zig").Loca.parse(
        face.table(sfnt.tag_loca).?,
        head.indexToLocFormat() == 1,
    );
    const bytes = (try loca.glyphBytes(37, face.table(sfnt.tag_glyf).?)).?;
    const glyph = try Glyph.parse(bytes);
    try std.testing.expectEqual(GlyphKind.simple, glyph.kind);
    const simple = glyph.simple();
    try std.testing.expectEqual(@as(i16, 2), simple.numberOfContours());
    try std.testing.expectEqual(@as(usize, 2), simple.contourCount());
    try std.testing.expectEqual(@as(usize, 11), simple.numPoints());
    try std.testing.expectEqual(@as(u16, 84), simple.instructionLength());
    try std.testing.expect(!simple.hasOverlappingContours());
    try std.testing.expect(simple.glyphData().len > 0);
}

test "composite glyphs expose components and instructions" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const head = try @import("head.zig").Head.parse(face.table(sfnt.tag_head).?);
    const loca = @import("loca.zig").Loca.parse(
        face.table(sfnt.tag_loca).?,
        head.indexToLocFormat() == 1,
    );
    const glyf = face.table(sfnt.tag_glyf).?;
    // Find the first composite glyph (there are accented Latin composites in
    // the Latin-1 range).
    var gid: u32 = 1;
    while (gid < 300) : (gid += 1) {
        const bytes = (loca.glyphBytes(gid, glyf) catch continue) orelse continue;
        const glyph = Glyph.parse(bytes) catch continue;
        if (glyph.kind != .composite) continue;
        const instructions = glyph.composite().countAndInstructions();
        try std.testing.expect(instructions.count >= 2);
        break;
    } else return error.SkipZigTest;
    try std.testing.expect(gid < 300);
}
