//! External consumer smoke command for the reusable headless test context.
//! This imports only the public `zui` module and never opens a native surface.
const std = @import("std");
const zui = @import("zui");

pub fn main(init: std.process.Init) !void {
    var output_buffer: [2048]u8 = undefined;
    var output: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &output_buffer);
    const writer = &output.interface;
    var scene = zui.Scene{};
    var context = zui.debug.test_context.VisualTestContext.init(&scene, 320, 200);
    context.beginFrame(1_000);
    _ = scene.push(.{ .x = 12, .y = 16, .w = 80, .h = 24, .color = .white, .radius = 4 });
    const input = [_]zui.debug.test_context.Input{
        .{ .kind = .mouse_move, .x = 20, .y = 20 },
        .{ .kind = .key_down, .code = 13 },
    };
    context.replay(&input, null);
    const captured = try context.endFrame();
    const inspector = context.inspect();
    try context.compareGolden(zui.debug.test_context.Golden.from(captured));
    try inspector.writeJson(init.gpa, writer);
    try writer.writeByte('\n');
    try writer.print("golden={x} inspector={x}\n", .{ captured.digest, inspector.digest() });
}

test "external visual context smoke" {
    var scene = zui.Scene{};
    var context = zui.debug.test_context.TestContext.init(&scene, 64, 64);
    context.beginFrame(0);
    _ = scene.push(.{ .x = 1, .y = 1, .w = 2, .h = 2, .color = .white });
    const captured = try context.endFrame();
    try context.compareGolden(.{
        .digest = captured.digest,
        .commands = captured.commands,
        .quads = captured.quads,
        .glyphs = captured.glyphs,
        .images = captured.images,
        .strokes = captured.strokes,
        .paths = captured.paths,
        .shadows = captured.shadows,
        .dropped = captured.dropped,
    });
}
