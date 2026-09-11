//! Parser for the shared scene corpus format (version 1).
//!
//! The same files under `tests/scenes/` drive the upstream Rust oracle
//! (`tools/oracle-rs`) and vellz, so scene construction cannot drift between
//! the two implementations. See `tools/oracle-rs/README.md` for the schema.
//!
//! Ownership: `parse` copies everything it needs into an arena that the caller
//! provides via `Parsed`. The returned slices point into that arena and are
//! valid until `deinit`.

const std = @import("std");

pub const Affine = [6]f64;

pub const Settings = struct {
    /// "quality" (f32 pipeline) or "speed" (u8 pipeline).
    mode: enum { quality, speed } = .quality,
    /// Additional renderer threads.
    threads: u16 = 0,
    /// "fallback" or "native" SIMD level.
    level: enum { fallback, native } = .fallback,
};

pub const TargetInit = enum { clear, src_over };

pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

pub const Extend = enum { pad, repeat, reflect };
pub const ImageQuality = enum { low, medium, high };
pub const ImageFormat = enum { rgba8, bgra8 };
pub const ImageAlphaType = enum { alpha, premultiplied };
pub const MaskKind = enum { alpha, luminance };

/// peniko's `Mix` compositing functions.
pub const Mix = enum {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,
};

/// peniko's `Compose` layer composition functions.
pub const Compose = enum {
    clear,
    copy,
    dest,
    src_over,
    dest_over,
    src_in,
    dest_in,
    src_out,
    dest_out,
    src_atop,
    dest_atop,
    xor,
    plus,
    plus_lighter,
};

pub const BlendSpec = struct {
    mix: Mix,
    compose: Compose,
};

pub const ColorStop = struct {
    offset: f64,
    rgba8: [4]u8,
};

/// One variant of [`GradientSpec`]; exactly one key is present in the JSON.
pub const GradientKind = union(enum) {
    linear: struct {
        start: [2]f64,
        end: [2]f64,
    },
    radial: struct {
        start_center: [2]f64,
        start_radius: f64,
        end_center: [2]f64,
        end_radius: f64,
    },
    sweep: struct {
        center: [2]f64,
        start_angle: f64,
        end_angle: f64,
    },
};

pub const GradientSpec = struct {
    kind: GradientKind,
    stops: []const ColorStop,
    extend: Extend,
};

pub const ImageSamplerSpec = struct {
    x_extend: Extend,
    y_extend: Extend,
    quality: ImageQuality,
    alpha: f64,
};

pub const ImageSpec = struct {
    /// Asset path relative to the scene file's directory; arena-owned.
    asset: []const u8,
    width: u16,
    height: u16,
    format: ImageFormat,
    alpha_type: ImageAlphaType,
    sampler: ImageSamplerSpec,
};

pub const MaskSpec = struct {
    /// Asset path relative to the scene file's directory; arena-owned.
    asset: []const u8,
    width: u16,
    height: u16,
    format: ImageFormat,
    alpha_type: ImageAlphaType,
    kind: MaskKind,
};

pub const PaintSpec = union(enum) {
    solid: [4]u8,
    gradient: GradientSpec,
    image: ImageSpec,
};

pub const LayerSpec = union(enum) {
    clip: []const u8,
    blend: BlendSpec,
    opacity: f64,
    mask: MaskSpec,
};

pub const StrokeSpec = struct {
    width: f64,
    join: ?Join = null,
    start_cap: ?Cap = null,
    end_cap: ?Cap = null,
    miter_limit: ?f64 = null,
    dash: ?[]const f64 = null,
    dash_offset: f64 = 0,
};

pub const Command = union(enum) {
    set_transform: Affine,
    reset_transform,
    set_paint_transform: Affine,
    reset_paint_transform,
    set_paint: PaintSpec,
    set_fill_rule: enum { nonzero, evenodd },
    set_stroke: StrokeSpec,
    set_aliasing_threshold: ?u8,
    fill_rect: [4]f64,
    stroke_rect: [4]f64,
    fill_path: []const u8,
    stroke_path: []const u8,
    push_clip_path: []const u8,
    pop_clip_path,
    push_clip_layer: []const u8,
    push_layer: LayerSpec,
    pop_layer,
    reset,
};

