//! The `hmtx` (horizontal metrics) table.
//!
//! Port of the `read-fonts` 0.41.0 `Hmtx` accessors: `advance` falls back to
//! the last long metric, `side_bearing` falls back to the trailing `i16`
//! array, and a table too short for the advertised `numberOfHMetrics` reads as
//! empty rather than an error (upstream `read_array(..).ok().unwrap_or_default()`).

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const LongMetric = struct {
    advance: u16,
    lsb: i16,
};

pub const Hmtx = struct {
    data: []const u8,
    num_h_metrics: u16,

    pub fn parse(data: []const u8, num_h_metrics: u16) Hmtx {
        return .{ .data = data, .num_h_metrics = num_h_metrics };
    }

    /// The `hMetrics` bytes, or empty when the advertised array does not fit.
    fn metricsBytes(self: Hmtx) []const u8 {
        const end = @as(usize, self.num_h_metrics) * 4;
        if (end > self.data.len) return &.{};
        return self.data[0..end];
    }

    /// The trailing `leftSideBearings` bytes, or empty when out of range.
    fn lsbsBytes(self: Hmtx) []const u8 {
        const start = @as(usize, self.num_h_metrics) * 4;
        if (start > self.data.len) return &.{};
        const usable = (self.data.len - start) & ~@as(usize, 1);
        return self.data[start .. start + usable];
    }

    pub fn longMetricCount(self: Hmtx) usize {
        return self.metricsBytes().len / 4;
    }

    pub fn longMetric(self: Hmtx, gid: u32) ?LongMetric {
        const metrics = self.metricsBytes();
        const ix = @as(usize, gid) * 4;
        if (ix + 4 > metrics.len) return null;
        return .{
            .advance = sfnt.readU16(metrics, ix).?,
            .lsb = sfnt.readI16(metrics, ix + 2).?,
        };
    }

    fn lastLongMetric(self: Hmtx) ?LongMetric {
        const count = self.longMetricCount();
        if (count == 0) return null;
        return self.longMetric(@intCast(count - 1));
    }

    /// Advance width in font units, matching `Hmtx::advance`.
    pub fn advance(self: Hmtx, gid: u32) ?u16 {
        if (self.longMetric(gid)) |metric| return metric.advance;
        return if (self.lastLongMetric()) |metric| metric.advance else null;
    }

    /// Left side bearing in font units, matching `Hmtx::side_bearing`.
    pub fn sideBearing(self: Hmtx, gid: u32) ?i16 {
        if (self.longMetric(gid)) |metric| return metric.lsb;
        const metrics = self.metricsBytes();
        const metric_count = metrics.len / 4;
        const ix: usize = if (gid >= metric_count) gid - metric_count else 0;
        const lsbs = self.lsbsBytes();
        const off = ix * 2;
        if (off + 2 > lsbs.len) return null;
        return sfnt.readI16(lsbs, off).?;
    }
};

test "hmtx metrics of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const maxp = try @import("maxp.zig").Maxp.parse(face.table(sfnt.tag_maxp).?);
    try std.testing.expectEqual(@as(u16, 1294), maxp.numGlyphs());
    const hhea = try @import("hhea.zig").Hhea.parse(face.table(sfnt.tag_hhea).?);
    const hmtx = Hmtx.parse(face.table(sfnt.tag_hmtx).?, hhea.numberOfHMetrics());
    try std.testing.expectEqual(@as(usize, 1294), hmtx.longMetricCount());
    // 'A' is glyph 37 in Roboto; see the oracle cmap dump.
    try std.testing.expectEqual(@as(?u16, 1336), hmtx.advance(37));
    try std.testing.expectEqual(@as(?i16, 28), hmtx.sideBearing(37));
    // Past the last long metric, `advance` repeats the last one.
    try std.testing.expectEqual(@as(?u16, 506), hmtx.advance(1294));
    try std.testing.expectEqual(@as(?i16, null), hmtx.sideBearing(1294));
}

test "hmtx with a truncated metrics array reads as empty" {
    // Two advertised long metrics but only one fits: upstream drops the whole
    // array and every lookup misses.
    const bytes = [_]u8{ 0, 1, 0, 2 };
    const hmtx = Hmtx.parse(&bytes, 2);
    try std.testing.expectEqual(@as(?u16, null), hmtx.advance(0));
}
