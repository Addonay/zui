//! Offscreen schedule renderer (port of `vello_gpu/src/render/wgpu/mod.rs`
//! `render_scene` plus `schedule/execute.rs`) (Apache-2.0 OR MIT).
//!
//! `Renderer` owns the long-lived GPU resources for one target size: shader
//! modules, layout/pipeline sets, per-target `Config` uniforms, the alpha
//! coverage texture (grown on demand), and placeholder views. `render`
//! schedules a `vellz.gpu.Scene` into a dependency-ordered plan of draw,
//! blend, filter, and clear operations, allocates the intermediate texture
//! pages the schedule requires, encodes every operation into one command
//! buffer, and submits.
//!
//! Everything unsupported is a typed error; there is no CPU fallback.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const device = @import("device.zig");
const wgpu_backend = @import("wgpu.zig");

const blend_mod = @import("../blend.zig");
const draw_mod = @import("../draw.zig");
const filter_mod = @import("../filter.zig");
const paint = @import("../paint.zig");
const schedule_mod = @import("../schedule/mod.zig");
const scene_mod = @import("../scene.zig");
const target = @import("../target.zig");
const util = @import("../util.zig");

const geometry = @import("../../common/geometry.zig");
const render_common = @import("../render/common.zig");
const peniko = @import("../../peniko/root.zig");

pub const Error = wgpu_backend.Error || error{
    /// The scene uses a feature this renderer does not implement.
    Unsupported,
    /// The target is larger than the device's resource texture size.
    UnsupportedCapability,
    /// An image paint references a texture id that was not bound.
    MissingTextureBinding,
    /// An image paint samples the render target.
    TextureFeedbackLoop,
    /// The schedule needs more intermediate textures than the limit allows.
    LimitReached,
};

/// How the root target is initialized before the strip passes.
pub const TargetInit = union(enum) {
    /// Clear the full viewport to a straight-alpha sRGB color.
    clear: peniko.color.Color,
    /// Load the existing target contents.
    src_over,
};

/// One external texture supplied at render time.
pub const ExternalTexture = struct {
    /// Texture view bound for the image paint.
    view: c.WGPUTextureView,
    /// Texture containing `view` (checked against the render target to reject
    /// a feedback loop).
    texture: c.WGPUTexture,
};

/// Image textures supplied through the render-time bindings.
pub const TextureBindings = struct {
    /// The bound textures.
    entries: []const Entry = &.{},

    /// One `(handle, texture)` binding.
    pub const Entry = struct {
        /// The opaque handle referenced by an image paint.
        id: u64,
        /// The bound texture.
        texture: ExternalTexture,
    };

    /// Look up a texture by handle.
    pub fn get(self: TextureBindings, id: u64) ?ExternalTexture {
        for (self.entries) |entry| {
            if (entry.id == id) return entry.texture;
        }
        return null;
    }
};

/// Pre-multiplied `wgpu::Color` for a load-op clear (upstream `clear_color`).
fn clearColor(color: peniko.color.Color) c.WGPUColor {
    const premul = color.premultiply().components;
    return .{
        .r = @floatCast(premul[0]),
        .g = @floatCast(premul[1]),
        .b = @floatCast(premul[2]),
        .a = @floatCast(premul[3]),
    };
}

/// A texture page owned by one render call.
const Page = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,

    fn deinit(self: *Page) void {
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
        self.* = undefined;
    }
};

/// Create an `Rgba8Unorm` intermediate page with a full view.
fn createPage(dev: *device.Device, dim: u32, label: []const u8) Error!Page {
    const texture = try wgpu_backend.createTexture2d(
        dev,
        dim,
        dim,
        c.WGPUTextureFormat_RGBA8Unorm,
        c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_RenderAttachment,
        label,
    );
    errdefer c.wgpuTextureRelease(texture);
    const view = try wgpu_backend.createFullView(
        texture,
        c.WGPUTextureFormat_RGBA8Unorm,
        label,
    );
    return .{ .texture = texture, .view = view };
}

