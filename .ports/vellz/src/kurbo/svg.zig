//! Port of kurbo 0.13.1 `svg.rs` (Apache-2.0 OR MIT).
//!
//! Best-effort SVG path data parser (`BezPath::from_svg` equivalent), the
//! inverse serializer (`toSvg`), and `fromPathSegments`.
//!
//! The SVG arc commands are converted to cubics with the same math as
//! upstream's `Arc::from_svg_arc` + `Arc::to_cubic_beziers(0.1, ...)`. `Arc`
//! itself is out of this port's scope, so the arc implementation here is
//! private; only `SvgArc` is exported, matching upstream's public type.
//!
//! Adaptations:
//! - Input is `[]const u8` (ASCII path data) rather than `&str`.
//! - Zig error sets cannot carry the offending character, so
//!   `error.UnknownCommand` has no payload (upstream `UnknownCommand(char)`).
//! - `toSvg` uses Zig's `{d}` float formatting, which matches Rust's default
//!   `Display` (plain decimal) for the values used by path data.

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;
const PathSeg = bezpath.PathSeg;

const PI = std.math.pi;
const FRAC_PI_2 = std.math.pi / 2.0;

/// An error which can be returned when parsing an SVG.
pub const SvgParseError = error{
    /// A number was expected.
    Wrong,
    /// The input string ended while still expecting input.
    UnexpectedEof,
    /// Encountered an unknown command letter.
    UnknownCommand,
    /// Encountered a command that precedes the expected 'moveto' command.
    UninitializedPath,
};

/// A single SVG arc segment.
pub const SvgArc = struct {
    /// The arc's start point.
    from: Point,
    /// The arc's end point.
    to: Point,
    /// The arc's radii, where the vector's x-component is the radius in the
    /// positive x direction after applying `x_rotation`.
    radii: Vec2,
    /// How much the arc is rotated, in radians.
    x_rotation: f64,
    /// Does this arc sweep through more than π radians?
    large_arc: bool,
    /// Determines if the arc should begin moving at positive angles.
    sweep: bool,

    /// Checks that arc is actually a straight line.
    ///
    /// In this case, it can be replaced with a `LineTo`.
    pub fn isStraightLine(self: SvgArc) bool {
        return @abs(self.radii.x) <= 1e-5 or @abs(self.radii.y) <= 1e-5 or
            (self.from.x == self.to.x and self.from.y == self.to.y);
    }
};