pub const Scene = struct {
    version: u32 = 1,
    width: u16,
    height: u16,
    settings: Settings = .{},
    target_init: TargetInit = .clear,
    commands: []const Command,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    scene: Scene,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{InvalidScene} || std.mem.Allocator.Error;

/// Parses scene JSON. The result owns an arena; call `deinit` when done.
pub fn parse(backing: std.mem.Allocator, text: []const u8) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch {
        return error.InvalidScene;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidScene,
    };

    var scene: Scene = .{
        .width = try u16Field(obj, "width"),
        .height = try u16Field(obj, "height"),
        .commands = &.{},
    };

    if (obj.get("version")) |v| {
        scene.version = switch (v) {
            .integer => |i| std.math.cast(u32, i) orelse return error.InvalidScene,
            else => return error.InvalidScene,
        };
    }
    if (scene.version != 1) return error.InvalidScene;

    if (obj.get("settings")) |settings_value| {
        const settings_obj = switch (settings_value) {
            .object => |o| o,
            else => return error.InvalidScene,
        };
        if (settings_obj.get("mode")) |mode| {
            const s = stringOf(mode) orelse return error.InvalidScene;
            scene.settings.mode = if (std.mem.eql(u8, s, "quality"))
                .quality
            else if (std.mem.eql(u8, s, "speed"))
                .speed
            else
                return error.InvalidScene;
        }
        if (settings_obj.get("threads")) |threads| {
            scene.settings.threads = switch (threads) {
                .integer => |i| std.math.cast(u16, i) orelse return error.InvalidScene,
                else => return error.InvalidScene,
            };
        }
        if (settings_obj.get("level")) |level| {
            const s = stringOf(level) orelse return error.InvalidScene;
            scene.settings.level = if (std.mem.eql(u8, s, "fallback"))
                .fallback
            else if (std.mem.eql(u8, s, "native"))
                .native
            else
                return error.InvalidScene;
        }
    }

    if (obj.get("target_init")) |target| {
        const s = stringOf(target) orelse return error.InvalidScene;
        scene.target_init = if (std.mem.eql(u8, s, "clear"))
            .clear
        else if (std.mem.eql(u8, s, "src_over"))
            .src_over
        else
            return error.InvalidScene;
    }

    if (obj.get("commands")) |commands_value| {
        const array = switch (commands_value) {
            .array => |a| a,
            else => return error.InvalidScene,
        };
        const commands = try alloc.alloc(Command, array.items.len);
        for (array.items, 0..) |item, i| {
            commands[i] = try parseCommand(alloc, item);
        }
        scene.commands = commands;
    }

    return .{ .arena = arena, .scene = scene };
}

fn parseCommand(alloc: std.mem.Allocator, value: std.json.Value) ParseError!Command {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidScene,
    };
    const op = stringOf(obj.get("op") orelse return error.InvalidScene) orelse
        return error.InvalidScene;

    if (std.mem.eql(u8, op, "set_transform")) return .{ .set_transform = try affineField(obj) };
    if (std.mem.eql(u8, op, "reset_transform")) return .reset_transform;
    if (std.mem.eql(u8, op, "set_paint_transform")) return .{ .set_paint_transform = try affineField(obj) };
    if (std.mem.eql(u8, op, "reset_paint_transform")) return .reset_paint_transform;
    if (std.mem.eql(u8, op, "set_paint")) return .{ .set_paint = try parsePaint(alloc, obj) };
    if (std.mem.eql(u8, op, "set_fill_rule")) {
        const s = stringOf(obj.get("rule") orelse return error.InvalidScene) orelse
            return error.InvalidScene;
        if (std.mem.eql(u8, s, "nonzero")) return .{ .set_fill_rule = .nonzero };
        if (std.mem.eql(u8, s, "evenodd")) return .{ .set_fill_rule = .evenodd };
        return error.InvalidScene;
    }
    if (std.mem.eql(u8, op, "set_stroke")) return .{ .set_stroke = try parseStroke(alloc, obj) };
    if (std.mem.eql(u8, op, "set_aliasing_threshold")) {
        const threshold: ?u8 = switch (obj.get("value") orelse .null) {
            .null => null,
            .integer => |i| std.math.cast(u8, i) orelse return error.InvalidScene,
            else => return error.InvalidScene,
        };
        return .{ .set_aliasing_threshold = threshold };
    }
    if (std.mem.eql(u8, op, "fill_rect")) return .{ .fill_rect = try rectField(obj) };
    if (std.mem.eql(u8, op, "stroke_rect")) return .{ .stroke_rect = try rectField(obj) };
    if (std.mem.eql(u8, op, "fill_path")) return .{ .fill_path = try pathField(alloc, obj) };
    if (std.mem.eql(u8, op, "stroke_path")) return .{ .stroke_path = try pathField(alloc, obj) };
    if (std.mem.eql(u8, op, "push_clip_path")) return .{ .push_clip_path = try pathField(alloc, obj) };
    if (std.mem.eql(u8, op, "pop_clip_path")) return .pop_clip_path;
    if (std.mem.eql(u8, op, "push_clip_layer")) return .{ .push_clip_layer = try pathField(alloc, obj) };
    if (std.mem.eql(u8, op, "push_layer")) return .{ .push_layer = try parseLayer(alloc, obj) };
    if (std.mem.eql(u8, op, "pop_layer")) return .pop_layer;
    if (std.mem.eql(u8, op, "reset")) return .reset;
    return error.InvalidScene;
}

