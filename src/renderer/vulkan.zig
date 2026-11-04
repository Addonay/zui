//! Vulkan bootstrap for the GPU renderer: loads libvulkan at runtime, creates the
//! instance and device the `gpu` layer requires, and owns per-window swapchains.
//! Nothing here is linked at build time, so a machine without Vulkan simply falls
//! back to the CPU renderer. The extern structs are the Vulkan ABI (vulkan_core.h).
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("../gpu/root.zig");
const dl = @import("../platform/linux/dl.zig");
const sdk = @import("../gpu/backends/vulkan/sdk.zig");

const Instance = ?*anyopaque;
const PhysicalDevice = ?*anyopaque;
const Device = ?*anyopaque;
const Queue = ?*anyopaque;
const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;

const SUCCESS = 0;
const SUBOPTIMAL = 1000001003;
const ERROR_OUT_OF_DATE = -1000001004;
const ERROR_SURFACE_LOST = -1000000000;
const TRUE = 1;
const API_VERSION_1_3: u32 = (1 << 22) | (3 << 12);
const QUEUE_GRAPHICS: u32 = 0x1;
const DEVICE_TYPE_DISCRETE = 2;
const DEVICE_TYPE_INTEGRATED = 1;
const DEVICE_TYPE_CPU = 4;
const FORMAT_RGBA8 = 37;
const FORMAT_BGRA8 = 44;
const COLOR_SPACE_SRGB_NONLINEAR = 0;
const PRESENT_MODE_MAILBOX = 1;
const PRESENT_MODE_FIFO = 2;
const COMPOSITE_ALPHA_OPAQUE: u32 = 0x1;
const COMPOSITE_ALPHA_PREMULTIPLIED: u32 = 0x2;
const USAGE_COLOR_ATTACHMENT: u32 = 0x10;
const USAGE_TRANSFER_SRC: u32 = 0x1;

const ApplicationInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = 0,
};
const InstanceCreateInfo = extern struct {
    sType: i32 = 1,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: ?*const ApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};
const DeviceQueueCreateInfo = extern struct {
    sType: i32 = 2,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32 = 0,
    queueCount: u32 = 0,
    pQueuePriorities: ?[*]const f32 = null,
};
const DeviceCreateInfo = extern struct {
    sType: i32 = 3,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueCreateInfoCount: u32 = 0,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};
