//! Windows library ownership through Zig's native OS layer.
const std = @import("std");
const builtin = @import("builtin");
pub const Library = struct {
    handle: *anyopaque,
    pub fn open(comptime name: [:0]const u8) !Library {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const windows = std.os.windows;
        const wide = std.unicode.utf8ToUtf16LeStringLiteral(name);
        const string = windows.UNICODE_STRING.initZ(wide);
        var handle: windows.PVOID = undefined;
        if (windows.ntdll.LdrLoadDll(null, null, &string, &handle) != .SUCCESS) return error.LibraryNotFound;
        return .{ .handle = handle };
    }
    pub fn lookup(self: Library, comptime T: type, name: [:0]const u8) ?T {
        if (comptime builtin.os.tag != .windows) return null;
        const windows = std.os.windows;
        const string = windows.ANSI_STRING.initZ(name);
        var address: windows.PVOID = undefined;
        if (windows.ntdll.LdrGetProcedureAddress(self.handle, &string, 0, &address) != .SUCCESS) return null;
        return @ptrCast(@alignCast(address));
    }
    pub fn close(self: Library) void {
        if (comptime builtin.os.tag == .windows) _ = std.os.windows.ntdll.LdrUnloadDll(self.handle);
    }
};
