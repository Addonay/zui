const std = @import("std");
const core = @import("../core/root.zig");
const gpu = @import("../gpu/root.zig");
const fonts = @import("../fonts/root.zig");
const images = @import("../images/root.zig");
const element = @import("element.zig");

pub fn paint(frame: *element.Frame, root: element.Element, scene: *gpu.Scene) void {
    paintNode(frame, root.index, scene, core.Color.white, .{
        .x = -1e9,
        .y = -1e9,
        .w = 2e9,
        .h = 2e9,
    });
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

fn mix(a: core.Color, b: core.Color, t: f32) core.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

fn clippedEquals(bounds: core.Rect, clipped: core.Rect) bool {
    return @abs(bounds.x - clipped.x) < 0.001 and @abs(bounds.y - clipped.y) < 0.001 and
        @abs(bounds.w - clipped.w) < 0.001 and @abs(bounds.h - clipped.h) < 0.001;
}

fn gradientQuad(scene: *gpu.Scene, bounds: core.Rect, from: core.Color, to: core.Color, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0) return;
    if (from.a <= 0 and to.a <= 0) return;
    const visible = intersect(bounds, clip);
    if (visible.w <= 0 or visible.h <= 0) return;
    // A rect clip can't preserve rounded corners once it cuts, so only keep
    // the radius when nothing was cut (the common case: parents fit).
    const kept_radius = if (clippedEquals(bounds, visible)) radius else 0;
    // Keep the gradient mapped to the original span so a clipped slice shows
    // the same colors as the unclipped button would at those pixels.
    const t0 = (visible.x - bounds.x) / bounds.w;
    const t1 = (visible.x + visible.w - bounds.x) / bounds.w;
    _ = scene.push(.{ .x = visible.x, .y = visible.y, .w = visible.w, .h = visible.h, .color = mix(from, to, t0), .gradient_to = mix(from, to, t1), .radius = kept_radius });
}

fn quad(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0 or color.a <= 0) return;
    const visible = intersect(bounds, clip);
    if (visible.w <= 0 or visible.h <= 0) return;
    const kept_radius = if (clippedEquals(bounds, visible)) radius else 0;
    _ = scene.push(.{ .x = visible.x, .y = visible.y, .w = visible.w, .h = visible.h, .color = color, .radius = kept_radius });
}

/// Border ring: one quad that honors `radius` exactly. The old 4-strip
/// emulation drew square corners, which poked past rounded backgrounds and
/// left background-colored notches (seen on the circular checkbox).
fn ring(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, width: f32, radius: f32, clip: core.Rect) void {
    if (bounds.w <= 0 or bounds.h <= 0 or color.a <= 0 or width <= 0) return;
    const visible = intersect(bounds, clip);
    if (visible.w <= 0 or visible.h <= 0) return;
    const kept_radius = if (clippedEquals(bounds, visible)) radius else 0;
    _ = scene.push(.{ .x = visible.x, .y = visible.y, .w = visible.w, .h = visible.h, .color = color, .radius = kept_radius, .border_width = width });
}