const ExtensionProperties = extern struct { name: [256]u8, specVersion: u32 };
const LayerProperties = extern struct { name: [256]u8, specVersion: u32, implementationVersion: u32, description: [256]u8 };
const QueueFamilyProperties = extern struct { queueFlags: u32, queueCount: u32, timestampValidBits: u32, minImageTransferGranularity: [3]u32 };
const Features2 = sdk.PhysicalDeviceFeatures2;
const DeviceProperties = sdk.PhysicalDeviceProperties;
const PhysicalDeviceVulkan12Features = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    samplerMirrorClampToEdge: u32 = 0,
    drawIndirectCount: u32 = 0,
    storageBuffer8BitAccess: u32 = 0,
    uniformAndStorageBuffer8BitAccess: u32 = 0,
    storagePushConstant8: u32 = 0,
    shaderBufferInt64Atomics: u32 = 0,
    shaderSharedInt64Atomics: u32 = 0,
    shaderFloat16: u32 = 0,
    shaderInt8: u32 = 0,
    descriptorIndexing: u32 = 0,
    shaderInputAttachmentArrayDynamicIndexing: u32 = 0,
    shaderUniformTexelBufferArrayDynamicIndexing: u32 = 0,
    shaderStorageTexelBufferArrayDynamicIndexing: u32 = 0,
    shaderUniformBufferArrayNonUniformIndexing: u32 = 0,
    shaderSampledImageArrayNonUniformIndexing: u32 = 0,
    shaderStorageBufferArrayNonUniformIndexing: u32 = 0,
    shaderStorageImageArrayNonUniformIndexing: u32 = 0,
    shaderInputAttachmentArrayNonUniformIndexing: u32 = 0,
    shaderUniformTexelBufferArrayNonUniformIndexing: u32 = 0,
    shaderStorageTexelBufferArrayNonUniformIndexing: u32 = 0,
    descriptorBindingUniformBufferUpdateAfterBind: u32 = 0,
    descriptorBindingSampledImageUpdateAfterBind: u32 = 0,
    descriptorBindingStorageImageUpdateAfterBind: u32 = 0,
    descriptorBindingStorageBufferUpdateAfterBind: u32 = 0,
    descriptorBindingUniformTexelBufferUpdateAfterBind: u32 = 0,
    descriptorBindingStorageTexelBufferUpdateAfterBind: u32 = 0,
    descriptorBindingUpdateUnusedWhilePending: u32 = 0,
    descriptorBindingPartiallyBound: u32 = 0,
    descriptorBindingVariableDescriptorCount: u32 = 0,
    runtimeDescriptorArray: u32 = 0,
    samplerFilterMinmax: u32 = 0,
    scalarBlockLayout: u32 = 0,
    imagelessFramebuffer: u32 = 0,
    uniformBufferStandardLayout: u32 = 0,
    shaderSubgroupExtendedTypes: u32 = 0,
    separateDepthStencilLayouts: u32 = 0,
    hostQueryReset: u32 = 0,
    timelineSemaphore: u32 = 0,
    bufferDeviceAddress: u32 = 0,
    bufferDeviceAddressCaptureReplay: u32 = 0,
    bufferDeviceAddressMultiDevice: u32 = 0,
    vulkanMemoryModel: u32 = 0,
    vulkanMemoryModelDeviceScope: u32 = 0,
    vulkanMemoryModelAvailabilityVisibilityChains: u32 = 0,
    shaderOutputViewportIndex: u32 = 0,
    shaderOutputLayer: u32 = 0,
    subgroupBroadcastDynamicId: u32 = 0,
};
const PhysicalDeviceVulkan13Features = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    robustImageAccess: u32 = 0,
    inlineUniformBlock: u32 = 0,
    descriptorBindingInlineUniformBlockUpdateAfterBind: u32 = 0,
    pipelineCreationCacheControl: u32 = 0,
    privateData: u32 = 0,
    shaderDemoteToHelperInvocation: u32 = 0,
    shaderTerminateInvocation: u32 = 0,
    subgroupSizeControl: u32 = 0,
    computeFullSubgroups: u32 = 0,
    synchronization2: u32 = 0,
    textureCompressionASTC_HDR: u32 = 0,
    shaderZeroInitializeWorkgroupMemory: u32 = 0,
    dynamicRendering: u32 = 0,
    shaderIntegerDotProduct: u32 = 0,
    maintenance4: u32 = 0,
};

const Extent = extern struct { width: u32, height: u32 };
const WaylandSurfaceInfo = extern struct { sType: i32 = 1000006000, pNext: ?*const anyopaque = null, flags: u32 = 0, display: *anyopaque, surface: *anyopaque };
const XlibSurfaceInfo = extern struct { sType: i32 = 1000004000, pNext: ?*const anyopaque = null, flags: u32 = 0, display: *anyopaque, window: c_ulong };
const Capabilities = extern struct { minImageCount: u32, maxImageCount: u32, currentExtent: Extent, minImageExtent: Extent, maxImageExtent: Extent, maxImageArrayLayers: u32, supportedTransforms: u32, currentTransform: u32, supportedCompositeAlpha: u32, supportedUsageFlags: u32 };
const SurfaceFormat = extern struct { format: i32, colorSpace: i32 };
const SwapchainCreateInfo = extern struct {
    sType: i32 = 1000001000,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: u64,
    minImageCount: u32,
    imageFormat: i32,
    imageColorSpace: i32,
    imageExtent: Extent,
    imageArrayLayers: u32 = 1,
    imageUsage: u32,
    imageSharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
    preTransform: u32,
    compositeAlpha: u32,
    presentMode: i32,
    clipped: u32 = 1,
    oldSwapchain: u64 = 0,
};
const ComponentMapping = extern struct { r: i32 = 0, g: i32 = 0, b: i32 = 0, a: i32 = 0 };
const SubresourceRange = extern struct { aspectMask: u32 = 1, baseMipLevel: u32 = 0, levelCount: u32 = 1, baseArrayLayer: u32 = 0, layerCount: u32 = 1 };
const ImageViewCreateInfo = extern struct {
    sType: i32 = 15,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    image: u64,
    viewType: i32 = 1,
    format: i32,
    components: ComponentMapping = .{},
    subresourceRange: SubresourceRange = .{},
};
const SemaphoreCreateInfo = extern struct { sType: i32 = 9, pNext: ?*const anyopaque = null, flags: u32 = 0 };
const PresentInfo = extern struct {
    sType: i32 = 1000001001,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 1,
    pWaitSemaphores: *const u64,
    swapchainCount: u32 = 1,
    pSwapchains: *const u64,
    pImageIndices: *const u32,
    pResults: ?*i32 = null,
};

