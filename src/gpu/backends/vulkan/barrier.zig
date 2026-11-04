//! Access tracking and pipeline barriers, sokol_gfx.h:20694-21253.
//! Every resource records its current access (`cur_access`), and barriers are
//! recorded when the access changes. Read-only accesses never need a barrier
//! between each other.
const std = @import("std");
const core = @import("../../core.zig");
const t = @import("../../types.zig");
const sdk = @import("sdk.zig");
const res = @import("resources.zig");

pub const Access = u32;
pub const none: Access = 0;
pub const copy_src: Access = 1 << 0;
pub const copy_dst: Access = 1 << 1;
pub const vertexbuffer: Access = 1 << 2;
pub const indexbuffer: Access = 1 << 3;
pub const storagebuffer_ro: Access = 1 << 4;
pub const storagebuffer_rw_compute: Access = 1 << 5;
pub const storagebuffer_rw_fragment: Access = 1 << 6;
pub const texture: Access = 1 << 7;
pub const storageimage: Access = 1 << 8;
pub const color_attachment: Access = 1 << 9;
pub const resolve_attachment: Access = 1 << 10;
pub const depth_attachment: Access = 1 << 11;
pub const stencil_attachment: Access = 1 << 12;
/// In combination with attachments: the previous content may be discarded.
pub const discard: Access = 1 << 13;
pub const present: Access = 1 << 14;

pub fn defaultBufferAccessMask(usage: t.BufferUsage) Access {
    var r: Access = none;
    if (usage.vertex_buffer) r |= vertexbuffer;
    if (usage.index_buffer) r |= indexbuffer;
    if (usage.storage_buffer) r |= storagebuffer_ro;
    if (usage.copy_src) r |= copy_src;
    return r;
}

pub fn defaultImageAccessMask() Access {
    return texture;
}

fn isReadAccess(access: Access) bool {
    const read_bits = vertexbuffer | indexbuffer | storagebuffer_ro | copy_src | texture | present;
    return 0 == (access & ~read_bits);
}

fn stageMask(access_in: Access, is_dst_access: bool) u64 {
    const access = access_in & ~discard;
    if (is_dst_access) std.debug.assert(access != none);
    var f: u64 = 0;
    if (access == none) return sdk.PIPELINE_STAGE_2_NONE;
    if (access & present != 0) return sdk.PIPELINE_STAGE_2_NONE;
    if (access & (copy_dst | copy_src) != 0) f |= sdk.PIPELINE_STAGE_2_COPY_BIT;
    if (access & vertexbuffer != 0) f |= sdk.PIPELINE_STAGE_2_VERTEX_ATTRIBUTE_INPUT_BIT;
    if (access & indexbuffer != 0) f |= sdk.PIPELINE_STAGE_2_INDEX_INPUT_BIT;
    if (access & (storagebuffer_ro | texture) != 0) {
        f |= sdk.PIPELINE_STAGE_2_VERTEX_SHADER_BIT | sdk.PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT | sdk.PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    }
    if (access & storagebuffer_rw_compute != 0) f |= sdk.PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    if (access & storagebuffer_rw_fragment != 0) f |= sdk.PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    if (access & storageimage != 0) f |= sdk.PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    if (access & color_attachment != 0) f |= sdk.PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    if (access & resolve_attachment != 0) f |= sdk.PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    if (access & (depth_attachment | stencil_attachment) != 0) {
        f |= sdk.PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | sdk.PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
    }
    std.debug.assert(f != 0);
    return f;
}

fn srcStageMask(access: Access) u64 {
    return stageMask(access, false);
}

fn dstStageMask(access: Access) u64 {
    return stageMask(access, true);
}

