//! Edge grid-fitting: the final alignment of edges to the pixel grid.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/hint/edges.rs` with the
//! recorder path omitted (the glifo JIT path passes `None`, which selects
//! `QuirksMode::Jit` upstream).

const std = @import("std");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const topo = @import("topo.zig");

const Dimension = @import("types.zig").Dimension;
const Direction = outline_mod.Direction;
const Edge = topo.Edge;
const Axis = topo.Axis;
const TopoFlags = topo.TopoFlags;
const ScriptGroup = topo.ScriptGroup;
const Scale = metrics.Scale;
const ScaledAxisMetrics = metrics.ScaledAxisMetrics;
const ScaledWidth = metrics.ScaledWidth;

/// Main Latin grid-fitting routine.
pub fn hintEdges(
    axis: *Axis,
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
    top_to_bottom_hinting_in: bool,
) void {
    var top_to_bottom_hinting = top_to_bottom_hinting_in;
    if (axis.dim != .vertical) top_to_bottom_hinting = false;
    // First align horizontal edges to blue zones if needed.
    var anchor_ix = alignEdgesToBlues(axis, metrics_axis, script_group, scale);
    // Now align the stem edges.
    const result = alignStemEdges(
        axis,
        metrics_axis,
        script_group,
        scale,
        top_to_bottom_hinting,
        anchor_ix,
    );
    const serif_count = result.serif_count;
    anchor_ix = result.anchor_ix;
    const edges = axis.edges.items;
    // Special case for lowercase m.
    if (axis.dim == .horizontal and (edges.len == 6 or edges.len == 12)) {
        hintLowercaseM(edges, script_group);
    }
    // Handle serifs and single segment edges.
    if (serif_count > 0 or anchor_ix == null) {
        alignRemainingEdges(axis, script_group, top_to_bottom_hinting, serif_count, anchor_ix);
    }
}

/// Aligns horizontal edges to blue zones.
fn alignEdgesToBlues(
    axis: *Axis,
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
) ?usize {
    var anchor_ix: ?usize = null;
    // For the default script group, only do vertical blues.
    if (script_group == .default and axis.dim != .vertical) return anchor_ix;
    for (0..axis.edges.items.len) |edge_ix| {
        var linked_edge_to_align: ?struct { edge1: usize, edge2: usize } = null;
        {
            const edges = axis.edges.items;
            const edge = &edges[edge_ix];
            if (edge.flags.contains(TopoFlags.done)) continue;
            const edge2_ix = edge.link_ix;
            const edge2: ?Edge = if (edge2_ix) |ix| edges[ix] else null;
            // If we have two neutral zones, skip one of them.
            if (edge.blue_edge != null and edge2 != null) {
                if (edge2.?.blue_edge != null) {
                    var skip_ix: ?usize = null;
                    if (edge2.?.flags.contains(TopoFlags.neutral)) {
                        skip_ix = if (edge2_ix) |ix| @as(usize, ix) else null;
                    } else if (edge.flags.contains(TopoFlags.neutral)) {
                        skip_ix = edge_ix;
                    }
                    if (skip_ix) |ix| {
                        edges[ix].blue_edge = null;
                        edges[ix].flags = edges[ix].flags.without(TopoFlags.neutral);
                    }
                }
            }
            // Flip edges if the other is aligned to a blue zone.
            var blue: ?ScaledWidth = null;
            var edge1_ix: ?usize = null;
            var edge2_out: ?usize = if (edge2_ix) |ix| @as(usize, ix) else null;
            if (edges[edge_ix].blue_edge) |b| {
                blue = b;
                edge1_ix = edge_ix;
            } else if (edge2_ix != null and edges[edge2_ix.?].blue_edge != null) {
                blue = edges[edge2_ix.?].blue_edge;
                edge1_ix = if (edge2_ix) |ix| @as(usize, ix) else null;
                edge2_out = edge_ix;
            }
            const e1 = edge1_ix orelse continue;
            // Skip if edge1 was already positioned by a previous iteration.
            if (edges[e1].flags.contains(TopoFlags.done)) continue;
            edges[e1].pos = blue.?.fitted;
            edges[e1].flags = edges[e1].flags.unionWith(TopoFlags.done);
            if (edge2_out) |e2| {
                if (edges[e2].blue_edge == null) {
                    edges[e2].flags = edges[e2].flags.unionWith(TopoFlags.done);
                    linked_edge_to_align = .{ .edge1 = e1, .edge2 = e2 };
                }
            }
        }
        if (linked_edge_to_align) |pair| {
            alignLinkedEdge(axis, metrics_axis, script_group, scale, pair.edge1, pair.edge2);
        }
        if (anchor_ix == null) anchor_ix = edge_ix;
    }
    return anchor_ix;
}

