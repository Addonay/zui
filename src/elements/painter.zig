const std = @import("std");
const cozmic = @import("cozmic");
const core = @import("../core/root.zig");
const gpu = @import("../gpu/root.zig");
const engine_mod = @import("../fonts/text_engine.zig");
const images = @import("../images/root.zig");
const platform = @import("../platform/root.zig");
const element = @import("element.zig");
const text_engine = @import("text_engine.zig");

pub fn paint(frame: *element.Frame, root: element.Element, scene: *gpu.Scene) void {
    // Counters describe one paint: a second paint on the same frame (e.g. a
    // repaint without `reset`) must report that paint's values, not the sum
    // of both. Per-node counters are cleared in `paintText` likewise.
    frame.cozmic_painted_extent = 0;
    frame.cozmic_painted_glyphs = 0;
    frame.cozmic_skipped_glyphs = 0;
    frame.cozmic_paint_failures = 0;

    // Frame boundary for the glyph atlas: applies any eviction deferred
    // past the previous frame's emitted glyphs (safe — that frame already
    // presented before this paint runs).
    if (frame.engine) |engine| engine.glyphs.beginFrame();
    paintNode(frame, root.index, scene, core.Color.white, 1, .{
        .x = -1e9,
        .y = -1e9,
        .w = 2e9,
        .h = 2e9,
    });
    // The measure→paint handoff is consumed: release every retained layout
    // so repaints, teardown, and layout+paint loops that never call `reset`
    // cannot leak a shaped buffer. A paint without a new measure reshapes
    // (retainedLayout then finds nothing).
    frame.clearCozmicLayouts();
}

fn alpha(color: core.Color, opacity: f32) core.Color {
    var result = color;
    result.a *= opacity;
    return result;
}

fn intersect(a: core.Rect, b: core.Rect) core.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x, .y = y, .w = @max(0, right - x), .h = @max(0, bottom - y) };
}

fn contentBox(node: *const element.Node) core.Rect {
    return .{
        .x = node.bounds.x + node.style.padding.left,
        .y = node.bounds.y + node.style.padding.top,
        .w = @max(0, node.bounds.w - node.style.padding.left - node.style.padding.right),
        .h = @max(0, node.bounds.h - node.style.padding.top - node.style.padding.bottom),
    };
}

fn gradientQuad(scene: *gpu.Scene, bounds: core.Rect, from: core.Color, to: core.Color, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0) return;
    if (from.a <= 0 and to.a <= 0) return;
    const visible = intersect(bounds, clip);
    if (visible.w <= 0 or visible.h <= 0) return;
    // Geometry goes out UNCUT with the clip attached: the rasterizer cuts
    // per pixel, so a partial clip keeps the corner radius and the full
    // gradient span (a clipped slice shows the same colors as the unclipped
    // button at those pixels).
    _ = scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = from, .gradient_to = to, .radius = radius, .clip = clip });
}

fn quad(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0 or color.a <= 0) return;
    if (intersect(bounds, clip).w <= 0 or intersect(bounds, clip).h <= 0) return;
    _ = scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = color, .radius = radius, .clip = clip });
}

/// Border ring: one quad that honors `radius` exactly. The old 4-strip
/// emulation drew square corners, which poked past rounded backgrounds and
/// left background-colored notches (seen on the circular checkbox).
fn ring(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, width: f32, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0 or color.a <= 0 or width <= 0) return;
    if (intersect(bounds, clip).w <= 0 or intersect(bounds, clip).h <= 0) return;
    _ = scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = color, .radius = radius, .border_width = width, .clip = clip });
}

fn paintNode(frame: *element.Frame, index: u16, scene: *gpu.Scene, inherited_color: core.Color, inherited_opacity: f32, clip: core.Rect) void {
    const node = &frame.nodes[index];
    // Hover follows the effective clip like hit-testing does: a clipped-away
    // control neither highlights nor clicks.
    const hovered = intersect(node.bounds, clip).contains(frame.pointer);
    const style = node.style;
    // Group opacity accumulates down the tree: a 0.5 child inside a 0.5
    // parent draws at 0.25. (True isolated group compositing would need an
    // offscreen buffer; multiplied alpha is the documented approximation.)
    const opacity = inherited_opacity * style.opacity;

    if (style.shadow) {
        // Two-layer shadow: wide faint halo + tight contact layer. Reads as
        // soft elevation instead of a hard offset slab.
        const outer = core.Rect{ .x = node.bounds.x - 6, .y = node.bounds.y + 4, .w = node.bounds.w + 12, .h = node.bounds.h + 12 };
        quad(scene, outer, alpha(core.Color.rgba(0, 0, 0, 0.14), opacity), style.radius + 6, clip);
        const inner = core.Rect{ .x = node.bounds.x - 2, .y = node.bounds.y + 2, .w = node.bounds.w + 4, .h = node.bounds.h + 4 };
        quad(scene, inner, alpha(core.Color.rgba(0, 0, 0, 0.16), opacity), style.radius + 2, clip);
    }
    if (style.blur > 0 and style.background != null) {
        // Fake blur as a soft falloff: concentric expanding layers, largest
        // and faintest first so the center accumulates softly with no hard
        // edge (single-quad "blurs" rendered as solid discs).
        const spread = style.blur * 0.3;
        const layers: usize = 8;
        for (0..layers) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(layers));
            const expand = spread * (1 - t);
            // Faintest on the outside, stronger toward the center so the
            // layers accumulate softly with no visible rim.
            const layer_alpha = opacity * (0.013 + 0.013 * t);
            const glow = core.Rect{
                .x = node.bounds.x - expand,
                .y = node.bounds.y - expand,
                .w = node.bounds.w + expand * 2,
                .h = node.bounds.h + expand * 2,
            };
            quad(scene, glow, alpha(style.background.?, layer_alpha), style.radius + expand, clip);
        }
    }

    const background = if (hovered) style.hover_background orelse style.background else style.background;
    if (background) |from| {
        if (style.gradient_to) |to| {
            gradientQuad(scene, node.bounds, alpha(from, opacity), alpha(to, opacity), style.radius, clip);
        } else {
            quad(scene, node.bounds, alpha(from, opacity), style.radius, clip);
        }
    }

    if (style.border_width > 0) {
        const border = if (hovered) style.hover_border orelse style.border_color else style.border_color;
        if (border) |border_color| paintBorder(scene, node.bounds, alpha(border_color, opacity), style.border_width, style.dashed_border, style.border_bottom_only, style.radius, clip);
    }

    const text_color = alpha(node.text_style.color orelse style.text_color orelse inherited_color, opacity);
    if (node.kind == .text) paintText(frame, scene, node, text_color, clip);
    if (node.kind == .image) paintImage(frame, scene, node, opacity, clip);

    if (node.listener != null or node.mouse_down_listener != null or node.double_click_listener != null or node.focus != null) {
        // Hit regions obey the same effective clip as paint: a clipped-away
        // control cannot be clicked. Empty clips register nothing.
        const hit = intersect(node.bounds, clip);
        if (hit.w > 0 and hit.h > 0) {
            _ = frame.addRegion(.{ .bounds = hit, .listener = node.listener, .mouse_down_listener = node.mouse_down_listener, .double_click_listener = node.double_click_listener, .focus = node.focus, .cursor = node.style.cursor });
        }
    }

    var child = node.first_child;
    // Children clip to this node's content box: overflowing text (long
    // titles, the composer placeholder) gets cut at the field edge instead
    // of bleeding into neighbors. Shadows/glow above intentionally use the
    // looser incoming clip so they can bleed outward.
    const child_clip = intersect(clip, contentBox(node));
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
        paintNode(frame, child_index, scene, style.text_color orelse inherited_color, opacity, child_clip);
    }
}

