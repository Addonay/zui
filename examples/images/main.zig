//! ZUI images demo — headless snapshot proving img()/svg() end to end.
//!
//! Renders one row (file PNG, tinted SVG icon, gradient logo, grayscale
//! PNG) through the real element → layout → paint → software rasterizer
//! pipeline and dumps it as PPM:
//!   zig build run-images -- /tmp/images.ppm

const std = @import("std");
const zui = @import("zui");

const ICON =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>
;

const LOGO =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7c5cff"/><stop offset="1" stop-color="#46d5e8"/></linearGradient></defs><rect x="4" y="4" width="56" height="56" rx="14" fill="url(#g)"/></svg>
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const out_path = if (std.c.getenv("ZUI_IMAGES_OUT")) |raw| std.mem.span(raw) else "/tmp/zui-images.ppm";

    var cache = try zui.images.Cache.init(gpa);
    defer cache.deinit(gpa);

    var frame = zui.elements.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    frame.images = cache;
    frame.allocator = gpa;
    frame.frame_id = 1;
    zui.elements.element.beginFrame(&frame);
    defer zui.elements.element.endFrame();

    const root = zui.div().flex_row().items_center().gap(12).p(16).bg(zui.hex(0x0e0e13))
        .child(zui.imgPath("examples/images/checker.png").w(64).h(64))
        .child(zui.svg(ICON).w(48).h(48).tint(zui.hex(0x3ddc84)))
        .child(zui.svg(LOGO).w(64).h(64))
        .child(zui.imgPath("examples/images/checker.png").w(64).h(64).grayscale());
    zui.elements.layout.layout(&frame, root, .{ .x = 0, .y = 0, .w = 320, .h = 96 });
    var scene = zui.Scene{};
    zui.elements.painter.paint(&frame, root, &scene);

    const width: u32 = 320;
    const height: u32 = 96;
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    const target = zui.gpu.software.Target.init(pixels, width, height, .rgba32);
    target.clear(zui.hex(0x0e0e13));
    target.renderScene(&scene, &.{}, cache.pool[0..cache.used]);

    var path_buf: [4096]u8 = undefined;
    if (out_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..out_path.len], out_path);
    path_buf[out_path.len] = 0;
    const name: [*:0]const u8 = path_buf[0..out_path.len :0];
    const file = std.c.fopen(name, "wb") orelse return error.CannotOpen;
    defer _ = std.c.fclose(file);
    var header: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    if (std.c.fwrite(header_text.ptr, 1, header_text.len, file) != header_text.len) return error.WriteFailed;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (std.c.fwrite(pixels.ptr + i, 1, 3, file) != 3) return error.WriteFailed;
    }
    std.debug.print("images demo: {d} quads {d} blits -> {s}\n", .{ scene.slice().len, scene.imageSlice().len, out_path });
}