/// Aligns stem edges, trying to maintain the relative order of stems.
fn alignStemEdges(
    axis: *Axis,
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
    top_to_bottom_hinting: bool,
    anchor_ix_in: ?usize,
) struct { serif_count: usize, anchor_ix: ?usize } {
    var anchor_ix = anchor_ix_in;
    var serif_count: usize = 0;
    var last_stem_pos: ?i32 = null;
    var delta: i32 = 0;
    for (0..axis.edges.items.len) |edge_ix| {
        var edge2_pos_for_cjk: i32 = 0;
        var edge2_has_blue = false;
        {
            const edges = axis.edges.items;
            const edge = &edges[edge_ix];
            if (edge.link_ix) |ix| {
                edge2_pos_for_cjk = edges[ix].pos;
                edge2_has_blue = edges[ix].blue_edge != null;
            }
            if (edge.flags.contains(TopoFlags.done)) continue;
            // Skip all non-stem edges.
            if (edge.link_ix == null) {
                serif_count += 1;
                continue;
            }
        }
        const edge2_ix = axis.edges.items[edge_ix].link_ix.?;
        // For CJK, skip stems that are too close. We'll deal with them later.
        if (script_group != .default) {
            if (last_stem_pos) |last_pos| {
                const edge_pos = axis.edges.items[edge_ix].pos;
                if (edge_pos < last_pos + 64 or edge2_pos_for_cjk < last_pos + 64) {
                    serif_count += 1;
                    continue;
                }
            }
        }
        // This should not happen, but match the C fallback.
        if (edge2_has_blue) {
            alignLinkedEdge(axis, metrics_axis, script_group, scale, edge2_ix, edge_ix);
            axis.edges.items[edge_ix].flags = axis.edges.items[edge_ix].flags.unionWith(TopoFlags.done);
            continue;
        }
        if (script_group == .default) {
            // Now align the stem. Note: the branches here are reversed from
            // the FreeType code.
            if (anchor_ix) |anchor_index| {
                const edges = axis.edges.items;
                const anchor = edges[anchor_index];
                const edge = edges[edge_ix];
                const edge2 = edges[edge2_ix];
                const original_pos = anchor.pos + (edge.opos - anchor.opos);
                const original_len = edge2.opos - edge.opos;
                const original_center = original_pos + (original_len >> 1);
                const cur_len = stemWidth(
                    metrics_axis,
                    script_group,
                    scale,
                    original_len,
                    0,
                    edge.flags,
                    edge2.flags,
                );
                if (edge2.flags.contains(TopoFlags.done)) {
                    const new_pos = edge2.pos - cur_len;
                    edges[edge_ix].pos = new_pos;
                } else if (cur_len < 96) {
                    const cur_pos1 = metrics.pixRound(original_center);
                    const offsets = if (cur_len <= 64)
                        .{ @as(i32, 32), @as(i32, 32) }
                    else
                        .{ @as(i32, 38), @as(i32, 26) };
                    const delta1 = @as(i32, @intCast(@abs(original_center - (cur_pos1 - offsets[0]))));
                    const delta2 = @as(i32, @intCast(@abs(original_center - (cur_pos1 + offsets[1]))));
                    const adjusted = if (delta1 < delta2) cur_pos1 - offsets[0] else cur_pos1 + offsets[1];
                    edges[edge_ix].pos = adjusted - @divTrunc(cur_len, 2);
                    edges[edge2_ix].pos = adjusted + @divTrunc(cur_len, 2);
                } else {
                    const cur_pos1 = metrics.pixRound(original_pos);
                    const delta1 = @as(i32, @intCast(@abs(cur_pos1 + (cur_len >> 1) - original_center)));
                    const cur_pos2 = metrics.pixRound(original_pos + original_len) - cur_len;
                    const delta2 = @as(i32, @intCast(@abs(cur_pos2 + (cur_len >> 1) - original_center)));
                    const new_pos = if (delta1 < delta2) cur_pos1 else cur_pos2;
                    const new_pos2 = new_pos + cur_len;
                    edges[edge_ix].pos = new_pos;
                    edges[edge2_ix].pos = new_pos2;
                }
                edges[edge_ix].flags = edges[edge_ix].flags.unionWith(TopoFlags.done);
                edges[edge2_ix].flags = edges[edge2_ix].flags.unionWith(TopoFlags.done);
                if (edge_ix > 0) {
                    adjustLink(edges, axis.dim, edge_ix, .prev, top_to_bottom_hinting);
                }
            } else {
                // No stem has been aligned yet.
                const edges = axis.edges.items;
                const edge = edges[edge_ix];
                const edge2 = edges[edge2_ix];
                const original_len = edge2.opos - edge.opos;
                const cur_len = stemWidth(
                    metrics_axis,
                    script_group,
                    scale,
                    original_len,
                    0,
                    edge.flags,
                    edge2.flags,
                );
                // "Voodoo" to specially round edges for small stem widths.
                const offsets = if (cur_len <= 64)
                    .{ @as(i32, 32), @as(i32, 32) }
                else
                    .{ @as(i32, 38), @as(i32, 26) };
                if (cur_len < 96) {
                    const original_center = edge.opos + (original_len >> 1);
                    var cur_pos1 = metrics.pixRound(original_center);
                    const error1 = @as(i32, @intCast(@abs(original_center - (cur_pos1 - offsets[0]))));
                    const error2 = @as(i32, @intCast(@abs(original_center - (cur_pos1 + offsets[1]))));
                    if (error1 < error2) {
                        cur_pos1 -= offsets[0];
                    } else {
                        cur_pos1 += offsets[1];
                    }
                    const edge_pos = cur_pos1 - @divTrunc(cur_len, 2);
                    edges[edge_ix].pos = edge_pos;
                    edges[edge2_ix].pos = edge_pos + cur_len;
                } else {
                    edges[edge_ix].pos = metrics.pixRound(edge.opos);
                }
                edges[edge_ix].flags = edges[edge_ix].flags.unionWith(TopoFlags.done);
                alignLinkedEdge(axis, metrics_axis, script_group, scale, edge_ix, edge2_ix);
                anchor_ix = edge_ix;
            }
        } else {
            // More CJK divergence.
            if (edge2_ix < edge_ix) {
                last_stem_pos = axis.edges.items[edge_ix].pos;
                axis.edges.items[edge_ix].flags = axis.edges.items[edge_ix].flags.unionWith(TopoFlags.done);
                alignLinkedEdge(axis, metrics_axis, script_group, scale, edge2_ix, edge_ix);
                continue;
            }
            const edges = axis.edges.items;
            if (axis.dim != .vertical and anchor_ix == null) {
                delta = hintNormalStemCjk(axis, metrics_axis, script_group, scale, edge_ix, edge2_ix, delta);
            } else {
                _ = hintNormalStemCjk(axis, metrics_axis, script_group, scale, edge_ix, edge2_ix, delta);
            }
            anchor_ix = edge_ix;
            axis.edges.items[edge_ix].flags = axis.edges.items[edge_ix].flags.unionWith(TopoFlags.done);
            axis.edges.items[edge2_ix].flags = axis.edges.items[edge2_ix].flags.unionWith(TopoFlags.done);
            last_stem_pos = edges[edge2_ix].pos;
        }
    }
    return .{ .serif_count = serif_count, .anchor_ix = anchor_ix };
}

