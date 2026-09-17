//! Dynamic library loading helper for runtime backend probing.
//!
//! Loads system shared objects via dlopen/dlsym/dlclose without hard compile-time
//! linking dependencies. Fails gracefully if a shared library is not installed
//! or if libc is not linked.

const std = @import("std");
const builtin = @import("builtin");

pub const RTLD_LAZY: c_int = 0x00001;
pub const RTLD_NOW: c_int = 0x00002;
pub const RTLD_LOCAL: c_int = 0;
pub const RTLD_GLOBAL: c_int = 0x00100;

pub const Library = struct {
    handle: *anyopaque,

    pub fn open(names: []const [*:0]const u8) ?Library {
        if (!builtin.link_libc) {
            return null;
        }
        return Impl.open(names);
    }

    pub fn close(self: *Library) void {
        if (!builtin.link_libc) return;
        Impl.close(self.handle);
    }

    pub fn lookup(self: Library, comptime T: type, name: [*:0]const u8) ?T {
        if (!builtin.link_libc) return null;
        return Impl.lookup(T, self.handle, name);
    }

    // POSIX libdl on Unix-likes, kernel32 on Windows (which has no
    // dlopen/dlsym/dlclose — linking those externs fails lld-link).
    const Impl = if (builtin.target.os.tag == .windows) WindowsImpl else PosixImpl;

    const PosixImpl = struct {
        extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
        extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
        extern "c" fn dlclose(handle: ?*anyopaque) c_int;

        fn open(names: []const [*:0]const u8) ?Library {
            for (names) |name| {
                if (dlopen(name, RTLD_LAZY | RTLD_LOCAL)) |h| {
                    return .{ .handle = h };
                }
            }
            return null;
        }

        fn close(handle: *anyopaque) void {
            _ = dlclose(handle);
        }

        fn lookup(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
            const sym = dlsym(handle, name);
            if (sym) |s| {
                // dlsym hands back a minimally-aligned data pointer; the
                // loaded symbol is really a function, so assert the target
                // alignment instead of growing it with a bare @ptrCast
                // (which the compiler rejects on parameters with stricter
                // alignment, e.g. aarch64 where fn pointers are 4-aligned).
                return @as(T, @ptrCast(@alignCast(s)));
            }
            return null;
        }
    };

    const WindowsImpl = struct {
        extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetProcAddress(handle: *anyopaque, symbol: [*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(handle: *anyopaque) callconv(.winapi) c_int;

        fn open(names: []const [*:0]const u8) ?Library {
            for (names) |name| {
                if (LoadLibraryA(name)) |h| {
                    return .{ .handle = h };
                }
            }
            return null;
        }

        fn close(handle: *anyopaque) void {
            _ = FreeLibrary(handle);
        }

        fn lookup(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
            const sym = GetProcAddress(handle, name);
            if (sym) |s| {
                return @as(T, @ptrCast(@alignCast(s)));
            }
            return null;
        }
    };
};

test "dynamic library loader" {
    var lib = Library.open(&.{ "libc.so.6", "libc.so" });
    if (builtin.link_libc) {
        try std.testing.expect(lib != null);
        defer lib.?.close();
        const puts_fn = lib.?.lookup(*const fn ([*:0]const u8) callconv(.c) c_int, "puts");
        try std.testing.expect(puts_fn != null);
    } else {
        try std.testing.expect(lib == null);
    }
}