/// Try to parse a bezier path from an SVG path element.
///
/// This is implemented on a best-effort basis, intended for cases where the
/// user controls the source of paths, and is not intended as a replacement
/// for a general, robust SVG parser.
///
/// Allocates with `allocator`; the caller owns the result.
pub fn parseSvg(allocator: std.mem.Allocator, data: []const u8) !BezPath {
    var lexer = SvgLexer{ .data = data, .ix = 0, .last_pt = Point.ORIGIN };
    var path = BezPath.init();
    errdefer path.deinit(allocator);
    var last_cmd: u8 = 0;
    var last_ctrl: ?Point = null;
    var first_pt = Point.ORIGIN;
    var implicit_moveto: ?Point = null;
    while (lexer.getCmd(last_cmd)) |c| {
        if (c != 'm' and c != 'M') {
            if (path.elementsSlice().len == 0) {
                return error.UninitializedPath;
            }
            if (implicit_moveto) |pt| {
                implicit_moveto = null;
                try path.moveTo(allocator, pt);
            }
        }
        switch (c) {
            'm', 'M' => {
                implicit_moveto = null;
                const pt = try lexer.getMaybeRelative(c);
                try path.moveTo(allocator, pt);
                lexer.last_pt = pt;
                first_pt = pt;
                last_ctrl = pt;
                last_cmd = c - 1; // 'M' -> 'L', 'm' -> 'l'
            },
            'l', 'L' => {
                const pt = try lexer.getMaybeRelative(c);
                try path.lineTo(allocator, pt);
                lexer.last_pt = pt;
                last_ctrl = pt;
                last_cmd = c;
            },
            'h', 'H' => {
                var x = try lexer.getNumber();
                lexer.optComma();
                if (c == 'h') {
                    x += lexer.last_pt.x;
                }
                const pt = Point.new(x, lexer.last_pt.y);
                try path.lineTo(allocator, pt);
                lexer.last_pt = pt;
                last_ctrl = pt;
                last_cmd = c;
            },
            'v', 'V' => {
                var y = try lexer.getNumber();
                lexer.optComma();
                if (c == 'v') {
                    y += lexer.last_pt.y;
                }
                const pt = Point.new(lexer.last_pt.x, y);
                try path.lineTo(allocator, pt);
                lexer.last_pt = pt;
                last_ctrl = pt;
                last_cmd = c;
            },
            'q', 'Q' => {
                const p1 = try lexer.getMaybeRelative(c);
                const p2 = try lexer.getMaybeRelative(c);
                try path.quadTo(allocator, p1, p2);
                last_ctrl = p1;
                lexer.last_pt = p2;
                last_cmd = c;
            },
            't', 'T' => {
                const p1 = if (last_ctrl) |ctrl|
                    Point.new(2.0 * lexer.last_pt.x - ctrl.x, 2.0 * lexer.last_pt.y - ctrl.y)
                else
                    lexer.last_pt;
                const p2 = try lexer.getMaybeRelative(c);
                try path.quadTo(allocator, p1, p2);
                last_ctrl = p1;
                lexer.last_pt = p2;
                last_cmd = c;
            },
            'c', 'C' => {
                const p1 = try lexer.getMaybeRelative(c);
                const p2 = try lexer.getMaybeRelative(c);
                const p3 = try lexer.getMaybeRelative(c);
                try path.curveTo(allocator, p1, p2, p3);
                last_ctrl = p2;
                lexer.last_pt = p3;
                last_cmd = c;
            },
            's', 'S' => {
                const p1 = if (last_ctrl) |ctrl|
                    Point.new(2.0 * lexer.last_pt.x - ctrl.x, 2.0 * lexer.last_pt.y - ctrl.y)
                else
                    lexer.last_pt;
                const p2 = try lexer.getMaybeRelative(c);
                const p3 = try lexer.getMaybeRelative(c);
                try path.curveTo(allocator, p1, p2, p3);
                last_ctrl = p2;
                lexer.last_pt = p3;
                last_cmd = c;
            },
            'a', 'A' => {
                const radii = try lexer.getNumberPair();
                const x_rotation = (try lexer.getNumber()) * (PI / 180.0); // to_radians
                lexer.optComma();
                const large_arc = try lexer.getFlag();
                lexer.optComma();
                const sweep = try lexer.getFlag();
                lexer.optComma();
                const p = try lexer.getMaybeRelative(c);
                const svg_arc = SvgArc{
                    .from = lexer.last_pt,
                    .to = p,
                    .radii = radii.toVec2(),
                    .x_rotation = x_rotation,
                    .large_arc = large_arc,
                    .sweep = sweep,
                };

                if (Arc.fromSvgArc(svg_arc)) |arc| {
                    // TODO: consider making tolerance configurable
                    try arc.appendCubics(allocator, &path, 0.1);
                } else {
                    try path.lineTo(allocator, p);
                }

                last_ctrl = p;
                lexer.last_pt = p;
                last_cmd = c;
            },
            'z', 'Z' => {
                try path.closePath(allocator);
                lexer.last_pt = first_pt;
                implicit_moveto = first_pt;
            },
            else => return error.UnknownCommand,
        }
    }
    return path;
}

/// Create a `BezPath` with segments corresponding to the sequence of
/// `PathSeg`s.
///
/// Allocates with `allocator`; the caller owns the result.
pub fn fromPathSegments(allocator: std.mem.Allocator, segments: []const PathSeg) !BezPath {
    var path = BezPath.init();
    errdefer path.deinit(allocator);
    var current_pos: ?Point = null;
    for (segments) |segment| {
        const start = segment.start();
        if (current_pos == null or current_pos.?.x != start.x or current_pos.?.y != start.y) {
            try path.moveTo(allocator, start);
        }
        switch (segment) {
            .Line => |l| try path.lineTo(allocator, l.p1),
            .Quad => |q| try path.quadTo(allocator, q.p1, q.p2),
            .Cubic => |c| try path.curveTo(allocator, c.p1, c.p2, c.p3),
        }
        current_pos = segment.end();
    }
    return path;
}

