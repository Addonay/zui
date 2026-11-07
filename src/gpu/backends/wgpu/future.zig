//! Owned native error-scope result. Caller, backend and callback hold references;
//! completion is delivered before the backend may release the driver's lifetime.
const std = @import("std");
const sdk = @import("sdk.zig");
pub const ScopeResult = struct {
    allocator: std.mem.Allocator,
    future: sdk.Future = .{},
    refs: std.atomic.Value(u32) = .init(2),
    finished: std.atomic.Value(bool) = .init(false),
    status: u32 = 0,
    error_type: u32 = 0,
    message: [1024:0]u8 = @splat(0),
    pub fn completed(status: u32, error_type: u32, text: sdk.StringView, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *ScopeResult = @ptrCast(@alignCast(data.?));
        self.status = status;
        self.error_type = error_type;
        if (text.data) |source| {
            const length = @min(if (text.length == std.math.maxInt(usize)) std.mem.len(@as([*:0]const u8, @ptrCast(source))) else text.length, 1023);
            @memcpy(self.message[0..length], source[0..length]);
        }
        self.release(); // the backend reference keeps self alive through publication
        self.finished.store(true, .release);
    }
    pub fn release(self: *ScopeResult) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};
