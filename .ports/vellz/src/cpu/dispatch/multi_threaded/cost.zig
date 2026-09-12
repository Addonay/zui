//! Port of vello_cpu src/dispatch/multi_threaded/cost.rs (Apache-2.0 OR MIT).
//!
//! Cost heuristics used by `MultiThreadedDispatcher` to batch render tasks
//! before sending them to the worker pool. The constants are upstream's and
//! are deliberately copied verbatim: changing them changes batching (and thus
//! task ordering across threads), never per-pixel math.

const std = @import("std");
const kurbo = @import("../../../kurbo/root.zig");
const peniko = @import("../../../peniko/root.zig");
const paint_mod = @import("../../../common/paint.zig");
const task = @import("task.zig");

const PathEl = kurbo.PathEl;
const RenderTaskType = task.RenderTaskType;

/// Batching threshold (upstream `COST_THRESHOLD`). The comment upstream:
/// "There is not much science behind this constant. It was instead determined
/// by doing profiling and finding a constant that seems to strike a reasonable
/// trade-off between not causing too big batch sizes".
pub const COST_THRESHOLD: f32 = 250.0;

/// Try to estimate the cost of the render task (upstream
/// `estimate_render_task_cost`).
pub fn estimateRenderTaskCost(render_task: *const RenderTaskType, paths: []const PathEl) f32 {
    const LAYER_COST: f32 = 10.0;

    return switch (render_task.*) {
        .fill_path => |fill| blk: {
            const path = paths[fill.path_range.start..fill.path_range.end];
            break :blk estimatePathCost(path, fill.transform, false);
        },
        .stroke_path => |stroke| blk: {
            const path = paths[stroke.path_range.start..stroke.path_range.end];
            break :blk estimatePathCost(path, stroke.transform, true);
        },
        .push_layer => |layer| blk: {
            var cost: f32 = LAYER_COST;
            if (layer.clip_path) |clip| {
                const path = paths[clip.path_range.start..clip.path_range.end];
                cost += estimatePathCost(path, clip.transform, false);
            }
            break :blk cost;
        },
        .pop_layer => LAYER_COST,
    };
}

/// Try to estimate an (admittedly somewhat abstract) "path cost" (upstream
/// `estimate_path_cost`).
///
/// The main point is that when sending paths to a worker to convert them into
/// sparse strip representation, small line-only geometries are batched to
/// avoid per-path overhead. The estimate uses line/curve counts and path
/// length; see the upstream doc comment for the reasoning behind the
/// constants.
pub fn estimatePathCost(path: []const PathEl, transform: kurbo.Affine, is_stroke: bool) f32 {
    const cost_data = PathCostData.init(path, transform);

    // "Once again, those constants were not determined 'scientifically' in any
    // way" (upstream): keep them verbatim.
    const CURVE_MULTIPLIER: f32 = 2.5;
    const STROKE_MULTIPLIER: f32 = 1.5;

    var cost: f32 = @floatFromInt(cost_data.num_line_segments);
    cost += @as(f32, @floatFromInt(cost_data.num_curve_segments)) * CURVE_MULTIPLIER;
    // No sqrt: a rough Manhattan-length estimate is enough.
    cost += cost * (@as(f32, @floatCast(cost_data.path_length)) / 1024.0);

    cost *= if (is_stroke) STROKE_MULTIPLIER else 1.0;
    return cost;
}

const PathCostData = struct {
    num_line_segments: u64,
    num_curve_segments: u64,
    path_length: f64,

    fn init(path: []const PathEl, transform: kurbo.Affine) PathCostData {
        var num_line_segments: u64 = 0;
        var num_curve_segments: u64 = 0;
        var path_length: f64 = 0.0;

        var segments = kurbo.bezpath.segments(path);
        while (segments.next()) |segment| {
            switch (segment) {
                .Line => |line| {
                    num_line_segments += 1;
                    path_length += transformedManhattanLength(transform, line.p0, line.p1);
                },
                .Quad => |quad| {
                    num_curve_segments += 1;
                    path_length += transformedManhattanLength(transform, quad.p0, quad.p2);
                },
                .Cubic => |cubic| {
                    num_curve_segments += 1;
                    path_length += transformedManhattanLength(transform, cubic.p0, cubic.p3);
                },
            }
        }

        return .{
            .num_line_segments = num_line_segments,
            .num_curve_segments = num_curve_segments,
            .path_length = path_length,
        };
    }
};

