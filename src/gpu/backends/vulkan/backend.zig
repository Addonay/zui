//! Native Vulkan backend, the counterpart of the `_sg_vk_*` functions of
//! sokol_gfx.h:20694-24132. Uses dynamic rendering, synchronization2 and the
//! VK_EXT_descriptor_buffer extension; all entry points are loaded at runtime.
const std = @import("std");
const observe = @import("result.zig").observe;
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const c = @import("../../constants.zig");
const config = @import("../../config.zig");
const sdk = @import("sdk.zig");
const barrier = @import("barrier.zig");
const convert = @import("convert.zig");
const formats = @import("../../formats.zig");
const memory = @import("memory.zig");
const res = @import("resources.zig");

const cache = @import("pipeline_cache.zig");
const sets = @import("descriptor_sets.zig");

const num_inflight = c.num_inflight_frames;
const max_ub_slots = c.max_uniformblock_bindslots;
const max_view_slots = c.max_view_bindslots;
const max_smp_slots = c.max_sampler_bindslots;
const max_vb_slots = c.max_vertexbuffer_bindslots;
const max_vertex_attrs = 16;

fn fromOpaque(p: ?*const anyopaque) u64 {
    return if (p) |v| @intFromPtr(v) else 0;
}

/// Set of "frame in flight" resources: command buffers, fences and delete queue.
const Frame = struct {
    cmd_pool: u64 = 0,
    cmd_buf: sdk.CommandBuffer = null,
    stream_cmd_buf: sdk.CommandBuffer = null,
    slots: [num_inflight]Slot = memory.fillDefault(Slot, num_inflight),

    const Slot = struct {
        fence: u64 = 0,
        command_buffer: sdk.CommandBuffer = null,
        stream_command_buffer: sdk.CommandBuffer = null,
        delete_queue: memory.DeleteQueue = .{},
        uploads: memory.UploadArena = .{},
    };
};

const CopyStaging = struct {
    cmd_pool: u64 = 0,
    cmd_buf: sdk.CommandBuffer = null,
    size: u32 = 0,
};

const Stage = struct {
    copy: CopyStaging = .{},
    stream: memory.SharedBuffer = .{},
};