fn paintBorder(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, width: f32, dashed: bool, bottom_only: bool, radius: f32, clip: core.Rect) void {
    if (bottom_only) {
        quad(scene, .{ .x = bounds.x, .y = bounds.y + bounds.h - width, .w = bounds.w, .h = width }, color, 0, clip);
        return;
    }
    if (!dashed) {
        ring(scene, bounds, color, width, radius, clip);
        return;
    }
    const dash: f32 = 6;
    var x = bounds.x;
    while (x < bounds.x + bounds.w) : (x += dash * 2) {
        const w = @min(dash, bounds.x + bounds.w - x);
        quad(scene, .{ .x = x, .y = bounds.y, .w = w, .h = width }, color, 0, clip);
        quad(scene, .{ .x = x, .y = bounds.y + bounds.h - width, .w = w, .h = width }, color, 0, clip);
    }
    var y = bounds.y;
    while (y < bounds.y + bounds.h) : (y += dash * 2) {
        const h = @min(dash, bounds.y + bounds.h - y);
        quad(scene, .{ .x = bounds.x, .y = y, .w = width, .h = h }, color, 0, clip);
        quad(scene, .{ .x = bounds.x + bounds.w - width, .y = y, .w = width, .h = h }, color, 0, clip);
    }
}

/// Resolve an image node to a cache handle and emit a blit. Drops the
/// image (logs at the cache) when sources fail, the cache is full, the
/// retained handle went stale, or no cache/allocator is attached — same
/// policy as quad overflow.
fn paintImage(frame: *element.Frame, scene: *gpu.Scene, node: *const element.Node, opacity: f32, clip: core.Rect) void {
    const desc = node.image;
    const bw = node.bounds.w;
    const bh = node.bounds.h;
    if (bw <= 0 or bh <= 0) return;
    const cache = frame.images orelse return;

    // Retained handles resolve without decoding or I/O, so they need no
    // allocator; bytes/path sources do.
    const handle: images.Handle = switch (desc.source) {
        .handle => |h| if (cache.validate(h, frame.frame_id)) h else return,
        .bytes, .path => blk: {
            const alloc = frame.allocator orelse return;
            break :blk switch (desc.source) {
                .bytes => |bytes| resolveBytes(cache, alloc, bytes, desc, bw, bh, frame.frame_id) orelse return,
                .path => |path| readPathBytes(cache, alloc, path, desc, bw, bh, frame.frame_id) orelse return,
                .handle => unreachable,
            };
        },
    };

    if (handle.w == 0 or handle.h == 0) return;
    const iw: f32 = @floatFromInt(handle.w);
    const ih: f32 = @floatFromInt(handle.h);

    // Object-fit: dest rect + source crop window in source pixels.
    var dx = node.bounds.x;
    var dy = node.bounds.y;
    var dw = bw;
    var dh = bh;
    var sx: f32 = 0;
    var sy: f32 = 0;
    var sw = iw;
    var sh = ih;
    switch (desc.fit) {
        .fill => {},
        .contain => {
            const s = @min(bw / iw, bh / ih);
            dw = iw * s;
            dh = ih * s;
            dx += (bw - dw) / 2;
            dy += (bh - dh) / 2;
        },
        .cover => {
            const s = @max(bw / iw, bh / ih);
            sw = bw / s;
            sh = bh / s;
            sx = (iw - sw) / 2;
            sy = (ih - sh) / 2;
        },
    }

    var tint = desc.tint orelse core.Color.white;
    tint.a *= opacity;
    _ = scene.pushImage(.{
        .x = dx,
        .y = dy,
        .w = dw,
        .h = dh,
        .pool_offset = handle.offset,
        .src_w = handle.w,
        .src_h = handle.h,
        .src_x = sx,
        .src_y = sy,
        .src_crop_w = sw,
        .src_crop_h = sh,
        .tint = tint,
        .gray = desc.gray,
        .radius = node.style.radius,
        .clip = clip,
    });
}

/// Path sources: read the file, then resolve like bytes.
fn readPathBytes(
    cache: *images.Cache,
    alloc: std.mem.Allocator,
    path: []const u8,
    desc: element.ImageDesc,
    bw: f32,
    bh: f32,
    frame_id: u64,
) ?images.Handle {
    const bytes = element.readPath(alloc, path) catch return null;
    defer alloc.free(bytes);
    return resolveBytes(cache, alloc, bytes, desc, bw, bh, frame_id);
}

/// Decode-or-rasterize bytes at the draw size (svg) or intrinsic size.
fn resolveBytes(
    cache: *images.Cache,
    alloc: std.mem.Allocator,
    bytes: []const u8,
    desc: element.ImageDesc,
    bw: f32,
    bh: f32,
    frame_id: u64,
) ?images.Handle {
    const is_svg = desc.svg or images.sniff(bytes) == .svg;
    if (is_svg) {
        const dw: u32 = @intFromFloat(@max(1.0, bw));
        const dh: u32 = @intFromFloat(@max(1.0, bh));
        return cache.svgFromBytes(alloc, bytes, dw, dh, desc.tint, frame_id) catch null;
    }
    return cache.imageFromBytes(alloc, bytes, frame_id) catch null;
}

fn paintText(frame: *element.Frame, scene: *gpu.Scene, node: *element.Node, color: core.Color, clip: core.Rect) void {
    // Node counters describe this paint only: a reused node must not carry
    // stale values from an earlier paint, and the frame aggregates stay the
    // sum of node values.
    node.cozmic_painted_extent = 0;
    node.cozmic_painted_glyphs = 0;
    node.cozmic_skipped_glyphs = 0;
    node.cozmic_paint_failures = 0;

    // Text is always cozmic. Without an engine installed there is no legacy
    // fallback: emit nothing and count the node as a paint failure so the gap
    // stays observable.
    const engine = frame.engine orelse {
        node.cozmic_paint_failures += 1;
        frame.cozmic_paint_failures += 1;
        return;
    };
    // Measure→paint ownership: only a node whose measure actually produced a
    // cozmic box may paint. A node that measured as skipped (no engine at
    // measure time, invalid metrics) has a zero natural box, and painting a
    // fresh shape into it would put ink in a box nobody sized; count the
    // mismatch instead.
    if (!node.cozmic_measured) {
        node.cozmic_paint_failures += 1;
        frame.cozmic_paint_failures += 1;
        return;
    }
    paintShapedCozmic(frame, engine, scene, node, color, clip);
}

