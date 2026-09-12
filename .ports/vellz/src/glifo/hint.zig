//! TrueType bytecode hinting interpreter, bit-exact with `skrifa 0.44.0`.
//!
//! Port of `skrifa/src/outline/glyf/hint/**` (the interpreter, graphics state,
//! zones, value stack, definitions and programs) plus the glyf-facing
//! `HintInstance`. Every arithmetic operation is transcribed from the pinned
//! Rust sources with the same fixed-point widths and the same evaluation
//! order, so hinted outlines are bit-identical rather than approximate.
//!
//! This module is deliberately self-contained: it does not import `glyf.zig`.
//! The caller (the glyf scaler) supplies the font program tables through
//! [`ProgramData`] and the per-glyph buffers through [`HintOutline`]. `cvar`
//! deltas are applied to the CVT during instance setup (the only variation
//! consumer inside the interpreter); the `GETVARIATION` opcode reads the
//! normalized coordinates passed by the scaler.
//!
//! Deferred with typed errors, never approximated: autohinting and CFF
//! hinting. Unhandled opcodes raise `error.UnhandledOpcode` (or dispatch to
//! user `IDEF`s, matching upstream).

const std = @import("std");

pub const GlyphId = u32;

/// Errors that may occur while interpreting TrueType bytecode.
///
/// Mirrors `skrifa::outline::glyf::hint::HintErrorKind` one-to-one, minus the
/// payloads (Zig error values are payload-free; the variants that carried
/// indices are split where the distinction matters for tests).
pub const HintError = std.mem.Allocator.Error || error{
    UnexpectedEndOfBytecode,
    UnhandledOpcode,
    DefinitionInGlyphProgram,
    NestedDefinition,
    DefinitionTooLarge,
    TooManyDefinitions,
    InvalidDefinition,
    ValueStackOverflow,
    ValueStackUnderflow,
    CallStackOverflow,
    CallStackUnderflow,
    InvalidStackValue,
    InvalidPointIndex,
    InvalidPointRange,
    InvalidContourIndex,
    InvalidCvtIndex,
    InvalidStorageIndex,
    DivideByZero,
    InvalidZoneIndex,
    NegativeLoopCounter,
    InvalidJump,
    ExceededExecutionBudget,
    /// `CowSlice::new` size mismatch (upstream panics; this port is typed).
    CvtSizeMismatch,
    StorageSizeMismatch,
};

/// A point in 26.6 fixed point (or font units when the code says "unscaled").
pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn coordinate(self: Point, axis: CoordAxis) i32 {
        return switch (axis) {
            .x => self.x,
            .y => self.y,
            .both => unreachable,
        };
    }

    pub fn setCoordinate(self: *Point, axis: CoordAxis, value: i32) void {
        switch (axis) {
            .x => self.x = value,
            .y => self.y = value,
            .both => unreachable,
        }
    }

    pub fn coordinateAdd(self: *Point, axis: CoordAxis, delta: i32) void {
        switch (axis) {
            .x => self.x +%= delta,
            .y => self.y +%= delta,
            .both => unreachable,
        }
    }
};

// ------------------------------------------------------------------- math

pub fn floor(x: i32) i32 {
    return x & ~@as(i32, 63);
}

pub fn roundNearest(x: i32) i32 {
    return floor(x +% 32);
}

pub fn ceil(x: i32) i32 {
    return floor(x +% 63);
}

fn floorPad(x: i32, n: i32) i32 {
    return x & ~(n - 1);
}

pub fn roundPad(x: i32, n: i32) i32 {
    return floorPad(x +% @divTrunc(n, 2), n);
}

/// `read-fonts`/`font-types` `Fixed` multiplication: round half away from zero.
pub fn mul(a: i32, b: i32) i32 {
    const ab: i64 = @as(i64, a) * @as(i64, b);
    const adjust: i64 = 0x8000 - @as(i64, @intFromBool(ab < 0));
    return @truncate((ab + adjust) >> 16);
}

/// `font-types` `Fixed` division: `(au << 16 + bu >> 1) / bu`, sign applied
/// afterwards, `0x7fffffff` when the divisor is zero.
pub fn div(a: i32, b: i32) i32 {
    const negative = (a < 0) != (b < 0);
    const au: u64 = @abs(@as(i64, a));
    const bu: u64 = @abs(@as(i64, b));
    const q: u32 = if (bu == 0)
        0x7FFFFFFF
    else
        @truncate(((au << 16) + (bu >> 1)) / bu);
    const bits: i32 = @bitCast(q);
    return if (negative) -%bits else bits;
}

/// `Fixed::mul_div`: a * b / c with round-half-up on the unsigned magnitudes.
pub fn mulDiv(a: i32, b: i32, c: i32) i32 {
    var sign: i32 = 1;
    var su: u64 = @bitCast(@as(i64, a));
    var au: u64 = @bitCast(@as(i64, b));
    var bu: u64 = @bitCast(@as(i64, c));
    if (a < 0) {
        su = 0 -% su;
        sign = -1;
    }
    if (b < 0) {
        au = 0 -% au;
        sign = -sign;
    }
    if (c < 0) {
        bu = 0 -% bu;
        sign = -sign;
    }
    const result: u64 = if (bu > 0)
        (su *% au +% (bu >> 1)) / bu
    else
        0x7FFFFFFF;
    const bits: i32 = @bitCast(@as(u32, @truncate(result)));
    return if (sign < 0) -%bits else bits;
}

/// `FT_MulDiv_NoRound`.
pub fn mulDivNoRound(a_in: i32, b_in: i32, c_in: i32) i32 {
    var a = a_in;
    var b = b_in;
    var c = c_in;
    var s: i32 = 1;
    if (a < 0) {
        a = -%a;
        s = -1;
    }
    if (b < 0) {
        b = -%b;
        s = -s;
    }
    if (c < 0) {
        c = -%c;
        s = -s;
    }
    const d: i64 = if (c > 0) @divTrunc(@as(i64, a) * @as(i64, b), @as(i64, c)) else 0x7FFFFFFF;
    const truncated: i32 = @truncate(d);
    return if (s < 0) -%truncated else truncated;
}

/// Multiplication in 2.14 fixed point (`TT_MulFix14`).
pub fn mul14(a: i32, b: i32) i32 {
    var v: i64 = @as(i64, a) * @as(i64, b);
    v += 0x2000 + (v >> 63);
    return @truncate(v >> 14);
}

/// Normalize a vector in 2.14 fixed point (`FT_Vector_NormLen`).
pub fn normalize14(x: i32, y: i32) Point {
    var sx: i32 = 1;
    var sy: i32 = 1;
    var ux: u32 = @bitCast(x);
    var uy: u32 = @bitCast(y);
    if (x < 0) {
        ux = 0 -% ux;
        sx = -sx;
    }
    if (y < 0) {
        uy = 0 -% uy;
        sy = -sy;
    }
    var result = Point{};
    if (ux == 0) {
        result.x = @divTrunc(x, 4);
        if (uy > 0) {
            result.y = @divTrunc(sy *% 0x10000, 4);
        }
        return result;
    }
    if (uy == 0) {
        result.y = @divTrunc(y, 4);
        if (ux > 0) {
            result.x = @divTrunc(sx *% 0x10000, 4);
        }
        return result;
    }
    var len: u32 = if (ux > uy) ux +% (uy >> 1) else uy +% (ux >> 1);
    const leading: i32 = @intCast(@clz(len));
    const shift: i32 = leading - 15 - @as(i32, @intFromBool(len >= (@as(u32, 0xAAAAAAAA) >> @intCast(leading))));
    if (shift > 0) {
        const s: u5 = @intCast(shift);
        ux <<= s;
        uy <<= s;
        len = if (ux > uy) ux +% (uy >> 1) else uy +% (ux >> 1);
    } else {
        const s: u5 = @intCast(-shift);
        ux >>= s;
        uy >>= s;
        len >>= s;
    }
    var b: i32 = 0x10000 -% @as(i32, @bitCast(len));
    const xv: i32 = @bitCast(ux);
    const yv: i32 = @bitCast(uy);
    var u: i32 = 0;
    var v: i32 = 0;
    while (true) {
        u = xv +% ((xv *% b) >> 16);
        v = yv +% ((yv *% b) >> 16);
        const sq: i32 = @bitCast((@as(u32, @bitCast(u)) *% @as(u32, @bitCast(u))) +%
            (@as(u32, @bitCast(v)) *% @as(u32, @bitCast(v))));
        var z: i32 = @divTrunc(-%sq, 0x200);
        z = @divTrunc(z *% ((0x10000 +% b) >> 8), 0x10000);
        b +%= z;
        if (z <= 0) break;
    }
    return Point{
        .x = @divTrunc(u *% sx, 4),
        .y = @divTrunc(v *% sy, 4),
    };
}

/// Dot product for vectors in 2.14 fixed point.
fn dot14(ax: i32, ay: i32, bx: i32, by: i32) i32 {
    var v1: i64 = @as(i64, ax) * @as(i64, bx);
    const v2: i64 = @as(i64, ay) * @as(i64, by);
    v1 +%= v2;
    v1 +%= 0x2000 + (v1 >> 63);
    return @truncate(v1 >> 14);
}

fn wrappingAbs(x: i32) i32 {
    return if (x < 0) -%x else x;
}

// ---------------------------------------------------------------- programs

/// Describes the source for a piece of bytecode.
pub const Program = enum(u8) {
    /// `fpgm`.
    font = 0,
    /// `prep`.
    control_value = 1,
    /// Per-glyph bytecode.
    glyph = 2,
};

/// Hinting target; mirrors `skrifa::outline::Target`.
pub const SmoothMode = enum { normal, light, lcd, vertical_lcd };

pub const Target = union(enum) {
    mono,
    smooth: struct {
        mode: SmoothMode = .normal,
        symmetric_rendering: bool = true,
        preserve_linear_metrics: bool = false,
    },

    pub const default: Target = .{ .smooth = .{} };

    pub fn isSmooth(self: Target) bool {
        return self == .smooth;
    }

    pub fn isGrayscaleCleartype(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.mode == .normal or s.mode == .light,
            else => false,
        };
    }

    pub fn isLight(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.mode == .light,
            else => false,
        };
    }

    pub fn isLcd(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.mode == .lcd,
            else => false,
        };
    }

    pub fn isVerticalLcd(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.mode == .vertical_lcd,
            else => false,
        };
    }

    pub fn symmetricRendering(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.symmetric_rendering,
            else => false,
        };
    }

    pub fn preserveLinearMetrics(self: Target) bool {
        return switch (self) {
            .smooth => |s| s.preserve_linear_metrics,
            else => false,
        };
    }
};

/// The single hinting configuration glifo uses upstream (`HINTING_OPTIONS`):
/// `Target::Smooth { mode: Lcd, symmetric_rendering: false,
/// preserve_linear_metrics: true }` with `Engine::AutoFallback`.
pub const glifo_target: Target = .{ .smooth = .{
    .mode = .lcd,
    .symmetric_rendering = false,
    .preserve_linear_metrics = true,
} };

// ------------------------------------------------------------------ zones

/// Axis selector for point movement and interpolation.
pub const CoordAxis = enum { both, x, y };

pub const marker_touched_x: u8 = 0x10;
pub const marker_touched_y: u8 = 0x20;
pub const marker_touched: u8 = marker_touched_x | marker_touched_y;
pub const flag_on_curve: u8 = 0x01;

fn touchedMarker(axis: CoordAxis) u8 {
    return switch (axis) {
        .both => marker_touched,
        .x => marker_touched_x,
        .y => marker_touched_y,
    };
}

/// Reference to either the twilight (0) or glyph (1) zone.
pub const ZonePointer = enum(u1) {
    twilight = 0,
    glyph = 1,

    pub fn isTwilight(self: ZonePointer) bool {
        return self == .twilight;
    }

    pub fn fromInt(value: i32) HintError!ZonePointer {
        return switch (value) {
            0 => .twilight,
            1 => .glyph,
            else => error.InvalidZoneIndex,
        };
    }
};

/// Glyph zone for TrueType hinting.
pub const Zone = struct {
    /// Outline points prior to applying the scale.
    unscaled: []const Point = &.{},
    /// Copy of the outline points after applying the scale.
    original: []Point = &.{},
    /// Scaled outline points.
    points: []Point = &.{},
    /// Curve type bits plus hinting markers.
    flags: []u8 = &.{},
    /// Contour end point indices.
    contours: []const u16 = &.{},

    pub fn point(self: *const Zone, index: usize) HintError!Point {
        if (index >= self.points.len) return error.InvalidPointIndex;
        return self.points[index];
    }

    pub fn originalPoint(self: *const Zone, index: usize) HintError!Point {
        if (index >= self.original.len) return error.InvalidPointIndex;
        return self.original[index];
    }

    pub fn unscaledPoint(self: *const Zone, index: usize) Point {
        // Unscaled points in the twilight zone are always (0, 0); the empty
        // backing slice makes that fall out naturally.
        if (index >= self.unscaled.len) return .{};
        return self.unscaled[index];
    }

    pub fn contour(self: *const Zone, index: usize) HintError!u16 {
        if (index >= self.contours.len) return error.InvalidContourIndex;
        return self.contours[index];
    }

    pub fn touch(self: *Zone, index: usize, axis: CoordAxis) HintError!void {
        if (index >= self.flags.len) return error.InvalidPointIndex;
        self.flags[index] |= touchedMarker(axis);
    }

    pub fn untouch(self: *Zone, index: usize, axis: CoordAxis) HintError!void {
        if (index >= self.flags.len) return error.InvalidPointIndex;
        self.flags[index] &= ~touchedMarker(axis);
    }

    pub fn isTouched(self: *const Zone, index: usize, axis: CoordAxis) HintError!bool {
        if (index >= self.flags.len) return error.InvalidPointIndex;
        return (self.flags[index] & touchedMarker(axis)) != 0;
    }

    pub fn flipOnCurve(self: *Zone, index: usize) HintError!void {
        if (index >= self.flags.len) return error.InvalidPointIndex;
        self.flags[index] ^= flag_on_curve;
    }

    pub fn setOnCurve(self: *Zone, start: usize, end: usize, on: bool) HintError!void {
        if (start > end or end > self.flags.len) return error.InvalidPointRange;
        for (self.flags[start..end]) |*flag| {
            if (on) {
                flag.* |= flag_on_curve;
            } else {
                flag.* &= ~flag_on_curve;
            }
        }
    }

    /// Interpolate untouched points (IUP).
    pub fn iup(self: *Zone, axis: CoordAxis) HintError!void {
        if (self.points.len == 0) return;
        var cursor: usize = 0;
        for (0..self.contours.len) |i| {
            var end_point: usize = try self.contour(i);
            const first_point = cursor;
            if (end_point >= self.points.len) {
                end_point = self.points.len - 1;
            }
            while (cursor <= end_point and !try self.isTouched(cursor, axis)) {
                cursor += 1;
            }
            if (cursor <= end_point) {
                const first_touched = cursor;
                var cur_touched = cursor;
                cursor += 1;
                while (cursor <= end_point) : (cursor += 1) {
                    if (try self.isTouched(cursor, axis)) {
                        try self.iupInterpolate(axis, cur_touched + 1, cursor - 1, cur_touched, cursor);
                        cur_touched = cursor;
                    }
                }
                if (cur_touched == first_touched) {
                    try self.iupShift(axis, first_point, end_point, cur_touched);
                } else {
                    try self.iupInterpolate(axis, cur_touched + 1, end_point, cur_touched, first_touched);
                    if (first_touched > 0) {
                        try self.iupInterpolate(axis, first_point, first_touched - 1, cur_touched, first_touched);
                    }
                }
            }
        }
    }

    /// Shift the range of points `p1..=p2` based on the delta given by the
    /// reference point `p` (every point except `p` itself).
    fn iupShift(self: *Zone, axis: CoordAxis, p1: usize, p2: usize, p: usize) HintError!void {
        if (p1 > p2 or p1 > p or p > p2) return;
        if (p2 >= self.points.len or p >= self.points.len or p >= self.original.len) {
            return error.InvalidPointRange;
        }
        const delta = (try self.point(p)).coordinate(axis) - (try self.originalPoint(p)).coordinate(axis);
        if (delta != 0) {
            for (self.points[p1 .. p2 + 1], p1..) |*pt, i| {
                if (i != p) pt.coordinateAdd(axis, delta);
            }
        }
    }

    /// Interpolate `p1..=p2` based on the deltas of the two reference points.
    fn iupInterpolate(
        self: *Zone,
        axis: CoordAxis,
        p1: usize,
        p2: usize,
        ref1_in: usize,
        ref2_in: usize,
    ) HintError!void {
        if (p1 > p2) return;
        var ref1 = ref1_in;
        var ref2 = ref2_in;
        const max_points = self.points.len;
        if (ref1 >= max_points or ref2 >= max_points) return;
        if (p2 >= self.original.len or p2 >= self.unscaled.len or p2 >= self.points.len) {
            return error.InvalidPointRange;
        }
        var orus1 = self.unscaledPoint(ref1).coordinate(axis);
        var orus2 = self.unscaledPoint(ref2).coordinate(axis);
        if (orus1 > orus2) {
            const tmp = orus1;
            orus1 = orus2;
            orus2 = tmp;
            const tref = ref1;
            ref1 = ref2;
            ref2 = tref;
        }
        const org1 = (try self.originalPoint(ref1)).coordinate(axis);
        const org2 = (try self.originalPoint(ref2)).coordinate(axis);
        const cur1 = (try self.point(ref1)).coordinate(axis);
        const cur2 = (try self.point(ref2)).coordinate(axis);
        const delta1 = cur1 -% org1;
        const delta2 = cur2 -% org2;
        if (cur1 == cur2 or orus1 == orus2) {
            for (self.original[p1 .. p2 + 1], self.unscaled[p1 .. p2 + 1], self.points[p1 .. p2 + 1]) |orig, unscaled_pt, *pt| {
                _ = unscaled_pt;
                const a = orig.coordinate(axis);
                pt.setCoordinate(axis, if (a <= org1)
                    a +% delta1
                else if (a >= org2)
                    a +% delta2
                else
                    cur1);
            }
        } else {
            const scale = div(cur2 -% cur1, orus2 -% orus1);
            for (self.original[p1 .. p2 + 1], self.unscaled[p1 .. p2 + 1], self.points[p1 .. p2 + 1]) |orig, unscaled_pt, *pt| {
                const a = orig.coordinate(axis);
                pt.setCoordinate(axis, if (a <= org1)
                    a +% delta1
                else if (a >= org2)
                    a +% delta2
                else
                    cur1 +% mul(unscaled_pt.coordinate(axis) -% orus1, scale));
            }
        }
    }
};

