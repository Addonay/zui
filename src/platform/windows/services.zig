//! Win32-facing aliases for the window-scoped GPUI platform contract.

pub const contract = @import("../native_window_services.zig");
pub const WindowHandle = contract.WindowHandle;
pub const WindowRegistry = contract.WindowRegistry;
pub const PlatformServices = contract.PlatformServices;
pub const ClipboardFormat = contract.ClipboardFormat;
pub const ImeState = contract.ImeState;
pub const Cursor = contract.Cursor;
pub const DpiState = contract.DpiState;
pub const Lifecycle = contract.Lifecycle;

/// The native handle is HWND on Windows and an integer identity in the
/// portable registry. The conversion is kept here so callback code cannot
/// accidentally use a process-global active window.
pub fn handleFromHwnd(hwnd: @import("bindings.zig").HWND, generation: u32) !WindowHandle {
    return .{ .native = @intFromPtr(hwnd orelse return error.InvalidHandle), .generation = generation };
}

test {
    _ = contract;
}
