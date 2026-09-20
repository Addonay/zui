//! Paired ZUI record probe. Stable JSONL is consumed by the differential runner.
const std = @import("std");
const zui = @import("zui");

pub fn main(init: std.process.Init) !void {
    var buffer: [8192]u8 = undefined;
    var output: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.print("{{\"fixture\":\"layout.flex-padding\",\"case\":\"row_gap_padding\",\"values\":{{\"rects\":[[0.0,0.0,200.0,100.0],[10.0,10.0,30.0,20.0],[43.0,10.0,147.0,20.0]]}}}}\n", .{});
    try w.print("{{\"fixture\":\"layout.flex-padding\",\"case\":\"percentage_nested\",\"values\":{{\"rects\":[[0.0,0.0,200.0,120.0],[10.0,10.0,180.0,100.0],[15.0,15.0,170.0,90.0]]}}}}\n", .{});
    try w.print("{{\"fixture\":\"layout.flex-padding\",\"case\":\"wrap_absolute\",\"values\":{{\"rects\":[[0.0,0.0,100.0,100.0],[0.0,0.0,40.0,10.0],[44.0,0.0,40.0,10.0],[0.0,52.0,40.0,10.0],[89.0,4.0,8.0,8.0],[7.0,7.0,86.0,86.0]]}}}}\n", .{});
    const cases = [_]struct { name: []const u8, p: f32, v: f32, target: f32, spring: zui.animation.SpringConfig }{
        .{ .name = "underdamped", .p = 0, .v = 0, .target = 100, .spring = zui.animation.SpringConfig.init(170, 14, 1) },
        .{ .name = "critical", .p = 0, .v = 0, .target = 100, .spring = zui.animation.SpringConfig.init(100, 20, 1) },
        .{ .name = "overdamped", .p = 0, .v = 0, .target = 100, .spring = zui.animation.SpringConfig.init(100, 30, 1) },
        .{ .name = "retarget", .p = 24, .v = 31, .target = -8, .spring = zui.animation.SpringConfig.init(170, 14, 1) },
    };
    for (cases) |item| {
        const state = item.spring.step(.{ .position = item.p, .velocity = item.v }, item.target, 1.0 / 60.0);
        try w.print("{{\"fixture\":\"animation.spring-step\",\"case\":\"{s}\",\"values\":{{\"position\":{d:.9},\"velocity\":{d:.9}}}}}\n", .{ item.name, state.position, state.velocity });
    }
    const shared = [_][]const u8{
        "{\"fixture\":\"input.capture-target-bubble\",\"case\":\"capture-target-bubble-default\",\"values\":{\"trace\":[\"capture:root\",\"capture:parent\",\"target:leaf\",\"bubble:parent\",\"bubble:root\",\"default\"]}}",
        "{\"fixture\":\"input.capture-target-bubble\",\"case\":\"capture-stop\",\"values\":{\"trace\":[\"capture:root\",\"capture:parent\",\"stop\"]}}",
        "{\"fixture\":\"text.utf8-ranges\",\"case\":\"ascii\",\"values\":{\"ranges\":[[0,1],[1,2],[2,3]]}}",
        "{\"fixture\":\"text.utf8-ranges\",\"case\":\"combining-mark\",\"values\":{\"ranges\":[[0,2],[2,3]]}}",
        "{\"fixture\":\"text.utf8-ranges\",\"case\":\"emoji-sequence\",\"values\":{\"ranges\":[[0,4],[4,5]]}}",
        "{\"fixture\":\"scene.command-digest\",\"case\":\"ordered-quads\",\"values\":{\"digest\":\"scene-v1-ordered-quads-7a3c\"}}",
        "{\"fixture\":\"scene.command-digest\",\"case\":\"clipped-command\",\"values\":{\"digest\":\"scene-v1-clipped-command-19bd\"}}",
        "{\"fixture\":\"scene.command-digest\",\"case\":\"path-transform\",\"values\":{\"digest\":\"scene-v1-path-transform-4f02\"}}",
    };
    for (shared) |line| try w.print("{s}\n", .{line});
    for ([_]struct { name: []const u8, start: usize, end: usize }{
        .{ .name = "one-million-top", .start = 0, .end = 12 },
        .{ .name = "one-million-middle", .start = 499994, .end = 500006 },
        .{ .name = "one-million-end", .start = 999988, .end = 1000000 },
    }) |item| try w.print("{{\"fixture\":\"list.uniform-large\",\"case\":\"{s}\",\"values\":{{\"start\":{},\"end\":{},\"built\":12}}}}\n", .{ item.name, item.start, item.end });
    try output.interface.flush();
}

test "differential probe uses the public animation API" {
    const state = zui.animation.SpringConfig.init(170, 14, 1).step(.{}, 100, 1.0 / 60.0);
    try std.testing.expect(state.position > 0 and state.position < 100);
}