/// Cozmic paint path: one layout for the node, glyphs placed from cozmic's
/// physical positions and rasterized through `Engine.cache`.
///
/// The layout is the one `layout.measure` retained when it matches the node's
/// current inputs and this engine (`text_engine.retainedLayout`); the emit
/// pass below is the same code either way, so reuse cannot change positions,
/// decorations, or fallback policy. Without a valid handoff the node is
/// reshaped here from the same inputs as measure. A glyph that cannot be
/// rasterized (unknown face, atlas full, color-only ink) is skipped and
/// counted, and a layout that cannot be shaped emits nothing — the measured
/// box stays valid either way.
fn paintShapedCozmic(
    frame: *element.Frame,
    engine: *engine_mod.Engine,
    scene: *gpu.Scene,
    node: *element.Node,
    color: core.Color,
    clip: core.Rect,
) void {
    // Measure→paint reuse. The retained layout is valid only for the exact
    // inputs it was shaped from; a mismatch (style change, wrap width
    // change, engine switch) falls through to a fresh shape, never stale
    // metrics.
    if (text_engine.retainedLayout(frame, node)) |cached| {
        paintLayoutCozmic(frame, engine, scene, node, &cached.layout, color, clip);
        return;
    }

    var layout = text_engine.shape(engine, node, text_engine.frameAllocator(frame)) catch {
        // Same shape inputs as measure; only resource failures land here.
        // The measured box stays, and the empty result is observable.
        node.cozmic_paint_failures += 1;
        frame.cozmic_paint_failures += 1;
        return;
    };
    defer layout.deinit();
    paintLayoutCozmic(frame, engine, scene, node, &layout, color, clip);
}

/// Per-glyph sink for `Layout.render`. Checks the atlas, rasterizes through
/// `Engine.cache.getImage` on a miss, uploads masks through
/// `Atlas.putBitmap`, and pushes the scene glyph at the atlas entry's
/// placement. Color and subpixel images are treated as misses (the
/// single-channel atlas cannot represent them) rather than emitting garbage.
const GlyphSink = struct {
    engine: *engine_mod.Engine,
    scene: *gpu.Scene,
    node: *const element.Node,
    color: core.Color,
    clip: core.Rect,
    /// Layout-local origin: node content x plus the vertical centering
    /// offset. Cozmic's physical glyph coordinates are relative to it.
    origin_x: f32,
    origin_y: f32,
    emitted: u64 = 0,
    skipped: u64 = 0,

    fn renderer(self: *GlyphSink) cozmic.render.Renderer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = cozmic.render.Renderer.VTable{
        .rectangle = rectangle,
        .glyph = glyph,
    };

    /// Text decorations from cozmic land as quads at layout-local
    /// coordinates. No decoration attrs are requested today; the strike rule
    /// is emitted by `paintLayoutCozmic`.
    fn rectangle(ctx: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: cozmic.Color) void {
        _ = color;
        const self: *GlyphSink = @ptrCast(@alignCast(ctx));
        quad(self.scene, .{
            .x = self.origin_x + @as(f32, @floatFromInt(x)),
            .y = self.origin_y + @as(f32, @floatFromInt(y)),
            .w = @as(f32, @floatFromInt(w)),
            .h = @as(f32, @floatFromInt(h)),
        }, self.color, 0, self.clip);
    }

    fn glyph(ctx: *anyopaque, physical_glyph: cozmic.layout.PhysicalGlyph, color: cozmic.Color) void {
        _ = color; // ZUI resolves the node color once (group opacity).
        const self: *GlyphSink = @ptrCast(@alignCast(ctx));
        // `.notdef` has no usable ink (the symbol-face substitution it used
        // to fall back to is gone): skip and count it, never rasterize the
        // tofu box.
        if (physical_glyph.cache_key.glyph_id == 0) {
            self.skipped += 1;
            return;
        }
        const key = atlasKeyFor(self.engine, self.node.text_style.weight, physical_glyph);
        const entry = self.engine.glyphs.get(key) orelse blk: {
            const image = self.engine.cache.getImage(physical_glyph.cache_key) catch {
                self.skipped += 1;
                return;
            };
            const view = image orelse {
                self.skipped += 1;
                return;
            };
            // The pool is single-channel coverage: color/subpixel images are
            // an explicit miss, never bytes reinterpreted as a mask.
            if (view.content != .mask) {
                self.skipped += 1;
                return;
            }
            const bytes = @as(usize, view.placement.width) * view.placement.height;
            if (view.data.len < bytes) {
                self.skipped += 1;
                return;
            }
            break :blk self.engine.glyphs.putBitmap(
                key,
                view.placement.width,
                view.placement.height,
                view.placement.width,
                view.data.ptr,
                view.placement.left,
                view.placement.top,
                .mask,
                key.synthetic_bold,
            ) catch {
                self.skipped += 1;
                return;
            };
        };
        if (entry.width == 0 or entry.height == 0) {
            self.skipped += 1; // empty raster (spaces)
            return;
        }
        if (self.scene.pushGlyph(.{
            .x = self.origin_x + @as(f32, @floatFromInt(physical_glyph.x)) + @as(f32, @floatFromInt(entry.bearing_x)),
            .y = self.origin_y + @as(f32, @floatFromInt(physical_glyph.y)) - @as(f32, @floatFromInt(entry.bearing_y)),
            .w = entry.width,
            .h = entry.height,
            .color = self.color,
            .atlas_offset = entry.offset,
            .clip = self.clip,
        })) {
            self.emitted += 1;
        } else {
            self.skipped += 1; // scene full: no ink emitted
        }
    }
};

/// Atlas key for one physical glyph. Mirrors the FULL cozmic raster key
/// (subpixel bins, weight, flags) — each of those changes the rasterized
/// image — plus the synthetic-dilation variant flag, so a dilated entry can
/// never alias the same weight's undilated ink.
fn atlasKeyFor(
    engine: *engine_mod.Engine,
    requested: element.FontWeight,
    physical_glyph: cozmic.layout.PhysicalGlyph,
) engine_mod.AtlasKey {
    const cache_key = physical_glyph.cache_key;
    return .{
        .face_id = cache_key.font_id,
        .glyph_id = cache_key.glyph_id,
        .size_px = engine_mod.sizeToPx(cache_key.fontSize()),
        .x_bin = cache_key.x_bin,
        .y_bin = cache_key.y_bin,
        .font_weight = cache_key.font_weight,
        .flags = cache_key.flags,
        .synthetic_bold = text_engine.syntheticBold(engine, requested, cache_key.font_id),
    };
}