/// Makes sure that lowercase m's maintain symmetry.
fn hintLowercaseM(edges: []Edge, script_group: ScriptGroup) void {
    const indices = if (edges.len == 6)
        .{ @as(usize, 0), @as(usize, 2), @as(usize, 4) }
    else
        .{ @as(usize, 1), @as(usize, 5), @as(usize, 9) };
    const edge1_ix = indices[0];
    const edge2_ix = indices[1];
    const edge3_ix = indices[2];
    const edge1 = edges[edge1_ix];
    const edge2 = edges[edge2_ix];
    const edge3 = edges[edge3_ix];
    const dist1 = edge2.opos - edge1.opos;
    const dist2 = edge3.opos - edge2.opos;
    const span = @as(i32, @intCast(@abs(dist1 - dist2)));
    if (script_group != .default) {
        // CJK has additional conditions.
        for ([_]struct { edge: Edge, ix: usize }{
            .{ .edge = edge1, .ix = edge1_ix },
            .{ .edge = edge2, .ix = edge2_ix },
            .{ .edge = edge3, .ix = edge3_ix },
        }) |entry| {
            if (entry.edge.link_ix != @as(?u16, @intCast(entry.ix + 1))) return;
        }
    }
    if (span < 8) {
        const delta = edge3.pos - (2 * edge2.pos - edge1.pos);
        const link_ix = edge3.link_ix;
        edges[edge3_ix].pos -= delta;
        edges[edge3_ix].flags = edges[edge3_ix].flags.unionWith(TopoFlags.done);
        if (link_ix) |ix| {
            edges[ix].pos -= delta;
            edges[ix].flags = edges[ix].flags.unionWith(TopoFlags.done);
        }
        // Move serifs along with the stem.
        if (edges.len == 12) {
            edges[8].pos -= delta;
            edges[11].pos -= delta;
        }
    }
}