// ------------------------------------------------------------------ rounds

pub const RoundMode = enum {
    /// RTG.
    grid,
    /// RTHG.
    half_grid,
    /// RTDG.
    double_grid,
    /// RDTG.
    down_to_grid,
    /// RUTG.
    up_to_grid,
    /// ROFF.
    off,
    /// SROUND.
    super,
    /// S45ROUND.
    super45,
};

pub const RoundState = struct {
    mode: RoundMode = .grid,
    threshold: i32 = 0,
    phase: i32 = 0,
    period: i32 = 64,

    pub fn round(self: *const RoundState, distance: i32) i32 {
        const result: i32 = switch (self.mode) {
            .half_grid => if (distance >= 0)
                @max(floor(distance) +% 32, 0)
            else
                @min(-%(floor(-%distance) +% 32), 0),
            .grid => if (distance >= 0)
                @max(roundNearest(distance), 0)
            else
                @min(-%roundNearest(-%distance), 0),
            .double_grid => if (distance >= 0)
                @max(roundPad(distance, 32), 0)
            else
                @min(-%roundPad(-%distance, 32), 0),
            .down_to_grid => if (distance >= 0)
                @max(floor(distance), 0)
            else
                @min(-%floor(-%distance), 0),
            .up_to_grid => if (distance >= 0)
                @max(ceil(distance), 0)
            else
                @min(-%ceil(-%distance), 0),
            .super => if (distance >= 0) blk: {
                const val = ((distance +% (self.threshold -% self.phase)) & -%self.period) +% self.phase;
                break :blk if (val < 0) self.phase else val;
            } else blk: {
                const val = -%(((self.threshold -% self.phase) -% distance) & -%self.period) -% self.phase;
                break :blk if (val > 0) -%self.phase else val;
            },
            .super45 => if (distance >= 0) blk: {
                const val = @divTrunc(distance +% (self.threshold -% self.phase), self.period) *% self.period +% self.phase;
                break :blk if (val < 0) self.phase else val;
            } else blk: {
                const val = -%(@divTrunc((self.threshold -% self.phase) -% distance, self.period) *% self.period) -% self.phase;
                break :blk if (val > 0) -%self.phase else val;
            },
            .off => distance,
        };
        return result;
    }
};

// ------------------------------------------------------------ graphics state

/// The persistent graphics state set by `fpgm`/`prep`.
pub const RetainedGraphicsState = struct {
    auto_flip: bool = true,
    control_value_cutin: i32 = 68,
    delta_base: u16 = 9,
    delta_shift: u16 = 3,
    instruct_control: u8 = 0,
    min_distance: i32 = 64,
    scan_control: bool = false,
    scan_type: i32 = 0,
    single_width_cutin: i32 = 0,
    single_width: i32 = 0,
    target: Target = Target.default,
    scale: i32 = 0,
    ppem: i32 = 0,
    is_rotated: bool = false,
    is_stretched: bool = false,

    pub fn new(scale: i32, ppem: i32, target: Target) RetainedGraphicsState {
        return .{ .scale = scale, .ppem = ppem, .target = target };
    }
};

pub const GraphicsState = struct {
    // Retained fields are flattened here so instruction handlers read like the
    // upstream Rust (`gs.min_distance`, ...); `retainedCopy`/`applyRetained`
    // move them between this struct and `RetainedGraphicsState`.
    auto_flip: bool = true,
    control_value_cutin: i32 = 68,
    delta_base: u16 = 9,
    delta_shift: u16 = 3,
    instruct_control: u8 = 0,
    min_distance: i32 = 64,
    scan_control: bool = false,
    scan_type: i32 = 0,
    single_width_cutin: i32 = 0,
    single_width: i32 = 0,
    target: Target = Target.default,
    scale: i32 = 0,
    ppem: i32 = 0,
    is_rotated: bool = false,
    is_stretched: bool = false,

    proj_vector: Point = .{ .x = 0x4000, .y = 0 },
    proj_axis: CoordAxis = .both,
    dual_proj_vector: Point = .{ .x = 0x4000, .y = 0 },
    dual_proj_axis: CoordAxis = .both,
    freedom_vector: Point = .{ .x = 0x4000, .y = 0 },
    freedom_axis: CoordAxis = .both,
    fdotp: i32 = 0x4000,
    round_state: RoundState = .{},
    rp0: usize = 0,
    rp1: usize = 0,
    rp2: usize = 0,
    loop_counter: u32 = 1,
    zp0: ZonePointer = .glyph,
    zp1: ZonePointer = .glyph,
    zp2: ZonePointer = .glyph,
    zones: [2]Zone = .{ .{}, .{} },
    is_composite: bool = false,
    backward_compatibility: bool = true,
    is_pedantic: bool = false,
    did_iup_x: bool = false,
    did_iup_y: bool = false,

    pub fn retainedCopy(self: *const GraphicsState) RetainedGraphicsState {
        return .{
            .auto_flip = self.auto_flip,
            .control_value_cutin = self.control_value_cutin,
            .delta_base = self.delta_base,
            .delta_shift = self.delta_shift,
            .instruct_control = self.instruct_control,
            .min_distance = self.min_distance,
            .scan_control = self.scan_control,
            .scan_type = self.scan_type,
            .single_width_cutin = self.single_width_cutin,
            .single_width = self.single_width,
            .target = self.target,
            .scale = self.scale,
            .ppem = self.ppem,
            .is_rotated = self.is_rotated,
            .is_stretched = self.is_stretched,
        };
    }

    pub fn applyRetained(self: *GraphicsState, r: RetainedGraphicsState) void {
        self.auto_flip = r.auto_flip;
        self.control_value_cutin = r.control_value_cutin;
        self.delta_base = r.delta_base;
        self.delta_shift = r.delta_shift;
        self.instruct_control = r.instruct_control;
        self.min_distance = r.min_distance;
        self.scan_control = r.scan_control;
        self.scan_type = r.scan_type;
        self.single_width_cutin = r.single_width_cutin;
        self.single_width = r.single_width;
        self.target = r.target;
        self.scale = r.scale;
        self.ppem = r.ppem;
        self.is_rotated = r.is_rotated;
        self.is_stretched = r.is_stretched;
    }

    /// Resets the non-retained portions while keeping zones/composite state.
    pub fn reset(self: *GraphicsState) void {
        const retained = self.retainedCopy();
        const zones = self.zones;
        const is_composite = self.is_composite;
        self.* = .{ .zones = zones, .is_composite = is_composite };
        self.applyRetained(retained);
        self.updateProjectionState();
    }

    /// Resets the retained values to defaults, keeping the instance settings.
    pub fn resetRetained(self: *GraphicsState) void {
        const scale = self.scale;
        const ppem = self.ppem;
        const mode = self.target;
        self.applyRetained(.{ .scale = scale, .ppem = ppem, .target = mode });
    }

    pub fn zone(self: *GraphicsState, pointer: ZonePointer) *Zone {
        return &self.zones[@intFromEnum(pointer)];
    }

    pub fn zoneConst(self: *const GraphicsState, pointer: ZonePointer) *const Zone {
        return &self.zones[@intFromEnum(pointer)];
    }

    pub fn zp0Mut(self: *GraphicsState) *Zone {
        return self.zone(self.zp0);
    }

    pub fn zp0Const(self: *const GraphicsState) *const Zone {
        return self.zoneConst(self.zp0);
    }

    pub fn zp1Mut(self: *GraphicsState) *Zone {
        return self.zone(self.zp1);
    }

    pub fn zp1Const(self: *const GraphicsState) *const Zone {
        return self.zoneConst(self.zp1);
    }

    pub fn zp2Mut(self: *GraphicsState) *Zone {
        return self.zone(self.zp2);
    }

    pub fn zp2Const(self: *const GraphicsState) *const Zone {
        return self.zoneConst(self.zp2);
    }

    /// Returns true if every (zone, index) pair is in bounds. Mirrors the
    /// upstream `index > len` check exactly (including its off-by-one).
    pub fn inBounds2(self: *const GraphicsState, a: struct { ZonePointer, usize }, b: struct { ZonePointer, usize }) bool {
        if (a[1] > self.zoneConst(a[0]).points.len) return false;
        if (b[1] > self.zoneConst(b[0]).points.len) return false;
        return true;
    }

    pub fn inBounds1(self: *const GraphicsState, a: struct { ZonePointer, usize }) bool {
        return a[1] <= self.zoneConst(a[0]).points.len;
    }

    pub fn unscaledToPixels(self: *const GraphicsState) i32 {
        return if (self.is_composite) 1 << 16 else self.scale;
    }

    /// Updates cached state derived from projection vectors.
    pub fn updateProjectionState(self: *GraphicsState) void {
        const one: i32 = 0x4000;
        if (self.freedom_vector.x == one) {
            self.fdotp = self.proj_vector.x;
        } else if (self.freedom_vector.y == one) {
            self.fdotp = self.proj_vector.y;
        } else {
            self.fdotp = (self.proj_vector.x *% self.freedom_vector.x +% self.proj_vector.y *% self.freedom_vector.y) >> 14;
        }
        self.proj_axis = .both;
        if (self.proj_vector.x == one) {
            self.proj_axis = .x;
        } else if (self.proj_vector.y == one) {
            self.proj_axis = .y;
        }
        self.dual_proj_axis = .both;
        if (self.dual_proj_vector.x == one) {
            self.dual_proj_axis = .x;
        } else if (self.dual_proj_vector.y == one) {
            self.dual_proj_axis = .y;
        }
        self.freedom_axis = .both;
        if (self.fdotp == one) {
            if (self.freedom_vector.x == one) {
                self.freedom_axis = .x;
            } else if (self.freedom_vector.y == one) {
                self.freedom_axis = .y;
            }
        }
        if (wrappingAbs(self.fdotp) < 0x400) {
            self.fdotp = 0x4000;
        }
    }

    pub fn roundDistance(self: *const GraphicsState, distance: i32) i32 {
        return self.round_state.round(distance);
    }

    /// Projection of (v1 - v2) along the projection vector.
    pub fn project(self: *const GraphicsState, v1: Point, v2: Point) i32 {
        return switch (self.proj_axis) {
            .x => v1.x -% v2.x,
            .y => v1.y -% v2.y,
            .both => blk: {
                const dx = v1.x -% v2.x;
                const dy = v1.y -% v2.y;
                break :blk dot14(dx, dy, self.proj_vector.x, self.proj_vector.y);
            },
        };
    }

    /// Projection of (v1 - v2) along the dual projection vector.
    pub fn dualProject(self: *const GraphicsState, v1: Point, v2: Point) i32 {
        return switch (self.dual_proj_axis) {
            .x => v1.x -% v2.x,
            .y => v1.y -% v2.y,
            .both => blk: {
                const dx = v1.x -% v2.x;
                const dy = v1.y -% v2.y;
                break :blk dot14(dx, dy, self.dual_proj_vector.x, self.dual_proj_vector.y);
            },
        };
    }

    /// Projection of (v1 - v2) along the dual projection vector for unscaled
    /// points.
    pub fn dualProjectUnscaled(self: *const GraphicsState, v1: Point, v2: Point) i32 {
        return switch (self.dual_proj_axis) {
            .x => v1.x -% v2.x,
            .y => v1.y -% v2.y,
            .both => dot14(v1.x -% v2.x, v1.y -% v2.y, self.dual_proj_vector.x, self.dual_proj_vector.y),
        };
    }

    /// Moves the requested original point by the given distance.
    pub fn moveOriginal(self: *GraphicsState, zone_ptr: ZonePointer, point_ix: usize, distance: i32) HintError!void {
        const fv = self.freedom_vector;
        const fdotp = self.fdotp;
        const axis = self.freedom_axis;
        const z = self.zone(zone_ptr);
        if (point_ix >= z.original.len) return error.InvalidPointIndex;
        const point = &z.original[point_ix];
        switch (axis) {
            .x => point.x +%= distance,
            .y => point.y +%= distance,
            .both => {
                if (fv.x != 0) {
                    point.x +%= mulDiv(distance, fv.x, fdotp);
                }
                if (fv.y != 0) {
                    point.y +%= mulDiv(distance, fv.y, fdotp);
                }
            },
        }
    }

    /// Moves the requested scaled point by the given distance.
    pub fn movePoint(self: *GraphicsState, zone_ptr: ZonePointer, point_ix: usize, distance: i32) HintError!void {
        const back_compat = self.backward_compatibility;
        const back_compat_and_did_iup = back_compat and self.did_iup_x and self.did_iup_y;
        const fv = self.freedom_vector;
        const fdotp = self.fdotp;
        const axis = self.freedom_axis;
        const z = self.zone(zone_ptr);
        if (point_ix >= z.points.len) return error.InvalidPointIndex;
        const point = &z.points[point_ix];
        switch (axis) {
            .x => {
                if (!back_compat) point.x +%= distance;
                try z.touch(point_ix, .x);
            },
            .y => {
                if (!back_compat_and_did_iup) point.y +%= distance;
                try z.touch(point_ix, .y);
            },
            .both => {
                if (fv.x != 0) {
                    if (!back_compat) point.x +%= mulDiv(distance, fv.x, fdotp);
                    try z.touch(point_ix, .x);
                }
                if (fv.y != 0) {
                    if (!back_compat_and_did_iup) {
                        const p2 = &z.points[point_ix];
                        p2.y +%= mulDiv(distance, fv.y, fdotp);
                    }
                    try z.touch(point_ix, .y);
                }
            },
        }
    }

    /// Moves a point in the zone referenced by `zp2` by the given deltas.
    pub fn moveZp2Point(self: *GraphicsState, point_ix: usize, dx: i32, dy: i32, do_touch: bool) HintError!void {
        const back_compat = self.backward_compatibility;
        const back_compat_and_did_iup = back_compat and self.did_iup_x and self.did_iup_y;
        const fv = self.freedom_vector;
        const z = self.zp2Mut();
        if (fv.x != 0) {
            if (point_ix >= z.points.len) return error.InvalidPointIndex;
            if (!back_compat) z.points[point_ix].x +%= dx;
            if (do_touch) try z.touch(point_ix, .x);
        }
        if (fv.y != 0) {
            if (point_ix >= z.points.len) return error.InvalidPointIndex;
            if (!back_compat_and_did_iup) z.points[point_ix].y +%= dy;
            if (do_touch) try z.touch(point_ix, .y);
        }
    }

    /// Computes the adjustment made to a point along the freedom vector.
    pub fn pointDisplacement(self: *GraphicsState, opcode: u8) HintError!PointDisplacement {
        const zp = if ((opcode & 1) != 0) self.zp0 else self.zp1;
        const point_ix = if ((opcode & 1) != 0) self.rp1 else self.rp2;
        const zone_data = self.zoneConst(zp);
        const point = try zone_data.point(point_ix);
        const original_point = try zone_data.originalPoint(point_ix);
        const distance = self.project(point, original_point);
        const fv = self.freedom_vector;
        const fdotp = self.fdotp;
        return .{
            .zone = zp,
            .point_ix = point_ix,
            .dx = mulDiv(distance, fv.x, fdotp),
            .dy = mulDiv(distance, fv.y, fdotp),
        };
    }
};

