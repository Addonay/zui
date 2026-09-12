//! Texture -> buffer -> host readback for offscreen verification.
//!
//! Port of the readback shape in `vello_gpu` plus the `.ports/wgpu`
//! `examples/offscreen.zig` loop: copy into a `MapRead | CopyDst` buffer whose
//! row stride is padded to `COPY_BYTES_PER_ROW_ALIGNMENT`, map asynchronously,
//! pump `wgpuDevicePoll`, copy the rows out (dropping the padding), then
//! unmap. Every intermediate handle is released before returning.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const device = @import("device.zig");

pub const Error = device.Error || error{
    MapFailed,
    MappedRangeFailed,
    BufferCreationFailed,
};

/// WebGPU requires `bytesPerRow` in a texel copy to be a multiple of 256.
pub const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256;

/// Padded row stride for a `width`-pixel `Rgba8Unorm` texture.
pub fn bytesPerRow(width: u32) u32 {
    return std.mem.alignForward(u32, width * 4, COPY_BYTES_PER_ROW_ALIGNMENT);
}

/// Userdata for `wgpuBufferMapAsync`; in this wgpu-native revision the callback
/// is delivered during `wgpuDevicePoll`.
const MapState = struct {
    status: c.WGPUMapAsyncStatus = c.WGPUMapAsyncStatus_Error,
    ok: bool = false,

    fn onCallback(
        status: c.WGPUMapAsyncStatus,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *MapState = @ptrCast(@alignCast(userdata1 orelse return));
        self.status = status;
        self.ok = status == c.WGPUMapAsyncStatus_Success;
        if (!self.ok) {
            std.debug.print("buffer map failed: status={d} message=\"{s}\"\n", .{
                status, device.messageSlice(message),
            });
        }
    }
};

/// Read a `width` x `height` `Rgba8Unorm` texture back to tightly packed
/// RGBA8 bytes. The caller owns the returned slice.
pub fn readTexture(
    allocator: std.mem.Allocator,
    dev: *device.Device,
    texture: c.WGPUTexture,
    width: u32,
    height: u32,
) Error![]u8 {
    if (dev.isLost()) return error.DeviceLost;
    if (width == 0 or height == 0) return error.TextureTooLarge;

    const row_stride = bytesPerRow(width);
    const buffer_size: u64 = @as(u64, row_stride) * height;

    dev.pushErrorScope(c.WGPUErrorFilter_Validation);
    var scope_open = true;
    errdefer if (scope_open) {
        // `wgpuDevicePopErrorScope` removes the scope even when its own
        // callback reports failure, so a successful pop clears `scope_open`
        // before the returned error is propagated.
        _ = dev.popErrorScope() catch {};
    };

    var buffer_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    buffer_desc.label = wgpu.stringView("vellz-gpu-readback");
    buffer_desc.size = buffer_size;
    buffer_desc.usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst;
    const buffer = c.wgpuDeviceCreateBuffer(dev.handle, &buffer_desc) orelse {
        return error.BufferCreationFailed;
    };
    defer c.wgpuBufferRelease(buffer);

    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("vellz-gpu-readback-encoder");
    const encoder = c.wgpuDeviceCreateCommandEncoder(dev.handle, &encoder_desc) orelse {
        return error.BufferCreationFailed;
    };
    defer c.wgpuCommandEncoderRelease(encoder);

    var source = c.WGPUTexelCopyTextureInfo{
        .texture = texture,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = c.WGPUTextureAspect_All,
    };
    var destination = c.WGPUTexelCopyBufferInfo{
        .layout = .{
            .offset = 0,
            .bytesPerRow = row_stride,
            .rowsPerImage = height,
        },
        .buffer = buffer,
    };
    var copy_size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &destination, &copy_size);

    var command_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_desc.label = wgpu.stringView("vellz-gpu-readback-commands");
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_desc) orelse {
        return error.BufferCreationFailed;
    };
    defer c.wgpuCommandBufferRelease(command_buffer);
    c.wgpuQueueSubmit(dev.queue, 1, &command_buffer);

    // The validation scope covers buffer creation + copy encoding.
    const scope_result = dev.popErrorScope();
    scope_open = false;
    try scope_result;

    var map_state = MapState{};
    _ = c.wgpuBufferMapAsync(buffer, c.WGPUMapMode_Read, 0, buffer_size, .{
        .callback = &MapState.onCallback,
        .userdata1 = &map_state,
    });
    _ = c.wgpuDevicePoll(dev.handle, 1, null);
    if (!map_state.ok) return error.MapFailed;

    const mapped = c.wgpuBufferGetMappedRange(buffer, 0, buffer_size) orelse {
        return error.MappedRangeFailed;
    };
    const mapped_bytes: [*]const u8 = @ptrCast(mapped);
    defer c.wgpuBufferUnmap(buffer);

    const result = allocator.alloc(u8, @as(usize, width) * height * 4) catch return error.OutOfMemory;
    errdefer allocator.free(result);
    const tight_stride = width * 4;
    for (0..height) |row| {
        const source_offset = row * row_stride;
        const dest_offset = row * tight_stride;
        @memcpy(
            result[dest_offset..][0..tight_stride],
            mapped_bytes[source_offset..][0..tight_stride],
        );
    }
    return result;
}

test "readback row stride is 256-byte aligned" {
    try std.testing.expectEqual(@as(u32, 256), bytesPerRow(64));
    try std.testing.expectEqual(@as(u32, 256), bytesPerRow(1));
    try std.testing.expectEqual(@as(u32, 512), bytesPerRow(65));
    try std.testing.expectEqual(@as(u32, 0), bytesPerRow(0));
}