fn parsePaint(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!PaintSpec {
    const variants = @as(u8, @intFromBool(obj.get("rgba8") != null)) +
        @intFromBool(obj.get("gradient") != null) +
        @intFromBool(obj.get("image") != null);
    if (variants != 1) return error.InvalidScene;
    if (obj.get("rgba8") != null) return .{ .solid = try rgba8Field(obj) };
    if (obj.get("gradient")) |value| return .{ .gradient = try parseGradient(alloc, value) };
    return .{ .image = try parseImage(alloc, obj.get("image").?) };
}

fn parseGradient(alloc: std.mem.Allocator, value: std.json.Value) ParseError!GradientSpec {
    const obj = try objectOf(value);
    const stops_value = obj.get("stops") orelse return error.InvalidScene;
    const stops_array = switch (stops_value) {
        .array => |a| a,
        else => return error.InvalidScene,
    };
    const stops = try alloc.alloc(ColorStop, stops_array.items.len);
    for (stops_array.items, 0..) |item, i| {
        stops[i] = try parseColorStop(item);
    }
    return .{
        .kind = try parseGradientKind(obj.get("kind") orelse return error.InvalidScene),
        .stops = stops,
        .extend = try enumField(Extend, obj, "extend"),
    };
}

fn parseGradientKind(value: std.json.Value) ParseError!GradientKind {
    const obj = try objectOf(value);
    if (obj.count() != 1) return error.InvalidScene;
    if (obj.get("linear")) |inner| {
        const inner_obj = try objectOf(inner);
        return .{ .linear = .{
            .start = try pointField(inner_obj, "start"),
            .end = try pointField(inner_obj, "end"),
        } };
    }
    if (obj.get("radial")) |inner| {
        const inner_obj = try objectOf(inner);
        return .{ .radial = .{
            .start_center = try pointField(inner_obj, "start_center"),
            .start_radius = try floatField(inner_obj, "start_radius"),
            .end_center = try pointField(inner_obj, "end_center"),
            .end_radius = try floatField(inner_obj, "end_radius"),
        } };
    }
    if (obj.get("sweep")) |inner| {
        const inner_obj = try objectOf(inner);
        return .{ .sweep = .{
            .center = try pointField(inner_obj, "center"),
            .start_angle = try floatField(inner_obj, "start_angle"),
            .end_angle = try floatField(inner_obj, "end_angle"),
        } };
    }
    return error.InvalidScene;
}

fn parseColorStop(value: std.json.Value) ParseError!ColorStop {
    const obj = try objectOf(value);
    return .{
        .offset = try floatField(obj, "offset"),
        .rgba8 = try rgba8Field(obj),
    };
}

fn parseImage(alloc: std.mem.Allocator, value: std.json.Value) ParseError!ImageSpec {
    const obj = try objectOf(value);
    const sampler_obj = try objectOf(obj.get("sampler") orelse return error.InvalidScene);
    return .{
        .asset = try dupeField(alloc, obj, "asset"),
        .width = try u16Field(obj, "width"),
        .height = try u16Field(obj, "height"),
        .format = try enumField(ImageFormat, obj, "format"),
        .alpha_type = try enumField(ImageAlphaType, obj, "alpha_type"),
        .sampler = .{
            .x_extend = try enumField(Extend, sampler_obj, "x_extend"),
            .y_extend = try enumField(Extend, sampler_obj, "y_extend"),
            .quality = try enumField(ImageQuality, sampler_obj, "quality"),
            .alpha = try floatField(sampler_obj, "alpha"),
        },
    };
}

fn parseMask(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!MaskSpec {
    return .{
        .asset = try dupeField(alloc, obj, "asset"),
        .width = try u16Field(obj, "width"),
        .height = try u16Field(obj, "height"),
        .format = try enumField(ImageFormat, obj, "format"),
        .alpha_type = try enumField(ImageAlphaType, obj, "alpha_type"),
        .kind = try enumField(MaskKind, obj, "kind"),
    };
}

fn parseLayer(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!LayerSpec {
    const kind = stringOf(obj.get("kind") orelse return error.InvalidScene) orelse
        return error.InvalidScene;
    if (std.mem.eql(u8, kind, "clip")) {
        return .{ .clip = try pathField(alloc, obj) };
    }
    if (std.mem.eql(u8, kind, "blend")) {
        const blend_obj = try objectOf(obj.get("blend") orelse return error.InvalidScene);
        return .{ .blend = .{
            .mix = try enumField(Mix, blend_obj, "mix"),
            .compose = try enumField(Compose, blend_obj, "compose"),
        } };
    }
    if (std.mem.eql(u8, kind, "opacity")) {
        return .{ .opacity = try floatField(obj, "opacity") };
    }
    if (std.mem.eql(u8, kind, "mask")) {
        const mask_obj = try objectOf(obj.get("mask") orelse return error.InvalidScene);
        return .{ .mask = try parseMask(alloc, mask_obj) };
    }
    return error.InvalidScene;
}

fn parseStroke(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!StrokeSpec {
    var spec: StrokeSpec = .{ .width = try floatField(obj, "width") };
    if (obj.get("join")) |v| {
        const s = stringOf(v) orelse return error.InvalidScene;
        spec.join = if (std.mem.eql(u8, s, "miter"))
            .miter
        else if (std.mem.eql(u8, s, "round"))
            .round
        else if (std.mem.eql(u8, s, "bevel"))
            .bevel
        else
            return error.InvalidScene;
    }
    if (obj.get("start_cap")) |v| spec.start_cap = try parseCap(v);
    if (obj.get("end_cap")) |v| spec.end_cap = try parseCap(v);
    if (obj.get("miter_limit")) |v| {
        spec.miter_limit = switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidScene,
        };
    }
    if (obj.get("dash_offset")) |v| {
        spec.dash_offset = switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidScene,
        };
    }
    if (obj.get("dash")) |v| {
        const array = switch (v) {
            .array => |a| a,
            else => return error.InvalidScene,
        };
        const dash = try alloc.alloc(f64, array.items.len);
        for (array.items, 0..) |item, i| {
            dash[i] = switch (item) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.InvalidScene,
            };
        }
        spec.dash = dash;
    }
    return spec;
}

fn parseCap(value: std.json.Value) ParseError!Cap {
    const s = stringOf(value) orelse return error.InvalidScene;
    if (std.mem.eql(u8, s, "butt")) return .butt;
    if (std.mem.eql(u8, s, "round")) return .round;
    if (std.mem.eql(u8, s, "square")) return .square;
    return error.InvalidScene;
}

fn affineField(obj: std.json.ObjectMap) ParseError!Affine {
    const array = switch (obj.get("affine") orelse return error.InvalidScene) {
        .array => |a| a,
        else => return error.InvalidScene,
    };
    if (array.items.len != 6) return error.InvalidScene;
    var out: Affine = undefined;
    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.InvalidScene,
        };
    }
    return out;
}

