//! Glue between native windows and the GPU renderer on Linux. One `GpuContext` (Vulkan
//! device, sprite atlas, pipelines) is shared by all windows of a connection, as in GPUI's
//! `WgpuContext`; each window owns a `GpuWindow` (its swapchain). Anything that fails here
//! makes the window use the CPU renderer instead.
//!
//! `ZUI_RENDERER=cpu` forces the CPU renderer. `ZUI_RENDERER=gpu` also accepts software
//! Vulkan devices, which the default rejects because the CPU renderer beats them.
const std = @import("std");
const platform_specs = @import("../platform.zig");
const gpu = @import("../gpu/root.zig");
const vulkan = @import("vulkan.zig");
const renderer = @import("gpu.zig");
const scene_mod = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");
const color = @import("../color.zig");

const log = std.log.scoped(.zui_renderer);

/// Enough for a frame of 200k quads; the Vulkan layer keeps this per in-flight frame.
/// Matches `renderer.Options.max_frame_upload_bytes`.
const transient_staging_bytes = 32 * 1024 * 1024;

pub const GpuContext = struct {
    allocator: std.mem.Allocator,
    vk: vulkan.Context,
    device: gpu.Device,
    atlas: renderer.GpuAtlas,
    /// The format every window of this context shares, set by the first swapchain.
    color_format: ?gpu.PixelFormat = null,
    /// Indexed by `premultiplied`: 0 for opaque windows (straight alpha), 1 for transparent ones.
    /// The second is created only when a transparent window exists, so opaque windows
    /// compile the same pipelines as before.
    renderers: [2]?renderer.GpuRenderer = .{ null, null },

    /// Null when the configuration or the machine calls for the CPU renderer.
    pub fn create(allocator: std.mem.Allocator, window_system: vulkan.WindowSystem) ?*GpuContext {
        const requested: []const u8 = if (std.c.getenv("ZUI_RENDERER")) |v| std.mem.span(v) else "auto";
        if (std.mem.eql(u8, requested, "cpu")) return null;
        const selection: vulkan.Selection = if (std.mem.eql(u8, requested, "gpu")) .any else .hardware;
        return create_with(allocator, window_system, selection) catch |err| {
            log.debug("using the CPU renderer: {s}", .{@errorName(err)});
            return null;
        };
    }

    fn create_with(allocator: std.mem.Allocator, window_system: vulkan.WindowSystem, selection: vulkan.Selection) !*GpuContext {
        const self = try allocator.create(GpuContext);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.color_format = null;
        self.renderers = .{ null, null };
        self.vk = try vulkan.Context.init(window_system, selection);
        errdefer self.vk.deinit();
        var backend = self.vk.device_options();
        backend.vulkan.transient_staging_buffer_size = transient_staging_bytes;
        self.device = try gpu.Device.init(allocator, .{
            .backend = backend,
            .defaults = .{ .color_format = .bgra8, .depth_format = .none, .sample_count = 1 },
        });
        errdefer self.device.deinit();
        self.atlas = renderer.GpuAtlas.init(allocator, &self.device);
        log.debug("using Vulkan on {s}", .{self.vk.device_label()});
        return self;
    }

    /// All windows must have released their `GpuWindow`s.
    pub fn destroy(self: *GpuContext) void {
        self.vk.wait_idle();
        for (&self.renderers) |*r| if (r.*) |*renderer_| renderer_.deinit();
        self.atlas.deinit();
        self.device.deinit();
        self.vk.deinit();
        self.allocator.destroy(self);
    }

    pub fn sprite_atlas(self: *GpuContext) atlas_mod.PlatformAtlas {
        return self.atlas.platform_atlas();
    }

    /// The renderer for windows of `format` with the given alpha, created on first use.
    fn renderer_for(self: *GpuContext, format: gpu.PixelFormat, premultiplied: bool) !*renderer.GpuRenderer {
        if (self.color_format) |f| {
            if (f != format) return error.MixedSwapchainFormats;
        } else self.color_format = format;
        const slot = &self.renderers[@intFromBool(premultiplied)];
        if (slot.* == null) {
            slot.* = try renderer.GpuRenderer.initWithOptions(self.allocator, &self.device, format, .{ .premultiplied_alpha = premultiplied });
        }
        return &slot.*.?;
    }
};

/// The GPU half of one window.
pub const GpuWindow = struct {
    ctx: *GpuContext,
    swapchain: vulkan.WindowSwapchain,

    /// The GPU this window renders with (GPUI `gpu_specs`). The driver fields stay empty: the
    /// driver properties are not read yet.
    pub fn gpu_specs(self: *const GpuWindow) platform_specs.GpuSpecs {
        return .{ .is_software_emulated = self.ctx.vk.is_software, .device_name = self.ctx.vk.device_label() };
    }

    pub fn create(ctx: *GpuContext, native: vulkan.NativeSurface, width: u32, height: u32, options: vulkan.WindowSwapchain.Options) ?GpuWindow {
        return create_with(ctx, native, width, height, options) catch |err| {
            log.debug("window uses the CPU renderer: {s}", .{@errorName(err)});
            return null;
        };
    }

    fn create_with(ctx: *GpuContext, native: vulkan.NativeSurface, width: u32, height: u32, options: vulkan.WindowSwapchain.Options) !GpuWindow {
        var swapchain = try vulkan.WindowSwapchain.init(&ctx.vk, native, width, height, options);
        errdefer swapchain.deinit();
        _ = try ctx.renderer_for(swapchain.color_format, swapchain.premultiplied());
        log.debug("swapchain composite alpha: {s}", .{if (swapchain.premultiplied()) "premultiplied" else "opaque"});
        return .{ .ctx = ctx, .swapchain = swapchain };
    }

    /// Must run before the native surface goes away.
    pub fn deinit(self: *GpuWindow) void {
        self.swapchain.deinit();
        self.* = undefined;
    }

    /// Switches between opaque and transparent. Takes effect at the next frame.
    pub fn set_transparent(self: *GpuWindow, transparent: bool) void {
        self.swapchain.set_transparent(transparent);
    }

    /// Draws and presents. False means no frame was shown and another should be requested.
    pub fn draw(self: *GpuWindow, scene: *const scene_mod.Scene, clear: color.Hsla, width: u32, height: u32) bool {
        return self.draw_inner(scene, clear, width, height) catch |err| {
            log.err("GPU frame failed: {s}", .{@errorName(err)});
            return false;
        };
    }

    fn draw_inner(self: *GpuWindow, scene: *const scene_mod.Scene, clear: color.Hsla, width: u32, height: u32) !bool {
        const image = (try self.swapchain.acquire(width, height)) orelse return false;
        // The renderer follows the composite alpha of this frame, which a background change may
        // have just switched (acquire recreates the swapchain then).
        const r = try self.ctx.renderer_for(self.swapchain.color_format, self.swapchain.premultiplied());
        try r.draw(scene, &self.ctx.atlas, .{ .swapchain = image }, clear);
        self.ctx.device.commit();
        try self.swapchain.present();
        return true;
    }
};