pub const PointDisplacement = struct {
    zone: ZonePointer,
    point_ix: usize,
    dx: i32,
    dy: i32,
};

// -------------------------------------------------------------- value stack

pub const InlineOperands = struct {
    values: [256]i32 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const InlineOperands) []const i32 {
        return self.values[0..self.len];
    }
};

/// Value stack for the TrueType interpreter.
pub const ValueStack = struct {
    values: []i32,
    len: usize = 0,
    is_pedantic: bool = false,

    pub fn init(values: []i32, is_pedantic: bool) ValueStack {
        return .{ .values = values, .is_pedantic = is_pedantic };
    }

    pub fn depth(self: *const ValueStack) usize {
        return self.len;
    }

    pub fn valuesSlice(self: *const ValueStack) []const i32 {
        return self.values[0..self.len];
    }

    pub fn push(self: *ValueStack, value: i32) HintError!void {
        if (self.len >= self.values.len) return error.ValueStackOverflow;
        self.values[self.len] = value;
        self.len += 1;
    }

    /// PUSHB[], PUSHW[], NPUSHB[] and NPUSHW[] payloads.
    pub fn pushInlineOperands(self: *ValueStack, operands: *const InlineOperands) HintError!void {
        const push_count: usize = operands.len;
        if (self.len + push_count > self.values.len) return error.ValueStackOverflow;
        @memcpy(self.values[self.len .. self.len + push_count], operands.values[0..push_count]);
        self.len += push_count;
    }

    pub fn peek(self: *const ValueStack) ?i32 {
        if (self.len == 0) return null;
        return self.values[self.len - 1];
    }

    pub fn pop(self: *ValueStack) HintError!i32 {
        if (self.peek()) |value| {
            self.len -= 1;
            return value;
        }
        if (self.is_pedantic) return error.ValueStackUnderflow;
        return 0;
    }

    pub fn popUsize(self: *ValueStack) HintError!usize {
        const value = try self.pop();
        return @bitCast(@as(isize, @as(i64, value)));
    }

    pub fn popCountChecked(self: *ValueStack) HintError!usize {
        const value = try self.pop();
        if (value < 0 and self.is_pedantic) return error.InvalidStackValue;
        return @intCast(@max(value, 0));
    }

    pub fn applyUnary(self: *ValueStack, comptime op: fn (i32) i32) HintError!void {
        const a = try self.pop();
        try self.push(op(a));
    }

    pub fn applyBinary(self: *ValueStack, comptime op: fn (i32, i32) HintError!i32) HintError!void {
        const b = try self.pop();
        const a = try self.pop();
        try self.push(try op(a, b));
    }

    pub fn clear(self: *ValueStack) void {
        self.len = 0;
    }

    pub fn dup(self: *ValueStack) HintError!void {
        if (self.peek()) |value| {
            try self.push(value);
        } else if (self.is_pedantic) {
            return error.ValueStackUnderflow;
        } else {
            try self.push(0);
        }
    }

    pub fn swap(self: *ValueStack) HintError!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a);
        try self.push(b);
    }

    pub fn copyIndex(self: *ValueStack) HintError!void {
        if (self.len == 0) return error.ValueStackUnderflow;
        const top_ix = self.len - 1;
        const index: usize = @bitCast(@as(isize, @as(i64, self.values[top_ix])));
        if (index > top_ix) return error.ValueStackUnderflow;
        const element_ix = top_ix - index;
        self.values[top_ix] = self.values[element_ix];
    }

    pub fn moveIndex(self: *ValueStack) HintError!void {
        if (self.len == 0) return error.ValueStackUnderflow;
        const top_ix = self.len - 1;
        const index: usize = @bitCast(@as(isize, @as(i64, self.values[top_ix])));
        if (index > top_ix) return error.ValueStackUnderflow;
        const element_ix = top_ix - index;
        if (top_ix == 0) return error.ValueStackUnderflow;
        const new_top_ix = top_ix - 1;
        const value = self.values[element_ix];
        std.mem.copyForwards(i32, self.values[element_ix..self.len], self.values[element_ix + 1 .. self.len]);
        self.values[new_top_ix] = value;
        self.len -= 1;
    }

    pub fn roll(self: *ValueStack) HintError!void {
        const a = try self.pop();
        const b = try self.pop();
        const c = try self.pop();
        try self.push(b);
        try self.push(a);
        try self.push(c);
    }
};

// --------------------------------------------------------------- call stack

/// FreeType provides a call stack with a depth of 32.
const max_call_depth: usize = 32;

pub const CallRecord = struct {
    caller_program: Program = .font,
    return_pc: usize = 0,
    current_count: u32 = 0,
    definition: Definition = .{},
};

pub const CallStack = struct {
    records: [max_call_depth]CallRecord = undefined,
    len: usize = 0,

    pub fn clear(self: *CallStack) void {
        self.len = 0;
    }

    pub fn push(self: *CallStack, record: CallRecord) HintError!void {
        if (self.len >= self.records.len) return error.CallStackOverflow;
        self.records[self.len] = record;
        self.len += 1;
    }

    pub fn peek(self: *const CallStack) ?CallRecord {
        if (self.len == 0) return null;
        return self.records[self.len - 1];
    }

    pub fn pop(self: *CallStack) HintError!CallRecord {
        const record = self.peek() orelse return error.CallStackUnderflow;
        self.len -= 1;
        return record;
    }
};

// -------------------------------------------------------------- definitions

/// Code range and properties for a function or instruction definition.
pub const Definition = struct {
    start: u32 = 0,
    end: u32 = 0,
    key: i32 = 0,
    program: u8 = 0,
    is_active: u8 = 0,

    pub fn new(program: Program, start: usize, end: usize, key: i32) Definition {
        return .{
            .start = @intCast(start),
            .end = @intCast(end),
            .key = key,
            .program = @intFromEnum(program),
            .is_active = 1,
        };
    }

    pub fn programId(self: *const Definition) Program {
        return switch (self.program) {
            0 => .font,
            1 => .control_value,
            else => .glyph,
        };
    }

    pub fn codeStart(self: *const Definition) usize {
        return self.start;
    }

    pub fn codeEnd(self: *const Definition) usize {
        return self.end;
    }

    pub fn isActive(self: *const Definition) bool {
        return self.is_active != 0;
    }
};

/// Map of function number or opcode to code definitions.
pub const DefinitionMap = union(enum) {
    ref: []const Definition,
    mut: []Definition,

    /// Attempts to allocate a new definition entry with the given key.
    pub fn allocate(self: *DefinitionMap, key: i32) HintError!*Definition {
        const defs = switch (self.*) {
            .ref => return error.DefinitionInGlyphProgram,
            .mut => |defs| defs,
        };
        var ix: usize = undefined;
        if (key >= 0) {
            const candidate_ix: usize = @intCast(key);
            if (candidate_ix < defs.len and
                (!defs[candidate_ix].isActive() or defs[candidate_ix].key == key))
            {
                ix = candidate_ix;
            } else {
                ix = try findDefinitionSlot(defs, key);
            }
        } else {
            ix = try findDefinitionSlot(defs, key);
        }
        if (ix >= defs.len) return error.TooManyDefinitions;
        defs[ix] = Definition.new(.font, 0, 0, key);
        return &defs[ix];
    }

    fn findDefinitionSlot(defs: []const Definition, key: i32) HintError!usize {
        var last_inactive: ?usize = null;
        var i = defs.len;
        while (i > 0) {
            i -= 1;
            const def = &defs[i];
            if (def.isActive()) {
                if (def.key == key) {
                    last_inactive = i;
                    break;
                }
            } else if (last_inactive == null) {
                last_inactive = i;
            }
        }
        return last_inactive orelse error.TooManyDefinitions;
    }

    pub fn get(self: *const DefinitionMap, key: i32) HintError!*const Definition {
        const defs: []const Definition = switch (self.*) {
            .ref => |defs| defs,
            .mut => |defs| defs,
        };
        if (key >= 0) {
            const ix: usize = @intCast(key);
            if (ix < defs.len) {
                if (defs[ix].isActive() and defs[ix].key == key) return &defs[ix];
            }
        }
        var i = defs.len;
        while (i > 0) {
            i -= 1;
            if (defs[i].isActive() and defs[i].key == key) return &defs[i];
        }
        return error.InvalidDefinition;
    }

    pub fn reset(self: *DefinitionMap) void {
        switch (self.*) {
            .ref => {},
            .mut => |defs| for (defs) |*def| {
                def.* = .{};
            },
        }
    }
};

pub const DefinitionState = struct {
    functions: DefinitionMap,
    instructions: DefinitionMap,
};

// --------------------------------------------------------- programs/decoder

pub const Instruction = struct {
    /// Position of the opcode byte.
    pc: usize,
    opcode: u8,
    inline_operands: InlineOperands,
};

/// State for managing active programs and decoding instructions.
pub const ProgramState = struct {
    bytecode: [3][]const u8,
    initial: Program,
    current: Program,
    decoder: Decoder,
    call_stack: CallStack = .{},

    pub fn new(
        font_code: []const u8,
        cv_code: []const u8,
        glyph_code: []const u8,
        initial_program: Program,
    ) ProgramState {
        const bytecode = [3][]const u8{ font_code, cv_code, glyph_code };
        return .{
            .bytecode = bytecode,
            .initial = initial_program,
            .current = initial_program,
            .decoder = Decoder.init(bytecode[@intFromEnum(initial_program)], 0),
        };
    }

    pub fn reset(self: *ProgramState, program: Program) void {
        self.initial = program;
        self.current = program;
        self.decoder = Decoder.init(self.bytecode[@intFromEnum(program)], 0);
        self.call_stack.clear();
    }

    pub fn enter(self: *ProgramState, definition: Definition, count: u32) HintError!void {
        const program = definition.programId();
        const pc = definition.codeStart();
        const bytecode = self.bytecode[@intFromEnum(program)];
        try self.call_stack.push(.{
            .caller_program = self.current,
            .return_pc = self.decoder.pc,
            .current_count = count,
            .definition = definition,
        });
        self.current = program;
        self.decoder = Decoder.init(bytecode, pc);
    }

    pub fn leave(self: *ProgramState) HintError!void {
        var record = try self.call_stack.pop();
        if (record.current_count > 1) {
            record.current_count -= 1;
            self.decoder.pc = record.definition.codeStart();
            try self.call_stack.push(record);
        } else {
            self.current = record.caller_program;
            self.decoder.bytecode = self.bytecode[@intFromEnum(record.caller_program)];
            self.decoder.pc = record.return_pc;
        }
    }
};

/// Instruction decoder for a single bytecode program.
pub const Decoder = struct {
    bytecode: []const u8,
    pc: usize = 0,

    pub fn init(bytecode: []const u8, pc: usize) Decoder {
        return .{ .bytecode = bytecode, .pc = pc };
    }

    pub fn decode(self: *Decoder) HintError!?Instruction {
        if (self.pc >= self.bytecode.len) return null;
        const start = self.pc;
        const opcode = self.bytecode[self.pc];
        self.pc += 1;
        var inline_operands = InlineOperands{};
        if (opcode == 0x40 or opcode == 0x41) {
            // NPUSHB / NPUSHW.
            if (self.pc >= self.bytecode.len) return error.UnexpectedEndOfBytecode;
            const count: usize = self.bytecode[self.pc];
            self.pc += 1;
            const word = opcode == 0x41;
            const bytes_per: usize = if (word) 2 else 1;
            if (self.pc + count * bytes_per > self.bytecode.len) {
                return error.UnexpectedEndOfBytecode;
            }
            var i: usize = 0;
            while (i < count) : (i += 1) {
                inline_operands.values[i] = if (word)
                    readBeI16(self.bytecode, self.pc + 2 * i)
                else
                    @as(i32, self.bytecode[self.pc + i]);
            }
            inline_operands.len = @intCast(count);
            self.pc += count * bytes_per;
        } else if (opcode >= 0xB0 and opcode <= 0xBF) {
            // PUSHB[abc] / PUSHW[abc].
            const word = opcode >= 0xB8;
            const count: usize = @as(usize, opcode & 0x7) + 1;
            const bytes_per: usize = if (word) 2 else 1;
            if (self.pc + count * bytes_per > self.bytecode.len) {
                return error.UnexpectedEndOfBytecode;
            }
            var i: usize = 0;
            while (i < count) : (i += 1) {
                inline_operands.values[i] = if (word)
                    readBeI16(self.bytecode, self.pc + 2 * i)
                else
                    @as(i32, self.bytecode[self.pc + i]);
            }
            inline_operands.len = @intCast(count);
            self.pc += count * bytes_per;
        }
        return .{ .pc = start, .opcode = opcode, .inline_operands = inline_operands };
    }
};

fn readBeI16(data: []const u8, offset: usize) i16 {
    const hi: u16 = data[offset];
    const lo: u16 = data[offset + 1];
    return @bitCast((hi << 8) | lo);
}

/// `Fixed::to_f26dot6`: `(bits + 0x200) >> 10`, wrapping add.
fn fixedToF26Dot6(bits: i32) i32 {
    const wrapped: i32 = @bitCast(@as(u32, @bitCast(bits)) +% 0x200);
    return wrapped >> 10;
}

// ------------------------------------------------------------------- cvt/storage

/// Copy-on-write backing store for CVT and storage.
pub const CowSlice = struct {
    data: []const i32,
    data_mut: []i32,
    use_mut: bool,

    pub fn new(data: []const i32, data_mut: []i32) CowSlice {
        return .{ .data = data, .data_mut = data_mut, .use_mut = false };
    }

    pub fn newMut(data_mut: []i32) CowSlice {
        return .{ .data = &.{}, .data_mut = data_mut, .use_mut = true };
    }

    pub fn get(self: *const CowSlice, index: usize) ?i32 {
        if (self.use_mut) {
            if (index >= self.data_mut.len) return null;
            return self.data_mut[index];
        }
        if (index >= self.data.len) return null;
        return self.data[index];
    }

    pub fn set(self: *CowSlice, index: usize, value: i32) ?void {
        if (!self.use_mut) {
            @memcpy(self.data_mut, self.data);
            self.use_mut = true;
        }
        if (index >= self.data_mut.len) return null;
        self.data_mut[index] = value;
    }

    pub fn len(self: *const CowSlice) usize {
        return if (self.use_mut) self.data_mut.len else self.data.len;
    }
};

