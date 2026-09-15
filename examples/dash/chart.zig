//! The "Total Visitors" stacked area chart, generated as an SVG and
//! rasterized by zui's SVG image path.
//!
//! The series are stacked like recharts' `stackId="a"`: the mobile band is
//! drawn first from the baseline, the desktop band is stacked on top of it.
//! Both curves are natural cubic splines through the raw 91 points, matching
//! recharts' `type="natural"` interpolation.

const std = @import("std");

const assets = @import("icons.zig");
const data = @import("data.zig");

/// The chart's internal SVG width; the element stretches it to fit.
const SVG_W: f32 = 1200;

/// Working space for the spline solve (the full series).
const MAX_POINTS = 91;

const Series = struct {
    values: [MAX_POINTS]f64,
    /// Second derivatives of the natural spline over the vertex index.
    second: [MAX_POINTS]f64,
};

fn solveNatural(values: *const [MAX_POINTS]f64, second: *[MAX_POINTS]f64, n: usize) void {
    // Natural cubic spline with uniform spacing (h = 1):
    //   M[i-1] + 4 M[i] + M[i+1] = 6 (y[i+1] - 2y[i] + y[i-1])
    // with M[0] = M[n-1] = 0.
    var b: [MAX_POINTS]f64 = undefined;
    var d: [MAX_POINTS]f64 = undefined;
    b[0] = 1;
    second[0] = 0;
    var i: usize = 1;
    while (i < n - 1) : (i += 1) {
        b[i] = 4;
        d[i] = 6 * (values[i + 1] - 2 * values[i] + values[i - 1]);
    }
    b[n - 1] = 1;
    d[n - 1] = 0;
    i = 1;
    while (i < n) : (i += 1) {
        const m = 1.0 / b[i - 1];
        b[i] -= m;
        d[i] -= m * d[i - 1];
    }
    second[n - 1] = 0;
    i = n - 1;
    while (i > 0) {
        i -= 1;
        second[i] = (d[i] - second[i + 1]) / b[i];
    }
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, format, args);
    try list.appendSlice(allocator, text);
}

/// Append an area path: the spline along `series` on top, closed down to the
/// given baseline (pixel y).
fn appendArea(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    series: *const Series,
    n: usize,
    x0: f32,
    dx: f32,
    ys: *const [MAX_POINTS]f64,
    baseline: f32,
) !void {
    try appendFmt(out, allocator, "M {d:.1} {d:.1} ", .{ x0, ys[0] });
    var i: usize = 0;
    while (i < n - 1) : (i += 1) {
        const x_a = x0 + @as(f32, @floatFromInt(i)) * dx;
        const x_b = x_a + dx;
        const y_a = ys[i];
        const y_b = ys[i + 1];
        const b = (y_b - y_a) - (2 * series.second[i] + series.second[i + 1]) / 6.0;
        const m1 = b + (series.second[i] + series.second[i + 1]) / 2.0;
        try appendFmt(out, allocator, "C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} ", .{
            x_a + dx / 3.0,
            y_a + b / 3.0,
            x_b - dx / 3.0,
            y_b - m1 / 3.0,
            x_b,
            y_b,
        });
    }
    try appendFmt(out, allocator, "L {d:.1} {d:.1} Z ", .{ x0 + @as(f32, @floatFromInt(n - 1)) * dx, baseline });
}

/// Append just the curve (no fill), for the stroke on top of each band.
fn appendCurve(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    series: *const Series,
    n: usize,
    x0: f32,
    dx: f32,
    ys: *const [MAX_POINTS]f64,
) !void {
    try appendFmt(out, allocator, "M {d:.1} {d:.1} ", .{ x0, ys[0] });
    var i: usize = 0;
    while (i < n - 1) : (i += 1) {
        const x_a = x0 + @as(f32, @floatFromInt(i)) * dx;
        const x_b = x_a + dx;
        const y_a = ys[i];
        const y_b = ys[i + 1];
        const b = (y_b - y_a) - (2 * series.second[i] + series.second[i + 1]) / 6.0;
        const m1 = b + (series.second[i] + series.second[i + 1]) / 2.0;
        try appendFmt(out, allocator, "C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} ", .{
            x_a + dx / 3.0,
            y_a + b / 3.0,
            x_b - dx / 3.0,
            y_b - m1 / 3.0,
            x_b,
            y_b,
        });
    }
}