const Uniforms = struct {
    dirty: bool = false,
    dbuf: memory.SharedBuffer = .{},
    addr_info: [max_ub_slots]sdk.DescriptorAddressInfoEXT = std.mem.zeroes([max_ub_slots]sdk.DescriptorAddressInfoEXT),
    get_info: [max_ub_slots]sdk.DescriptorGetInfoEXT = std.mem.zeroes([max_ub_slots]sdk.DescriptorGetInfoEXT),
    dset_cache_size: usize = 0,
    dset_cache: []u8 = &.{},
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    use_descriptor_buffer: bool = false,
    descriptor_set_capacity: u32 = 4096,
    pipeline_cache: sdk.PipelineCache = 0,
    descriptor_sets_used: u32 = 0,
    delete_queue_budget: usize = 0,
    descriptor_pools: [num_inflight]sdk.DescriptorPool = @splat(0),
    uniform_buffer_infos: [max_ub_slots]sdk.DescriptorBufferInfo = std.mem.zeroes([max_ub_slots]sdk.DescriptorBufferInfo),
    fns: sdk.Dispatch = .{},
    instance: sdk.Instance = null,
    phys_dev: sdk.PhysicalDevice = null,
    dev: sdk.Device = null,
    queue: sdk.Queue = null,
    queue_family_index: u32 = 0,
    /// The swapchain of the current pass (`_sg.vk.swapchain`), cleared at end of pass.
    swapchain: t.VulkanSwapchain = .{},
    swapchain_track_frame_index: u32 = 0,
    swapchain_track_render_image: u64 = 0,
    present_complete_sem: u64 = 0,
    render_finished_sem: u64 = 0,
    frame_slot: usize = 0,
    frame: Frame = .{},
    stage: Stage = .{},
    uniforms: Uniforms = .{},
    bind: memory.SharedBuffer = .{},
    track_buffers: memory.Track = .{},
    track_images: memory.Track = .{},
    dev_props: sdk.PhysicalDeviceProperties2 = std.mem.zeroes(sdk.PhysicalDeviceProperties2),
    descriptor_buffer_props: sdk.PhysicalDeviceDescriptorBufferPropertiesEXT = std.mem.zeroes(sdk.PhysicalDeviceDescriptorBufferPropertiesEXT),
    dev_features: sdk.PhysicalDeviceFeatures2 = std.mem.zeroes(sdk.PhysicalDeviceFeatures2),

    // ------------------------------------------------------------ lifecycle

    /// Creates the backend, and fills in features, limits and pixel format caps (_sg_vk_setup_backend).
    pub fn init(s: *core.State) !Backend {
        const desc = &s.desc;
        const env = s.desc.environment.vulkan;
        const get_instance_ptr = env.get_instance_proc_addr orelse return error.MissingVulkanLoader;
        const get_instance: sdk.GetInstanceProcAddr = @ptrCast(@alignCast(get_instance_ptr));
        const instance = env.instance orelse return error.MissingVulkanDevice;
        const phys_dev = env.physical_device orelse return error.MissingVulkanDevice;
        const device = env.device orelse return error.MissingVulkanDevice;
        const queue = env.queue orelse return error.MissingVulkanDevice;
        std.debug.assert(s.desc.uniform_buffer_size > 0);

        var self: Backend = .{
            .allocator = s.allocator,
            .use_descriptor_buffer = desc.vulkan.use_descriptor_buffer,
            .descriptor_set_capacity = desc.vulkan.descriptor_set_capacity,
            .instance = @constCast(instance),
            .phys_dev = @constCast(phys_dev),
            .dev = @constCast(device),
            .queue = @constCast(queue),
            .queue_family_index = env.queue_family_index,
        };
        self.fns.load(get_instance, self.instance, self.dev) catch return error.VulkanInitFailed;
        const d = &self.fns.device;
        if (self.use_descriptor_buffer and (d.vkGetDescriptorSetLayoutSizeEXT == null or d.vkGetDescriptorSetLayoutBindingOffsetEXT == null or
            d.vkGetDescriptorEXT == null or d.vkCmdBindDescriptorBuffersEXT == null or d.vkCmdSetDescriptorBufferOffsetsEXT == null))
        {
            return error.MissingVulkanExtension;
        }

        self.track_buffers = try memory.Track.init(s.allocator, @intCast(s.desc.buffer_pool_size));
        errdefer self.track_buffers.deinit(s.allocator);
        self.track_images = try memory.Track.init(s.allocator, @intCast(s.desc.image_pool_size));
        errdefer self.track_images.deinit(s.allocator);

        self.initCaps(s);
        try cache.init(&self, desc.vulkan.pipeline_cache_data);
        errdefer cache.deinit(&self);
        // each cleanup is registered before its step, since the discard
        // functions accept partially created (null) objects
        errdefer self.destroyFences();
        try self.createFences();
        errdefer self.destroyFrameCommandPool();
        try self.createFrameCommandPoolAndBuffers();
        errdefer memory.stagingCopyDiscard(&self);
        try memory.stagingCopyInit(&self, desc);
        memory.stagingStreamInit(&self, desc);
        errdefer memory.sharedBufferDiscard(&self, &self.stage.stream);
        errdefer memory.uniformDiscard(&self);
        try memory.uniformInit(&self, desc);
        memory.bindInit(&self, desc);
        if (!self.use_descriptor_buffer) try sets.init(&self, self.descriptor_set_capacity);
        errdefer if (!self.use_descriptor_buffer) sets.deinit(&self);
        errdefer memory.bindDiscard(&self);
        errdefer memory.destroyDeleteQueues(&self);
        try memory.createDeleteQueues(&self, desc);
        return self;
    }

    /// Waits for the device and destroys all backend objects (_sg_vk_discard_backend).
    pub fn deinit(self: *Backend) void {
        const idle = observe(self.fns.device.vkDeviceWaitIdle(self.dev));
        if (idle != sdk.SUCCESS and idle != -4) std.debug.panic("Vulkan idle wait failed ({d}); GPU completion is unproven", .{idle});
        for (&self.frame.slots) |*slot| slot.uploads.deinit(self);
        cache.deinit(self);
        memory.destroyDeleteQueues(self);
        memory.bindDiscard(self);
        if (!self.use_descriptor_buffer) sets.deinit(self);
        memory.uniformDiscard(self);
        memory.sharedBufferDiscard(self, &self.stage.stream);
        memory.stagingCopyDiscard(self);
        self.destroyFrameCommandPool();
        self.destroyFences();
        self.track_images.deinit(self.allocator);
        self.track_buffers.deinit(self.allocator);
    }

    pub fn resetStateCache(self: *Backend) void {
        _ = self;
    }

    fn initCaps(self: *Backend, s: *core.State) void {
        const d = &self.fns;
        s.features.origin_top_left = true;
        s.features.image_clamp_to_border = true;
        s.features.compute = true;
        s.features.msaa_texture_bindings = true;
        s.features.draw_base_vertex = true;
        s.features.draw_base_instance = true;
        s.features.vertexformat_int10_n2 = true;
        s.features.copy_buffer_to_image_relaxed_buffer_type = true;
        s.features.copy_buffer_to_image_relaxed_bytes_per_row = true;

        self.descriptor_buffer_props.sType = sdk.STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT;
        self.dev_props.sType = sdk.STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        self.dev_props.pNext = if (self.use_descriptor_buffer) &self.descriptor_buffer_props else null;
        d.instance.vkGetPhysicalDeviceProperties2(self.phys_dev, &self.dev_props);
        self.dev_props.pNext = null;
        self.dev_features.sType = sdk.STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        d.instance.vkGetPhysicalDeviceFeatures2(self.phys_dev, &self.dev_features);
        s.features.mrt_independent_blend_state = self.dev_features.features.independentBlend != 0;
        s.features.mrt_independent_write_mask = self.dev_features.features.independentBlend != 0;
        s.features.dual_source_blending = self.dev_features.features.dualSrcBlend != 0;

        const l = &self.dev_props.properties.limits;
        s.limits.max_image_size_2d = @intCast(l.maxImageDimension2D);
        s.limits.max_image_size_cube = @intCast(l.maxImageDimensionCube);
        s.limits.max_image_size_3d = @intCast(l.maxImageDimension3D);
        s.limits.max_image_size_array = s.limits.max_image_size_2d;
        s.limits.max_image_array_layers = @intCast(l.maxImageArrayLayers);
        s.limits.max_vertex_attrs = @min(@as(i32, @intCast(l.maxVertexInputAttributes)), max_vertex_attrs);
        s.limits.max_color_attachments = @min(@as(i32, @intCast(l.maxFragmentOutputAttachments)), c.max_color_attachments);
        s.limits.max_texture_bindings_per_stage = @min(@as(i32, @intCast(l.maxPerStageDescriptorSampledImages)), c.max_view_bindslots);
        s.limits.max_storage_buffer_bindings_per_stage = @min(@as(i32, @intCast(l.maxPerStageDescriptorStorageBuffers)), c.max_view_bindslots);
        s.limits.max_storage_image_bindings_per_stage = @min(@as(i32, @intCast(l.maxPerStageDescriptorStorageImages)), c.max_view_bindslots);
        s.limits.vk_min_uniform_buffer_offset_alignment = @intCast(l.minUniformBufferOffsetAlignment);

        var fmt_info: sdk.PhysicalDeviceImageFormatInfo2 = std.mem.zeroes(sdk.PhysicalDeviceImageFormatInfo2);
        fmt_info.sType = sdk.STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
        fmt_info.type = sdk.IMAGE_TYPE_2D;
        fmt_info.tiling = sdk.IMAGE_TILING_OPTIMAL;
        var props2: sdk.ImageFormatProperties2 = std.mem.zeroes(sdk.ImageFormatProperties2);
        props2.sType = sdk.STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
        for (1..core.num_pixel_formats) |fmt_index| {
            const fmt: e.PixelFormat = @fromBackingInt(@intCast(fmt_index));
            var props: sdk.FormatProperties = std.mem.zeroes(sdk.FormatProperties);
            const vkfmt = convert.pixelFormat(fmt);
            d.instance.vkGetPhysicalDeviceFormatProperties(self.phys_dev, vkfmt, &props);
            const f = props.optimalTilingFeatures;
            const info = &s.formats[fmt_index];
            info.sample = f & sdk.FORMAT_FEATURE_SAMPLED_IMAGE_BIT != 0;
            info.filter = f & sdk.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT != 0;
            info.render = f & sdk.FORMAT_FEATURE_COLOR_ATTACHMENT_BIT != 0;
            info.blend = f & sdk.FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT != 0;
            info.depth = f & sdk.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT != 0;
            info.read = f & sdk.FORMAT_FEATURE_STORAGE_IMAGE_BIT != 0;
            info.write = info.read;
            if (info.depth) info.render = true;
            if (info.render or info.depth) {
                // query msaa support
                fmt_info.format = vkfmt;
                fmt_info.usage = if (info.depth) sdk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT else sdk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
                if (observe(d.instance.vkGetPhysicalDeviceImageFormatProperties2(self.phys_dev, &fmt_info, &props2)) == sdk.SUCCESS) {
                    info.msaa = props2.imageFormatProperties.sampleCounts > sdk.SAMPLE_COUNT_1_BIT;
                }
            }
        }
    }

    fn createFences(self: *Backend) !void {
        const create_info: sdk.FenceCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = sdk.FENCE_CREATE_SIGNALED_BIT,
        };
        for (&self.frame.slots) |*slot| {
            if (observe(self.fns.device.vkCreateFence(self.dev, &create_info, null, &slot.fence)) != sdk.SUCCESS) return error.VulkanInitFailed;
        }
    }

    fn destroyFences(self: *Backend) void {
        for (&self.frame.slots) |*slot| {
            self.fns.device.vkDestroyFence(self.dev, slot.fence, null);
            slot.fence = 0;
        }
    }

    fn createFrameCommandPoolAndBuffers(self: *Backend) !void {
        const pool_info: sdk.CommandPoolCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = sdk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family_index,
        };
        if (observe(self.fns.device.vkCreateCommandPool(self.dev, &pool_info, null, &self.frame.cmd_pool)) != sdk.SUCCESS) return error.VulkanInitFailed;
        for (&self.frame.slots) |*slot| {
            const alloc_info: sdk.CommandBufferAllocateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .pNext = null,
                .commandPool = self.frame.cmd_pool,
                .level = sdk.COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            };
            if (observe(self.fns.device.vkAllocateCommandBuffers(self.dev, &alloc_info, &slot.command_buffer)) != sdk.SUCCESS) return error.VulkanInitFailed;
            if (observe(self.fns.device.vkAllocateCommandBuffers(self.dev, &alloc_info, &slot.stream_command_buffer)) != sdk.SUCCESS) return error.VulkanInitFailed;
        }
    }

    fn destroyFrameCommandPool(self: *Backend) void {
        self.fns.device.vkDestroyCommandPool(self.dev, self.frame.cmd_pool, null);
        self.frame.cmd_pool = 0;
        for (&self.frame.slots) |*slot| {
            slot.command_buffer = null;
            slot.stream_command_buffer = null;
        }
    }

    /// Waits for the oldest in-flight frame and begins the command buffers of the new frame.
    fn acquireFrameCommandBuffers(self: *Backend) void {
        if (self.frame.cmd_buf != null) return;
        std.debug.assert(self.frame.stream_cmd_buf == null);
        const d = &self.fns.device;
        self.frame_slot = (self.frame_slot + 1) % num_inflight;
        const slot = &self.frame.slots[self.frame_slot];
        // block until the oldest inflight frame has finished
        var r: i32 = undefined;
        while (true) {
            r = observe(d.vkWaitForFences(self.dev, 1, @ptrCast(&slot.fence), sdk.TRUE, std.math.maxInt(u64)));
            if (r != sdk.TIMEOUT) break;
        }
        if (r != sdk.SUCCESS) {
            if (r == -4) core.recordLoss(r);
            core.logWarn(.vulkan_wait_for_fence_failed);
            core.state().cur_pass.valid = false;
            return;
        }
        _ = observe(d.vkResetFences(self.dev, 1, @ptrCast(&slot.fence)));
        memory.deleteQueueCollect(self);
        slot.uploads.reset(self);

        self.frame.cmd_buf = slot.command_buffer;
        _ = observe(d.vkResetCommandBuffer(self.frame.cmd_buf, 0));
        self.frame.stream_cmd_buf = slot.stream_command_buffer;
        _ = observe(d.vkResetCommandBuffer(self.frame.stream_cmd_buf, 0));

        const begin_info: sdk.CommandBufferBeginInfo = .{
            .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = sdk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = observe(d.vkBeginCommandBuffer(self.frame.cmd_buf, &begin_info));
        _ = observe(d.vkBeginCommandBuffer(self.frame.stream_cmd_buf, &begin_info));

        memory.uniformAfterAcquire(self);
        memory.bindAfterAcquire(self);
        memory.sharedBufferAfterAcquire(self, &self.stage.stream);
    }

    /// Initial/unsealed uploads run before rendering; those resources cannot be
    /// consumed by a draw until initialized/sealed. Arena bytes live to the fence.
    pub fn uploadCommands(self: *Backend) sdk.CommandBuffer {
        self.acquireFrameCommandBuffers();
        return self.frame.stream_cmd_buf;
    }

    fn submitFrameCommandBuffers(self: *Backend) void {
        std.debug.assert(self.frame.cmd_buf != null and self.frame.stream_cmd_buf != null);
        const d = &self.fns.device;
        memory.sharedBufferBeforeSubmit(&self.stage.stream);
        memory.bindBeforeSubmit(self);
        memory.uniformBeforeSubmit(self);

        _ = observe(d.vkEndCommandBuffer(self.frame.stream_cmd_buf));
        _ = observe(d.vkEndCommandBuffer(self.frame.cmd_buf));

        var stream_cmd = self.frame.stream_cmd_buf;
        var cmd = self.frame.cmd_buf;
        const present_wait_dst_stage_mask: u32 = sdk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var wait_sem = self.present_complete_sem;
        var signal_sem = self.render_finished_sem;
        var submit_infos: [2]sdk.SubmitInfo = std.mem.zeroes([2]sdk.SubmitInfo);
        // streaming-update command buffer
        submit_infos[0].sType = sdk.STRUCTURE_TYPE_SUBMIT_INFO;
        submit_infos[0].commandBufferCount = 1;
        submit_infos[0].pCommandBuffers = @ptrCast(&stream_cmd);
        // render command buffer
        submit_infos[1].sType = sdk.STRUCTURE_TYPE_SUBMIT_INFO;
        // NOTE: the semaphores are only provided in swapchain passes, but rendering
        // without a swapchain pass is valid (for instance headless rendering)
        if (self.present_complete_sem != 0 and self.render_finished_sem != 0) {
            submit_infos[1].waitSemaphoreCount = 1;
            submit_infos[1].pWaitSemaphores = @ptrCast(&wait_sem);
            submit_infos[1].pWaitDstStageMask = &present_wait_dst_stage_mask;
            submit_infos[1].signalSemaphoreCount = 1;
            submit_infos[1].pSignalSemaphores = @ptrCast(&signal_sem);
        }
        submit_infos[1].commandBufferCount = 1;
        submit_infos[1].pCommandBuffers = @ptrCast(&cmd);
        core.statsInc("vk.num_queue_submits");
        const result = observe(d.vkQueueSubmit(self.queue, 2, &submit_infos, self.frame.slots[self.frame_slot].fence));
        if (result == -4) core.recordLoss(result);

        self.frame.cmd_buf = null;
        self.frame.stream_cmd_buf = null;
        // NOTE: resources may be registered for destruction past this point, since
        // they can at most have been used by the command buffer just submitted
    }

    // ------------------------------------------------------------ resources

    pub fn createBuffer(self: *Backend, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        const d = &self.fns.device;
        buf.native = .{ .vulkan = .{} };
        const payload = &buf.native.vulkan;
        std.debug.assert(buf.cmn.size > 0);
        // unlike images, the initial access of buffers is their default access
        payload.cur_access = barrier.defaultBufferAccessMask(buf.cmn.usage);
        const create_info: sdk.BufferCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = buf.cmn.size,
            .usage = convert.bufferUsage(buf.cmn.usage),
            .sharingMode = sdk.SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        if (observe(d.vkCreateBuffer(self.dev, &create_info, null, &payload.buf)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_buffer_failed);
            return .failed;
        }
        std.debug.assert(payload.buf != 0);
        memory.setObjectLabel(self, sdk.OBJECT_TYPE_BUFFER, payload.buf, desc.label);
        if (!memory.allocBufferDeviceMemory(self, buf)) return .failed;
        if (observe(d.vkBindBufferMemory(self.dev, payload.buf, payload.mem, 0)) != sdk.SUCCESS) {
            core.logError(.vulkan_bind_buffer_memory_failed);
            return .failed;
        }
        if (buf.cmn.usage.storage_buffer) {
            const addr_info: sdk.BufferDeviceAddressInfo = .{
                .sType = sdk.STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
                .pNext = null,
                .buffer = payload.buf,
            };
            payload.dev_addr = d.vkGetBufferDeviceAddress(self.dev, &addr_info);
            std.debug.assert(payload.dev_addr != 0);
        }
        if (desc.data.ptr != null) {
            if (!memory.stagingCopyBufferData(self, buf, &desc.data, 0, 0, desc.data.size)) return .failed;
        }
        return .valid;
    }

    pub fn discardBuffer(self: *Backend, buf: *core.Buffer) void {
        if (buf.native != .vulkan) return;
        const payload = &buf.native.vulkan;
        self.track_buffers.remove(buf.slot.id);
        if (payload.buf != 0) {
            memory.deleteQueueAdd(self, .buffer, payload.buf);
            payload.buf = 0;
        }
        if (payload.mem != 0) {
            memory.deleteQueueAdd(self, .memory, payload.mem);
            payload.mem = 0;
        }
    }

    pub fn createImage(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        const d = &self.fns.device;
        img.native = .{ .vulkan = .{} };
        const payload = &img.native.vulkan;
        // NOTE: the initial access of images is none, their layout is UNDEFINED
        payload.cur_access = barrier.none;
        const create_info: sdk.ImageCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = convert.imageCreateFlags(img.cmn.type),
            .imageType = convert.imageType(img.cmn.type),
            .format = convert.pixelFormat(desc.pixel_format),
            .extent = .{
                .width = @intCast(img.cmn.width),
                .height = @intCast(img.cmn.height),
                .depth = if (desc.type == .@"3d") @intCast(img.cmn.num_slices) else 1,
            },
            .mipLevels = @intCast(img.cmn.num_mipmaps),
            .arrayLayers = if (desc.type == .@"3d") 1 else @intCast(img.cmn.num_slices),
            .samples = @intCast(desc.sample_count),
            .tiling = sdk.IMAGE_TILING_OPTIMAL,
            .usage = convert.imageUsage(img.cmn.usage),
            .sharingMode = sdk.SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = sdk.IMAGE_LAYOUT_UNDEFINED,
        };
        if (observe(d.vkCreateImage(self.dev, &create_info, null, &payload.img)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_image_failed);
            return .failed;
        }
        std.debug.assert(payload.img != 0);
        memory.setObjectLabel(self, sdk.OBJECT_TYPE_IMAGE, payload.img, desc.label);
        if (!memory.allocImageDeviceMemory(self, img)) return .failed;
        if (observe(d.vkBindImageMemory(self.dev, payload.img, payload.mem, 0)) != sdk.SUCCESS) {
            core.logError(.vulkan_bind_image_memory_failed);
            return .failed;
        }
        if (desc.data.mip_levels[0].ptr != null) {
            if (!memory.stagingCopyImageData(self, img, &desc.data)) return .failed;
        }
        return .valid;
    }

    pub fn discardImage(self: *Backend, img: *core.Image) void {
        if (img.native != .vulkan) return;
        const payload = &img.native.vulkan;
        self.track_images.remove(img.slot.id);
        if (payload.img != 0) {
            memory.deleteQueueAdd(self, .image, payload.img);
            payload.img = 0;
        }
        if (payload.mem != 0) {
            memory.deleteQueueAdd(self, .memory, payload.mem);
            payload.mem = 0;
        }
    }

    pub fn createSampler(self: *Backend, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        smp.native = .{ .vulkan = .{} };
        const payload = &smp.native.vulkan;
        const anisotropy: f32 = if (self.dev_features.features.samplerAnisotropy != 0)
            @min(@as(f32, @floatFromInt(desc.max_anisotropy)), self.dev_props.properties.limits.maxSamplerAnisotropy)
        else
            1;
        const create_info: sdk.SamplerCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = convert.samplerMinMagFilter(desc.mag_filter),
            .minFilter = convert.samplerMinMagFilter(desc.min_filter),
            .mipmapMode = convert.samplerMipmapMode(desc.mipmap_filter),
            .addressModeU = convert.samplerAddressMode(desc.wrap_u),
            .addressModeV = convert.samplerAddressMode(desc.wrap_v),
            .addressModeW = convert.samplerAddressMode(desc.wrap_w),
            .mipLodBias = 0.0,
            .anisotropyEnable = if (anisotropy > 1) sdk.TRUE else sdk.FALSE,
            .maxAnisotropy = anisotropy,
            .compareEnable = if (desc.compare != .never) sdk.TRUE else sdk.FALSE,
            .compareOp = if (desc.compare != .never) convert.compareOp(desc.compare) else sdk.COMPARE_OP_NEVER,
            .minLod = desc.min_lod,
            .maxLod = desc.max_lod,
            .borderColor = convert.samplerBorderColor(desc.border_color),
            .unnormalizedCoordinates = sdk.FALSE,
        };
        if (observe(self.fns.device.vkCreateSampler(self.dev, &create_info, null, &payload.smp)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_sampler_failed);
            return .failed;
        }
        std.debug.assert(payload.smp != 0);
        memory.setObjectLabel(self, sdk.OBJECT_TYPE_SAMPLER, payload.smp, desc.label);

        if (!self.use_descriptor_buffer) return .valid;
        // record sampler descriptor data
        payload.descriptor_size = @intCast(self.descriptor_buffer_props.samplerDescriptorSize);
        if (res.max_descriptor_data_size < payload.descriptor_size) {
            core.logError(.vulkan_sampler_max_descriptor_size);
            return .failed;
        }
        const get_info: sdk.DescriptorGetInfoEXT = .{
            .sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
            .pNext = null,
            .type = sdk.DESCRIPTOR_TYPE_SAMPLER,
            .data = .{ .pSampler = &payload.smp },
        };
        self.fns.device.vkGetDescriptorEXT.?(self.dev, &get_info, payload.descriptor_size, &payload.descriptor_data);
        return .valid;
    }

    pub fn discardSampler(self: *Backend, smp: *core.Sampler) void {
        if (smp.native != .vulkan) return;
        const payload = &smp.native.vulkan;
        if (payload.smp != 0) {
            memory.deleteQueueAdd(self, .sampler, payload.smp);
            payload.smp = 0;
        }
    }

    fn createShaderFunc(self: *Backend, func: *const t.ShaderFunction, label: ?[*:0]const u8) res.ShaderFunc {
        std.debug.assert(func.bytecode.ptr != null and func.bytecode.size > 0);
        std.debug.assert(func.entry != null);
        var vk_func: res.ShaderFunc = .{};
        const entry = std.mem.span(func.entry.?);
        const n = @min(entry.len, vk_func.entry.len - 1);
        @memcpy(vk_func.entry[0..n], entry[0..n]);
        var create_info: sdk.ShaderModuleCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = func.bytecode.size,
            .pCode = null,
        };
        // SPIR-V is read as 32-bit words, so unaligned bytecode is copied into aligned storage first
        const aligned = @intFromPtr(func.bytecode.ptr.?) % @alignOf(u32) == 0;
        const words: []align(@alignOf(u32)) u8 = if (aligned) &.{} else blk: {
            const copy = self.allocator.alignedAlloc(u8, .of(u32), func.bytecode.size) catch {
                core.logError(.vulkan_create_shader_module_failed);
                return vk_func;
            };
            @memcpy(copy, @as([*]const u8, @ptrCast(func.bytecode.ptr.?))[0..func.bytecode.size]);
            break :blk copy;
        };
        defer if (!aligned) self.allocator.free(words);
        create_info.pCode = if (aligned) @ptrCast(@alignCast(func.bytecode.ptr.?)) else @ptrCast(words.ptr);
        if (observe(self.fns.device.vkCreateShaderModule(self.dev, &create_info, null, &vk_func.module)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_shader_module_failed);
        } else {
            std.debug.assert(vk_func.module != 0);
            memory.setObjectLabel(self, sdk.OBJECT_TYPE_SHADER_MODULE, vk_func.module, label);
        }
        return vk_func;
    }

    fn discardShaderFunc(self: *Backend, func: *res.ShaderFunc) void {
        if (func.module != 0) {
            memory.deleteQueueAdd(self, .shader_module, func.module);
            func.module = 0;
        }
    }

    fn ensureSpirvBindslotRanges(desc: *const t.ShaderDesc) bool {
        for (&desc.uniform_blocks) |*ub| {
            if (ub.stage != .none and ub.spirv_set0_binding_n >= max_ub_slots * 2) {
                core.logError(.vulkan_uniformblock_spirv_set0_binding_out_of_range);
                return false;
            }
        }
        for (&desc.views) |*view| {
            if (view.texture.stage != .none and view.texture.spirv_set1_binding_n >= 128) {
                core.logError(.vulkan_texture_spirv_set1_binding_out_of_range);
                return false;
            }
            if (view.storage_buffer.stage != .none and view.storage_buffer.spirv_set1_binding_n >= 128) {
                core.logError(.vulkan_storagebuffer_spirv_set1_binding_out_of_range);
                return false;
            }
            if (view.storage_image.stage != .none and view.storage_image.spirv_set1_binding_n >= 128) {
                core.logError(.vulkan_storageimage_spirv_set1_binding_out_of_range);
                return false;
            }
        }
        for (&desc.samplers) |*smp| {
            if (smp.stage != .none and smp.spirv_set1_binding_n >= 128) {
                core.logError(.vulkan_sampler_spirv_set1_binding_out_of_range);
                return false;
            }
        }
        return true;
    }

    pub fn createShader(self: *Backend, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        shd.native = .{ .vulkan = .{} };
        const payload = &shd.native.vulkan;
        if (!ensureSpirvBindslotRanges(desc)) return .failed;

        // build shader modules
        var shd_valid = true;
        if (desc.vertex_func.bytecode.ptr != null) {
            payload.vertex_func = createShaderFunc(self, &desc.vertex_func, desc.label);
            shd_valid = shd_valid and payload.vertex_func.module != 0;
        }
        if (desc.fragment_func.bytecode.ptr != null) {
            payload.fragment_func = createShaderFunc(self, &desc.fragment_func, desc.label);
            shd_valid = shd_valid and payload.fragment_func.module != 0;
        }
        if (desc.compute_func.bytecode.ptr != null) {
            payload.compute_func = createShaderFunc(self, &desc.compute_func, desc.label);
            shd_valid = shd_valid and payload.compute_func.module != 0;
        }
        if (!shd_valid) {
            self.discardShaderFunc(&payload.vertex_func);
            self.discardShaderFunc(&payload.fragment_func);
            self.discardShaderFunc(&payload.compute_func);
            return .failed;
        }

        // descriptor set layouts and pipeline layout
        var dsl_entries: [max_view_slots + max_smp_slots]sdk.DescriptorSetLayoutBinding = undefined;
        var dsl_index: usize = 0;
        for (0..max_ub_slots) |i| {
            if (shd.cmn.uniform_blocks[i].stage == .none) continue;
            payload.ub_set0_bnd_n[i] = @intCast(desc.uniform_blocks[i].spirv_set0_binding_n);
            dsl_entries[dsl_index] = .{
                .binding = payload.ub_set0_bnd_n[i],
                .descriptorType = sdk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = convert.shaderStage(shd.cmn.uniform_blocks[i].stage),
                .pImmutableSamplers = null,
            };
            dsl_index += 1;
        }
        payload.ub_count = @intCast(dsl_index);
        var dsl_create_info: sdk.DescriptorSetLayoutCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = if (self.use_descriptor_buffer) sdk.DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT else 0,
            .bindingCount = @intCast(dsl_index),
            .pBindings = &dsl_entries[0],
        };
        if (observe(self.fns.device.vkCreateDescriptorSetLayout(self.dev, &dsl_create_info, null, &payload.ub_dsl)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_descriptor_set_layout_failed);
            return .failed;
        }

        if (self.use_descriptor_buffer) {
            // store uniform descriptor set size and descriptor offsets
            self.fns.device.vkGetDescriptorSetLayoutSizeEXT.?(self.dev, payload.ub_dsl, &payload.ub_dset_size);
            if (payload.ub_dset_size > self.uniforms.dset_cache_size) {
                core.logError(.vulkan_shader_uniform_descriptor_set_size_vs_cache_size);
                return .failed;
            }
            for (0..max_ub_slots) |i| {
                if (shd.cmn.uniform_blocks[i].stage == .none) continue;
                var dset_offset: u64 = 0;
                self.fns.device.vkGetDescriptorSetLayoutBindingOffsetEXT.?(self.dev, payload.ub_dsl, payload.ub_set0_bnd_n[i], &dset_offset);
                payload.ub_dset_offsets[i] = @intCast(dset_offset);
            }
        }

        dsl_index = 0;
        for (0..max_view_slots) |i| {
            if (shd.cmn.views[i].stage == .none) continue;
            std.debug.assert(dsl_index < max_view_slots + max_smp_slots);
            const view_type = shd.cmn.views[i].view_type;
            var dtype: i32 = undefined;
            if (view_type == .texture) {
                payload.view_set1_bnd_n[i] = @intCast(desc.views[i].texture.spirv_set1_binding_n);
                dtype = sdk.DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            } else if (view_type == .storagebuffer) {
                payload.view_set1_bnd_n[i] = @intCast(desc.views[i].storage_buffer.spirv_set1_binding_n);
                dtype = sdk.DESCRIPTOR_TYPE_STORAGE_BUFFER;
            } else if (view_type == .storageimage) {
                payload.view_set1_bnd_n[i] = @intCast(desc.views[i].storage_image.spirv_set1_binding_n);
                dtype = sdk.DESCRIPTOR_TYPE_STORAGE_IMAGE;
            } else unreachable;
            dsl_entries[dsl_index] = .{
                .binding = payload.view_set1_bnd_n[i],
                .descriptorType = dtype,
                .descriptorCount = 1,
                .stageFlags = convert.shaderStage(shd.cmn.views[i].stage),
                .pImmutableSamplers = null,
            };
            dsl_index += 1;
        }
        for (0..max_smp_slots) |i| {
            if (shd.cmn.samplers[i].stage == .none) continue;
            payload.smp_set1_bnd_n[i] = @intCast(desc.samplers[i].spirv_set1_binding_n);
            std.debug.assert(dsl_index < max_view_slots + max_smp_slots);
            dsl_entries[dsl_index] = .{
                .binding = payload.smp_set1_bnd_n[i],
                .descriptorType = sdk.DESCRIPTOR_TYPE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = convert.shaderStage(shd.cmn.samplers[i].stage),
                .pImmutableSamplers = null,
            };
            dsl_index += 1;
        }
        payload.view_smp_count = @intCast(dsl_index);
        dsl_create_info.bindingCount = @intCast(dsl_index);
        dsl_create_info.pBindings = &dsl_entries[0];
        if (observe(self.fns.device.vkCreateDescriptorSetLayout(self.dev, &dsl_create_info, null, &payload.view_smp_dsl)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_descriptor_set_layout_failed);
            return .failed;
        }

        if (self.use_descriptor_buffer) {
            // store view/smp descriptor set size and descriptor offsets
            self.fns.device.vkGetDescriptorSetLayoutSizeEXT.?(self.dev, payload.view_smp_dsl, &payload.view_smp_dset_size);
            for (0..max_view_slots) |i| {
                if (shd.cmn.views[i].stage == .none) continue;
                var dset_offset: u64 = 0;
                self.fns.device.vkGetDescriptorSetLayoutBindingOffsetEXT.?(self.dev, payload.view_smp_dsl, payload.view_set1_bnd_n[i], &dset_offset);
                payload.view_dset_offsets[i] = @intCast(dset_offset);
            }
            for (0..max_smp_slots) |i| {
                if (shd.cmn.samplers[i].stage == .none) continue;
                var dset_offset: u64 = 0;
                self.fns.device.vkGetDescriptorSetLayoutBindingOffsetEXT.?(self.dev, payload.view_smp_dsl, payload.smp_set1_bnd_n[i], &dset_offset);
                payload.smp_dset_offsets[i] = @intCast(dset_offset);
            }
        }

        var set_layouts: [2]sdk.DescriptorSetLayout = .{ payload.ub_dsl, payload.view_smp_dsl };
        const pl_create_info: sdk.PipelineLayoutCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 2,
            .pSetLayouts = &set_layouts[0],
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        if (observe(self.fns.device.vkCreatePipelineLayout(self.dev, &pl_create_info, null, &payload.pip_layout)) != sdk.SUCCESS) {
            core.logError(.vulkan_create_pipeline_layout_failed);
            return .failed;
        }
        return .valid;
    }

    pub fn discardShader(self: *Backend, shd: *core.Shader) void {
        if (shd.native != .vulkan) return;
        const payload = &shd.native.vulkan;
        self.discardShaderFunc(&payload.vertex_func);
        self.discardShaderFunc(&payload.fragment_func);
        self.discardShaderFunc(&payload.compute_func);
        if (payload.pip_layout != 0) {
            memory.deleteQueueAdd(self, .pipeline_layout, payload.pip_layout);
            payload.pip_layout = 0;
        }
        if (payload.ub_dsl != 0) {
            memory.deleteQueueAdd(self, .descriptor_set_layout, payload.ub_dsl);
            payload.ub_dsl = 0;
        }
        if (payload.view_smp_dsl != 0) {
            memory.deleteQueueAdd(self, .descriptor_set_layout, payload.view_smp_dsl);
            payload.view_smp_dsl = 0;
        }
    }

    pub fn createPipeline(self: *Backend, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        const d = &self.fns.device;
        pip.native = .{ .vulkan = .{} };
        const payload = &pip.native.vulkan;
        const shd = pip.cmn.shader.get();
        const shd_payload = &shd.native.vulkan;
        std.debug.assert(shd_payload.pip_layout != 0);
        if (pip.cmn.is_compute) {
            std.debug.assert(shd_payload.compute_func.module != 0);
            const pip_create_info: sdk.ComputePipelineCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                .pNext = null,
                .flags = if (self.use_descriptor_buffer) sdk.PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT else 0,
                .stage = .{
                    .sType = sdk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .stage = sdk.SHADER_STAGE_COMPUTE_BIT,
                    .module = shd_payload.compute_func.module,
                    .pName = @ptrCast(&shd_payload.compute_func.entry),
                    .pSpecializationInfo = null,
                },
                .layout = shd_payload.pip_layout,
                .basePipelineHandle = 0,
                .basePipelineIndex = 0,
            };
            if (observe(d.vkCreateComputePipelines(self.dev, self.pipeline_cache, 1, @ptrCast(&pip_create_info), null, @ptrCast(&payload.pip))) != sdk.SUCCESS) {
                core.logError(.vulkan_create_compute_pipeline_failed);
                return .failed;
            }
        } else {
            var stages: [2]sdk.PipelineShaderStageCreateInfo = undefined;
            var num_stages: u32 = 0;
            if (shd_payload.vertex_func.module != 0) {
                stages[num_stages] = .{
                    .sType = sdk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .stage = sdk.SHADER_STAGE_VERTEX_BIT,
                    .module = shd_payload.vertex_func.module,
                    .pName = @ptrCast(&shd_payload.vertex_func.entry),
                    .pSpecializationInfo = null,
                };
                num_stages += 1;
            }
            if (shd_payload.fragment_func.module != 0) {
                stages[num_stages] = .{
                    .sType = sdk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .stage = sdk.SHADER_STAGE_FRAGMENT_BIT,
                    .module = shd_payload.fragment_func.module,
                    .pName = @ptrCast(&shd_payload.fragment_func.entry),
                    .pSpecializationInfo = null,
                };
                num_stages += 1;
            }

            var vtx_bnds: [max_vb_slots]sdk.VertexInputBindingDescription = std.mem.zeroes([max_vb_slots]sdk.VertexInputBindingDescription);
            var num_vtx_bnds: u32 = 0;
            for (0..max_vb_slots) |vbl_idx| {
                const vbl_state = &desc.layout.buffers[vbl_idx];
                if (vbl_state.stride == 0) break;
                vtx_bnds[vbl_idx] = .{
                    .binding = @intCast(vbl_idx),
                    .stride = @intCast(vbl_state.stride),
                    .inputRate = convert.vertexInputRate(vbl_state.step_func),
                };
                num_vtx_bnds += 1;
            }

            var vtx_attrs: [max_vertex_attrs]sdk.VertexInputAttributeDescription = std.mem.zeroes([max_vertex_attrs]sdk.VertexInputAttributeDescription);
            var num_vtx_attrs: u32 = 0;
            for (0..max_vertex_attrs) |va_idx| {
                const va_state = &desc.layout.attrs[va_idx];
                if (va_state.format == .invalid) break;
                const vbl_idx: u32 = @intCast(va_state.buffer_index);
                std.debug.assert(vbl_idx < max_vb_slots);
                std.debug.assert(pip.cmn.vertex_buffer_layout_active[vbl_idx]);
                vtx_attrs[va_idx] = .{
                    .location = @intCast(va_idx),
                    .binding = vbl_idx,
                    .format = convert.vertexFormat(va_state.format),
                    .offset = @intCast(va_state.offset),
                };
                num_vtx_attrs += 1;
            }

            const vi_state: sdk.PipelineVertexInputStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .vertexBindingDescriptionCount = num_vtx_bnds,
                .pVertexBindingDescriptions = &vtx_bnds[0],
                .vertexAttributeDescriptionCount = num_vtx_attrs,
                .pVertexAttributeDescriptions = &vtx_attrs[0],
            };
            const ia_state: sdk.PipelineInputAssemblyStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .topology = convert.primitiveTopology(desc.primitive_type),
                .primitiveRestartEnable = sdk.FALSE, // FIXME: needs the primitiveTopologyRestart feature
            };
            const vp_state: sdk.PipelineViewportStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .viewportCount = 1,
                .pViewports = null,
                .scissorCount = 1,
                .pScissors = null,
            };
            const rs_state: sdk.PipelineRasterizationStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .depthClampEnable = sdk.FALSE,
                .rasterizerDiscardEnable = sdk.FALSE,
                .polygonMode = sdk.POLYGON_MODE_FILL,
                .cullMode = convert.cullMode(desc.cull_mode),
                .frontFace = convert.frontFace(desc.face_winding),
                .depthBiasEnable = if (@as(i32, @intFromFloat(desc.depth.bias)) != 0) sdk.TRUE else sdk.FALSE,
                .depthBiasConstantFactor = desc.depth.bias,
                .depthBiasClamp = desc.depth.bias_clamp,
                .depthBiasSlopeFactor = desc.depth.bias_slope_scale,
                .lineWidth = 1.0,
            };
            const ms_state: sdk.PipelineMultisampleStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .rasterizationSamples = @intCast(desc.sample_count),
                .sampleShadingEnable = sdk.FALSE,
                .minSampleShading = 0,
                .pSampleMask = null,
                .alphaToCoverageEnable = if (desc.alpha_to_coverage_enabled) sdk.TRUE else sdk.FALSE,
                .alphaToOneEnable = sdk.FALSE,
            };
            const ds_state: sdk.PipelineDepthStencilStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .depthTestEnable = if (desc.depth.compare != .always) sdk.TRUE else sdk.FALSE,
                .depthWriteEnable = if (desc.depth.write_enabled) sdk.TRUE else sdk.FALSE,
                .depthCompareOp = convert.compareOp(desc.depth.compare),
                .depthBoundsTestEnable = sdk.FALSE,
                .stencilTestEnable = if (desc.stencil.enabled) sdk.TRUE else sdk.FALSE,
                .front = stencilOpState(desc.stencil.front, desc.stencil),
                .back = stencilOpState(desc.stencil.back, desc.stencil),
                .minDepthBounds = 0,
                .maxDepthBounds = 0,
            };
            var att_states: [c.max_color_attachments]sdk.PipelineColorBlendAttachmentState = std.mem.zeroes([c.max_color_attachments]sdk.PipelineColorBlendAttachmentState);
            for (0..@intCast(desc.color_count)) |i| {
                const blend = desc.colors[i].blend;
                att_states[i] = .{
                    .blendEnable = if (blend.enabled) sdk.TRUE else sdk.FALSE,
                    .srcColorBlendFactor = convert.blendFactor(blend.src_factor_rgb),
                    .dstColorBlendFactor = convert.blendFactor(blend.dst_factor_rgb),
                    .colorBlendOp = convert.blendOp(blend.op_rgb),
                    .srcAlphaBlendFactor = convert.blendFactor(blend.src_factor_alpha),
                    .dstAlphaBlendFactor = convert.blendFactor(blend.dst_factor_alpha),
                    .alphaBlendOp = convert.blendOp(blend.op_alpha),
                    .colorWriteMask = convert.colorWriteMask(desc.colors[i].write_mask),
                };
            }
            const cb_state: sdk.PipelineColorBlendStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .logicOpEnable = sdk.FALSE,
                .logicOp = 0,
                .attachmentCount = @intCast(desc.color_count),
                .pAttachments = &att_states[0],
                .blendConstants = .{ desc.blend_color.r, desc.blend_color.g, desc.blend_color.b, desc.blend_color.a },
            };
            var color_formats: [c.max_color_attachments]i32 = undefined;
            for (0..@intCast(desc.color_count)) |i| {
                color_formats[i] = convert.pixelFormat(desc.colors[i].pixel_format);
            }
            const rnd_state: sdk.PipelineRenderingCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                .pNext = null,
                .viewMask = 0,
                .colorAttachmentCount = @intCast(desc.color_count),
                .pColorAttachmentFormats = &color_formats[0],
                .depthAttachmentFormat = convert.pixelFormat(desc.depth.pixel_format),
                .stencilAttachmentFormat = if (core.isDepthStencilFormat(desc.depth.pixel_format)) convert.pixelFormat(desc.depth.pixel_format) else sdk.FORMAT_UNDEFINED,
            };
            const dyn_states = [2]i32{ sdk.DYNAMIC_STATE_VIEWPORT, sdk.DYNAMIC_STATE_SCISSOR };
            const dyn_state: sdk.PipelineDynamicStateCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .dynamicStateCount = 2,
                .pDynamicStates = &dyn_states[0],
            };
            const pip_create_info: sdk.GraphicsPipelineCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = @ptrCast(&rnd_state),
                .flags = if (self.use_descriptor_buffer) sdk.PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT else 0,
                .stageCount = num_stages,
                .pStages = &stages[0],
                .pVertexInputState = &vi_state,
                .pInputAssemblyState = &ia_state,
                .pTessellationState = null,
                .pViewportState = &vp_state,
                .pRasterizationState = &rs_state,
                .pMultisampleState = &ms_state,
                .pDepthStencilState = &ds_state,
                .pColorBlendState = &cb_state,
                .pDynamicState = &dyn_state,
                .layout = shd_payload.pip_layout,
                .renderPass = 0,
                .subpass = 0,
                .basePipelineHandle = 0,
                .basePipelineIndex = 0,
            };
            if (observe(d.vkCreateGraphicsPipelines(self.dev, self.pipeline_cache, 1, @ptrCast(&pip_create_info), null, @ptrCast(&payload.pip))) != sdk.SUCCESS) {
                core.logError(.vulkan_create_graphics_pipeline_failed);
                return .failed;
            }
        }
        std.debug.assert(payload.pip != 0);
        memory.setObjectLabel(self, sdk.OBJECT_TYPE_PIPELINE, payload.pip, desc.label);
        return .valid;
    }

    fn stencilOpState(face: t.StencilFaceState, stencil: t.StencilState) sdk.StencilOpState {
        return .{
            .failOp = convert.stencilOp(face.fail_op),
            .passOp = convert.stencilOp(face.pass_op),
            .depthFailOp = convert.stencilOp(face.depth_fail_op),
            .compareOp = convert.compareOp(face.compare),
            .compareMask = stencil.read_mask,
            .writeMask = stencil.write_mask,
            .reference = stencil.ref,
        };
    }

    pub fn discardPipeline(self: *Backend, pip: *core.Pipeline) void {
        if (pip.native != .vulkan) return;
        const payload = &pip.native.vulkan;
        if (payload.pip != 0) {
            memory.deleteQueueAdd(self, .pipeline, payload.pip);
            payload.pip = 0;
        }
    }

    pub fn createView(self: *Backend, view: *core.View, desc: *const t.ViewDesc) e.ResourceState {
        if (!memory.reserveDeleteQueue(self)) return .failed;
        view.native = .{ .vulkan = .{} };
        const payload = &view.native.vulkan;
        const dp = &self.descriptor_buffer_props;
        var get_info: sdk.DescriptorGetInfoEXT = .{
            .sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
            .pNext = null,
            .type = 0,
            .data = std.mem.zeroes(sdk.DescriptorDataEXT),
        };
        if (view.cmn.type == .storagebuffer) {
            if (!self.use_descriptor_buffer) return .valid;
            // record descriptor data for storage buffer
            payload.descriptor_size = @intCast(dp.storageBufferDescriptorSize);
            if (res.max_descriptor_data_size < payload.descriptor_size) {
                core.logError(.vulkan_view_max_descriptor_size);
                return .failed;
            }
            const buf = view.cmn.buf.ref.get();
            std.debug.assert(buf.native.vulkan.dev_addr != 0);
            var addr_info: sdk.DescriptorAddressInfoEXT = .{
                .sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT,
                .pNext = null,
                .address = buf.native.vulkan.dev_addr + @as(u64, @intCast(view.cmn.buf.offset)),
                .range = @intCast(buf.cmn.size - @as(usize, @intCast(view.cmn.buf.offset))),
                .format = 0,
            };
            get_info.type = sdk.DESCRIPTOR_TYPE_STORAGE_BUFFER;
            get_info.data.pStorageBuffer = &addr_info;
            self.fns.device.vkGetDescriptorEXT.?(self.dev, &get_info, payload.descriptor_size, &payload.descriptor_data);
        } else {
            // create image view object
            const img = view.cmn.img.ref.get();
            std.debug.assert(img.native.vulkan.img != 0);
            std.debug.assert(view.cmn.img.mip_level_count >= 1 and view.cmn.img.slice_count >= 1);
            var create_info: sdk.ImageViewCreateInfo = .{
                .sType = sdk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = img.native.vulkan.img,
                .viewType = if (view.cmn.type == .texture) convert.textureImageViewType(img.cmn.type) else convert.attachmentImageViewType(img.cmn.type),
                .format = convert.pixelFormat(img.cmn.pixel_format),
                .components = std.mem.zeroes(sdk.ComponentMapping),
                .subresourceRange = .{
                    .aspectMask = 0,
                    .baseMipLevel = @intCast(view.cmn.img.mip_level),
                    .levelCount = @intCast(view.cmn.img.mip_level_count),
                    .baseArrayLayer = @intCast(view.cmn.img.slice),
                    .layerCount = @intCast(view.cmn.img.slice_count),
                },
            };
            if (view.cmn.type == .depthstencilattachment) {
                create_info.subresourceRange.aspectMask = sdk.IMAGE_ASPECT_DEPTH_BIT;
                if (core.isDepthStencilFormat(img.cmn.pixel_format)) {
                    create_info.subresourceRange.aspectMask |= sdk.IMAGE_ASPECT_STENCIL_BIT;
                }
            } else if (core.isDepthOrDepthStencilFormat(img.cmn.pixel_format)) {
                create_info.subresourceRange.aspectMask = sdk.IMAGE_ASPECT_DEPTH_BIT;
            } else {
                create_info.subresourceRange.aspectMask = sdk.IMAGE_ASPECT_COLOR_BIT;
            }
            if (observe(self.fns.device.vkCreateImageView(self.dev, &create_info, null, &payload.img_view)) != sdk.SUCCESS) {
                core.logError(.vulkan_create_image_view_failed);
                return .failed;
            }
            std.debug.assert(payload.img_view != 0);
            memory.setObjectLabel(self, sdk.OBJECT_TYPE_IMAGE_VIEW, payload.img_view, desc.label);

            // record descriptor data for storage images and textures
            if (self.use_descriptor_buffer and (view.cmn.type == .storageimage or view.cmn.type == .texture)) {
                var img_info: sdk.DescriptorImageInfo = .{ .sampler = 0, .imageView = payload.img_view, .imageLayout = 0 };
                if (view.cmn.type == .storageimage) {
                    payload.descriptor_size = @intCast(dp.storageImageDescriptorSize);
                    img_info.imageLayout = sdk.IMAGE_LAYOUT_GENERAL;
                    get_info.type = sdk.DESCRIPTOR_TYPE_STORAGE_IMAGE;
                    get_info.data.pStorageImage = &img_info;
                } else {
                    payload.descriptor_size = @intCast(dp.sampledImageDescriptorSize);
                    img_info.imageLayout = sdk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                    get_info.type = sdk.DESCRIPTOR_TYPE_SAMPLED_IMAGE;
                    get_info.data.pSampledImage = &img_info;
                }
                if (res.max_descriptor_data_size < payload.descriptor_size) {
                    core.logError(.vulkan_view_max_descriptor_size);
                    return .failed;
                }
                self.fns.device.vkGetDescriptorEXT.?(self.dev, &get_info, payload.descriptor_size, &payload.descriptor_data);
            }
        }
        return .valid;
    }

    pub fn discardView(self: *Backend, view: *core.View) void {
        if (view.native != .vulkan) return;
        const payload = &view.native.vulkan;
        if (payload.img_view != 0) {
            memory.deleteQueueAdd(self, .image_view, payload.img_view);
            payload.img_view = 0;
        }
    }

    // ------------------------------------------------------------ passes

    fn barrierOnBeginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs, is_compute_pass: bool) void {
        const cmd_buf = self.frame.cmd_buf;
        const d = &self.fns.device;
        const st = core.state();
        std.debug.assert(self.track_buffers.cur_slot == 0 and self.track_images.cur_slot == 0);
        if (is_compute_pass) return;
        barrier.renderPassStorageBarrier(d, cmd_buf);
        const is_swapchain_pass = atts.empty;
        if (is_swapchain_pass) {
            const vk_swapchain = &pass.swapchain.vulkan;
            const render_image = fromOpaque(vk_swapchain.render_image);
            std.debug.assert(render_image != 0);
            const first_in_frame = (self.swapchain_track_frame_index != st.frame_index) or (self.swapchain_track_render_image != render_image);
            self.swapchain_track_frame_index = st.frame_index;
            self.swapchain_track_render_image = render_image;
            const is_msaa = st.cur_pass.swapchain.sample_count > 1;

            // render_image: keep the content only if an earlier pass in this frame rendered to it and this pass loads it
            var render_image_old_layout: i32 = sdk.IMAGE_LAYOUT_UNDEFINED;
            if (!first_in_frame and pass.action.colors[0].load_action == .load) {
                render_image_old_layout = if (is_msaa) sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL else sdk.IMAGE_LAYOUT_PRESENT_SRC_KHR;
            }
            barrier.swapchainBeginPassBarrier(d, cmd_buf, render_image, barrier.color_attachment, render_image_old_layout);
            if (is_msaa) {
                const resolve_image = fromOpaque(vk_swapchain.resolve_image);
                std.debug.assert(resolve_image != 0);
                barrier.swapchainBeginPassBarrier(d, cmd_buf, resolve_image, barrier.resolve_attachment, sdk.IMAGE_LAYOUT_UNDEFINED);
            }
            if (vk_swapchain.depth_stencil_image) |ds_ptr| {
                const ds_image = fromOpaque(ds_ptr);
                const has_stencil = core.isDepthStencilFormat(st.cur_pass.swapchain.depth_fmt);
                var access: barrier.Access = barrier.depth_attachment;
                if (has_stencil) access |= barrier.stencil_attachment;
                var ds_old_layout: i32 = sdk.IMAGE_LAYOUT_UNDEFINED;
                const is_load_action = pass.action.depth.load_action == .load or pass.action.stencil.load_action == .load;
                if (!first_in_frame and is_load_action) {
                    ds_old_layout = sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL;
                }
                barrier.swapchainBeginPassBarrier(d, cmd_buf, ds_image, access, ds_old_layout);
            }
        } else {
            for (0..atts.num_color_views) |i| {
                const color_image = atts.color_views[i].?.cmn.img.ref.get();
                if (pass.action.colors[i].load_action != .load) {
                    // don't need to preserve image content for clear and dontcare
                    color_image.native.vulkan.cur_access |= barrier.discard;
                }
                barrier.imageBarrier(d, cmd_buf, color_image, barrier.color_attachment);
                if (atts.resolve_views[i]) |resolve_view| {
                    const resolve_image = resolve_view.cmn.img.ref.get();
                    // never need to preserve content for resolve image
                    resolve_image.native.vulkan.cur_access |= barrier.discard;
                    barrier.imageBarrier(d, cmd_buf, resolve_image, barrier.resolve_attachment);
                }
            }
            if (atts.ds_view) |ds_view| {
                const ds_image = ds_view.cmn.img.ref.get();
                const has_stencil = core.isDepthStencilFormat(ds_image.cmn.pixel_format);
                if (pass.action.depth.load_action != .load and pass.action.stencil.load_action != .load) {
                    // don't need to preserve image content for clear and dontcare
                    ds_image.native.vulkan.cur_access |= barrier.discard;
                }
                var dst_access: barrier.Access = barrier.depth_attachment;
                if (has_stencil) dst_access |= barrier.stencil_attachment;
                barrier.imageBarrier(d, cmd_buf, ds_image, dst_access);
            }
        }
    }

    fn barrierOnApplyBindings(self: *Backend, bnd: *const core.BindingsPtrs, is_compute_pass: bool) void {
        const cmd_buf = self.frame.cmd_buf;
        const d = &self.fns.device;
        const shd = bnd.pip.cmn.shader.get();
        if (is_compute_pass) {
            for (0..max_view_slots) |i| {
                const view = bnd.views[i] orelse continue;
                switch (view.cmn.type) {
                    .storagebuffer => {
                        const buf = view.cmn.buf.ref.get();
                        const new_access: barrier.Access = if (shd.cmn.views[i].sbuf_readonly) barrier.storagebuffer_ro else barrier.storagebuffer_rw_compute;
                        barrier.bufferBarrier(d, cmd_buf, buf, new_access);
                        self.track_buffers.add(buf.slot.id);
                    },
                    .storageimage => {
                        const img = view.cmn.img.ref.get();
                        barrier.imageBarrier(d, cmd_buf, img, barrier.storageimage);
                        self.track_images.add(img.slot.id);
                    },
                    .texture => {
                        const img = view.cmn.img.ref.get();
                        barrier.imageBarrier(d, cmd_buf, img, barrier.texture);
                        self.track_images.add(img.slot.id);
                    },
                    else => unreachable,
                }
            }
        } else {
            // No transitions are allowed in render passes, but read-write storage buffers need
            // tracking for the transition in endPass. Otherwise only the expected bits are checked.
            for (0..max_vb_slots) |i| {
                if (bnd.vbs[i]) |vb| {
                    if (!vb.cmn.usage.write_transient) {
                        std.debug.assert(vb.native.vulkan.cur_access & barrier.vertexbuffer != 0);
                    }
                }
            }
            if (bnd.ib) |ib| {
                if (!ib.cmn.usage.write_transient) {
                    std.debug.assert(ib.native.vulkan.cur_access & barrier.indexbuffer != 0);
                }
            }
            for (0..max_view_slots) |i| {
                const view = bnd.views[i] orelse continue;
                switch (view.cmn.type) {
                    .storagebuffer => {
                        const buf = view.cmn.buf.ref.get();
                        if (shd.cmn.views[i].sbuf_readonly) {
                            if (!buf.cmn.usage.write_transient) {
                                std.debug.assert(buf.native.vulkan.cur_access & barrier.storagebuffer_ro != 0);
                            }
                        } else {
                            const cur = buf.native.vulkan.cur_access;
                            std.debug.assert(cur == barrier.defaultBufferAccessMask(buf.cmn.usage) or cur == barrier.storagebuffer_rw_fragment);
                            // only record the new rw-access, the barrier is deferred to endPass
                            buf.native.vulkan.cur_access = barrier.storagebuffer_rw_fragment;
                            self.track_buffers.add(buf.slot.id);
                        }
                    },
                    .texture => {
                        const img = view.cmn.img.ref.get();
                        if (!img.cmn.usage.write_transient) {
                            std.debug.assert(img.native.vulkan.cur_access & barrier.texture != 0);
                        }
                    },
                    else => unreachable,
                }
            }
        }
    }

    fn barrierOnEndPass(self: *Backend, atts: *const core.AttachmentsPtrs, is_compute_pass: bool) void {
        const cmd_buf = self.frame.cmd_buf;
        const d = &self.fns.device;
        const st = core.state();

        // transition all tracked buffers into their default access, in render passes these
        // are only storage buffers written in fragment shaders
        for (self.track_buffers.slots[0..self.track_buffers.cur_slot]) |buf_id| {
            if (core.lookupBuffer(buf_id)) |buf| {
                barrier.bufferBarrier(d, cmd_buf, buf, barrier.defaultBufferAccessMask(buf.cmn.usage));
            }
        }
        self.track_buffers.reset();

        if (is_compute_pass) {
            // transition all tracked images into texture access
            for (self.track_images.slots[0..self.track_images.cur_slot]) |img_id| {
                if (core.lookupImage(img_id)) |img| {
                    barrier.imageBarrier(d, cmd_buf, img, barrier.defaultImageAccessMask());
                }
            }
            self.track_images.reset();
        } else {
            // transition all render targets into their default access
            if (atts.empty) {
                const present_image = if (self.swapchain.resolve_image != null) fromOpaque(self.swapchain.resolve_image) else fromOpaque(self.swapchain.render_image);
                std.debug.assert(present_image != 0);
                barrier.swapchainEndPassBarrier(d, cmd_buf, present_image, barrier.color_attachment, true);
            } else {
                for (0..atts.num_color_views) |i| {
                    if (st.cur_pass.action.colors[i].store_action == .store) {
                        const img = atts.color_views[i].?.cmn.img.ref.get();
                        barrier.imageBarrier(d, cmd_buf, img, barrier.defaultImageAccessMask());
                    }
                    if (atts.resolve_views[i]) |resolve_view| {
                        const img = resolve_view.cmn.img.ref.get();
                        barrier.imageBarrier(d, cmd_buf, img, barrier.defaultImageAccessMask());
                    }
                }
                if (atts.ds_view) |ds_view| {
                    if (st.cur_pass.action.depth.store_action == .store) {
                        const img = ds_view.cmn.img.ref.get();
                        barrier.imageBarrier(d, cmd_buf, img, barrier.defaultImageAccessMask());
                    }
                }
            }
        }
    }

    fn initColorAttachmentInfo(info: *sdk.RenderingAttachmentInfo, action: *const t.ColorAttachmentAction, color_view: u64, resolve_view: u64) void {
        info.* = std.mem.zeroes(sdk.RenderingAttachmentInfo);
        info.sType = sdk.STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        info.imageView = color_view;
        info.imageLayout = sdk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        if (resolve_view != 0) {
            info.resolveMode = sdk.RESOLVE_MODE_AVERAGE_BIT;
            info.resolveImageView = resolve_view;
            info.resolveImageLayout = sdk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        } else {
            info.resolveMode = sdk.RESOLVE_MODE_NONE;
            info.resolveImageView = 0;
            info.resolveImageLayout = sdk.IMAGE_LAYOUT_UNDEFINED;
        }
        info.loadOp = convert.loadOp(action.load_action);
        info.storeOp = convert.storeOp(action.store_action);
        info.clearValue.color.float32 = .{ action.clear_value.r, action.clear_value.g, action.clear_value.b, action.clear_value.a };
    }

    fn initDepthAttachmentInfo(info: *sdk.RenderingAttachmentInfo, action: *const t.DepthAttachmentAction, ds_view: u64) void {
        info.* = std.mem.zeroes(sdk.RenderingAttachmentInfo);
        info.sType = sdk.STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        info.imageView = ds_view;
        info.imageLayout = sdk.IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
        info.resolveMode = sdk.RESOLVE_MODE_NONE;
        info.loadOp = convert.loadOp(action.load_action);
        info.storeOp = convert.storeOp(action.store_action);
        info.clearValue.depthStencil.depth = action.clear_value;
    }

    fn initStencilAttachmentInfo(info: *sdk.RenderingAttachmentInfo, action: *const t.StencilAttachmentAction, ds_view: u64) void {
        info.* = std.mem.zeroes(sdk.RenderingAttachmentInfo);
        info.sType = sdk.STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        info.imageView = ds_view;
        info.imageLayout = sdk.IMAGE_LAYOUT_STENCIL_ATTACHMENT_OPTIMAL;
        info.resolveMode = sdk.RESOLVE_MODE_NONE;
        info.loadOp = convert.loadOp(action.load_action);
        info.storeOp = convert.storeOp(action.store_action);
        info.clearValue.depthStencil.stencil = action.clear_value;
    }

    fn beginRenderPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) void {
        const cmd_buf = self.frame.cmd_buf;
        const st = core.state();
        const action = &pass.action;
        const is_swapchain_pass = atts.empty;

        var color_att_infos: [c.max_color_attachments]sdk.RenderingAttachmentInfo = std.mem.zeroes([c.max_color_attachments]sdk.RenderingAttachmentInfo);
        var depth_att_info: sdk.RenderingAttachmentInfo = std.mem.zeroes(sdk.RenderingAttachmentInfo);
        var stencil_att_info: sdk.RenderingAttachmentInfo = std.mem.zeroes(sdk.RenderingAttachmentInfo);
        var render_info: sdk.RenderingInfo = std.mem.zeroes(sdk.RenderingInfo);
        render_info.sType = sdk.STRUCTURE_TYPE_RENDERING_INFO;
        render_info.renderArea.extent.width = @intCast(st.cur_pass.dim.width);
        render_info.renderArea.extent.height = @intCast(st.cur_pass.dim.height);
        render_info.layerCount = 1;

        if (is_swapchain_pass) {
            self.swapchain = pass.swapchain.vulkan;
            std.debug.assert(self.swapchain.render_view != null);
            if (pass.swapchain.sample_count > 1) std.debug.assert(self.swapchain.resolve_view != null);
            std.debug.assert(self.swapchain.present_complete_semaphore != null);
            std.debug.assert(self.swapchain.render_finished_semaphore != null);
            // FIXME: need to support multiple present_complete_semaphores
            const present_sem = fromOpaque(self.swapchain.present_complete_semaphore);
            if (self.present_complete_sem == 0) {
                self.present_complete_sem = present_sem;
            } else {
                std.debug.assert(self.present_complete_sem == present_sem);
            }
            const render_sem = fromOpaque(self.swapchain.render_finished_semaphore);
            if (self.render_finished_sem == 0) {
                self.render_finished_sem = render_sem;
            } else {
                std.debug.assert(self.render_finished_sem == render_sem);
            }
            const vk_color_view = fromOpaque(self.swapchain.render_view);
            const vk_resolve_view = fromOpaque(self.swapchain.resolve_view);
            initColorAttachmentInfo(&color_att_infos[0], &action.colors[0], vk_color_view, vk_resolve_view);
            render_info.colorAttachmentCount = 1;
            render_info.pColorAttachments = &color_att_infos[0];
            if (self.swapchain.depth_stencil_view) |ds_view_ptr| {
                const vk_ds_view = fromOpaque(ds_view_ptr);
                const has_stencil = core.isDepthStencilFormat(pass.swapchain.depth_format);
                initDepthAttachmentInfo(&depth_att_info, &action.depth, vk_ds_view);
                render_info.pDepthAttachment = &depth_att_info;
                if (has_stencil) {
                    initStencilAttachmentInfo(&stencil_att_info, &action.stencil, vk_ds_view);
                    render_info.pStencilAttachment = &stencil_att_info;
                }
            }
        } else {
            for (0..atts.num_color_views) |i| {
                const color_view = atts.color_views[i].?;
                const resolve_view_ptr = atts.resolve_views[i];
                const vk_resolve_view: u64 = if (resolve_view_ptr) |rv| rv.native.vulkan.img_view else 0;
                initColorAttachmentInfo(&color_att_infos[i], &action.colors[i], color_view.native.vulkan.img_view, vk_resolve_view);
            }
            if (atts.num_color_views > 0) {
                render_info.colorAttachmentCount = @intCast(atts.num_color_views);
                render_info.pColorAttachments = &color_att_infos[0];
            }
            if (atts.ds_view) |ds_view| {
                const ds_image = ds_view.cmn.img.ref.get();
                const has_stencil = core.isDepthStencilFormat(ds_image.cmn.pixel_format);
                const vk_ds_view = ds_view.native.vulkan.img_view;
                initDepthAttachmentInfo(&depth_att_info, &action.depth, vk_ds_view);
                render_info.pDepthAttachment = &depth_att_info;
                if (has_stencil) {
                    initStencilAttachmentInfo(&stencil_att_info, &action.stencil, vk_ds_view);
                    render_info.pStencilAttachment = &stencil_att_info;
                }
            }
        }
        self.fns.device.vkCmdBeginRendering(cmd_buf, &render_info);

        // the viewport is flipped so that the origin is at the top left (Vulkan's y axis points down)
        const dim_w: f32 = @floatFromInt(st.cur_pass.dim.width);
        const dim_h: f32 = @floatFromInt(st.cur_pass.dim.height);
        const vp: sdk.Viewport = .{ .x = 0, .y = dim_h, .width = dim_w, .height = -dim_h, .minDepth = 0, .maxDepth = 1 };
        self.fns.device.vkCmdSetViewport(self.frame.cmd_buf, 0, 1, @ptrCast(&vp));
        const rect: sdk.Rect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = @intCast(st.cur_pass.dim.width), .height = @intCast(st.cur_pass.dim.height) },
        };
        self.fns.device.vkCmdSetScissor(self.frame.cmd_buf, 0, 1, @ptrCast(&rect));
    }

    /// Acquires the frame command buffers and begins the pass. Returns false if the frame could not be acquired.
    pub fn beginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
        self.acquireFrameCommandBuffers();
        if (self.frame.cmd_buf == null) return false;
        const st = core.state();
        self.barrierOnBeginPass(pass, atts, st.cur_pass.is_compute);
        if (!st.cur_pass.is_compute) {
            self.beginRenderPass(pass, atts);
        }
        return true;
    }

    pub fn endPass(self: *Backend, atts: *const core.AttachmentsPtrs) void {
        std.debug.assert(self.frame.cmd_buf != null);
        const st = core.state();
        if (!st.cur_pass.is_compute) {
            self.fns.device.vkCmdEndRendering(self.frame.cmd_buf);
        }
        self.barrierOnEndPass(atts, st.cur_pass.is_compute);
        self.swapchain = .{};
    }

    pub fn commit(self: *Backend) void {
        std.debug.assert(self.queue != null);
        if (self.frame.cmd_buf != null) {
            self.submitFrameCommandBuffers();
        } else if (core.state().readbacks.items.len == 0 and observe(self.fns.device.vkGetFenceStatus(self.dev, self.frame.slots[self.frame_slot].fence)) == sdk.SUCCESS) {
            // Idle resource-only frames still retire objects, without a GPU wait.
            memory.deleteQueueCollect(self);
        }
        self.present_complete_sem = 0;
        self.render_finished_sem = 0;
    }

    // ------------------------------------------------------------ apply, draw, dispatch

    pub fn applyViewport(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        std.debug.assert(self.frame.cmd_buf != null);
        const st = core.state();
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const vp: sdk.Viewport = .{
            .x = fx,
            .y = if (origin_top_left) fy + fh else @as(f32, @floatFromInt(st.cur_pass.dim.height)) - fy,
            .width = fw,
            .height = -fh,
            .minDepth = 0,
            .maxDepth = 1,
        };
        self.fns.device.vkCmdSetViewport(self.frame.cmd_buf, 0, 1, @ptrCast(&vp));
    }

    pub fn applyScissorRect(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        std.debug.assert(self.frame.cmd_buf != null);
        const st = core.state();
        const clip = core.clipRect(x, y, w, h, st.cur_pass.dim.width, st.cur_pass.dim.height);
        const rect: sdk.Rect2D = .{
            .offset = .{
                .x = clip.x,
                .y = if (origin_top_left) clip.y else st.cur_pass.dim.height - (clip.y + clip.h),
            },
            .extent = .{ .width = @intCast(clip.w), .height = @intCast(clip.h) },
        };
        self.fns.device.vkCmdSetScissor(self.frame.cmd_buf, 0, 1, @ptrCast(&rect));
    }

    pub fn applyPipeline(self: *Backend, pip: *core.Pipeline) void {
        std.debug.assert(pip.native.vulkan.pip != 0);
        std.debug.assert(self.frame.cmd_buf != null);
        self.uniforms.dirty = false;
        const bind_point: i32 = if (pip.cmn.is_compute) sdk.PIPELINE_BIND_POINT_COMPUTE else sdk.PIPELINE_BIND_POINT_GRAPHICS;
        self.fns.device.vkCmdBindPipeline(self.frame.cmd_buf, bind_point, pip.native.vulkan.pip);
    }

    pub fn applyBindings(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        const cmd_buf = self.frame.cmd_buf;
        const st = core.state();
        std.debug.assert(cmd_buf != null);
        // track or insert pipeline barriers
        self.barrierOnApplyBindings(bnd, st.cur_pass.is_compute);

        if (!st.cur_pass.is_compute) {
            // NOTE: could be a single call if the buffer bindings are guaranteed to be continuous
            for (0..max_vb_slots) |i| {
                if (bnd.vbs[i]) |vb| {
                    var vk_buf: [1]u64 = .{vb.native.vulkan.buf};
                    var vk_offset: [1]u64 = .{@intCast(bnd.vb_offsets[i])};
                    self.fns.device.vkCmdBindVertexBuffers(cmd_buf, @intCast(i), 1, &vk_buf, &vk_offset);
                }
            }
            if (bnd.ib) |ib| {
                self.fns.device.vkCmdBindIndexBuffer(cmd_buf, ib.native.vulkan.buf, @intCast(bnd.ib_offset), convert.indexType(bnd.pip.cmn.index_type));
            }
        }

        // bind views and samplers
        const bind_point: i32 = if (st.cur_pass.is_compute) sdk.PIPELINE_BIND_POINT_COMPUTE else sdk.PIPELINE_BIND_POINT_GRAPHICS;
        return self.bindViewSmpDescriptorSet(cmd_buf, bnd, bind_point);
    }

    fn bindViewSmpDescriptorSet(self: *Backend, cmd_buf: sdk.CommandBuffer, bnd: *const core.BindingsPtrs, bind_point: i32) bool {
        if (!self.use_descriptor_buffer) return sets.bindViews(self, cmd_buf, bnd, bind_point);
        const shd = bnd.pip.cmn.shader.get();
        const shd_payload = &shd.native.vulkan;

        // get the next pointer in the descriptor buffer
        const dset_size = shd_payload.view_smp_dset_size;
        if (dset_size == 0) {
            // nothing to bind
            return true;
        }
        const dbuf_offset = memory.sharedBufferAlloc(&self.bind, @intCast(dset_size));
        if (self.bind.overflown) {
            core.logError(.vulkan_descriptor_buffer_overflow);
            return false;
        }
        core.statsAdd("vk.size_descriptor_buffer_writes", @intCast(dset_size));
        const dbuf_ptr = memory.sharedBufferPtr(&self.bind, dbuf_offset);

        // copy the pre-recorded descriptor data into the descriptor buffer
        for (0..max_view_slots) |i| {
            if (shd.cmn.views[i].stage == .none) continue;
            const view = bnd.views[i].?;
            std.debug.assert(view.native.vulkan.descriptor_size > 0);
            const size = view.native.vulkan.descriptor_size;
            @memcpy((dbuf_ptr + shd_payload.view_dset_offsets[i])[0..size], view.native.vulkan.descriptor_data[0..size]);
        }
        for (0..max_smp_slots) |i| {
            if (shd.cmn.samplers[i].stage == .none) continue;
            const smp = bnd.smps[i].?;
            std.debug.assert(smp.native.vulkan.descriptor_size > 0);
            const size = smp.native.vulkan.descriptor_size;
            @memcpy((dbuf_ptr + shd_payload.smp_dset_offsets[i])[0..size], smp.native.vulkan.descriptor_data[0..size]);
        }

        // record the new descriptor buffer offset
        const dbuf_index: u32 = 0;
        const offset: u64 = dbuf_offset;
        std.debug.assert(shd_payload.pip_layout != 0);
        self.fns.device.vkCmdSetDescriptorBufferOffsetsEXT.?(cmd_buf, bind_point, shd_payload.pip_layout, 1, 1, @ptrCast(&dbuf_index), @ptrCast(&offset));
        core.statsInc("vk.num_cmd_set_descriptor_buffer_offsets");
        return true;
    }

    fn bindUniformDescriptorSet(self: *Backend, cmd_buf: sdk.CommandBuffer) bool {
        if (!self.use_descriptor_buffer) return sets.bindUniforms(self, cmd_buf);
        std.debug.assert(self.uniforms.dirty);
        self.uniforms.dirty = false;
        const st = core.state();
        const pip = st.cur_pip.get();
        const shd = pip.cmn.shader.get();
        const shd_payload = &shd.native.vulkan;

        // get the next pointer in the descriptor buffer
        const dbuf_offset = memory.sharedBufferAlloc(&self.bind, @intCast(shd_payload.ub_dset_size));
        if (self.bind.overflown) {
            core.logError(.vulkan_descriptor_buffer_overflow);
            return false;
        }
        core.statsAdd("vk.size_descriptor_buffer_writes", @intCast(shd_payload.ub_dset_size));
        const dbuf_ptr = memory.sharedBufferPtr(&self.bind, dbuf_offset);

        // update the descriptor buffer
        std.debug.assert(shd_payload.ub_dset_size <= self.uniforms.dset_cache_size);
        @memcpy(dbuf_ptr[0..@as(usize, @intCast(shd_payload.ub_dset_size))], self.uniforms.dset_cache[0..@as(usize, @intCast(shd_payload.ub_dset_size))]);

        // record the descriptor buffer offset
        const bind_point: i32 = if (st.cur_pass.is_compute) sdk.PIPELINE_BIND_POINT_COMPUTE else sdk.PIPELINE_BIND_POINT_GRAPHICS;
        const dbuf_index: u32 = 0;
        const offset: u64 = dbuf_offset;
        std.debug.assert(shd_payload.pip_layout != 0);
        self.fns.device.vkCmdSetDescriptorBufferOffsetsEXT.?(cmd_buf, bind_point, shd_payload.pip_layout, 0, 1, @ptrCast(&dbuf_index), @ptrCast(&offset));
        core.statsInc("vk.num_cmd_set_descriptor_buffer_offsets");
        return true;
    }

    pub fn applyUniforms(self: *Backend, ub_slot: usize, data: *const t.Range) void {
        std.debug.assert(self.uniforms.dbuf.cur_dev_addr != 0);
        std.debug.assert(data.ptr != null and data.size > 0);
        const st = core.state();
        const pip = st.cur_pip.get();
        const shd = pip.cmn.shader.get();
        std.debug.assert(data.size == shd.cmn.uniform_blocks[ub_slot].size);

        // copy the data into the uniform buffer and keep track of the uniform bind infos
        const ubuf_offset = memory.uniformCopy(self, data);
        if (self.uniforms.dbuf.overflown) {
            core.logError(.vulkan_uniform_buffer_overflow);
            st.next_draw_valid = false;
            return;
        }
        self.uniform_buffer_infos[ub_slot] = .{ .buffer = self.uniforms.dbuf.cur_buf, .offset = ubuf_offset, .range = data.size };
        if (!self.use_descriptor_buffer) {
            self.uniforms.dirty = true;
            return;
        }
        self.uniforms.addr_info[ub_slot].range = data.size;
        self.uniforms.addr_info[ub_slot].address = self.uniforms.dbuf.cur_dev_addr + ubuf_offset;

        // copy the uniform buffer descriptor into an intermediate system memory buffer; letting
        // vkGetDescriptorEXT write directly into the descriptor buffer is very slow on some drivers
        const dsize: usize = @intCast(self.descriptor_buffer_props.uniformBufferDescriptorSize);
        const shd_payload = &shd.native.vulkan;
        const dst_offset: usize = shd_payload.ub_dset_offsets[ub_slot];
        std.debug.assert(dst_offset + dsize <= self.uniforms.dset_cache_size);
        const get_info = &self.uniforms.get_info[ub_slot];
        get_info.sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
        get_info.pNext = null;
        get_info.type = sdk.DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        get_info.data = std.mem.zeroes(sdk.DescriptorDataEXT);
        get_info.data.pUniformBuffer = &self.uniforms.addr_info[ub_slot];
        self.fns.device.vkGetDescriptorEXT.?(self.dev, get_info, dsize, self.uniforms.dset_cache.ptr + dst_offset);

        // the uniform descriptor offset is applied in draw/dispatch
        self.uniforms.dirty = true;
    }

    pub fn draw(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
        const cmd_buf = self.frame.cmd_buf;
        std.debug.assert(cmd_buf != null);
        if (self.uniforms.dirty) {
            if (!self.bindUniformDescriptorSet(cmd_buf)) return;
        }
        if (core.state().use_indexed_draw) {
            self.fns.device.vkCmdDrawIndexed(cmd_buf, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), base_vertex, @intCast(base_instance));
        } else {
            self.fns.device.vkCmdDraw(cmd_buf, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), @intCast(base_instance));
        }
    }

    pub fn dispatch(self: *Backend, x: i32, y: i32, z: i32) void {
        const cmd_buf = self.frame.cmd_buf;
        std.debug.assert(cmd_buf != null);
        if (self.uniforms.dirty) {
            if (!self.bindUniformDescriptorSet(cmd_buf)) return;
        }
        self.fns.device.vkCmdDispatch(cmd_buf, @intCast(x), @intCast(y), @intCast(z));
    }

    // ------------------------------------------------------------ data transfer

    pub fn writeBufferTransient(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
        _ = first_time_in_frame;
        std.debug.assert(buf.slot.state == .valid and buf.cmn.usage.write_transient);
        self.acquireFrameCommandBuffers();
        memory.stagingStreamBufferData(self, buf, &desc.src.data, desc.src.offset, desc.dst.offset, desc.size);
    }

    pub fn writeImageTransient(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
        _ = first_time_in_frame;
        std.debug.assert(img.slot.state == .valid and img.cmn.usage.write_transient);
        self.acquireFrameCommandBuffers();
        const cmd_buf = self.frame.stream_cmd_buf;
        barrier.imageBarrier(&self.fns.device, cmd_buf, img, barrier.copy_dst);
        memory.stagingStreamMiplevelData(self, img, mipSource(desc.src), mipRegion(desc.dst, desc.size));
        barrier.imageBarrier(&self.fns.device, cmd_buf, img, barrier.defaultImageAccessMask());
    }

    pub fn writeBufferUnsealed(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
        std.debug.assert(buf.slot.state == .unsealed and buf.cmn.usage.write_unsealed);
        std.debug.assert(desc.src.data.ptr != null and desc.src.data.size > 0);
        _ = memory.stagingCopyBufferData(self, buf, &desc.src.data, desc.src.offset, desc.dst.offset, desc.size);
    }

    pub fn writeImageUnsealed(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
        std.debug.assert(img.slot.state == .unsealed and img.cmn.usage.write_unsealed);
        _ = memory.stagingCopyMiplevelData(self, img, mipSource(desc.src), mipRegion(desc.dst, desc.size));
    }

    pub fn sealBuffer(self: *Backend, buf: *core.Buffer) void {
        _ = .{ self, buf };
    }

    pub fn sealImage(self: *Backend, img: *core.Image) void {
        _ = .{ self, img };
    }

    pub fn copyBufferToBuffer(self: *Backend, src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
        std.debug.assert(src.cmn.usage.copy_src and dst.cmn.usage.copy_dst);
        self.acquireFrameCommandBuffers();
        // NOTE: the regular command buffer, not the stream one, because GPU copies must run interleaved with passes
        const cmd_buf = self.frame.cmd_buf;
        const d = &self.fns.device;
        const region: sdk.BufferCopy = .{ .srcOffset = @intCast(desc.src.offset), .dstOffset = @intCast(desc.dst.offset), .size = @intCast(desc.size) };
        barrier.bufferBarrier(d, cmd_buf, src, barrier.copy_src);
        barrier.bufferBarrier(d, cmd_buf, dst, barrier.copy_dst);
        d.vkCmdCopyBuffer(cmd_buf, src.native.vulkan.buf, dst.native.vulkan.buf, 1, @ptrCast(&region));
        core.statsInc("vk.num_cmd_copy_buffer");
        barrier.bufferBarrier(d, cmd_buf, src, barrier.defaultBufferAccessMask(src.cmn.usage));
        barrier.bufferBarrier(d, cmd_buf, dst, barrier.defaultBufferAccessMask(dst.cmn.usage));
    }

    pub fn copyBufferToImage(self: *Backend, src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
        std.debug.assert(src.cmn.usage.copy_src and dst.cmn.usage.copy_dst and !src.cmn.usage.staging_index_buffer);
        self.acquireFrameCommandBuffers();
        // NOTE: the regular command buffer, not the stream one, because GPU copies must run interleaved with passes
        const cmd_buf = self.frame.cmd_buf;
        const d = &self.fns.device;
        barrier.bufferBarrier(d, cmd_buf, src, barrier.copy_src);
        barrier.imageBarrier(d, cmd_buf, dst, barrier.copy_dst);

        var region: sdk.BufferImageCopy2 = undefined;
        var copy_info: sdk.CopyBufferToImageInfo2 = undefined;
        memory.initVkImageStagingStructs(dst, src.native.vulkan.buf, &region, &copy_info);
        const block_dim = formats.blockDimension(dst.cmn.pixel_format);
        const block_bytesize = formats.blockSize(dst.cmn.pixel_format);
        region.bufferRowLength = @intCast(@divTrunc(desc.src.bytes_per_row, block_bytesize) * block_dim);
        region.bufferImageHeight = @intCast(@divTrunc(desc.src.bytes_per_slice, desc.src.bytes_per_row) * block_dim);
        region.bufferOffset = @intCast(desc.src.offset);
        region.imageSubresource.mipLevel = @intCast(desc.dst.mip_level);
        region.imageOffset.x = desc.dst.x;
        region.imageOffset.y = desc.dst.y;
        region.imageExtent.width = @intCast(desc.size.width);
        region.imageExtent.height = @intCast(desc.size.height);
        if (dst.cmn.type == .@"3d") {
            region.imageOffset.z = desc.dst.slice;
            region.imageExtent.depth = @intCast(desc.size.num_slices);
        } else {
            region.imageSubresource.baseArrayLayer = @intCast(desc.dst.slice);
            region.imageSubresource.layerCount = @intCast(desc.size.num_slices);
        }
        d.vkCmdCopyBufferToImage2(cmd_buf, &copy_info);
        core.statsInc("vk.num_cmd_copy_buffer_to_image");
        barrier.bufferBarrier(d, cmd_buf, src, barrier.defaultBufferAccessMask(src.cmn.usage));
        barrier.imageBarrier(d, cmd_buf, dst, barrier.defaultImageAccessMask());
    }

    pub fn pushDebugGroup(self: *Backend, name: [*:0]const u8) void {
        if (!config.debug) return;
        const cmd_buf = self.frame.cmd_buf orelse return;
        const begin = self.fns.device.vkCmdBeginDebugUtilsLabelEXT orelse return;
        const label: sdk.DebugUtilsLabelEXT = .{ .sType = sdk.STRUCTURE_TYPE_DEBUG_UTILS_LABEL_EXT, .pNext = null, .pLabelName = name, .color = .{ 0, 0, 0, 0 } };
        begin(cmd_buf, &label);
    }

    pub fn requestBufferRead(self: *Backend, buffer: *core.Buffer, offset: usize, out: []u8) ?*@import("../../readback_task.zig").Task {
        if (self.frame.cmd_buf != null) self.commit();
        const read = NativeRead.create(self, out.len, out) orelse return null;
        var submitted = false;
        defer if (!submitted) read.destroyResources();
        readbackDependency(self, read.command, false);
        const access = buffer.native.vulkan.cur_access;
        barrier.bufferBarrier(&self.fns.device, read.command, buffer, barrier.copy_src);
        const copy: sdk.BufferCopy = .{ .srcOffset = offset, .dstOffset = 0, .size = out.len };
        self.fns.device.vkCmdCopyBuffer(read.command, buffer.native.vulkan.buf, read.staging.buf, 1, @ptrCast(&copy));
        barrier.bufferBarrier(&self.fns.device, read.command, buffer, access);
        readbackDependency(self, read.command, true);
        if (!read.submit()) return null;
        submitted = true;
        return &read.task;
    }
    pub fn requestImageRead(self: *Backend, image: *core.Image, region: *const core.ReadRegion, out: []u8) ?*@import("../../readback_task.zig").Task {
        if (self.frame.cmd_buf != null) self.commit();
        const bpp: usize = @intCast(formats.pixelSize(image.cmn.pixel_format));
        const row = @as(usize, region.width) * bpp;
        const read = NativeRead.create(self, row * region.height * region.num_slices, out) orelse return null;
        var submitted = false;
        defer if (!submitted) read.destroyResources();
        read.row_bytes = row;
        read.rows = region.height;
        read.slices = region.num_slices;
        read.target_row = region.bytes_per_row;
        read.target_slice = region.bytes_per_slice;
        const is3d = image.cmn.type == .@"3d";
        const old_layout = barrier.imageLayout(image.native.vulkan.cur_access);
        readbackDependency(self, read.command, false);
        readbackTransition(self, image.native.vulkan.img, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, read.command, sdk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT, sdk.ACCESS_2_MEMORY_READ_BIT | sdk.ACCESS_2_MEMORY_WRITE_BIT, sdk.PIPELINE_STAGE_2_COPY_BIT, sdk.ACCESS_2_TRANSFER_READ_BIT, old_layout);
        const copy: sdk.BufferImageCopy = .{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = sdk.IMAGE_ASPECT_COLOR_BIT, .mipLevel = region.mip_level, .baseArrayLayer = if (is3d) 0 else region.slice, .layerCount = if (is3d) 1 else region.num_slices }, .imageOffset = .{ .x = @intCast(region.x), .y = @intCast(region.y), .z = if (is3d) @intCast(region.slice) else 0 }, .imageExtent = .{ .width = region.width, .height = region.height, .depth = if (is3d) region.num_slices else 1 } };
        self.fns.device.vkCmdCopyImageToBuffer(read.command, image.native.vulkan.img, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, read.staging.buf, 1, @ptrCast(&copy));
        readbackTransition(self, image.native.vulkan.img, old_layout, read.command, sdk.PIPELINE_STAGE_2_COPY_BIT, sdk.ACCESS_2_TRANSFER_READ_BIT, sdk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT, sdk.ACCESS_2_MEMORY_READ_BIT | sdk.ACCESS_2_MEMORY_WRITE_BIT, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        readbackDependency(self, read.command, true);
        if (!read.submit()) return null;
        submitted = true;
        return &read.task;
    }

    /// Readback (zicr extension): waits for committed GPU work, copies buffer bytes into `out`.
    pub fn readBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
        if (self.frame.cmd_buf != null) self.commit();
        return readbackBuffer(self, buf, offset, out);
    }

    /// Readback (zicr extension): waits for committed GPU work, copies an image region into `out`.
    pub fn readImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
        if (self.frame.cmd_buf != null) self.commit();
        return readbackImage(self, img, region, out);
    }

    pub fn popDebugGroup(self: *Backend) void {
        if (!config.debug) return;
        const cmd_buf = self.frame.cmd_buf orelse return;
        const end = self.fns.device.vkCmdEndDebugUtilsLabelEXT orelse return;
        end(cmd_buf);
    }
};

