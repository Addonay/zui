//! Device bootstrap for the wgpu-backed GPU backend (Apache-2.0 OR MIT).
//!
//! Port of the instance/adapter/device subset of
//! `vello_gpu/src/render/wgpu/mod.rs` plus the error policy from
//! `docs/gpu-m5-plan.md` §4:
//!
//! - `Instance` -> `Adapter` -> `Device`/`Queue` creation, offscreen only
//!   (no `WGPUSurface` anywhere).
//! - Error scopes wrap resource creation; the uncaptured-error callback and
//!   the device-lost callback store status + message on the device wrapper so
//!   later calls can return `error.DeviceLost` / `error.ValidationFailed`
//!   instead of silently continuing.
//! - `--force-adapter-failure` style requests (`AdapterOptions.force_failure`)
//!   return `error.NoAdapter`.
//!
//! The listener state lives behind a stable heap pointer: wgpu-native invokes
//! the callbacks with `userdata1`, and a `Device` value may be moved after
//! creation.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;

/// Error policy from `docs/gpu-m5-plan.md` §4. Every failure path in the
/// backend maps into this set (or a superset that includes it); there is no
/// silent CPU fallback.
pub const Error = error{
    NoInstance,
    NoAdapter,
    NoDevice,
    DeviceLost,
    ValidationFailed,
    OutOfMemory,
    UnsupportedCapability,
    TextureTooLarge,
    LimitReached,
    MissingTextureBinding,
    TextureFeedbackLoop,
    Unsupported,
};

/// Borrow the bytes of a `WGPUStringView` (API-owned string; valid until the
/// owning object is released or the next blocking call).
pub fn messageSlice(message: c.WGPUStringView) []const u8 {
    if (message.data == null) return "";
    if (message.length == c.WGPU_STRLEN) {
        const data: [*:0]const u8 = @ptrCast(message.data);
        return std.mem.span(data);
    }
    const data: [*]const u8 = @ptrCast(message.data);
    return data[0..message.length];
}