fn transformedManhattanLength(transform: kurbo.Affine, p0: kurbo.Point, p1: kurbo.Point) f64 {
    const t0 = transform.transformPoint(p0);
    const t1 = transform.transformPoint(p1);
    return @abs(t1.x - t0.x) + @abs(t1.y - t0.y);
}

// ---------------------------------------------------------------------------
// Tests (upstream cost.rs has no `#[cfg(test)]`; these pin the ported formula)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rectPath() [4]PathEl {
    return .{
        .{ .MoveTo = kurbo.Point.new(0.0, 0.0) },
        .{ .LineTo = kurbo.Point.new(3.0, 4.0) },
        .{ .QuadTo = .{
            .p1 = kurbo.Point.new(4.0, 6.0),
            .p2 = kurbo.Point.new(6.0, 8.0),
        } },
        .{ .LineTo = kurbo.Point.new(6.0, 8.0) },
    };
}

fn blackPaint() paint_mod.Paint {
    return paint_mod.Paint.fromAlphaColor(peniko.Color.BLACK);
}

test "estimate path cost matches the documented formula" {
    const path = rectPath();

    // Line (0,0)-(3,4): |3|+|4| = 7. Quad (3,4)-(6,8): 7. Line (6,8)-(6,8): 0.
    // num_line = 2, num_curve = 1, path_length = 14.
    const fill = estimatePathCost(&path, kurbo.Affine.IDENTITY, false);
    const expected_fill: f32 = 2.0 + 1.0 * 2.5;
    const scaled = expected_fill * (14.0 / 1024.0);
    try testing.expectApproxEqAbs(expected_fill + scaled, fill, 1e-6);

    const stroke = estimatePathCost(&path, kurbo.Affine.IDENTITY, true);
    try testing.expectApproxEqAbs((expected_fill + scaled) * 1.5, stroke, 1e-6);
}

test "estimate render task cost dispatches on task kind" {
    const path = rectPath();
    const paths: []const PathEl = &path;

    const fill_task = RenderTaskType{ .fill_path = .{
        .path_range = .{ .start = 0, .end = path.len },
        .transform = kurbo.Affine.IDENTITY,
        .paint = blackPaint(),
        .fill_rule = .non_zero,
        .blend_mode = .default,
        .aliasing_threshold = null,
        .mask = null,
    } };
    const pop_task = RenderTaskType{ .pop_layer = {} };
    const push_task = RenderTaskType{ .push_layer = .{
        .clip_path = .{ .path_range = .{ .start = 0, .end = path.len }, .transform = kurbo.Affine.IDENTITY },
        .blend_mode = .default,
        .opacity = 1.0,
        .mask = null,
        .fill_rule = .non_zero,
        .aliasing_threshold = null,
    } };

    const fill_cost = estimateRenderTaskCost(&fill_task, paths);
    const stroke_cost = estimateRenderTaskCost(&RenderTaskType{ .stroke_path = .{
        .path_range = .{ .start = 0, .end = path.len },
        .transform = kurbo.Affine.IDENTITY,
        .paint = blackPaint(),
        .stroke = kurbo.Stroke.new(1.0),
        .blend_mode = .default,
        .aliasing_threshold = null,
        .mask = null,
    } }, paths);
    try testing.expect(stroke_cost > fill_cost);
    try testing.expectApproxEqAbs(@as(f32, 10.0), estimateRenderTaskCost(&pop_task, paths), 1e-6);
    try testing.expectApproxEqAbs(
        @as(f32, 10.0) + fill_cost,
        estimateRenderTaskCost(&push_task, paths),
        1e-6,
    );
}
