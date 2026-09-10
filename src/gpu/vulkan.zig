//! Vulkan driver: `dlopen` function tables, verified ABI types, device stub.
//!
//! Pattern modeled on SDL3 `src/gpu/vulkan/SDL_gpu_vulkan.c` (zlib,
//! Copyright 1997-2026 Sam Lantinga), reimplemented in Zig — no verbatim
//! C ported. Vulkan is cross-platform (Linux + Windows, macOS via
//! MoltenVK), so it lives in `gpu/`, not `platform/linux/`. Per-OS surface
//! creation takes handles supplied by `platform/` as
//! `device.SurfaceHandle`.
//!
//! ABI discipline: every constant and struct layout below was checked
//! against `/usr/include/vulkan/vulkan_core.h` (+ `vulkan_wayland.h`,
//! `vulkan_xlib.h`, `vulkan_metal.h`). Values are pinned by unit tests so
//! header drift fails loudly instead of corrupting calls.
//!
//! Status: loader probe + global/instance tables resolve at runtime; full
//! device/swapchain/pipeline init lands next (Phase 8b). Until then
//! `init()` returns `error.Unsupported` and the `Device` side discards
//! frames via the shared `stub_vtable`.

const std = @import("std");
const builtin = @import("builtin");
const device = @import("device.zig");
const scene_mod = @import("scene.zig");
const dl = @import("../platform/dl.zig");

pub const vulkan_lib_names: []const [*:0]const u8 = &.{ "libvulkan.so.1", "libvulkan.so" };

// ============================================================================
// Extension names (verified against vulkan_*.h)
// ============================================================================

pub const ext_surface = "VK_KHR_surface";
pub const ext_wayland_surface = "VK_KHR_wayland_surface";
pub const ext_xlib_surface = "VK_KHR_xlib_surface";
pub const ext_xcb_surface = "VK_KHR_xcb_surface";
pub const ext_win32_surface = "VK_KHR_win32_surface";
pub const ext_metal_surface = "VK_EXT_metal_surface";
pub const ext_swapchain = "VK_KHR_swapchain";

/// Instance extensions for a surface tag. Headless needs none beyond the
/// base surface extension (there is no window to present to).
pub fn requiredInstanceExtensions(tag: device.SurfaceHandle.Tag) []const []const u8 {
    return switch (tag) {
        .wayland => &.{ ext_surface, ext_wayland_surface },
        .x11 => &.{ ext_surface, ext_xlib_surface },
        .win32 => &.{ ext_surface, ext_win32_surface },
        .cocoa => &.{ ext_surface, ext_metal_surface },
        .headless => &.{ext_surface},
    };
}

// ============================================================================
// Handles (dispatchable and non-dispatchable are all 64-bit/pointer-sized;
// `enum(usize)` keeps `.null == 0` and type safety)
// ============================================================================

pub const Instance = enum(usize) { null = 0, _ };
pub const PhysicalDevice = enum(usize) { null = 0, _ };
pub const VkDevice = enum(usize) { null = 0, _ };
pub const Queue = enum(usize) { null = 0, _ };
pub const SurfaceKHR = enum(usize) { null = 0, _ };
pub const SwapchainKHR = enum(usize) { null = 0, _ };
pub const Semaphore = enum(usize) { null = 0, _ };
pub const VkFence = enum(usize) { null = 0, _ };
pub const CommandPool = enum(usize) { null = 0, _ };
pub const CommandBuffer = enum(usize) { null = 0, _ };
pub const Image = enum(usize) { null = 0, _ };
pub const ImageView = enum(usize) { null = 0, _ };
pub const VkBuffer = enum(usize) { null = 0, _ };
pub const DeviceMemory = enum(usize) { null = 0, _ };
pub const ShaderModule = enum(usize) { null = 0, _ };
pub const Pipeline = enum(usize) { null = 0, _ };
pub const PipelineLayout = enum(usize) { null = 0, _ };

pub const Bool32 = u32;
pub const DeviceSize = u64;
pub const Flags = u32;

pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

pub const api_version_1_0: u32 = makeApiVersion(0, 1, 0, 0);

