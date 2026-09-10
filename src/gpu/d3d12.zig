//! Direct3D 12 driver skeleton (Windows-only).
//!
//! Pattern modeled on SDL3 `src/gpu/d3d12/SDL_gpu_d3d12.c` (zlib,
//! Copyright 1997-2026 Sam Lantinga), reimplemented in Zig — no verbatim
//! C ported. The real driver builds the D3D12 device via
//! `D3D12CreateDevice`, owns a direct command queue + swapchain over the
//! `HWND` from `platform/windows/win32.zig` (supplied as
//! `device.SurfaceHandle{ .tag = .win32 }`), and consumes DXBC/DXIL shaders
//! compiled offline (see `device.shaderFormatsFor`). COM vtables are
//! expressed as Zig `extern struct`s of function pointers, mirroring how
//! `src/text/bindings.zig` maps C ABIs. Cannot be verified on this Linux
//! box: `isAvailable()` is Windows-only and `init()` stays
//! `error.Unsupported` until the driver lands.

const std = @import("std");
const builtin = @import("builtin");
const device = @import("device.zig");
const scene_mod = @import("scene.zig");

/// Entry points / interfaces the driver will resolve (names only until the
/// driver lands): `D3D12CreateDevice` (d3d12.dll),
/// `CreateDXGIFactory2` (dxgi.dll), `ID3D12Device`, `IDXGISwapChain3`,
/// `ID3D12CommandQueue/Allocator/List`, `ID3D12Resource`,
/// `ID3D12DescriptorHeap`, `D3DCompile`/`DxcCreateInstance` for offline
/// shader blobs (build-time only; the runtime consumes DXBC/DXIL bytes).
pub const planned_d3d12_interfaces: []const []const u8 = &.{
    "D3D12CreateDevice",
    "CreateDXGIFactory2",
    "ID3D12Device",
    "IDXGISwapChain3",
    "ID3D12CommandQueue",
    "ID3D12GraphicsCommandList",
    "ID3D12Resource",
};

pub const D3D12Device = struct {
    tracker: device.Tracker = .{ .kind = .d3d12 },

    // TODO(gpu-d3d12): real init, in order —
    // 1. CreateDXGIFactory2 + adapter pick (hardware first, WARP fallback
    //    allowed in debug) + D3D12CreateDevice (feature level 12_0 min).
    // 2. direct command queue + per-frame-in-flight allocators/lists +
    //    fence values.
    // 3. swapchain (IDXGIFactory2 CreateSwapChainForHwnd) over the Win32
    //    HWND (SurfaceHandle .win32); resize-buffers path on needsRecreate.
    // 4. root signature + PSO for the shared textured-rect vertex layout;
    //    DXBC/DXIL blobs compiled offline (D3DCompile/dxc at build time,
    //    never at runtime).
    // 5. descriptor heaps (RTV + CBV/SRV/UAV) sized from limits.zig pools.
    // NOTE: needs Windows hardware to verify; keep the stub green until then.

    pub fn isAvailable() bool {
        return builtin.os.tag == .windows;
    }

    pub fn init() !void {
        return error.Unsupported;
    }

    pub fn handle(self: *@This()) device.Device {
        return .{ .ptr = &self.tracker, .vtable = &device.stub_vtable };
    }
};

test "d3d12 stub reports kind but constructs nowhere on linux" {
    var g = D3D12Device{};
    const d = g.handle();
    try std.testing.expectEqual(device.DeviceKind.d3d12, d.kind());
    try std.testing.expectEqualStrings("d3d12", d.driverName());
    try std.testing.expectError(error.Unsupported, D3D12Device.init());
    if (builtin.os.tag != .windows) try std.testing.expect(!D3D12Device.isAvailable());
    try std.testing.expect(d.render(&scene_mod.Scene{}, &.{}));
    try std.testing.expect(planned_d3d12_interfaces.len >= 5);
}
