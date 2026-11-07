//! Heap-owned mapping state. The ticket and callback each own a reference, so
//! abandoning a ticket cannot leave WebGPU holding a pointer to a stack frame.
const std = @import("std");
const sdk = @import("sdk.zig");

pub const Pending = struct {
    allocator: std.mem.Allocator,
    procs: sdk.Procs,
    device: sdk.Device,
    device_poll: ?sdk.DevicePollFn,
    instance: ?sdk.Instance = null,
    wait_any: ?sdk.InstanceWaitAnyFn = null,
    wait_timeout_ns: u64 = 0,
    future: sdk.Future = .{},
    buffer: sdk.Buffer,
    mapped_size: usize,
    data: []u8,
    /// Tickets own their result. Blocking reads borrow the caller's storage;
    /// only poll copies into it, never the callback or backend retirement.
    owns_data: bool = true,
    offset: usize = 0,
    row_bytes: usize = 0,
    source_row: usize = 0,
    source_slice: usize = 0,
    target_row: usize = 0,
    target_slice: usize = 0,
    rows: usize = 1,
    slices: usize = 1,
    refs: std.atomic.Value(u32) = .init(1),
    done: std.atomic.Value(bool) = .init(false),
    status: u32 = 0,
    copied: bool = false,
    tracked: bool = false,
    callback_finished: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Pending) void {
        _ = self.refs.fetchAdd(1, .monotonic);
        self.future = self.procs.wgpuBufferMapAsync(self.buffer, 1, 0, self.mapped_size, .{
            .mode = 3,
            .callback = mapped,
            .userdata1 = self,
        });
    }

    fn mapped(status: u32, _: sdk.StringView, userdata: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *Pending = @ptrCast(@alignCast(userdata.?));
        self.status = status;
        self.done.store(true, .release);
        if (self.tracked) {
            // The backend retains a reference until this final notification.
            self.release();
            self.callback_finished.store(true, .release);
        } else self.release();
    }

    /// Non-blocking: null means the caller must return to the event loop.
    pub fn poll(self: *Pending) error{ReadFailed}!?[]const u8 {
        if (self.device_poll) |poll_device| _ = poll_device(self.device, 0, null);
        if (!self.done.load(.acquire)) {
            if (self.device_poll == null) if (self.wait_any) |wait_any| {
                var info: sdk.FutureWaitInfo = .{ .future = self.future };
                if (wait_any(self.instance, 1, @ptrCast(&info), 0) == 3) return error.ReadFailed;
            };
            if (!self.done.load(.acquire)) return null;
        }
        if (self.status != 1) return error.ReadFailed;
        if (!self.copied) {
            const source: [*]const u8 = @ptrCast(self.procs.wgpuBufferGetConstMappedRange(self.buffer, 0, self.mapped_size) orelse return error.ReadFailed);
            if (self.row_bytes == 0) {
                @memcpy(self.data, source[self.offset..][0..self.data.len]);
            } else {
                for (0..self.slices) |slice| for (0..self.rows) |row| {
                    const from = slice * self.source_slice + row * self.source_row;
                    const to = slice * self.target_slice + row * self.target_row;
                    @memcpy(self.data[to..][0..self.row_bytes], source[from..][0..self.row_bytes]);
                };
            }
            self.copied = true;
        }
        return self.data;
    }

    pub fn release(self: *Pending) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.status == 1) self.procs.wgpuBufferUnmap(self.buffer);
        self.procs.wgpuBufferRelease(self.buffer);
        if (self.owns_data) self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};