/// Convert the path to an SVG path string representation.
///
/// The current implementation doesn't take special care to produce a short
/// string (reducing precision, using relative movement). Allocates; the
/// caller owns the result.
pub fn toSvg(allocator: std.mem.Allocator, path: *const BezPath) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path.elementsSlice(), 0..) |el, i| {
        if (i > 0) {
            try out.append(allocator, ' ');
        }
        switch (el) {
            .MoveTo => |p| try appendPrint(allocator, &out, "M{d},{d}", .{ p.x, p.y }),
            .LineTo => |p| try appendPrint(allocator, &out, "L{d},{d}", .{ p.x, p.y }),
            .QuadTo => |q| try appendPrint(allocator, &out, "Q{d},{d} {d},{d}", .{ q.p1.x, q.p1.y, q.p2.x, q.p2.y }),
            .CurveTo => |c| try appendPrint(
                allocator,
                &out,
                "C{d},{d} {d},{d} {d},{d}",
                .{ c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y },
            ),
            .ClosePath => try out.append(allocator, 'Z'),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendPrint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

/// The private elliptical-arc implementation used by `parseSvg`.
///
/// This is upstream `arc.rs`'s `Arc::from_svg_arc` and `append_iter` (the
/// latter consumed by `to_cubic_beziers`).
const Arc = struct {
    center: Point,
    radii: Vec2,
    start_angle: f64,
    sweep_angle: f64,
    x_rotation: f64,

    /// Creates an `Arc` from a `SvgArc`.
    ///
    /// Returns `null` if `arc` is actually a straight line.
    fn fromSvgArc(arc: SvgArc) ?Arc {
        // Have to check this first, otherwise `sum_of_sq` will be 0.
        if (arc.isStraightLine()) {
            return null;
        }

        var rx = @abs(arc.radii.x);
        var ry = @abs(arc.radii.y);

        const xr = @rem(arc.x_rotation, 2.0 * PI);
        const sc = common.FloatFuncs.sinCos(xr);
        const sin_phi = sc[0];
        const cos_phi = sc[1];
        const hd_x = (arc.from.x - arc.to.x) * 0.5;
        const hd_y = (arc.from.y - arc.to.y) * 0.5;
        const hs_x = (arc.from.x + arc.to.x) * 0.5;
        const hs_y = (arc.from.y + arc.to.y) * 0.5;

        // F6.5.1
        const p = Vec2.new(
            cos_phi * hd_x + sin_phi * hd_y,
            -sin_phi * hd_x + cos_phi * hd_y,
        );

        // Sanitize the radii. If rf > 1 it means the radii are too small for
        // the arc to possibly connect the end points; scale them up according
        // to the formula provided by the SVG spec.
        // F6.6.2
        const rf = p.x * p.x / (rx * rx) + p.y * p.y / (ry * ry);
        if (rf > 1.0) {
            const scale = @sqrt(rf);
            rx *= scale;
            ry *= scale;
        }

        const rxry = rx * ry;
        const rxpy = rx * p.y;
        const rypx = ry * p.x;
        const sum_of_sq = rxpy * rxpy + rypx * rypx;

        // F6.5.2
        const sign_coe: f64 = if (arc.large_arc == arc.sweep) -1.0 else 1.0;
        const coe = sign_coe * @sqrt(@abs((rxry * rxry - sum_of_sq) / sum_of_sq));
        const transformed_cx = coe * rxpy / ry;
        const transformed_cy = -coe * rypx / rx;

        // F6.5.3
        const center = Point.new(
            cos_phi * transformed_cx - sin_phi * transformed_cy + hs_x,
            sin_phi * transformed_cx + cos_phi * transformed_cy + hs_y,
        );

        const start_v = Vec2.new((p.x - transformed_cx) / rx, (p.y - transformed_cy) / ry);
        const end_v = Vec2.new((-p.x - transformed_cx) / rx, (-p.y - transformed_cy) / ry);

        const start_angle = start_v.atan2();

        var sweep_angle = @rem(end_v.atan2() - start_angle, 2.0 * PI);

        if (arc.sweep and sweep_angle < 0.0) {
            sweep_angle += 2.0 * PI;
        } else if (!arc.sweep and sweep_angle > 0.0) {
            sweep_angle -= 2.0 * PI;
        }

        return .{
            .center = center,
            .radii = Vec2.new(rx, ry),
            .start_angle = start_angle,
            .sweep_angle = sweep_angle,
            .x_rotation = arc.x_rotation,
        };
    }

    /// Appends `CurveTo` elements approximating this arc, with the same
    /// subdivision heuristic as upstream `Arc::append_iter`.
    fn appendCubics(self: Arc, allocator: std.mem.Allocator, path: *BezPath, tolerance: f64) !void {
        const sign = common.FloatFuncs.signum(self.sweep_angle);
        const scaled_err = @max(self.radii.x, self.radii.y) / tolerance;
        // Number of subdivisions per ellipse based on error tolerance.
        // Note: this may slightly underestimate the error for quadrants.
        const n_err = @max(std.math.pow(f64, 1.1163 * scaled_err, 1.0 / 6.0), 3.999999);
        const n_f = @ceil(n_err * @abs(self.sweep_angle) * (1.0 / (2.0 * PI)));
        const angle_step = self.sweep_angle / n_f;
        const n = common.castToUsize(n_f);
        const arm_len = (4.0 / 3.0) * @tan(@abs(0.25 * angle_step)) * sign;

        var angle0 = self.start_angle;
        var p0 = sampleEllipse(self.radii, self.x_rotation, angle0);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const angle1 = angle0 + angle_step;
            const p1 = p0.add(
                sampleEllipse(self.radii, self.x_rotation, angle0 + FRAC_PI_2).mulScalar(arm_len),
            );
            const p3 = sampleEllipse(self.radii, self.x_rotation, angle1);
            const p2 = p3.sub(
                sampleEllipse(self.radii, self.x_rotation, angle1 + FRAC_PI_2).mulScalar(arm_len),
            );

            angle0 = angle1;
            p0 = p3;
            try path.curveTo(
                allocator,
                self.center.addVec(p1),
                self.center.addVec(p2),
                self.center.addVec(p3),
            );
        }
    }
};

/// Take the ellipse radii, how the radii are rotated, and the angle, and
/// return a point on the ellipse.
fn sampleEllipse(radii: Vec2, x_rotation: f64, angle: f64) Vec2 {
    const sc = common.FloatFuncs.sinCos(angle);
    const angle_sin = sc[0];
    const angle_cos = sc[1];
    const u = radii.x * angle_cos;
    const v = radii.y * angle_sin;
    return rotatePt(Vec2.new(u, v), x_rotation);
}

/// Rotate `pt` about the origin by `angle` radians.
fn rotatePt(pt: Vec2, angle: f64) Vec2 {
    const sc = common.FloatFuncs.sinCos(angle);
    const angle_sin = sc[0];
    const angle_cos = sc[1];
    return Vec2.new(
        pt.x * angle_cos - pt.y * angle_sin,
        pt.x * angle_sin + pt.y * angle_cos,
    );
}

/// The SVG path-data lexer (upstream `SvgLexer`).
const SvgLexer = struct {
    data: []const u8,
    ix: usize,
    last_pt: Point,

    fn skipWs(self: *SvgLexer) void {
        while (self.data.len > self.ix) {
            const c = self.data[self.ix];
            if (!(c == ' ' or c == 9 or c == 10 or c == 12 or c == 13)) {
                break;
            }
            self.ix += 1;
        }
    }

    fn getCmd(self: *SvgLexer, last_cmd: u8) ?u8 {
        self.skipWs();
        if (self.getByte()) |c| {
            if (std.ascii.isLower(c) or std.ascii.isUpper(c)) {
                return c;
            } else if (last_cmd != 0 and (c == '-' or c == '.' or std.ascii.isDigit(c))) {
                // Plausible number start
                self.unget();
                return last_cmd;
            } else {
                self.unget();
            }
        }
        return null;
    }

    fn getByte(self: *SvgLexer) ?u8 {
        if (self.ix >= self.data.len) return null;
        const c = self.data[self.ix];
        self.ix += 1;
        return c;
    }

    fn unget(self: *SvgLexer) void {
        self.ix -= 1;
    }

    fn getNumber(self: *SvgLexer) !f64 {
        self.skipWs();
        const start = self.ix;
        const c = self.getByte() orelse return error.UnexpectedEof;
        if (!(c == '-' or c == '+')) {
            self.unget();
        }
        var digit_count: usize = 0;
        var seen_period = false;
        while (self.getByte()) |ch| {
            if (std.ascii.isDigit(ch)) {
                digit_count += 1;
            } else if (ch == '.' and !seen_period) {
                seen_period = true;
            } else {
                self.unget();
                break;
            }
        }
        if (self.getByte()) |ch| {
            if (ch == 'e' or ch == 'E') {
                var e = self.getByte() orelse return error.Wrong;
                if (e == '-' or e == '+') {
                    e = self.getByte() orelse return error.Wrong;
                }
                if (!std.ascii.isDigit(e)) {
                    return error.Wrong;
                }
                while (self.getByte()) |d| {
                    if (!std.ascii.isDigit(d)) {
                        self.unget();
                        break;
                    }
                }
            } else {
                self.unget();
            }
        }
        if (digit_count > 0) {
            return std.fmt.parseFloat(f64, self.data[start..self.ix]) catch error.Wrong;
        }
        return error.Wrong;
    }

    fn getFlag(self: *SvgLexer) !bool {
        self.skipWs();
        const c = self.getByte() orelse return error.UnexpectedEof;
        return switch (c) {
            '0' => false,
            '1' => true,
            else => error.Wrong,
        };
    }

    fn getNumberPair(self: *SvgLexer) !Point {
        const x = try self.getNumber();
        self.optComma();
        const y = try self.getNumber();
        self.optComma();
        return Point.new(x, y);
    }

    fn getMaybeRelative(self: *SvgLexer, cmd: u8) !Point {
        const pt = try self.getNumberPair();
        if (std.ascii.isLower(cmd)) {
            return self.last_pt.addVec(pt.toVec2());
        }
        return pt;
    }

    fn optComma(self: *SvgLexer) void {
        self.skipWs();
        if (self.getByte()) |c| {
            if (c != ',') {
                self.unget();
            }
        }
    }
};

// ------------------------------------------------------------------
// Tests (ported from svg.rs).
// ------------------------------------------------------------------

test "test_parse_svg" {
    const testing = std.testing;
    var path = try parseSvg(testing.allocator, "m10 10 100 0 0 100 -100 0z");
    defer path.deinit(testing.allocator);
    var count: usize = 0;
    var it = path.segments();
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 4), count);
}