/// Per-render resources that are released after the command buffer is
/// submitted.
const Frame = struct {
    allocator: std.mem.Allocator,
    pages: [2]std.ArrayList(Page),
    scratch: ?Page = null,
    releases: std.ArrayList(Release),

    const Release = union(enum) {
        texture: c.WGPUTexture,
        view: c.WGPUTextureView,
        bind_group: c.WGPUBindGroup,
    };

    fn init(allocator: std.mem.Allocator) Frame {
        return .{
            .allocator = allocator,
            .pages = .{ .empty, .empty },
            .releases = .empty,
        };
    }

    fn deinit(self: *Frame) void {
        for (self.releases.items) |release| {
            switch (release) {
                .texture => |texture| c.wgpuTextureRelease(texture),
                .view => |view| c.wgpuTextureViewRelease(view),
                .bind_group => |bind_group| c.wgpuBindGroupRelease(bind_group),
            }
        }
        for (&self.pages) |*pages| {
            for (pages.items) |*page| page.deinit();
            pages.deinit(self.allocator);
        }
        if (self.scratch) |*page| page.deinit();
        self.releases.deinit(self.allocator);
        self.* = undefined;
    }

    fn track(self: *Frame, release: Release) std.mem.Allocator.Error!void {
        try self.releases.append(self.allocator, release);
    }

    fn pageView(self: *const Frame, id: target.LayerTextureId) c.WGPUTextureView {
        return self.pages[id.texture_parity.getParity()].items[id.page_index].view;
    }
};

