//! Minimal external consumer of the zui package: exercises the public
//! module surface (`zui.hex`, geometry helpers, limits) without opening
//! a window, so the smoke test stays headless-safe on any machine.

const std = @import("std");
const zui = @import("zui");

pub fn main() void {
    const red = zui.hex(0xff0000);
    const p = zui.point(1, 2);
    const s = zui.size(640, 480);
    const r = zui.rect(p.x, p.y, s.w, s.h);
    std.debug.print("smoke: color={d},{d},{d} rect={d}x{d} max_windows={d}\n", .{
        red.r,
        red.g,
        red.b,
        r.w,
        r.h,
        zui.core.limits.MAX_WINDOWS,
    });
}