fn mipSource(src: anytype) memory.MipSource {
    return .{
        .ptr = @ptrCast(src.data.ptr.?),
        .size = src.data.size,
        .offset = src.offset,
        .bytes_per_row = src.bytes_per_row,
        .bytes_per_slice = src.bytes_per_slice,
    };
}

fn mipRegion(dst: anytype, size: anytype) memory.MipRegion {
    return .{
        .mip_level = dst.mip_level,
        .x = dst.x,
        .y = dst.y,
        .slice = dst.slice,
        .width = size.width,
        .height = size.height,
        .num_slices = size.num_slices,
    };
}

// ---------------------------------------------------------------- readback (zicr extension)

/// A host-visible temporary buffer that receives a copy of GPU data.
const ReadbackStaging = struct {
    buf: u64,
    mem: u64,
};

fn createReadbackStaging(self: *Backend, size: u64) ?ReadbackStaging {
    const info: sdk.BufferCreateInfo = .{
        .sType = sdk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = sdk.BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = sdk.SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var buf: u64 = 0;
    if (observe(self.fns.device.vkCreateBuffer(self.dev, &info, null, &buf)) != sdk.SUCCESS) return null;
    var reqs: sdk.MemoryRequirements = undefined;
    self.fns.device.vkGetBufferMemoryRequirements(self.dev, buf, &reqs);
    const mem = memory.allocDeviceMemory(self, .staging_readback, &reqs);
    if (mem == 0) {
        self.fns.device.vkDestroyBuffer(self.dev, buf, null);
        return null;
    }
    if (observe(self.fns.device.vkBindBufferMemory(self.dev, buf, mem, 0)) != sdk.SUCCESS) {
        self.fns.device.vkDestroyBuffer(self.dev, buf, null);
        memory.freeDeviceMemory(self, mem);
        return null;
    }
    return .{ .buf = buf, .mem = mem };
}

fn destroyReadbackStaging(self: *Backend, staging: ReadbackStaging) void {
    self.fns.device.vkDestroyBuffer(self.dev, staging.buf, null);
    memory.freeDeviceMemory(self, staging.mem);
}

/// Maps the staging memory; the caller unmaps it after copying out.
fn mapReadbackStaging(self: *Backend, staging: ReadbackStaging, size: u64) ?[*]u8 {
    var ptr: ?*anyopaque = null;
    if (observe(self.fns.device.vkMapMemory(self.dev, staging.mem, 0, size, 0, &ptr)) != sdk.SUCCESS) return null;
    const p: [*]u8 = @ptrCast(ptr orelse return null);
    return p;
}

/// Cross-submission execution dependency for transfers. Readback destinations
/// may reuse device-memory ranges previously read as vertices; queue order alone
/// does not create the execution dependency required for a write-after-read.
fn readbackDependency(self: *Backend, cmd: sdk.CommandBuffer, host_read: bool) void {
    const memory_barrier: sdk.MemoryBarrier2 = .{ .sType = sdk.STRUCTURE_TYPE_MEMORY_BARRIER_2, .srcStageMask = if (host_read) sdk.PIPELINE_STAGE_2_COPY_BIT else sdk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .srcAccessMask = if (host_read) sdk.ACCESS_2_TRANSFER_WRITE_BIT else sdk.ACCESS_2_MEMORY_READ_BIT | sdk.ACCESS_2_MEMORY_WRITE_BIT, .dstStageMask = if (host_read) 0x4000 else sdk.PIPELINE_STAGE_2_COPY_BIT, .dstAccessMask = if (host_read) 0x2000 else sdk.ACCESS_2_TRANSFER_READ_BIT | sdk.ACCESS_2_TRANSFER_WRITE_BIT };
    const dependency: sdk.DependencyInfo = .{ .sType = sdk.STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &memory_barrier };
    self.fns.device.vkCmdPipelineBarrier2(cmd, &dependency);
}

/// Copies `out.len` bytes starting at `offset`. Waits for all submitted work (memory.stagingCopyEnd).
fn readbackBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
    const staging = createReadbackStaging(self, out.len) orelse return false;
    defer destroyReadbackStaging(self, staging);
    const d = &self.fns.device;
    const cmd = memory.stagingCopyBegin(self) orelse return false;
    readbackDependency(self, cmd, false);
    const old_access = buf.native.vulkan.cur_access;
    barrier.bufferBarrier(d, cmd, buf, barrier.copy_src);
    const region: sdk.BufferCopy = .{ .srcOffset = offset, .dstOffset = 0, .size = out.len };
    d.vkCmdCopyBuffer(cmd, buf.native.vulkan.buf, staging.buf, 1, @ptrCast(&region));
    core.statsInc("vk.num_cmd_copy_buffer");
    barrier.bufferBarrier(d, cmd, buf, old_access);
    readbackDependency(self, cmd, true);
    if (!memory.stagingCopyEnd(self, cmd)) return false;
    const src = mapReadbackStaging(self, staging, out.len) orelse return false;
    @memcpy(out, src[0..out.len]);
    self.fns.device.vkUnmapMemory(self.dev, staging.mem);
    return true;
}