/// The offscreen schedule renderer.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    /// Borrowed device; must outlive the renderer.
    dev: *device.Device,
    /// Caller target format for the alpha strip pipelines.
    target_format: c.WGPUTextureFormat,
    /// Width (and `Config` width-bits base) of the alphas/encoded-paints
    /// textures; a power of two capped at 4096 like upstream.
    resource_dim: u32,
    target_width: u32,
    target_height: u32,

    shaders: wgpu_backend.ShaderModules,
    layouts: wgpu_backend.Layouts,
    pipelines: wgpu_backend.Pipelines,
    sampler: c.WGPUSampler,

    /// `Config` for the caller target.
    config_buffer: c.WGPUBuffer,
    /// `Config` for intermediate layer pages.
    layer_config_buffer: c.WGPUBuffer,
    /// Rect-clear pipeline for intermediate pages (`Rgba8Unorm`).
    layer_clear_pipeline: wgpu_backend.ClearPipeline,

    alphas_texture: c.WGPUTexture,
    alphas_view: c.WGPUTextureView,
    alphas_height: u32,
    /// 1x1 `Rgba8Unorm` child-layer placeholder.
    placeholder_texture: c.WGPUTexture,
    placeholder_view: c.WGPUTextureView,
    /// 1x1 `Rgba32Uint` encoded-paints texture (solid paints never read it).
    encoded_paints_texture: c.WGPUTexture,
    encoded_paints_view: c.WGPUTextureView,
    encoded_paints_bind_group: c.WGPUBindGroup,
    /// Placeholder gradient bind group for unindexed paints.
    gradient_bind_group: c.WGPUBindGroup,

    depth_cleared_this_frame: bool,

    /// Create the renderer for a `width` x `height` target.
    pub fn init(
        allocator: std.mem.Allocator,
        dev: *device.Device,
        target_format: c.WGPUTextureFormat,
        width: u32,
        height: u32,
    ) Error!Renderer {
        if (dev.isLost()) return error.DeviceLost;
        const limits = try dev.getLimits();
        // Upstream caps resource textures at 4096 in addition to the adapter
        // limit; the shader requires a power-of-two width for its mask/shift.
        const capped = @min(limits.resourceTextureDimension2d(), 4096);
        const resource_dim = std.math.floorPowerOfTwo(u32, capped);
        if (resource_dim < width or resource_dim < height) {
            std.debug.print(
                "vellz-gpu: target {d}x{d} exceeds the resource texture dimension {d}\n",
                .{ width, height, resource_dim },
            );
            return error.UnsupportedCapability;
        }

        var self: Renderer = .{
            .allocator = allocator,
            .dev = dev,
            .target_format = target_format,
            .resource_dim = resource_dim,
            .target_width = width,
            .target_height = height,
            .shaders = undefined,
            .layouts = undefined,
            .pipelines = undefined,
            .sampler = null,
            .config_buffer = null,
            .layer_config_buffer = null,
            .layer_clear_pipeline = undefined,
            .alphas_texture = null,
            .alphas_view = null,
            .alphas_height = 0,
            .placeholder_texture = null,
            .placeholder_view = null,
            .encoded_paints_texture = null,
            .encoded_paints_view = null,
            .encoded_paints_bind_group = null,
            .gradient_bind_group = null,
            .depth_cleared_this_frame = false,
        };

        self.shaders = try wgpu_backend.ShaderModules.create(dev);
        errdefer self.shaders.deinit();
        self.layouts = try wgpu_backend.Layouts.create(dev);
        errdefer self.layouts.deinit();
        self.pipelines = try wgpu_backend.Pipelines.create(dev, &self.layouts, &self.shaders, target_format);
        errdefer self.pipelines.deinit();
        self.sampler = try wgpu_backend.createFilterLinearSampler(dev);
        errdefer c.wgpuSamplerRelease(self.sampler);

        self.config_buffer = try wgpu_backend.createConfigBuffer(
            dev,
            width,
            height,
            resource_dim,
            "vellz-config",
        );
        errdefer c.wgpuBufferRelease(self.config_buffer);
        self.layer_config_buffer = try wgpu_backend.createConfigBuffer(
            dev,
            resource_dim,
            resource_dim,
            resource_dim,
            "vellz-layer-config",
        );
        errdefer c.wgpuBufferRelease(self.layer_config_buffer);

        self.layer_clear_pipeline = try wgpu_backend.ClearPipeline.create(
            dev,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vellz-layer-clear",
        );
        errdefer self.layer_clear_pipeline.deinit();

        // Initial (empty) alpha texture; grown by `prepareAlphas`.
        self.alphas_texture = try wgpu_backend.createRgba32UintTexture(dev, resource_dim, 1, "vellz-alphas");
        errdefer c.wgpuTextureRelease(self.alphas_texture);
        self.alphas_view = try wgpu_backend.createFullView(
            self.alphas_texture,
            c.WGPUTextureFormat_RGBA32Uint,
            "vellz-alphas-view",
        );
        errdefer c.wgpuTextureViewRelease(self.alphas_view);
        self.alphas_height = 1;

        self.placeholder_texture = try wgpu_backend.createTexture2d(
            dev,
            1,
            1,
            c.WGPUTextureFormat_RGBA8Unorm,
            c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            "vellz-placeholder",
        );
        errdefer c.wgpuTextureRelease(self.placeholder_texture);
        self.placeholder_view = try wgpu_backend.createFullView(
            self.placeholder_texture,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vellz-placeholder-view",
        );
        errdefer c.wgpuTextureViewRelease(self.placeholder_view);

        self.encoded_paints_texture = try wgpu_backend.createRgba32UintTexture(
            dev,
            1,
            1,
            "vellz-encoded-paints",
        );
        errdefer c.wgpuTextureRelease(self.encoded_paints_texture);
        self.encoded_paints_view = try wgpu_backend.createFullView(
            self.encoded_paints_texture,
            c.WGPUTextureFormat_RGBA32Uint,
            "vellz-encoded-paints-view",
        );
        errdefer c.wgpuTextureViewRelease(self.encoded_paints_view);
        self.encoded_paints_bind_group = try wgpu_backend.createEncodedPaintsBindGroup(
            dev,
            self.layouts.encoded_paints,
            self.encoded_paints_view,
        );
        errdefer c.wgpuBindGroupRelease(self.encoded_paints_bind_group);

        self.gradient_bind_group = try wgpu_backend.createGradientBindGroup(
            dev,
            self.layouts.gradient,
            self.placeholder_view,
        );
        errdefer c.wgpuBindGroupRelease(self.gradient_bind_group);

        return self;
    }

    /// Release every owned handle.
    pub fn deinit(self: *Renderer) void {
        c.wgpuBindGroupRelease(self.gradient_bind_group);
        c.wgpuBindGroupRelease(self.encoded_paints_bind_group);
        c.wgpuTextureViewRelease(self.encoded_paints_view);
        c.wgpuTextureRelease(self.encoded_paints_texture);
        c.wgpuTextureViewRelease(self.placeholder_view);
        c.wgpuTextureRelease(self.placeholder_texture);
        c.wgpuTextureViewRelease(self.alphas_view);
        c.wgpuTextureRelease(self.alphas_texture);
        self.layer_clear_pipeline.deinit();
        c.wgpuBufferRelease(self.layer_config_buffer);
        c.wgpuBufferRelease(self.config_buffer);
        c.wgpuSamplerRelease(self.sampler);
        self.pipelines.deinit();
        self.layouts.deinit();
        self.shaders.deinit();
        self.* = undefined;
    }

    /// Render `scene` into `target_view`, optionally using `depth_view`
    /// (`Depth24Plus`, same extents, render attachment), with optional image
    /// texture bindings.
    pub fn render(
        self: *Renderer,
        scene: *const scene_mod.Scene,
        target_view: c.WGPUTextureView,
        depth_view: ?c.WGPUTextureView,
        target_init: TargetInit,
    ) Error!void {
        return self.renderWithBindings(scene, target_view, depth_view, target_init, .{});
    }

    /// Render `scene` with explicit external texture bindings.
    pub fn renderWithBindings(
        self: *Renderer,
        scene: *const scene_mod.Scene,
        target_view: c.WGPUTextureView,
        depth_view: ?c.WGPUTextureView,
        target_init: TargetInit,
        bindings: TextureBindings,
    ) Error!void {
        _ = bindings;
        if (self.dev.isLost()) return error.DeviceLost;
        if (self.target_width == 0 or self.target_height == 0) return error.TextureTooLarge;
        self.depth_cleared_this_frame = false;

        if (scene.encoded_paints.items.len != 0) {
            // Encoded paints (gradients/images/blurred rects) need the
            // gradient and encoded-paints textures; not wired yet.
            return error.Unsupported;
        }

        var plan = try schedule_mod.schedule(
            self.allocator,
            scene,
            .user_surface,
            depth_view != null,
            paint.PaintResolver.solid_only,
            geometry.SizeU16.new(@intCast(self.resource_dim)),
            null,
        );
        defer plan.deinit();

        var frame = Frame.init(self.allocator);
        defer frame.deinit();
        try self.createPages(&frame, plan.allocations);

        // Filter data texture (one per frame).
        var filter_data: ?FilterDataTexture = null;
        defer if (filter_data) |*data| data.deinit();
        if (!plan.filter_context.isEmpty()) {
            filter_data = try FilterDataTexture.create(self.dev, &self.layouts, self.resource_dim, &plan.filter_context);
        }

        // Filter group 2 always samples the shared scratch texture (upstream
        // `update_scratch_bind_groups`); the pre-filter contents of the
        // original region are copied there by the first filter step. Binding
        // the filtered region itself would create a read/write usage conflict.
        const filter_original_view = if (frame.scratch) |scratch| scratch.view else self.placeholder_view;
        const filter_original_bind_group = try wgpu_backend.createFilterOriginalBindGroup(
            self.dev,
            self.layouts.filter_original,
            filter_original_view,
        );
        try frame.track(.{ .bind_group = filter_original_bind_group });

        // Upload alpha coverage, growing the texture if this scene needs more.
        try self.prepareAlphas(scene.strip_storage.alphas.items);

        var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
        encoder_desc.label = wgpu.stringView("vellz-gpu-render-encoder");
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.dev.handle, &encoder_desc) orelse
            return error.CommandEncodingFailed;
        defer c.wgpuCommandEncoderRelease(encoder);

        var root_load_op: c.WGPULoadOp = c.WGPULoadOp_Load;
        var root_clear_value = c.WGPUColor{ .r = 0, .g = 0, .b = 0, .a = 0 };
        switch (target_init) {
            .src_over => {},
            .clear => |color| {
                root_load_op = c.WGPULoadOp_Clear;
                root_clear_value = clearColor(color);
            },
        }
        var root_clear_consumed = false;

        var alpha_strips: std.ArrayList(render_common.GpuStrip) = .empty;
        defer alpha_strips.deinit(self.allocator);

        // Root opaque strips are drawn first, front-to-back, with depth.
        if (plan.hasOpaqueStrips() and depth_view != null) {
            const no_child_group = try self.childBindGroup(&frame, null);
            try wgpu_backend.stripPass(self.dev, encoder, .{
                .view = target_view,
                .depth_view = depth_view,
                .clear_depth = !self.depth_cleared_this_frame,
                .load_op = root_load_op,
                .clear_value = root_clear_value,
                .opaque_strips = plan.draw_buffers.opaque_draw.stripItems(),
                .alpha_strips = &.{},
                .is_root = true,
                .strip_bind_group = no_child_group,
                .external_bind_group = try self.placeholderExternalBindGroup(&frame),
                .encoded_paints_bind_group = self.encoded_paints_bind_group,
                .gradient_bind_group = self.gradient_bind_group,
                .pipelines = &self.pipelines,
            });
            root_clear_consumed = true;
            if (depth_view != null) self.depth_cleared_this_frame = true;
        }

        for (plan.ops.items) |op| {
            switch (op) {
                .draw => |draw_op| {
                    const is_root = std.meta.activeTag(draw_op.target) == .root;
                    const view = switch (draw_op.target) {
                        .root => target_view,
                        .layer => |id| frame.pageView(id),
                    };
                    const config_buffer = if (is_root) self.config_buffer else self.layer_config_buffer;
                    const child_view: c.WGPUTextureView = if (draw_op.child) |id|
                        frame.pageView(id)
                    else
                        self.placeholder_view;

                    alpha_strips.clearRetainingCapacity();
                    const ranged = util.RangedSlice(render_common.GpuStrip).init(
                        plan.draw_buffers.strips.items,
                        &draw_op.draw.strip_ranges,
                    );
                    try ranged.appendTo(self.allocator, &alpha_strips);

                    const strip_bind_group = try wgpu_backend.createStripBindGroup(
                        self.dev,
                        self.layouts.strip,
                        self.alphas_view,
                        config_buffer,
                        child_view,
                    );
                    try frame.track(.{ .bind_group = strip_bind_group });

                    const load_op: c.WGPULoadOp = if (is_root and !root_clear_consumed)
                        root_load_op
                    else
                        c.WGPULoadOp_Load;
                    const clear_value = if (is_root and !root_clear_consumed)
                        root_clear_value
                    else
                        c.WGPUColor{ .r = 0, .g = 0, .b = 0, .a = 0 };
                    if (is_root) root_clear_consumed = true;

                    const use_depth = is_root and depth_view != null;
                    try wgpu_backend.stripPass(self.dev, encoder, .{
                        .view = view,
                        .depth_view = if (use_depth) depth_view else null,
                        .clear_depth = use_depth and !self.depth_cleared_this_frame,
                        .load_op = load_op,
                        .clear_value = clear_value,
                        .opaque_strips = &.{},
                        .alpha_strips = alpha_strips.items,
                        .is_root = is_root,
                        .strip_bind_group = strip_bind_group,
                        .external_bind_group = try self.placeholderExternalBindGroup(&frame),
                        .encoded_paints_bind_group = self.encoded_paints_bind_group,
                        .gradient_bind_group = self.gradient_bind_group,
                        .pipelines = &self.pipelines,
                    });
                    if (use_depth) self.depth_cleared_this_frame = true;
                },
                .blend => |blend_op| {
                    try self.executeBlend(encoder, &frame, &plan, &blend_op);
                },
                .filter => |filter_op| {
                    if (filter_data == null) return error.Unsupported;
                    try self.executeFilter(
                        encoder,
                        &frame,
                        &filter_op,
                        &filter_data.?,
                        filter_original_bind_group,
                    );
                },
                .clear => |clear_op| {
                    try self.executeClear(encoder, &frame, clear_op);
                },
            }
        }

        if (!root_clear_consumed and root_load_op == c.WGPULoadOp_Clear) {
            try wgpu_backend.clearFullTarget(self.dev, encoder, target_view, root_clear_value);
        }

        var command_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
        command_desc.label = wgpu.stringView("vellz-gpu-render-commands");
        const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_desc) orelse {
            return error.CommandEncodingFailed;
        };
        defer c.wgpuCommandBufferRelease(command_buffer);
        c.wgpuQueueSubmit(self.dev.queue, 1, &command_buffer);

        // Surface validation errors recorded during encoding.
        try self.dev.check();
    }

    /// Create the intermediate texture pages and scratch texture a schedule
    /// requires.
    fn createPages(self: *Renderer, frame: *Frame, allocations: schedule_mod.IntermediateTextureAllocations) Error!void {
        const dim = self.resource_dim;
        for (0..2) |parity| {
            const count = allocations.layer_pages[parity];
            for (0..count) |_| {
                const page = try createPage(self.dev, dim, "vellz-layer-page");
                frame.pages[parity].append(self.allocator, page) catch |err| {
                    var owned = page;
                    owned.deinit();
                    return err;
                };
            }
        }
        if (allocations.scratch) {
            frame.scratch = try createPage(self.dev, dim, "vellz-scratch");
        }
    }

    /// Create (or fetch) the strip bind group for a child layer view.
    fn childBindGroup(self: *Renderer, frame: *Frame, child: ?c.WGPUTextureView) Error!c.WGPUBindGroup {
        const group = try wgpu_backend.createStripBindGroup(
            self.dev,
            self.layouts.strip,
            self.alphas_view,
            self.config_buffer,
            child orelse self.placeholder_view,
        );
        try frame.track(.{ .bind_group = group });
        return group;
    }

    /// A bind group for group 1 with all four slots bound to the placeholder.
    fn placeholderExternalBindGroup(self: *Renderer, frame: *Frame) Error!c.WGPUBindGroup {
        const group = try wgpu_backend.createExternalTextureBindGroup(
            self.dev,
            self.layouts.external_texture,
            .{ self.placeholder_view, self.placeholder_view, self.placeholder_view, self.placeholder_view },
        );
        try frame.track(.{ .bind_group = group });
        return group;
    }

    /// Execute a scheduled blend operation (blend to scratch, then copy back).
    fn executeBlend(
        self: *Renderer,
        encoder: c.WGPUCommandEncoder,
        frame: *Frame,
        plan: *const schedule_mod.Schedule,
        blend_op: *const blend_mod.BlendOp,
    ) Error!void {
        const scratch = frame.scratch orelse return error.Unsupported;
        const bindings = target.BlendPassBindings.new(
            blend_op.parent_region.texture.target,
            blend_op.child_region.texture.target,
        );
        const parent_view = frame.pageView(bindings.blendTarget());
        const even_view = frame.pageView(bindings.layerId(.even));
        const odd_view = frame.pageView(bindings.layerId(.odd));

        const blend_bind_group = try wgpu_backend.createBlendBindGroup(
            self.dev,
            self.layouts.blend,
            even_view,
            odd_view,
            self.alphas_view,
        );
        try frame.track(.{ .bind_group = blend_bind_group });

        var instances: std.ArrayList(render_common.GpuBlendInstance) = .empty;
        defer instances.deinit(self.allocator);
        const texture_size = geometry.SizeU16.new(@intCast(self.resource_dim));
        if (blend_op.clip_strips) |range| {
            for (plan.blend_strips.items[range.start..range.end]) |strip| {
                try instances.append(self.allocator, render_common.GpuBlendInstance.new(blend_op, strip, texture_size));
            }
        } else {
            try instances.append(self.allocator, render_common.GpuBlendInstance.new(blend_op, null, texture_size));
        }

        try wgpu_backend.encodeBlendPass(
            self.dev,
            encoder,
            self.pipelines.blend,
            blend_bind_group,
            instances.items,
            scratch.view,
            "vellz-blend-to-scratch",
        );

        // Copy the blended region back into the parent layer.
        var copy_instances: std.ArrayList(render_common.GpuCopyInstance) = .empty;
        defer copy_instances.deinit(self.allocator);
        try copy_instances.ensureTotalCapacity(self.allocator, instances.items.len);
        for (instances.items) |instance| copy_instances.appendAssumeCapacity(instance.copyFromScratch());

        const copy_bind_group = try wgpu_backend.createCopySourceBindGroup(
            self.dev,
            self.layouts.copy,
            scratch.view,
        );
        try frame.track(.{ .bind_group = copy_bind_group });
        try wgpu_backend.encodeCopyPass(
            self.dev,
            encoder,
            self.pipelines.copy,
            copy_instances.items,
            copy_bind_group,
            parent_view,
            "vellz-blend-copy-back",
        );
    }

    /// Execute a scheduled filter operation.
    fn executeFilter(
        self: *Renderer,
        encoder: c.WGPUCommandEncoder,
        frame: *Frame,
        filter_op: *const filter_mod.FilterOp,
        filter_data: *const FilterDataTexture,
        original_bind_group: c.WGPUBindGroup,
    ) Error!void {
        const scratch = frame.scratch;
        const bindings = target.FilterPassBindings.new(
            filter_op.textures.original.target,
            filter_op.textures.temporary.target,
        );
        const texture_size = geometry.SizeU16.new(@intCast(self.resource_dim));

        var pass_plan = filter_mod.FilterPassPlan{};
        defer pass_plan.deinit(self.allocator);
        try pass_plan.init(self.allocator, &.{filter_op.*}, texture_size);

        if (pass_plan.copyPass()) |instances| {
            const scratch_page = scratch orelse return error.Unsupported;
            const original_view = frame.pageView(filter_op.textures.original.target);
            const copy_bind_group = try wgpu_backend.createCopySourceBindGroup(
                self.dev,
                self.layouts.copy,
                original_view,
            );
            try frame.track(.{ .bind_group = copy_bind_group });
            try wgpu_backend.encodeCopyPass(
                self.dev,
                encoder,
                self.pipelines.copy,
                instances,
                copy_bind_group,
                scratch_page.view,
                "vellz-filter-original-copy",
            );
        }

        for (0..pass_plan.stepCount()) |step| {
            const input_id = bindings.input(step);
            const output_id = bindings.output(step);
            const input_bind_group = try wgpu_backend.createFilterInputBindGroup(
                self.dev,
                self.layouts.filter_input,
                self.sampler,
                frame.pageView(input_id),
            );
            try frame.track(.{ .bind_group = input_bind_group });
            try wgpu_backend.encodeFilterPass(
                self.dev,
                encoder,
                self.pipelines.filter,
                filter_data.bind_group,
                input_bind_group,
                original_bind_group,
                pass_plan.stepItems(step),
                frame.pageView(output_id),
                "vellz-filter-pass",
            );
        }
    }

    /// Clear one scheduled region back to transparent.
    fn executeClear(
        self: *Renderer,
        encoder: c.WGPUCommandEncoder,
        frame: *const Frame,
        clear_op: schedule_mod.ClearOp,
    ) Error!void {
        const rect = clear_op.rect;
        if (rect.isEmpty()) return;
        const instance = render_common.GpuClearInstance.new(
            .{ rect.x0, rect.y0 },
            .{ rect.width(), rect.height() },
            .{ @intCast(self.resource_dim), @intCast(self.resource_dim) },
            0,
        );
        try wgpu_backend.clearPass(
            self.dev,
            encoder,
            frame.pageView(clear_op.target),
            &self.layer_clear_pipeline,
            &.{instance},
        );
    }

    /// Grow and upload the alpha texture for `alphas` (row-major 16-byte
    /// blocks, matching `StripStorage.alphas`).
    fn prepareAlphas(self: *Renderer, alphas: []const u8) Error!void {
        const width = self.resource_dim;
        const bytes_per_row: usize = @as(usize, width) * 16;
        if (alphas.len == 0) return;

        const required_height: u32 = @intCast(
            (alphas.len + bytes_per_row - 1) / bytes_per_row,
        );
        if (required_height > width) {
            std.debug.print(
                "vellz-gpu: alpha data needs height {d} above the resource dimension {d}\n",
                .{ required_height, width },
            );
            return error.UnsupportedCapability;
        }

        if (required_height > self.alphas_height) {
            c.wgpuTextureViewRelease(self.alphas_view);
            c.wgpuTextureRelease(self.alphas_texture);
            self.alphas_texture = try wgpu_backend.createRgba32UintTexture(
                self.dev,
                width,
                required_height,
                "vellz-alphas",
            );
            self.alphas_view = try wgpu_backend.createFullView(
                self.alphas_texture,
                c.WGPUTextureFormat_RGBA32Uint,
                "vellz-alphas-view",
            );
            self.alphas_height = required_height;
        }

        const total = bytes_per_row * self.alphas_height;
        const padded = self.allocator.alloc(u8, total) catch return error.OutOfMemory;
        defer self.allocator.free(padded);
        @memset(padded, 0);
        @memcpy(padded[0..alphas.len], alphas);
        try wgpu_backend.writeRgba32Uint(
            self.dev,
            self.alphas_texture,
            padded,
            width,
            self.alphas_height,
        );
    }
};

