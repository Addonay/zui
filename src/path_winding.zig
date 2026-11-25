//! Path fills by per-pixel winding (port of GPUI `path_winding.rs`).
//!
//! `PathBuilder` turns contours into closed chains of xy-monotone quadratic
//! curves (`PathCurve`). To paint a `Path`, we compute the winding number at
//! each pixel using Eric Lengyel's Slug algorithm: cast rays leftward and
//! upward from the pixel center and count crossings with the path's curves.
//! Crossings within half a pixel contribute partial winding for antialiasing.
//!
//! To reduce the curves tested per pixel, curves are binned into adaptive grid
//! cells; neighboring cells with identical curve lists and backdrops are merged
//! into rectangular `PathTile`s.

const std = @import("std");
const geometry = @import("geometry.zig");
const testing = std.testing;

const Point = geometry.Point;
const Bounds = geometry.Bounds;
const ScaledPixels = geometry.ScaledPixels;

/// A tile lists every curve within this distance of its bounds. Any other curve
/// is more than half a pixel away from the tile, so it cannot contribute partial
/// winding. The extra 1/256 covers the rasterizer snapping tile edges to its
/// subpixel grid.
pub const MARGIN: f32 = 0.5 + 1.0 / 256.0;
const BOX_MARGIN: f32 = MARGIN + 1.0 / 16.0;

