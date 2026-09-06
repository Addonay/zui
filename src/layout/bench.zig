//! Reproducible layout benchmarks.
//!
//! The cases mirror the vendored Taffy benchmark crate:
//! `flexbox.rs` (huge/wide/deep/auto/super-deep), `grid.rs` (wide/deep/
//! super-deep), `mixed.rs`, and `tree_creation.rs`. ZUI deliberately keeps
//! its 4096-node fixed pool, so the Taffy 10k/100k rows are represented by the
//! largest legal 3000-node run and documented as capacity-limited rather than
//! silently growing memory.
//!
//! Setup is outside each timed interval, like Taffy's `iter_batched`: a fresh
//! fixed-capacity tree is built, then only `computeRoot` is timed. No random
//! source is consulted; the small LCG and all seeds are constants.

const std = @import("std");
const layout = @import("layout");

const Style = layout.style.Style;
const GridTrack = layout.style.GridTrack;
const GridAutoFlow = layout.style.GridAutoFlow;
const Display = layout.style.Display;
const FlexDirection = layout.style.FlexDirection;
const FlexWrap = layout.style.FlexWrap;
const NodeId = layout.tree.NodeId;

const Suite = enum { tree_creation, flat_flex, huge_nested, wide, deep_random, deep_auto, super_deep, grid_wide, grid_deep, grid_deep_3, grid_superdeep, mixed };

const BenchFixture = struct {
    compute: layout.compute.ComputeTree = .{},
    columns: [layout.grid.max_tracks]GridTrack = undefined,
    rows: [layout.grid.max_tracks]GridTrack = undefined,
};

const BenchStats = struct {
    total_ns: i128 = 0,
    checksum: f32 = 0,
};

fn random(seed: *u64) f32 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return @as(f32, @floatFromInt(@as(u32, @truncate(seed.* >> 32)))) / 4294967295.0;
}

fn randomDimension(seed: *u64) layout.style.Dimension {
    const value = random(seed);
    if (value < 0.2) return .auto;
    if (value < 0.8) return .{ .length = random(seed) * 500 };
    return .{ .percent = random(seed) };
}

fn randomFlexStyle(seed: *u64) Style {
    return .{
        .display = .flex,
        .flex_direction = if (random(seed) < 0.5) .row else .column,
        .flex_wrap = if (random(seed) < 0.5) .no_wrap else .wrap,
        .width = randomDimension(seed),
        .height = randomDimension(seed),
    };
}

fn randomLeafStyle(seed: *u64) Style {
    return .{
        .size = .{ .w = random(seed) * 120, .h = random(seed) * 40 },
        .width = .auto,
        .height = .auto,
    };
}

fn addLeaves(fixture: *BenchFixture, root: NodeId, count: usize, seed: *u64) void {
    for (0..count) |_| {
        const child = fixture.compute.tree.newLeaf(randomLeafStyle(seed));
        fixture.compute.tree.attach(root, child);
    }
}

fn addFixedLeaves(fixture: *BenchFixture, root: NodeId, count: usize) void {
    for (0..count) |_| {
        const child = fixture.compute.tree.newLeaf(.{ .size = .{ .w = 20, .h = 20 } });
        fixture.compute.tree.attach(root, child);
    }
}

fn addDeep(fixture: *BenchFixture, depth: usize, max_depth: usize, budget: *usize, style: Style, branching: usize) NodeId {
    const node = fixture.compute.tree.newLeaf(style);
    budget.* -= 1;
    if (depth >= max_depth or budget.* == 0) return node;
    var branch: usize = 0;
    while (branch < branching and budget.* > 0) : (branch += 1) {
        const child = addDeep(fixture, depth + 1, max_depth, budget, style, branching);
        fixture.compute.tree.attach(node, child);
    }
    return node;
}