fn rectField(obj: std.json.ObjectMap) ParseError![4]f64 {
    const array = switch (obj.get("rect") orelse return error.InvalidScene) {
        .array => |a| a,
        else => return error.InvalidScene,
    };
    if (array.items.len != 4) return error.InvalidScene;
    var out: [4]f64 = undefined;
    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.InvalidScene,
        };
    }
    return out;
}

fn rgba8Field(obj: std.json.ObjectMap) ParseError![4]u8 {
    const array = switch (obj.get("rgba8") orelse return error.InvalidScene) {
        .array => |a| a,
        else => return error.InvalidScene,
    };
    if (array.items.len != 4) return error.InvalidScene;
    var out: [4]u8 = undefined;
    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |n| std.math.cast(u8, n) orelse return error.InvalidScene,
            else => return error.InvalidScene,
        };
    }
    return out;
}

fn pathField(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError![]const u8 {
    return dupeField(alloc, obj, "path");
}

fn dupeField(alloc: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
    const s = stringOf(obj.get(name) orelse return error.InvalidScene) orelse
        return error.InvalidScene;
    return alloc.dupe(u8, s) catch return error.OutOfMemory;
}

fn objectOf(value: std.json.Value) ParseError!std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.InvalidScene,
    };
}

fn enumField(comptime T: type, obj: std.json.ObjectMap, name: []const u8) ParseError!T {
    const s = stringOf(obj.get(name) orelse return error.InvalidScene) orelse
        return error.InvalidScene;
    return std.meta.stringToEnum(T, s) orelse error.InvalidScene;
}