inline fn fastMin(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

inline fn fastMax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

inline fn fastClamp(v: f32, min_v: f32, max_v: f32) f32 {
    return fastMin(fastMax(v, min_v), max_v);
}

/// An xy-monotone quadratic Bezier curve oriented downward (`p0.y <= p1.y`),
/// represented in power basis `B(t) = a*t^2 + b*t + p0` for `t in [0, 1]`.
pub const PathCurve = struct {
    p0: Point(f32) = .{},
    p1: Point(f32) = .{},
    a: Point(f32) = .{},
    b: Point(f32) = .{},
    sign: f32 = 1.0,
    pad: u32 = 0,

    pub fn init(p0: Point(f32), ctrl: Point(f32), p1: Point(f32), sign: f32) PathCurve {
        return .{
            .p0 = p0,
            .p1 = p1,
            .a = .{
                .x = p0.x - 2.0 * ctrl.x + p1.x,
                .y = p0.y - 2.0 * ctrl.y + p1.y,
            },
            .b = .{
                .x = 2.0 * (ctrl.x - p0.x),
                .y = 2.0 * (ctrl.y - p0.y),
            },
            .sign = sign,
            .pad = 0,
        };
    }

    /// A straight line segment with zero quadratic term.
    pub fn line(from: Point(f32), to: Point(f32)) PathCurve {
        const d = downward(from, to);
        return .{
            .p0 = d.p0,
            .p1 = d.p1,
            .a = .{ .x = 0.0, .y = 0.0 },
            .b = .{ .x = d.p1.x - d.p0.x, .y = d.p1.y - d.p0.y },
            .sign = d.sign,
            .pad = 0,
        };
    }

    /// Splits a quadratic Bezier `(p0, ctrl, p1)` at its x and y extrema into
    /// xy-monotone pieces, clamping control points into each piece's endpoint
    /// bounding box and guaranteeing bit-identical shared endpoints.
    pub fn push_monotone(
        curves: *std.ArrayList(PathCurve),
        allocator: std.mem.Allocator,
        p0: Point(f32),
        ctrl: Point(f32),
        p1: Point(f32),
    ) !void {
        var splits: [2]f32 = undefined;
        var split_count: usize = 0;

        const denom_x = p0.x - 2.0 * ctrl.x + p1.x;
        if (denom_x != 0.0) {
            const tx = (p0.x - ctrl.x) / denom_x;
            if (tx > 0.0 and tx < 1.0) {
                splits[split_count] = tx;
                split_count += 1;
            }
        }
        const denom_y = p0.y - 2.0 * ctrl.y + p1.y;
        if (denom_y != 0.0) {
            const ty = (p0.y - ctrl.y) / denom_y;
            if (ty > 0.0 and ty < 1.0) {
                if (split_count == 0 or ty != splits[0]) {
                    splits[split_count] = ty;
                    split_count += 1;
                }
            }
        }
        if (split_count == 2 and splits[1] < splits[0]) {
            std.mem.swap(f32, &splits[0], &splits[1]);
        }

        var t_prev: f32 = 0.0;
        var prev_pt = p0;
        for (0..split_count + 1) |i| {
            const is_last = (i == split_count);
            const t_next: f32 = if (is_last) 1.0 else splits[i];
            const next_pt = if (is_last) p1 else evalQuad(p0, ctrl, p1, t_next);

            const from = prev_pt;
            const to = next_pt;
            prev_pt = next_pt;

            if (from.x == to.x and from.y == to.y) {
                t_prev = t_next;
                continue;
            }

            // Blossoming B(t_prev, t_next) gives the sub-segment's control point.
            const om0 = 1.0 - t_prev;
            const om1 = 1.0 - t_next;
            const w0 = om0 * om1;
            const w1 = om0 * t_next + t_prev * om1;
            const w2 = t_prev * t_next;
            const raw_ctrl: Point(f32) = .{
                .x = w0 * p0.x + w1 * ctrl.x + w2 * p1.x,
                .y = w0 * p0.y + w1 * ctrl.y + w2 * p1.y,
            };

            const d = downward(from, to);
            const clamped_ctrl: Point(f32) = .{
                .x = std.math.clamp(raw_ctrl.x, @min(d.p0.x, d.p1.x), @max(d.p0.x, d.p1.x)),
                .y = std.math.clamp(raw_ctrl.y, d.p0.y, d.p1.y),
            };
            try curves.append(allocator, PathCurve.init(d.p0, clamped_ctrl, d.p1, d.sign));
            t_prev = t_next;
        }
    }

    pub fn scaled(self: PathCurve, scale_factor: f32) PathCurve {
        return .{
            .p0 = .{ .x = self.p0.x * scale_factor, .y = self.p0.y * scale_factor },
            .p1 = .{ .x = self.p1.x * scale_factor, .y = self.p1.y * scale_factor },
            .a = .{ .x = self.a.x * scale_factor, .y = self.a.y * scale_factor },
            .b = .{ .x = self.b.x * scale_factor, .y = self.b.y * scale_factor },
            .sign = self.sign,
            .pad = 0,
        };
    }

    pub fn min_x(self: PathCurve) f32 {
        return fastMin(self.p0.x, self.p1.x);
    }

    pub fn max_x(self: PathCurve) f32 {
        return fastMax(self.p0.x, self.p1.x);
    }

    pub fn step(self: PathCurve) i32 {
        return if (self.sign < 0.0) -1 else 1;
    }

    /// Whether the curve crosses the horizontal line at `y`. Half-open so two
    /// curves meeting on the line contribute exactly once.
    pub fn crosses(self: PathCurve, y: f32) bool {
        return self.p0.y <= y and y < self.p1.y;
    }

    /// Each endpoint paired with the step the shader corrects for it.
    pub fn endpoints(self: PathCurve) [2]EndpointStep {
        const s = self.step();
        return .{
            .{ .point = self.p0, .step = s },
            .{ .point = self.p1, .step = -s },
        };
    }

    pub const EndpointStep = struct {
        point: Point(f32),
        step: i32,
    };

    /// The curve's x extent between two heights.
    pub fn x_range(self: PathCurve, top: f32, bottom: f32) struct { f32, f32 } {
        const t = fastMax(top, self.p0.y);
        const bot = fastMin(bottom, self.p1.y);
        const x_top = if (t <= self.p0.y) self.p0.x else self.x_at_y(t);
        const x_bottom = if (bot >= self.p1.y) self.p1.x else self.x_at_y(bot);
        // Clamped so rounding can't carry the range past the curve's extent.
        return .{
            fastMax(fastMin(x_top, x_bottom), self.min_x()),
            fastMin(fastMax(x_top, x_bottom), self.max_x()),
        };
    }

    pub fn x_at_y(self: PathCurve, y: f32) f32 {
        if (self.a.y == 0.0) {
            if (self.b.y == 0.0) return self.p0.x;
            const t = fastClamp((y - self.p0.y) / self.b.y, 0.0, 1.0);
            return (self.a.x * t + self.b.x) * t + self.p0.x;
        }
        const t = monotone_quadratic_root(self.a.y, self.b.y, self.p0.y - y, 1.0);
        return (self.a.x * t + self.b.x) * t + self.p0.x;
    }
};

fn evalQuad(p0: Point(f32), ctrl: Point(f32), p1: Point(f32), t: f32) Point(f32) {
    const u = 1.0 - t;
    const w0 = u * u;
    const w1 = 2.0 * u * t;
    const w2 = t * t;
    return .{
        .x = w0 * p0.x + w1 * ctrl.x + w2 * p1.x,
        .y = w0 * p0.y + w1 * ctrl.y + w2 * p1.y,
    };
}

fn downward(from: Point(f32), to: Point(f32)) struct { p0: Point(f32), p1: Point(f32), sign: f32 } {
    if (from.y > to.y) {
        return .{ .p0 = to, .p1 = from, .sign = -1.0 };
    }
    return .{ .p0 = from, .p1 = to, .sign = 1.0 };
}

/// Solves `a*t^2 + b*t + c = 0` for the root in `[0, 1]` on a monotone piece.
pub fn monotone_quadratic_root(a: f32, b: f32, c: f32, direction: f32) f32 {
    const discriminant = fastMax(b * b - 4.0 * a * c, 0.0);
    const denominator = b + direction * @sqrt(discriminant);
    if (denominator == 0.0) return 0.0;
    return fastClamp(-2.0 * c / denominator, 0.0, 1.0);
}

/// Maps finite floats to integers in the same order.
pub fn ordered_bits(x: f32) u32 {
    const bits: u32 = @bitCast(x);
    if (bits >> 31 == 1) {
        return ~bits;
    }
    return bits | (@as(u32, 1) << 31);
}

/// A merged rectangular tile of cells sharing a curve list and backdrop.
pub const PathTile = struct {
    paint: u32 = 0,
    curve_start: u32 = 0,
    curve_count: u32 = 0,
    backdrop: i32 = 0,
    top_left: Point(f32) = .{},
    bottom_right: Point(f32) = .{},
    reference: Point(f32) = .{},
    curves_top_left: Point(f32) = .{},
    curves_bottom_right: Point(f32) = .{},
};

/// A path's curves binned into tiles for one display scale.
pub const PathTiles = struct {
    allocator: std.mem.Allocator,
    bounds_: Bounds(ScaledPixels) = .{},
    tiles_: std.ArrayList(PathTile) = .empty,
    curves_: std.ArrayList(PathCurve) = .empty,

    pub fn init(allocator: std.mem.Allocator) PathTiles {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PathTiles) void {
        self.tiles_.deinit(self.allocator);
        self.curves_.deinit(self.allocator);
    }

    pub fn clone(self: *const PathTiles) !PathTiles {
        var copy: PathTiles = .{
            .allocator = self.allocator,
            .bounds_ = self.bounds_,
        };
        errdefer copy.deinit();
        try copy.tiles_.appendSlice(self.allocator, self.tiles_.items);
        try copy.curves_.appendSlice(self.allocator, self.curves_.items);
        return copy;
    }

    pub fn bounds(self: *const PathTiles) Bounds(ScaledPixels) {
        return self.bounds_;
    }

    pub fn painted_bounds(self: *const PathTiles) Bounds(ScaledPixels) {
        if (self.tiles_.items.len == 0) return self.bounds_;
        return self.bounds_.dilate(MARGIN);
    }

    pub fn tiles(self: *const PathTiles) []const PathTile {
        return self.tiles_.items;
    }

    pub fn curves(self: *const PathTiles) []const PathCurve {
        return self.curves_.items;
    }

    /// Drops tiles that lie entirely outside `mask`.
    pub fn retain_visible(self: *PathTiles, mask: Bounds(ScaledPixels)) void {
        const mask_right = mask.right();
        const mask_bottom = mask.bottom();
        var write_idx: usize = 0;
        for (self.tiles_.items) |tile| {
            if (tile.top_left.x < mask_right and
                tile.top_left.y < mask_bottom and
                tile.bottom_right.x > mask.origin.x and
                tile.bottom_right.y > mask.origin.y)
            {
                self.tiles_.items[write_idx] = tile;
                write_idx += 1;
            }
        }
        self.tiles_.shrinkRetainingCapacity(write_idx);
    }
};

/// Bins `curves_in` into `PathTiles` at `scale_factor` using a one-shot `Binner`.
pub fn bin(allocator: std.mem.Allocator, curves_in: []const PathCurve, even_odd: bool, scale_factor: f32) !PathTiles {
    var binner = Binner.init(allocator);
    defer binner.deinit();
    return try binner.bin(allocator, curves_in, even_odd, scale_factor);
}

/// Picks the power-of-two cell size that minimizes estimated binning + shading cost.
pub fn cell_size(curves: f32, length: f32, size: Point(f32)) f32 {
    const LISTING_CPU_COST: f32 = 320.0;
    const EMPTY_CELL_CPU_COST: f32 = 95.0;
    const MIN_CELL_SIZE: f32 = 16.0;
    const MAX_GRID_CELLS: f32 = 4096.0;

    const grid_cells = struct {
        fn count(sz: Point(f32), cs: f32) f32 {
            return (@floor(sz.x / cs) + 1.0) * (@floor(sz.y / cs) + 1.0);
        }
    }.count;

    const extent = fastMax(size.x, size.y);
    var cs = MIN_CELL_SIZE;
    while (grid_cells(size, cs) > MAX_GRID_CELLS) {
        cs *= 2.0;
    }
    var best_cost: f32 = std.math.inf(f32);
    var best_cs: f32 = cs;
    while (true) {
        const listings = if (cs >= extent) curves else curves + length / cs;
        const area = fastMin(cs, size.x) * fastMin(cs, size.y) / 2.0;
        const empty_cells = fastMax(grid_cells(size, cs) - listings, 0.0);
        const cost = listings * (LISTING_CPU_COST + area) + empty_cells * EMPTY_CELL_CPU_COST;
        if (cost < best_cost) {
            best_cost = cost;
            best_cs = cs;
        }
        if (cs >= extent) {
            return best_cs;
        }
        cs *= 2.0;
    }
}

fn fills(winding: i32, even_odd: bool) bool {
    if (even_odd) {
        return @rem(winding, 2) != 0;
    }
    return winding != 0;
}

const Span = struct {
    cell: usize,
    count: usize,
    key: u64,
};

const Run = struct {
    start: usize,
    end: usize,
    backdrop: i32,
    list_start: usize,
    list_end: usize,
    top_left: Point(f32),
    bottom_right: Point(f32),
    tile: usize,

    fn shades_like(self: Run, other: Run, keys: []const u64) bool {
        if (self.backdrop != other.backdrop) return false;
        const a = if (self.list_start <= self.list_end and self.list_end <= keys.len)
            keys[self.list_start..self.list_end]
        else
            &[_]u64{};
        const b = if (other.list_start <= other.list_end and other.list_end <= keys.len)
            keys[other.list_start..other.list_end]
        else
            &[_]u64{};
        return std.mem.eql(u64, a, b);
    }
};

pub const Grid = struct {
    left: f32,
    top: f32,
    cell_size: f32,
    columns: usize,
    rows: usize,

    pub fn covering(min_pt: Point(f32), max_pt: Point(f32), curves_len: usize, length: f32) ?Grid {
        const left = @floor(min_pt.x - MARGIN);
        const top = @floor(min_pt.y - MARGIN);
        const size_x = max_pt.x + MARGIN - left;
        const size_y = max_pt.y + MARGIN - top;
        if (!std.math.isFinite(left) or !std.math.isFinite(top)) return null;
        if (!std.math.isFinite(size_x) or !std.math.isFinite(size_y)) return null;
        if (size_x < 0.0 or size_y < 0.0) return null;

        const cs = cell_size(@floatFromInt(curves_len), length, .{ .x = size_x, .y = size_y });
        if (!std.math.isFinite(cs) or cs <= 0.0) return null;
        const cols_f = size_x / cs;
        const rows_f = size_y / cs;
        if (!std.math.isFinite(cols_f) or !std.math.isFinite(rows_f)) return null;
        if (cols_f >= 1e9 or rows_f >= 1e9) return null;

        return .{
            .left = left,
            .top = top,
            .cell_size = cs,
            .columns = @as(usize, @intFromFloat(cols_f)) + 1,
            .rows = @as(usize, @intFromFloat(rows_f)) + 1,
        };
    }

    pub fn column_of(self: Grid, x_val: f32) usize {
        const col = (x_val - self.left) / self.cell_size;
        return @intFromFloat(fastClamp(col, 0.0, @floatFromInt(self.columns - 1)));
    }

    pub fn row_of(self: Grid, y_val: f32) usize {
        const row = (y_val - self.top) / self.cell_size;
        return @intFromFloat(fastClamp(row, 0.0, @floatFromInt(self.rows - 1)));
    }

    pub fn x(self: Grid, column: usize) f32 {
        return self.left + @as(f32, @floatFromInt(column)) * self.cell_size;
    }

    pub fn y(self: Grid, row: usize) f32 {
        return self.top + @as(f32, @floatFromInt(row)) * self.cell_size;
    }

    pub fn cell(self: Grid, column: usize, row: usize) Cell {
        return .{
            .left = self.x(column),
            .top = self.y(row),
            .right = self.x(column + 1),
            .bottom = self.y(row + 1),
        };
    }
};

pub const Cell = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    fn top_left(self: Cell) Point(f32) {
        return .{ .x = self.left, .y = self.top };
    }

    fn bottom_right(self: Cell) Point(f32) {
        return .{ .x = self.right, .y = self.bottom };
    }
};

