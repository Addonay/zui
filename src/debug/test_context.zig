//! Reusable, renderer-independent GPUI-style test contexts.
//!
//! A TestContext owns deterministic time, frame/event recording, an offscreen
//! Scene supplied by the caller, golden comparison, replay, and compact
//! profiler/inspector snapshots. It deliberately does not create a Window,
//! access a platform backend, or make a GPU claim.
const std = @import("std");
const geometry = @import("../core/geometry.zig");
const scene_mod = @import("../gpu/scene.zig");
const trace_mod = @import("trace.zig");
const profiler_mod = @import("profiler.zig");
const snapshot_mod = @import("snapshot.zig");

pub const Scene = scene_mod.Scene;
pub const InputKind = enum(u8) { mouse_move, mouse_down, mouse_up, key_down, key_up, scroll, marker };

pub const Input = struct {
    kind: InputKind,
    code: u16 = 0,
    x: f32 = 0,
    y: f32 = 0,
    value: i64 = 0,
    aux: i64 = 0,
};

pub const InputHandler = *const fn (*TestContext, Input) void;

pub const Golden = struct {
    digest: u64,
    commands: usize,
    quads: usize,
    glyphs: usize,
    images: usize,
    strokes: usize,
    paths: usize,
    shadows: usize,
    dropped: u64,

    pub fn from(value: snapshot_mod.Snapshot) @This() {
        return .{
            .digest = value.digest,
            .commands = value.commands,
            .quads = value.quads,
            .glyphs = value.glyphs,
            .images = value.images,
            .strokes = value.strokes,
            .paths = value.paths,
            .shadows = value.shadows,
            .dropped = value.dropped,
        };
    }

    pub fn matches(self: @This(), value: snapshot_mod.Snapshot) bool {
        return self.digest == value.digest and
            self.commands == value.commands and
            self.quads == value.quads and
            self.glyphs == value.glyphs and
            self.images == value.images and
            self.strokes == value.strokes and
            self.paths == value.paths and
            self.shadows == value.shadows and
            self.dropped == value.dropped;
    }
};

pub const InspectorSnapshot = struct {
    frame: u32,
    now_ns: u64,
    viewport: geometry.Rect,
    scene_digest: u64,
    event_digest: u64,
    profiler_digest: u64,
    event_count: usize,
    profiler_count: usize,
    scene_commands: usize,

    pub fn digest(self: @This()) u64 {
        var hash: u64 = 14695981039346656037;
        hashU64(&hash, self.frame);
        hashU64(&hash, self.now_ns);
        hashF32(&hash, self.viewport.x);
        hashF32(&hash, self.viewport.y);
        hashF32(&hash, self.viewport.w);
        hashF32(&hash, self.viewport.h);
        hashU64(&hash, self.scene_digest);
        hashU64(&hash, self.event_digest);
        hashU64(&hash, self.profiler_digest);
        hashU64(&hash, self.event_count);
        hashU64(&hash, self.profiler_count);
        hashU64(&hash, self.scene_commands);
        return hash;
    }

    /// Stable JSON for external smoke tools and snapshot artifacts.
    pub fn writeJson(self: @This(), allocator: std.mem.Allocator, writer: anytype) !void {
        _ = allocator;
        try std.json.Stringify.value(.{
            .type = "zui.test_context",
            .version = 1,
            .frame = self.frame,
            .now_ns = self.now_ns,
            .viewport = self.viewport,
            .scene_digest = self.scene_digest,
            .event_digest = self.event_digest,
            .profiler_digest = self.profiler_digest,
            .event_count = self.event_count,
            .profiler_count = self.profiler_count,
            .scene_commands = self.scene_commands,
        }, .{}, writer);
    }
};

