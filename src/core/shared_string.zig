const std = @import("std");

/// An immutable, allocator-owned string. ZUI state is foreground-thread owned,
/// so cloning is explicit and no atomic reference count is needed.
pub const SharedString = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, value: []const u8) !SharedString {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, value),
        };
    }

    pub fn clone(self: SharedString) !SharedString {
        return init(self.allocator, self.bytes);
    }

    pub fn release(self: SharedString) void {
        self.allocator.free(self.bytes);
    }

    pub fn slice(self: SharedString) []const u8 {
        return self.bytes;
    }
};

pub fn string(allocator: std.mem.Allocator, value: []const u8) !SharedString {
    return SharedString.init(allocator, value);
}

test "shared string owns its bytes" {
    var value = try SharedString.init(std.testing.allocator, "tasks");
    defer value.release();
    try std.testing.expectEqualStrings("tasks", value.slice());

    var copy = try value.clone();
    defer copy.release();
    try std.testing.expectEqualStrings(value.slice(), copy.slice());
}