/// Accumulates the bounds and windings of a cell's curves to trim its quad.
pub const Measure = struct {
    cell: Cell,
    backdrop: i32,
    min: Point(f32),
    max: Point(f32),
    right_winding: i32,
    bottom_winding: i32,

    pub fn init(cell: Cell, backdrop: i32) Measure {
        const inf = std.math.inf(f32);
        return .{
            .cell = cell,
            .backdrop = backdrop,
            .min = .{ .x = inf, .y = inf },
            .max = .{ .x = -inf, .y = -inf },
            .right_winding = backdrop,
            .bottom_winding = backdrop,
        };
    }

    pub fn add(self: *Measure, curve: PathCurve) void {
        self.min.x = fastMin(self.min.x, curve.min_x());
        self.max.x = fastMax(self.max.x, curve.max_x());
        self.min.y = fastMin(self.min.y, curve.p0.y);
        self.max.y = fastMax(self.max.y, curve.p1.y);
        if (curve.crosses(self.cell.top)) {
            self.right_winding += curve.step();
        }
        for (curve.endpoints()) |ep| {
            if (ep.point.x <= self.cell.left and ep.point.y > self.cell.top) {
                self.bottom_winding -= ep.step;
            }
        }
    }

    pub fn quad(self: *const Measure, even_odd: bool) ?struct { top_left: Point(f32), bottom_right: Point(f32) } {
        const c = self.cell;
        const unfilled = !fills(self.backdrop, even_odd);
        const left = if (unfilled) fastClamp(self.min.x - MARGIN, c.left, c.right) else c.left;
        const top = if (unfilled) fastClamp(self.min.y - MARGIN, c.top, c.bottom) else c.top;
        const right = if (fills(self.right_winding, even_odd)) c.right else fastClamp(self.max.x + MARGIN, c.left, c.right);
        const bottom = if (fills(self.bottom_winding, even_odd)) c.bottom else fastClamp(self.max.y + MARGIN, c.top, c.bottom);
        if (left < right and top < bottom) {
            return .{
                .top_left = .{ .x = left, .y = top },
                .bottom_right = .{ .x = right, .y = bottom },
            };
        }
        return null;
    }
};

