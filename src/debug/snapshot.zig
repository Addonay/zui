//! Renderer-independent scene snapshots and golden comparison.
//!
//! The snapshot follows Scene's paint-order command stream and hashes only
//! initialized payload fields. It therefore works as an offscreen golden
//! oracle without opening a window or depending on a GPU/backend.
const std = @import("std");
const Scene = @import("../gpu/scene.zig").Scene;
const Point = @import("../core/geometry.zig").Point;
const Rect = @import("../core/geometry.zig").Rect;
const Color = @import("../core/color.zig").Color;

/// Exported only to let standalone headless probes construct the same scene
/// type without importing the application/runtime module.
pub const SceneType = Scene;

pub const Snapshot = struct {
    digest: u64,
    commands: usize,
    quads: usize,
    glyphs: usize,
    images: usize,
    strokes: usize,
    paths: usize,
    shadows: usize,
    dropped: u64,

    pub fn matches(self: @This(), expected_digest: u64) bool {
        return self.digest == expected_digest;
    }
};

pub const Error = error{InvalidCommandIndex};

pub fn capture(scene: *const Scene) Error!Snapshot {
    var hash: u64 = 14695981039346656037;
    hashU64(&hash, scene.command_len);
    hashU64(&hash, scene.dropped);
    hashU64(&hash, scene.group_len);
    for (scene.commandSlice()) |command| {
        hashU64(&hash, @backingInt(command.kind));
        hashU64(&hash, command.index);
        switch (command.kind) {
            .begin_group => if (command.index >= scene.group_len) return error.InvalidCommandIndex else hashGroup(&hash, scene.groups[command.index]),
            .end_group => {},
            .quad => if (command.index >= scene.len) return error.InvalidCommandIndex else hashQuad(&hash, scene.quads[command.index]),
            .glyph => if (command.index >= scene.glyph_len) return error.InvalidCommandIndex else hashGlyph(&hash, scene.glyphs[command.index]),
            .blit => if (command.index >= scene.blit_len) return error.InvalidCommandIndex else hashBlit(&hash, scene.blits[command.index]),
            .stroke => if (command.index >= scene.stroke_len) return error.InvalidCommandIndex else hashStroke(&hash, scene.strokes[command.index]),
            .path => if (command.index >= scene.path_len) return error.InvalidCommandIndex else hashPath(&hash, scene.paths[command.index]),
            .shadow => if (command.index >= scene.shadow_len) return error.InvalidCommandIndex else hashShadow(&hash, scene.shadows[command.index]),
        }
    }
    return .{
        .digest = hash,
        .commands = scene.command_len,
        .quads = scene.len,
        .glyphs = scene.glyph_len,
        .images = scene.blit_len,
        .strokes = scene.stroke_len,
        .paths = scene.path_len,
        .shadows = scene.shadow_len,
        .dropped = scene.dropped,
    };
}

fn hashGroup(hash: *u64, value: anytype) void {
    hashF32(hash, value.opacity);
    for (value.transform) |coefficient| hashF32(hash, coefficient);
    if (value.clip) |clip| {
        hashU64(hash, 1);
        switch (clip) {
            .rect => |rect| {
                hashU64(hash, 0);
                hashRect(hash, rect);
            },
            .rounded => |rounded| {
                hashU64(hash, 1);
                hashRect(hash, rounded.rect);
                hashF32(hash, rounded.radius);
            },
            .path => |path| {
                hashU64(hash, 2);
                hashPath(hash, path);
            },
        }
    } else hashU64(hash, 0);
}

fn hashQuad(hash: *u64, value: anytype) void {
    hashRect(hash, .{ .x = value.x, .y = value.y, .w = value.w, .h = value.h });
    hashColor(hash, value.color);
    hashF32(hash, value.radius);
    if (value.gradient_to) |color| {
        hashU64(hash, 1);
        hashColor(hash, color);
    } else hashU64(hash, 0);
    hashF32(hash, value.border_width);
    hashOptionalRect(hash, value.clip);
}

fn hashGlyph(hash: *u64, value: anytype) void {
    hashF32(hash, value.x);
    hashF32(hash, value.y);
    hashU64(hash, value.w);
    hashU64(hash, value.h);
    hashColor(hash, value.color);
    hashU64(hash, value.atlas_offset);
    hashF32(hash, value.density);
    hashRect(hash, value.clip);
}