/// Emit one shaped cozmic layout into the scene. Shared verbatim by the
/// retained-layout path and the reshape path, so a cache hit is
/// indistinguishable in the scene from a fresh shape.
fn paintLayoutCozmic(
    frame: *element.Frame,
    engine: *engine_mod.Engine,
    scene: *gpu.Scene,
    node: *element.Node,
    layout: *engine_mod.Layout,
    color: core.Color,
    clip: core.Rect,
) void {
    // Baseline = node origin + vertical centering + cozmic's run baseline;
    // physical glyph y already includes the run baseline.
    const v_offset = node.bounds.y + @max(0, (node.bounds.h - layout.height) / 2);
    var sink = GlyphSink{
        .engine = engine,
        .scene = scene,
        .node = node,
        .color = color,
        .clip = clip,
        .origin_x = node.bounds.x,
        .origin_y = v_offset,
    };
    if (layout.render(sink.renderer(), cozmic.Color{ .value = 0xFF00_0000 })) |_| {} else |_| {
        // Resource failure: the scene may hold partial ink, so keep the
        // sink's counts and make the node observable as failed.
        node.cozmic_paint_failures += 1;
        frame.cozmic_paint_failures += 1;
    }

    // Strike: one rule per layout run at that run's baseline, so wrapped
    // and multi-line text gets a rule on every line instead of only the
    // first. Cozmic's default strikethrough offset is 0.3em above the
    // baseline; line_y is cozmic's baseline.
    if (node.text_style.strike) {
        const thickness = @max(1.0, @as(f32, @floatFromInt(engine_mod.sizeToPx(node.text_style.size))) / 14.0);
        var runs = layout.runs();
        while (runs.next()) |run| {
            quad(scene, .{
                .x = node.bounds.x,
                .y = v_offset + run.line_y - node.text_style.size * 0.3,
                .w = node.bounds.w,
                .h = thickness,
            }, color, 0, clip);
        }
    }

    node.cozmic_painted_extent = layout.width;
    node.cozmic_painted_glyphs = sink.emitted;
    node.cozmic_skipped_glyphs = sink.skipped;
    frame.cozmic_painted_extent = @max(frame.cozmic_painted_extent, layout.width);
    frame.cozmic_painted_glyphs += sink.emitted;
    frame.cozmic_skipped_glyphs += sink.skipped;
}

test "gradient background emits a single quad" {
    const t = @import("std").testing;
    // Heap-allocated: Frame+Scene on the stack (~8.6MB) forces deep stack
    // growth that collides with heap mmaps depending on order/ASLR (flaky
    // segfault); see the budget test below.
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(100).h(20).bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8));
    @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 20 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 1), scene.slice().len);
    try t.expect(scene.slice()[0].gradient_to != null);
    try t.expectEqual(@as(f32, 100), scene.slice()[0].w);
}

