//! Shared COM ownership, Windows calling conventions and HLSL blob access.
const std = @import("std");
const builtin = @import("builtin");
pub const call_conv: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;
pub const Object = opaque {};
pub const Guid = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };
pub const CompileFn = *const fn (?*const anyopaque, usize, ?[*:0]const u8, ?*const anyopaque, ?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, u32, u32, *?*Object, *?*Object) callconv(call_conv) i32;

pub fn invoke(comptime index: usize, comptime Function: type, object: *Object, arguments: anytype) @typeInfo(@typeInfo(Function).pointer.child).@"fn".return_type.? {
    comptime {
        const Return = @typeInfo(@typeInfo(Function).pointer.child).@"fn".return_type.?;
        if (@typeInfo(Return) == .@"struct") @compileError("COM member struct returns require an explicit hidden result pointer");
    }
    const header: *const [*]const ?*const anyopaque = @ptrCast(@alignCast(object));
    const method: Function = @ptrCast(@alignCast(header.*[index].?));
    return @call(.auto, method, .{object} ++ arguments);
}

pub fn addRef(object: *Object) u32 {
    return invoke(1, *const fn (*Object) callconv(call_conv) u32, object, .{});
}

pub fn release(object: ?*Object) void {
    if (object) |value| _ = invoke(2, *const fn (*Object) callconv(call_conv) u32, value, .{});
}

pub fn getBufferPointer(object: *Object) ?*anyopaque {
    return invoke(3, *const fn (*Object) callconv(call_conv) ?*anyopaque, object, .{});
}

pub fn getBufferSize(object: *Object) usize {
    return invoke(4, *const fn (*Object) callconv(call_conv) usize, object, .{});
}

pub fn setPrivateData(object: *Object, guid: *const Guid, size: u32, data: ?*const anyopaque) i32 {
    return invoke(5, *const fn (*Object, *const Guid, u32, ?*const anyopaque) callconv(call_conv) i32, object, .{ guid, size, data });
}