fn buildTreeCreation(fixture: *BenchFixture, node_count: usize) NodeId {
    // Tree creation intentionally excludes cache initialization; Taffy's
    // `TaffyTree::new` benchmark likewise measures node storage/building, not
    // a layout reset.
    fixture.compute.tree.reset();
    var seed: u64 = 12345;
    var children: [1024]NodeId = undefined;
    var child_count: usize = 0;
    var created: usize = 0;
    while (created < node_count and child_count < children.len) {
        const group_size = @min(@as(usize, 4), node_count - created);
        const group = fixture.compute.tree.newLeaf(.{});
        for (0..group_size) |_| {
            const leaf = fixture.compute.tree.newLeaf(randomLeafStyle(&seed));
            fixture.compute.tree.attach(group, leaf);
        }
        children[child_count] = group;
        child_count += 1;
        created += 1 + group_size;
    }
    return fixture.compute.tree.newWithChildren(.{ .display = .flex }, children[0..child_count]);
}

fn measureTreeCreation(fixture: *BenchFixture, node_count: usize, iterations: usize, io: std.Io) BenchStats {
    var stats = BenchStats{};
    for (0..iterations) |_| {
        const started = std.Io.Clock.awake.now(io);
        const root = buildTreeCreation(fixture, node_count);
        stats.total_ns += @as(i128, @intCast(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        stats.checksum += @as(f32, @floatFromInt(root)) + @as(f32, @floatFromInt(fixture.compute.tree.len()));
    }
    return stats;
}

fn buildFlex(fixture: *BenchFixture, suite: Suite, value: usize) NodeId {
    fixture.compute.reset();
    var seed: u64 = 12345;
    return switch (suite) {
        .huge_nested => blk: {
            const style: Style = .{ .size = .{ .w = 10, .h = 10 }, .flex_grow = 1, .flex_direction = .row };
            var budget = value;
            break :blk addDeep(fixture, 0, 10, &budget, style, 2);
        },
        .wide => blk: {
            const root = fixture.compute.tree.newLeaf(.{ .display = .flex, .flex_direction = .row, .flex_wrap = .wrap });
            addLeaves(fixture, root, value - 1, &seed);
            break :blk root;
        },
        .deep_random => blk: {
            var budget = value;
            break :blk addDeep(fixture, 0, 14, &budget, .{ .display = .flex, .width = randomDimension(&seed), .height = randomDimension(&seed) }, 2);
        },
        .deep_auto => blk: {
            var budget = value;
            break :blk addDeep(fixture, 0, 14, &budget, .{ .display = .flex, .flex_grow = 1, .margin = .all(10) }, 2);
        },
        .super_deep => blk: {
            const root = fixture.compute.tree.newLeaf(.{ .display = .flex, .flex_direction = .row, .flex_grow = 1, .margin = .all(10) });
            var cursor = root;
            var depth: usize = 1;
            while (depth < value) : (depth += 1) {
                const child = fixture.compute.tree.newLeaf(.{ .display = .flex, .flex_direction = .row, .flex_grow = 1, .margin = .all(10) });
                fixture.compute.tree.attach(cursor, child);
                cursor = child;
            }
            break :blk root;
        },
        else => unreachable,
    };
}

fn buildFlatFlex(fixture: *BenchFixture, node_count: usize) NodeId {
    fixture.compute.reset();
    const root = fixture.compute.tree.newLeaf(.{ .display = .flex });
    for (0..node_count - 1) |_| fixture.compute.tree.attach(root, fixture.compute.tree.newLeaf(.{ .size = .{ .w = 10, .h = 20 } }));
    return root;
}

fn buildGridWide(fixture: *BenchFixture, tracks: usize) NodeId {
    fixture.compute.reset();
    for (fixture.columns[0..tracks]) |*track| track.* = GridTrack.flex(1);
    for (fixture.rows[0..tracks]) |*track| track.* = GridTrack.flex(1);
    const root = fixture.compute.tree.newLeaf(.{ .display = .grid, .grid_columns = fixture.columns[0..tracks], .grid_rows = fixture.rows[0..tracks] });
    addFixedLeaves(fixture, root, tracks * tracks);
    return root;
}

fn buildGridDeep(fixture: *BenchFixture, levels: usize, tracks: usize) NodeId {
    fixture.compute.reset();
    for (fixture.columns[0..tracks]) |*track| track.* = GridTrack.flex(1);
    for (fixture.rows[0..tracks]) |*track| track.* = GridTrack.flex(1);
    const style: Style = .{ .display = .grid, .grid_columns = fixture.columns[0..tracks], .grid_rows = fixture.rows[0..tracks] };
    var budget: usize = layout.tree.max_nodes - 1;
    return addGridDeep(fixture, levels, style, &budget, tracks);
}

fn addGridDeep(fixture: *BenchFixture, levels: usize, style: Style, budget: *usize, tracks: usize) NodeId {
    std.debug.assert(budget.* > 0);
    const node = fixture.compute.tree.newLeaf(if (levels == 0) .{ .size = .{ .w = 20, .h = 20 } } else style);
    budget.* -= 1;
    if (levels == 0 or budget.* < tracks * tracks) return node;
    var child_index: usize = 0;
    while (child_index < tracks * tracks and budget.* > 0) : (child_index += 1) {
        const child = addGridDeep(fixture, levels - 1, style, budget, tracks);
        fixture.compute.tree.attach(node, child);
    }
    return node;
}

fn addMixed(fixture: *BenchFixture, depth: usize, width: usize, grid_turn: bool, seed: *u64) NodeId {
    if (depth == 0) return fixture.compute.tree.newLeaf(.{ .size = .{ .w = 20, .h = 18 } });
    const style: Style = if (grid_turn) blk: {
        for (fixture.columns[0..width]) |*track| track.* = GridTrack.flex(1);
        for (fixture.rows[0..width]) |*track| track.* = GridTrack.flex(1);
        break :blk .{ .display = .grid, .grid_columns = fixture.columns[0..width], .grid_rows = fixture.rows[0..width] };
    } else .{ .display = .flex, .flex_direction = if (random(seed) < 0.5) .row else .column, .flex_wrap = .wrap };
    const node = fixture.compute.tree.newLeaf(style);
    for (0..width) |_| fixture.compute.tree.attach(node, addMixed(fixture, depth - 1, width, !grid_turn, seed));
    return node;
}

fn buildMixed(fixture: *BenchFixture, depth: usize, width: usize) NodeId {
    fixture.compute.reset();
    var seed: u64 = 12345;
    return addMixed(fixture, depth, width, true, &seed);
}

fn measureLayout(fixture: *BenchFixture, suite: Suite, value: usize, iterations: usize, io: std.Io) BenchStats {
    var stats = BenchStats{};
    for (0..iterations) |_| {
        const root = switch (suite) {
            .flat_flex => buildFlatFlex(fixture, value),
            .grid_wide => buildGridWide(fixture, value),
            .grid_deep => buildGridDeep(fixture, value, 2),
            .grid_deep_3 => buildGridDeep(fixture, value, 3),
            .grid_superdeep => buildGridDeep(fixture, value, 1),
            .mixed => buildMixed(fixture, if (value == 4) 2 else 4, if (value == 4) 4 else 6),
            else => buildFlex(fixture, suite, value),
        };
        const started = std.Io.Clock.awake.now(io);
        fixture.compute.computeRoot(root, .{ .w = 12000, .h = 8000 });
        stats.total_ns += @as(i128, @intCast(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        stats.checksum += fixture.compute.tree.nodes[root].layout.w + fixture.compute.tree.nodes[root].layout.h;
    }
    return stats;
}

fn printResult(writer: *std.Io.Writer, suite: []const u8, case_name: []const u8, nodes: usize, iterations: usize, stats: BenchStats) !void {
    const mean = @as(f64, @floatFromInt(stats.total_ns)) / @as(f64, @floatFromInt(iterations));
    const per_second = if (mean > 0) 1_000_000_000.0 / mean else 0;
    try writer.print("| {s} | {s} | {d} | {d} | {d:.1} | {d:.0} | {d:.1} |\n", .{ suite, case_name, nodes, iterations, mean, per_second, stats.checksum });
}

pub fn main(init: std.process.Init) !void {
    var fixture = BenchFixture{ .compute = layout.compute.ComputeTree.init() };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("# ZUI Layout Benchmark Results\n\n");
    try out.writeAll("Generated by `zig build bench-layout` with `ReleaseFast`. Each row builds a fresh fixed-capacity tree outside the timed interval and times one cold `computeRoot` call.\n\n");
    try out.writeAll("| suite | case | nodes | iterations | ns/layout | layouts/s | checksum |\n|---|---|---:|---:|---:|---:|---:|\n");

    const tree_cases = [_]struct { nodes: usize, iterations: usize }{
        .{ .nodes = 1000, .iterations = 50 },
        .{ .nodes = 3000, .iterations = 20 },
    };
    for (tree_cases) |case| {
        std.debug.print("running tree_creation / {d} nodes\n", .{case.nodes});
        try printResult(out, "tree_creation", "fixed-capacity tree", case.nodes, case.iterations, measureTreeCreation(&fixture, case.nodes, case.iterations, init.io));
    }

    const flex_cases = [_]struct { suite: Suite, label: []const u8, nodes: usize, iterations: usize }{
        .{ .suite = .flat_flex, .label = "fixed row", .nodes = 1000, .iterations = 20 },
        .{ .suite = .flat_flex, .label = "fixed row", .nodes = 3000, .iterations = 10 },
        .{ .suite = .huge_nested, .label = "huge nested", .nodes = 1000, .iterations = 20 },
        .{ .suite = .huge_nested, .label = "huge nested", .nodes = 3000, .iterations = 10 },
        .{ .suite = .wide, .label = "2-level wide", .nodes = 1000, .iterations = 20 },
        .{ .suite = .wide, .label = "2-level wide", .nodes = 3000, .iterations = 10 },
        .{ .suite = .deep_random, .label = "12-level random", .nodes = 1000, .iterations = 20 },
        .{ .suite = .deep_random, .label = "14-level random", .nodes = 3000, .iterations = 10 },
        .{ .suite = .deep_auto, .label = "12-level auto", .nodes = 1000, .iterations = 20 },
        .{ .suite = .deep_auto, .label = "14-level auto", .nodes = 3000, .iterations = 10 },
        .{ .suite = .super_deep, .label = "depth 50", .nodes = 50, .iterations = 50 },
    };
    for (flex_cases) |case| {
        std.debug.print("running {s} / {s} ({d} nodes)\n", .{ @tagName(case.suite), case.label, case.nodes });
        try printResult(out, @tagName(case.suite), case.label, case.nodes, case.iterations, measureLayout(&fixture, case.suite, case.nodes, case.iterations, init.io));
    }

    const grid_cases = [_]struct { suite: Suite, label: []const u8, value: usize, nodes: usize, iterations: usize }{
        .{ .suite = .grid_wide, .label = "4x4", .value = 4, .nodes = 17, .iterations = 50 },
        .{ .suite = .grid_wide, .label = "16x16", .value = 16, .nodes = 257, .iterations = 20 },
        .{ .suite = .grid_wide, .label = "63x63", .value = 63, .nodes = 3970, .iterations = 5 },
        .{ .suite = .grid_deep, .label = "2x2, 5 levels", .value = 5, .nodes = 1365, .iterations = 10 },
        .{ .suite = .grid_deep_3, .label = "3x3, 4 levels (cap-limited)", .value = 4, .nodes = 4095, .iterations = 5 },
        .{ .suite = .grid_superdeep, .label = "1x1, depth 50", .value = 50, .nodes = 51, .iterations = 50 },
    };
    for (grid_cases) |case| {
        std.debug.print("running {s} / {s} ({d} nodes)\n", .{ @tagName(case.suite), case.label, case.nodes });
        try printResult(out, @tagName(case.suite), case.label, case.nodes, case.iterations, measureLayout(&fixture, case.suite, case.value, case.iterations, init.io));
    }

    const mixed_cases = [_]struct { label: []const u8, value: usize, nodes: usize, iterations: usize }{
        .{ .label = "depth 2 width 4", .value = 4, .nodes = 21, .iterations = 50 },
        .{ .label = "depth 4 width 6 (cap-safe substitute for width 8)", .value = 6, .nodes = 1555, .iterations = 10 },
    };
    for (mixed_cases) |case| {
        std.debug.print("running mixed / {s} ({d} nodes)\n", .{ case.label, case.nodes });
        try printResult(out, "mixed", case.label, case.nodes, case.iterations, measureLayout(&fixture, .mixed, case.value, case.iterations, init.io));
    }

    try out.writeAll("\nNotes: the vendored Taffy cases use 1k/10k/100k flex trees and 31/100/316 grid tracks. ZUI intentionally caps nodes at 4096 and tracks at 512, so 3000 nodes and 63x63 are the largest directly comparable legal cases. This report is a ZUI measurement, not a cross-language claim of Taffy equivalence.\n");
    try out.flush();
}