test "overflowing text clips to parent content box" {
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(60).h(30).bg(core.Color.hex(0x1e1f2a))
        .child(element.text("aaaaaaaaaaaaaaaaaaaa", .{ .size = 14 }));
    @import("layout.zig").layout(frame, root, .{ .w = 200, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expect(scene.glyphSlice().len > 0); // clipped glyph ink, no bitmap quads
    // Scene geometry is logical (uncut); the clip binds at rasterization.
    // Render and assert no painted pixel escapes the 60px field.
    var buf: [200 * 100 * 4]u8 = undefined;
    const target = gpu.software.Target.init(&buf, 200, 100, .rgba32);
    target.clear(core.Color.hex(0x000000));
    target.renderScene(scene, &.{}, &.{});
    var y: usize = 0;
    while (y < 100) : (y += 1) {
        var x: usize = 60;
        while (x < 200) : (x += 1) {
            const off = (y * 200 + x) * 4;
            try t.expectEqual(@as(u8, 0), buf[off]);
            try t.expectEqual(@as(u8, 0), buf[off + 1]);
            try t.expectEqual(@as(u8, 0), buf[off + 2]);
        }
    }
    // ...while the field itself did paint.
    try t.expect(buf[(15 * 200 + 30) * 4 + 2] > 0 or buf[(15 * 200 + 30) * 4] > 0);
}

test "blurred background emits soft falloff layers" {
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(50).h(50).bg(core.Color.hex(0x7c5cff)).blur(60);
    @import("layout.zig").layout(frame, root, .{ .w = 50, .h = 50 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    // 8 glow layers + 1 background (was a single hard disc before).
    try t.expectEqual(@as(usize, 9), scene.slice().len);
    // Outermost layer is the largest and faintest.
    try t.expect(scene.slice()[0].w > scene.slice()[6].w);
    try t.expect(scene.slice()[0].color.a < scene.slice()[5].color.a);
}

test "hot frame structs stay within stack budget" {
    // Regression for flaky segfaults: in Debug, Frame (~2.5MB) + Scene
    // (~5.9MB, quads carry their clip) stack to ~8.6MB frames. Deep stack
    // growth into heap-mmap territory segfaults depending on order/ASLR —
    // never on a fixed threshold, so the rule is structural, not numeric:
    // heap-allocate whenever a function holds more than one of Frame/Scene
    // (or calls an engine init beneath them). Production keeps them on the
    // heap (Window, App); tests use the allocator (see the font tests).
    // Structural fix (pools behind init/deinit) is plan M10; until then
    // these pins fail loudly on growth instead of segfaulting rarely.
    const t = @import("std").testing;
    try t.expect(@sizeOf(element.Frame) < 4 * 1024 * 1024);
    try t.expect(@sizeOf(gpu.Scene) < 7 * 1024 * 1024);
    try t.expect(@sizeOf(element.Frame) + @sizeOf(gpu.Scene) < 9 * 1024 * 1024);
}

test "shaped text emits atlas glyphs, not bitmap quads" {
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("Hi", .{ .size = 16 });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);

    // Both glyphs have ink; a bare text node emits no quads at all.
    const glyphs = scene.glyphSlice();
    try t.expectEqual(@as(usize, 2), glyphs.len);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expect(glyphs[1].x > glyphs[0].x);
    for (glyphs) |g| {
        try t.expect(g.w > 0 and g.h > 0);
        const bytes = @as(usize, g.w) * g.h;
        try t.expect(g.atlas_offset + bytes <= engine.glyphs.pixels_used);
    }
}

test "missing glyph emits no ink and is counted" {
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    // U+6F22 (CJK) is covered by none of the vendored corpus faces and the
    // old symbol-face substitution is gone: the `.notdef` glyph must be
    // skipped (counted) instead of emitting garbage.
    const root = element.text("A漢B", .{ .size = 16 });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);

    try t.expectEqual(@as(usize, 2), scene.glyphSlice().len); // A, B
    try t.expectEqual(@as(u64, 1), frame.cozmic_skipped_glyphs);
    try t.expectEqual(@as(u64, 2), frame.cozmic_painted_glyphs);
}

test "rounded border ring leaves no notches" {
    // Repro: the circular checkbox (rounded_full bg + border_2, same color)
    // showed background-colored corner notches because borders drew as
    // square strips past the rounded background.
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const green = core.Color.hex(0x3DDC84);
    const root = element.div().size(24).rounded_full().bg(green).border_2().border_color(green);
    @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    // One fill + one ring (was 1 fill + 4 strips).
    try t.expectEqual(@as(usize, 2), scene.slice().len);

    var buf: [24 * 24 * 4]u8 = undefined;
    const target = gpu.software.Target.init(&buf, 24, 24, .rgba32);
    target.clear(core.Color.hex(0x000000));
    target.renderScene(scene, &.{}, &.{});
    const at = struct {
        fn pixel(pixels: []u8, x: usize, y: usize) u8 {
            return pixels[(y * 24 + x) * 4 + 1]; // green channel
        }
    }.pixel;
    // Fill center, ring band on edges, empty outside the circle. The old
    // square strips painted (0,0) green (poke-out); the ring must not.
    try t.expectEqual(@as(u8, 0), at(&buf, 0, 0));
    try t.expect(at(&buf, 12, 0) > 200);
    try t.expect(at(&buf, 0, 12) > 200);
    try t.expect(at(&buf, 12, 12) > 200);
}

// 4x2 RGB PNG (top row red, bottom row blue).
const test_png: []const u8 = &.{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xf0, 0xca, 0xea,
    0x34, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xfc, 0xcf, 0x80, 0x00,
    0x8c, 0x0c, 0x0c, 0x08, 0x2e, 0x00, 0x23, 0x1e, 0x02, 0x01, 0x06, 0xf7, 0x4a, 0xae, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const test_icon =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>
;

fn testImageFrame(frame: *element.Frame, cache: *images.Cache) void {
    frame.reset(@ptrFromInt(1), .{});
    frame.images = cache;
    frame.allocator = @import("std").testing.allocator;
    frame.frame_id = 1;
    element.beginFrame(frame);
}

test "img element measures intrinsic size and paints one blit" {
    const t = @import("std").testing;
    var cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    testImageFrame(frame, cache);
    defer element.endFrame();
    const root = element.img(test_png);
    @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
    try t.expectEqual(@as(f32, 4), frame.nodes[root.index].measured.w);
    try t.expectEqual(@as(f32, 2), frame.nodes[root.index].measured.h);
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
    const b = scene.imageSlice()[0];
    try t.expectEqual(@as(u32, 4), b.src_w);
    try t.expectEqual(@as(u32, 2), b.src_h);
    // Root stretches to the 100x100 viewport; contain letterboxes the 4x2
    // artwork to 100x50 centered vertically.
    try t.expectEqual(@as(f32, 100), b.w);
    try t.expectEqual(@as(f32, 50), b.h);
    try t.expectEqual(@as(f32, 0), b.x);
    try t.expectEqual(@as(f32, 25), b.y);

    // Pixels land in the target: red top row, blue bottom row.
    var buf: [100 * 100 * 4]u8 = undefined;
    const target = gpu.software.Target.init(&buf, 100, 100, .rgba32);
    target.clear(core.Color.hex(0x000000));
    target.renderScene(scene, &.{}, cache.pool[0..cache.used]);
    try t.expectEqual(@as(u8, 255), buf[(25 * 100 + 0) * 4]);
    try t.expectEqual(@as(u8, 255), buf[(74 * 100 + 0) * 4 + 2]);
}

test "img aspect derives the missing axis and cover crops" {
    const t = @import("std").testing;
    var cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    // 4x2 source at h=10 derives w=20.
    {
        const frame = try t.allocator.create(element.Frame);
        defer t.allocator.destroy(frame);
        frame.* = .{};
        testImageFrame(frame, cache);
        defer element.endFrame();
        const root = element.img(test_png).h(10);
        @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
        try t.expectEqual(@as(f32, 20), frame.nodes[root.index].measured.w);
        try t.expectEqual(@as(f32, 10), frame.nodes[root.index].measured.h);
    }

    // Cover in a square box: full dest, centered horizontal crop.
    const frame2 = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame2);
    frame2.* = .{};
    testImageFrame(frame2, cache);
    defer element.endFrame();
    const cover = element.img(test_png).w(10).h(10).object_fit(.cover);
    @import("layout.zig").layout(frame2, cover, .{ .w = 100, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame2, cover, scene);
    try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
    const b = scene.imageSlice()[0];
    try t.expectEqual(@as(f32, 10), b.w);
    try t.expectEqual(@as(f32, 10), b.h);
    // 4x2 into 10x10 cover: scale 5, visible 2x2 window centered -> x=1.
    try t.expectApproxEqAbs(@as(f32, 1), b.src_x, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), b.src_y, 0.01);
    try t.expectApproxEqAbs(@as(f32, 2), b.src_crop_w, 0.01);
    try t.expectApproxEqAbs(@as(f32, 2), b.src_crop_h, 0.01);
}

test "svg icon paints tinted blit, drops without cache" {
    const t = @import("std").testing;
    var cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    {
        const frame = try t.allocator.create(element.Frame);
        defer t.allocator.destroy(frame);
        frame.* = .{};
        testImageFrame(frame, cache);
        defer element.endFrame();
        const root = element.svg(test_icon).w(24).h(24).tint(core.Color.hex(0xFFFFFF));
        @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
        const scene = try t.allocator.create(gpu.Scene);
        defer t.allocator.destroy(scene);
        scene.* = .{};
        paint(frame, root, scene);
        try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
        const b = scene.imageSlice()[0];
        try t.expectEqual(@as(u32, 24), b.src_w);
        try t.expectEqual(@as(u32, 24), b.src_h);

        // Raster proof: white stroke pixels present in the pool region.
        const px = cache.pool[b.pool_offset..][0 .. @as(usize, b.src_w) * b.src_h * 4];
        var lit: usize = 0;
        var i: usize = 0;
        while (i < px.len) : (i += 4) {
            if (px[i + 3] > 8 and px[i] > 200) lit += 1;
        }
        try t.expect(lit > 20);
    }

    // No cache attached: drops silently, never crashes.
    var bare = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(bare);
    bare.* = .{};
    bare.reset(@ptrFromInt(1), .{});
    element.beginFrame(bare);
    defer element.endFrame();
    const root2 = element.svg(test_icon).w(24).h(24);
    @import("layout.zig").layout(bare, root2, .{ .w = 100, .h = 100 });
    const scene2 = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene2);
    scene2.* = .{};
    paint(bare, root2, scene2);
    try t.expectEqual(@as(usize, 0), scene2.imageSlice().len);
}

test "nested opacity multiplies down the tree" {
    // 0.5 parent x 0.5 child = 0.25 effective. Over black, white lands at
    // ~64. (The old painter applied only the node's own opacity, so the
    // child drew at 0.5; text ignored opacity entirely.)
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(10).h(10).opacity(0.5)
        .child(element.div().w(10).h(10).bg(core.Color.hex(0xFFFFFF)).opacity(0.5));
    @import("layout.zig").layout(frame, root, .{ .w = 10, .h = 10 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    var buf: [10 * 10 * 4]u8 = undefined;
    const target = gpu.software.Target.init(&buf, 10, 10, .rgba32);
    target.clear(core.Color.hex(0x000000));
    target.renderScene(scene, &.{}, &.{});
    const v = buf[(5 * 10 + 5) * 4];
    try t.expect(v > 55 and v < 75);
}

test "imgHandle validates generations, drops stale" {
    const t = @import("std").testing;
    var cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    // Valid handle resolved through the real decode path paints one blit.
    const h = try cache.imageFromBytes(t.allocator, test_png, 1);
    {
        const frame = try t.allocator.create(element.Frame);
        defer t.allocator.destroy(frame);
        frame.* = .{};
        frame.images = cache;
        frame.frame_id = 1;
        element.beginFrame(frame);
        defer element.endFrame();
        const root = element.imgHandle(h).w(2).h(2);
        @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
        const scene = try t.allocator.create(gpu.Scene);
        defer t.allocator.destroy(scene);
        scene.* = .{};
        paint(frame, root, scene);
        try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
    }
    // Next frame the pool resets around the retained handle (stale pin, no
    // current-frame pins): the same element now paints nothing instead of
    // another image's recycled bytes. The reset is forced by rasterizing
    // the icon at 1024x2048 (exactly the pool size) on frame 2.
    _ = try cache.svgFromBytes(t.allocator, test_icon, 1024, 2048, null, 2);
    {
        const frame = try t.allocator.create(element.Frame);
        defer t.allocator.destroy(frame);
        frame.* = .{};
        frame.images = cache;
        frame.frame_id = 2;
        element.beginFrame(frame);
        defer element.endFrame();
        const root = element.imgHandle(h).w(2).h(2);
        @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
        const scene = try t.allocator.create(gpu.Scene);
        defer t.allocator.destroy(scene);
        scene.* = .{};
        paint(frame, root, scene);
        try t.expectEqual(@as(usize, 0), scene.imageSlice().len);
    }
}

test "hit regions obey the painter clip" {
    // A 20x20 button overflowing a 20x20 field at (15,15): paint clips the
    // region to the visible 5x5, so clicks outside cannot hit it.
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const L = struct {
        fn noop(_: *anyopaque, _: *const element.ListenerPayload, _: *anyopaque) void {}
    }.noop;
    const root = element.div().w(20).h(20)
        .child(element.div().w(20).h(20).absolute().left(15).top(15).on_click(.{ .target = frame, .call_fn = L }));
    @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 1), frame.region_count);
    const r = frame.regions[0].bounds;
    try t.expectEqual(@as(f32, 15), r.x);
    try t.expectEqual(@as(f32, 15), r.y);
    try t.expectEqual(@as(f32, 5), r.w);
    try t.expectEqual(@as(f32, 5), r.h);
    try t.expect(!r.contains(.{ .x = 25, .y = 16 }));
    try t.expect(r.contains(.{ .x = 16, .y = 16 }));
}

test "painted regions carry the style cursor" {
    // .cursor_pointer() must reach the hit region so hover can show the
    // hand; plain regions carry no opinion (null, not a forced default).
    const t = @import("std").testing;
    var frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    const L = struct {
        fn noop(_: *anyopaque, _: *const element.ListenerPayload, _: *anyopaque) void {}
    }.noop;
    const root = element.div().w(100).h(100)
        .child(element.div().w(10).h(10).cursor_pointer().on_click(.{ .target = frame, .call_fn = L }))
        .child(element.div().w(10).h(10).on_click(.{ .target = frame, .call_fn = L }));
    @import("layout.zig").layout(frame, root, .{ .w = 100, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 2), frame.region_count);
    try t.expectEqual(@as(?platform.CursorShape, .pointer), frame.regions[0].cursor);
    try t.expectEqual(@as(?platform.CursorShape, null), frame.regions[1].cursor);
}

test "region overflow counts instead of silently dropping clicks" {
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    var i: usize = 0;
    while (i < element.max_regions + 10) : (i += 1) {
        _ = frame.addRegion(.{ .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 } });
    }
    try t.expectEqual(@as(usize, element.max_regions), frame.region_count);
    try t.expectEqual(@as(u64, 10), frame.dropped_regions);
}