/// Reusable scratch state for binning paths without per-path scratch allocations.
pub const Binner = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(PathCurve) = .empty,
    spans: std.ArrayList(Span) = .empty,
    cell_ends: std.ArrayList(usize) = .empty,
    steps: std.ArrayList(i32) = .empty,
    keys: std.ArrayList(u64) = .empty,
    runs: std.ArrayList(Run) = .empty,
    above: std.ArrayList(Run) = .empty,

    pub fn init(allocator: std.mem.Allocator) Binner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Binner) void {
        self.input.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.cell_ends.deinit(self.allocator);
        self.steps.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.above.deinit(self.allocator);
    }

    pub fn bin(
        self: *Binner,
        out_allocator: std.mem.Allocator,
        curves_in: []const PathCurve,
        even_odd: bool,
        scale_factor: f32,
    ) !PathTiles {
        std.debug.assert(scale_factor > 0.0 and std.math.isFinite(scale_factor));
        if (curves_in.len == 0) {
            return PathTiles.init(out_allocator);
        }
        const scaled_info = try self.scaleCurves(curves_in, scale_factor);
        const grid = Grid.covering(scaled_info.min, scaled_info.max, curves_in.len, scaled_info.length) orelse {
            return PathTiles.init(out_allocator);
        };
        try self.findSpans(grid);
        try self.fillCells();
        var tiles = try self.mergeCells(out_allocator, grid, even_odd);
        tiles.bounds_ = Bounds(ScaledPixels).from_corners(scaled_info.min, scaled_info.max);
        return tiles;
    }

    fn scaleCurves(
        self: *Binner,
        curves_in: []const PathCurve,
        scale_factor: f32,
    ) !struct { min: Point(f32), max: Point(f32), length: f32 } {
        const inf = std.math.inf(f32);
        var min_pt: Point(f32) = .{ .x = inf, .y = inf };
        var max_pt: Point(f32) = .{ .x = -inf, .y = -inf };
        var length: f32 = 0.0;
        self.input.clearRetainingCapacity();
        try self.input.ensureTotalCapacity(self.allocator, curves_in.len);
        for (curves_in) |curve| {
            const sc = curve.scaled(scale_factor);
            min_pt.x = fastMin(min_pt.x, sc.min_x());
            max_pt.x = fastMax(max_pt.x, sc.max_x());
            min_pt.y = fastMin(min_pt.y, sc.p0.y);
            max_pt.y = fastMax(max_pt.y, sc.p1.y);
            length += sc.max_x() - sc.min_x() + sc.p1.y - sc.p0.y;
            self.input.appendAssumeCapacity(sc);
        }
        return .{ .min = min_pt, .max = max_pt, .length = length };
    }

    fn findSpans(self: *Binner, grid: Grid) !void {
        const cells = grid.rows * grid.columns;
        self.spans.clearRetainingCapacity();
        try self.cell_ends.resize(self.allocator, cells);
        @memset(self.cell_ends.items, 0);
        try self.steps.resize(self.allocator, cells);
        @memset(self.steps.items, 0);

        for (self.input.items, 0..) |curve, index| {
            const key: u64 = (@as(u64, ordered_bits(curve.min_x())) << 32) | @as(u64, index);
            const row_first = grid.row_of(curve.p0.y - MARGIN);
            const row_last = grid.row_of(curve.p1.y + MARGIN);
            for (row_first .. row_last + 1) |row| {
                const row_top = grid.y(row);
                const xr = curve.x_range(row_top - MARGIN, grid.y(row + 1) + MARGIN);
                const first = grid.column_of(xr[0] - MARGIN);
                const last = grid.column_of(xr[1] + MARGIN);
                const cell_idx = row * grid.columns + first;
                const count = last + 1 - first;
                try self.spans.append(self.allocator, .{ .cell = cell_idx, .count = count, .key = key });
                if (cell_idx + count <= self.cell_ends.items.len) {
                    for (self.cell_ends.items[cell_idx .. cell_idx + count]) |*listings| {
                        listings.* += 1;
                    }
                }
                if (curve.crosses(row_top) and last + 1 < grid.columns) {
                    const after = cell_idx + count;
                    if (after < self.steps.items.len) {
                        self.steps.items[after] += curve.step();
                    }
                }
            }
        }
    }

    fn fillCells(self: *Binner) !void {
        var total: usize = 0;
        for (self.cell_ends.items) |*end_slot| {
            const count = end_slot.*;
            end_slot.* = total;
            total += count;
        }
        try self.keys.resize(self.allocator, total);
        @memset(self.keys.items, 0);

        for (self.spans.items) |span| {
            if (span.cell + span.count <= self.cell_ends.items.len) {
                for (self.cell_ends.items[span.cell .. span.cell + span.count]) |*cursor| {
                    if (cursor.* < self.keys.items.len) {
                        self.keys.items[cursor.*] = span.key;
                    }
                    cursor.* += 1;
                }
            }
        }

        var start: usize = 0;
        for (self.cell_ends.items) |end| {
            if (start <= end and end <= self.keys.items.len) {
                std.sort.pdq(u64, self.keys.items[start..end], {}, std.sort.asc(u64));
            }
            start = end;
        }
    }

    fn mergeCells(self: *Binner, out_allocator: std.mem.Allocator, grid: Grid, even_odd: bool) !PathTiles {
        var out = PathTiles.init(out_allocator);
        errdefer out.deinit();
        try out.curves_.ensureTotalCapacity(out_allocator, self.keys.items.len);

        const inf = std.math.inf(f32);
        self.above.clearRetainingCapacity();
        var cell_start: usize = 0;

        for (0..grid.rows) |row| {
            self.runs.clearRetainingCapacity();
            var backdrop: i32 = 0;
            for (0..grid.columns) |column| {
                const idx = row * grid.columns + column;
                backdrop += if (idx < self.steps.items.len) self.steps.items[idx] else 0;
                const cell_end = if (idx < self.cell_ends.items.len) self.cell_ends.items[idx] else cell_start;
                const list_start = cell_start;
                const list_end = cell_end;
                cell_start = cell_end;

                const c = grid.cell(column, row);
                var quad_tl: Point(f32) = undefined;
                var quad_br: Point(f32) = undefined;
                if (list_start == list_end) {
                    if (!fills(backdrop, even_odd)) continue;
                    quad_tl = c.top_left();
                    quad_br = c.bottom_right();
                } else {
                    var measure = Measure.init(c, backdrop);
                    for (self.keys.items[list_start..list_end]) |key| {
                        const curve_idx: usize = @intCast(@as(u32, @truncate(key)));
                        if (curve_idx < self.input.items.len) {
                            measure.add(self.input.items[curve_idx]);
                        }
                    }
                    const q = measure.quad(even_odd) orelse continue;
                    quad_tl = q.top_left;
                    quad_br = q.bottom_right;
                }

                const run: Run = .{
                    .start = column,
                    .end = column + 1,
                    .backdrop = backdrop,
                    .list_start = list_start,
                    .list_end = list_end,
                    .top_left = quad_tl,
                    .bottom_right = quad_br,
                    .tile = 0,
                };
                if (self.runs.items.len > 0) {
                    const last = &self.runs.items[self.runs.items.len - 1];
                    if (last.end == run.start and last.shades_like(run, self.keys.items)) {
                        last.end = run.end;
                        extendQuad(&last.top_left, &last.bottom_right, run);
                        continue;
                    }
                }
                try self.runs.append(self.allocator, run);
            }

            // Merge with matching runs from the row above. Both rows' runs are in column order.
            var above_idx: usize = 0;
            const above_items = self.above.items;
            for (self.runs.items) |*run| {
                while (above_idx < above_items.len and above_items[above_idx].start < run.start) {
                    above_idx += 1;
                }
                var matched_tile: ?usize = null;
                if (above_idx < above_items.len) {
                    const other = above_items[above_idx];
                    if (other.start == run.start and other.end == run.end and other.shades_like(run.*, self.keys.items)) {
                        matched_tile = other.tile;
                        above_idx += 1;
                    }
                }
                if (matched_tile) |tile_idx| {
                    if (tile_idx < out.tiles_.items.len) {
                        extendQuad(&out.tiles_.items[tile_idx].top_left, &out.tiles_.items[tile_idx].bottom_right, run.*);
                    }
                    run.tile = tile_idx;
                } else {
                    const curve_start: u32 = @intCast(out.curves_.items.len);
                    var curves_tl: Point(f32) = .{ .x = inf, .y = inf };
                    var curves_br: Point(f32) = .{ .x = -inf, .y = -inf };
                    for (self.keys.items[run.list_start..run.list_end]) |key| {
                        const curve_idx: usize = @intCast(@as(u32, @truncate(key)));
                        if (curve_idx >= self.input.items.len) continue;
                        const curve = self.input.items[curve_idx];
                        curves_tl.x = fastMin(curves_tl.x, curve.min_x() - BOX_MARGIN);
                        curves_tl.y = fastMin(curves_tl.y, curve.p0.y - BOX_MARGIN);
                        curves_br.x = fastMax(curves_br.x, curve.max_x() + BOX_MARGIN);
                        curves_br.y = fastMax(curves_br.y, curve.p1.y + BOX_MARGIN);
                        try out.curves_.append(out_allocator, curve);
                    }
                    try out.tiles_.append(out_allocator, .{
                        .paint = 0,
                        .curve_start = curve_start,
                        .curve_count = @intCast(out.curves_.items.len - curve_start),
                        .top_left = run.top_left,
                        .bottom_right = run.bottom_right,
                        .reference = grid.cell(run.start, row).top_left(),
                        .backdrop = run.backdrop,
                        .curves_top_left = curves_tl,
                        .curves_bottom_right = curves_br,
                    });
                    run.tile = out.tiles_.items.len - 1;
                }
            }
            std.mem.swap(std.ArrayList(Run), &self.above, &self.runs);
        }
        return out;
    }
};

