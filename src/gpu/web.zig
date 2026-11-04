//! Browser ABI helpers for freestanding wasm hosts. The JavaScript bridge lives
//! in tools/web/gl.js; context creation and presentation remain application-owned.
const std = @import("std");
const Dispatch = @import("backends/gl/dispatch.zig").Dispatch;

pub fn glProcAddress(name: [:0]const u8, _: ?*anyopaque) ?*const anyopaque {
    inline for (@typeInfo(Dispatch).@"struct".field_names) |field| {
        const symbol = comptime "gl" ++ .{std.ascii.toUpper(field[0])} ++ field[1..];
        if (std.mem.eql(u8, name, symbol)) {
            const T = @typeInfo(@FieldType(Dispatch, field)).optional.child;
            return @ptrCast(@extern(T, .{ .name = symbol, .library_name = "gl" }));
        }
    }
    return null;
}

const sdk = @import("backends/wgpu/sdk.zig");

/// Imports webgpu.h entry points from the host's `webgpu` namespace.
pub fn wgpuProcAddress(name: [:0]const u8, _: ?*anyopaque) ?*const anyopaque {
    inline for (@typeInfo(sdk.Procs).@"struct".field_names) |field| {
        if (std.mem.eql(u8, name, field)) return @ptrCast(@extern(@FieldType(sdk.Procs, field), .{ .name = field, .library_name = "webgpu" }));
    }
    return null; // wgpuDevicePoll is deliberately absent in browsers
}

fn shortName(comptime T: type) []const u8 {
    const name = @typeName(T);
    return name[(std.mem.lastIndexOfScalar(u8, name, '.') orelse return name) + 1 ..];
}
fn fieldKind(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional, .pointer => "u32",
        .int, .float => @typeName(T),
        .@"struct" => "struct:" ++ shortName(T),
        .@"enum" => "enum:" ++ shortName(T),
        else => @compileError("unsupported webgpu.h ABI field: " ++ @typeName(T)),
    };
}

/// Generated on the wasm target: offsets, sizes, field kinds and enum values
/// are taken from the exact declarations used by the backend, never hardcoded JS.
pub const wgpu_layout = blk: {
    @setEvalBranchQuota(2_000_000);
    var json: []const u8 = "{";
    var comma: []const u8 = "";
    for (@typeInfo(sdk).@"struct".decl_names) |name| {
        const decl = @field(sdk, name);
        if (@TypeOf(decl) != type) continue;
        switch (@typeInfo(decl)) {
            .@"struct" => |info| {
                if (info.layout != .@"extern") continue;
                json = json ++ comma ++ "\"" ++ name ++ "\":{\"size\":" ++ std.fmt.comptimePrint("{d}", .{@sizeOf(decl)}) ++ ",\"fields\":[";
                var field_comma: []const u8 = "";
                for (info.field_names, info.field_types) |field, T| {
                    json = json ++ field_comma ++ std.fmt.comptimePrint("[\"{s}\",{d},\"{s}\"]", .{ field, @offsetOf(decl, field), fieldKind(T) });
                    field_comma = ",";
                }
                json = json ++ "]}";
                comma = ",";
            },
            .@"enum" => |info| {
                json = json ++ comma ++ "\"" ++ name ++ "\":{\"enum\":{";
                var field_comma: []const u8 = "";
                for (info.field_names) |field| {
                    json = json ++ field_comma ++ std.fmt.comptimePrint("\"{d}\":\"{s}\"", .{ @backingInt(@field(decl, field)), field });
                    field_comma = ",";
                }
                json = json ++ "}}";
                comma = ",";
            },
            else => {},
        }
    }
    break :blk json ++ "}";
};

/// For the host's mapAsync promise handler. Export a wrapper with these four
/// integer arguments; callback signatures stay coupled to the pinned webgpu.h ABI.
pub fn dispatchMapCallback(callback: usize, status: u32, user1: usize, user2: usize) void {
    const function: sdk.BufferMapCallback = @ptrFromInt(callback);
    function(status, .{}, if (user1 == 0) null else @ptrFromInt(user1), if (user2 == 0) null else @ptrFromInt(user2));
}