test "text frame without an engine emits no text" {
    // There is no legacy or bitmap fallback: with no engine installed the
    // text node measures as zero and paints nothing, and the gap is
    // observable as a paint failure instead of silent stale ink.
    const t = @import("std").testing;
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("abc", .{ .size = 14 });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    try t.expect(!node.cozmic_measured);
    try t.expectEqual(@as(f32, 0), node.measured.w);

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 0), scene.glyphSlice().len);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expectEqual(@as(u64, 1), node.cozmic_paint_failures);
    try t.expectEqual(@as(u64, 1), frame.cozmic_paint_failures);
    try t.expectEqual(@as(u64, 0), frame.cozmic_painted_glyphs);
}

test "shape failure at paint skips ink instead of stale metrics" {
    // A paint-time replay that cannot shape must keep the measured box and
    // emit no ink into it (there is no second engine to repaint with).
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("Hi", .{ .size = 16, .line_height = 20 });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    try t.expect(node.cozmic_measured);
    const box_w = node.measured.w;
    try t.expect(box_w > 0);
    const shaped_by_measure = engine.layout_calls;

    // Make the paint-time replay of the same shape inputs fail (measure
    // already succeeded): an invalid metric only the paint pass sees.
    node.text_style.line_height = 0;

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    // The attrs mismatch (line_height 20 -> 0) must force a paint-side
    // reshape, which is the shape that fails here; the retained layout was
    // never reused with stale metrics.
    try t.expectEqual(shaped_by_measure + 1, engine.layout_calls);
    try t.expectEqual(@as(usize, 0), scene.glyphSlice().len);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expectEqual(@as(u64, 1), node.cozmic_paint_failures);
    try t.expectEqual(@as(u64, 1), frame.cozmic_paint_failures);
    try t.expectEqual(@as(u64, 0), frame.cozmic_painted_glyphs);
    try t.expectApproxEqAbs(box_w, node.measured.w, 0.001); // box untouched
}

