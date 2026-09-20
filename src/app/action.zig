//! Type-erased actions and deterministic dispatch.
//!
//! This is the safe, non-macro portion of GPUI's `Action` family. Zig callers
//! provide an explicit descriptor for each action type; no derive or global
//! registration mechanism is required.

const std = @import("std");

pub const ActionError = error{ OutOfMemory, UnknownAction };

pub const Action = struct {
    name: []const u8,
    type_tag: u64,
    payload: *anyopaque,
    clone_fn: *const fn (std.mem.Allocator, *const anyopaque) ActionError!*anyopaque,
    destroy_fn: *const fn (std.mem.Allocator, *anyopaque) void,
    eql_fn: *const fn (*const anyopaque, *const anyopaque) bool,

    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) ActionError!Action {
        return .{ .name = self.name, .type_tag = self.type_tag, .payload = try self.clone_fn(allocator, self.payload), .clone_fn = self.clone_fn, .destroy_fn = self.destroy_fn, .eql_fn = self.eql_fn };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.destroy_fn(allocator, self.payload);
        self.* = undefined;
    }

    pub fn eql(self: *const @This(), other: *const @This()) bool {
        return self.type_tag == other.type_tag and self.eql_fn(self.payload, other.payload);
    }

    pub fn as(self: *const @This(), comptime T: type) ?*const T {
        if (self.type_tag != typeTag(T)) return null;
        return @ptrCast(@alignCast(self.payload));
    }
};

pub fn typeTag(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

pub fn make(comptime T: type, allocator: std.mem.Allocator, value: T) ActionError!Action {
    const Box = struct { value: T };
    const box = allocator.create(Box) catch return error.OutOfMemory;
    box.* = .{ .value = value };
    return .{
        .name = if (@hasDecl(T, "actionName")) T.actionName() else @typeName(T),
        .type_tag = typeTag(T),
        .payload = @ptrCast(box),
        .clone_fn = struct {
            fn clone(a: std.mem.Allocator, raw: *const anyopaque) ActionError!*anyopaque {
                const source: *const Box = @ptrCast(@alignCast(raw));
                const copy = a.create(Box) catch return error.OutOfMemory;
                copy.* = source.*;
                return @ptrCast(copy);
            }
        }.clone,
        .destroy_fn = struct {
            fn destroy(a: std.mem.Allocator, raw: *anyopaque) void {
                a.destroy(@as(*Box, @ptrCast(@alignCast(raw))));
            }
        }.destroy,
        .eql_fn = struct {
            fn eql(left: *const anyopaque, right: *const anyopaque) bool {
                const a: *const Box = @ptrCast(@alignCast(left));
                const b: *const Box = @ptrCast(@alignCast(right));
                return std.meta.eql(a.value, b.value);
            }
        }.eql,
    };
}

pub const Dispatch = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(Handler) = .empty,

    const Handler = struct {
        tag: u64,
        ctx: *anyopaque,
        callback: *const anyopaque,
        invoke: *const fn (*anyopaque, *const anyopaque, *const Action) void,
    };

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *@This()) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn bind(self: *@This(), comptime T: type, ctx: *anyopaque, callback: *const fn (*anyopaque, *const T) void) ActionError!void {
        try self.handlers.append(self.allocator, .{ .tag = typeTag(T), .ctx = ctx, .invoke = struct {
            fn invoke(raw_ctx: *anyopaque, raw_callback: *const anyopaque, action: *const Action) void {
                const typed_callback: *const fn (*anyopaque, *const T) void = @ptrCast(@alignCast(raw_callback));
                typed_callback(raw_ctx, &(@as(*const T, @ptrCast(@alignCast(action.payload))).*));
            }
        }.invoke, .callback = @ptrCast(callback) });
    }

    pub fn dispatch(self: *const @This(), action: *const Action) bool {
        for (self.handlers.items) |handler| if (handler.tag == action.type_tag) {
            handler.invoke(handler.ctx, handler.callback, action);
            return true;
        };
        return false;
    }
};

test "typed actions clone compare and dispatch without macros" {
    const A = struct { count: u8 };
    var action = try make(A, std.testing.allocator, .{ .count = 3 });
    defer action.deinit(std.testing.allocator);
    var copy = try action.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expect(action.eql(&copy));
    var seen: u8 = 0;
    var dispatch = Dispatch.init(std.testing.allocator);
    defer dispatch.deinit();
    try dispatch.bind(A, @ptrCast(&seen), struct {
        fn run(ctx: *anyopaque, value: *const A) void {
            @as(*u8, @ptrCast(@alignCast(ctx))).* = value.count;
        }
    }.run);
    try std.testing.expect(dispatch.dispatch(&action));
    try std.testing.expectEqual(@as(u8, 3), seen);
}
