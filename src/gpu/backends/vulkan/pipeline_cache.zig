//! Owned Vulkan pipeline cache and driver/UUID-checked persistence.
const std = @import("std");
const sdk = @import("sdk.zig");
const t = @import("../../types.zig");
const core = @import("../../core.zig");
const Backend = @import("backend.zig").Backend;
const observe = @import("result.zig").observe;
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @ptrCast(bytes[offset..][0..4].ptr), .little);
}
pub fn compatible(self: *const Backend, bytes: []const u8) bool {
    if (bytes.len < 32) return false;
    const props = &self.dev_props.properties;
    return word(bytes, 0) == 32 and word(bytes, 4) == 1 and word(bytes, 8) == props.vendorID and
        word(bytes, 12) == props.deviceID and std.mem.eql(u8, bytes[16..32], &props.pipelineCacheUUID);
}
/// Mesa lavapipe's 2026-09 size update reports five words after writing the
/// complete eight-word header. Recover only that exact fully validated case.
/// https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/ec071eb25d7fd923e836569277da6c5e81030444/src/gallium/frontends/lavapipe/lvp_pipeline_cache.c
fn exportedSize(self: *const Backend, bytes: []const u8, reported: usize) usize {
    const props = &self.dev_props.properties;
    if (reported == 20 and bytes.len >= 32 and props.vendorID == 0x10005 and props.deviceID == 0 and compatible(self, bytes[0..32])) return 32;
    return reported;
}
pub fn init(self: *Backend, input: t.Range) !void {
    var initial_bytes: []const u8 = if (input.ptr) |ptr| @as([*]const u8, @ptrCast(ptr))[0..input.size] else &.{};
    if (initial_bytes.len > 0 and !compatible(self, initial_bytes)) {
        core.logWarn(.vulkan_pipeline_cache_ignored);
        initial_bytes = &.{};
    }
    const info: sdk.PipelineCacheCreateInfo = .{ .initialDataSize = initial_bytes.len, .pInitialData = if (initial_bytes.len == 0) null else initial_bytes.ptr };
    if (observe(self.fns.device.vkCreatePipelineCache(self.dev, &info, null, &self.pipeline_cache)) != sdk.SUCCESS) return error.VulkanInitFailed;
}
pub fn deinit(self: *Backend) void {
    if (self.pipeline_cache != 0) self.fns.device.vkDestroyPipelineCache(self.dev, self.pipeline_cache, null);
    self.pipeline_cache = 0;
}
pub fn data(self: *Backend, allocator: std.mem.Allocator) ![]u8 {
    for (0..4) |_| {
        var size: usize = 0;
        if (observe(self.fns.device.vkGetPipelineCacheData(self.dev, self.pipeline_cache, &size, null)) != sdk.SUCCESS) return error.DriverError;
        if (size == 0) return allocator.alloc(u8, 0);
        const bytes = try allocator.alloc(u8, size);
        // A driver may misreport its written length. Zero initialization makes
        // the bounded header check safe without inspecting uninitialized bytes.
        @memset(bytes, 0);
        const result = observe(self.fns.device.vkGetPipelineCacheData(self.dev, self.pipeline_cache, &size, bytes.ptr));
        if (result == sdk.SUCCESS) {
            if (size > bytes.len) {
                allocator.free(bytes);
                return error.DriverError;
            }
            const normalized = exportedSize(self, bytes, size);
            if (normalized != size) {
                core.logWarn(.vulkan_pipeline_cache_header_size_repaired);
                core.statsInc("vk.num_pipeline_cache_header_repairs");
                size = normalized;
            }
            if (size != 0 and size < 32) {
                allocator.free(bytes);
                return error.DriverError;
            }
            return allocator.realloc(bytes, size) catch |err| {
                allocator.free(bytes);
                return err;
            };
        }
        allocator.free(bytes);
        if (result != 5) return error.DriverError; // VK_INCOMPLETE: driver grew cache, retry
    }
    return error.DriverError;
}

test "cache headers are little endian and short Mesa sizes require a full matching UUID" {
    var backend: Backend = .{ .allocator = std.testing.allocator };
    const uuid = [_]u8{ 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf };
    backend.dev_props.properties.vendorID = 0x10005;
    backend.dev_props.properties.pipelineCacheUUID = uuid;
    var header = [_]u8{ 32, 0, 0, 0, 1, 0, 0, 0, 5, 0, 1, 0, 0, 0, 0, 0 } ++ uuid;
    try std.testing.expect(compatible(&backend, &header));
    try std.testing.expectEqual(@as(usize, 32), exportedSize(&backend, &header, 20));
    try std.testing.expectEqual(@as(usize, 20), exportedSize(&backend, header[0..20], 20));
    try std.testing.expectEqual(@as(usize, 19), exportedSize(&backend, &header, 19));
    header[31] ^= 1;
    try std.testing.expectEqual(@as(usize, 20), exportedSize(&backend, &header, 20));
    header[31] ^= 1;
    backend.dev_props.properties.vendorID = 0x1002;
    try std.testing.expectEqual(@as(usize, 20), exportedSize(&backend, &header, 20));
    backend.dev_props.properties.vendorID = 0x10005;
    header[0..4].* = .{ 0, 0, 0, 32 };
    try std.testing.expect(!compatible(&backend, &header));
}