fn paintNode(frame: *element.Frame, index: u16, scene: *gpu.Scene, inherited_color: core.Color, clip: core.Rect) void {
    const node = &frame.nodes[index];
    const hovered = node.bounds.contains(frame.pointer);
    const style = node.style;

    if (style.shadow) {
        // Two-layer shadow: wide faint halo + tight contact layer. Reads as
        // soft elevation instead of a hard offset slab.
        const outer = core.Rect{ .x = node.bounds.x - 6, .y = node.bounds.y + 4, .w = node.bounds.w + 12, .h = node.bounds.h + 12 };
        quad(scene, outer, alpha(core.Color.rgba(0, 0, 0, 0.14), style.opacity), style.radius + 6, clip);
        const inner = core.Rect{ .x = node.bounds.x - 2, .y = node.bounds.y + 2, .w = node.bounds.w + 4, .h = node.bounds.h + 4 };
        quad(scene, inner, alpha(core.Color.rgba(0, 0, 0, 0.16), style.opacity), style.radius + 2, clip);
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
            const layer_alpha = style.opacity * (0.013 + 0.013 * t);
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
            gradientQuad(scene, node.bounds, alpha(from, style.opacity), alpha(to, style.opacity), style.radius, clip);
        } else {
            quad(scene, node.bounds, alpha(from, style.opacity), style.radius, clip);
        }
    }

    if (style.border_width > 0) {
        const border = if (hovered) style.hover_border orelse style.border_color else style.border_color;
        if (border) |border_color| paintBorder(scene, node.bounds, alpha(border_color, style.opacity), style.border_width, style.dashed_border, style.border_bottom_only, style.radius, clip);
    }

    const text_color = node.text_style.color orelse style.text_color orelse inherited_color;
    if (node.kind == .text) paintText(frame, scene, node, text_color, clip);
    if (node.kind == .image) paintImage(frame, scene, node, clip);

    if (node.listener != null or node.mouse_down_listener != null or node.double_click_listener != null or node.focus != null) {
        frame.addRegion(.{ .bounds = node.bounds, .listener = node.listener, .mouse_down_listener = node.mouse_down_listener, .double_click_listener = node.double_click_listener, .focus = node.focus });
    }

    var child = node.first_child;
    // Children clip to this node's content box: overflowing text (long
    // titles, the composer placeholder) gets cut at the field edge instead
    // of bleeding into neighbors. Shadows/glow above intentionally use the
    // looser incoming clip so they can bleed outward.
    const child_clip = intersect(clip, contentBox(node));
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
        paintNode(frame, child_index, scene, style.text_color orelse inherited_color, child_clip);
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
/// image (logs at the cache) when sources fail, the cache is full, or no
/// cache/allocator is attached — same policy as quad overflow.
fn paintImage(frame: *element.Frame, scene: *gpu.Scene, node: *const element.Node, clip: core.Rect) void {
    const desc = node.image;
    const bw = node.bounds.w;
    const bh = node.bounds.h;
    if (bw <= 0 or bh <= 0) return;
    const cache = frame.images orelse return;
    const alloc = frame.allocator orelse return;

    const handle: images.Handle = switch (desc.source) {
        .handle => |h| h,
        .bytes => |bytes| resolveBytes(cache, alloc, bytes, desc, bw, bh, frame.frame_id) orelse return,
        .path => |path| readPathBytes(cache, alloc, path, desc, bw, bh, frame.frame_id) orelse return,
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
    tint.a *= node.style.opacity;
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

fn paintText(frame: *element.Frame, scene: *gpu.Scene, node: *const element.Node, color: core.Color, clip: core.Rect) void { // Shaped path when the font stack is present, bitmap fallback without
    // system fonts (headless CI) or if sizing fails mid-frame.
    if (frame.fonts) |fc| {
        paintShaped(fc, scene, node, color, clip);
    } else {
        paintBitmapText(scene, node, color, clip);
    }
}

/// Shape, cache, and emit atlas glyphs. Placement uses the shaped advances
/// verbatim — the same numbers `Collection.measureText` returns, so
/// measurement matches output by construction.
fn paintShaped(fc: *fonts.Collection, scene: *gpu.Scene, node: *const element.Node, color: core.Color, clip: core.Rect) void {
    const px = fonts.sizeToPx(node.text_style.size);
    const shaper = fc.shaperFor(node.text_style.font);
    shaper.setPixelSize(px) catch return;
    const face = fc.faceFor(node.text_style.font);
    if (fc.symbols) |*sym| sym.setPixelSize(px) catch {};
    const run = shaper.shape(node.text_value);

    const lm = face.lineMetrics();
    const line_h = node.text_style.line_height orelse node.text_style.size * 1.25;
    const baseline = node.bounds.y + @max(0, (node.bounds.h - line_h) / 2) + lm.ascender_px;

    var pen = node.bounds.x;
    // Semibold/bold have no separate faces loaded; embolden the cached ink
    // instead (1px dilation, metrics untouched so measure still matches).
    const bold = node.text_style.weight == .semibold or node.text_style.weight == .bold;
    for (run.glyphs) |g| {
        // Tofu substitution: a shaped `.notdef` (gid 0) is re-resolved in
        // the symbol face by source codepoint. Fallback advance comes from
        // the raster (documented deviation, symbols only).
        var use_face = face;
        var use_gid = g.glyph_id;
        var use_adv = g.advance_px;
        if (use_gid == 0) {
            if (clusterCodepoint(node.text_value, g.cluster)) |cp| {
                if (fc.symbols) |*sym| {
                    if (sym.glyphIndex(cp) != 0) {
                        use_face = sym;
                        use_gid = sym.glyphIndex(cp);
                        use_adv = 0; // filled from the raster below
                    }
                }
            }
        }
        const key = fonts.atlas.AtlasKey{ .face_id = use_face.id, .glyph_id = use_gid, .size_px = @intCast(px), .bold = bold };
        const entry = fc.glyphs.get(key) orelse blk: {
            const raster = use_face.rasterizeGlyphId(use_gid) catch {
                pen += if (use_adv > 0) use_adv else g.advance_px;
                continue;
            };
            break :blk fc.glyphs.put(key, &raster, bold) catch {
                pen += if (use_adv > 0) use_adv else g.advance_px;
                continue;
            };
        };
        if (use_adv == 0) use_adv = entry.advance_px;
        if (entry.width > 0 and entry.height > 0) {
            _ = scene.pushGlyph(.{
                .x = pen + g.offset_px[0] + @as(f32, @floatFromInt(entry.bearing_x)),
                .y = baseline - @as(f32, @floatFromInt(entry.bearing_y)) + g.offset_px[1],
                .w = entry.width,
                .h = entry.height,
                .color = color,
                .atlas_offset = entry.offset,
                .clip = clip,
            });
        }
        pen += use_adv;
    }
    if (node.text_style.strike) {
        const thickness = @max(1.0, @as(f32, @floatFromInt(px)) / 14.0);
        quad(scene, .{ .x = node.bounds.x, .y = node.bounds.y + node.bounds.h / 2, .w = node.bounds.w, .h = thickness }, color, 0, clip);
    }
}

fn paintBitmapText(scene: *gpu.Scene, node: *const element.Node, color: core.Color, clip: core.Rect) void {
    // NOTE: bitmap fallback renderer for machines without system fonts.
    // Glyphs come from the 5x7 table below (ASCII + a hand-drawn symbol set
    // for chrome icons).
    const scale = @max(1.0, node.text_style.size / 8.0);
    const advance = element.textAdvance(node.text_style.size, node.text_style.tracking, node.text_style.weight);
    var x = node.bounds.x;
    const y = node.bounds.y + @max(0, (node.bounds.h - scale * 7) / 2);
    var index: usize = 0;
    while (index < node.text_value.len) {
        const first = node.text_value[index];
        var codepoint: u21 = first;
        var len: usize = 1;
        if (first >= 0x80) {
            const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
                index += 1;
                continue;
            };
            if (index + seq_len > node.text_value.len) break;
            codepoint = std.unicode.utf8Decode(node.text_value[index..][0..seq_len]) catch {
                index += 1;
                continue;
            };
            len = seq_len;
        }
        index += len;
        const rows = glyphFor(codepoint);
        drawRows(scene, x, y, scale, rows, color, node.text_style.weight, clip);
        x += advance;
    }
    if (node.text_style.strike) {
        quad(scene, .{ .x = node.bounds.x, .y = node.bounds.y + node.bounds.h / 2, .w = node.bounds.w, .h = @max(1, scale * 0.65) }, color, 0, clip);
    }
}

/// Decode the codepoint at a shaping cluster (byte index). Null on
/// truncation or invalid bytes; used for symbol-fallback resolution.
fn clusterCodepoint(text: []const u8, cluster: u32) ?u21 {
    if (cluster >= text.len) return null;
    const first = text[cluster];
    if (first < 0x80) return first;
    const len = std.unicode.utf8ByteSequenceLength(first) catch return null;
    if (cluster + len > text.len) return null;
    return std.unicode.utf8Decode(text[cluster..][0..len]) catch null;
}

fn glyphFor(codepoint: u21) [7]u5 {
    // ASCII renders as-is: lowercase has its own x-height forms below.
    // (The old build folded a-z to A-Z, which is why the whole app shouted.)
    if (codepoint < 0x80) {
        const byte: u8 = @intCast(codepoint);
        return glyph(byte);
    }
    return switch (codepoint) {
        0x2713 => .{ 0, 0, 0b00001, 0b00010, 0b10100, 0b01000, 0 }, // ✓ check
        0x00D7 => .{ 0, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0 }, // × close
        0x2014 => .{ 0, 0, 0, 0b11111, 0, 0, 0 }, // — em dash (minimize)
        0x25A1 => .{ 0b11111, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11111 }, // □ maximize
        0x25A2 => .{ 0b11111, 0b11111, 0b11011, 0b11011, 0b11011, 0b11111, 0b11111 }, // ▢ restore
        0x25CB => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // ○ empty state
        0x2726 => .{ 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0, 0 }, // ✦ sparkle
        0x00B7 => .{ 0, 0, 0, 0b00100, 0, 0, 0 }, // · middle dot
        else => .{ 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0, 0 }, // fallback star
    };
}

fn drawRows(scene: *gpu.Scene, x: f32, y: f32, scale: f32, rows: [7]u5, color: core.Color, weight: element.FontWeight, clip: core.Rect) void {
    const bold = weight == .bold or weight == .semibold;
    for (rows, 0..) |bits, row| {
        for (0..5) |column| {
            const shift: u3 = @intCast(4 - column);
            if (((bits >> shift) & 1) == 0) continue;
            const width = scale + if (bold) @min(1.0, scale * 0.3) else 0;
            quad(scene, .{ .x = x + @as(f32, @floatFromInt(column)) * scale, .y = y + @as(f32, @floatFromInt(row)) * scale, .w = width, .h = scale }, color, 0, clip);
        }
    }
}

fn glyph(ch: u8) [7]u5 {
    return switch (ch) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        'a' => .{ 0, 0, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 },
        'b' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110 },
        'c' => .{ 0, 0, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110 },
        'd' => .{ 0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111 },
        'e' => .{ 0, 0, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110 },
        'f' => .{ 0b00110, 0b00100, 0b00100, 0b11110, 0b00100, 0b00100, 0b00100 },
        'g' => .{ 0, 0, 0b01110, 0b10001, 0b01111, 0b00001, 0b01110 },
        'h' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'i' => .{ 0b00100, 0, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'j' => .{ 0b00010, 0, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 },
        'k' => .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 },
        'l' => .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'm' => .{ 0, 0, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001 },
        'n' => .{ 0, 0, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'o' => .{ 0, 0, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 },
        'p' => .{ 0, 0, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 },
        'q' => .{ 0, 0, 0b01111, 0b10001, 0b01111, 0b00001, 0b00001 },
        'r' => .{ 0, 0, 0b10111, 0b11000, 0b10000, 0b10000, 0b10000 },
        's' => .{ 0, 0, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 },
        't' => .{ 0b00100, 0b00100, 0b11110, 0b00100, 0b00100, 0b00101, 0b00010 },
        'u' => .{ 0, 0, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 },
        'v' => .{ 0, 0, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'w' => .{ 0, 0, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010 },
        'x' => .{ 0, 0, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 },
        'y' => .{ 0, 0, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 },
        'z' => .{ 0, 0, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        '+' => .{ 0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0 },
        '-' => .{ 0, 0, 0, 0b11111, 0, 0, 0 },
        '#' => .{ 0b01010, 0b11111, 0b01010, 0b01010, 0b11111, 0b01010, 0 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        ':' => .{ 0, 0b00100, 0b00100, 0, 0b00100, 0b00100, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 0b00110, 0b00110 },
        ',' => .{ 0, 0, 0, 0, 0b00110, 0b00100, 0b01000 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0, 0b00100 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '*' => .{ 0, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 0b11111, 0b10001, 0b00110, 0b00110, 0, 0b00100, 0 },
    };
}

test "lowercase glyphs differ from uppercase" {
    const t = @import("std").testing;
    // Regression: the old painter folded a-z to A-Z so the app shouted.
    try t.expect(!std.mem.eql(u5, &glyphFor('a'), &glyphFor('A')));
    try t.expect(!std.mem.eql(u5, &glyphFor('e'), &glyphFor('E')));
    // Lowercase sits on the x-height: top row empty, body in lower rows.
    try t.expectEqual(@as(u5, 0), glyphFor('a')[0]);
    try t.expectEqual(@as(u5, 0), glyphFor('e')[0]);
    try t.expect(glyphFor('A')[0] != 0);
}

test "gradient background emits a single quad" {
    const t = @import("std").testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.div().w(100).h(20).bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8));
    @import("layout.zig").layout(&frame, root, .{ .w = 100, .h = 20 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);
    try t.expectEqual(@as(usize, 1), scene.slice().len);
    try t.expect(scene.slice()[0].gradient_to != null);
    try t.expectEqual(@as(f32, 100), scene.slice()[0].w);
}

test "overflowing text clips to parent content box" {
    const t = @import("std").testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.div().w(60).h(30).bg(core.Color.hex(0x1e1f2a))
        .child(element.text("aaaaaaaaaaaaaaaaaaaa", .{ .size = 14 }));
    @import("layout.zig").layout(&frame, root, .{ .w = 200, .h = 100 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);
    try t.expect(scene.slice().len > 1); // bg + (clipped) glyph pixels
    for (scene.slice()) |q| {
        try t.expect(q.x >= -0.01);
        try t.expect(q.x + q.w <= 60.01);
    }
}

test "blurred background emits soft falloff layers" {
    const t = @import("std").testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.div().w(50).h(50).bg(core.Color.hex(0x7c5cff)).blur(60);
    @import("layout.zig").layout(&frame, root, .{ .w = 50, .h = 50 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);
    // 8 glow layers + 1 background (was a single hard disc before).
    try t.expectEqual(@as(usize, 9), scene.slice().len);
    // Outermost layer is the largest and faintest.
    try t.expect(scene.slice()[0].w > scene.slice()[6].w);
    try t.expect(scene.slice()[0].color.a < scene.slice()[5].color.a);
}

test "shaped text emits atlas glyphs, not bitmap quads" {
    const t = @import("std").testing;
    if (!fonts.tables.FontconfigApi.isAvailable() or !fonts.tables.FreeTypeApi.isAvailable() or !fonts.tables.HarfBuzzApi.isAvailable()) return;
    var stack = try fonts.Collection.init();
    defer stack.deinit();

    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    frame.fonts = &stack;
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.text("Hi", .{ .size = 16 });
    @import("layout.zig").layout(&frame, root, .{ .w = 500, .h = 100 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);

    // Both glyphs have ink; a bare text node emits no quads at all.
    const glyphs = scene.glyphSlice();
    try t.expectEqual(@as(usize, 2), glyphs.len);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expect(glyphs[1].x > glyphs[0].x);
    for (glyphs) |g| {
        try t.expect(g.w > 0 and g.h > 0);
        const bytes = @as(usize, g.w) * g.h;
        try t.expect(g.atlas_offset + bytes <= stack.glyphs.pixels_used);
    }
}

test "tofu codepoint substitutes the symbol face" {
    const t = @import("std").testing;
    if (!fonts.tables.FontconfigApi.isAvailable() or !fonts.tables.FreeTypeApi.isAvailable() or !fonts.tables.HarfBuzzApi.isAvailable()) return;
    var stack = try fonts.Collection.init();
    defer stack.deinit();
    if (stack.symbols == null) return;

    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    frame.fonts = &stack;
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.text("✓", .{ .size = 16 });
    @import("layout.zig").layout(&frame, root, .{ .w = 500, .h = 100 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);

    // The sans face has no U+2713, so the glyph must come from the symbol
    // face (id 3) with real ink — not dropped, not `.notdef`.
    try t.expectEqual(@as(usize, 1), scene.glyphSlice().len);
    const g = scene.glyphSlice()[0];
    try t.expect(g.w > 0 and g.h > 0);
    const bytes = @as(usize, g.w) * g.h;
    var ink: usize = 0;
    for (stack.glyphs.pixels[g.atlas_offset..][0..bytes]) |v| {
        if (v > 0) ink += 1;
    }
    try t.expect(ink > 0);
}

test "rounded border ring leaves no notches" {
    // Repro: the circular checkbox (rounded_full bg + border_2, same color)
    // showed background-colored corner notches because borders drew as
    // square strips past the rounded background.
    const t = @import("std").testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const green = core.Color.hex(0x3DDC84);
    const root = element.div().size(24).rounded_full().bg(green).border_2().border_color(green);
    @import("layout.zig").layout(&frame, root, .{ .w = 100, .h = 100 });
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);
    // One fill + one ring (was 1 fill + 4 strips).
    try t.expectEqual(@as(usize, 2), scene.slice().len);

    var buf: [24 * 24 * 4]u8 = undefined;
    const target = gpu.software.Target.init(&buf, 24, 24, .rgba32);
    target.clear(core.Color.hex(0x000000));
    target.renderScene(&scene, &.{}, &.{});
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
    var frame = element.Frame{};
    testImageFrame(&frame, cache);
    defer element.endFrame();
    const root = element.img(test_png);
    @import("layout.zig").layout(&frame, root, .{ .w = 100, .h = 100 });
    try t.expectEqual(@as(f32, 4), frame.nodes[root.index].measured.w);
    try t.expectEqual(@as(f32, 2), frame.nodes[root.index].measured.h);
    var scene = gpu.Scene{};
    paint(&frame, root, &scene);
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
    target.renderScene(&scene, &.{}, cache.pool[0..cache.used]);
    try t.expectEqual(@as(u8, 255), buf[(25 * 100 + 0) * 4]);
    try t.expectEqual(@as(u8, 255), buf[(74 * 100 + 0) * 4 + 2]);
}

test "img aspect derives the missing axis and cover crops" {
    const t = @import("std").testing;
    var cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    // 4x2 source at h=10 derives w=20.
    {
        var frame = element.Frame{};
        testImageFrame(&frame, cache);
        defer element.endFrame();
        const root = element.img(test_png).h(10);
        @import("layout.zig").layout(&frame, root, .{ .w = 100, .h = 100 });
        try t.expectEqual(@as(f32, 20), frame.nodes[root.index].measured.w);
        try t.expectEqual(@as(f32, 10), frame.nodes[root.index].measured.h);
    }

    // Cover in a square box: full dest, centered horizontal crop.
    var frame2 = element.Frame{};
    testImageFrame(&frame2, cache);
    defer element.endFrame();
    const cover = element.img(test_png).w(10).h(10).object_fit(.cover);
    @import("layout.zig").layout(&frame2, cover, .{ .w = 100, .h = 100 });
    var scene = gpu.Scene{};
    paint(&frame2, cover, &scene);
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
        var frame = element.Frame{};
        testImageFrame(&frame, cache);
        defer element.endFrame();
        const root = element.svg(test_icon).w(24).h(24).tint(core.Color.hex(0xFFFFFF));
        @import("layout.zig").layout(&frame, root, .{ .w = 100, .h = 100 });
        var scene = gpu.Scene{};
        paint(&frame, root, &scene);
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
    var bare = element.Frame{};
    bare.reset(@ptrFromInt(1), .{});
    element.beginFrame(&bare);
    defer element.endFrame();
    const root2 = element.svg(test_icon).w(24).h(24);
    @import("layout.zig").layout(&bare, root2, .{ .w = 100, .h = 100 });
    var scene2 = gpu.Scene{};
    paint(&bare, root2, &scene2);
    try t.expectEqual(@as(usize, 0), scene2.imageSlice().len);
}
