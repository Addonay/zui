//! Offscreen root-strip renderer (port of the root path of
//! `vello_gpu/src/render/wgpu/mod.rs` `render_scene`) (Apache-2.0 OR MIT).
//!
//! `Renderer` owns the long-lived GPU resources for one target size: shader
//! modules, layout/pipeline sets, the `Config` uniform, the alpha coverage
//! texture (grown on demand), 1x1 placeholders for the encoded-paints and
//! gradient bind groups, and an empty external-texture bind group. `render`
//! encodes the root clear plus the opaque/alpha strip passes for a
//! `vellz.gpu.Scene`, then submits.
//!
//! Scope: root solid fills/paths only. Layers and indexed paints are rejected
//! with `error.Unsupported` (never approximated); the schedule milestone adds
//! them.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const device = @import("device.zig");
const wgpu_backend = @import("wgpu.zig");

const draw = @import("../draw.zig");
const paint = @import("../paint.zig");
const scene_mod = @import("../scene.zig");
const target = @import("../target.zig");
const util = @import("../util.zig");

const geometry = @import("../../common/geometry.zig");
const render_common = @import("../render/common.zig");
const peniko = @import("../../peniko/root.zig");

pub const Error = wgpu_backend.Error || error{
    /// The scene uses a feature this milestone does not implement.
    Unsupported,
    /// The target is larger than the device's resource texture size.
    UnsupportedCapability,
};

