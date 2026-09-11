//! CPU rendering example: overlapping translucent fills, a clip layer, and a
//! round-capped stroke, written as a PPM for inspection.
//!
//! This mirrors the upstream `vello_cpu/examples/basic.rs` scene shape using
//! the vellz API. Run with `zig build run-cpu-example`; the image is written to
//! `cpu_example.ppm` in the working directory.

const std = @import("std");
const vellz = @import("vellz");
const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const cpu = vellz.cpu;
const common = vellz.common;

const width: u16 = 200;
const height: u16 = 200;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var ctx = try cpu.RenderContext.init(allocator, width, height, .{
        .level = vellz.simd.Level.fallback,
        .num_threads = 0,
    });
    defer ctx.deinit(allocator);

    var resources = cpu.Resources.init();
    defer resources.deinit(allocator);

    var pixmap = try common.pixmap.Pixmap.init(allocator, width, height);
    defer pixmap.deinit(allocator);

    // Solid blue square.
    ctx.setPaint(peniko.color.palette.css.BLUE);
    try ctx.fillRect(allocator, kurbo.Rect.new(20, 20, 120, 120));

    // Translucent red square overlapping it.
    ctx.setPaint(peniko.Color.fromRgba8(255, 0, 0, 128));
    try ctx.fillRect(allocator, kurbo.Rect.new(80, 80, 180, 180));

    // Isolated clip layer: a diamond; a frame-colored square is visible only
    // inside it and composites as one layer.
    var diamond = try diamondPath(allocator, 100, 100, 55);
    defer diamond.deinit(allocator);
    try ctx.pushClipLayer(allocator, diamond.elements.items);
    ctx.setPaint(peniko.Color.fromRgba8(255, 200, 0, 200));
    try ctx.fillRect(allocator, kurbo.Rect.new(0, 0, 200, 200));
    ctx.popLayer();

    // Round-capped stroke.
    const line = [_]kurbo.PathEl{
        .{ .MoveTo = kurbo.Point.new(30, 170) },
        .{ .LineTo = kurbo.Point.new(170, 170) },
    };
    ctx.setStroke(kurbo.Stroke.new(9.0).withStartCap(.round).withEndCap(.round));
    ctx.setPaint(peniko.color.palette.css.GREEN);
    try ctx.strokePath(allocator, &line);

    ctx.flush();
    try ctx.renderWith(&pixmap, &resources, .{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    });

    try writePpm(io, "cpu_example.ppm", &pixmap, allocator);
    std.debug.print(
        "wrote cpu_example.ppm ({d}x{d}); center={any} corner={any}\n",
        .{ width, height, pixmap.sample(100, 100), pixmap.sample(1, 1) },
    );
}

fn diamondPath(allocator: std.mem.Allocator, cx: f64, cy: f64, r: f64) !kurbo.BezPath {
    var path = kurbo.BezPath.init();
    errdefer path.deinit(allocator);
    try path.append(allocator, .{ .MoveTo = kurbo.Point.new(cx, cy - r) });
    try path.append(allocator, .{ .LineTo = kurbo.Point.new(cx + r, cy) });
    try path.append(allocator, .{ .LineTo = kurbo.Point.new(cx, cy + r) });
    try path.append(allocator, .{ .LineTo = kurbo.Point.new(cx - r, cy) });
    try path.append(allocator, kurbo.PathEl.closePath());
    return path;
}

fn writePpm(
    io: std.Io,
    path: []const u8,
    pixmap: *const common.pixmap.Pixmap,
    allocator: std.mem.Allocator,
) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ pixmap.width, pixmap.height });
    defer allocator.free(header);

    const pixel_count = @as(usize, pixmap.width) * @as(usize, pixmap.height);
    const bytes = try allocator.alloc(u8, header.len + pixel_count * 3);
    defer allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);

    const src = pixmap.dataAsU8Slice();
    var dst = header.len;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        // PPM has no alpha; composite onto white so translucent pixels are
        // visible instead of being silently truncated.
        const a = src[i + 3];
        bytes[dst + 0] = composite(src[i + 0], a);
        bytes[dst + 1] = composite(src[i + 1], a);
        bytes[dst + 2] = composite(src[i + 2], a);
        dst += 3;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn composite(channel: u8, alpha: u8) u8 {
    // Premultiplied channel over white: c + 255*(1 - a).
    const inv = 255 - @as(u32, alpha);
    return @intCast(@min(255, @as(u32, channel) + inv));
}