/// Aligns serif and single segment edges.
fn alignRemainingEdges(
    axis: *Axis,
    script_group: ScriptGroup,
    top_to_bottom_hinting: bool,
    serif_count_in: usize,
    anchor_ix_in: ?usize,
) void {
    var serif_count = serif_count_in;
    var anchor_ix = anchor_ix_in;
    if (script_group == .default) {
        for (0..axis.edges.items.len) |edge_ix| {
            var edge_opos: i32 = 0;
            var edge_serif_ix: ?u16 = null;
            var delta: i32 = 1000;
            {
                const edges = axis.edges.items;
                const edge = &edges[edge_ix];
                if (edge.serif(edges)) |serif| {
                    delta = @as(i32, @intCast(@abs(serif.opos - edge.opos)));
                }
                if (edge.flags.contains(TopoFlags.done)) continue;
                edge_opos = edge.opos;
                edge_serif_ix = edge.serif_ix;
            }
            if (delta < 64 + 16) {
                // delta is only < 1000 if edge_serif_ix is set.
                const serif_ix: usize = edge_serif_ix.?;
                alignSerifEdge(axis, serif_ix, edge_ix);
            } else if (anchor_ix != null) {
                const edges = axis.edges.items;
                const bounds = findBoundingCompletedEdges(edges, edge_ix);
                if (bounds[0] != null and bounds[1] != null) {
                    const before = edges[bounds[0].?];
                    const after = edges[bounds[1].?];
                    const new_pos = if (after.opos == before.opos)
                        before.pos
                    else
                        before.pos + metrics.fixedMulDiv(
                            edge_opos - before.opos,
                            after.pos - before.pos,
                            after.opos - before.opos,
                        );
                    edges[edge_ix].pos = new_pos;
                } else {
                    const anchor = edges[anchor_ix.?];
                    const new_pos = anchor.pos + ((edge_opos - anchor.opos + 16) & ~@as(i32, 31));
                    edges[edge_ix].pos = new_pos;
                }
            } else {
                anchor_ix = edge_ix;
                const edges = axis.edges.items;
                edges[edge_ix].pos = metrics.pixRound(edge_opos);
            }
            axis.edges.items[edge_ix].flags = axis.edges.items[edge_ix].flags.unionWith(TopoFlags.done);
            adjustLink(axis.edges.items, axis.dim, edge_ix, .prev, top_to_bottom_hinting);
            adjustLink(axis.edges.items, axis.dim, edge_ix, .next, top_to_bottom_hinting);
        }
    } else {
        for (0..axis.edges.items.len) |edge_ix| {
            const edge = &axis.edges.items[edge_ix];
            if (edge.flags.contains(TopoFlags.done)) continue;
            if (edge.serif_ix) |serif_ix| {
                edge.flags = edge.flags.unionWith(TopoFlags.done);
                alignSerifEdge(axis, serif_ix, edge_ix);
                serif_count = serif_count -| 1;
            }
        }
        if (serif_count == 0) return;
        for (0..axis.edges.items.len) |edge_ix| {
            const edges = axis.edges.items;
            const edge = &edges[edge_ix];
            if (edge.flags.contains(TopoFlags.done)) continue;
            const bounds = findBoundingCompletedEdges(edges, edge_ix);
            if (bounds[0] != null and bounds[1] == null) {
                alignSerifEdge(axis, bounds[0].?, edge_ix);
            } else if (bounds[0] == null and bounds[1] != null) {
                alignSerifEdge(axis, bounds[1].?, edge_ix);
            } else if (bounds[0] != null and bounds[1] != null) {
                const before = edges[bounds[0].?];
                const after = edges[bounds[1].?];
                if (after.fpos == before.fpos) {
                    edges[edge_ix].pos = before.pos;
                } else {
                    edges[edge_ix].pos = before.pos + metrics.fixedMulDiv(
                        @as(i32, edge.fpos) - before.fpos,
                        after.pos - before.pos,
                        @as(i32, after.fpos) - before.fpos,
                    );
                }
            }
        }
    }
}