pub const TestContext = struct {
    scene: *Scene,
    viewport: geometry.Rect,
    frame: u32 = 0,
    now_ns: u64 = 0,
    events: trace_mod.Trace = .{},
    profiler: profiler_mod.Recorder = .{},
    last_snapshot: ?snapshot_mod.Snapshot = null,

    pub fn init(scene: *Scene, width: f32, height: f32) @This() {
        scene.clear();
        return .{ .scene = scene, .viewport = .{ .x = 0, .y = 0, .w = width, .h = height } };
    }

    pub fn beginFrame(self: *@This(), timestamp_ns: u64) void {
        self.now_ns = timestamp_ns;
        self.scene.clear();
        _ = self.events.frameBegin(timestamp_ns, self.frame);
    }

    pub fn advance(self: *@This(), timestamp_ns: u64) void {
        self.now_ns = timestamp_ns;
    }

    pub fn profileBegin(self: *@This(), label: []const u8) profiler_mod.Span {
        return self.profiler.begin(label, self.now_ns);
    }

    pub fn profileEnd(self: *@This(), span: *profiler_mod.Span, timestamp_ns: u64) bool {
        self.now_ns = timestamp_ns;
        return self.profiler.end(span, timestamp_ns);
    }

    pub fn profileCounter(self: *@This(), label: []const u8, value: u64) bool {
        return self.profiler.counter(label, value);
    }

    pub fn dispatch(self: *@This(), input: Input) void {
        const value: u64 = @bitCast(input.value);
        const aux: u64 = @bitCast(input.aux);
        const event_code: u16 = @as(u16, @backingInt(input.kind)) * 256 + input.code;
        _ = self.events.append(self.now_ns, self.frame, .event, event_code, value, aux, "input");
    }

    pub fn replay(self: *@This(), inputs: []const Input, handler: ?InputHandler) void {
        for (inputs) |input| {
            self.dispatch(input);
            if (handler) |callback| callback(self, input);
        }
    }

    pub fn endFrame(self: *@This()) !snapshot_mod.Snapshot {
        _ = self.events.frameEnd(self.now_ns, self.frame);
        self.last_snapshot = try snapshot_mod.capture(self.scene);
        self.frame += 1;
        return self.last_snapshot.?;
    }

    pub fn compareGolden(self: *const @This(), golden: Golden) !void {
        const value = self.last_snapshot orelse return error.NoFrame;
        if (!golden.matches(value)) return error.GoldenMismatch;
    }

    pub fn inspect(self: *const @This()) InspectorSnapshot {
        const scene_digest = if (self.last_snapshot) |value| value.digest else 0;
        return .{
            .frame = self.frame,
            .now_ns = self.now_ns,
            .viewport = self.viewport,
            .scene_digest = scene_digest,
            .event_digest = self.events.digest(false),
            .profiler_digest = self.profiler.digest(),
            .event_count = self.events.len,
            .profiler_count = self.profiler.len,
            .scene_commands = self.scene.command_len,
        };
    }
};

/// Naming aligned with GPUI visual tests; it is intentionally the same
/// deterministic context because this layer captures scene data rather than
/// pixels from a native compositor.
pub const VisualTestContext = TestContext;

fn hashU64(hash: *u64, value: anytype) void {
    var v: u64 = @intCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        hash.* ^= v & 0xff;
        hash.* *%= 1099511628211;
        v >>= 8;
    }
}

fn hashF32(hash: *u64, value: f32) void {
    hashU64(hash, @as(u32, @bitCast(value)));
}

test "test context replays input and compares an offscreen golden" {
    var scene = Scene{};
    var context = TestContext.init(&scene, 320, 200);
    context.beginFrame(100);
    _ = scene.push(.{ .x = 4, .y = 5, .w = 20, .h = 10, .color = .white });
    const inputs = [_]Input{ .{ .kind = .mouse_move, .x = 8, .y = 9 }, .{ .kind = .key_down, .code = 13 } };
    context.replay(&inputs, null);
    const captured = try context.endFrame();
    try context.compareGolden(Golden.from(captured));
    try std.testing.expectEqual(@as(usize, 4), context.events.len);
    try std.testing.expect(context.inspect().scene_digest == captured.digest);
}

test "test context inspector and replay are deterministic" {
    var left_scene = Scene{};
    var right_scene = Scene{};
    var left = TestContext.init(&left_scene, 100, 80);
    var right = TestContext.init(&right_scene, 100, 80);
    const inputs = [_]Input{.{ .kind = .scroll, .code = 2, .value = -4 }};
    left.beginFrame(10);
    right.beginFrame(9000);
    left.replay(&inputs, null);
    right.replay(&inputs, null);
    _ = try left.endFrame();
    _ = try right.endFrame();
    try std.testing.expectEqual(left.inspect().event_digest, right.inspect().event_digest);
    try std.testing.expectEqual(left.inspect().scene_digest, right.inspect().scene_digest);
}

test "test context rejects a changed golden" {
    var scene = Scene{};
    var context = TestContext.init(&scene, 10, 10);
    context.beginFrame(0);
    _ = scene.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white });
    _ = try context.endFrame();
    var golden = Golden.from(context.last_snapshot.?);
    golden.digest +%= 1;
    try std.testing.expectError(error.GoldenMismatch, context.compareGolden(golden));
}
