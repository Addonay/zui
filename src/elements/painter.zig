const std = @import("std");
const core = @import("../core/root.zig");
const gpu = @import("../gpu/root.zig");
const element = @import("element.zig");

pub fn paint(frame: *element.Frame, root: element.Element, scene: *gpu.Scene) void {
    paintNode(frame, root.index, scene, core.Color.white);
}

fn alpha(color: core.Color, opacity: f32) core.Color {
    var result = color;
    result.a *= opacity;
    return result;
}

fn mix(a: core.Color, b: core.Color, t: f32) core.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

fn quad(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, radius: f32) void {
    if (bounds.w <= 0 or bounds.h <= 0 or color.a <= 0) return;
    _ = scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = color, .radius = radius });
}

fn paintNode(frame: *element.Frame, index: u16, scene: *gpu.Scene, inherited_color: core.Color) void {
    const node = &frame.nodes[index];
    const hovered = node.bounds.contains(frame.pointer);
    const style = node.style;

    if (style.shadow) {
        const shadow_bounds = core.Rect{ .x = node.bounds.x - 4, .y = node.bounds.y + 8, .w = node.bounds.w + 8, .h = node.bounds.h + 8 };
        quad(scene, shadow_bounds, core.Color.rgba(0, 0, 0, 0.28), style.radius + 4);
    }
    if (style.blur > 0 and style.background != null) {
        const spread = style.blur * 0.22;
        const glow = core.Rect{ .x = node.bounds.x - spread, .y = node.bounds.y - spread, .w = node.bounds.w + spread * 2, .h = node.bounds.h + spread * 2 };
        quad(scene, glow, alpha(style.background.?, style.opacity * 0.18), style.radius + spread);
    }

    const background = if (hovered) style.hover_background orelse style.background else style.background;
    if (background) |from| {
        if (style.gradient_to) |to| {
            const strips: usize = 12;
            for (0..strips) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips - 1));
                const x = node.bounds.x + node.bounds.w * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips));
                const next_x = node.bounds.x + node.bounds.w * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(strips));
                quad(scene, .{ .x = x, .y = node.bounds.y, .w = next_x - x + 0.5, .h = node.bounds.h }, alpha(mix(from, to, t), style.opacity), if (i == 0 or i + 1 == strips) style.radius else 0);
            }
        } else {
            quad(scene, node.bounds, alpha(from, style.opacity), style.radius);
        }
    }

    if (style.border_width > 0) {
        const border = if (hovered) style.hover_border orelse style.border_color else style.border_color;
        if (border) |border_color| paintBorder(scene, node.bounds, alpha(border_color, style.opacity), style.border_width, style.dashed_border, style.border_bottom_only);
    }

    const text_color = node.text_style.color orelse style.text_color orelse inherited_color;
    if (node.kind == .text) paintText(scene, node, text_color);

    if (node.listener != null or node.mouse_down_listener != null or node.double_click_listener != null or node.focus != null) {
        frame.addRegion(.{ .bounds = node.bounds, .listener = node.listener, .mouse_down_listener = node.mouse_down_listener, .double_click_listener = node.double_click_listener, .focus = node.focus });
    }

    var child = node.first_child;
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
        paintNode(frame, child_index, scene, style.text_color orelse inherited_color);
    }
}

fn paintBorder(scene: *gpu.Scene, bounds: core.Rect, color: core.Color, width: f32, dashed: bool, bottom_only: bool) void {
    if (bottom_only) {
        quad(scene, .{ .x = bounds.x, .y = bounds.y + bounds.h - width, .w = bounds.w, .h = width }, color, 0);
        return;
    }
    if (!dashed) {
        quad(scene, .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = width }, color, 0);
        quad(scene, .{ .x = bounds.x, .y = bounds.y + bounds.h - width, .w = bounds.w, .h = width }, color, 0);
        quad(scene, .{ .x = bounds.x, .y = bounds.y, .w = width, .h = bounds.h }, color, 0);
        quad(scene, .{ .x = bounds.x + bounds.w - width, .y = bounds.y, .w = width, .h = bounds.h }, color, 0);
        return;
    }
    const dash: f32 = 6;
    var x = bounds.x;
    while (x < bounds.x + bounds.w) : (x += dash * 2) {
        const w = @min(dash, bounds.x + bounds.w - x);
        quad(scene, .{ .x = x, .y = bounds.y, .w = w, .h = width }, color, 0);
        quad(scene, .{ .x = x, .y = bounds.y + bounds.h - width, .w = w, .h = width }, color, 0);
    }
    var y = bounds.y;
    while (y < bounds.y + bounds.h) : (y += dash * 2) {
        const h = @min(dash, bounds.y + bounds.h - y);
        quad(scene, .{ .x = bounds.x, .y = y, .w = width, .h = h }, color, 0);
        quad(scene, .{ .x = bounds.x + bounds.w - width, .y = y, .w = width, .h = h }, color, 0);
    }
}

fn paintText(scene: *gpu.Scene, node: *const element.Node, color: core.Color) void {
    // NOTE: bitmap fallback renderer. Glyphs come from the 5x7 table below
    // (ASCII + a hand-drawn symbol set for chrome icons); real shaped text
    // via FreeType/HarfBuzz (`src/text/`) replaces this in the text phase.
    const scale = @max(1.0, node.text_style.size / 8.0);
    const advance = scale * 6 + node.text_style.tracking;
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
        drawRows(scene, x, y, scale, rows, color, node.text_style.weight);
        x += advance;
    }
    if (node.text_style.strike) {
        quad(scene, .{ .x = node.bounds.x, .y = node.bounds.y + node.bounds.h / 2, .w = node.bounds.w, .h = @max(1, scale * 0.65) }, color, 0);
    }
}

fn glyphFor(codepoint: u21) [7]u5 {
    // ASCII fast path preserves the old behavior exactly (a-z fold to A-Z).
    if (codepoint < 0x80) {
        var byte: u8 = @intCast(codepoint);
        if (byte >= 'a' and byte <= 'z') byte -= ('a' - 'A');
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

fn drawGlyph(scene: *gpu.Scene, x: f32, y: f32, scale: f32, input: u8, color: core.Color, weight: element.FontWeight) void {
    const ch = if (input >= 'a' and input <= 'z') input - ('a' - 'A') else input;
    drawRows(scene, x, y, scale, glyph(ch), color, weight);
}

fn drawRows(scene: *gpu.Scene, x: f32, y: f32, scale: f32, rows: [7]u5, color: core.Color, weight: element.FontWeight) void {
    const bold = weight == .bold or weight == .semibold;
    for (rows, 0..) |bits, row| {
        for (0..5) |column| {
            const shift: u3 = @intCast(4 - column);
            if (((bits >> shift) & 1) == 0) continue;
            const width = scale + if (bold) @min(1.0, scale * 0.3) else 0;
            quad(scene, .{ .x = x + @as(f32, @floatFromInt(column)) * scale, .y = y + @as(f32, @floatFromInt(row)) * scale, .w = width, .h = scale }, color, 0);
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