fn pointField(obj: std.json.ObjectMap, name: []const u8) ParseError![2]f64 {
    const array = switch (obj.get(name) orelse return error.InvalidScene) {
        .array => |a| a,
        else => return error.InvalidScene,
    };
    if (array.items.len != 2) return error.InvalidScene;
    var out: [2]f64 = undefined;
    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.InvalidScene,
        };
    }
    return out;
}

fn stringOf(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn u16Field(obj: std.json.ObjectMap, name: []const u8) ParseError!u16 {
    const value = obj.get(name) orelse return error.InvalidScene;
    return switch (value) {
        .integer => |i| std.math.cast(u16, i) orelse error.InvalidScene,
        else => error.InvalidScene,
    };
}

fn floatField(obj: std.json.ObjectMap, name: []const u8) ParseError!f64 {
    const value = obj.get(name) orelse return error.InvalidScene;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.InvalidScene,
    };
}

test "parse every corpus scene" {
    const std_testing = std.testing;
    const io = std_testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/scenes", .{ .iterate = true });
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const text = try dir.readFileAlloc(io, entry.name, std_testing.allocator, .unlimited);
        defer std_testing.allocator.free(text);
        var parsed = try parse(std_testing.allocator, text);
        defer parsed.deinit();
        try std_testing.expect(parsed.scene.width > 0);
        try std_testing.expect(parsed.scene.height > 0);
        count += 1;
    }
    try std_testing.expect(count >= 22);
}

test "commands parse with expected variants" {
    const text =
        \\{"version":1,"width":8,"height":8,
        \\ "commands":[
        \\   {"op":"set_paint","rgba8":[1,2,3,4]},
        \\   {"op":"set_stroke","width":2.5,"join":"round","dash":[1,2],"dash_offset":0.5},
        \\   {"op":"fill_rect","rect":[0,0,8,8]},
        \\   {"op":"push_clip_path","path":"M0 0 L8 8 Z"},
        \\   {"op":"pop_clip_path"},
        \\   {"op":"push_clip_layer","path":"M0 0 L8 0 L8 8 Z"},
        \\   {"op":"push_layer","kind":"clip","path":"M0 0 L8 8 Z"},
        \\   {"op":"pop_layer"}
        \\ ]}
    ;
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 8), parsed.scene.width);
    try std.testing.expectEqual(@as(usize, 8), parsed.scene.commands.len);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, parsed.scene.commands[0].set_paint.solid);
    const stroke = parsed.scene.commands[1].set_stroke;
    try std.testing.expectEqual(@as(f64, 2.5), stroke.width);
    try std.testing.expectEqual(Join.round, stroke.join.?);
    try std.testing.expectEqual(@as(usize, 2), stroke.dash.?.len);
    try std.testing.expectEqualStrings("M0 0 L8 8 Z", parsed.scene.commands[3].push_clip_path);
    // `push_layer kind:clip` is equivalent to `push_clip_layer`.
    try std.testing.expectEqualStrings("M0 0 L8 0 L8 8 Z", parsed.scene.commands[5].push_clip_layer);
    try std.testing.expectEqualStrings("M0 0 L8 8 Z", parsed.scene.commands[6].push_layer.clip);
}

