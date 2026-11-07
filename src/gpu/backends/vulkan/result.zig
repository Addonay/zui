//! VkResult observation shared by resource, frame, memory and readback paths.
const core = @import("../../core.zig");
pub fn observe(result: i32) i32 {
    if (result == -4) core.recordLoss(result); // VK_ERROR_DEVICE_LOST
    return result;
}

/// An unexpected query error cannot prove completion on a healthy device.
pub const FenceProgress = enum { complete, pending, lost, retry };
pub fn fenceProgress(result: i32) FenceProgress {
    return switch (result) {
        0 => .complete,
        1, 2 => .pending,
        -4 => .lost,
        else => .retry,
    };
}