/// Copy a `WGPUStringView` into a fixed-capacity buffer, returning the length.
fn copyMessage(message: c.WGPUStringView, buffer: []u8) usize {
    const text = messageSlice(message);
    const n = @min(text.len, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    return n;
}

/// Adapter identity as reported by `wgpuAdapterGetInfo`, owned by value.
pub const AdapterInfo = struct {
    backend_type: c.WGPUBackendType = c.WGPUBackendType_Undefined,
    adapter_type: c.WGPUAdapterType = c.WGPUAdapterType_Unknown,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    vendor: [128]u8 = @splat(0),
    vendor_len: usize = 0,
    architecture: [128]u8 = @splat(0),
    architecture_len: usize = 0,
    device: [256]u8 = @splat(0),
    device_len: usize = 0,
    description: [256]u8 = @splat(0),
    description_len: usize = 0,

    pub fn vendorSlice(self: *const AdapterInfo) []const u8 {
        return self.vendor[0..self.vendor_len];
    }
    pub fn architectureSlice(self: *const AdapterInfo) []const u8 {
        return self.architecture[0..self.architecture_len];
    }
    pub fn deviceSlice(self: *const AdapterInfo) []const u8 {
        return self.device[0..self.device_len];
    }
    pub fn descriptionSlice(self: *const AdapterInfo) []const u8 {
        return self.description[0..self.description_len];
    }

    pub fn backendName(self: *const AdapterInfo) []const u8 {
        return switch (self.backend_type) {
            c.WGPUBackendType_Null => "null",
            c.WGPUBackendType_WebGPU => "webgpu",
            c.WGPUBackendType_D3D11 => "d3d11",
            c.WGPUBackendType_D3D12 => "d3d12",
            c.WGPUBackendType_Metal => "metal",
            c.WGPUBackendType_Vulkan => "vulkan",
            c.WGPUBackendType_OpenGL => "opengl",
            c.WGPUBackendType_OpenGLES => "opengles",
            else => "undefined",
        };
    }

    pub fn adapterTypeName(self: *const AdapterInfo) []const u8 {
        return switch (self.adapter_type) {
            c.WGPUAdapterType_DiscreteGPU => "discrete-gpu",
            c.WGPUAdapterType_IntegratedGPU => "integrated-gpu",
            c.WGPUAdapterType_CPU => "cpu",
            else => "unknown",
        };
    }

    /// Distinguishes real hardware from a software rasterizer such as
    /// lavapipe/llvmpipe or SwiftShader.
    pub fn executionKind(self: *const AdapterInfo) []const u8 {
        return switch (self.adapter_type) {
            c.WGPUAdapterType_DiscreteGPU, c.WGPUAdapterType_IntegratedGPU => "hardware",
            c.WGPUAdapterType_CPU => "software-adapter",
            else => "unknown",
        };
    }

    /// Print one `adapter: ...` block, matching the `.ports/wgpu` examples so
    /// the recorded adapter line is greppable.
    pub fn print(self: *const AdapterInfo) void {
        std.debug.print(
            "adapter: description=\"{s}\" device=\"{s}\" vendor=\"{s}\" architecture=\"{s}\"\n",
            .{ self.descriptionSlice(), self.deviceSlice(), self.vendorSlice(), self.architectureSlice() },
        );
        std.debug.print(
            "adapter: backend={s} type={s} execution={s} vendorID=0x{x} deviceID=0x{x}\n",
            .{ self.backendName(), self.adapterTypeName(), self.executionKind(), self.vendor_id, self.device_id },
        );
    }
};

/// Device limits read back from `wgpuDeviceGetLimits`.
pub const Limits = struct {
    /// Maximum width or height of a 2D texture.
    max_texture_dimension_2d: u32,

    /// Upstream caps intermediate data textures at 4096 in addition to the
    /// adapter limit (see the `MAX_RESOURCE_TEXTURE_DIMENSION_2D` comment in
    /// `render/common.rs`).
    pub const MAX_RESOURCE_TEXTURE_DIMENSION_2D: u32 = 4096;

    pub fn resourceTextureDimension2d(self: Limits) u32 {
        return @min(self.max_texture_dimension_2d, MAX_RESOURCE_TEXTURE_DIMENSION_2D);
    }
};

/// State shared with the wgpu-native callbacks. Heap-allocated by
/// `Device.acquire` so the `userdata1` pointer stays valid across moves.
pub const ErrorState = struct {
    /// Number of uncaptured errors delivered.
    uncaptured_count: usize = 0,
    /// The uncaptured error type, if any.
    last_error_type: c.WGPUErrorType = c.WGPUErrorType_NoError,
    /// Copy of the last uncaptured error message.
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    /// Set by the device-lost callback; stays set for the device's lifetime.
    lost: bool = false,
    /// Reason from the device-lost callback.
    lost_reason: c.WGPUDeviceLostReason = c.WGPUDeviceLostReason_Unknown,

    pub fn lastMessage(self: *const ErrorState) []const u8 {
        return self.message[0..self.message_len];
    }

    /// Map the recorded uncaptured status to the typed error set.
    pub fn lastError(self: *const ErrorState) Error {
        return switch (self.last_error_type) {
            c.WGPUErrorType_OutOfMemory => error.OutOfMemory,
            c.WGPUErrorType_Validation => error.ValidationFailed,
            c.WGPUErrorType_Internal => error.ValidationFailed,
            c.WGPUErrorType_Unknown => error.ValidationFailed,
            else => error.ValidationFailed,
        };
    }

    pub fn onUncaptured(
        device: [*c]const c.WGPUDevice,
        error_type: c.WGPUErrorType,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = device;
        _ = userdata2;
        const self: *ErrorState = @ptrCast(@alignCast(userdata1 orelse return));
        self.uncaptured_count += 1;
        self.last_error_type = error_type;
        self.message_len = copyMessage(message, &self.message);
    }

    pub fn onDeviceLost(
        device: [*c]const c.WGPUDevice,
        reason: c.WGPUDeviceLostReason,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = device;
        _ = userdata2;
        const self: *ErrorState = @ptrCast(@alignCast(userdata1 orelse return));
        self.lost = true;
        self.lost_reason = reason;
        self.message_len = copyMessage(message, &self.message);
    }
};

/// `wgpuInstanceRequestAdapter` userdata; the callback runs synchronously in
/// this wgpu-native revision.
const AdapterQuery = struct {
    adapter: c.WGPUAdapter = null,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,

    fn onCallback(
        status: c.WGPURequestAdapterStatus,
        adapter: c.WGPUAdapter,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *AdapterQuery = @ptrCast(@alignCast(userdata1 orelse return));
        self.message_len = copyMessage(message, &self.message);
        if (status == c.WGPURequestAdapterStatus_Success) {
            self.adapter = adapter;
        }
    }

    fn lastMessage(self: *const AdapterQuery) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// `wgpuAdapterRequestDevice` userdata.
const DeviceQuery = struct {
    device: c.WGPUDevice = null,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,

    fn onCallback(
        status: c.WGPURequestDeviceStatus,
        device: c.WGPUDevice,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const self: *DeviceQuery = @ptrCast(@alignCast(userdata1 orelse return));
        self.message_len = copyMessage(message, &self.message);
        if (status == c.WGPURequestDeviceStatus_Success) {
            self.device = device;
        }
    }

    fn lastMessage(self: *const DeviceQuery) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// `wgpuDevicePopErrorScope` userdata.
const ErrorScopeResult = struct {
    status: c.WGPUPopErrorScopeStatus = c.WGPUPopErrorScopeStatus_CallbackCancelled,
    error_type: c.WGPUErrorType = c.WGPUErrorType_NoError,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,

    fn onPop(
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
        self.message_len = copyMessage(message, &self.message);
    }

    fn lastMessage(self: *const ErrorScopeResult) []const u8 {
        return self.message[0..self.message_len];
    }

    fn toError(self: *const ErrorScopeResult) Error!void {
        return switch (self.error_type) {
            c.WGPUErrorType_NoError => {},
            c.WGPUErrorType_OutOfMemory => error.OutOfMemory,
            c.WGPUErrorType_Validation => error.ValidationFailed,
            else => error.ValidationFailed,
        };
    }
};

/// Options for `Adapter.acquire`.
pub const AdapterOptions = struct {
    /// Ask for no backend at all, which deterministically fails adapter
    /// selection. Mirrors the `.ports/wgpu` `--force-adapter-failure` path.
    force_failure: bool = false,
    /// Request the implementation's fallback adapter (typically a software
    /// rasterizer such as lavapipe).
    force_fallback_adapter: bool = false,
    power_preference: c.WGPUPowerPreference = c.WGPUPowerPreference_HighPerformance,
};

/// A wgpu instance. Owns its handle; release with `deinit`.
pub const Instance = struct {
    handle: c.WGPUInstance,

    pub fn create() Error!Instance {
        const handle = c.wgpuCreateInstance(null) orelse return error.NoInstance;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Instance) void {
        c.wgpuInstanceRelease(self.handle);
        self.handle = null;
    }
};

/// An adapter selected from an instance, plus its printed identity.
pub const Adapter = struct {
    handle: c.WGPUAdapter,
    info: AdapterInfo,

    /// Request an adapter. On failure returns `error.NoAdapter` after printing
    /// the wgpu-native status message (matching the examples' diagnostics).
    pub fn acquire(instance: *const Instance, options: AdapterOptions) Error!Adapter {
        var query = AdapterQuery{};
        var desc = c.wgpu_zig_init_WGPURequestAdapterOptions();
        desc.powerPreference = options.power_preference;
        desc.forceFallbackAdapter = @intFromBool(options.force_fallback_adapter);
        if (options.force_failure) {
            desc.backendType = c.WGPUBackendType_Null;
        }
        _ = c.wgpuInstanceRequestAdapter(instance.handle, &desc, .{
            .callback = &AdapterQuery.onCallback,
            .userdata1 = &query,
        });
        const handle = query.adapter orelse {
            std.debug.print("request_adapter failed: message=\"{s}\"\n", .{query.lastMessage()});
            return error.NoAdapter;
        };
        errdefer c.wgpuAdapterRelease(handle);

        var raw_info = c.wgpu_zig_init_WGPUAdapterInfo();
        if (c.wgpuAdapterGetInfo(handle, &raw_info) != c.WGPUStatus_Success) {
            return error.UnsupportedCapability;
        }
        defer c.wgpuAdapterInfoFreeMembers(raw_info);

        var info = AdapterInfo{
            .backend_type = raw_info.backendType,
            .adapter_type = raw_info.adapterType,
            .vendor_id = raw_info.vendorID,
            .device_id = raw_info.deviceID,
        };
        info.vendor_len = copyMessage(raw_info.vendor, &info.vendor);
        info.architecture_len = copyMessage(raw_info.architecture, &info.architecture);
        info.device_len = copyMessage(raw_info.device, &info.device);
        info.description_len = copyMessage(raw_info.description, &info.description);

        return .{ .handle = handle, .info = info };
    }

    pub fn deinit(self: *Adapter) void {
        c.wgpuAdapterRelease(self.handle);
        self.handle = null;
    }
};

/// A device and its default queue, with the uncaptured error and device-lost
/// callbacks wired to a stable `ErrorState`.
pub const Device = struct {
    handle: c.WGPUDevice,
    queue: c.WGPUQueue,
    state: *ErrorState,
    allocator: std.mem.Allocator,

    pub fn acquire(allocator: std.mem.Allocator, adapter: *const Adapter, label: []const u8) Error!Device {
        const state = allocator.create(ErrorState) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);
        state.* = .{};

        var lost_info = c.wgpu_zig_init_WGPUDeviceLostCallbackInfo();
        lost_info.callback = &ErrorState.onDeviceLost;
        lost_info.userdata1 = state;

        var uncaptured_info = c.wgpu_zig_init_WGPUUncapturedErrorCallbackInfo();
        uncaptured_info.callback = &ErrorState.onUncaptured;
        uncaptured_info.userdata1 = state;

        var desc = c.wgpu_zig_init_WGPUDeviceDescriptor();
        desc.label = wgpu.stringView(label);
        desc.deviceLostCallbackInfo = lost_info;
        desc.uncapturedErrorCallbackInfo = uncaptured_info;

        var query = DeviceQuery{};
        _ = c.wgpuAdapterRequestDevice(adapter.handle, &desc, .{
            .callback = &DeviceQuery.onCallback,
            .userdata1 = &query,
        });
        const handle = query.device orelse {
            std.debug.print("request_device failed: message=\"{s}\"\n", .{query.lastMessage()});
            return error.NoDevice;
        };
        errdefer c.wgpuDeviceRelease(handle);

        const queue = c.wgpuDeviceGetQueue(handle) orelse return error.NoDevice;
        errdefer c.wgpuQueueRelease(queue);

        return .{
            .handle = handle,
            .queue = queue,
            .state = state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Device) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.handle);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Blocking `wgpuDevicePoll(device, true, null)`, which also delivers
    /// uncaptured errors. Returns false if the poll failed.
    pub fn poll(self: *Device) bool {
        return c.wgpuDevicePoll(self.handle, 1, null) != 0;
    }

    /// True once the device-lost callback fired.
    pub fn isLost(self: *const Device) bool {
        return self.state.lost;
    }

    /// Fail if the device is lost or any uncaptured error is pending.
    pub fn check(self: *Device) Error!void {
        _ = self.poll();
        if (self.state.lost) return error.DeviceLost;
        if (self.state.uncaptured_count != 0) return self.state.lastError();
    }

    /// Push a validation/out-of-memory/internal error scope.
    pub fn pushErrorScope(self: *Device, filter: c.WGPUErrorFilter) void {
        if (self.state.lost) return;
        c.wgpuDevicePushErrorScope(self.handle, filter);
    }

    /// Pop the innermost error scope. In this wgpu-native revision the callback
    /// runs synchronously, so the result is available on return.
    pub fn popErrorScope(self: *Device) Error!void {
        if (self.state.lost) return error.DeviceLost;
        var result = ErrorScopeResult{};
        _ = c.wgpuDevicePopErrorScope(self.handle, .{
            .callback = &ErrorScopeResult.onPop,
            .userdata1 = &result,
        });
        if (result.status != c.WGPUPopErrorScopeStatus_Success) {
            std.debug.print("pop_error_scope failed: status={d}\n", .{result.status});
            return error.ValidationFailed;
        }
        if (result.error_type != c.WGPUErrorType_NoError) {
            std.debug.print("error scope captured error: type={d} message=\"{s}\"\n", .{
                result.error_type, result.lastMessage(),
            });
        }
        return result.toError();
    }

    /// Read the device limits through `wgpuDeviceGetLimits`.
    pub fn getLimits(self: *Device) Error!Limits {
        if (self.state.lost) return error.DeviceLost;
        var raw = c.wgpu_zig_init_WGPULimits();
        if (c.wgpuDeviceGetLimits(self.handle, &raw) != c.WGPUStatus_Success) {
            return error.UnsupportedCapability;
        }
        if (raw.maxTextureDimension2D == 0) return error.UnsupportedCapability;
        return .{ .max_texture_dimension_2d = raw.maxTextureDimension2D };
    }
};

test "adapter info formatting names" {
    var info = AdapterInfo{
        .backend_type = c.WGPUBackendType_Vulkan,
        .adapter_type = c.WGPUAdapterType_CPU,
        .vendor_id = 0x10005,
        .device_id = 0,
    };
    info.description_len = copyMessage(wgpu.stringView("llvmpipe"), &info.description);
    try std.testing.expectEqualStrings("vulkan", info.backendName());
    try std.testing.expectEqualStrings("cpu", info.adapterTypeName());
    try std.testing.expectEqualStrings("software-adapter", info.executionKind());
    try std.testing.expectEqualStrings("llvmpipe", info.descriptionSlice());
}

test "error state maps status to typed errors" {
    var state = ErrorState{};
    try std.testing.expectEqual(@as(usize, 0), state.uncaptured_count);
    state.last_error_type = c.WGPUErrorType_OutOfMemory;
    try std.testing.expectEqual(Error.OutOfMemory, state.lastError());
    state.last_error_type = c.WGPUErrorType_Validation;
    try std.testing.expectEqual(Error.ValidationFailed, state.lastError());
    state.message_len = copyMessage(wgpu.stringView("boom"), &state.message);
    try std.testing.expectEqualStrings("boom", state.lastMessage());
}

test "limits cap resource textures at 4096" {
    try std.testing.expectEqual(@as(u32, 4096), (Limits{ .max_texture_dimension_2d = 16384 }).resourceTextureDimension2d());
    try std.testing.expectEqual(@as(u32, 2048), (Limits{ .max_texture_dimension_2d = 2048 }).resourceTextureDimension2d());
}