test "test_parse_svg2" {
    const testing = std.testing;
    var path = try parseSvg(testing.allocator, "M3.5 8a.5.5 0 01.5-.5h8a.5.5 0 010 1H4a.5.5 0 01-.5-.5z");
    defer path.deinit(testing.allocator);
    var count: usize = 0;
    var it = path.segments();
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 6), count);
}

test "test_parse_svg_arc" {
    const testing = std.testing;
    var path = try parseSvg(testing.allocator, "M 100 100 A 25 25 0 1 0 -25 25 z");
    defer path.deinit(testing.allocator);
    var count: usize = 0;
    var it = path.segments();
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "test_parse_svg_arc_pie" {
    const testing = std.testing;
    var path = try parseSvg(testing.allocator, "M 100 100 h 25 a 25 25 0 1 0 -25 25 z");
    defer path.deinit(testing.allocator);
    // Approximate figures, but useful for regression testing.
    try testing.expectEqual(@as(f64, -1473.0), @round(path.area()));
    try testing.expectEqual(@as(f64, 168.0), @round(path.perimeter(1e-6)));
}

test "test_parse_svg_uninitialized" {
    const testing = std.testing;
    const result = parseSvg(testing.allocator, "L10 10 100 0 0 100");
    try testing.expectError(error.UninitializedPath, result);
}

test "test_parse_scientific_notation" {
    const testing = std.testing;
    var path = try parseSvg(testing.allocator, "M 0 0 L 1e-123 -4E+5");
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), path.elementsSlice().len);
    try testing.expectEqualDeep(PathEl.moveTo(Point.new(0.0, 0.0)), path.elementsSlice()[0]);
    try testing.expectEqualDeep(PathEl.lineTo(Point.new(1e-123, -4e5)), path.elementsSlice()[1]);
}