/// Build the chart SVG for the given series window.
pub fn build(allocator: std.mem.Allocator, days: []const data.Day, svg_h: f32) ![]u8 {
    var n = days.len;
    if (n > MAX_POINTS) n = MAX_POINTS;

    // Convert to pixel space: the y domain is niced to 250-unit steps, like
    // recharts' automatic ticks (our data peaks at 1018, so 1250).
    var peak: u32 = 0;
    for (days[0..n]) |day| {
        if (day.total() > peak) peak = day.total();
    }
    var domain: f32 = 1250;
    if (peak > 1250) {
        domain = @floatFromInt((peak + 249) / 250 * 250);
    }

    const left: f32 = 10;
    const right: f32 = SVG_W - 10;
    const top: f32 = 8;
    const bottom: f32 = svg_h - 8;

    var total = Series{ .values = undefined, .second = undefined };
    var mobile = Series{ .values = undefined, .second = undefined };
    for (days[0..n], 0..) |day, i| {
        total.values[i] = bottom - @as(f64, @floatFromInt(day.total())) / domain * (bottom - top);
        mobile.values[i] = bottom - @as(f64, @floatFromInt(day.mobile)) / domain * (bottom - top);
    }
    solveNatural(&total.values, &total.second, n);
    solveNatural(&mobile.values, &mobile.second, n);

    const dx = (right - left) / @as(f32, @floatFromInt(@max(n, 2) - 1));

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // nanosvg treats gradient stop coordinates as user-space units (it does
    // not honour the objectBoundingBox default), so each band's gradient is
    // anchored to that band's own bounding box explicitly.
    var total_top: f64 = bottom;
    var mobile_top: f64 = bottom;
    for (days[0..n], 0..) |_, i| {
        if (total.values[i] < total_top) total_top = total.values[i];
        if (mobile.values[i] < mobile_top) mobile_top = mobile.values[i];
    }

    try appendFmt(&out, allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d:.1}\" viewBox=\"0 0 {d} {d:.1}\">", .{ SVG_W, svg_h, SVG_W, svg_h });
    try appendFmt(&out, allocator, "<defs>" ++
        "<linearGradient id=\"gTotal\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"{d:.1}\" x2=\"0\" y2=\"{d:.1}\">" ++
        "<stop offset=\"0\" stop-color=\"#a6a6a6\"/>" ++
        "<stop offset=\"1\" stop-color=\"#2c2c2c\"/>" ++
        "</linearGradient>" ++
        "<linearGradient id=\"gMobile\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"{d:.1}\" x2=\"0\" y2=\"{d:.1}\">" ++
        "<stop offset=\"0\" stop-color=\"#949494\"/>" ++
        "<stop offset=\"1\" stop-color=\"#2e2e2e\"/>" ++
        "</linearGradient>" ++
        "</defs>", .{ total_top, bottom, mobile_top, bottom });

    // Horizontal gridlines at 250-unit ticks (the target's faint rules).
    var tick: u32 = 250;
    while (tick <= 1000) : (tick += 250) {
        const y = bottom - @as(f32, @floatFromInt(tick)) / domain * (bottom - top);
        try appendFmt(&out, allocator, "<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#262626\" stroke-width=\"1\"/>", .{ left, y, right, y });
    }

    // Areas: total first, then the mobile band stacked over it.
    try out.appendSlice(allocator, "<path d=\"");
    try appendArea(&out, allocator, &total, n, left, dx, &total.values, bottom);
    try out.appendSlice(allocator, "\" fill=\"url(#gTotal)\" stroke=\"none\"/>");
    try out.appendSlice(allocator, "<path d=\"");
    try appendArea(&out, allocator, &mobile, n, left, dx, &mobile.values, bottom);
    try out.appendSlice(allocator, "\" fill=\"url(#gMobile)\" stroke=\"none\"/>");

    // Strokes on top so both boundaries stay crisp.
    try out.appendSlice(allocator, "<path d=\"");
    try appendCurve(&out, allocator, &total, n, left, dx, &total.values);
    try out.appendSlice(allocator, "\" fill=\"none\" stroke=\"#e8e8e8\" stroke-width=\"1.6\"/>");
    try out.appendSlice(allocator, "<path d=\"");
    try appendCurve(&out, allocator, &mobile, n, left, dx, &mobile.values);
    try out.appendSlice(allocator, "\" fill=\"none\" stroke=\"#e8e8e8\" stroke-width=\"1.6\"/>");

    try out.appendSlice(allocator, "</svg>");
    return out.toOwnedSlice(allocator);
}

test "chart builds with stacked series" {
    const allocator = std.testing.allocator;
    const svg = try build(allocator, &data.DAYS, 260.0);
    defer allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "url(#gTotal)") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "url(#gMobile)") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "C ") != null);
}
