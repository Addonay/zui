//! Portable descriptor-set strategy. Each frame owns its pool, reset only after
//! that frame's fence completes. No optional Vulkan extensions are used here.
const std = @import("std");
const sdk = @import("sdk.zig");
const core = @import("../../core.zig");
const c = @import("../../constants.zig");
const Backend = @import("backend.zig").Backend;
const observe = @import("result.zig").observe;

pub fn init(self: *Backend, capacity: u32) !void {
    if (capacity == 0 or capacity > 1024 * 1024) return error.VulkanInitFailed;
    const sizes = [_]sdk.DescriptorPoolSize{
        .{ .type = sdk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = @intCast(capacity * c.max_uniformblock_bindslots) },
        .{ .type = sdk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = @intCast(capacity * c.max_view_bindslots) },
        .{ .type = sdk.DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = @intCast(capacity * c.max_view_bindslots) },
        .{ .type = sdk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = @intCast(capacity * c.max_view_bindslots) },
        .{ .type = sdk.DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = @intCast(capacity * c.max_sampler_bindslots) },
    };
    const info: sdk.DescriptorPoolCreateInfo = .{ .maxSets = capacity, .poolSizeCount = sizes.len, .pPoolSizes = &sizes };
    errdefer deinit(self);
    for (&self.descriptor_pools) |*pool| {
        if (observe(self.fns.device.vkCreateDescriptorPool(self.dev, &info, null, pool)) != sdk.SUCCESS) return error.VulkanInitFailed;
    }
}
pub fn deinit(self: *Backend) void {
    for (&self.descriptor_pools) |*pool| {
        if (pool.* != 0) self.fns.device.vkDestroyDescriptorPool(self.dev, pool.*, null);
        pool.* = 0;
    }
}
pub fn begin(self: *Backend) void {
    if (observe(self.fns.device.vkResetDescriptorPool(self.dev, self.descriptor_pools[self.frame_slot], 0)) != sdk.SUCCESS) core.state().next_draw_valid = false;
    self.descriptor_sets_used = 0;
}
fn allocate(self: *Backend, layout: sdk.DescriptorSetLayout) ?sdk.DescriptorSet {
    if (self.descriptor_sets_used >= self.descriptor_set_capacity) {
        core.logError(.vulkan_descriptor_pool_exhausted);
        return null;
    }
    const info: sdk.DescriptorSetAllocateInfo = .{ .descriptorPool = self.descriptor_pools[self.frame_slot], .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&layout) };
    var set: sdk.DescriptorSet = 0;
    if (observe(self.fns.device.vkAllocateDescriptorSets(self.dev, &info, @ptrCast(&set))) != sdk.SUCCESS) {
        core.logError(.vulkan_descriptor_pool_exhausted);
        return null;
    }
    self.descriptor_sets_used += 1;
    return set;
}
pub fn bindViews(self: *Backend, cmd: sdk.CommandBuffer, bnd: *const core.BindingsPtrs, point: i32) bool {
    const shader = bnd.pip.cmn.shader.get();
    const payload = &shader.native.vulkan;
    if (payload.view_smp_count == 0) return true;
    const set = allocate(self, payload.view_smp_dsl) orelse return false;
    var writes: [c.max_view_bindslots + c.max_sampler_bindslots]sdk.WriteDescriptorSet = undefined;
    var images: [c.max_view_bindslots + c.max_sampler_bindslots]sdk.DescriptorImageInfo = undefined;
    var buffers: [c.max_view_bindslots]sdk.DescriptorBufferInfo = undefined;
    var count: usize = 0;
    for (shader.cmn.views, 0..) |slot, i| {
        if (slot.stage == .none) continue;
        const view = bnd.views[i].?;
        writes[count] = .{ .dstSet = set, .dstBinding = payload.view_set1_bnd_n[i] };
        if (slot.view_type == .storagebuffer) {
            const buffer = view.cmn.buf.ref.get();
            const offset: u64 = @intCast(view.cmn.buf.offset);
            buffers[i] = .{ .buffer = buffer.native.vulkan.buf, .offset = offset, .range = buffer.cmn.size - offset };
            writes[count].descriptorType = sdk.DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[count].pBufferInfo = @ptrCast(&buffers[i]);
        } else {
            images[count] = .{ .sampler = 0, .imageView = view.native.vulkan.img_view, .imageLayout = if (slot.view_type == .storageimage) sdk.IMAGE_LAYOUT_GENERAL else sdk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
            writes[count].descriptorType = if (slot.view_type == .storageimage) sdk.DESCRIPTOR_TYPE_STORAGE_IMAGE else sdk.DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            writes[count].pImageInfo = @ptrCast(&images[count]);
        }
        count += 1;
    }
    for (shader.cmn.samplers, 0..) |slot, i| {
        if (slot.stage == .none) continue;
        images[count] = .{ .sampler = bnd.smps[i].?.native.vulkan.smp, .imageView = 0, .imageLayout = sdk.IMAGE_LAYOUT_UNDEFINED };
        writes[count] = .{ .dstSet = set, .dstBinding = payload.smp_set1_bnd_n[i], .descriptorType = sdk.DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = @ptrCast(&images[count]) };
        count += 1;
    }
    self.fns.device.vkUpdateDescriptorSets(self.dev, @intCast(count), &writes, 0, null);
    self.fns.device.vkCmdBindDescriptorSets(cmd, point, payload.pip_layout, 1, 1, @ptrCast(&set), 0, null);
    return true;
}
pub fn bindUniforms(self: *Backend, cmd: sdk.CommandBuffer) bool {
    const shader = core.state().cur_pip.get().cmn.shader.get();
    const payload = &shader.native.vulkan;
    self.uniforms.dirty = false;
    if (payload.ub_count == 0) return true;
    const set = allocate(self, payload.ub_dsl) orelse return false;
    var writes: [c.max_uniformblock_bindslots]sdk.WriteDescriptorSet = undefined;
    var count: usize = 0;
    for (shader.cmn.uniform_blocks, 0..) |slot, i| {
        if (slot.stage == .none) continue;
        writes[count] = .{ .dstSet = set, .dstBinding = payload.ub_set0_bnd_n[i], .descriptorType = sdk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = @ptrCast(&self.uniform_buffer_infos[i]) };
        count += 1;
    }
    self.fns.device.vkUpdateDescriptorSets(self.dev, @intCast(count), &writes, 0, null);
    const point: i32 = if (core.state().cur_pass.is_compute) sdk.PIPELINE_BIND_POINT_COMPUTE else sdk.PIPELINE_BIND_POINT_GRAPHICS;
    self.fns.device.vkCmdBindDescriptorSets(cmd, point, payload.pip_layout, 0, 1, @ptrCast(&set), 0, null);
    return true;
}