/// How the root target is initialized before the strip passes.
pub const TargetInit = union(enum) {
    /// Clear the full viewport to a straight-alpha sRGB color.
    clear: peniko.color.Color,
    /// Load the existing target contents.
    src_over,
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

/// The offscreen root renderer.
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

    config_buffer: c.WGPUBuffer,
    alphas_texture: c.WGPUTexture,
    alphas_view: c.WGPUTextureView,
    alphas_height: u32,

    /// 1x1 `Rgba8Unorm` used for unbound child-layer and gradient slots.
    placeholder_texture: c.WGPUTexture,
    placeholder_view: c.WGPUTextureView,
    /// 1x1 `Rgba32Uint` encoded-paints texture (solid paints never read it).
    encoded_paints_texture: c.WGPUTexture,
    encoded_paints_view: c.WGPUTextureView,
    encoded_paints_bind_group: c.WGPUBindGroup,
    gradient_bind_group: c.WGPUBindGroup,
    empty_external_bind_group: c.WGPUBindGroup,

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
            .alphas_texture = null,
            .alphas_view = null,
            .alphas_height = 0,
            .placeholder_texture = null,
            .placeholder_view = null,
            .encoded_paints_texture = null,
            .encoded_paints_view = null,
            .encoded_paints_bind_group = null,
            .gradient_bind_group = null,
            .empty_external_bind_group = null,
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

        self.empty_external_bind_group = try wgpu_backend.createExternalTextureBindGroup(
            dev,
            self.layouts.external_texture,
            .{ self.placeholder_view, self.placeholder_view, self.placeholder_view, self.placeholder_view },
        );
        errdefer c.wgpuBindGroupRelease(self.empty_external_bind_group);

        return self;
    }

    /// Release every owned handle.
    pub fn deinit(self: *Renderer) void {
        c.wgpuBindGroupRelease(self.empty_external_bind_group);
        c.wgpuBindGroupRelease(self.gradient_bind_group);
        c.wgpuBindGroupRelease(self.encoded_paints_bind_group);
        c.wgpuTextureViewRelease(self.placeholder_view);
        c.wgpuTextureRelease(self.placeholder_texture);
        c.wgpuTextureViewRelease(self.encoded_paints_view);
        c.wgpuTextureRelease(self.encoded_paints_texture);
        c.wgpuTextureViewRelease(self.alphas_view);
        c.wgpuTextureRelease(self.alphas_texture);
        c.wgpuBufferRelease(self.config_buffer);
        c.wgpuSamplerRelease(self.sampler);
        self.pipelines.deinit();
        self.layouts.deinit();
        self.shaders.deinit();
        self.* = undefined;
    }

    /// Render `scene` into `target_view`, optionally using `depth_view`
    /// (`Depth24Plus`, same extents, render attachment).
    pub fn render(
        self: *Renderer,
        scene: *const scene_mod.Scene,
        target_view: c.WGPUTextureView,
        depth_view: ?c.WGPUTextureView,
        target_init: TargetInit,
    ) Error!void {
        if (self.dev.isLost()) return error.DeviceLost;
        if (scene.recorder.layers.items.len != 0) return error.Unsupported;
        if (self.target_width == 0 or self.target_height == 0) return error.TextureTooLarge;
        self.depth_cleared_this_frame = false;

        // Encode the root draws into opaque/alpha strip buffers. With no
        // layers, every recorded draw belongs to the single root draw pass.
        var buffers = draw.DrawBuffers{};
        defer buffers.deinit(self.allocator);
        var root_draw = draw.Draw{};
        defer root_draw.deinit(self.allocator);
        const target_bbox = geometry.RectU16.new(
            0,
            0,
            scene.recorder.scene_size.width(),
            scene.recorder.scene_size.height(),
        );
        var state = draw.DrawState(target.RootTarget).init(
            .user_surface,
            target_bbox,
            depth_view != null,
        );
        var builder = draw.DrawBuilder(target.RootTarget).init(&root_draw, &buffers, &state);
        for (scene.recorder.draws.items) |*recorded| {
            try builder.pushDraw(
                self.allocator,
                recorded,
                &scene.strip_storage,
                paint.PaintResolver.solid_only,
            );
        }
        buffers.opaque_draw.reverse();

        // Upload alpha coverage, growing the texture if this scene needs more.
        try self.prepareAlphas(scene.strip_storage.alphas.items);

        const strip_bind_group = try wgpu_backend.createStripBindGroup(
            self.dev,
            self.layouts.strip,
            self.alphas_view,
            self.config_buffer,
            self.placeholder_view,
        );
        defer c.wgpuBindGroupRelease(strip_bind_group);

        var alpha_strips: std.ArrayList(render_common.GpuStrip) = .empty;
        defer alpha_strips.deinit(self.allocator);
        const ranged = util.RangedSlice(render_common.GpuStrip).init(
            buffers.strips.items,
            &root_draw.strip_ranges,
        );
        try ranged.appendTo(self.allocator, &alpha_strips);

        var load_op: c.WGPULoadOp = c.WGPULoadOp_Load;
        var clear_value = c.WGPUColor{ .r = 0, .g = 0, .b = 0, .a = 0 };
        switch (target_init) {
            .src_over => {},
            .clear => |color| {
                load_op = c.WGPULoadOp_Clear;
                clear_value = clearColor(color);
            },
        }

        var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
        encoder_desc.label = wgpu.stringView("vellz-gpu-render-encoder");
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.dev.handle, &encoder_desc) orelse
            return error.CommandEncodingFailed;
        defer c.wgpuCommandEncoderRelease(encoder);

        var pending_clear = load_op == c.WGPULoadOp_Clear;
        if (buffers.opaque_draw.strips.items.len > 0 or alpha_strips.items.len > 0) {
            try wgpu_backend.stripPass(self.dev, encoder, .{
                .view = target_view,
                .depth_view = depth_view,
                .clear_depth = !self.depth_cleared_this_frame,
                .load_op = load_op,
                .clear_value = clear_value,
                .opaque_strips = buffers.opaque_draw.strips.items,
                .alpha_strips = alpha_strips.items,
                .is_root = true,
                .strip_bind_group = strip_bind_group,
                .external_bind_group = self.empty_external_bind_group,
                .encoded_paints_bind_group = self.encoded_paints_bind_group,
                .gradient_bind_group = self.gradient_bind_group,
                .pipelines = &self.pipelines,
            });
            if (depth_view != null) self.depth_cleared_this_frame = true;
            pending_clear = false;
        }

        if (pending_clear) {
            try wgpu_backend.clearFullTarget(self.dev, encoder, target_view, clear_value);
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