// ============================================================================
// VkResult (verified values)
// ============================================================================

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_device_lost = -4,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    suboptimal_khr = 1000001003,
    error_out_of_date_khr = -1000001004,
    _,

    pub fn isSuccess(self: @This()) bool {
        return @backingInt(self) >= 0;
    }

    /// Swapchain images are usable but the swapchain should be rebuilt.
    pub fn needsRecreate(self: @This()) bool {
        return self == .suboptimal_khr or self == .error_out_of_date_khr;
    }
};

// ============================================================================
// Structure types + formats + present modes (verified values)
// ============================================================================

pub const StructureType = enum(u32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    swapchain_create_info_khr = 1000001000,
    present_info_khr = 1000001001,
    xlib_surface_create_info_khr = 1000004000,
    xcb_surface_create_info_khr = 1000005000,
    wayland_surface_create_info_khr = 1000006000,
    win32_surface_create_info_khr = 1000009000,
    metal_surface_create_info_ext = 1000217000,
    _,
};

/// Present modes (verified). Maps 1:1 onto `device.PresentMode` by order:
/// immediate=0, mailbox=1, fifo(vsync)=2. `fifo_relaxed` has no SDL
/// counterpart and is unused until a driver asks for it.
pub const PresentModeKHR = enum(u32) {
    immediate = 0,
    mailbox = 1,
    fifo = 2,
    fifo_relaxed = 3,
    _,

    pub fn fromPresentMode(mode: device.PresentMode) @This() {
        return switch (mode) {
            .immediate => .immediate,
            .mailbox => .mailbox,
            .vsync => .fifo,
        };
    }
};

/// Swapchain image formats per composition (verified format numbers).
/// HDR10 (A2R10G10B10 pack) is left unmapped until verified against a
/// header on a machine that needs it.
pub const Format = enum(u32) {
    b8g8r8a8_unorm = 44,
    r8g8b8a8_srgb = 43,
    b8g8r8a8_srgb = 50,
    r16g16b16a16_sfloat = 97,
    _,

    pub fn forComposition(comp: device.SwapchainComposition) ?@This() {
        return switch (comp) {
            .sdr => .b8g8r8a8_unorm,
            .sdr_linear => .b8g8r8a8_srgb,
            .hdr_extended_linear => .r16g16b16a16_sfloat,
            .hdr10_st2084 => null,
        };
    }
};

pub const ColorSpaceKHR = enum(u32) { srgb_nonlinear = 0, _ };
pub const ImageUsage = struct {
    pub const color_attachment: u32 = 0x00000010;
};
pub const SharingMode = enum(u32) { exclusive = 0, concurrent = 1 };
pub const SurfaceTransformKHR = struct {
    pub const identity: u32 = 0x00000001;
};
pub const CompositeAlphaKHR = struct {
    pub const opaque_bit: u32 = 0x00000001;
};

// ============================================================================
// Create-info structs (field order verified against vulkan_core.h)
// ============================================================================

pub const ApplicationInfo = extern struct {
    sType: StructureType = .application_info,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = api_version_1_0,
};