/// Control value table wrapper that converts out of bounds accesses to typed
/// errors.
pub const Cvt = struct {
    inner: CowSlice,

    pub fn get(self: *const Cvt, index: usize) HintError!i32 {
        return self.inner.get(index) orelse error.InvalidCvtIndex;
    }

    pub fn set(self: *Cvt, index: usize, value: i32) HintError!void {
        if (self.inner.set(index, value) == null) return error.InvalidCvtIndex;
    }

    pub fn len(self: *const Cvt) usize {
        return self.inner.len();
    }
};

/// Storage area wrapper.
pub const Storage = struct {
    inner: CowSlice,

    pub fn get(self: *const Storage, index: usize) HintError!i32 {
        return self.inner.get(index) orelse error.InvalidStorageIndex;
    }

    pub fn set(self: *Storage, index: usize, value: i32) HintError!void {
        if (self.inner.set(index, value) == null) return error.InvalidStorageIndex;
    }
};

// --------------------------------------------------------------- loop budget

/// Tracks budgets for loops to limit execution time.
pub const LoopBudget = struct {
    limit: usize,
    backward_jumps: usize = 0,
    loop_calls: usize = 0,

    pub fn new(cvt_len: usize, point_count: ?usize) LoopBudget {
        const limit = if (point_count) |count|
            @max(count * 10, 50) + @max(cvt_len / 10, 50)
        else
            300 + 22 * cvt_len;
        return .{ .limit = limit };
    }

    pub fn reset(self: *LoopBudget) void {
        self.backward_jumps = 0;
        self.loop_calls = 0;
    }

    pub fn doingBackwardJump(self: *LoopBudget) HintError!void {
        self.backward_jumps += 1;
        if (self.backward_jumps > self.limit) return error.ExceededExecutionBudget;
    }

    pub fn doingLoopCall(self: *LoopBudget, count: usize) HintError!void {
        self.loop_calls += count;
        if (self.loop_calls > self.limit) return error.ExceededExecutionBudget;
    }
};

pub const ProgramData = struct {
    /// `fpgm` bytecode.
    fpgm: []const u8 = &.{},
    /// `prep` bytecode.
    prep: []const u8 = &.{},
    /// Raw `cvt` table bytes (big-endian i16 entries).
    cvt: []const u8 = &.{},
    /// `cvar` deltas, applied to the scaled CVT during setup.
    cvar: ?@import("tables/gvar.zig").Cvar = null,
    max_function_defs: u16 = 0,
    max_instruction_defs: u16 = 0,
    max_twilight_points: u16 = 0,
    max_stack_elements: u16 = 0,
    max_storage: u16 = 0,
    axis_count: u16 = 0,

    pub fn cvtLen(self: ProgramData) usize {
        return self.cvt.len / 2;
    }
};

// ------------------------------------------------------------------- engine