test "milestone 2 gradient scenes parse with expected kinds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    {
        var parsed = try parseSceneFile(alloc, io, "gradient_linear_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[0].set_paint) {
            .gradient => |g| {
                try std.testing.expectEqual(@as(usize, 2), g.stops.len);
                try std.testing.expectEqual(Extend.pad, g.extend);
                try std.testing.expectEqual(@as(f64, 0.0), g.stops[0].offset);
                try std.testing.expectEqual([4]u8{ 0, 200, 64, 255 }, g.stops[0].rgba8);
                switch (g.kind) {
                    .linear => |lin| {
                        try std.testing.expectEqual([2]f64{ 10, 10 }, lin.start);
                        try std.testing.expectEqual([2]f64{ 54, 54 }, lin.end);
                    },
                    else => return error.InvalidScene,
                }
            },
            else => return error.InvalidScene,
        }
    }
    {
        var parsed = try parseSceneFile(alloc, io, "gradient_radial_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[0].set_paint) {
            .gradient => |g| switch (g.kind) {
                .radial => |r| {
                    try std.testing.expectEqual([2]f64{ 32, 32 }, r.start_center);
                    try std.testing.expectEqual(@as(f64, 4), r.start_radius);
                    try std.testing.expectEqual([2]f64{ 32, 32 }, r.end_center);
                    try std.testing.expectEqual(@as(f64, 24), r.end_radius);
                },
                else => return error.InvalidScene,
            },
            else => return error.InvalidScene,
        }
    }
    {
        var parsed = try parseSceneFile(alloc, io, "gradient_sweep_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[0].set_paint) {
            .gradient => |g| switch (g.kind) {
                .sweep => |s| {
                    try std.testing.expectEqual([2]f64{ 32, 32 }, s.center);
                    try std.testing.expectEqual(@as(f64, 0), s.start_angle);
                    try std.testing.expectApproxEqAbs(
                        @as(f64, 6.283185307179586),
                        s.end_angle,
                        1e-12,
                    );
                },
                else => return error.InvalidScene,
            },
            else => return error.InvalidScene,
        }
    }
    {
        var parsed = try parseSceneFile(alloc, io, "gradient_repeat_128.json");
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u16, 128), parsed.scene.width);
        switch (parsed.scene.commands[0].set_paint) {
            .gradient => |g| {
                try std.testing.expectEqual(@as(usize, 3), g.stops.len);
                try std.testing.expectEqual(Extend.repeat, g.extend);
            },
            else => return error.InvalidScene,
        }
        try std.testing.expect(parsed.scene.commands[1].fill_path.len > 0);
    }
}

test "milestone 2 image scenes parse with expected samplers" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    {
        var parsed = try parseSceneFile(alloc, io, "image_nearest_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[0].set_paint) {
            .image => |im| {
                try std.testing.expectEqualStrings("assets/checker16.rgba", im.asset);
                try std.testing.expectEqual(@as(u16, 16), im.width);
                try std.testing.expectEqual(@as(u16, 16), im.height);
                try std.testing.expectEqual(ImageFormat.rgba8, im.format);
                try std.testing.expectEqual(ImageAlphaType.alpha, im.alpha_type);
                try std.testing.expectEqual(Extend.pad, im.sampler.x_extend);
                try std.testing.expectEqual(Extend.pad, im.sampler.y_extend);
                try std.testing.expectEqual(ImageQuality.low, im.sampler.quality);
                try std.testing.expectEqual(@as(f64, 1.0), im.sampler.alpha);
            },
            else => return error.InvalidScene,
        }
        try std.testing.expectEqual(
            Affine{ 3, 0, 0, 3, 0, 0 },
            parsed.scene.commands[1].set_paint_transform,
        );
    }
    {
        var parsed = try parseSceneFile(alloc, io, "image_bilinear_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[0].set_paint) {
            .image => |im| {
                try std.testing.expectEqual(Extend.reflect, im.sampler.x_extend);
                try std.testing.expectEqual(Extend.reflect, im.sampler.y_extend);
                try std.testing.expectEqual(ImageQuality.medium, im.sampler.quality);
            },
            else => return error.InvalidScene,
        }
    }
}