/// The filter data texture and its bind group for one frame.
const FilterDataTexture = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bind_group: c.WGPUBindGroup,

    fn create(
        dev: *device.Device,
        layouts: *const wgpu_backend.Layouts,
        resource_dim: u32,
        context: *const filter_mod.FilterContext,
    ) Error!FilterDataTexture {
        const height = context.requiredFilterDataHeight(resource_dim) orelse 1;
        if (height > resource_dim) return error.UnsupportedCapability;
        const texture = try wgpu_backend.createRgba32UintTexture(dev, resource_dim, height, "vellz-filter-data");
        errdefer c.wgpuTextureRelease(texture);
        const view = try wgpu_backend.createFullView(
            texture,
            c.WGPUTextureFormat_RGBA32Uint,
            "vellz-filter-data-view",
        );
        errdefer c.wgpuTextureViewRelease(view);

        const bytes_per_texel: usize = 16;
        const total = @as(usize, resource_dim) * height * bytes_per_texel;
        const padded = dev.allocator.alloc(u8, total) catch return error.OutOfMemory;
        defer dev.allocator.free(padded);
        @memset(padded, 0);
        context.serializeToBuffer(padded);
        try wgpu_backend.writeRgba32Uint(dev, texture, padded, resource_dim, height);

        const bind_group = try wgpu_backend.createFilterDataBindGroup(dev, layouts.filter_data, view);
        errdefer c.wgpuBindGroupRelease(bind_group);
        return .{ .texture = texture, .view = view, .bind_group = bind_group };
    }

    fn deinit(self: *FilterDataTexture) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "clear color premultiplies" {
    const color = peniko.color.Color.fromRgba8(255, 0, 0, 128);
    const cleared = clearColor(color);
    // 128/255 alpha premultiplies red to about 0.5.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cleared.r, 0.01);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.b);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.g);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5019608), cleared.a, 1e-6);
}

test "target init union shapes" {
    const init: TargetInit = .{ .clear = peniko.color.Color.TRANSPARENT };
    switch (init) {
        .clear => |color| try std.testing.expectEqual(peniko.color.Color.TRANSPARENT, color),
        .src_over => return error.TestUnexpectedResult,
    }
    const src_over: TargetInit = .src_over;
    switch (src_over) {
        .clear => return error.TestUnexpectedResult,
        .src_over => {},
    }
}

test "texture bindings lookup" {
    const bindings = TextureBindings{
        .entries = &.{
            .{ .id = 7, .texture = .{ .view = null, .texture = null } },
        },
    };
    try std.testing.expect(bindings.get(7) != null);
    try std.testing.expect(bindings.get(8) == null);
}