pub const Engine = struct {
    program: ProgramState,
    graphics: GraphicsState,
    definitions: DefinitionState,
    cvt: Cvt,
    storage: Storage,
    value_stack: ValueStack,
    loop_budget: LoopBudget,
    axis_count: u16,
    coords: []const i16,
    /// Diagnostics for the last `run()` failure.
    error_pc: usize = 0,
    error_opcode: u8 = 0,

    pub fn new(
        program: ProgramState,
        retained: RetainedGraphicsState,
        definitions: DefinitionState,
        cvt: CowSlice,
        storage: CowSlice,
        value_stack: ValueStack,
        twilight: Zone,
        glyph: Zone,
        axis_count: u16,
        coords: []const i16,
        is_composite: bool,
    ) Engine {
        const point_count: ?usize = if (glyph.points.len == 0) null else glyph.points.len;
        const cvt_len = cvt.len();
        var graphics = GraphicsState{
            .zones = .{ twilight, glyph },
            .is_composite = is_composite,
        };
        graphics.applyRetained(retained);
        return .{
            .program = program,
            .graphics = graphics,
            .definitions = definitions,
            .cvt = .{ .inner = cvt },
            .storage = .{ .inner = storage },
            .value_stack = value_stack,
            .loop_budget = LoopBudget.new(cvt_len, point_count),
            .axis_count = axis_count,
            .coords = coords,
        };
    }

    pub fn runProgram(self: *Engine, program: Program, is_pedantic: bool) HintError!void {
        self.resetProgram(program, is_pedantic);
        return self.run();
    }

    /// Sets internal state for running the specified program.
    pub fn resetProgram(self: *Engine, program: Program, is_pedantic: bool) void {
        self.program.reset(program);
        self.graphics.reset();
        self.graphics.is_pedantic = is_pedantic;
        self.loop_budget.reset();
        switch (program) {
            .font => {
                self.definitions.functions.reset();
                self.definitions.instructions.reset();
            },
            .control_value => self.graphics.backward_compatibility = false,
            .glyph => {
                if (self.graphics.instruct_control & 2 != 0) {
                    self.graphics.resetRetained();
                }
                if (self.graphics.target.preserveLinearMetrics()) {
                    self.graphics.backward_compatibility = true;
                } else if (self.graphics.target.isSmooth()) {
                    self.graphics.backward_compatibility = (self.graphics.instruct_control & 0x4) == 0;
                } else {
                    self.graphics.backward_compatibility = false;
                }
            },
        }
    }

    /// Maximum number of instructions executed in one `run()`.
    const max_run_instructions: usize = 1_000_000;

    pub fn run(self: *Engine) HintError!void {
        var count: usize = 0;
        while (try self.decode()) |ins| {
            try self.dispatch(&ins);
            count += 1;
            if (count > max_run_instructions) return error.ExceededExecutionBudget;
        }
    }

    fn decode(self: *Engine) HintError!?Instruction {
        return self.program.decoder.decode();
    }

    fn dispatch(self: *Engine, ins: *const Instruction) HintError!void {
        self.error_pc = ins.pc;
        self.error_opcode = ins.opcode;
        return self.dispatchInner(ins);
    }

    fn dispatchInner(self: *Engine, ins: *const Instruction) HintError!void {
        const opcode = ins.opcode;
        switch (opcode) {
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05 => try self.opSvtca(opcode),
            0x06, 0x07, 0x08, 0x09 => try self.opSvtl(opcode),
            0x0A => try self.opSpvfs(),
            0x0B => try self.opSfvfs(),
            0x0C => try self.opGpv(),
            0x0D => try self.opGfv(),
            0x0E => try self.opSfvtpv(),
            0x0F => try self.opIsect(),
            0x10 => try self.opSrp0(),
            0x11 => try self.opSrp1(),
            0x12 => try self.opSrp2(),
            0x13 => try self.opSzp0(),
            0x14 => try self.opSzp1(),
            0x15 => try self.opSzp2(),
            0x16 => try self.opSzps(),
            0x17 => try self.opSloop(),
            0x18 => try self.opRtg(),
            0x19 => try self.opRthg(),
            0x1A => try self.opSmd(),
            0x1B => try self.opElse(),
            0x1C => try self.opJmpr(),
            0x1D => try self.opScvtci(),
            0x1E => try self.opSswci(),
            0x1F => try self.opSsw(),
            0x20 => try self.opDup(),
            0x21 => try self.opPop(),
            0x22 => try self.opClear(),
            0x23 => try self.opSwap(),
            0x24 => try self.opDepth(),
            0x25 => try self.opCindex(),
            0x26 => try self.opMindex(),
            0x27 => try self.opAlignpts(),
            // 0x28 UNUSED.
            0x29 => try self.opUtp(),
            0x2A => try self.opLoopcall(),
            0x2B => try self.opCall(),
            0x2C => try self.opFdef(),
            0x2D => try self.opEndf(),
            0x2E, 0x2F => try self.opMdap(opcode),
            0x30, 0x31 => try self.opIup(opcode),
            0x32, 0x33 => try self.opShp(opcode),
            0x34, 0x35 => try self.opShc(opcode),
            0x36, 0x37 => try self.opShz(opcode),
            0x38 => try self.opShpix(),
            0x39 => try self.opIp(),
            0x3A, 0x3B => try self.opMsirp(opcode),
            0x3C => try self.opAlignrp(),
            0x3D => try self.opRtdg(),
            0x3E, 0x3F => try self.opMiap(opcode),
            0x40, 0x41 => try self.opPush(&ins.inline_operands),
            0x42 => try self.opWs(),
            0x43 => try self.opRs(),
            0x44 => try self.opWcvtp(),
            0x45 => try self.opRcvt(),
            0x46, 0x47 => try self.opGc(opcode),
            0x48 => try self.opScfs(),
            0x49, 0x4A => try self.opMd(opcode),
            0x4B => try self.opMppem(),
            0x4C => try self.opMps(),
            0x4D => try self.opFlipon(),
            0x4E => try self.opFlipoff(),
            0x4F => {
                _ = try self.value_stack.pop();
            },
            0x50 => try self.opLt(),
            0x51 => try self.opLteq(),
            0x52 => try self.opGt(),
            0x53 => try self.opGteq(),
            0x54 => try self.opEq(),
            0x55 => try self.opNeq(),
            0x56 => try self.opOdd(),
            0x57 => try self.opEven(),
            0x58 => try self.opIf(),
            0x59 => try self.opEif(),
            0x5A => try self.opAnd(),
            0x5B => try self.opOr(),
            0x5C => try self.opNot(),
            0x5D => try self.opDeltap(opcode),
            0x5E => try self.opSdb(),
            0x5F => try self.opSds(),
            0x60 => try self.opAdd(),
            0x61 => try self.opSub(),
            0x62 => try self.opDiv(),
            0x63 => try self.opMul(),
            0x64 => try self.opAbs(),
            0x65 => try self.opNeg(),
            0x66 => try self.opFloorOp(),
            0x67 => try self.opCeiling(),
            0x68, 0x69, 0x6A, 0x6B => try self.opRound(),
            // 0x6C..0x6F NROUND: no-op.
            0x6C, 0x6D, 0x6E, 0x6F => {},
            0x70 => try self.opWcvtf(),
            0x71, 0x72 => try self.opDeltap(opcode),
            0x73, 0x74, 0x75 => try self.opDeltac(opcode),
            0x76 => try self.opSround(),
            0x77 => try self.opS45round(),
            0x78 => try self.opJrot(),
            0x79 => try self.opJrof(),
            0x7A => try self.opRoff(),
            // 0x7B UNUSED.
            0x7C => try self.opRutg(),
            0x7D => try self.opRdtg(),
            0x7E => try self.opSangw(),
            // 0x7F AA: unsupported, do nothing.
            0x7F => {},
            0x80 => try self.opFlippt(),
            0x81 => try self.opFliprgon(),
            0x82 => try self.opFliprgoff(),
            // 0x83, 0x84 UNUSED.
            0x85 => try self.opScanctrl(),
            0x86, 0x87 => try self.opSdpvtl(opcode),
            0x88 => try self.opGetinfo(),
            0x89 => try self.opIdef(),
            0x8A => try self.opRoll(),
            0x8B => try self.opMax(),
            0x8C => try self.opMin(),
            0x8D => try self.opScantype(),
            0x8E => try self.opInstctrl(),
            // 0x8F, 0x90 UNUSED.
            0x91 => try self.opGetvariation(),
            0x92 => try self.opGetdata(),
            else => {
                if (opcode >= 0xE0) {
                    try self.opMirp(opcode);
                } else if (opcode >= 0xC0) {
                    try self.opMdrp(opcode);
                } else if (opcode >= 0xB0) {
                    try self.opPush(&ins.inline_operands);
                } else {
                    try self.opUnknown(opcode);
                }
            },
        }
    }

    // ------------------------------------------------------------- stack ops

    fn opDup(self: *Engine) HintError!void {
        return self.value_stack.dup();
    }

    fn opPop(self: *Engine) HintError!void {
        _ = try self.value_stack.pop();
    }

    fn opClear(self: *Engine) HintError!void {
        self.value_stack.clear();
    }

    fn opSwap(self: *Engine) HintError!void {
        return self.value_stack.swap();
    }

    fn opDepth(self: *Engine) HintError!void {
        try self.value_stack.push(@intCast(self.value_stack.depth()));
    }

    fn opCindex(self: *Engine) HintError!void {
        return self.value_stack.copyIndex();
    }

    fn opMindex(self: *Engine) HintError!void {
        return self.value_stack.moveIndex();
    }

    fn opRoll(self: *Engine) HintError!void {
        return self.value_stack.roll();
    }

    fn opPush(self: *Engine, operands: *const InlineOperands) HintError!void {
        return self.value_stack.pushInlineOperands(operands);
    }

    // -------------------------------------------------------------- data ops

    fn opGc(self: *Engine, opcode: u8) HintError!void {
        const p = try self.value_stack.popUsize();
        const gs = &self.graphics;
        if (!gs.is_pedantic and !gs.inBounds1(.{ gs.zp2, p })) {
            try self.value_stack.push(0);
            return;
        }
        const value = if ((opcode & 1) != 0)
            gs.dualProject(try gs.zp2Const().originalPoint(p), .{})
        else
            gs.project(try gs.zp2Const().point(p), .{});
        try self.value_stack.push(value);
    }

    fn opScfs(self: *Engine) HintError!void {
        const value = try self.value_stack.pop();
        const p = try self.value_stack.popUsize();
        const gs = &self.graphics;
        const projection = gs.project(try gs.zp2Const().point(p), .{});
        try gs.movePoint(gs.zp2, p, value -% projection);
        if (gs.zp2.isTwilight()) {
            const tw = gs.zone(.twilight);
            if (p >= tw.original.len or p >= tw.points.len) return error.InvalidPointIndex;
            tw.original[p] = tw.points[p];
        }
    }

    fn opMd(self: *Engine, opcode: u8) HintError!void {
        const p1 = try self.value_stack.popUsize();
        const p2 = try self.value_stack.popUsize();
        const gs = &self.graphics;
        if (!gs.is_pedantic and !gs.inBounds2(.{ gs.zp0, p2 }, .{ gs.zp1, p1 })) {
            try self.value_stack.push(0);
            return;
        }
        const distance = if ((opcode & 1) != 0)
            gs.project(try gs.zp0Const().point(p2), try gs.zp1Const().point(p1))
        else if (gs.zp0.isTwilight() or gs.zp1.isTwilight())
            gs.dualProject(try gs.zp0Const().originalPoint(p2), try gs.zp1Const().originalPoint(p1))
        else
            mul(
                gs.dualProjectUnscaled(
                    gs.zp0Const().unscaledPoint(p2),
                    gs.zp1Const().unscaledPoint(p1),
                ),
                gs.unscaledToPixels(),
            );
        try self.value_stack.push(distance);
    }

    fn opMppem(self: *Engine) HintError!void {
        try self.value_stack.push(self.graphics.ppem);
    }

    fn opMps(self: *Engine) HintError!void {
        try self.value_stack.push(self.graphics.ppem *% 64);
    }

    // -------------------------------------------------------------- cvt ops

    fn opWcvtp(self: *Engine) HintError!void {
        const value = try self.value_stack.pop();
        const location = try self.value_stack.popUsize();
        const result = self.cvt.set(location, value);
        if (self.graphics.is_pedantic) return result;
    }

    fn opWcvtf(self: *Engine) HintError!void {
        const value = try self.value_stack.pop();
        const location = try self.value_stack.popUsize();
        const result = self.cvt.set(location, mul(value, self.graphics.scale));
        if (self.graphics.is_pedantic) return result;
    }

    fn opRcvt(self: *Engine) HintError!void {
        const location = try self.value_stack.popUsize();
        const maybe_value = self.cvt.get(location);
        const value: i32 = if (self.graphics.is_pedantic)
            try maybe_value
        else
            maybe_value catch 0;
        try self.value_stack.push(value);
    }

    fn opWs(self: *Engine) HintError!void {
        const value = try self.value_stack.pop();
        const location = try self.value_stack.popUsize();
        const result = self.storage.set(location, value);
        if (self.graphics.is_pedantic) return result;
    }

    fn opRs(self: *Engine) HintError!void {
        const location = try self.value_stack.popUsize();
        const maybe_value = self.storage.get(location);
        const value: i32 = if (self.graphics.is_pedantic)
            try maybe_value
        else
            maybe_value catch 0;
        try self.value_stack.push(value);
    }

    // ------------------------------------------------------------- arith ops

    fn opAdd(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opAddImpl);
    }
    fn opAddImpl(a: i32, b: i32) HintError!i32 {
        return a +% b;
    }

    fn opSub(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opSubImpl);
    }
    fn opSubImpl(a: i32, b: i32) HintError!i32 {
        return a -% b;
    }

    fn opDiv(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opDivImpl);
    }
    fn opDivImpl(a: i32, b: i32) HintError!i32 {
        if (b == 0) return error.DivideByZero;
        return mulDivNoRound(a, 64, b);
    }

    fn opMul(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opMulImpl);
    }
    fn opMulImpl(a: i32, b: i32) HintError!i32 {
        return mulDiv(a, b, 64);
    }

    fn opAbs(self: *Engine) HintError!void {
        return self.value_stack.applyUnary(wrappingAbs);
    }

    fn opNeg(self: *Engine) HintError!void {
        return self.value_stack.applyUnary(opNegImpl);
    }
    fn opNegImpl(a: i32) i32 {
        return -%a;
    }

    fn opFloorOp(self: *Engine) HintError!void {
        return self.value_stack.applyUnary(floor);
    }

    fn opCeiling(self: *Engine) HintError!void {
        return self.value_stack.applyUnary(ceil);
    }

    fn opMax(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opMaxImpl);
    }
    fn opMaxImpl(a: i32, b: i32) HintError!i32 {
        return @max(a, b);
    }

    fn opMin(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opMinImpl);
    }
    fn opMinImpl(a: i32, b: i32) HintError!i32 {
        return @min(a, b);
    }

    // ----------------------------------------------------------- logical ops

    fn opLt(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opLtImpl);
    }
    fn opLtImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a < b);
    }

    fn opLteq(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opLteqImpl);
    }
    fn opLteqImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a <= b);
    }

    fn opGt(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opGtImpl);
    }
    fn opGtImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a > b);
    }

    fn opGteq(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opGteqImpl);
    }
    fn opGteqImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a >= b);
    }

    fn opEq(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opEqImpl);
    }
    fn opEqImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a == b);
    }

    fn opNeq(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opNeqImpl);
    }
    fn opNeqImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a != b);
    }

    fn opOdd(self: *Engine) HintError!void {
        const round_state = self.graphics.round_state;
        const a = try self.value_stack.pop();
        const rounded = round_state.round(a);
        try self.value_stack.push(@intFromBool((rounded & 127) == 64));
    }

    fn opEven(self: *Engine) HintError!void {
        const round_state = self.graphics.round_state;
        const a = try self.value_stack.pop();
        const rounded = round_state.round(a);
        try self.value_stack.push(@intFromBool((rounded & 127) == 0));
    }

    fn opAnd(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opAndImpl);
    }
    fn opAndImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a != 0 and b != 0);
    }

    fn opOr(self: *Engine) HintError!void {
        return self.value_stack.applyBinary(opOrImpl);
    }
    fn opOrImpl(a: i32, b: i32) HintError!i32 {
        return @intFromBool(a != 0 or b != 0);
    }

    fn opNot(self: *Engine) HintError!void {
        return self.value_stack.applyUnary(opNotImpl);
    }
    fn opNotImpl(a: i32) i32 {
        return @intFromBool(a == 0);
    }

    // ------------------------------------------------------------- round ops

    fn opRound(self: *Engine) HintError!void {
        const n1 = try self.value_stack.pop();
        const n2 = self.graphics.roundDistance(n1);
        try self.value_stack.push(n2);
    }

    fn opRtg(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .grid;
    }
    fn opRthg(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .half_grid;
    }
    fn opRtdg(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .double_grid;
    }
    fn opRdtg(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .down_to_grid;
    }
    fn opRutg(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .up_to_grid;
    }
    fn opRoff(self: *Engine) HintError!void {
        self.graphics.round_state.mode = .off;
    }

    fn opSround(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        self.superRound(0x4000, n);
        self.graphics.round_state.mode = .super;
    }

    fn opS45round(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        self.superRound(0x2D41, n);
        self.graphics.round_state.mode = .super45;
    }

    fn superRound(self: *Engine, grid_period: i32, selector: i32) void {
        const round_state = &self.graphics.round_state;
        const period = switch (selector & 0xC0) {
            0 => @divTrunc(grid_period, 2),
            0x40 => grid_period,
            0x80 => grid_period *% 2,
            0xC0 => grid_period,
            else => round_state.period,
        };
        const phase = switch (selector & 0x30) {
            0 => 0,
            0x10 => @divTrunc(period, 4),
            0x20 => @divTrunc(period, 2),
            0x30 => @divTrunc(period *% 3, 4),
            else => round_state.phase,
        };
        const threshold = if ((selector & 0x0F) == 0)
            period -% 1
        else
            @divTrunc(((selector & 0x0F) -% 4) *% period, 8);
        round_state.period = period >> 8;
        round_state.phase = phase >> 8;
        round_state.threshold = threshold >> 8;
    }

    // ------------------------------------------------------------- delta ops

    fn opDeltap(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const ppem: u32 = @bitCast(gs.ppem);
        const point_count = gs.zp0Const().points.len;
        const n0 = try self.value_stack.popCountChecked();
        const n = @min(n0, self.value_stack.len / 2);
        const extra: u32 = switch (opcode) {
            0x71 => 16,
            0x72 => 32,
            else => 0,
        };
        const bias: u32 = extra + @as(u32, gs.delta_base);
        const back_compat = gs.backward_compatibility;
        const did_iup = gs.did_iup_x and gs.did_iup_y;
        for (0..n) |_| {
            const point_ix = try self.value_stack.popUsize();
            var b = try self.value_stack.pop();
            if (point_ix >= point_count) continue;
            const high: u32 = (@as(u32, @bitCast(b)) & 0xF0) >> 4;
            const c = high + bias;
            if (ppem == c) {
                b = (b & 0xF) - 8;
                if (b >= 0) b += 1;
                b *= @as(i32, 1) << @intCast(6 - @as(i32, gs.delta_shift));
                const distance = b;
                if (back_compat) {
                    if (!did_iup and ((gs.is_composite and gs.freedom_vector.y != 0) or
                        try gs.zp0Const().isTouched(point_ix, .y)))
                    {
                        try gs.movePoint(gs.zp0, point_ix, distance);
                    }
                } else {
                    try gs.movePoint(gs.zp0, point_ix, distance);
                }
            }
        }
    }

    fn opDeltac(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const ppem: u32 = @bitCast(gs.ppem);
        const n0 = try self.value_stack.popCountChecked();
        const n = @min(n0, self.value_stack.len / 2);
        const extra: u32 = switch (opcode) {
            0x74 => 16,
            0x75 => 32,
            else => 0,
        };
        const bias: u32 = extra + @as(u32, gs.delta_base);
        for (0..n) |_| {
            const cvt_ix = try self.value_stack.popUsize();
            var b = try self.value_stack.pop();
            const high: u32 = (@as(u32, @bitCast(b)) & 0xF0) >> 4;
            const c = high + bias;
            if (ppem == c) {
                b = (b & 0xF) - 8;
                if (b >= 0) b += 1;
                b *= @as(i32, 1) << @intCast(6 - @as(i32, gs.delta_shift));
                const cvt_val = try self.cvt.get(cvt_ix);
                try self.cvt.set(cvt_ix, cvt_val +% b);
            }
        }
    }

    // -------------------------------------------------------------- misc ops

    fn opGetinfo(self: *Engine) HintError!void {
        const selector = try self.value_stack.pop();
        var result: i32 = 0;
        if ((selector & (1 << 0)) != 0) result = 40;
        if ((selector & (1 << 1)) != 0 and self.graphics.is_rotated) result |= 1 << 8;
        if ((selector & (1 << 2)) != 0 and self.graphics.is_stretched) result |= 1 << 9;
        if ((selector & (1 << 3)) != 0 and self.axis_count != 0) result |= 1 << 10;
        if (self.graphics.target.isSmooth()) {
            if ((selector & (1 << 6)) != 0) result |= 1 << 13;
            if ((selector & (1 << 8)) != 0 and self.graphics.target.isVerticalLcd()) {
                result |= 1 << 15;
            }
            if ((selector & (1 << 10)) != 0) result |= 1 << 17;
            if ((selector & (1 << 11)) != 0 and self.graphics.target.symmetricRendering()) {
                result |= 1 << 18;
            }
            if ((selector & (1 << 12)) != 0 and self.graphics.target.isGrayscaleCleartype()) {
                result |= 1 << 19;
            }
        }
        try self.value_stack.push(result);
    }

    fn opGetvariation(self: *Engine) HintError!void {
        const axis_count: usize = self.axis_count;
        if (axis_count != 0) {
            var i: usize = 0;
            while (i < axis_count) : (i += 1) {
                const coord: i16 = if (i < self.coords.len) self.coords[i] else 0;
                try self.value_stack.push(@as(i32, coord));
            }
            return;
        }
        return self.opUnknown(0x91);
    }

    fn opGetdata(self: *Engine) HintError!void {
        if (self.axis_count != 0) {
            try self.value_stack.push(17);
            return;
        }
        return self.opUnknown(0x92);
    }

    fn opSangw(self: *Engine) HintError!void {
        _ = try self.value_stack.pop();
    }

    // ------------------------------------------------------- control flow ops

    fn opIf(self: *Engine) HintError!void {
        if (try self.value_stack.pop() == 0) {
            var nest_depth: i32 = 1;
            var out = false;
            while (!out) {
                const opcode = try self.decodeNextOpcode();
                switch (opcode) {
                    0x58 => nest_depth += 1,
                    0x1B => out = nest_depth == 1,
                    0x59 => {
                        nest_depth -= 1;
                        out = nest_depth == 0;
                    },
                    else => {},
                }
            }
        }
    }

    fn opElse(self: *Engine) HintError!void {
        var nest_depth: i32 = 1;
        while (nest_depth != 0) {
            const opcode = try self.decodeNextOpcode();
            switch (opcode) {
                0x58 => nest_depth += 1,
                0x59 => nest_depth -= 1,
                else => {},
            }
        }
    }

    fn opEif(self: *Engine) HintError!void {
        _ = self;
        // Nothing.
    }

    fn opJrot(self: *Engine) HintError!void {
        const e = try self.value_stack.pop();
        return self.doJump(e != 0);
    }

    fn opJmpr(self: *Engine) HintError!void {
        return self.doJump(true);
    }

    fn opJrof(self: *Engine) HintError!void {
        const e = try self.value_stack.pop();
        return self.doJump(e == 0);
    }

    fn doJump(self: *Engine, take_jump: bool) HintError!void {
        const jump_offset = (try self.value_stack.pop()) -% 1;
        if (take_jump) {
            if (jump_offset < 0) {
                if (jump_offset == -1) return error.InvalidJump;
                try self.loop_budget.doingBackwardJump();
            }
            const pc: isize = @bitCast(@as(usize, self.program.decoder.pc));
            self.program.decoder.pc = @bitCast(pc +% @as(isize, jump_offset));
        }
    }

    fn decodeNextOpcode(self: *Engine) HintError!u8 {
        const ins = (try self.program.decoder.decode()) orelse return error.UnexpectedEndOfBytecode;
        return ins.opcode;
    }

    // ------------------------------------------------------- definitions/ops

    const DefKind = enum { function, instruction };

    fn opFdef(self: *Engine) HintError!void {
        const f = try self.value_stack.pop();
        return self.doDef(.function, f);
    }

    fn opEndf(self: *Engine) HintError!void {
        return self.program.leave();
    }

    fn opCall(self: *Engine) HintError!void {
        const f = try self.value_stack.pop();
        return self.doCall(.function, 1, f);
    }

    fn opLoopcall(self: *Engine) HintError!void {
        const f = try self.value_stack.pop();
        const count = try self.value_stack.pop();
        if (count > 0) {
            try self.loop_budget.doingLoopCall(@intCast(count));
            return self.doCall(.function, @intCast(count), f);
        }
    }

    fn opIdef(self: *Engine) HintError!void {
        const opcode = try self.value_stack.pop();
        return self.doDef(.instruction, opcode);
    }

    fn opUnknown(self: *Engine, opcode: u8) HintError!void {
        return self.doCall(.instruction, 1, opcode);
    }

    fn doDef(self: *Engine, kind: DefKind, key: i32) HintError!void {
        if (self.program.initial == .glyph) return error.DefinitionInGlyphProgram;
        const defs = switch (kind) {
            .function => &self.definitions.functions,
            .instruction => &self.definitions.instructions,
        };
        const def = try defs.allocate(key);
        const start = self.program.decoder.pc;
        while (try self.program.decoder.decode()) |ins| {
            switch (ins.opcode) {
                0x2C, 0x89 => return error.NestedDefinition,
                0x2D => {
                    const end = ins.pc + 1;
                    if (self.graphics.is_pedantic and end - start > 0xFFFF) {
                        def.* = .{};
                        return error.DefinitionTooLarge;
                    }
                    def.* = Definition.new(self.program.current, start, end, key);
                    return;
                },
                else => {},
            }
        }
        return error.UnexpectedEndOfBytecode;
    }

    fn doCall(self: *Engine, kind: DefKind, count: u32, key: i32) HintError!void {
        if (count == 0) return;
        const def: *const Definition = switch (kind) {
            .function => try self.definitions.functions.get(key),
            .instruction => self.definitions.instructions.get(key) catch |err| switch (err) {
                error.InvalidDefinition => return error.UnhandledOpcode,
                else => return err,
            },
        };
        return self.program.enter(def.*, count);
    }

    // ---------------------------------------------------------- graphics ops

    fn opSvtca(self: *Engine, opcode: u8) HintError!void {
        const op: i32 = opcode;
        const x: i32 = (op & 1) << 14;
        const y: i32 = x ^ 0x4000;
        if (op < 4) {
            self.graphics.proj_vector = .{ .x = x, .y = y };
            self.graphics.dual_proj_vector = .{ .x = x, .y = y };
        }
        if (op & 2 == 0) {
            self.graphics.freedom_vector = .{ .x = x, .y = y };
        }
        self.graphics.updateProjectionState();
    }

    fn opSvtl(self: *Engine, opcode: u8) HintError!void {
        const index1 = try self.value_stack.popUsize();
        const index2 = try self.value_stack.popUsize();
        const is_parallel = opcode & 1 == 0;
        const p1 = try self.graphics.zp1Const().point(index2);
        const p2 = try self.graphics.zp2Const().point(index1);
        const vector = lineVector(p1, p2, is_parallel);
        if (opcode < 8) {
            self.graphics.proj_vector = vector;
            self.graphics.dual_proj_vector = vector;
        } else {
            self.graphics.freedom_vector = vector;
        }
        self.graphics.updateProjectionState();
    }

    fn opSdpvtl(self: *Engine, opcode: u8) HintError!void {
        const index1 = try self.value_stack.popUsize();
        const index2 = try self.value_stack.popUsize();
        const is_parallel = opcode & 1 == 0;
        {
            const p1 = try self.graphics.zp1Const().originalPoint(index2);
            const p2 = try self.graphics.zp2Const().originalPoint(index1);
            self.graphics.dual_proj_vector = lineVector(p1, p2, is_parallel);
        }
        {
            const p1 = try self.graphics.zp1Const().point(index2);
            const p2 = try self.graphics.zp2Const().point(index1);
            self.graphics.proj_vector = lineVector(p1, p2, is_parallel);
        }
        self.graphics.updateProjectionState();
    }

    fn opSpvfs(self: *Engine) HintError!void {
        const y = @as(i16, @truncate(try self.value_stack.pop()));
        const x = @as(i16, @truncate(try self.value_stack.pop()));
        const vector = if (x == 0 and y == 0)
            self.graphics.proj_vector
        else
            normalize14(x, y);
        self.graphics.proj_vector = vector;
        self.graphics.dual_proj_vector = vector;
        self.graphics.updateProjectionState();
    }

    fn opSfvfs(self: *Engine) HintError!void {
        const y = @as(i16, @truncate(try self.value_stack.pop()));
        const x = @as(i16, @truncate(try self.value_stack.pop()));
        const vector = if (x == 0 and y == 0)
            self.graphics.freedom_vector
        else
            normalize14(x, y);
        self.graphics.freedom_vector = vector;
        self.graphics.updateProjectionState();
    }

    fn opGpv(self: *Engine) HintError!void {
        const vector = self.graphics.proj_vector;
        try self.value_stack.push(vector.x);
        try self.value_stack.push(vector.y);
    }

    fn opGfv(self: *Engine) HintError!void {
        const vector = self.graphics.freedom_vector;
        try self.value_stack.push(vector.x);
        try self.value_stack.push(vector.y);
    }

    fn opSfvtpv(self: *Engine) HintError!void {
        self.graphics.freedom_vector = self.graphics.proj_vector;
        self.graphics.updateProjectionState();
    }

    fn opSrp0(self: *Engine) HintError!void {
        self.graphics.rp0 = try self.value_stack.popUsize();
    }

    fn opSrp1(self: *Engine) HintError!void {
        self.graphics.rp1 = try self.value_stack.popUsize();
    }

    fn opSrp2(self: *Engine) HintError!void {
        self.graphics.rp2 = try self.value_stack.popUsize();
    }

    fn opSzp0(self: *Engine) HintError!void {
        self.graphics.zp0 = try ZonePointer.fromInt(try self.value_stack.pop());
    }

    fn opSzp1(self: *Engine) HintError!void {
        self.graphics.zp1 = try ZonePointer.fromInt(try self.value_stack.pop());
    }

    fn opSzp2(self: *Engine) HintError!void {
        self.graphics.zp2 = try ZonePointer.fromInt(try self.value_stack.pop());
    }

    fn opSzps(self: *Engine) HintError!void {
        const zp = try ZonePointer.fromInt(try self.value_stack.pop());
        self.graphics.zp0 = zp;
        self.graphics.zp1 = zp;
        self.graphics.zp2 = zp;
    }

    fn opSloop(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        if (n < 0) return error.NegativeLoopCounter;
        self.graphics.loop_counter = @min(@as(u32, @intCast(n)), 0xFFFF);
    }

    fn opSmd(self: *Engine) HintError!void {
        self.graphics.min_distance = try self.value_stack.pop();
    }

    fn opScvtci(self: *Engine) HintError!void {
        self.graphics.control_value_cutin = try self.value_stack.pop();
    }

    fn opSswci(self: *Engine) HintError!void {
        self.graphics.single_width_cutin = try self.value_stack.pop();
    }

    fn opSsw(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        self.graphics.single_width = mul(n, self.graphics.scale);
    }

    fn opFlipon(self: *Engine) HintError!void {
        self.graphics.auto_flip = true;
    }

    fn opFlipoff(self: *Engine) HintError!void {
        self.graphics.auto_flip = false;
    }

    fn opSdb(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        self.graphics.delta_base = @truncate(@as(u32, @bitCast(n)));
    }

    fn opSds(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        if (@as(u32, @bitCast(n)) > 6) return error.InvalidStackValue;
        self.graphics.delta_shift = @truncate(@as(u32, @bitCast(n)));
    }

    fn opScanctrl(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        const threshold = n & 0xFF;
        switch (threshold) {
            0xFF => self.graphics.scan_control = true,
            0 => self.graphics.scan_control = false,
            else => {
                const ppem = self.graphics.ppem;
                const is_rotated = self.graphics.is_rotated;
                const is_stretched = self.graphics.is_stretched;
                if ((n & 0x100) != 0 and ppem <= threshold) self.graphics.scan_control = true;
                if ((n & 0x200) != 0 and is_rotated) self.graphics.scan_control = true;
                if ((n & 0x400) != 0 and is_stretched) self.graphics.scan_control = true;
                if ((n & 0x800) != 0 and ppem > threshold) self.graphics.scan_control = false;
                if ((n & 0x1000) != 0 and is_rotated) self.graphics.scan_control = false;
                if ((n & 0x2000) != 0 and is_stretched) self.graphics.scan_control = false;
            },
        }
    }

    fn opScantype(self: *Engine) HintError!void {
        const n = try self.value_stack.pop();
        self.graphics.scan_type = n & 0xFFFF;
    }

    fn opInstctrl(self: *Engine) HintError!void {
        const selector: u32 = @bitCast(try self.value_stack.pop());
        const value: u32 = @bitCast(try self.value_stack.pop());
        if (selector < 1 or selector > 3) return;
        const selector_flag: u32 = @as(u32, 1) << @intCast(selector - 1);
        if (value != 0 and value != selector_flag) return;
        if (selector == 3 and self.graphics.target.preserveLinearMetrics()) return;
        switch (self.program.initial) {
            .control_value => {
                self.graphics.instruct_control &= ~@as(u8, @truncate(selector_flag));
                self.graphics.instruct_control |= @truncate(value);
            },
            .glyph => {
                if (selector == 3) {
                    self.graphics.backward_compatibility = value != 4;
                }
            },
            .font => {},
        }
    }

    // ----------------------------------------------------------- outline ops

    fn opFlippt(self: *Engine) HintError!void {
        const gs = &self.graphics;
        const count = gs.loop_counter;
        gs.loop_counter = 1;
        if (gs.backward_compatibility and gs.did_iup_x and gs.did_iup_y) {
            for (0..count) |_| {
                _ = try self.value_stack.popUsize();
            }
            return;
        }
        const zone = gs.zone(.glyph);
        for (0..count) |_| {
            const p = try self.value_stack.popUsize();
            try zone.flipOnCurve(p);
        }
    }

    fn opFliprgon(self: *Engine) HintError!void {
        return self.setOnCurveForRange(true);
    }

    fn opFliprgoff(self: *Engine) HintError!void {
        return self.setOnCurveForRange(false);
    }

    fn setOnCurveForRange(self: *Engine, on: bool) HintError!void {
        const high_point = try self.value_stack.popUsize();
        const low_point = try self.value_stack.popUsize();
        const high_end = std.math.add(usize, high_point, 1) catch return error.InvalidPointIndex;
        if (self.graphics.backward_compatibility and
            self.graphics.did_iup_x and self.graphics.did_iup_y)
        {
            return;
        }
        return self.graphics.zone(.glyph).setOnCurve(low_point, high_end, on);
    }

    fn opShp(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const disp = try gs.pointDisplacement(opcode);
        const count = gs.loop_counter;
        gs.loop_counter = 1;
        for (0..count) |_| {
            const p = try self.value_stack.popUsize();
            try gs.moveZp2Point(p, disp.dx, disp.dy, true);
        }
    }

    fn opShc(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const contour_ix = try self.value_stack.popUsize();
        if (!gs.is_pedantic and contour_ix >= gs.zp2Const().contours.len) return;
        const disp = try gs.pointDisplacement(opcode);
        const start: usize = if (contour_ix != 0)
            @as(usize, try gs.zp2Const().contour(contour_ix - 1)) + 1
        else
            0;
        const end: usize = if (gs.zp2.isTwilight())
            gs.zp2Const().points.len
        else
            @as(usize, try gs.zp2Const().contour(contour_ix)) + 1;
        for (start..end) |i| {
            if (disp.zone != gs.zp2 or disp.point_ix != i) {
                try gs.moveZp2Point(i, disp.dx, disp.dy, true);
            }
        }
    }

    fn opShz(self: *Engine, opcode: u8) HintError!void {
        _ = try ZonePointer.fromInt(try self.value_stack.pop());
        const gs = &self.graphics;
        const disp = try gs.pointDisplacement(opcode);
        const end: usize = if (gs.zp2.isTwilight())
            gs.zp2Const().points.len
        else if (gs.zp2Const().contours.len != 0)
            @as(usize, gs.zp2Const().contours[gs.zp2Const().contours.len - 1]) + 1
        else
            0;
        for (0..end) |i| {
            if (disp.zone != gs.zp2 or i != disp.point_ix) {
                try gs.moveZp2Point(i, disp.dx, disp.dy, false);
            }
        }
    }

    fn opShpix(self: *Engine) HintError!void {
        const gs = &self.graphics;
        const in_twilight = gs.zp0.isTwilight() or gs.zp1.isTwilight() or gs.zp2.isTwilight();
        const amount = try self.value_stack.pop();
        const dx = mul14(amount, gs.freedom_vector.x);
        const dy = mul14(amount, gs.freedom_vector.y);
        const count = gs.loop_counter;
        gs.loop_counter = 1;
        const did_iup = gs.did_iup_x and gs.did_iup_y;
        for (0..count) |_| {
            const p = try self.value_stack.popUsize();
            if (gs.backward_compatibility) {
                if (in_twilight or
                    (!did_iup and
                        ((gs.is_composite and gs.freedom_vector.y != 0) or
                            try gs.zp2Const().isTouched(p, .y))))
                {
                    try gs.moveZp2Point(p, dx, dy, true);
                }
            } else {
                try gs.moveZp2Point(p, dx, dy, true);
            }
        }
    }

    fn opMsirp(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const distance = try self.value_stack.pop();
        const point_ix = try self.value_stack.popUsize();
        if (!gs.is_pedantic and !gs.inBounds2(.{ gs.zp1, point_ix }, .{ gs.zp0, gs.rp0 })) return;
        if (gs.zp1.isTwilight()) {
            const rp0_original = try gs.zp0Const().originalPoint(gs.rp0);
            const zone = gs.zp1Mut();
            if (point_ix >= zone.points.len or point_ix >= zone.original.len) {
                return error.InvalidPointIndex;
            }
            zone.points[point_ix] = rp0_original;
            try gs.moveOriginal(gs.zp1, point_ix, distance);
            zone.points[point_ix] = zone.original[point_ix];
        }
        const d = gs.project(
            try gs.zp1Const().point(point_ix),
            try gs.zp0Const().point(gs.rp0),
        );
        try gs.movePoint(gs.zp1, point_ix, distance -% d);
        gs.rp1 = gs.rp0;
        gs.rp2 = point_ix;
        if ((opcode & 1) != 0) gs.rp0 = point_ix;
    }

    fn opMdap(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const p = try self.value_stack.popUsize();
        if (!gs.is_pedantic and !gs.inBounds1(.{ gs.zp0, p })) {
            gs.rp0 = p;
            gs.rp1 = p;
            return;
        }
        const distance: i32 = if ((opcode & 1) != 0) blk: {
            const cur_dist = gs.project(try gs.zp0Const().point(p), .{});
            break :blk gs.roundDistance(cur_dist) -% cur_dist;
        } else 0;
        try gs.movePoint(gs.zp0, p, distance);
        gs.rp0 = p;
        gs.rp1 = p;
    }

    fn opMiap(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const cvt_entry = try self.value_stack.popUsize();
        const point_ix = try self.value_stack.popUsize();
        var distance = try self.cvt.get(cvt_entry);
        if (gs.zp0.isTwilight()) {
            const fv = gs.freedom_vector;
            const z = gs.zp0Mut();
            if (point_ix >= z.original.len or point_ix >= z.points.len) {
                return error.InvalidPointIndex;
            }
            z.original[point_ix] = .{
                .x = mul14(distance, fv.x),
                .y = mul14(distance, fv.y),
            };
            z.points[point_ix] = z.original[point_ix];
        }
        const original_distance = gs.project(try gs.zp0Const().point(point_ix), .{});
        if ((opcode & 1) != 0) {
            const delta = wrappingAbs(distance -% original_distance);
            if (delta > gs.control_value_cutin) distance = original_distance;
            distance = gs.roundDistance(distance);
        }
        try gs.movePoint(gs.zp0, point_ix, distance -% original_distance);
        gs.rp0 = point_ix;
        gs.rp1 = point_ix;
    }

    fn opMdrp(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const p = try self.value_stack.popUsize();
        if (!gs.is_pedantic and !gs.inBounds2(.{ gs.zp1, p }, .{ gs.zp0, gs.rp0 })) {
            gs.rp1 = gs.rp0;
            gs.rp2 = p;
            if ((opcode & 16) != 0) gs.rp0 = p;
            return;
        }
        var original_distance: i32 = if (gs.zp0.isTwilight() or gs.zp1.isTwilight())
            gs.dualProject(
                try gs.zp1Const().originalPoint(p),
                try gs.zp0Const().originalPoint(gs.rp0),
            )
        else blk: {
            const v1 = gs.zp1Const().unscaledPoint(p);
            const v2 = gs.zp0Const().unscaledPoint(gs.rp0);
            const dist = gs.dualProjectUnscaled(v1, v2);
            break :blk mul(dist, gs.unscaledToPixels());
        };
        const cutin = gs.single_width_cutin;
        const value = gs.single_width;
        if (cutin > 0 and original_distance < value +% cutin and original_distance > value -% cutin) {
            original_distance = if (original_distance >= 0) value else -%value;
        }
        var distance: i32 = if ((opcode & 4) != 0)
            gs.roundDistance(original_distance)
        else
            original_distance;
        if ((opcode & 8) != 0) {
            const min_distance = gs.min_distance;
            if (original_distance >= 0) {
                if (distance < min_distance) distance = min_distance;
            } else if (distance > -%min_distance) {
                distance = -%min_distance;
            }
        }
        original_distance = gs.project(
            try gs.zp1Const().point(p),
            try gs.zp0Const().point(gs.rp0),
        );
        try gs.movePoint(gs.zp1, p, distance -% original_distance);
        gs.rp1 = gs.rp0;
        gs.rp2 = p;
        if ((opcode & 16) != 0) gs.rp0 = p;
    }

    fn opMirp(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const n_raw = try self.value_stack.pop();
        const n_plus_one: i32 = n_raw +% 1;
        const n: usize = @bitCast(@as(isize, n_plus_one));
        const p = try self.value_stack.popUsize();
        if (!gs.is_pedantic and
            (!gs.inBounds2(.{ gs.zp1, p }, .{ gs.zp0, gs.rp0 }) or n > self.cvt.len()))
        {
            gs.rp1 = gs.rp0;
            if ((opcode & 16) != 0) gs.rp0 = p;
            gs.rp2 = p;
            return;
        }
        var cvt_distance: i32 = if (n == 0) 0 else try self.cvt.get(n - 1);
        const cutin = gs.single_width_cutin;
        const value = gs.single_width;
        var delta = wrappingAbs(cvt_distance -% value);
        if (delta < cutin) {
            cvt_distance = if (cvt_distance >= 0) value else -%value;
        }
        if (gs.zp1.isTwilight()) {
            const fv = gs.freedom_vector;
            const rp0_original = try gs.zp0Const().originalPoint(gs.rp0);
            const zone = gs.zp1Mut();
            if (p >= zone.original.len or p >= zone.points.len) {
                return error.InvalidPointIndex;
            }
            zone.original[p] = .{
                .x = rp0_original.x +% mul(cvt_distance, fv.x),
                .y = rp0_original.y +% mul(cvt_distance, fv.y),
            };
            zone.points[p] = zone.original[p];
        }
        const original_distance = gs.dualProject(
            try gs.zp1Const().originalPoint(p),
            try gs.zp0Const().originalPoint(gs.rp0),
        );
        const current_distance = gs.project(
            try gs.zp1Const().point(p),
            try gs.zp0Const().point(gs.rp0),
        );
        if (gs.auto_flip and (original_distance ^ cvt_distance) < 0) {
            cvt_distance = -%cvt_distance;
        }
        var distance: i32 = if ((opcode & 4) != 0) blk: {
            if (gs.zp0 == gs.zp1) {
                delta = wrappingAbs(cvt_distance -% original_distance);
                if (delta > gs.control_value_cutin) cvt_distance = original_distance;
            }
            break :blk gs.roundDistance(cvt_distance);
        } else cvt_distance;
        if ((opcode & 8) != 0) {
            const min_distance = gs.min_distance;
            if (original_distance >= 0) {
                if (distance < min_distance) distance = min_distance;
            } else if (distance > -%min_distance) {
                distance = -%min_distance;
            }
        }
        try gs.movePoint(gs.zp1, p, distance -% current_distance);
        gs.rp1 = gs.rp0;
        if ((opcode & 16) != 0) gs.rp0 = p;
        gs.rp2 = p;
    }

    fn opAlignrp(self: *Engine) HintError!void {
        const gs = &self.graphics;
        const count = gs.loop_counter;
        gs.loop_counter = 1;
        for (0..count) |_| {
            const p = try self.value_stack.popUsize();
            const distance = gs.project(
                try gs.zp1Const().point(p),
                try gs.zp0Const().point(gs.rp0),
            );
            try gs.movePoint(gs.zp1, p, -%distance);
        }
    }

    fn opIsect(self: *Engine) HintError!void {
        const gs = &self.graphics;
        const b1 = try self.value_stack.popUsize();
        const b0 = try self.value_stack.popUsize();
        const a1 = try self.value_stack.popUsize();
        const a0 = try self.value_stack.popUsize();
        const point_ix = try self.value_stack.popUsize();
        const pa0_t = try gs.zp1Const().point(a0);
        const pa1_t = try gs.zp1Const().point(a1);
        const pb0_t = try gs.zp0Const().point(b0);
        const pb1_t = try gs.zp0Const().point(b1);
        const pa0 = pa0_t;
        const pa1 = pa1_t;
        const pb0 = pb0_t;
        const pb1 = pb1_t;
        const dbx = pb1.x -% pb0.x;
        const dby = pb1.y -% pb0.y;
        const dax = pa1.x -% pa0.x;
        const day = pa1.y -% pa0.y;
        const dx = pb0.x -% pa0.x;
        const dy = pb0.y -% pa0.y;
        const discriminant = mulDiv(dax, -%dby, 0x40) +% mulDiv(day, dbx, 0x40);
        const dotproduct = mulDiv(dax, dbx, 0x40) +% mulDiv(day, dby, 0x40);
        const zone = gs.zp2Mut();
        if (point_ix >= zone.points.len) return error.InvalidPointIndex;
        if (wrappingAbs(discriminant) *% 19 > wrappingAbs(dotproduct)) {
            const v = mulDiv(dx, -%dby, 0x40) +% mulDiv(dy, dbx, 0x40);
            const x = mulDiv(v, dax, discriminant);
            const y = mulDiv(v, day, discriminant);
            zone.points[point_ix] = .{ .x = pa0.x +% x, .y = pa0.y +% y };
        } else {
            zone.points[point_ix] = .{
                .x = @divTrunc(pa0.x +% pa1.x +% pb0.x +% pb1.x, 4),
                .y = @divTrunc(pa0.y +% pa1.y +% pb0.y +% pb1.y, 4),
            };
        }
        try zone.touch(point_ix, .both);
    }

    fn opAlignpts(self: *Engine) HintError!void {
        const p2 = try self.value_stack.popUsize();
        const p1 = try self.value_stack.popUsize();
        const gs = &self.graphics;
        const distance = @divTrunc(
            gs.project(try gs.zp0Const().point(p2), try gs.zp1Const().point(p1)),
            2,
        );
        try gs.movePoint(gs.zp1, p1, distance);
        try gs.movePoint(gs.zp0, p2, -%distance);
    }

    fn opIp(self: *Engine) HintError!void {
        const gs = &self.graphics;
        const count = gs.loop_counter;
        gs.loop_counter = 1;
        if (!gs.is_pedantic and !gs.inBounds2(.{ gs.zp0, gs.rp1 }, .{ gs.zp1, gs.rp2 })) return;
        const in_twilight = gs.zp0.isTwilight() or gs.zp1.isTwilight() or gs.zp2.isTwilight();
        const orus_base: Point = if (in_twilight)
            try gs.zp0Const().originalPoint(gs.rp1)
        else
            gs.zp0Const().unscaledPoint(gs.rp1);
        const cur_base = try gs.zp0Const().point(gs.rp1);
        const old_range: i32 = if (in_twilight)
            gs.dualProject(try gs.zp1Const().originalPoint(gs.rp2), orus_base)
        else
            gs.dualProject(gs.zp1Const().unscaledPoint(gs.rp2), orus_base);
        const cur_range = gs.project(try gs.zp1Const().point(gs.rp2), cur_base);
        for (0..count) |_| {
            const point = try self.value_stack.popUsize();
            if (!gs.is_pedantic and !gs.inBounds1(.{ gs.zp2, point })) continue;
            const original_distance: i32 = if (in_twilight)
                gs.dualProject(try gs.zp2Const().originalPoint(point), orus_base)
            else
                gs.dualProject(gs.zp2Const().unscaledPoint(point), orus_base);
            const cur_distance = gs.project(try gs.zp2Const().point(point), cur_base);
            const new_distance: i32 = if (original_distance != 0)
                (if (old_range != 0)
                    mulDiv(original_distance, cur_range, old_range)
                else
                    original_distance)
            else
                0;
            try gs.movePoint(gs.zp2, point, new_distance -% cur_distance);
        }
    }

    fn opIup(self: *Engine, opcode: u8) HintError!void {
        const gs = &self.graphics;
        const axis: CoordAxis = if ((opcode & 1) != 0) .x else .y;
        var should_run = true;
        if (gs.backward_compatibility) {
            if (gs.did_iup_x and gs.did_iup_y) should_run = false;
            if (axis == .x) {
                gs.did_iup_x = true;
            } else {
                gs.did_iup_y = true;
            }
        }
        if (should_run) {
            const zone = gs.zone(.glyph);
            try zone.iup(axis);
        }
    }

    fn opUtp(self: *Engine) HintError!void {
        const p = try self.value_stack.popUsize();
        const coord_axis: ?CoordAxis = switch (self.graphics.freedom_vector.x != 0) {
            true => switch (self.graphics.freedom_vector.y != 0) {
                true => .both,
                false => .x,
            },
            false => switch (self.graphics.freedom_vector.y != 0) {
                true => .y,
                false => null,
            },
        };
        if (coord_axis) |axis| {
            try self.graphics.zp0Mut().untouch(p, axis);
        }
    }
};