/// Instance-level entry points, resolved through vkGetInstanceProcAddr.
const InstanceFns = struct {
    vkDestroyInstance: *const fn (Instance, ?*const anyopaque) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) i32,
    vkGetPhysicalDeviceProperties: *const fn (PhysicalDevice, *DeviceProperties) callconv(.c) void,
    vkGetPhysicalDeviceFeatures2: *const fn (PhysicalDevice, *Features2) callconv(.c) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void,
    vkEnumerateDeviceExtensionProperties: *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) i32,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(.c) i32,
    vkGetDeviceProcAddr: *const fn (Device, [*:0]const u8) callconv(.c) ?*const anyopaque,
};

/// Device-level entry points. Swapchain functions stay null on headless contexts.
const DeviceFns = struct {
    vkDestroyDevice: *const fn (Device, ?*const anyopaque) callconv(.c) void,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) i32,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(.c) void,
    vkCreateImageView: *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroyImageView: *const fn (Device, u64, ?*const anyopaque) callconv(.c) void,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroySemaphore: *const fn (Device, u64, ?*const anyopaque) callconv(.c) void,
};

const SwapchainFns = struct {
    vkCreateSwapchainKHR: *const fn (Device, *const SwapchainCreateInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroySwapchainKHR: *const fn (Device, u64, ?*const anyopaque) callconv(.c) void,
    vkGetSwapchainImagesKHR: *const fn (Device, u64, *u32, ?[*]u64) callconv(.c) i32,
    vkAcquireNextImageKHR: *const fn (Device, u64, u64, u64, u64, *u32) callconv(.c) i32,
    vkQueuePresentKHR: *const fn (Queue, *const PresentInfo) callconv(.c) i32,
};

const SurfaceFns = struct {
    vkDestroySurfaceKHR: *const fn (Instance, u64, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (PhysicalDevice, u32, u64, *u32) callconv(.c) i32,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (PhysicalDevice, u64, *Capabilities) callconv(.c) i32,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (PhysicalDevice, u64, *u32, ?[*]SurfaceFormat) callconv(.c) i32,
    vkGetPhysicalDeviceSurfacePresentModesKHR: *const fn (PhysicalDevice, u64, *u32, ?[*]i32) callconv(.c) i32,
};

/// Which window system surfaces the instance must be able to create.
pub const WindowSystem = enum { headless, wayland, x11 };

pub const Selection = enum {
    /// Hardware devices only; software rasterizers lose to the CPU renderer.
    hardware,
    /// Anything that works, preferring hardware. For tests and explicit user requests.
    any,
};

/// One Vulkan instance and device. Every window of an application shares it.
pub const Context = struct {
    lib: dl.Library,
    get_instance: GetInstanceProcAddr,
    instance: Instance,
    physical: PhysicalDevice,
    device: Device,
    queue: Queue,
    family: u32,
    fns: InstanceFns,
    device_fns: DeviceFns,
    surface_fns: ?SurfaceFns = null,
    swapchain_fns: ?SwapchainFns = null,
    create_wayland_surface: ?*const fn (Instance, *const WaylandSurfaceInfo, ?*const anyopaque, *u64) callconv(.c) i32 = null,
    create_xlib_surface: ?*const fn (Instance, *const XlibSurfaceInfo, ?*const anyopaque, *u64) callconv(.c) i32 = null,
    device_name: [256]u8 = @splat(0),
    is_software: bool = false,

    fn resolve(comptime Fns: type, get: anytype, handle: anytype) !Fns {
        var out: Fns = undefined;
        inline for (@typeInfo(Fns).@"struct".field_names) |name| {
            const ptr = get(handle, name.ptr) orelse return error.MissingVulkanFunction;
            @field(out, name) = @ptrCast(@alignCast(ptr));
        }
        return out;
    }

    pub fn init(window_system: WindowSystem, selection: Selection) !Context {
        var lib = dl.Library.open(&.{ "libvulkan.so.1", "libvulkan.so" }) orelse return error.VulkanUnavailable;
        errdefer lib.close();
        const get = lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.VulkanUnavailable;

        const create_instance: *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(.c) i32 =
            @ptrCast(@alignCast(get(null, "vkCreateInstance") orelse return error.VulkanUnavailable));
        const enumerate_layers: *const fn (*u32, ?[*]LayerProperties) callconv(.c) i32 =
            @ptrCast(@alignCast(get(null, "vkEnumerateInstanceLayerProperties") orelse return error.VulkanUnavailable));

        var surface_extensions: [2][*:0]const u8 = undefined;
        var extension_count: u32 = 0;
        switch (window_system) {
            .headless => {},
            .wayland, .x11 => {
                surface_extensions[0] = "VK_KHR_surface";
                surface_extensions[1] = if (window_system == .wayland) "VK_KHR_wayland_surface" else "VK_KHR_xlib_surface";
                extension_count = 2;
            },
        }

        // ZUI_VULKAN_VALIDATION=1 enables the Khronos layer when it is installed.
        const validation_layer = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        var validation = false;
        if (std.c.getenv("ZUI_VULKAN_VALIDATION") != null) {
            var count: u32 = 0;
            _ = enumerate_layers(&count, null);
            var layers: [64]LayerProperties = undefined;
            count = @min(count, layers.len);
            _ = enumerate_layers(&count, &layers);
            for (layers[0..count]) |*layer| {
                if (std.mem.eql(u8, std.mem.sliceTo(&layer.name, 0), "VK_LAYER_KHRONOS_validation")) validation = true;
            }
        }

        const app_info: ApplicationInfo = .{ .pApplicationName = "zui", .pEngineName = "zui", .apiVersion = API_VERSION_1_3 };
        var instance: Instance = null;
        if (create_instance(&.{
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (validation) 1 else 0,
            .ppEnabledLayerNames = if (validation) &validation_layer else null,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = if (extension_count > 0) &surface_extensions else null,
        }, null, &instance) != SUCCESS) return error.VulkanInitFailed;

        const fns = try resolve(InstanceFns, get, instance);
        errdefer fns.vkDestroyInstance(instance, null);

        // Pick a Vulkan 1.3 device with a graphics queue, best device type first.
        var devices: [16]PhysicalDevice = undefined;
        var device_count: u32 = devices.len;
        const enumerated = fns.vkEnumeratePhysicalDevices(instance, &device_count, &devices);
        if (enumerated != SUCCESS and enumerated != 5) return error.VulkanInitFailed;

        var physical: PhysicalDevice = null;
        var family: u32 = 0;
        var best_rank: u32 = 0;
        var props: DeviceProperties = undefined;
        var chosen_name: [256]u8 = @splat(0);
        var chosen_type: i32 = 0;
        for (devices[0..device_count]) |candidate| {
            fns.vkGetPhysicalDeviceProperties(candidate, &props);
            if (props.apiVersion < API_VERSION_1_3) continue;
            if (selection == .hardware and props.deviceType == DEVICE_TYPE_CPU) continue;
            if (!requiredFeaturesPresent(&fns, candidate)) continue;
            if (window_system != .headless and !hasDeviceExtension(&fns, candidate, "VK_KHR_swapchain")) continue;
            const rank: u32 = switch (props.deviceType) {
                DEVICE_TYPE_DISCRETE => 4,
                DEVICE_TYPE_INTEGRATED => 3,
                DEVICE_TYPE_CPU => 1,
                else => 2,
            };
            if (rank <= best_rank) continue;
            var family_count: u32 = 0;
            fns.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &family_count, null);
            var families: [32]QueueFamilyProperties = undefined;
            family_count = @min(family_count, families.len);
            fns.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &family_count, &families);
            for (families[0..family_count], 0..) |*f, i| {
                if (f.queueFlags & QUEUE_GRAPHICS != 0) {
                    physical = candidate;
                    family = @intCast(i);
                    best_rank = rank;
                    chosen_name = props.deviceName;
                    chosen_type = props.deviceType;
                    break;
                }
            }
        }
        if (physical == null) return error.NoSuitableVulkanDevice;

        // Enable exactly what the gpu layer requires, plus independentBlend when present.
        var supported: Features2 = .{ .sType = 1000059000 };
        fns.vkGetPhysicalDeviceFeatures2(physical, &supported);
        var features13: PhysicalDeviceVulkan13Features = .{ .sType = 53, .synchronization2 = TRUE, .dynamicRendering = TRUE };
        var features12: PhysicalDeviceVulkan12Features = .{ .sType = 51, .pNext = &features13, .bufferDeviceAddress = TRUE };
        var features2: Features2 = .{ .sType = 1000059000, .pNext = &features12 };
        features2.features.independentBlend = supported.features.independentBlend;
        features2.features.dualSrcBlend = supported.features.dualSrcBlend;

        const priority: f32 = 1.0;
        const queue_info: DeviceQueueCreateInfo = .{ .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = @ptrCast(&priority) };
        const swapchain_extension = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device: Device = null;
        if (fns.vkCreateDevice(physical, &.{
            .pNext = &features2,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = @ptrCast(&queue_info),
            .enabledExtensionCount = if (window_system != .headless) 1 else 0,
            .ppEnabledExtensionNames = if (window_system != .headless) &swapchain_extension else null,
        }, null, &device) != SUCCESS) return error.VulkanInitFailed;

        const device_fns = try resolve(DeviceFns, fns.vkGetDeviceProcAddr, device);
        errdefer device_fns.vkDestroyDevice(device, null);
        var queue: Queue = null;
        device_fns.vkGetDeviceQueue(device, family, 0, &queue);

        var self: Context = .{
            .lib = lib,
            .get_instance = get,
            .instance = instance,
            .physical = physical,
            .device = device,
            .queue = queue,
            .family = family,
            .fns = fns,
            .device_fns = device_fns,
            .device_name = chosen_name,
            .is_software = chosen_type == DEVICE_TYPE_CPU,
        };
        if (window_system != .headless) {
            self.surface_fns = try resolve(SurfaceFns, get, instance);
            self.swapchain_fns = try resolve(SwapchainFns, fns.vkGetDeviceProcAddr, device);
            switch (window_system) {
                .wayland => self.create_wayland_surface = @ptrCast(@alignCast(get(instance, "vkCreateWaylandSurfaceKHR") orelse return error.MissingVulkanFunction)),
                .x11 => self.create_xlib_surface = @ptrCast(@alignCast(get(instance, "vkCreateXlibSurfaceKHR") orelse return error.MissingVulkanFunction)),
                .headless => unreachable,
            }
        }
        return self;
    }

    /// Destroys the device and instance. All swapchains and the `gpu.Device` must be gone.
    pub fn deinit(self: *Context) void {
        _ = self.device_fns.vkDeviceWaitIdle(self.device);
        self.device_fns.vkDestroyDevice(self.device, null);
        self.fns.vkDestroyInstance(self.instance, null);
        self.lib.close();
        self.* = undefined;
    }

    /// The options for `gpu.Device.init` on this context.
    pub fn device_options(self: *const Context) gpu.BackendOptions {
        return .{ .vulkan = .{
            .get_instance_proc_addr = @ptrCast(self.get_instance),
            .instance = @ptrCast(self.instance.?),
            .physical_device = @ptrCast(self.physical.?),
            .device = @ptrCast(self.device.?),
            .queue = @ptrCast(self.queue.?),
            .queue_family_index = self.family,
        } };
    }

    pub fn device_label(self: *const Context) []const u8 {
        return std.mem.sliceTo(&self.device_name, 0);
    }

    pub fn wait_idle(self: *const Context) void {
        _ = self.device_fns.vkDeviceWaitIdle(self.device);
    }

    fn requiredFeaturesPresent(fns: *const InstanceFns, candidate: PhysicalDevice) bool {
        var features13: PhysicalDeviceVulkan13Features = .{ .sType = 53 };
        var features12: PhysicalDeviceVulkan12Features = .{ .sType = 51, .pNext = &features13 };
        var features2: Features2 = .{ .sType = 1000059000, .pNext = &features12 };
        fns.vkGetPhysicalDeviceFeatures2(candidate, &features2);
        return features13.synchronization2 == TRUE and
            features13.dynamicRendering == TRUE and
            features12.bufferDeviceAddress == TRUE;
    }

    fn hasDeviceExtension(fns: *const InstanceFns, candidate: PhysicalDevice, wanted: []const u8) bool {
        var count: u32 = 0;
        if (fns.vkEnumerateDeviceExtensionProperties(candidate, null, &count, null) != SUCCESS) return false;
        var extensions: [512]ExtensionProperties = undefined;
        count = @min(count, extensions.len);
        const status = fns.vkEnumerateDeviceExtensionProperties(candidate, null, &count, &extensions);
        if (status != SUCCESS and status != 5) return false;
        for (extensions[0..count]) |*extension| {
            if (std.mem.eql(u8, std.mem.sliceTo(&extension.name, 0), wanted)) return true;
        }
        return false;
    }
};