fn extendQuad(top_left: *Point(f32), bottom_right: *Point(f32), run: Run) void {
    top_left.x = fastMin(top_left.x, run.top_left.x);
    top_left.y = fastMin(top_left.y, run.top_left.y);
    bottom_right.x = fastMax(bottom_right.x, run.bottom_right.x);
    bottom_right.y = fastMax(bottom_right.y, run.bottom_right.y);
}

// ---------------------------------------------------------------------------
// Tests (ported from gpui/src/path_winding.rs)
// ---------------------------------------------------------------------------

fn squareCurves(allocator: std.mem.Allocator, left: f32, top: f32, right: f32, bottom: f32) ![]PathCurve {
    const pts = [_]Point(f32){
        .{ .x = left, .y = top },
        .{ .x = right, .y = top },
        .{ .x = right, .y = bottom },
        .{ .x = left, .y = bottom },
    };
    var curves: std.ArrayList(PathCurve) = .empty;
    errdefer curves.deinit(allocator);
    for (0..4) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % 4];
        if (a.x != b.x or a.y != b.y) {
            try curves.append(allocator, PathCurve.line(a, b));
        }
    }
    return curves.toOwnedSlice(allocator);
}

test "rectangle_is_nine_tiles" {
    const curves = try squareCurves(testing.allocator, 100.0, 40.0, 900.0, 600.0);
    defer testing.allocator.free(curves);

    var tiles = try bin(testing.allocator, curves, true, 1.25);
    defer tiles.deinit();
    try testing.expectEqual(@as(usize, 9), tiles.tiles().len);
}