test "strike draws one rule per wrapped line" {
    // Regression: the strike was a single rule at the first run's baseline,
    // so multi-line/wrapped text only had a line on its first line.
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("The quick brown fox jumps over the lazy dog", .{ .size = 14, .strike = true }).w(80);
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 200 });
    const node = &frame.nodes[root.index];
    try t.expect(node.cozmic_measured);

    // Run count from the same engine inputs the painter uses: one strike
    // rule per run, i.e. per wrapped line.
    var reference = try text_engine.shape(engine, node, t.allocator);
    defer reference.deinit();
    var runs = reference.runs();
    var run_count: usize = 0;
    while (runs.next()) |_| run_count += 1;
    try t.expect(run_count > 1);

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);

    // Only strike rules emit quads for a bare text node.
    try t.expectEqual(run_count, scene.slice().len);
    var previous_y = scene.slice()[0].y;
    for (scene.slice()[1..]) |rule| {
        try t.expect(rule.y > previous_y);
        previous_y = rule.y;
    }
}

test "counters track emitted glyphs and per-node values" {
    // Regression: glyphs were counted before the atlas/emission check
    // (spaces counted as placed) and the frame-wide counters were documented
    // as node-local. Emitted counts must equal the scene; laid-out glyphs
    // are emitted or skipped; per-node values sum into the frame aggregates.
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(300).h(100).flex_col()
        .child(element.text("Hi", .{ .size = 16 }))
        .child(element.text("i i", .{ .size = 16 }));
    @import("layout.zig").layout(frame, root, .{ .w = 300, .h = 100 });
    const a_index = frame.nodes[root.index].first_child.?;
    const b_index = frame.nodes[a_index].next_sibling.?;
    const a = &frame.nodes[a_index];
    const b = &frame.nodes[b_index];
    try t.expect(a.cozmic_measured and b.cozmic_measured);

    var ref_a = try text_engine.shape(engine, a, t.allocator);
    defer ref_a.deinit();
    var ref_b = try text_engine.shape(engine, b, t.allocator);
    defer ref_b.deinit();
    const laid_out: u64 = @intCast(ref_a.glyphCount() + ref_b.glyphCount());

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);

    // Only glyphs that reached the scene are "painted".
    try t.expectEqual(@as(u64, @intCast(scene.glyphSlice().len)), frame.cozmic_painted_glyphs);
    try t.expectEqual(laid_out, frame.cozmic_painted_glyphs + frame.cozmic_skipped_glyphs);
    // Per-node values are real (and the frame values are their aggregate).
    try t.expectEqual(frame.cozmic_painted_glyphs, a.cozmic_painted_glyphs + b.cozmic_painted_glyphs);
    try t.expectEqual(frame.cozmic_skipped_glyphs, a.cozmic_skipped_glyphs + b.cozmic_skipped_glyphs);
    try t.expectEqual(laid_out, a.cozmic_painted_glyphs + a.cozmic_skipped_glyphs + b.cozmic_painted_glyphs + b.cozmic_skipped_glyphs);
    // The space in "i i" carries no ink.
    try t.expect(b.cozmic_skipped_glyphs >= 1);
    // Frame extent is the max over nodes, not the last or the sum.
    try t.expectApproxEqAbs(
        @max(a.cozmic_painted_extent, b.cozmic_painted_extent),
        frame.cozmic_painted_extent,
        0.001,
    );

    // Double paint on the same frame (no reset in between): the aggregates
    // describe the latest paint only and still equal the node sums, so a
    // second paint can never double-count.
    const first_glyphs = frame.cozmic_painted_glyphs;
    const first_skipped = frame.cozmic_skipped_glyphs;
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(first_glyphs, frame.cozmic_painted_glyphs);
    try t.expectEqual(first_skipped, frame.cozmic_skipped_glyphs);
    try t.expectEqual(frame.cozmic_painted_glyphs, a.cozmic_painted_glyphs + b.cozmic_painted_glyphs);
    try t.expectEqual(frame.cozmic_skipped_glyphs, a.cozmic_skipped_glyphs + b.cozmic_skipped_glyphs);
    try t.expectEqual(@as(u64, @intCast(scene.glyphSlice().len)), frame.cozmic_painted_glyphs);
    try t.expectApproxEqAbs(
        @max(a.cozmic_painted_extent, b.cozmic_painted_extent),
        frame.cozmic_painted_extent,
        0.001,
    );
}

test "engine lost between measure and paint counts the mismatch" {
    // Regression: `paintText` returned silently when the node was
    // cozmic-measured but no engine was installed at paint time: no ink, no
    // counter, and a repaint would have placed wrong metrics. The mismatch
    // must be observable on the node and frame, and the node counters must
    // reset instead of keeping the first paint's values.
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("Hi", .{ .size = 16, .line_height = 20 });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    try t.expect(node.cozmic_measured);
    const box_w = node.measured.w;
    try t.expect(box_w > 0);

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expect(node.cozmic_painted_glyphs > 0);
    try t.expectEqual(frame.cozmic_painted_glyphs, node.cozmic_painted_glyphs);

    // Engine cleared between measure and paint: the cozmic box stays, no ink
    // may land in it, and the mismatch is counted once.
    frame.engine = null;
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(@as(usize, 0), scene.glyphSlice().len);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expectEqual(@as(u64, 1), node.cozmic_paint_failures);
    try t.expectEqual(@as(u64, 1), frame.cozmic_paint_failures);
    try t.expectEqual(frame.cozmic_paint_failures, node.cozmic_paint_failures);
    // Node counters were reset by the second paint, not left stale.
    try t.expectEqual(@as(u64, 0), node.cozmic_painted_glyphs);
    try t.expectEqual(@as(u64, 0), node.cozmic_skipped_glyphs);
    try t.expectEqual(@as(f32, 0), node.cozmic_painted_extent);
    try t.expectEqual(@as(u64, 0), frame.cozmic_painted_glyphs);
    try t.expectEqual(@as(u64, 0), frame.cozmic_skipped_glyphs);
    try t.expectEqual(@as(f32, 0), frame.cozmic_painted_extent);
    try t.expectApproxEqAbs(box_w, node.measured.w, 0.001);
}

