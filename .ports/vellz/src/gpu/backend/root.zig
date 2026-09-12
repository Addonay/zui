//! wgpu-backed GPU backend (device bootstrap + readback + clear pipeline).
//!
//! This file is analyzed only when the package is built with `-Dgpu=true`;
//! every module behind it may import the sibling `wgpu` package.

const device = @import("device.zig");

pub const readback = @import("readback.zig");
pub const wgpu = @import("wgpu.zig");

pub const Instance = device.Instance;
pub const Adapter = device.Adapter;
pub const AdapterInfo = device.AdapterInfo;
pub const AdapterOptions = device.AdapterOptions;
pub const Device = device.Device;
pub const Limits = device.Limits;
pub const Error = device.Error;
pub const ErrorState = device.ErrorState;
pub const messageSlice = device.messageSlice;

test {
    @import("std").testing.refAllDecls(@This());

    // Explicit imports keep the submodule tests in the `-Dgpu=true` test run.
    _ = @import("device.zig");
    _ = @import("readback.zig");
    _ = @import("wgpu.zig");
}
