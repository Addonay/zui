//! Bounded three-lane priority sender/receiver queues.

const std = @import("std");

pub const Priority = enum { high, medium, low };
pub const SendError = error{ Closed, Full, OutOfMemory };
pub const RecvError = error{Closed};

pub fn PriorityQueueSender(comptime T: type) type {
    return PriorityQueue(T).Sender;
}

pub fn PriorityQueueReceiver(comptime T: type) type {
    return PriorityQueue(T).Receiver;
}

pub fn PriorityQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = struct {
            allocator: std.mem.Allocator,
            mutex: std.atomic.Mutex = .unlocked,
            queues: [3]std.ArrayList(T) = .{ .empty, .empty, .empty },
            capacity: usize,
            senders: usize = 1,
            receivers: usize = 1,
        };

        pub const Sender = struct {
            state: *State,
            pub fn clone(self: @This()) @This() {
                lock(&self.state.mutex);
                defer self.state.mutex.unlock();
                self.state.senders += 1;
                return .{ .state = self.state };
            }
            pub fn send(self: @This(), priority: Priority, value: T) SendError!void {
                lock(&self.state.mutex);
                defer self.state.mutex.unlock();
                if (self.state.receivers == 0) return error.Closed;
                if (lenLocked(self.state) >= self.state.capacity) return error.Full;
                try self.state.queues[@backingInt(priority)].append(self.state.allocator, value);
            }
            pub fn deinit(self: *@This()) void {
                lock(&self.state.mutex);
                self.state.senders -= 1;
                const destroy = self.state.senders == 0 and self.state.receivers == 0;
                self.state.mutex.unlock();
                if (destroy) destroyState(self.state);
                self.* = undefined;
            }
        };

        pub const Receiver = struct {
            state: *State,
            pub fn clone(self: @This()) @This() {
                lock(&self.state.mutex);
                defer self.state.mutex.unlock();
                self.state.receivers += 1;
                return .{ .state = self.state };
            }
            pub fn tryPop(self: @This()) RecvError!?T {
                lock(&self.state.mutex);
                defer self.state.mutex.unlock();
                if (lenLocked(self.state) == 0 and self.state.senders == 0) return error.Closed;
                return popLocked(self.state);
            }
            pub fn pop(self: @This()) RecvError!T {
                while (true) {
                    lock(&self.state.mutex);
                    if (lenLocked(self.state) != 0 or self.state.senders == 0) break;
                    self.state.mutex.unlock();
                    std.Thread.yield() catch {};
                }
                defer self.state.mutex.unlock();
                if (lenLocked(self.state) == 0) return error.Closed;
                return popLocked(self.state).?;
            }
            pub fn len(self: @This()) usize {
                lock(&self.state.mutex);
                defer self.state.mutex.unlock();
                return lenLocked(self.state);
            }
            pub fn deinit(self: *@This()) void {
                lock(&self.state.mutex);
                self.state.receivers -= 1;
                const destroy = self.state.senders == 0 and self.state.receivers == 0;
                self.state.mutex.unlock();
                if (destroy) destroyState(self.state);
                self.* = undefined;
            }
        };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !struct { sender: Sender, receiver: Receiver } {
            if (capacity == 0) return error.InvalidCapacity;
            const state = try allocator.create(State);
            state.* = .{ .allocator = allocator, .capacity = capacity };
            return .{ .sender = .{ .state = state }, .receiver = .{ .state = state } };
        }

        fn lock(mutex: *std.atomic.Mutex) void {
            while (!mutex.tryLock()) std.Thread.yield() catch {};
        }

        fn lenLocked(state: *State) usize {
            var n: usize = 0;
            for (state.queues) |q| n += q.items.len;
            return n;
        }
        fn popLocked(state: *State) ?T {
            var i: usize = 0;
            while (i < 3) : (i += 1) if (state.queues[i].items.len != 0) return state.queues[i].orderedRemove(0);
            return null;
        }
        fn destroyState(state: *State) void {
            for (&state.queues) |*q| q.deinit(state.allocator);
            state.allocator.destroy(state);
        }
    };
}

test "bounded priority queue preserves priority and closes" {
    const Q = PriorityQueue(u8);
    var pair = try Q.init(std.testing.allocator, 2);
    defer pair.receiver.deinit();
    try pair.sender.send(.low, 1);
    try pair.sender.send(.high, 2);
    try std.testing.expectError(error.Full, pair.sender.send(.medium, 3));
    try std.testing.expectEqual(@as(u8, 2), try pair.receiver.pop());
    try std.testing.expectEqual(@as(u8, 1), try pair.receiver.pop());
    pair.sender.deinit();
    try std.testing.expectError(error.Closed, pair.receiver.pop());
}