pub const InstanceCreateInfo = extern struct {
    sType: StructureType = .instance_create_info,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    pApplicationInfo: ?*const ApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

pub const DeviceQueueCreateInfo = extern struct {
    sType: StructureType = .device_queue_create_info,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    queueFamilyIndex: u32 = 0,
    queueCount: u32 = 0,
    pQueuePriorities: ?[*]const f32 = null,
};

pub const DeviceCreateInfo = extern struct {
    sType: StructureType = .device_create_info,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    queueCreateInfoCount: u32 = 0,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo = null,
    enabledLayerCount: u32 = 0, // legacy, must stay 0
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null, // legacy, must stay null
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null, // VkPhysicalDeviceFeatures; unneeded until 8b
};

pub const Extent2D = extern struct { width: u32 = 0, height: u32 = 0 };

pub const SwapchainCreateInfoKHR = extern struct {
    sType: StructureType = .swapchain_create_info_khr,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    surface: SurfaceKHR = .null,
    minImageCount: u32 = 2,
    imageFormat: Format = .b8g8r8a8_unorm,
    imageColorSpace: ColorSpaceKHR = .srgb_nonlinear,
    imageExtent: Extent2D = .{},
    imageArrayLayers: u32 = 1,
    imageUsage: Flags = ImageUsage.color_attachment,
    imageSharingMode: SharingMode = .exclusive,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
    preTransform: Flags = SurfaceTransformKHR.identity,
    compositeAlpha: Flags = CompositeAlphaKHR.opaque_bit,
    presentMode: PresentModeKHR = .fifo,
    clipped: Bool32 = 1,
    oldSwapchain: SwapchainKHR = .null,
};

// Surface create-infos reference foreign window-system types as opaque
// pointers: the driver never dereferences them, it just forwards them to
// the loader. Field order verified against vulkan_wayland.h etc.
pub const WaylandSurfaceCreateInfoKHR = extern struct {
    sType: StructureType = .wayland_surface_create_info_khr,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    display: ?*anyopaque = null, // struct wl_display*
    surface: ?*anyopaque = null, // struct wl_surface*
};

pub const XlibSurfaceCreateInfoKHR = extern struct {
    sType: StructureType = .xlib_surface_create_info_khr,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    dpy: ?*anyopaque = null, // Display*
    window: usize = 0, // Window (XID, 64-bit-safe)
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    sType: StructureType = .win32_surface_create_info_khr,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    hinstance: ?*anyopaque = null, // HINSTANCE
    hwnd: ?*anyopaque = null, // HWND
};

pub const MetalSurfaceCreateInfoEXT = extern struct {
    sType: StructureType = .metal_surface_create_info_ext,
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    pLayer: ?*const anyopaque = null, // const CAMetalLayer*
};

// ============================================================================
// Function tables (resolved at runtime; never linked)
// ============================================================================

pub const CreateInstanceFn = *const fn (?*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(.c) Result;
pub const DestroyInstanceFn = *const fn (Instance, ?*const anyopaque) callconv(.c) void;
pub const EnumeratePhysicalDevicesFn = *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result;
pub const GetInstanceProcAddrFn = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;
pub const EnumerateInstanceExtensionPropertiesFn = *const fn (?[*:0]const u8, *u32, ?*anyopaque) callconv(.c) Result;

/// Loader-global entry points: these are exported by libvulkan.so itself,
/// so `dlsym` resolves them. Everything else comes from
/// `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` after an instance and
/// device exist (Phase 8b growth point; the instance/device tables below
/// name the exact functions to pull).
pub const GlobalApi = struct {
    createInstance: CreateInstanceFn,
    destroyInstance: DestroyInstanceFn,
    enumeratePhysicalDevices: EnumeratePhysicalDevicesFn,
    getInstanceProcAddr: GetInstanceProcAddrFn,
    enumerateInstanceExtensionProperties: EnumerateInstanceExtensionPropertiesFn,

    pub fn load(lib: dl.Library) ?GlobalApi {
        return .{
            .createInstance = lib.lookup(CreateInstanceFn, "vkCreateInstance") orelse return null,
            .destroyInstance = lib.lookup(DestroyInstanceFn, "vkDestroyInstance") orelse return null,
            .enumeratePhysicalDevices = lib.lookup(EnumeratePhysicalDevicesFn, "vkEnumeratePhysicalDevices") orelse return null,
            .getInstanceProcAddr = lib.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse return null,
            .enumerateInstanceExtensionProperties = lib.lookup(EnumerateInstanceExtensionPropertiesFn, "vkEnumerateInstanceExtensionProperties") orelse return null,
        };
    }
};

/// Instance-level functions to resolve via `getInstanceProcAddr` once an
/// instance exists (names only until Phase 8b wires them):
// TODO(gpu-vulkan-8b): resolve each of these after instance creation and
// fail init loudly if any is missing (loader without surface support is
// a hard error, not a fallback — surfaces are the whole point).
/// vkDestroySurfaceKHR, vkCreateDevice, vkEnumerateDeviceExtensionProperties,
/// vkGetPhysicalDeviceQueueFamilyProperties, vkGetPhysicalDeviceSurfaceSupportKHR,
/// vkGetPhysicalDeviceSurfaceCapabilitiesKHR, vkGetPhysicalDeviceSurfaceFormatsKHR,
/// vkGetPhysicalDeviceSurfacePresentModesKHR.
/// Device-level via `vkGetDeviceProcAddr`: vkGetDeviceQueue,
/// vkCreateSwapchainKHR/vkDestroySwapchainKHR/vkGetSwapchainImagesKHR/
/// vkAcquireNextImageKHR/vkQueuePresentKHR, vkCreateCommandPool,
/// vkAllocateCommandBuffers/vkBeginCommandBuffer/vkEndCommandBuffer,
/// vkQueueSubmit/vkQueueWaitIdle/vkDeviceWaitIdle, vkCreateFence/vkWaitForFences/
/// vkResetFences/vkDestroyFence, vkCreateSemaphore/vkDestroySemaphore,
/// vkCreateShaderModule/vkDestroyShaderModule, vkCreateGraphicsPipelines/
/// vkCreateComputePipelines/vkDestroyPipeline, vkCreatePipelineLayout/
/// vkDestroyPipelineLayout, vkCreateBuffer/vkDestroyBuffer,
/// vkCreateImage/vkDestroyImage, vkCreateImageView/vkDestroyImageView,
/// vkCreateSampler/vkDestroySampler, vkAllocateMemory/vkFreeMemory/
/// vkBindBufferMemory/vkBindImageMemory, vkMapMemory/vkUnmapMemory,
/// vkCmdBeginRenderPass/vkCmdEndRenderPass, vkCmdBindPipeline,
/// vkCmdSetViewport/vkCmdSetScissor, vkCmdBindVertexBuffers/
/// vkCmdBindIndexBuffer, vkCmdDraw/vkCmdDrawIndexed/vkCmdDrawIndirect/
/// vkCmdDrawIndexedIndirect, vkCmdDispatch/vkCmdDispatchIndirect,
/// vkCmdCopyBuffer/vkCmdCopyBufferToImage/vkCmdCopyImageToBuffer/
/// vkCmdBlitImage/vkCmdPipelineBarrier.
pub const planned_instance_functions: []const []const u8 = &.{
    "vkDestroySurfaceKHR",
    "vkCreateDevice",
    "vkEnumerateDeviceExtensionProperties",
    "vkGetPhysicalDeviceQueueFamilyProperties",
    "vkGetPhysicalDeviceSurfaceSupportKHR",
    "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
    "vkGetPhysicalDeviceSurfaceFormatsKHR",
    "vkGetPhysicalDeviceSurfacePresentModesKHR",
};

pub const planned_device_functions: []const []const u8 = &.{
    "vkGetDeviceQueue",
    "vkCreateSwapchainKHR",
    "vkDestroySwapchainKHR",
    "vkGetSwapchainImagesKHR",
    "vkAcquireNextImageKHR",
    "vkQueuePresentKHR",
    "vkCreateCommandPool",
    "vkAllocateCommandBuffers",
    "vkQueueSubmit",
    "vkQueueWaitIdle",
    "vkDeviceWaitIdle",
    "vkCreateFence",
    "vkWaitForFences",
    "vkCreateSemaphore",
    "vkCreateShaderModule",
    "vkCreateGraphicsPipelines",
    "vkCreateComputePipelines",
    "vkCreateBuffer",
    "vkCreateImage",
    "vkCreateImageView",
    "vkCreateSampler",
    "vkAllocateMemory",
    "vkMapMemory",
};

// ============================================================================
// Device stub (tracks via shared Tracker until real init lands)
// ============================================================================

pub const VulkanDevice = struct {
    tracker: device.Tracker = .{ .kind = .vulkan },

    // TODO(gpu-vulkan-8b): real init, in order —
    // 1. createInstance (GlobalApi) + validation layers in debug.
    // 2. pick physical device: discrete GPU first, must support graphics +
    //    present for the claimed surface tag; record queue families.
    // 3. createDevice + graphics/present queues; resolve the device table
    //    via vkGetDeviceProcAddr (see planned_device_functions).
    // 4. surface via requiredInstanceExtensions(tag) + per-OS create-info
    //    above; swapchain with minImageCount from surface capabilities and
    //    presentMode from PresentModeKHR.fromPresentMode; keep oldSwapchain
    //    rebuild path for resize / needsRecreate().
    // 5. per-frame-in-flight command pools + fences/semaphores.
    // 6. textured-rect graphics pipeline (Scene quads) + glyph atlas
    //    texture upload path; shaders from offline SPIR-V @embedFile blobs.
    // TODO(gpu-vulkan): HDR10 swapchain mapping (Format.forComposition
    // returns null) — verify A2R10G10B10 pack values against headers on a
    // machine that needs HDR before enabling.

    pub fn isAvailable() bool {
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return false;
        var lib = dl.Library.open(vulkan_lib_names) orelse return false;
        defer lib.close();
        return GlobalApi.load(lib) != null;
    }

    pub fn init() !void {
        return error.Unsupported;
    }

    pub fn handle(self: *@This()) device.Device {
        return .{ .ptr = &self.tracker, .vtable = &device.stub_vtable };
    }
};

test "vulkan stub reports kind and probes loader only" {
    var v = VulkanDevice{};
    const d = v.handle();
    try std.testing.expectEqual(device.DeviceKind.vulkan, d.kind());
    try std.testing.expectEqualStrings("vulkan", d.driverName());
    try std.testing.expectError(error.Unsupported, VulkanDevice.init());
    // Availability reflects the machine; the call itself must never link.
    _ = VulkanDevice.isAvailable();
    try std.testing.expect(d.render(&scene_mod.Scene{}, &.{}));
    try std.testing.expectEqual(@as(u64, 1), v.tracker.frames);
}

test "vulkan ABI pins match system headers" {
    try std.testing.expectEqual(@as(u32, 0), @backingInt(StructureType.application_info));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(StructureType.instance_create_info));
    try std.testing.expectEqual(@as(u32, 3), @backingInt(StructureType.device_create_info));
    try std.testing.expectEqual(@as(u32, 1000001000), @backingInt(StructureType.swapchain_create_info_khr));
    try std.testing.expectEqual(@as(u32, 1000006000), @backingInt(StructureType.wayland_surface_create_info_khr));
    try std.testing.expectEqual(@as(u32, 1000217000), @backingInt(StructureType.metal_surface_create_info_ext));
    try std.testing.expectEqual(@as(i32, 0), @backingInt(Result.success));
    try std.testing.expectEqual(@as(i32, -1000001004), @backingInt(Result.error_out_of_date_khr));
    try std.testing.expectEqual(@as(i32, 1000001003), @backingInt(Result.suboptimal_khr));
    try std.testing.expect(Result.error_out_of_date_khr.needsRecreate());
    try std.testing.expect(Result.suboptimal_khr.needsRecreate());
    try std.testing.expect(!Result.success.needsRecreate());
    try std.testing.expect(Result.success.isSuccess());
    try std.testing.expect(!Result.error_device_lost.isSuccess());
    try std.testing.expectEqual(@as(u32, 2), @backingInt(PresentModeKHR.fromPresentMode(.vsync)));
    try std.testing.expectEqual(@as(u32, 0), @backingInt(PresentModeKHR.fromPresentMode(.immediate)));
    try std.testing.expectEqual(@as(u32, 44), @backingInt(Format.b8g8r8a8_unorm));
    try std.testing.expectEqual(Format.b8g8r8a8_unorm, Format.forComposition(.sdr).?);
    try std.testing.expectEqual(Format.r16g16b16a16_sfloat, Format.forComposition(.hdr_extended_linear).?);
    try std.testing.expectEqual(@as(?Format, null), Format.forComposition(.hdr10_st2084));
    try std.testing.expectEqual(@as(u32, 0x00400000), api_version_1_0);
    // Struct default sTypes must already be correct for direct submission.
    try std.testing.expectEqual(StructureType.instance_create_info, (InstanceCreateInfo{}).sType);
    try std.testing.expectEqual(StructureType.device_create_info, (DeviceCreateInfo{}).sType);
    try std.testing.expectEqual(StructureType.swapchain_create_info_khr, (SwapchainCreateInfoKHR{}).sType);
    try std.testing.expectEqual(StructureType.wayland_surface_create_info_khr, (WaylandSurfaceCreateInfoKHR{}).sType);
    try std.testing.expectEqual(@as(usize, 2), requiredInstanceExtensions(.wayland).len);
    try std.testing.expectEqualStrings(ext_wayland_surface, requiredInstanceExtensions(.wayland)[1]);
    try std.testing.expect(planned_device_functions.len >= 20);
}
