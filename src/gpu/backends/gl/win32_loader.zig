//! The automatic Windows GL loader of sokol_gfx.h:10040-10211, used when no
//! `environment.gl.get_proc_address` is provided on Windows: functions are looked
//! up with wglGetProcAddress, falling back to the exports of opengl32.dll.
const std = @import("std");
const builtin = @import("builtin");
const Library = @import("../../platform/windows_library.zig").Library;

const WglGetProcAddress = *const fn (name: [*:0]const u8) callconv(if (builtin.os.tag == .windows) .winapi else .c) ?*const anyopaque;

pub const Loader = struct {
    opengl32: Library,
    wgl_get_proc_address: WglGetProcAddress,

    pub fn open() !Loader {
        const opengl32 = try Library.open("opengl32.dll");
        errdefer opengl32.close();
        const wgl = opengl32.lookup(WglGetProcAddress, "wglGetProcAddress") orelse return error.MissingOpenGlFunction;
        return .{ .opengl32 = opengl32, .wgl_get_proc_address = wgl };
    }

    pub fn close(self: *Loader) void {
        self.opengl32.close();
    }

    /// A resolver with the signature of `GlEnvironment.get_proc_address`;
    /// `user_data` points to the Loader.
    pub fn getProcAddress(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        const self: *const Loader = @ptrCast(@alignCast(user_data.?));
        if (self.wgl_get_proc_address(name.ptr)) |address| return address;
        return self.opengl32.lookup(*const anyopaque, name);
    }
};

pub const available = builtin.os.tag == .windows;