test "milestone 2 layer and mask scenes parse with expected kinds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    {
        var parsed = try parseSceneFile(alloc, io, "layer_blend_multiply_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[2].push_layer) {
            .blend => |b| {
                try std.testing.expectEqual(Mix.multiply, b.mix);
                try std.testing.expectEqual(Compose.src_over, b.compose);
            },
            else => return error.InvalidScene,
        }
        try std.testing.expectEqual(@as(usize, 6), parsed.scene.commands.len);
    }
    {
        var parsed = try parseSceneFile(alloc, io, "layer_opacity_64.json");
        defer parsed.deinit();
        try std.testing.expectEqual(
            @as(f64, 0.5),
            parsed.scene.commands[2].push_layer.opacity,
        );
        try std.testing.expectEqual(
            @as(f64, 0.5),
            parsed.scene.commands[5].push_layer.opacity,
        );
    }
    {
        var parsed = try parseSceneFile(alloc, io, "mask_alpha_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[2].push_layer) {
            .mask => |m| {
                try std.testing.expectEqualStrings("assets/mask16.rgba", m.asset);
                try std.testing.expectEqual(@as(u16, 16), m.width);
                try std.testing.expectEqual(@as(u16, 16), m.height);
                try std.testing.expectEqual(ImageFormat.rgba8, m.format);
                try std.testing.expectEqual(ImageAlphaType.alpha, m.alpha_type);
                try std.testing.expectEqual(MaskKind.alpha, m.kind);
            },
            else => return error.InvalidScene,
        }
    }
    {
        var parsed = try parseSceneFile(alloc, io, "mask_luminance_64.json");
        defer parsed.deinit();
        switch (parsed.scene.commands[2].push_layer) {
            .mask => |m| try std.testing.expectEqual(MaskKind.luminance, m.kind),
            else => return error.InvalidScene,
        }
    }
}

test "invalid scenes are rejected" {
    try std.testing.expectError(error.InvalidScene, parse(std.testing.allocator, "{}"));
    try std.testing.expectError(
        error.InvalidScene,
        parse(std.testing.allocator, "{\"version\":2,\"width\":1,\"height\":1}"),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(std.testing.allocator, "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"nope\"}]}"),
    );
    // set_paint requires exactly one variant.
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"set_paint\"}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"set_paint\",\"rgba8\":[1,2,3,4],\"gradient\":{}}]}",
        ),
    );
    // Unknown gradient kinds, sampler values and layer kinds are rejected.
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"set_paint\",\"gradient\":{\"kind\":{\"conic\":{}},\"stops\":[],\"extend\":\"pad\"}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"set_paint\",\"gradient\":{\"kind\":{\"linear\":{\"start\":[0,0],\"end\":[1,1]}},\"stops\":[],\"extend\":\"clamp\"}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"set_paint\",\"image\":{\"asset\":\"a.rgba\",\"width\":1,\"height\":1,\"format\":\"rgba8\",\"alpha_type\":\"alpha\",\"sampler\":{\"x_extend\":\"pad\",\"y_extend\":\"pad\",\"quality\":\"ultra\",\"alpha\":1.0}}}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"push_layer\",\"kind\":\"filter\"}]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidScene,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"width\":1,\"height\":1,\"commands\":[{\"op\":\"push_layer\",\"kind\":\"mask\",\"mask\":{\"asset\":\"a.rgba\",\"width\":1,\"height\":1,\"format\":\"rgba8\",\"alpha_type\":\"alpha\",\"kind\":\"chroma\"}}]}",
        ),
    );
}

fn parseSceneFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
) ParseError!Parsed {
    var dir = std.Io.Dir.cwd().openDir(io, "tests/scenes", .{}) catch return error.InvalidScene;
    defer dir.close(io);
    const text = dir.readFileAlloc(io, name, alloc, .unlimited) catch return error.InvalidScene;
    defer alloc.free(text);
    return parse(alloc, text);
}