/// Computes a parallel or perpendicular normalized vector for the line
/// between the two given points.
fn lineVector(p1: Point, p2: Point, is_parallel: bool) Point {
    var a = p1.x -% p2.x;
    var b = p1.y -% p2.y;
    if (a == 0 and b == 0) {
        a = 0x4000;
    } else if (!is_parallel) {
        const c = b;
        b = a;
        a = -%c;
    }
    return normalize14(a, b);
}

// ----------------------------------------------------------------- instance

/// Outline data that is passed to the hinter.
pub const HintOutline = struct {
    glyph_id: GlyphId = 0,
    unscaled: []const Point = &.{},
    scaled: []Point = &.{},
    original_scaled: []Point = &.{},
    flags: []u8 = &.{},
    contours: []const u16 = &.{},
    /// The four phantom points (horizontal lsb/advance, vertical tsb/descent).
    phantom: []Point = &.{},
    bytecode: []const u8 = &.{},
    stack: []i32 = &.{},
    cvt: []i32 = &.{},
    storage: []i32 = &.{},
    twilight_scaled: []Point = &.{},
    twilight_original_scaled: []Point = &.{},
    twilight_flags: []u8 = &.{},
    is_composite: bool = false,
    coords: []const i16 = &.{},
};

/// Instance state for TrueType hinting.
///
/// `reconfigure` runs `fpgm` + `prep` and retains the resulting graphics
/// state (upstream `HintInstance`). One instance can be reused across sizes
/// and fonts; `glyf.zig` caches instances through glifo's `HintCache`.
pub const HintInstance = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(Definition) = .empty,
    instructions: std.ArrayList(Definition) = .empty,
    cvt: std.ArrayList(i32) = .empty,
    storage: std.ArrayList(i32) = .empty,
    twilight_scaled: std.ArrayList(Point) = .empty,
    twilight_original_scaled: std.ArrayList(Point) = .empty,
    twilight_flags: std.ArrayList(u8) = .empty,
    /// Owned copy of the normalized coordinates, used for cache-key equality
    /// (`HintKey.coords` upstream) and `cvar` deltas during setup.
    coords: std.ArrayList(i16) = .empty,
    graphics: RetainedGraphicsState = .{},
    axis_count: u16 = 0,
    max_stack: usize = 0,
    /// The requested (unrounded) ppem, used when hinting is disabled.
    size: f32 = 0,
    target: Target = Target.default,

    pub fn init(allocator: std.mem.Allocator) HintInstance {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HintInstance) void {
        self.functions.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
        self.cvt.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        self.twilight_scaled.deinit(self.allocator);
        self.twilight_original_scaled.deinit(self.allocator);
        self.twilight_flags.deinit(self.allocator);
        self.coords.deinit(self.allocator);
        self.* = undefined;
    }

    /// The normalized coordinates this instance was configured for
    /// (`HintingInstance::location`).
    pub fn location(self: *const HintInstance) []const i16 {
        return self.coords.items;
    }

    /// Reconfigures this instance for a new font/size/location, running the
    /// font and control value programs.
    pub fn reconfigure(
        self: *HintInstance,
        data: ProgramData,
        scale: i32,
        ppem: i32,
        target: Target,
        coords: []const i16,
        size: f32,
    ) HintError!void {
        self.size = size;
        self.target = target;
        try self.coords.resize(self.allocator, coords.len);
        @memcpy(self.coords.items, coords);
        try self.setup(data, scale, ppem, coords, target, size);
        const twilight_count: u16 = @intCast(self.twilight_scaled.items.len);
        const twilight_contours = [1]u16{twilight_count};
        const twilight = Zone{
            .unscaled = &.{},
            .original = self.twilight_original_scaled.items,
            .points = self.twilight_scaled.items,
            .flags = self.twilight_flags.items,
            .contours = &twilight_contours,
        };
        const glyph = Zone{};
        const stack_buf = try self.allocator.alloc(i32, self.max_stack);
        defer self.allocator.free(stack_buf);
        const value_stack = ValueStack.init(stack_buf, false);
        var engine = Engine.new(
            ProgramState.new(data.fpgm, data.prep, &.{}, .font),
            RetainedGraphicsState.new(scale, ppem, target),
            .{
                .functions = .{ .mut = self.functions.items },
                .instructions = .{ .mut = self.instructions.items },
            },
            CowSlice.newMut(self.cvt.items),
            CowSlice.newMut(self.storage.items),
            value_stack,
            twilight,
            glyph,
            data.axis_count,
            coords,
            false,
        );
        try engine.runProgram(.font, false);
        try engine.runProgram(.control_value, false);
        self.graphics = engine.graphics.retainedCopy();
    }

    /// Returns true if hinting should actually be applied; the CVT program
    /// can disable it via `INSTCTRL`.
    pub fn isEnabled(self: *const HintInstance) bool {
        return self.graphics.instruct_control & 1 == 0;
    }

    /// True if backward compatibility mode has been activated by the hinter
    /// settings or the `prep` table.
    pub fn backwardCompatibility(self: *const HintInstance) bool {
        if (self.graphics.target.preserveLinearMetrics()) return true;
        if (self.graphics.target.isSmooth()) return (self.graphics.instruct_control & 0x4) == 0;
        return false;
    }

    /// Runs the glyph program for one outline.
    pub fn hint(
        self: *const HintInstance,
        data: ProgramData,
        outline: *HintOutline,
        is_pedantic: bool,
    ) HintError!void {
        if (outline.twilight_scaled.len != self.twilight_scaled.items.len or
            outline.twilight_original_scaled.len != self.twilight_original_scaled.items.len or
            outline.twilight_flags.len != self.twilight_flags.items.len)
        {
            return error.InvalidPointRange;
        }
        @memcpy(outline.twilight_original_scaled, self.twilight_original_scaled.items);
        @memcpy(outline.twilight_scaled, self.twilight_scaled.items);
        @memcpy(outline.twilight_flags, self.twilight_flags.items);
        const twilight_count: u16 = @intCast(outline.twilight_scaled.len);
        const twilight_contours = [1]u16{twilight_count};
        const twilight = Zone{
            .unscaled = &.{},
            .original = outline.twilight_original_scaled,
            .points = outline.twilight_scaled,
            .flags = outline.twilight_flags,
            .contours = &twilight_contours,
        };
        const glyph = Zone{
            .unscaled = outline.unscaled,
            .original = outline.original_scaled,
            .points = outline.scaled,
            .flags = outline.flags,
            .contours = outline.contours,
        };
        if (self.cvt.items.len != outline.cvt.len) return error.CvtSizeMismatch;
        if (self.storage.items.len != outline.storage.len) return error.StorageSizeMismatch;
        const value_stack = ValueStack.init(outline.stack, is_pedantic);
        const cvt = CowSlice.new(self.cvt.items, outline.cvt);
        const storage = CowSlice.new(self.storage.items, outline.storage);
        var engine = Engine.new(
            ProgramState.new(data.fpgm, data.prep, outline.bytecode, .glyph),
            self.graphics,
            .{
                .functions = .{ .ref = self.functions.items },
                .instructions = .{ .ref = self.instructions.items },
            },
            cvt,
            storage,
            value_stack,
            twilight,
            glyph,
            self.axis_count,
            outline.coords,
            outline.is_composite,
        );
        try engine.runProgram(.glyph, is_pedantic);
        // If we're not running in backward compatibility mode, capture
        // modified phantom points.
        if (!engine.graphics.backward_compatibility) {
            const len = outline.scaled.len;
            if (len < 4 or outline.phantom.len < 4) return error.InvalidPointIndex;
            for (0..4) |i| {
                outline.phantom[i] = outline.scaled[len - 4 + i];
            }
        }
    }

    /// Captures limits, resizes buffers and scales the CVT.
    fn setup(
        self: *HintInstance,
        data: ProgramData,
        scale: i32,
        ppem: i32,
        coords: []const i16,
        target: Target,
        size: f32,
    ) HintError!void {
        _ = size;
        self.axis_count = data.axis_count;
        self.functions.clearRetainingCapacity();
        try self.functions.resize(self.allocator, data.max_function_defs);
        for (self.functions.items) |*def| def.* = .{};
        self.instructions.clearRetainingCapacity();
        try self.instructions.resize(self.allocator, data.max_instruction_defs);
        for (self.instructions.items) |*def| def.* = .{};
        // CVT entries are converted to 26.6 on load; `cvar` deltas (when the
        // table exists) are accumulated in 16.16 first and converted, exactly
        // like `HintInstance::setup`.
        const cvt_len = data.cvtLen();
        self.cvt.clearRetainingCapacity();
        try self.cvt.resize(self.allocator, cvt_len);
        if (data.cvar) |cvar| {
            @memset(self.cvt.items, 0);
            // Upstream discards malformed `cvar` errors and keeps whatever
            // deltas were accumulated.
            cvar.deltas(data.axis_count, coords, self.cvt.items[0..cvt_len]) catch {};
            for (0..cvt_len) |i| {
                const delta = fixedToF26Dot6(self.cvt.items[i]);
                const base_value: i32 = @as(i32, readBeI16(data.cvt, 2 * i)) *% 64;
                self.cvt.items[i] = base_value +% delta;
            }
        } else {
            for (0..cvt_len) |i| {
                self.cvt.items[i] = @as(i32, readBeI16(data.cvt, 2 * i)) *% 64;
            }
        }
        const scale_bits = scale >> 6;
        for (self.cvt.items) |*value| {
            value.* = mul(value.*, scale_bits);
        }
        self.storage.clearRetainingCapacity();
        try self.storage.resize(self.allocator, data.max_storage);
        for (self.storage.items) |*value| value.* = 0;
        const twilight_points: usize = data.max_twilight_points;
        self.twilight_scaled.clearRetainingCapacity();
        try self.twilight_scaled.resize(self.allocator, twilight_points);
        for (self.twilight_scaled.items) |*p| p.* = .{};
        self.twilight_original_scaled.clearRetainingCapacity();
        try self.twilight_original_scaled.resize(self.allocator, twilight_points);
        for (self.twilight_original_scaled.items) |*p| p.* = .{};
        self.twilight_flags.clearRetainingCapacity();
        try self.twilight_flags.resize(self.allocator, twilight_points);
        for (self.twilight_flags.items) |*f| f.* = 0;
        self.max_stack = data.max_stack_elements;
        self.graphics = RetainedGraphicsState.new(scale, ppem, target);
    }
};