test "huge_path_paints_only_visible_tiles" {
    const curves = try squareCurves(testing.allocator, -20000.0, -20000.0, 20000.0, 20000.0);
    defer testing.allocator.free(curves);

    var tiles = try bin(testing.allocator, curves, true, 1.5);
    defer tiles.deinit();
    try testing.expect(tiles.tiles().len < 10_000);

    const mask: Bounds(ScaledPixels) = .{
        .origin = .{ .x = 300.0 * 1.5, .y = 200.0 * 1.5 },
        .size = .{ .width = 120.0 * 1.5, .height = 90.0 * 1.5 },
    };
    tiles.retain_visible(mask);
    const painted = tiles.tiles().len;
    try testing.expect(painted > 0 and painted < 20);
}

test "overflowing_paths_are_skipped" {
    const radius1 = std.math.floatMax(f32) / 4.0;
    const curves1 = try squareCurves(testing.allocator, -radius1, -radius1, radius1, radius1);
    defer testing.allocator.free(curves1);

    var tiles1 = try bin(testing.allocator, curves1, true, 1.0);
    defer tiles1.deinit();
    try testing.expect(tiles1.tiles().len > 0);

    var tiles4 = try bin(testing.allocator, curves1, true, 4.0);
    defer tiles4.deinit();
    try testing.expectEqual(@as(usize, 0), tiles4.tiles().len);

    const radius2 = std.math.floatMax(f32) * 0.75;
    const curves2 = try squareCurves(testing.allocator, -radius2, -radius2, radius2, radius2);
    defer testing.allocator.free(curves2);

    var tiles2 = try bin(testing.allocator, curves2, true, 1.0);
    defer tiles2.deinit();
    try testing.expectEqual(@as(usize, 0), tiles2.tiles().len);
}

test "monotone quadratic split produces exact downward xy-monotone pieces" {
    var curves: std.ArrayList(PathCurve) = .empty;
    defer curves.deinit(testing.allocator);

    try PathCurve.push_monotone(
        &curves,
        testing.allocator,
        .{ .x = 0.0, .y = 10.0 },
        .{ .x = 50.0, .y = -10.0 },
        .{ .x = 20.0, .y = 30.0 },
    );
    try testing.expect(curves.items.len >= 2);
    for (curves.items) |c| {
        try testing.expect(c.p0.y <= c.p1.y);
    }
}