const LinkDir = enum { prev, next };

/// Adjusts links based on hinting direction.
fn adjustLink(
    edges: []Edge,
    dim: Dimension,
    edge_ix: usize,
    link_dir: LinkDir,
    top_to_bottom_hinting: bool,
) void {
    if (edge_ix >= edges.len) return;
    const edge = edges[edge_ix];
    var edge2: Edge = undefined;
    var prev_edge: Edge = undefined;
    if (link_dir == .next) {
        if (edge_ix + 1 >= edges.len) return;
        edge2 = edges[edge_ix + 1];
        // Don't adjust the next edge if it's not done yet.
        if (!edge2.flags.contains(TopoFlags.done)) return;
        if (edge_ix == 0) return;
        prev_edge = edges[edge_ix - 1];
    } else {
        if (edge_ix == 0) return;
        edge2 = edges[edge_ix - 1];
        prev_edge = edge2;
    }
    const pos1 = edge.pos;
    const pos2 = edge2.pos;
    const order_check = switch (link_dir) {
        .prev => if (top_to_bottom_hinting) pos1 > pos2 else pos1 < pos2,
        .next => if (top_to_bottom_hinting) pos1 < pos2 else pos1 > pos2,
    };
    if (!order_check) return;
    const link = edge.link(edges) orelse return;
    if (@as(i32, @intCast(@abs(link.pos - prev_edge.pos))) > 16) {
        edges[edge_ix].pos = edge2.pos;
    }
    _ = dim;
}

fn latinRemainingBounds(edges: []const Edge, edge_ix: usize) [2]?usize {
    const lower_bound_ix = if (edge_ix > 0) edge_ix - 1 else null;
    const upper_bound_ix: ?usize = if (edge_ix + 1 < edges.len and
        edges[edge_ix + 1].flags.contains(TopoFlags.done))
        edge_ix + 1
    else
        null;
    return .{ lower_bound_ix, upper_bound_ix };
}