/// The native window a swapchain presents to.
pub const NativeSurface = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    x11: struct { display: *anyopaque, window: c_ulong },
};

/// The swapchain of one window. `acquire` returns null when no image can be drawn
/// right now (window has no size, or the swapchain went stale and must wait a frame).
pub const WindowSwapchain = struct {
    const max_images = 8;

    ctx: *Context,
    surface: u64,
    swapchain: u64 = 0,
    format: SurfaceFormat = .{ .format = FORMAT_BGRA8, .colorSpace = COLOR_SPACE_SRGB_NONLINEAR },
    color_format: gpu.PixelFormat = .bgra8,
    present_mode: i32 = PRESENT_MODE_FIFO,
    composite_alpha: u32 = COMPOSITE_ALPHA_OPAQUE,
    transparent: bool,
    width: u32 = 0,
    height: u32 = 0,
    count: u32 = 0,
    images: [max_images]u64 = @splat(0),
    views: [max_images]u64 = @splat(0),
    /// Signaled by presentation-ready rendering; one per image, reused when it is acquired again.
    finished: [max_images]u64 = @splat(0),
    /// Waited by rendering. One per image plus a spare, swapped into the acquired image's slot.
    acquired: [max_images]u64 = @splat(0),
    spare_acquired: u64 = 0,
    index: u32 = 0,
    needs_recreate: bool = false,

    pub const Options = struct {
        /// True when the compositor paces the window by itself (Wayland frame callbacks):
        /// mailbox then never blocks the main thread on an occluded window.
        externally_paced: bool = false,
        transparent: bool = false,
    };

    pub fn init(ctx: *Context, native: NativeSurface, width: u32, height: u32, options: Options) !WindowSwapchain {
        const sf = ctx.surface_fns orelse return error.SurfacesNotEnabled;
        var surface: u64 = 0;
        const created = switch (native) {
            .wayland => |w| (ctx.create_wayland_surface orelse return error.WrongWindowSystem)(ctx.instance, &.{ .display = w.display, .surface = w.surface }, null, &surface),
            .x11 => |x| (ctx.create_xlib_surface orelse return error.WrongWindowSystem)(ctx.instance, &.{ .display = x.display, .window = x.window }, null, &surface),
        };
        if (created != SUCCESS) return error.SurfaceCreationFailed;
        errdefer sf.vkDestroySurfaceKHR(ctx.instance, surface, null);

        var supported: u32 = 0;
        if (sf.vkGetPhysicalDeviceSurfaceSupportKHR(ctx.physical, ctx.family, surface, &supported) != SUCCESS or supported == 0) return error.QueueCannotPresent;

        var format_count: u32 = 0;
        if (sf.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical, surface, &format_count, null) != SUCCESS) return error.SurfaceQueryFailed;
        var formats: [64]SurfaceFormat = undefined;
        format_count = @min(format_count, formats.len);
        const format_status = sf.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical, surface, &format_count, &formats);
        if (format_status != SUCCESS and format_status != 5) return error.SurfaceQueryFailed;
        // Non-sRGB targets, as in GPUI: its blending happens in the encoded space.
        const chosen: SurfaceFormat = pick: {
            for (formats[0..format_count]) |f| if (f.format == FORMAT_BGRA8 and f.colorSpace == COLOR_SPACE_SRGB_NONLINEAR) break :pick f;
            for (formats[0..format_count]) |f| if (f.format == FORMAT_RGBA8 and f.colorSpace == COLOR_SPACE_SRGB_NONLINEAR) break :pick f;
            return error.NoUsableSurfaceFormat;
        };

        var mode_count: u32 = 0;
        var modes: [16]i32 = undefined;
        if (sf.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physical, surface, &mode_count, null) != SUCCESS) return error.SurfaceQueryFailed;
        mode_count = @min(mode_count, modes.len);
        const mode_status = sf.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physical, surface, &mode_count, &modes);
        if (mode_status != SUCCESS and mode_status != 5) return error.SurfaceQueryFailed;
        var present_mode: i32 = PRESENT_MODE_FIFO;
        if (options.externally_paced) {
            for (modes[0..mode_count]) |mode| if (mode == PRESENT_MODE_MAILBOX) {
                present_mode = PRESENT_MODE_MAILBOX;
            };
        }

        var self: WindowSwapchain = .{
            .ctx = ctx,
            .surface = surface,
            .format = chosen,
            .color_format = if (chosen.format == FORMAT_BGRA8) .bgra8 else .rgba8,
            .present_mode = present_mode,
            .transparent = options.transparent,
        };
        errdefer self.destroy_sync();
        self.spare_acquired = try self.new_semaphore();
        try self.recreate(width, height);
        return self;
    }

    pub fn deinit(self: *WindowSwapchain) void {
        self.ctx.wait_idle();
        self.destroy_images();
        self.destroy_sync();
        const sc = self.ctx.swapchain_fns.?;
        if (self.swapchain != 0) sc.vkDestroySwapchainKHR(self.ctx.device, self.swapchain, null);
        self.ctx.surface_fns.?.vkDestroySurfaceKHR(self.ctx.instance, self.surface, null);
        self.* = undefined;
    }

    fn new_semaphore(self: *WindowSwapchain) !u64 {
        var semaphore: u64 = 0;
        if (self.ctx.device_fns.vkCreateSemaphore(self.ctx.device, &.{}, null, &semaphore) != SUCCESS) return error.SemaphoreCreationFailed;
        return semaphore;
    }

    fn destroy_sync(self: *WindowSwapchain) void {
        const d = &self.ctx.device_fns;
        for (&self.finished) |*s| if (s.* != 0) {
            d.vkDestroySemaphore(self.ctx.device, s.*, null);
            s.* = 0;
        };
        for (&self.acquired) |*s| if (s.* != 0) {
            d.vkDestroySemaphore(self.ctx.device, s.*, null);
            s.* = 0;
        };
        if (self.spare_acquired != 0) {
            d.vkDestroySemaphore(self.ctx.device, self.spare_acquired, null);
            self.spare_acquired = 0;
        }
    }

    fn destroy_images(self: *WindowSwapchain) void {
        const d = &self.ctx.device_fns;
        for (self.views[0..self.count]) |view| if (view != 0) d.vkDestroyImageView(self.ctx.device, view, null);
        self.views = @splat(0);
        self.images = @splat(0);
        self.count = 0;
    }

    /// (Re)creates the swapchain at `width`x`height`; caller guarantees the queue is idle.
    fn recreate(self: *WindowSwapchain, width: u32, height: u32) !void {
        const ctx = self.ctx;
        const sc = ctx.swapchain_fns.?;
        const sf = ctx.surface_fns.?;
        var caps: Capabilities = undefined;
        if (sf.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical, self.surface, &caps) != SUCCESS) return error.SurfaceQueryFailed;

        // Wayland reports 0xffffffff: the client decides, within the advertised range.
        const extent: Extent = if (caps.currentExtent.width == 0xffffffff) .{
            .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
        } else caps.currentExtent;
        if (extent.width == 0 or extent.height == 0) return error.ZeroSizedSurface;

        var image_count = @max(caps.minImageCount + 1, 2);
        if (caps.maxImageCount != 0) image_count = @min(image_count, caps.maxImageCount);
        image_count = @min(image_count, max_images);

        const alpha: u32 = if (self.transparent and caps.supportedCompositeAlpha & COMPOSITE_ALPHA_PREMULTIPLIED != 0)
            COMPOSITE_ALPHA_PREMULTIPLIED
        else if (caps.supportedCompositeAlpha & COMPOSITE_ALPHA_OPAQUE != 0)
            COMPOSITE_ALPHA_OPAQUE
        else
            @as(u32, 1) << @intCast(@ctz(caps.supportedCompositeAlpha));
        self.composite_alpha = alpha;

        var swapchain: u64 = 0;
        if (sc.vkCreateSwapchainKHR(ctx.device, &.{
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.format.format,
            .imageColorSpace = self.format.colorSpace,
            .imageExtent = extent,
            .imageUsage = USAGE_COLOR_ATTACHMENT | (caps.supportedUsageFlags & USAGE_TRANSFER_SRC),
            .preTransform = caps.currentTransform,
            .compositeAlpha = alpha,
            .presentMode = self.present_mode,
            .oldSwapchain = self.swapchain,
        }, null, &swapchain) != SUCCESS) return error.SwapchainCreationFailed;

        self.destroy_images();
        if (self.swapchain != 0) sc.vkDestroySwapchainKHR(ctx.device, self.swapchain, null);
        self.swapchain = swapchain;
        self.width = extent.width;
        self.height = extent.height;

        var count: u32 = max_images;
        const images_status = sc.vkGetSwapchainImagesKHR(ctx.device, swapchain, &count, &self.images);
        if (images_status != SUCCESS and images_status != 5) return error.SwapchainCreationFailed;
        for (self.images[0..count], 0..) |image, i| {
            if (ctx.device_fns.vkCreateImageView(ctx.device, &.{ .image = image, .format = self.format.format }, null, &self.views[i]) != SUCCESS) return error.SwapchainCreationFailed;
            self.count = @intCast(i + 1);
            if (self.finished[i] == 0) self.finished[i] = try self.new_semaphore();
            if (self.acquired[i] == 0) self.acquired[i] = try self.new_semaphore();
        }
        self.needs_recreate = false;
    }

    /// The next image to draw into, or null when this frame must be skipped. Size is in physical pixels.
    pub fn acquire(self: *WindowSwapchain, width: u32, height: u32) !?gpu.Swapchain {
        if (width == 0 or height == 0) return null;
        if (self.needs_recreate or width != self.width or height != self.height) {
            self.ctx.wait_idle();
            try self.recreate(width, height);
        }
        const sc = self.ctx.swapchain_fns.?;
        const semaphore = self.spare_acquired;
        const status = sc.vkAcquireNextImageKHR(self.ctx.device, self.swapchain, std.math.maxInt(u64), semaphore, 0, &self.index);
        switch (status) {
            SUCCESS, SUBOPTIMAL => {},
            ERROR_OUT_OF_DATE => {
                self.needs_recreate = true;
                return null;
            },
            else => return error.AcquireFailed,
        }
        if (status == SUBOPTIMAL) self.needs_recreate = true;
        // The semaphore previously tied to this image is unused by now: its wait happened
        // in the submission that finished before this image could be acquired again.
        self.spare_acquired = self.acquired[self.index];
        self.acquired[self.index] = semaphore;
        return .{
            .width = self.width,
            .height = self.height,
            .sample_count = 1,
            .color_format = self.color_format,
            .depth_format = .none,
            .native = .{ .vulkan = .{
                .render_image = @ptrFromInt(self.images[self.index]),
                .render_view = @ptrFromInt(self.views[self.index]),
                .render_finished_semaphore = @ptrFromInt(self.finished[self.index]),
                .present_complete_semaphore = @ptrFromInt(semaphore),
            } },
        };
    }

    /// Presents the image drawn since `acquire`. The device must have been committed.
    pub fn present(self: *WindowSwapchain) !void {
        const sc = self.ctx.swapchain_fns.?;
        const status = sc.vkQueuePresentKHR(self.ctx.queue, &.{
            .pWaitSemaphores = &self.finished[self.index],
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.index,
        });
        switch (status) {
            SUCCESS => {},
            SUBOPTIMAL, ERROR_OUT_OF_DATE => self.needs_recreate = true,
            ERROR_SURFACE_LOST => return error.SurfaceLost,
            else => return error.PresentFailed,
        }
    }
};