test "test_write_svg_single" {
    const testing = std.testing;
    const CubicBez = @import("cubicbez.zig").CubicBez;
    const segments = [_]PathSeg{.{ .Cubic = CubicBez.new(
        Point.new(10.0, 10.0),
        Point.new(20.0, 20.0),
        Point.new(30.0, 30.0),
        Point.new(40.0, 40.0),
    ) }};
    var path = try fromPathSegments(testing.allocator, &segments);
    defer path.deinit(testing.allocator);
    const svg = try toSvg(testing.allocator, &path);
    defer testing.allocator.free(svg);
    try testing.expectEqualStrings("M10,10 C20,20 30,30 40,40", svg);
}

test "test_write_svg_two_move" {
    const testing = std.testing;
    const CubicBez = @import("cubicbez.zig").CubicBez;
    const segments = [_]PathSeg{
        .{ .Cubic = CubicBez.new(
            Point.new(10.0, 10.0),
            Point.new(20.0, 20.0),
            Point.new(30.0, 30.0),
            Point.new(40.0, 40.0),
        ) },
        .{ .Cubic = CubicBez.new(
            Point.new(50.0, 50.0),
            Point.new(30.0, 30.0),
            Point.new(20.0, 20.0),
            Point.new(10.0, 10.0),
        ) },
    };
    var path = try fromPathSegments(testing.allocator, &segments);
    defer path.deinit(testing.allocator);
    const svg = try toSvg(testing.allocator, &path);
    defer testing.allocator.free(svg);
    try testing.expectEqualStrings("M10,10 C20,20 30,30 40,40 M50,50 C30,30 20,20 10,10", svg);
}