/// Layout transition of a whole image around a copy. The tracked access (`cur_access`) is left
/// unchanged; only the Vulkan layout is moved and then moved back. Uses conservative sync.
fn readbackTransition(self: *Backend, image: u64, new_layout: i32, cmd: sdk.CommandBuffer, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64, old_layout: i32) void {
    const bar: sdk.ImageMemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = src_stage,
        .srcAccessMask = src_access,
        .dstStageMask = dst_stage,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{ .aspectMask = sdk.IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = sdk.REMAINING_MIP_LEVELS, .baseArrayLayer = 0, .layerCount = sdk.REMAINING_ARRAY_LAYERS },
    };
    const dep: sdk.DependencyInfo = .{
        .sType = sdk.STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &bar,
    };
    self.fns.device.vkCmdPipelineBarrier2(cmd, &dep);
    core.statsInc("vk.num_cmd_pipeline_barrier");
}

/// Copies one mip level region of an image into `out`, honouring bytes_per_row and bytes_per_slice.
/// The GPU copy packs the region tightly into a staging buffer; the CPU copy then applies the pitches.
fn readbackImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
    const payload = &img.native.vulkan;
    const is3d = img.cmn.type == .@"3d";
    const px: usize = @intCast(formats.pixelSize(img.cmn.pixel_format));
    const row_bytes: usize = @as(usize, region.width) * px;
    const rows: usize = region.height;
    const slices: usize = region.num_slices;
    const total = row_bytes * rows * slices;
    const staging = createReadbackStaging(self, total) orelse return false;
    defer destroyReadbackStaging(self, staging);

    const d = &self.fns.device;
    const cmd = memory.stagingCopyBegin(self) orelse return false;
    readbackDependency(self, cmd, false);
    const old_layout = barrier.imageLayout(payload.cur_access);
    // conservative synchronization: everything before, transfer read, everything after
    const all_stages = sdk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    const all_access = sdk.ACCESS_2_MEMORY_READ_BIT | sdk.ACCESS_2_MEMORY_WRITE_BIT;
    readbackTransition(self, payload.img, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, cmd, all_stages, all_access, sdk.PIPELINE_STAGE_2_COPY_BIT, sdk.ACCESS_2_TRANSFER_READ_BIT, old_layout);
    const copy: sdk.BufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0, // tightly packed
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = sdk.IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = region.mip_level,
            .baseArrayLayer = if (is3d) 0 else region.slice,
            .layerCount = if (is3d) 1 else region.num_slices,
        },
        .imageOffset = .{ .x = @intCast(region.x), .y = @intCast(region.y), .z = if (is3d) @intCast(region.slice) else 0 },
        .imageExtent = .{ .width = region.width, .height = region.height, .depth = if (is3d) region.num_slices else 1 },
    };
    d.vkCmdCopyImageToBuffer(cmd, payload.img, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buf, 1, @ptrCast(&copy));
    core.statsInc("vk.num_cmd_copy_buffer_to_image");
    readbackTransition(self, payload.img, old_layout, cmd, sdk.PIPELINE_STAGE_2_COPY_BIT, sdk.ACCESS_2_TRANSFER_READ_BIT, all_stages, all_access, sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    readbackDependency(self, cmd, true);
    if (!memory.stagingCopyEnd(self, cmd)) return false;

    const src = mapReadbackStaging(self, staging, total) orelse return false;
    defer self.fns.device.vkUnmapMemory(self.dev, staging.mem);
    for (0..slices) |s| {
        for (0..rows) |r| {
            const from = (s * rows + r) * row_bytes;
            const to = s * region.bytes_per_slice + r * region.bytes_per_row;
            @memcpy(out[to..][0..row_bytes], src[from..][0..row_bytes]);
        }
    }
    return true;
}