// --------------------------------------------------------------------- tests

test "fixed point helpers match skrifa vectors" {
    const mul_div_cases = [_]struct { a: i32, b: i32, c: i32, expected: i32 }{
        .{ .a = -326, .b = -11474, .c = 9942, .expected = 376 },
        .{ .a = -6781, .b = 13948, .c = 11973, .expected = -7899 },
        .{ .a = -6127, .b = 15026, .c = 2276, .expected = -40450 },
        .{ .a = 14304, .b = -10377, .c = -21, .expected = 7068219 },
    };
    for (mul_div_cases) |case| {
        try std.testing.expectEqual(case.expected, mulDivNoRound(case.a, case.b, case.c));
    }
    const mul14_cases = [_]struct { a: i32, b: i32, expected: i32 }{
        .{ .a = 6236, .b = -10078, .expected = -3836 },
        .{ .a = -6803, .b = -5405, .expected = 2244 },
        .{ .a = 316, .b = 3390, .expected = 65 },
        .{ .a = -678, .b = -2205, .expected = 91 },
    };
    for (mul14_cases) |case| {
        try std.testing.expectEqual(case.expected, mul14(case.a, case.b));
    }
    const normalize_cases = [_]struct { x: i32, y: i32, ex: i32, ey: i32 }{
        .{ .x = -13660, .y = 11807, .ex = -12395, .ey = 10713 },
        .{ .x = -3673, .y = 673, .ex = -16115, .ey = 2952 },
        .{ .x = 0x4000, .y = 0, .ex = 0x4000, .ey = 0 },
        .{ .x = 0, .y = -0x4000, .ex = 0, .ey = -0x4000 },
    };
    for (normalize_cases) |case| {
        const n = normalize14(case.x, case.y);
        try std.testing.expectEqual(case.ex, n.x);
        try std.testing.expectEqual(case.ey, n.y);
    }
}

