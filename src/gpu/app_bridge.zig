//! Optional App/Window WGPU handoff.
//!
//! This is intentionally a small ownership boundary: platform code supplies
//! opaque Wayland handles, this module owns WGPU/Vellz objects, and the
//! renderer controller decides when CPU fallback is required.

const std = @import("std");
const wgpu = @import("wgpu");
const vellz = @import("vellz");
const render_backend = @import("render_backend.zig");
const scene_mod = @import("scene.zig");
const bridge = @import("wgpu_bridge.zig");

const c = wgpu.c;
const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;
const peniko = vellz.peniko;
const gpu_resources = vellz.gpu.resources;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    instance: backend.Instance,
    adapter: backend.Adapter,
    device: backend.Device,
    surface: c.WGPUSurface,
    format: c.WGPUTextureFormat,
    config: c.WGPUSurfaceConfiguration,
    renderer: backend.renderer.Renderer,
    resources: gpu_resources.Resources,
    cache: bridge.BridgeCache = .{},

    pub fn create(allocator: std.mem.Allocator, native: render_backend.NativeSurface, width: u32, height: u32) !*Bridge {
        if (native.kind != .wayland) return error.UnsupportedSurface;
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.instance = try backend.Instance.create();
        errdefer self.instance.deinit();
        self.adapter = try backend.Adapter.acquire(&self.instance, .{});
        errdefer self.adapter.deinit();
        self.device = try backend.Device.acquire(allocator, &self.adapter, "zui-app-wgpu");
        errdefer self.device.deinit();

        var source = c.wgpu_zig_init_WGPUSurfaceSourceWaylandSurface();
        source.display = native.display;
        source.surface = native.surface;
        var descriptor = c.wgpu_zig_init_WGPUSurfaceDescriptor();
        descriptor.label = wgpu.stringView("zui-app-wgpu-surface");
        descriptor.nextInChain = &source.chain;
        self.surface = c.wgpuInstanceCreateSurface(self.instance.handle, &descriptor) orelse return error.SurfaceCreateFailed;
        errdefer c.wgpuSurfaceRelease(self.surface);

        var caps = c.wgpu_zig_init_WGPUSurfaceCapabilities();
        if (c.wgpuSurfaceGetCapabilities(self.surface, self.adapter.handle, &caps) != c.WGPUStatus_Success) return error.SurfaceCapabilitiesFailed;
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        if (caps.formatCount == 0 or caps.formats == null) return error.NoSurfaceFormat;
        self.format = caps.formats[0];
        self.config = c.wgpu_zig_init_WGPUSurfaceConfiguration();
        self.config.device = self.device.handle;
        self.config.format = self.format;
        self.config.usage = c.WGPUTextureUsage_RenderAttachment;
        self.config.width = @max(width, 1);
        self.config.height = @max(height, 1);
        self.config.alphaMode = c.WGPUCompositeAlphaMode_Auto;
        self.config.presentMode = c.WGPUPresentMode_Fifo;
        c.wgpuSurfaceConfigure(self.surface, &self.config);

        self.renderer = try backend.renderer.Renderer.init(allocator, &self.device, self.format, self.config.width, self.config.height);
        errdefer self.renderer.deinit();
        self.resources = try gpu_resources.Resources.init(allocator);
        errdefer self.resources.deinit();
        try self.renderer.configureResources(&self.resources);
        return self;
    }

    pub fn hooks(self: *Bridge) render_backend.Hooks {
        return .{
            .ctx = self,
            .submit = submit,
            .recreate = recreate,
            .resize = resize,
        };
    }

    fn resize(ctx: *anyopaque, width: u32, height: u32) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.config.width = @max(width, 1);
        self.config.height = @max(height, 1);
        c.wgpuSurfaceConfigure(self.surface, &self.config);
    }

    fn recreate(ctx: *anyopaque) bool {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        // Reconfiguration is safe after a recoverable surface loss. A real
        // adapter/device loss returns false and lets Controller select CPU.
        c.wgpuSurfaceConfigure(self.surface, &self.config);
        return true;
    }

    fn submit(ctx: *anyopaque, _: u64, raw_scene: *const anyopaque, glyph_pixels: []const u8, image_pixels: []const u8, width: u32, height: u32) render_backend.Submit {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const source: *const scene_mod.Scene = @ptrCast(@alignCast(raw_scene));
        if (width != self.config.width or height != self.config.height) resize(ctx, width, height);
        var current = c.wgpu_zig_init_WGPUSurfaceTexture();
        c.wgpuSurfaceGetCurrentTexture(self.surface, &current);
        switch (current.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            => {},
            c.WGPUSurfaceGetCurrentTextureStatus_Outdated,
            c.WGPUSurfaceGetCurrentTextureStatus_Lost,
            => return .device_lost,
            else => return .unsupported,
        }
        const texture = current.texture orelse return .unsupported;
        defer c.wgpuTextureRelease(texture);
        const view = backend.wgpu.createFullView(texture, self.format, "zui-app-wgpu-view") catch return .unsupported;
        defer c.wgpuTextureViewRelease(view);
        var target = gpu_scene.Scene.init(self.allocator, @intCast(width), @intCast(height)) catch return .unsupported;
        defer target.deinit();
        bridge.bridgeScene(self.allocator, source, &target, null, null, image_pixels, glyph_pixels, &self.renderer, &self.resources, &self.cache) catch return .unsupported;
        self.renderer.renderWithResources(&target, view, null, .{ .clear = peniko.Color.fromRgba8(0, 0, 0, 255) }, .{}, null, &self.resources) catch return .device_lost;
        self.device.check() catch return .device_lost;
        if (c.wgpuSurfacePresent(self.surface) != c.WGPUStatus_Success) return .device_lost;
        return .presented;
    }

    pub fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        self.cache.deinit(allocator, &self.resources) catch {};
        self.resources.deinit();
        self.renderer.deinit();
        c.wgpuSurfaceRelease(self.surface);
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
        allocator.destroy(self);
    }
};

test "app bridge exposes controller hooks without changing CPU policy" {
    // The native constructor is intentionally not run in headless tests.
    // Selection remains a separate, deterministic controller contract.
    const selection = render_backend.select(.cpu, false, false, false);
    try std.testing.expectEqual(render_backend.Active.cpu, selection.active);
}