fn hashBlit(hash: *u64, value: anytype) void {
    hashF32(hash, value.x);
    hashF32(hash, value.y);
    hashF32(hash, value.w);
    hashF32(hash, value.h);
    hashU64(hash, value.pool_offset);
    hashU64(hash, value.src_w);
    hashU64(hash, value.src_h);
    hashF32(hash, value.src_x);
    hashF32(hash, value.src_y);
    hashF32(hash, value.src_crop_w);
    hashF32(hash, value.src_crop_h);
    hashColor(hash, value.tint);
    hashF32(hash, value.rotation);
    hashF32(hash, value.scale_x);
    hashF32(hash, value.scale_y);
    hashF32(hash, value.translate_x);
    hashF32(hash, value.translate_y);
    hashU64(hash, @intFromBool(value.gray));
    hashF32(hash, value.radius);
    hashRect(hash, value.clip);
}

fn hashStroke(hash: *u64, value: anytype) void {
    hashPoint(hash, value.from);
    hashPoint(hash, value.to);
    hashColor(hash, value.color);
    hashF32(hash, value.width);
    hashRect(hash, value.clip);
}

fn hashPath(hash: *u64, value: anytype) void {
    hashU64(hash, value.segment_len);
    hashColor(hash, value.color);
    hashF32(hash, value.stroke_width);
    hashRect(hash, value.clip);
    for (value.segments[0..value.segment_len]) |segment| switch (segment) {
        .move_to => |point| {
            hashU64(hash, 0);
            hashPoint(hash, point);
        },
        .line_to => |point| {
            hashU64(hash, 1);
            hashPoint(hash, point);
        },
        .quad_to => |data| {
            hashU64(hash, 2);
            hashPoint(hash, data.ctrl);
            hashPoint(hash, data.to);
        },
        .cubic_to => |data| {
            hashU64(hash, 3);
            hashPoint(hash, data.ctrl1);
            hashPoint(hash, data.ctrl2);
            hashPoint(hash, data.to);
        },
        .close => hashU64(hash, 4),
    };
    for (value.transform) |coefficient| hashF32(hash, coefficient);
}

fn hashShadow(hash: *u64, value: anytype) void {
    hashRect(hash, value.bounds);
    hashF32(hash, value.radius);
    hashF32(hash, value.offset_x);
    hashF32(hash, value.offset_y);
    hashF32(hash, value.spread);
    hashF32(hash, value.blur_radius);
    hashColor(hash, value.color);
    hashU64(hash, @intFromBool(value.inset));
    hashOptionalRect(hash, value.clip);
}

fn hashPoint(hash: *u64, value: Point) void {
    hashF32(hash, value.x);
    hashF32(hash, value.y);
}
fn hashRect(hash: *u64, value: Rect) void {
    hashF32(hash, value.x);
    hashF32(hash, value.y);
    hashF32(hash, value.w);
    hashF32(hash, value.h);
}
fn hashOptionalRect(hash: *u64, value: ?Rect) void {
    if (value) |rect| {
        hashU64(hash, 1);
        hashRect(hash, rect);
    } else hashU64(hash, 0);
}
fn hashColor(hash: *u64, value: Color) void {
    hashF32(hash, value.r);
    hashF32(hash, value.g);
    hashF32(hash, value.b);
    hashF32(hash, value.a);
}
fn hashF32(hash: *u64, value: f32) void {
    hashU64(hash, @as(u32, @bitCast(value)));
}
fn hashU64(hash: *u64, value: anytype) void {
    var v: u64 = @intCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        hash.* ^= v & 0xff;
        hash.* *%= 1099511628211;
        v >>= 8;
    }
}

test "offscreen scene snapshot is stable and catches a visual regression" {
    const scene_mod = @import("../gpu/scene.zig");
    var scene = scene_mod.Scene{};
    try std.testing.expect(scene.push(.{ .x = 2, .y = 3, .w = 40, .h = 20, .color = .white, .radius = 4 }));
    const first = try capture(&scene);
    const golden = first.digest;
    try std.testing.expect(first.matches(golden));
    scene.quads[0].radius = 5;
    const changed = try capture(&scene);
    try std.testing.expect(!changed.matches(golden));
}

test "scene snapshot rejects malformed paint order" {
    const scene_mod = @import("../gpu/scene.zig");
    var scene = scene_mod.Scene{};
    scene.commands[0] = .{ .kind = .quad, .index = 9 };
    scene.command_len = 1;
    try std.testing.expectError(error.InvalidCommandIndex, capture(&scene));
}