fn accessMask(access_in: Access, is_dst_access: bool) u64 {
    const access = access_in & ~discard;
    if (access == none) return sdk.ACCESS_2_NONE;
    if (access & present != 0) return sdk.ACCESS_2_NONE;
    var f: u64 = sdk.ACCESS_2_NONE;
    if (is_dst_access) {
        // read bits don't make sense for the src-mask
        if (access & vertexbuffer != 0) f |= sdk.ACCESS_2_VERTEX_ATTRIBUTE_READ_BIT;
        if (access & indexbuffer != 0) f |= sdk.ACCESS_2_INDEX_READ_BIT;
        if (access & storagebuffer_ro != 0) f |= sdk.ACCESS_2_SHADER_STORAGE_READ_BIT;
        if (access & texture != 0) f |= sdk.ACCESS_2_SHADER_SAMPLED_READ_BIT;
    }
    if (access & copy_dst != 0) f |= sdk.ACCESS_2_TRANSFER_WRITE_BIT;
    if (access & copy_src != 0) f |= sdk.ACCESS_2_TRANSFER_READ_BIT;
    if (access & (storagebuffer_rw_compute | storagebuffer_rw_fragment) != 0) {
        f |= sdk.ACCESS_2_SHADER_STORAGE_WRITE_BIT | sdk.ACCESS_2_SHADER_STORAGE_READ_BIT;
    }
    if (access & storageimage != 0) {
        f |= sdk.ACCESS_2_SHADER_STORAGE_WRITE_BIT | sdk.ACCESS_2_SHADER_STORAGE_READ_BIT;
    }
    if (access & color_attachment != 0) {
        f |= sdk.ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
        if (is_dst_access) f |= sdk.ACCESS_2_COLOR_ATTACHMENT_READ_BIT;
    }
    if (access & resolve_attachment != 0) f |= sdk.ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    if (access & (depth_attachment | stencil_attachment) != 0) {
        f |= sdk.ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        if (is_dst_access) f |= sdk.ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
    }
    return f;
}

fn srcAccessMask(access: Access) u64 {
    return accessMask(access, false);
}

fn dstAccessMask(access: Access) u64 {
    return accessMask(access, true);
}

pub fn imageLayout(access: Access) i32 {
    // NOTE: "image layout transitions with VK_IMAGE_LAYOUT_UNDEFINED allow
    // the implementation to discard the image subresource range"
    if (access & discard != 0) return sdk.IMAGE_LAYOUT_UNDEFINED;
    return switch (access) {
        none => sdk.IMAGE_LAYOUT_UNDEFINED,
        copy_src => sdk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        copy_dst => sdk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        texture => sdk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        storageimage => sdk.IMAGE_LAYOUT_GENERAL,
        color_attachment, resolve_attachment, depth_attachment, depth_attachment | stencil_attachment => sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
        present => sdk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
        else => unreachable,
    };
}

fn subresourceAspect(pass_access: Access) u32 {
    if (pass_access & (depth_attachment | stencil_attachment) != 0) {
        var aspect: u32 = sdk.IMAGE_ASPECT_DEPTH_BIT;
        if (pass_access & stencil_attachment != 0) aspect |= sdk.IMAGE_ASPECT_STENCIL_BIT;
        return aspect;
    }
    return sdk.IMAGE_ASPECT_COLOR_BIT;
}

fn imageBarrierInfo(dev_fn: *const fn (sdk.CommandBuffer, *const sdk.DependencyInfo) callconv(.c) void, cmd_buf: sdk.CommandBuffer, barriers: *const sdk.ImageMemoryBarrier2) void {
    const dep_info: sdk.DependencyInfo = .{
        .sType = sdk.STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = barriers,
    };
    dev_fn(cmd_buf, &dep_info);
    core.statsInc("vk.num_cmd_pipeline_barrier");
}