test "round state vectors" {
    const cases = [_]struct { mode: RoundMode, value: i32, expected: i32 }{
        .{ .mode = .grid, .value = 32, .expected = 64 },
        .{ .mode = .grid, .value = -32, .expected = -64 },
        .{ .mode = .half_grid, .value = 0, .expected = 32 },
        .{ .mode = .double_grid, .value = 32, .expected = 32 },
        .{ .mode = .down_to_grid, .value = 50, .expected = 0 },
        .{ .mode = .up_to_grid, .value = 50, .expected = 64 },
        .{ .mode = .off, .value = 50, .expected = 50 },
    };
    for (cases) |case| {
        var state = RoundState{ .mode = case.mode };
        try std.testing.expectEqual(case.expected, state.round(case.value));
    }
}

test "value stack operations" {
    var buf: [16]i32 = undefined;
    var stack = ValueStack.init(&buf, true);
    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try std.testing.expectEqual(@as(usize, 3), stack.depth());
    try stack.dup();
    try std.testing.expectEqual(@as(?i32, 3), stack.peek());
    try stack.swap();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 3 }, stack.valuesSlice());
    _ = try stack.pop();
    try stack.roll();
    try std.testing.expectEqualSlices(i32, &.{ 2, 3, 1 }, stack.valuesSlice());
    try std.testing.expectEqual(@as(?i32, 1), stack.peek());
    stack.clear();
    try std.testing.expectEqual(@as(usize, 0), stack.depth());
}

test "decoder reads push payloads" {
    // NPUSHB 3, 1, 2, 3; PUSHW000 -2.
    const code = [_]u8{ 0x40, 3, 1, 2, 3, 0xB8, 0xFF, 0xFE };
    var decoder = Decoder.init(&code, 0);
    const first = (try decoder.decode()).?;
    try std.testing.expectEqual(@as(u8, 0x40), first.opcode);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, first.inline_operands.slice());
    const second = (try decoder.decode()).?;
    try std.testing.expectEqual(@as(u8, 0xB8), second.opcode);
    try std.testing.expectEqualSlices(i32, &.{-2}, second.inline_operands.slice());
    try std.testing.expectEqual(@as(?Instruction, null), try decoder.decode());
}

test "engine runs empty programs" {
    var cvt_buf = [_]i32{ 10, 20 };
    var storage_buf = [_]i32{0};
    var stack_buf = [_]i32{0};
    var twilight_points = [_]Point{.{}};
    var twilight_flags = [_]u8{0};
    var engine = Engine.new(
        ProgramState.new(&.{}, &.{}, &.{}, .font),
        RetainedGraphicsState.new(0x10000, 16, Target.default),
        .{ .functions = .{ .mut = &.{} }, .instructions = .{ .mut = &.{} } },
        CowSlice.newMut(&cvt_buf),
        CowSlice.newMut(&storage_buf),
        ValueStack.init(&stack_buf, false),
        Zone{ .points = &twilight_points, .flags = &twilight_flags },
        Zone{},
        0,
        &.{},
        false,
    );
    try engine.runProgram(.font, false);
    try engine.runProgram(.control_value, false);
    try engine.runProgram(.glyph, false);
}

test "hint instance applies an empty fpgm and cvt program" {
    const data = ProgramData{ .cvt = &.{ 0x00, 0x40, 0xFF, 0xC0 } };
    var instance = HintInstance.init(std.testing.allocator);
    defer instance.deinit();
    try instance.reconfigure(data, 0x8000, 16, Target.default, &.{}, 16.0);
    try std.testing.expect(instance.isEnabled());
    try std.testing.expect(instance.cvt.items.len == 2);
    // 1.0 in font units scaled by 0.5 -> 32 in 26.6.
    try std.testing.expectEqual(@as(i32, 32), instance.cvt.items[0]);
    try std.testing.expectEqual(@as(i32, -32), instance.cvt.items[1]);
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-geometry engine for instruction tests, mirroring skrifa's
/// `MockEngine` (32 unscaled points, 64 scaled points, one contour).
const MockEngine = struct {
    cvt_storage: [32]i32 = @splat(0),
    value_stack: [32]i32 = @splat(0),
    definitions: [8]Definition = @splat(.{}),
    unscaled: [32]Point = @splat(.{}),
    points: [64]Point = @splat(.{}),
    point_flags: [32]u8 = @splat(0),
    contours: [1]u16 = .{31},
    twilight: [32]Point = @splat(.{}),
    twilight_flags: [32]u8 = @splat(0),

    fn engine(self: *MockEngine) Engine {
        for (&self.unscaled, 0..) |*point, i| {
            const x: i32 = 57 + @as(i32, @intCast(i)) * 2;
            point.* = .{ .x = x, .y = -x * 3 };
        }
        const cvt = self.cvt_storage[0..16];
        const storage = self.cvt_storage[16..32];
        const functions = self.definitions[0..5];
        const instructions = self.definitions[5..8];
        return Engine.new(
            ProgramState.new(&.{}, &.{}, &.{}, .font),
            RetainedGraphicsState.new(0x10000, 16, Target.default),
            .{
                .functions = .{ .mut = functions },
                .instructions = .{ .mut = instructions },
            },
            CowSlice.newMut(cvt),
            CowSlice.newMut(storage),
            ValueStack.init(&self.value_stack, false),
            Zone{
                .unscaled = &.{},
                .original = self.twilight[0..16],
                .points = self.twilight[16..32],
                .flags = &self.twilight_flags,
                .contours = &.{},
            },
            Zone{
                .unscaled = &self.unscaled,
                .original = self.points[0..32],
                .points = self.points[32..64],
                .flags = &self.point_flags,
                .contours = &self.contours,
            },
            0,
            &.{},
            false,
        );
    }
};

test "svtca sets the coordinate axes" {
    var mock = MockEngine{};
    var engine = mock.engine();
    // freedom and projection vector to y axis
    try engine.opSvtca(0x00);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0x4000 }, engine.graphics.freedom_vector);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0x4000 }, engine.graphics.proj_vector);
    // freedom and projection vector to x axis
    try engine.opSvtca(0x01);
    try std.testing.expectEqual(Point{ .x = 0x4000, .y = 0 }, engine.graphics.freedom_vector);
    try std.testing.expectEqual(Point{ .x = 0x4000, .y = 0 }, engine.graphics.proj_vector);
    // projection vector only
    try engine.opSvtca(0x02);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0x4000 }, engine.graphics.proj_vector);
    try engine.opSvtca(0x03);
    try std.testing.expectEqual(Point{ .x = 0x4000, .y = 0 }, engine.graphics.proj_vector);
    // freedom vector only
    try engine.opSvtca(0x04);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0x4000 }, engine.graphics.freedom_vector);
    try engine.opSvtca(0x05);
    try std.testing.expectEqual(Point{ .x = 0x4000, .y = 0 }, engine.graphics.freedom_vector);
}

test "set/get vectors from the stack" {
    var mock = MockEngine{};
    var engine = mock.engine();
    const x_axis = Point{ .x = 0x4000, .y = 0 };
    const y_axis = Point{ .x = 0, .y = 0x4000 };
    try engine.value_stack.push(x_axis.x);
    try engine.value_stack.push(x_axis.y);
    try engine.opSpvfs();
    try std.testing.expectEqual(x_axis, engine.graphics.proj_vector);
    try engine.opGpv();
    const y = try engine.value_stack.pop();
    const x = try engine.value_stack.pop();
    try std.testing.expectEqual(x_axis, Point{ .x = x, .y = y });
    try engine.value_stack.push(y_axis.x);
    try engine.value_stack.push(y_axis.y);
    try engine.opSfvfs();
    try std.testing.expectEqual(y_axis, engine.graphics.freedom_vector);
    try engine.opGfv();
    const gy = try engine.value_stack.pop();
    const gx = try engine.value_stack.pop();
    try std.testing.expectEqual(y_axis, Point{ .x = gx, .y = gy });
}

test "zone iup shift and interpolate" {
    var original = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 } };
    var points = [_]Point{ .{ .x = -5, .y = -20 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 } };
    var flags = [_]u8{ marker_touched, 0, 0 };
    var zone = Zone{
        .unscaled = &.{},
        .original = &original,
        .points = &points,
        .flags = &flags,
        .contours = &.{3},
    };
    try zone.iup(.x);
    try std.testing.expectEqualSlices(Point, &[_]Point{
        .{ .x = -5, .y = -20 },
        .{ .x = 5, .y = 10 },
        .{ .x = 15, .y = 20 },
    }, &points);
    try zone.iup(.y);
    try std.testing.expectEqualSlices(Point, &[_]Point{
        .{ .x = -5, .y = -20 },
        .{ .x = 5, .y = -10 },
        .{ .x = 15, .y = 0 },
    }, &points);
}

test "zone iup interpolation between two touched points" {
    var original = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 } };
    var points = [_]Point{ .{ .x = -5, .y = -20 }, .{ .x = 10, .y = 10 }, .{ .x = 27, .y = 56 } };
    var flags = [_]u8{ marker_touched, 0, marker_touched };
    const unscaled = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 500, .y = 500 }, .{ .x = 1000, .y = 1000 } };
    var zone = Zone{
        .unscaled = &unscaled,
        .original = &original,
        .points = &points,
        .flags = &flags,
        .contours = &.{3},
    };
    try zone.iup(.x);
    try std.testing.expectEqualSlices(Point, &[_]Point{
        .{ .x = -5, .y = -20 },
        .{ .x = 11, .y = 10 },
        .{ .x = 27, .y = 56 },
    }, &points);
    try zone.iup(.y);
    try std.testing.expectEqualSlices(Point, &[_]Point{
        .{ .x = -5, .y = -20 },
        .{ .x = 11, .y = 18 },
        .{ .x = 27, .y = 56 },
    }, &points);
}

test "unknown opcodes fail typed and IDEF overrides them" {
    var mock = MockEngine{};
    var engine = mock.engine();
    // INS28 (0x28) is unused and undefined: typed UnhandledOpcode.
    var glyph_code = [_]u8{0x28};
    engine.program.bytecode[2] = &glyph_code;
    engine.program.decoder = Decoder.init(&glyph_code, 0);
    engine.program.initial = .glyph;
    engine.program.current = .glyph;
    try std.testing.expectError(error.UnhandledOpcode, engine.run());

    // IDEF 0x28 (defined in the font program) adds 2 to the top stack value.
    var mock2 = MockEngine{};
    var engine2 = mock2.engine();
    var font_code = [_]u8{ 0xB0, 0x28, 0x89, 0xB0, 2, 0x60, 0x2D };
    engine2.program.bytecode[0] = &font_code;
    engine2.program.decoder = Decoder.init(&font_code, 0);
    engine2.program.initial = .font;
    engine2.program.current = .font;
    try engine2.runProgram(.font, false);
    try engine2.value_stack.push(10);
    var glyph_code2 = [_]u8{0x28};
    engine2.program.bytecode[2] = &glyph_code2;
    engine2.program.decoder = Decoder.init(&glyph_code2, 0);
    engine2.program.initial = .glyph;
    engine2.program.current = .glyph;
    engine2.program.call_stack.clear();
    try engine2.run();
    try std.testing.expectEqual(@as(?i32, 12), engine2.value_stack.peek());
}

test "loop budget and call stack errors are typed" {
    var mock = MockEngine{};
    var engine = mock.engine();
    try std.testing.expectError(error.CallStackUnderflow, engine.opEndf());

    engine.loop_budget.limit = 2;
    engine.value_stack.clear();
    try engine.value_stack.push(-5);
    try engine.opJmpr();
    try engine.value_stack.push(-5);
    try engine.opJmpr();
    try engine.value_stack.push(-5);
    try std.testing.expectError(error.ExceededExecutionBudget, engine.opJmpr());
}

test "getinfo and instctrl match upstream flags" {
    var mock = MockEngine{};
    var engine = mock.engine();
    try engine.value_stack.push(1 << 0);
    try engine.opGetinfo();
    try std.testing.expectEqual(@as(?i32, 40), engine.value_stack.peek());
    // Smooth target reports grayscale ClearType.
    engine.graphics.target = .{ .smooth = .{ .mode = .normal } };
    try engine.value_stack.push(1 << 12);
    try engine.opGetinfo();
    try std.testing.expectEqual(@as(?i32, 1 << 19), engine.value_stack.peek());
    // INSTCTRL in the prep program disables hinting via selector 1.
    engine.program.initial = .control_value;
    try engine.value_stack.push(1);
    try engine.value_stack.push(1);
    try engine.opInstctrl();
    try std.testing.expect((engine.graphics.instruct_control & 1) != 0);
}
