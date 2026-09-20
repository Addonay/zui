const std = @import("std");
const backend = @import("render_backend");

pub fn main() !void {
    const selection = backend.select(.wgpu, true, true, true);
    if (selection.active != .wgpu) return error.GpuSelectionFailed;
    var controller = backend.Controller.init(selection, 320, 240);
    controller.setMinimized(true);
    if (controller.beginFrame() != null) return error.MinimizedSubmission;
    controller.setMinimized(false);
    if (controller.beginFrame() == null) return error.FrameWasNotStarted;
    std.debug.print("PASS: renderer selection active={s} minimized-skip={d}\n", .{ @tagName(controller.selection.active), controller.skipped });
}