/// Transition of a swapchain image at the beginning of a pass (sokol_gfx.h:20900).
pub fn swapchainBeginPassBarrier(dispatch: *const sdk.DeviceFns, cmd_buf: sdk.CommandBuffer, vk_img: sdk.Image, pass_access: Access, old_layout: i32) void {
    const barrier: sdk.ImageMemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = srcStageMask(pass_access),
        .srcAccessMask = srcAccessMask(pass_access),
        .dstStageMask = dstStageMask(pass_access),
        .dstAccessMask = dstAccessMask(pass_access),
        .oldLayout = old_layout,
        .newLayout = sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .image = vk_img,
        .subresourceRange = .{
            .aspectMask = subresourceAspect(pass_access),
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    imageBarrierInfo(dispatch.vkCmdPipelineBarrier2, cmd_buf, &barrier);
}

/// Transition of a swapchain image at the end of a pass (sokol_gfx.h:20931).
pub fn swapchainEndPassBarrier(dispatch: *const sdk.DeviceFns, cmd_buf: sdk.CommandBuffer, vk_img: sdk.Image, pass_access: Access, present_it: bool) void {
    const barrier: sdk.ImageMemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = srcStageMask(pass_access),
        .srcAccessMask = srcAccessMask(pass_access),
        .dstStageMask = sdk.PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = sdk.ACCESS_2_NONE,
        .oldLayout = sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
        .newLayout = if (present_it) sdk.IMAGE_LAYOUT_PRESENT_SRC_KHR else sdk.IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .image = vk_img,
        .subresourceRange = .{
            .aspectMask = subresourceAspect(pass_access),
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    imageBarrierInfo(dispatch.vkCmdPipelineBarrier2, cmd_buf, &barrier);
}

/// Transitions an image to `new_access` unless both old and new access are reads.
pub fn imageBarrier(dispatch: *const sdk.DeviceFns, cmd_buf: sdk.CommandBuffer, img: *core.Image, new_access: Access) void {
    const payload = &img.native.vulkan;
    std.debug.assert(payload.img != 0);
    if (isReadAccess(payload.cur_access) and isReadAccess(new_access)) return;
    const aspect: u32 = if (core.isDepthOrDepthStencilFormat(img.cmn.pixel_format))
        sdk.IMAGE_ASPECT_DEPTH_BIT | (if (core.isDepthStencilFormat(img.cmn.pixel_format)) sdk.IMAGE_ASPECT_STENCIL_BIT else 0)
    else
        sdk.IMAGE_ASPECT_COLOR_BIT;
    const barrier: sdk.ImageMemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = srcStageMask(payload.cur_access),
        .srcAccessMask = srcAccessMask(payload.cur_access),
        .dstStageMask = dstStageMask(new_access),
        .dstAccessMask = dstAccessMask(new_access),
        .oldLayout = imageLayout(payload.cur_access),
        .newLayout = imageLayout(new_access),
        .srcQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .image = payload.img,
        .subresourceRange = .{
            .aspectMask = aspect,
            .baseMipLevel = 0,
            .levelCount = sdk.REMAINING_MIP_LEVELS,
            .baseArrayLayer = 0,
            .layerCount = sdk.REMAINING_ARRAY_LAYERS,
        },
    };
    imageBarrierInfo(dispatch.vkCmdPipelineBarrier2, cmd_buf, &barrier);
    payload.cur_access = new_access;
}

/// Transitions a buffer to `new_access` unless both old and new access are reads.
pub fn bufferBarrier(dispatch: *const sdk.DeviceFns, cmd_buf: sdk.CommandBuffer, buf: *core.Buffer, new_access: Access) void {
    const payload = &buf.native.vulkan;
    std.debug.assert(payload.buf != 0);
    if (isReadAccess(payload.cur_access) and isReadAccess(new_access)) return;
    const barrier: sdk.BufferMemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = srcStageMask(payload.cur_access),
        .srcAccessMask = srcAccessMask(payload.cur_access),
        .dstStageMask = dstStageMask(new_access),
        .dstAccessMask = dstAccessMask(new_access),
        .srcQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = sdk.QUEUE_FAMILY_IGNORED,
        .buffer = payload.buf,
        .offset = 0,
        .size = sdk.WHOLE_SIZE,
    };
    const dep_info: sdk.DependencyInfo = .{
        .sType = sdk.STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .bufferMemoryBarrierCount = 1,
        .pBufferMemoryBarriers = &barrier,
    };
    dispatch.vkCmdPipelineBarrier2(cmd_buf, &dep_info);
    core.statsInc("vk.num_cmd_pipeline_barrier");
    payload.cur_access = new_access;
}

/// Storage buffers written in fragment shaders need a memory barrier inside render passes (sokol_gfx.h:21027).
pub fn renderPassStorageBarrier(dispatch: *const sdk.DeviceFns, cmd_buf: sdk.CommandBuffer) void {
    const barrier: sdk.MemoryBarrier2 = .{
        .sType = sdk.STRUCTURE_TYPE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = sdk.PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT | sdk.PIPELINE_STAGE_2_COMPUTE_SHADER_BIT | sdk.PIPELINE_STAGE_2_COPY_BIT,
        .srcAccessMask = sdk.ACCESS_2_NONE,
        .dstStageMask = sdk.PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
        .dstAccessMask = sdk.ACCESS_2_NONE,
    };
    const dep_info: sdk.DependencyInfo = .{
        .sType = sdk.STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 1,
        .pMemoryBarriers = &barrier,
    };
    dispatch.vkCmdPipelineBarrier2(cmd_buf, &dep_info);
    core.statsInc("vk.num_cmd_pipeline_barrier");
}