test "real bold face skips synthetic embolden" {
    // Regression: the painter always applied the 1px synthetic embolden, so
    // when cozmic matched a 600/700 face the ink was bolded twice and the
    // atlas key disagreed with the cached pixels. The decision keys off the
    // matched face's own weight.
    const t = @import("std").testing;
    // Host-dependent: the vendored corpus only ships 400/500 faces, where
    // synthetic embolden is the correct approximation. Find a real bold face
    // on the host; skip when there is none.
    const engine = engine_mod.Engine.initSystem(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    var bold_family: ?[]const u8 = null;
    for (engine.fs.db.faces.items) |fi| {
        if (fi.weight < 700 or fi.families.len == 0) continue;
        bold_family = fi.families[0];
        break;
    }
    const family = bold_family orelse return error.SkipZigTest;

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.text("Hi", .{ .font = family, .size = 16, .line_height = 20, .weight = .bold });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    if (!node.cozmic_measured) return error.SkipZigTest;

    // The shaped face must really be >= 700, or synthetic embolden is the
    // right behavior and the test could not observe the fix.
    var reference = try text_engine.shape(engine, node, t.allocator);
    defer reference.deinit();
    var shaped_phys: ?cozmic.layout.PhysicalGlyph = null;
    const shaped = blk: {
        var runs = reference.runs();
        while (runs.next()) |run| {
            for (run.glyphs) |g| if (g.glyph_id != 0) {
                shaped_phys = g.physical(0, run.line_y, 1.0);
                break :blk g;
            };
        }
        return error.SkipZigTest;
    };
    const info = engine.fs.db.face(shaped.font_id) orelse return error.SkipZigTest;
    if (info.weight < 700) return error.SkipZigTest;

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expect(scene.glyphSlice().len > 0);

    // The atlas entry is the un-emboldened variant: the painter's own key
    // (full raster key + synthetic_bold) exists with dilation off, and no
    // dilated twin was written for that ink.
    const key = atlasKeyFor(engine, .bold, shaped_phys.?);
    try t.expect(!key.synthetic_bold);
    try t.expect(engine.glyphs.get(key) != null);
    var dilated = key;
    dilated.synthetic_bold = true;
    try t.expect(engine.glyphs.get(dilated) == null);
}

test "atlas keys mirror the full cozmic cache key" {
    // Regression: the painter used to key on (face, glyph, size, bold), so
    // weight/flags/bin variants of one glyph aliased each other.
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const base = cozmic.glyph_cache.CacheKey{
        .font_id = 0,
        .glyph_id = 65,
        .font_size_bits = @bitCast(@as(f32, 16)),
        .x_bin = .zero,
        .y_bin = .zero,
        .font_weight = 400,
        .flags = .{},
    };
    const physical = cozmic.layout.PhysicalGlyph{ .cache_key = base, .x = 0, .y = 0 };
    const key = atlasKeyFor(engine, .normal, physical);
    try t.expectEqual(base.font_id, key.face_id);
    try t.expectEqual(@as(u32, base.glyph_id), key.glyph_id);
    try t.expectEqual(@as(u16, 16), key.size_px);
    try t.expectEqual(base.font_weight, key.font_weight);
    try t.expect(key.synthetic_bold == false); // 400 never dilates

    var bin = base;
    bin.x_bin = .two;
    bin.y_bin = .one;
    const bin_key = atlasKeyFor(engine, .normal, .{ .cache_key = bin, .x = 0, .y = 0 });
    try t.expect(!engine_mod.AtlasKey.eql(key, bin_key));

    var heavy = base;
    heavy.font_weight = 700;
    const heavy_key = atlasKeyFor(engine, .normal, .{ .cache_key = heavy, .x = 0, .y = 0 });
    try t.expect(!engine_mod.AtlasKey.eql(key, heavy_key));

    var italic = base;
    italic.flags = .fake_italic;
    const italic_key = atlasKeyFor(engine, .normal, .{ .cache_key = italic, .x = 0, .y = 0 });
    try t.expect(!engine_mod.AtlasKey.eql(key, italic_key));

    // Requesting bold mirrors the axis-aware decision into the key flag.
    const bold_key = atlasKeyFor(engine, .bold, physical);
    try t.expectEqual(engine.needsSyntheticBold(base.font_id, 700), bold_key.synthetic_bold);
}

test "paint reshapes when the wrap width changed since measure" {
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();

    // Measured unbounded (one line) with a per-run strike rule.
    const root = element.text("The quick brown fox jumps over the lazy dog, and then the dog jumps back.", .{ .size = 14, .line_height = 20, .strike = true });
    @import("layout.zig").layout(frame, root, .{ .w = 500, .h = 300 });
    const node = &frame.nodes[root.index];
    try t.expect(node.cozmic_measured);
    try t.expect(node.cozmic_layout != null);
    const shaped_by_measure = engine.layout_calls;

    // Wrap width changes between measure and paint: a reused unbounded layout
    // would paint one stale line. Paint must reshape at the new width.
    node.style.width = 80;
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    paint(frame, root, scene);
    try t.expectEqual(shaped_by_measure + 1, engine.layout_calls);
    try t.expectEqual(@as(u64, 0), frame.cozmic_paint_failures);
    try t.expect(scene.slice().len > 1); // one rule per wrapped run
}

test "retained layout is invalidated by reset and re-measure" {
    const t = @import("std").testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();

    const root = element.div().w(300).h(100).flex_col()
        .child(element.text("first", .{ .size = 14 }))
        .child(element.text("second", .{ .size = 14 }));
    @import("layout.zig").layout(frame, root, .{ .w = 300, .h = 100 });
    const first_index = frame.nodes[root.index].first_child.?;
    try t.expect(frame.nodes[first_index].cozmic_layout != null);
    const shaped_first = engine.layout_calls;

    // A new frame drops (and frees) the previous handoff: the testing
    // allocator would flag the entry at test end if reset leaked it.
    frame.reset(@ptrFromInt(1), .{});
    try t.expect(frame.nodes[first_index].cozmic_layout == null);

    // Rebuilding into the reused slot measures fresh text through a fresh
    // handoff.
    frame.engine = engine;
    frame.allocator = t.allocator;
    const root2 = element.div().w(300).h(100).flex_col()
        .child(element.text("third", .{ .size = 14 }));
    @import("layout.zig").layout(frame, root2, .{ .w = 300, .h = 100 });
    try t.expectEqual(shaped_first + 1, engine.layout_calls);
    const third_index = frame.nodes[root2.index].first_child.?;
    try t.expect(frame.nodes[third_index].cozmic_layout != null);

    // Re-measuring the same node replaces and frees the previous entry.
    @import("layout.zig").layout(frame, root2, .{ .w = 300, .h = 100 });
    try t.expectEqual(shaped_first + 2, engine.layout_calls);
    try t.expect(frame.nodes[third_index].cozmic_layout != null);
}

/// Corpus engine, skipping only when the host lacks the runtime libraries
/// cozmic loads via `dlopen` (or the vendored corpus is absent).
fn testEngine() !*engine_mod.Engine {
    return engine_mod.Engine.init(std.testing.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable => return error.SkipZigTest,
        else => return err,
    };
}