// Every asynchronous copy owns its command pool, staging allocation and fence.
// Frame-slot recycling cannot reset a command buffer whose ticket is pending.
const NativeRead = struct {
    task: @import("../../readback_task.zig").Task,
    backend: *Backend,
    staging: ReadbackStaging = .{ .buf = 0, .mem = 0 },
    pool: sdk.CommandPool = 0,
    command: sdk.CommandBuffer = null,
    fence: sdk.Fence = 0,
    size: usize,
    row_bytes: usize = 0,
    rows: usize = 1,
    slices: usize = 1,
    target_row: usize = 0,
    target_slice: usize = 0,
    query_error_reported: bool = false,
    fn create(backend: *Backend, size: usize, out: []u8) ?*NativeRead {
        const read = backend.allocator.create(NativeRead) catch return null;
        read.* = .{ .task = .{ .owner = core.state(), .allocator = backend.allocator, .data = out, .poll_fn = poll, .destroy_fn = destroy }, .backend = backend, .size = size };
        var success = false;
        defer if (!success) read.destroyResources();
        read.staging = createReadbackStaging(backend, size) orelse return null;
        const pool_info: sdk.CommandPoolCreateInfo = .{ .sType = sdk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = backend.queue_family_index };
        const d = &backend.fns.device;
        if (observe(d.vkCreateCommandPool(backend.dev, &pool_info, null, &read.pool)) != sdk.SUCCESS) return null;
        const allocation: sdk.CommandBufferAllocateInfo = .{ .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = read.pool, .level = sdk.COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        if (observe(d.vkAllocateCommandBuffers(backend.dev, &allocation, &read.command)) != sdk.SUCCESS) return null;
        const fence_info: sdk.FenceCreateInfo = .{ .sType = sdk.STRUCTURE_TYPE_FENCE_CREATE_INFO };
        if (observe(d.vkCreateFence(backend.dev, &fence_info, null, &read.fence)) != sdk.SUCCESS) return null;
        const begin_info: sdk.CommandBufferBeginInfo = .{ .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = sdk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        if (observe(d.vkBeginCommandBuffer(read.command, &begin_info)) != sdk.SUCCESS) return null;
        success = true;
        return read;
    }
    fn submit(self: *NativeRead) bool {
        const backend = self.backend;
        if (observe(backend.fns.device.vkEndCommandBuffer(self.command)) != sdk.SUCCESS) return false;
        const info: sdk.SubmitInfo = .{ .sType = sdk.STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&self.command) };
        core.statsInc("vk.num_queue_submits");
        return observe(backend.fns.device.vkQueueSubmit(backend.queue, 1, @ptrCast(&info), self.fence)) == sdk.SUCCESS;
    }
    fn poll(task: *@import("../../readback_task.zig").Task, wait: bool) error{ReadFailed}!bool {
        const self: *NativeRead = @alignCast(@fieldParentPtr("task", task));
        const backend = self.backend;
        const d = &backend.fns.device;
        const result = observe(if (wait) d.vkWaitForFences(backend.dev, 1, @ptrCast(&self.fence), sdk.TRUE, std.math.maxInt(u64)) else d.vkGetFenceStatus(backend.dev, self.fence));
        var progress = @import("result.zig").fenceProgress(result);
        if (progress == .retry and wait) {
            // Only teardown may block. If a fence query failed without removal,
            // a successful idle wait is independent proof that copies finished.
            const idle = observe(d.vkDeviceWaitIdle(backend.dev));
            progress = if (idle == sdk.SUCCESS) .complete else if (idle == -4) .lost else .retry;
        }
        switch (progress) {
            .pending => return false,
            .lost => return error.ReadFailed,
            .retry => {
                if (!self.query_error_reported) {
                    core.logWarn(.vulkan_fence_status_retry);
                    self.query_error_reported = true;
                }
                return false; // retain GPU ownership until completion is proved
            },
            .complete => {},
        }
        if (task.refs == 1) return true; // cancelled: no CPU copy is needed
        const source = mapReadbackStaging(backend, self.staging, self.size) orelse return error.ReadFailed;
        defer d.vkUnmapMemory(backend.dev, self.staging.mem);
        if (self.row_bytes == 0) {
            @memcpy(task.data, source[0..task.data.len]);
        } else for (0..self.slices) |slice| for (0..self.rows) |row| {
            const from = (slice * self.rows + row) * self.row_bytes;
            const to = slice * self.target_slice + row * self.target_row;
            @memcpy(task.data[to..][0..self.row_bytes], source[from..][0..self.row_bytes]);
        };
        return true;
    }
    fn destroyResources(self: *NativeRead) void {
        const backend = self.backend;
        if (self.pool != 0) backend.fns.device.vkDestroyCommandPool(backend.dev, self.pool, null);
        if (self.fence != 0) backend.fns.device.vkDestroyFence(backend.dev, self.fence, null);
        if (self.staging.buf != 0) destroyReadbackStaging(backend, self.staging);
        backend.allocator.destroy(self);
    }
    fn destroy(task: *@import("../../readback_task.zig").Task) void {
        const self: *NativeRead = @alignCast(@fieldParentPtr("task", task));
        task.allocator.free(task.data);
        self.destroyResources();
    }
};

test "cancelled readback retains GPU objects after a healthy fence-query error" {
    const Task = @import("../../readback_task.zig").Task;
    const Mock = struct {
        var queries: usize = 0;
        var destroyed: usize = 0;
        var idle_calls: usize = 0;
        var buffers_destroyed: usize = 0;
        fn destroyBuffer(_: sdk.Device, _: sdk.Buffer, _: ?*const sdk.AllocationCallbacks) callconv(.c) void {
            buffers_destroyed += 1;
        }
        fn waitFailure(_: sdk.Device, _: u32, _: [*]const sdk.Fence, _: u32, _: u64) callconv(.c) i32 {
            return -1;
        }
        fn idle(_: sdk.Device) callconv(.c) i32 {
            idle_calls += 1;
            return sdk.SUCCESS;
        }
        fn removed(_: sdk.Device, _: sdk.Fence) callconv(.c) i32 {
            return -4;
        }
        fn status(_: sdk.Device, _: sdk.Fence) callconv(.c) i32 {
            queries += 1;
            return if (queries == 1) -1 else sdk.SUCCESS; // transient host OOM
        }
        fn discard(_: *Task) void {
            destroyed += 1;
        }
        fn log(_: ?[*:0]const u8, _: u32, _: u32, _: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {}
    };
    Mock.queries = 0;
    Mock.destroyed = 0;
    Mock.idle_calls = 0;
    Mock.buffers_destroyed = 0;
    var state: core.State = .{ .allocator = std.testing.allocator, .desc = .{}, .pools = undefined, .backend = .dummy, .commit_listeners = &.{} };
    state.desc.logger.func = Mock.log;
    const scope = core.enter(&state);
    defer scope.end();
    defer state.readbacks.deinit(std.testing.allocator);
    var backend: Backend = .{ .allocator = std.testing.allocator };
    backend.fns.device.vkGetFenceStatus = Mock.status;
    backend.fns.device.vkWaitForFences = Mock.waitFailure;
    backend.fns.device.vkDeviceWaitIdle = Mock.idle;
    backend.fns.device.vkDestroyBuffer = Mock.destroyBuffer;
    var retired = [_]memory.DeleteItem{.{ .kind = .buffer, .obj = 42 }};
    backend.frame.slots[0].delete_queue = .{ .items = &retired, .index = 1 };
    var bytes: [1]u8 = .{0};
    var read: NativeRead = .{ .backend = &backend, .fence = 1, .size = 1, .task = .{ .owner = &state, .allocator = std.testing.allocator, .data = &bytes, .poll_fn = NativeRead.poll, .destroy_fn = Mock.discard } };
    try state.readbacks.append(std.testing.allocator, &read.task);
    read.task.release(); // client cancels, Device still owns its reference
    @import("../../readback_task.zig").collect(&state, false);
    try std.testing.expectEqual(@as(usize, 1), state.readbacks.items.len);
    try std.testing.expectEqual(@as(usize, 0), Mock.destroyed);
    try std.testing.expect(!read.task.failed);
    try std.testing.expectEqual(@as(usize, 0), Mock.idle_calls);
    try std.testing.expectEqual(@as(i32, 0), state.loss_code.load(.acquire));
    memory.deleteQueueCollect(&backend);
    try std.testing.expectEqual(@as(usize, 0), Mock.buffers_destroyed);
    try std.testing.expectEqual(@as(u32, 1), backend.frame.slots[0].delete_queue.index);
    @import("../../readback_task.zig").collect(&state, false);
    try std.testing.expectEqual(@as(usize, 0), state.readbacks.items.len);
    try std.testing.expectEqual(@as(usize, 1), Mock.destroyed);
    memory.deleteQueueCollect(&backend);
    try std.testing.expectEqual(@as(usize, 1), Mock.buffers_destroyed);
    try std.testing.expectEqual(@as(u32, 0), backend.frame.slots[0].delete_queue.index);
    // Reuse the now-retired stack fixture: teardown may prove completion through
    // an independent idle wait when the private fence wait itself fails.
    read.task = .{ .owner = &state, .allocator = std.testing.allocator, .data = &bytes, .poll_fn = NativeRead.poll, .destroy_fn = Mock.discard };
    try state.readbacks.append(std.testing.allocator, &read.task);
    read.task.release();
    @import("../../readback_task.zig").collect(&state, true);
    try std.testing.expectEqual(@as(usize, 0), state.readbacks.items.len);
    try std.testing.expectEqual(@as(usize, 1), Mock.idle_calls);
    try std.testing.expectEqual(@as(usize, 2), Mock.destroyed);
    // Confirmed removal is terminal, rather than a healthy-device query failure.
    read.task = .{ .owner = &state, .allocator = std.testing.allocator, .data = &bytes, .poll_fn = NativeRead.poll, .destroy_fn = Mock.discard };
    backend.fns.device.vkGetFenceStatus = Mock.removed;
    try state.readbacks.append(std.testing.allocator, &read.task);
    read.task.release();
    @import("../../readback_task.zig").collect(&state, false);
    try std.testing.expectEqual(@as(usize, 0), state.readbacks.items.len);
    try std.testing.expectEqual(@as(usize, 3), Mock.destroyed);
    try std.testing.expectEqual(@as(i32, -4), state.loss_code.load(.acquire));
    try std.testing.expect(read.task.failed);
}