/// Returns the indices of the "completed" edges before and after `ix`.
fn findBoundingCompletedEdges(edges: []const Edge, ix: usize) [2]?usize {
    var before_ix: ?usize = null;
    var i = if (ix > 0) ix - 1 else return .{ null, findAfter(edges, ix) };
    while (true) {
        if (edges[i].flags.contains(TopoFlags.done)) {
            before_ix = i;
            break;
        }
        if (i == 0) break;
        i -= 1;
    }
    return .{ before_ix, findAfter(edges, ix) };
}

fn findAfter(edges: []const Edge, ix: usize) ?usize {
    var i = ix + 1;
    while (i < edges.len) : (i += 1) {
        if (edges[i].flags.contains(TopoFlags.done)) return i;
    }
    return null;
}

/// Snaps a scaled width to one of the standard widths.
fn snapWidth(widths: []const ScaledWidth, width: i32) i32 {
    var best_dist: i32 = 64 + 32 + 2;
    var ref_width: i32 = width;
    for (widths) |candidate| {
        const dist = @as(i32, @intCast(@abs(width - candidate.scaled)));
        if (dist < best_dist) {
            best_dist = dist;
            ref_width = candidate.scaled;
        }
    }
    const scaled = metrics.pixRound(ref_width);
    if (width >= ref_width) {
        if (width < scaled + 48) {
            return ref_width;
        }
        return width;
    } else if (width > scaled - 48) {
        return ref_width;
    }
    return width;
}

/// Computes the snapped width of a given stem.
fn stemWidth(
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
    width: i32,
    base_delta: i32,
    base_flags: TopoFlags,
    stem_flags: TopoFlags,
) i32 {
    if (!scale.flags.contains(metrics.ScaleFlags.stem_adjust) or
        (script_group == .default and metrics_axis.width_metrics.is_extra_light))
    {
        return width;
    }
    const is_vertical = metrics_axis.dim == .vertical;
    const sign: i32 = if (width < 0) -1 else 1;
    var dist: i32 = @intCast(@abs(width));
    if ((is_vertical and !scale.flags.contains(metrics.ScaleFlags.vertical_snap)) or
        (!is_vertical and !scale.flags.contains(metrics.ScaleFlags.horizontal_snap)))
    {
        // Do smooth hinting.
        if (script_group == .default) {
            if (stem_flags.contains(TopoFlags.serif) and is_vertical and dist < 3 * 64) {
                // Don't touch widths of serifs.
                return dist * sign;
            } else if (base_flags.contains(TopoFlags.round)) {
                if (dist < 80) dist = 64;
            } else if (dist < 56) {
                dist = 56;
            }
        }
        if (metrics_axis.widths.len > 0) {
            // Compare to standard width.
            const min_width = metrics_axis.widths.items[0].scaled;
            const delta = @as(i32, @intCast(@abs(dist - min_width)));
            if (delta < 40) {
                dist = @max(min_width, 48);
                return dist * sign;
            }
            if (script_group == .default) {
                // Default/Latin behavior.
                if (dist < 3 * 64) {
                    const frac = dist & 63;
                    dist &= -64;
                    if (frac < 10) {
                        dist += frac;
                    } else if (frac < 32) {
                        dist += 10;
                    } else if (frac < 54) {
                        dist += 54;
                    } else {
                        dist += frac;
                    }
                } else {
                    var new_base_delta: i32 = 0;
                    if ((width > 0 and base_delta > 0) or (width < 0 and base_delta < 0)) {
                        if (scale.size < 10.0) {
                            new_base_delta = base_delta;
                        } else if (scale.size < 30.0) {
                            new_base_delta = @divTrunc(
                                base_delta * @as(i32, @intFromFloat(30.0 - scale.size)),
                                20,
                            );
                        }
                    }
                    dist = (dist - @as(i32, @intCast(@abs(new_base_delta))) + 32) & ~@as(i32, 63);
                }
            }
        }
        if (script_group != .default) {
            // Divergent CJK behavior.
            if (dist < 54) {
                dist += @divTrunc(54 - dist, 2);
            } else if (dist < 3 * 64) {
                const frac = dist & 63;
                dist &= -64;
                if (frac < 10) {
                    dist += frac;
                } else if (frac < 22) {
                    dist += 10;
                } else if (frac < 42) {
                    dist += frac;
                } else if (frac < 54) {
                    dist += 54;
                } else {
                    dist += frac;
                }
            }
        }
    } else {
        // Do strong hinting: snap to integer pixels.
        const original_dist = dist;
        dist = snapWidth(metrics_axis.widths.asSlice(), dist);
        if (is_vertical) {
            // Always round to integers in the vertical case.
            if (dist >= 64) {
                dist = (dist + 16) & ~@as(i32, 63);
            } else {
                dist = 64;
            }
        } else if (scale.flags.contains(metrics.ScaleFlags.mono)) {
            // Mono horizontal hinting.
            if (dist < 64) {
                dist = 64;
            } else {
                dist = (dist + 32) & ~@as(i32, 63);
            }
        } else {
            // Smooth horizontal hinting.
            if (dist < 48) {
                dist = (dist + 64) >> 1;
            } else if (dist < 128) {
                // Only round to integer if distortion is less than 1/4 pixel.
                dist = (dist + 22) & ~@as(i32, 63);
                if (script_group == .default) {
                    const delta = @as(i32, @intCast(@abs(dist - original_dist)));
                    if (delta >= 16) {
                        dist = original_dist;
                        if (dist < 48) {
                            dist = (dist + 64) >> 1;
                        }
                    }
                }
            } else {
                // Round otherwise to prevent color fringes in LCD mode.
                dist = (dist + 32) & ~@as(i32, 63);
            }
        }
    }
    return dist *% sign;
}

