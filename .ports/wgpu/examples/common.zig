//! Small helpers shared by the verification examples.
//!
//! This file is example support code, not part of the package API. It keeps
//! the examples focused on the raw C API calls.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;

/// Borrow the bytes of a `WGPUStringView`. Valid only while the string's owner
/// keeps the data alive (for API-owned strings: until the owning object is
/// released or the next blocking call).
pub fn messageSlice(message: c.WGPUStringView) []const u8 {
    if (message.data == null) return "";
    if (message.length == c.WGPU_STRLEN) {
        const data: [*:0]const u8 = @ptrCast(message.data);
        return std.mem.span(data);
    }
    const data: [*]const u8 = @ptrCast(message.data);
    return data[0..message.length];
}

pub fn installLogging(level: c.WGPULogLevel) void {
    c.wgpuSetLogCallback(&logCallback, null);
    c.wgpuSetLogLevel(level);
}

fn logCallback(level: c.WGPULogLevel, message: c.WGPUStringView, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const name = switch (level) {
        c.WGPULogLevel_Error => "error",
        c.WGPULogLevel_Warn => "warn",
        c.WGPULogLevel_Info => "info",
        c.WGPULogLevel_Debug => "debug",
        c.WGPULogLevel_Trace => "trace",
        else => "log",
    };
    std.debug.print("[wgpu-native/{s}] {s}\n", .{ name, messageSlice(message) });
}

pub fn backendName(backend: c.WGPUBackendType) []const u8 {
    return switch (backend) {
        c.WGPUBackendType_Undefined => "undefined",
        c.WGPUBackendType_Null => "null",
        c.WGPUBackendType_WebGPU => "webgpu",
        c.WGPUBackendType_D3D11 => "d3d11",
        c.WGPUBackendType_D3D12 => "d3d12",
        c.WGPUBackendType_Metal => "metal",
        c.WGPUBackendType_Vulkan => "vulkan",
        c.WGPUBackendType_OpenGL => "opengl",
        c.WGPUBackendType_OpenGLES => "opengles",
        else => "unknown",
    };
}

pub fn adapterTypeName(adapter_type: c.WGPUAdapterType) []const u8 {
    return switch (adapter_type) {
        c.WGPUAdapterType_DiscreteGPU => "discrete-gpu",
        c.WGPUAdapterType_IntegratedGPU => "integrated-gpu",
        c.WGPUAdapterType_CPU => "cpu",
        c.WGPUAdapterType_Unknown => "unknown",
        else => "unknown",
    };
}

pub fn printAdapterInfo(info: *const c.WGPUAdapterInfo) void {
    std.debug.print(
        "adapter: description=\"{s}\" device=\"{s}\" vendor=\"{s}\" architecture=\"{s}\"\n",
        .{
            messageSlice(info.description),
            messageSlice(info.device),
            messageSlice(info.vendor),
            messageSlice(info.architecture),
        },
    );
    std.debug.print(
        "adapter: backend={s} type={s} execution={s} vendorID=0x{x} deviceID=0x{x}\n",
        .{
            backendName(info.backendType),
            adapterTypeName(info.adapterType),
            executionKind(info.adapterType),
            info.vendorID,
            info.deviceID,
        },
    );
}

/// Distinguishes real hardware from a software rasterizer such as SwiftShader
/// or Mesa's lavapipe.
pub fn executionKind(adapter_type: c.WGPUAdapterType) []const u8 {
    return switch (adapter_type) {
        c.WGPUAdapterType_DiscreteGPU, c.WGPUAdapterType_IntegratedGPU => "hardware",
        c.WGPUAdapterType_CPU => "software-adapter",
        else => "unknown",
    };
}

/// Userdata and callback for `wgpuInstanceRequestAdapter`. In this wgpu-native
/// revision the callback runs synchronously inside the request call; the
/// stored handle is owned by us and must be released.
pub const AdapterQuery = struct {
    adapter: c.WGPUAdapter = null,
    ok: bool = false,

    pub fn onCallback(
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
            self.ok = true;
        } else {
            std.debug.print("request_adapter failed: status={d} message=\"{s}\"\n", .{
                status, messageSlice(message),
            });
        }
    }
};

/// Userdata and callback for `wgpuAdapterRequestDevice`.
pub const DeviceQuery = struct {
    device: c.WGPUDevice = null,
    ok: bool = false,

    pub fn onCallback(
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
            self.ok = true;
        } else {
            std.debug.print("request_device failed: status={d} message=\"{s}\"\n", .{
                status, messageSlice(message),
            });
        }
    }
};

/// Tracks errors surfaced through the device's uncaptured-error callback.
/// The tracker must outlive the device. Errors are delivered during
/// `wgpuDevicePoll`.
pub const ErrorTracker = struct {
    count: usize = 0,
    last_type: c.WGPUErrorType = c.WGPUErrorType_NoError,
    last_message: [512]u8 = undefined,
    last_message_len: usize = 0,

    pub fn onUncaptured(
        device: [*c]const c.WGPUDevice,
        error_type: c.WGPUErrorType,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = device;
        _ = userdata2;
        const self: *ErrorTracker = @ptrCast(@alignCast(userdata1 orelse return));
        self.count += 1;
        self.last_type = error_type;
        const text = messageSlice(message);
        const n = @min(text.len, self.last_message.len);
        @memcpy(self.last_message[0..n], text[0..n]);
        self.last_message_len = n;
    }

    pub fn last(this: *const ErrorTracker) []const u8 {
        return this.last_message[0..this.last_message_len];
    }
};

/// Result of a push/pop error scope round trip.
pub const ErrorScopeResult = struct {
    status: c.WGPUPopErrorScopeStatus = c.WGPUPopErrorScopeStatus_Error,
    error_type: c.WGPUErrorType = c.WGPUErrorType_NoError,
    message: [512]u8 = undefined,
    message_len: usize = 0,

    pub fn onPop(
        status: c.WGPUPopErrorScopeStatus,
        error_type: c.WGPUErrorType,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *ErrorScopeResult = @ptrCast(@alignCast(userdata1 orelse return));
        self.status = status;
        self.error_type = error_type;
        const text = messageSlice(message);
        const n = @min(text.len, self.message.len);
        @memcpy(self.message[0..n], text[0..n]);
        self.message_len = n;
    }

    pub fn messageSliceOf(this: *const ErrorScopeResult) []const u8 {
        return this.message[0..this.message_len];
    }
};

/// Userdata and callback for `wgpuBufferMapAsync`.
pub const MapState = struct {
    status: c.WGPUMapAsyncStatus = c.WGPUMapAsyncStatus_Error,
    ok: bool = false,

    pub fn onCallback(
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
                status, messageSlice(message),
            });
        }
    }
};
