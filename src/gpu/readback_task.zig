//! Backend-neutral ownership of fence-driven native readbacks. Only the owning
//! thread manipulates tickets; the device keeps cancelled tasks until GPU completion.
const std = @import("std");
const core = @import("core.zig");
pub const Task = struct {
    owner: *core.State,
    allocator: std.mem.Allocator,
    data: []u8,
    refs: u32 = 2, // client and device retirement queue
    ready: bool = false,
    failed: bool = false,
    /// Return an error only after completion or confirmed removal. A healthy
    /// query failure must remain pending, so collection cannot free in-flight work.
    poll_fn: *const fn (*Task, bool) error{ReadFailed}!bool,
    destroy_fn: *const fn (*Task) void,
    pub fn poll(self: *Task, wait: bool) error{ReadFailed}!bool {
        if (self.failed) return error.ReadFailed;
        if (self.ready) return true;
        self.ready = self.poll_fn(self, wait) catch {
            self.failed = true;
            return error.ReadFailed;
        };
        return self.ready;
    }
    pub fn release(self: *Task) void {
        self.refs -= 1;
        if (self.refs == 0) self.destroy_fn(self);
    }
};
pub fn collect(state: *core.State, wait: bool) void {
    var i: usize = 0;
    while (i < state.readbacks.items.len) {
        const task = state.readbacks.items[i];
        if (!(task.poll(wait) catch true)) {
            if (wait) {
                std.atomic.spinLoopHint();
                continue;
            }
            i += 1;
            continue;
        }
        if (wait) std.debug.assert(task.refs == 1); // release tickets before Device.deinit
        task.release();
        _ = state.readbacks.swapRemove(i);
    }
}
pub fn prepare(state: *core.State) !void {
    collect(state, false);
    try state.readbacks.ensureUnusedCapacity(state.allocator, 1);
}
pub fn register(state: *core.State, task: *Task) void {
    state.readbacks.appendAssumeCapacity(task);
}
