//! Cocoa-facing aliases for the window-scoped GPUI platform contract.

pub const contract = @import("../native_window_services.zig");
pub const WindowHandle = contract.WindowHandle;
pub const WindowRegistry = contract.WindowRegistry;
pub const PlatformServices = contract.PlatformServices;
pub const ClipboardFormat = contract.ClipboardFormat;
pub const ImeState = contract.ImeState;
pub const Cursor = contract.Cursor;
pub const DpiState = contract.DpiState;
pub const Lifecycle = contract.Lifecycle;

pub fn handleFromId(id: @import("bindings.zig").id, generation: u32) !WindowHandle {
    return .{ .native = @intFromPtr(id orelse return error.InvalidHandle), .generation = generation };
}

test {
    _ = contract;
}
