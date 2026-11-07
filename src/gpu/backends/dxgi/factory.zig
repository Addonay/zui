//! DXGI adapter discovery used by native test/application hosts.
const com = @import("com.zig");
const std = @import("std");
const Library = @import("../../platform/windows_library.zig").Library;
const factory4_iid: com.Guid = .{ .data1 = 0x1bc6ea02, .data2 = 0xef36, .data3 = 0x464f, .data4 = .{ 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a } };
const adapter_iid: com.Guid = .{ .data1 = 0x2411e7e1, .data2 = 0x12ac, .data3 = 0x4ccf, .data4 = .{ 0xbd, 0x14, 0x97, 0x98, 0xe8, 0x53, 0x4d, 0xc0 } };

/// Keeps dxgi.dll loaded for the entire lifetime of its COM objects.
pub const Warp = struct {
    library: Library,
    factory: *com.Object,
    adapter: *com.Object,
    pub fn init() !Warp {
        const library = try Library.open("dxgi.dll");
        errdefer library.close();
        const Create = *const fn (u32, *const com.Guid, *?*com.Object) callconv(com.call_conv) i32;
        const create = library.lookup(Create, "CreateDXGIFactory2") orelse return error.MissingDxgiFactory;
        var factory: ?*com.Object = null;
        if (create(0, &factory4_iid, &factory) < 0 or factory == null) return error.MissingDxgiFactory;
        errdefer com.release(factory);
        var adapter: ?*com.Object = null;
        const Enum = *const fn (*com.Object, *const com.Guid, *?*com.Object) callconv(com.call_conv) i32;
        if (com.invoke(27, Enum, factory.?, .{ &adapter_iid, &adapter }) < 0 or adapter == null) return error.WarpUnavailable;
        return .{ .library = library, .factory = factory.?, .adapter = adapter.? };
    }
    pub fn deinit(self: *Warp) void {
        com.release(self.adapter);
        com.release(self.factory);
        self.library.close();
    }
};

/// Owned adapter selected through IDXGIFactory6. The application still checks
/// whether its API/feature level is supported; preference does not guarantee it.
pub const Preferred = struct {
    library: Library,
    factory: *com.Object,
    adapter: *com.Object,
    pub const Preference = enum(u32) { unspecified = 0, minimum_power = 1, high_performance = 2 };

    pub fn init(preference: Preference, index: u32) !Preferred {
        const library = try Library.open("dxgi.dll");
        errdefer library.close();
        const factory6_iid: com.Guid = .{ .data1 = 0xc1b6694f, .data2 = 0xff09, .data3 = 0x44a9, .data4 = .{ 0xb0, 0x3c, 0x77, 0x90, 0x0a, 0x0a, 0x1d, 0x17 } };
        const Create = *const fn (u32, *const com.Guid, *?*com.Object) callconv(com.call_conv) i32;
        const create = library.lookup(Create, "CreateDXGIFactory2") orelse return error.MissingDxgiFactory;
        var factory: ?*com.Object = null;
        if (create(0, &factory6_iid, &factory) < 0 or factory == null) return error.MissingDxgiFactory6;
        errdefer com.release(factory);
        var adapter: ?*com.Object = null;
        const Enum = *const fn (*com.Object, u32, u32, *const com.Guid, *?*com.Object) callconv(com.call_conv) i32;
        if (com.invoke(29, Enum, factory.?, .{ index, @backingInt(preference), &adapter_iid, &adapter }) < 0 or adapter == null) return error.AdapterUnavailable;
        return .{ .library = library, .factory = factory.?, .adapter = adapter.? };
    }

    pub fn deinit(self: *Preferred) void {
        com.release(self.adapter);
        com.release(self.factory);
        self.library.close();
    }
};

/// Owned UTF-8 adapter identity for a D3D11 device; suitable for test evidence.
pub fn describeD3D11Device(allocator: std.mem.Allocator, device: *com.Object) ![]u8 {
    const device_iid: com.Guid = .{ .data1 = 0x54ec77fa, .data2 = 0x1377, .data3 = 0x44e6, .data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
    const Query = *const fn (*com.Object, *const com.Guid, *?*com.Object) callconv(com.call_conv) i32;
    var dxgi_device: ?*com.Object = null;
    if (com.invoke(0, Query, device, .{ &device_iid, &dxgi_device }) < 0 or dxgi_device == null) return error.NoDxgiDevice;
    defer com.release(dxgi_device);
    const GetAdapter = *const fn (*com.Object, *?*com.Object) callconv(com.call_conv) i32;
    var adapter: ?*com.Object = null;
    if (com.invoke(7, GetAdapter, dxgi_device.?, .{&adapter}) < 0 or adapter == null) return error.NoDxgiAdapter;
    defer com.release(adapter);
    const Description = extern struct {
        name: [128]u16,
        vendor: u32,
        device: u32,
        subsystem: u32,
        revision: u32,
        video_memory: usize,
        system_memory: usize,
        shared_memory: usize,
        luid: [2]u32,
    };
    var desc: Description = undefined;
    const GetDesc = *const fn (*com.Object, *Description) callconv(com.call_conv) i32;
    if (com.invoke(8, GetDesc, adapter.?, .{&desc}) < 0) return error.NoDxgiDescription;
    const name = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(&desc.name, 0));
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s} (vendor 0x{x}, device 0x{x})", .{ name, desc.vendor, desc.device });
}