/// Aligns one stem edge relative to a previous stem edge.
fn alignLinkedEdge(
    axis: *Axis,
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
    base_edge_ix: usize,
    stem_edge_ix: usize,
) void {
    const edges = axis.edges.items;
    const base_edge = edges[base_edge_ix];
    const stem_edge = edges[stem_edge_ix];
    const width = stem_edge.opos - base_edge.opos;
    const base_delta = base_edge.pos - base_edge.opos;
    const fitted_width = stemWidth(
        metrics_axis,
        script_group,
        scale,
        width,
        base_delta,
        base_edge.flags,
        stem_edge.flags,
    );
    edges[stem_edge_ix].pos = base_edge.pos + fitted_width;
}

/// Shifts the serif edge by the adjustment made to the base edge.
fn alignSerifEdge(axis: *Axis, base_edge_ix: usize, serif_edge_ix: usize) void {
    const edges = axis.edges.items;
    const base_edge = edges[base_edge_ix];
    const serif_edge = edges[serif_edge_ix];
    edges[serif_edge_ix].pos = base_edge.pos + (serif_edge.opos - base_edge.opos);
}

/// Adjusts both edges of a CJK stem and returns the delta.
fn hintNormalStemCjk(
    axis: *Axis,
    metrics_axis: *const ScaledAxisMetrics,
    script_group: ScriptGroup,
    scale: *const Scale,
    edge_ix: usize,
    edge2_ix: usize,
    anchor: i32,
) i32 {
    const max_horizontal_gap: i32 = 9;
    const max_vertical_gap: i32 = 15;
    const max_delta_abs: i32 = 14;
    const edge = axis.edges.items[edge_ix];
    const edge2 = axis.edges.items[edge2_ix];
    const do_stem_adjust = scale.flags.contains(metrics.ScaleFlags.stem_adjust);
    const threshold_delta: i32 = if (do_stem_adjust) 0 else blk: {
        const delta = if (axis.dim == .vertical) max_horizontal_gap else max_vertical_gap;
        break :blk if (edge.flags.contains(TopoFlags.round) and edge2.flags.contains(TopoFlags.round))
            delta
        else
            @divTrunc(delta, 3);
    };
    const threshold = 64 - threshold_delta;
    const original_len = edge2.opos - edge.opos;
    const cur_len = stemWidth(
        metrics_axis,
        script_group,
        scale,
        original_len,
        0,
        edge.flags,
        edge2.flags,
    );
    const original_center = @divTrunc(edge.opos + edge2.opos, 2) + anchor;
    const cur_pos1 = original_center - @divTrunc(cur_len, 2);
    const cur_pos2 = cur_pos1 + cur_len;
    // The upstream `finish` closure; the delta is clamped unless stem
    // adjustment is disabled.
    const Finish = struct {
        fn apply(
            axis_ptr: *Axis,
            edge_ix_ptr: usize,
            edge2_ix_ptr: usize,
            edge_opos: i32,
            edge2_opos: i32,
            cur_pos1_ptr: i32,
            cur_len_ptr: i32,
            do_adjust: bool,
            delta_in: i32,
        ) i32 {
            var delta = delta_in;
            if (!do_adjust) {
                delta = std.math.clamp(delta, -max_delta_abs, max_delta_abs);
            }
            const adjustment = cur_pos1_ptr + delta;
            if (edge_opos < edge2_opos) {
                axis_ptr.edges.items[edge_ix_ptr].pos = adjustment;
                axis_ptr.edges.items[edge2_ix_ptr].pos = adjustment + cur_len_ptr;
            } else {
                axis_ptr.edges.items[edge2_ix_ptr].pos = adjustment;
                axis_ptr.edges.items[edge_ix_ptr].pos = adjustment + cur_len_ptr;
            }
            return delta;
        }
    };
    var d_off1 = cur_pos1 - metrics.pixFloor(cur_pos1);
    var d_off2 = cur_pos2 - metrics.pixFloor(cur_pos2);
    var delta: i32 = 0;
    if (d_off1 == 0 or d_off2 == 0) {
        return Finish.apply(axis, edge_ix, edge2_ix, edge.opos, edge2.opos, cur_pos1, cur_len, do_stem_adjust, delta);
    }
    var u_off1 = 64 - d_off1;
    var u_off2 = 64 - d_off2;
    if (cur_len <= threshold) {
        if (d_off2 < cur_len) {
            delta = if (u_off1 <= d_off2) u_off1 else -d_off2;
        }
        return Finish.apply(axis, edge_ix, edge2_ix, edge.opos, edge2.opos, cur_pos1, cur_len, do_stem_adjust, delta);
    }
    if (threshold < 64 and
        (d_off1 >= threshold or u_off1 >= threshold or d_off2 >= threshold or u_off2 >= threshold))
    {
        return Finish.apply(axis, edge_ix, edge2_ix, edge.opos, edge2.opos, cur_pos1, cur_len, do_stem_adjust, delta);
    }
    var offset = cur_len & 63;
    if (offset < 32) {
        if (u_off1 <= offset or d_off2 <= offset) {
            return Finish.apply(axis, edge_ix, edge2_ix, edge.opos, edge2.opos, cur_pos1, cur_len, do_stem_adjust, delta);
        }
    } else {
        offset = 64 - threshold;
    }
    d_off1 = threshold - u_off1;
    u_off1 -= offset;
    u_off2 = threshold - d_off2;
    d_off2 -= offset;
    if (d_off1 <= u_off1) u_off1 = -d_off1;
    if (d_off2 <= u_off2) u_off2 = -d_off2;
    if (@as(i32, @intCast(@abs(u_off1))) <= @as(i32, @intCast(@abs(u_off2)))) {
        delta = u_off1;
    } else {
        delta = u_off2;
    }
    return Finish.apply(axis, edge_ix, edge2_ix, edge.opos, edge2.opos, cur_pos1, cur_len, do_stem_adjust, delta);
}
