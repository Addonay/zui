const std = @import("std");

/// A small ArcCow-style value for foreground-owned ZUI state.
///
/// Borrowed values do not allocate. Owned values are reference counted and
/// shared by clones; `write` detaches when another clone still observes the
/// value. `T` is intentionally a value type: callers that store pointers or
/// slices in `T` remain responsible for cloning the pointee themselves.
pub fn ArcCow(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = struct {
            refs: std.atomic.Value(usize),
            allocator: std.mem.Allocator,
            value: T,
        };

        borrowed: ?*const T = null,
        owned: ?*State = null,
        borrowed_allocator: std.mem.Allocator = std.heap.page_allocator,

        pub fn initBorrowed(value: *const T) Self {
            return .{ .borrowed = value };
        }

        pub fn initBorrowedWithAllocator(allocator: std.mem.Allocator, value: *const T) Self {
            return .{ .borrowed = value, .borrowed_allocator = allocator };
        }

        pub fn initOwned(allocator: std.mem.Allocator, value: T) !Self {
            const state = try allocator.create(State);
            state.* = .{
                .refs = std.atomic.Value(usize).init(1),
                .allocator = allocator,
                .value = value,
            };
            return .{ .owned = state };
        }

        pub fn clone(self: *const Self) Self {
            if (self.owned) |state| {
                _ = state.refs.fetchAdd(1, .monotonic);
                return .{ .owned = state };
            }
            return .{ .borrowed = self.borrowed.?, .borrowed_allocator = self.borrowed_allocator };
        }

        pub fn read(self: *const Self) *const T {
            if (self.owned) |state| return &state.value;
            return self.borrowed.?;
        }

        /// Returns mutable access, detaching from any other owned clone.
        pub fn write(self: *Self) !*T {
            if (self.owned) |state| {
                if (state.refs.load(.acquire) == 1) return &state.value;

                const replacement = try Self.initOwned(state.allocator, state.value);
                _ = state.refs.fetchSub(1, .acq_rel);
                self.* = replacement;
                return &self.owned.?.value;
            }

            const replacement = try Self.initOwned(self.borrowed_allocator, self.borrowed.?.*);
            self.* = replacement;
            return &self.owned.?.value;
        }

        pub fn isBorrowed(self: *const Self) bool {
            return self.owned == null;
        }

        pub fn isShared(self: *const Self) bool {
            return if (self.owned) |state| state.refs.load(.acquire) > 1 else false;
        }

        pub fn deinit(self: *Self) void {
            if (self.owned) |state| {
                if (state.refs.fetchSub(1, .acq_rel) == 1) state.allocator.destroy(state);
            }
            self.* = undefined;
        }
    };
}

test "ArcCow borrows without allocation and detaches on write" {
    const Cow = ArcCow(u32);
    var source: u32 = 7;
    var borrowed = Cow.initBorrowedWithAllocator(std.testing.allocator, &source);
    defer borrowed.deinit();
    try std.testing.expect(borrowed.isBorrowed());
    source = 8;
    try std.testing.expectEqual(@as(u32, 8), borrowed.read().*);

    const detached = try borrowed.write();
    detached.* = 9;
    try std.testing.expectEqual(@as(u32, 8), source);
    try std.testing.expectEqual(@as(u32, 9), borrowed.read().*);
    try std.testing.expect(!borrowed.isBorrowed());
}

test "ArcCow shares owned state then copies before mutation" {
    const Cow = ArcCow(u32);
    var first = try Cow.initOwned(std.testing.allocator, 11);
    defer first.deinit();
    var second = first.clone();
    defer second.deinit();
    try std.testing.expect(first.isShared());

    const value = try second.write();
    value.* = 12;
    try std.testing.expectEqual(@as(u32, 11), first.read().*);
    try std.testing.expectEqual(@as(u32, 12), second.read().*);
}

test "ArcCow compares through its visible value" {
    const Cow = ArcCow([]const u8);
    var a = try Cow.initOwned(std.testing.allocator, "same");
    defer a.deinit();
    var source: []const u8 = "same";
    var b = Cow.initBorrowed(&source);
    defer b.deinit();
    try std.testing.expectEqualStrings(a.read().*, b.read().*);
}
