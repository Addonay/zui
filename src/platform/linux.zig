//! Linux platform: Wayland first, then X11 (GPUI `gpui_linux`).
const std = @import("std");
const platform = @import("../platform.zig");

pub fn create(allocator: std.mem.Allocator) !*platform.Platform {
    _ = allocator;
    return error.Unsupported;
}