test "test_serialize_deserialize" {
    const testing = std.testing;
    const Line = @import("line.zig").Line;
    const QuadBez = @import("quadbez.zig").QuadBez;
    const CubicBez = @import("cubicbez.zig").CubicBez;

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    const N_TESTS = 100;
    var t: usize = 0;
    while (t < N_TESTS) : (t += 1) {
        var segments: std.ArrayList(PathSeg) = .empty;
        defer segments.deinit(testing.allocator);

        var position: ?Point = null;
        const length = random.intRangeAtMost(u32, 0, 9);
        var k: u32 = 0;
        while (k < length) : (k += 1) {
            const should_follow = random.boolean();
            const first = if (position != null and should_follow)
                position.?
            else
                Point.new(random.float(f64), random.float(f64));
            const kind = random.intRangeAtMost(u8, 0, 2);
            const segment: PathSeg = switch (kind) {
                0 => .{ .Line = Line.new(first, Point.new(random.float(f64), random.float(f64))) },
                1 => .{ .Quad = QuadBez.new(
                    first,
                    Point.new(random.float(f64), random.float(f64)),
                    Point.new(random.float(f64), random.float(f64)),
                ) },
                else => .{ .Cubic = CubicBez.new(
                    first,
                    Point.new(random.float(f64), random.float(f64)),
                    Point.new(random.float(f64), random.float(f64)),
                    Point.new(random.float(f64), random.float(f64)),
                ) },
            };
            position = segment.end();
            try segments.append(testing.allocator, segment);
        }

        var path = try fromPathSegments(testing.allocator, segments.items);
        defer path.deinit(testing.allocator);
        const svg = try toSvg(testing.allocator, &path);
        defer testing.allocator.free(svg);
        var deser = try parseSvg(testing.allocator, svg);
        defer deser.deinit(testing.allocator);

        const wanted_it = segments.items;
        var got_count: usize = 0;
        var got_it = deser.segments();
        while (got_it.next()) |got| : (got_count += 1) {
            if (got_count >= wanted_it.len) break;
            try testing.expectEqualDeep(wanted_it[got_count], got);
        }
        try testing.expectEqual(wanted_it.len, got_count);
    }
}
