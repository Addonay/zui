//! Explicit refinement values and cascades, equivalent to GPUI's safe
//! `Refineable` semantics without a derive macro.

const std = @import("std");

pub fn Refinement(comptime T: type) type {
    return struct {
        value: ?T = null,
        pub fn set(value: T) @This() {
            return .{ .value = value };
        }
        pub fn isEmpty(self: @This()) bool {
            return self.value == null;
        }
        pub fn refine(self: *@This(), other: @This()) void {
            if (other.value) |value| self.value = value;
        }
        pub fn resolve(self: @This(), fallback: T) T {
            return self.value orelse fallback;
        }
    };
}

pub fn Cascade(comptime T: type) type {
    const R = Refinement(T);
    return struct {
        slots: std.ArrayList(?R) = .empty,
        allocator: std.mem.Allocator,
        pub fn init(allocator: std.mem.Allocator) !@This() {
            var result = @This(){ .allocator = allocator };
            try result.slots.append(allocator, R{});
            return result;
        }
        pub fn deinit(self: *@This()) void {
            self.slots.deinit(self.allocator);
        }
        pub fn reserve(self: *@This()) !usize {
            try self.slots.append(self.allocator, null);
            return self.slots.items.len - 1;
        }
        pub fn set(self: *@This(), slot: usize, value: ?R) error{InvalidSlot}!void {
            if (slot >= self.slots.items.len) return error.InvalidSlot;
            self.slots.items[slot] = value;
        }
        pub fn merged(self: *const @This()) R {
            var result = self.slots.items[0].?;
            for (self.slots.items[1..]) |slot| if (slot) |value| result.refine(value);
            return result;
        }
    };
}

test "refinements cascade with later values winning" {
    const R = Refinement(u8);
    var cascade = try Cascade(u8).init(std.testing.allocator);
    defer cascade.deinit();
    const later = try cascade.reserve();
    try cascade.set(0, R.set(1));
    try cascade.set(later, R.set(2));
    try std.testing.expectEqual(@as(u8, 2), cascade.merged().resolve(0));
}
