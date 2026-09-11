//! Minimal consumer of the wgpu package: creates an instance, selects an
//! adapter, reports it, creates a device, creates and releases one buffer, and
//! shuts everything down. This proves the package can be imported and linked
//! from an independent build.zig, not just from the package's own examples.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;

const AdapterQuery = struct {
    adapter: c.WGPUAdapter = null,

    fn callback(
        status: c.WGPURequestAdapterStatus,
        adapter: c.WGPUAdapter,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *AdapterQuery = @ptrCast(@alignCast(userdata1 orelse return));
        if (status == c.WGPURequestAdapterStatus_Success) {
            self.adapter = adapter;
        } else {
            std.debug.print("consumer: request_adapter failed ({d}): {s}\n", .{
                status, messageToSlice(message),
            });
        }
    }
};

const DeviceQuery = struct {
    device: c.WGPUDevice = null,

    fn callback(
        status: c.WGPURequestDeviceStatus,
        device: c.WGPUDevice,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *DeviceQuery = @ptrCast(@alignCast(userdata1 orelse return));
        if (status == c.WGPURequestDeviceStatus_Success) {
            self.device = device;
        } else {
            std.debug.print("consumer: request_device failed ({d}): {s}\n", .{
                status, messageToSlice(message),
            });
        }
    }
};

fn messageToSlice(message: c.WGPUStringView) []const u8 {
    if (message.data == null) return "";
    if (message.length == c.WGPU_STRLEN) {
        const data: [*:0]const u8 = @ptrCast(message.data);
        return std.mem.span(data);
    }
    const data: [*]const u8 = @ptrCast(message.data);
    return data[0..message.length];
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    const instance = c.wgpuCreateInstance(null) orelse return error.NoInstance;
    defer c.wgpuInstanceRelease(instance);

    var adapter_query = AdapterQuery{};
    _ = c.wgpuInstanceRequestAdapter(instance, null, .{
        .callback = &AdapterQuery.callback,
        .userdata1 = &adapter_query,
    });
    const adapter = adapter_query.adapter orelse return error.NoAdapter;
    defer c.wgpuAdapterRelease(adapter);

    var info = c.wgpu_zig_init_WGPUAdapterInfo();
    if (c.wgpuAdapterGetInfo(adapter, &info) != c.WGPUStatus_Success) return error.AdapterInfoFailed;
    defer c.wgpuAdapterInfoFreeMembers(info);
    std.debug.print("consumer: adapter \"{s}\" ({s}, {s})\n", .{
        messageToSlice(info.description),
        messageToSlice(info.device),
        switch (info.adapterType) {
            c.WGPUAdapterType_CPU => "software",
            c.WGPUAdapterType_DiscreteGPU, c.WGPUAdapterType_IntegratedGPU => "hardware",
            else => "unknown",
        },
    });

    var device_query = DeviceQuery{};
    _ = c.wgpuAdapterRequestDevice(adapter, null, .{
        .callback = &DeviceQuery.callback,
        .userdata1 = &device_query,
    });
    const device = device_query.device orelse return error.NoDevice;
    defer c.wgpuDeviceRelease(device);

    // The descriptor initializer comes from the generated upstream shims, and
    // ownership follows the raw C API: create then release.
    var buffer_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    buffer_desc.label = wgpu.stringView("consumer-buffer");
    buffer_desc.size = 4096;
    buffer_desc.usage = c.WGPUBufferUsage_CopySrc | c.WGPUBufferUsage_CopyDst;
    const buffer = c.wgpuDeviceCreateBuffer(device, &buffer_desc) orelse return error.NoBuffer;
    defer c.wgpuBufferRelease(buffer);

    _ = c.wgpuDevicePoll(device, 1, null);
    std.debug.print("consumer: PASS (instance, adapter, device and buffer created)\n", .{});
}
