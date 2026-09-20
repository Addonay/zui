//! Backend-selection and frame-lifetime contract for the Window renderer.
//!
//! This module deliberately does not import WGPU.  The CPU build therefore
//! keeps the same ABI and hot-frame budget, while the optional native bridge
//! can install a submit callback at the App/Window boundary.  The controller
//! owns policy; a backend owns API objects and persistent GPU resources.

const std = @import("std");

pub const Mode = enum { cpu, wgpu };
pub const Active = enum { cpu, wgpu, cpu_fallback };
pub const Submit = enum { presented, skipped_minimized, device_lost, unsupported };

/// Opaque native surface proof supplied by a platform backend. The WGPU
/// adapter owns interpretation of the handles; CPU-only builds never need to
/// know their ABI.
pub const NativeSurface = struct {
    kind: enum { wayland },
    display: *anyopaque,
    surface: *anyopaque,
};

pub const Selection = struct {
    requested: Mode,
    active: Active,
    gpu_compiled: bool,
    native_surface: bool,
    reason: Reason,

    pub const Reason = enum {
        cpu_default,
        gpu_selected,
        gpu_not_compiled,
        native_surface_missing,
        gpu_runtime_missing,
        cpu_after_loss,
    };
};

pub fn modeFromEnvironment() Mode {
    if (!@import("builtin").link_libc) return .cpu;
    const raw = std.c.getenv("ZUI_RENDERER") orelse return .cpu;
    return if (std.mem.eql(u8, std.mem.span(raw), "wgpu")) .wgpu else .cpu;
}

/// Selects policy only when the native integration has supplied all three
/// proofs: the build contains WGPU, the window exposes a compatible surface,
/// and a submit callback is installed.  This prevents an opt-in environment
/// variable from silently pretending that the CPU scene reached a GPU.
pub fn select(requested: Mode, gpu_compiled: bool, native_surface: bool, runtime_ready: bool) Selection {
    if (requested == .cpu) return .{ .requested = requested, .active = .cpu, .gpu_compiled = gpu_compiled, .native_surface = native_surface, .reason = .cpu_default };
    if (!gpu_compiled) return .{ .requested = requested, .active = .cpu_fallback, .gpu_compiled = false, .native_surface = native_surface, .reason = .gpu_not_compiled };
    if (!native_surface) return .{ .requested = requested, .active = .cpu_fallback, .gpu_compiled = true, .native_surface = false, .reason = .native_surface_missing };
    if (!runtime_ready) return .{ .requested = requested, .active = .cpu_fallback, .gpu_compiled = true, .native_surface = true, .reason = .gpu_runtime_missing };
    return .{ .requested = requested, .active = .wgpu, .gpu_compiled = true, .native_surface = true, .reason = .gpu_selected };
}

pub const Hook = *const fn (ctx: *anyopaque, frame_id: u64, scene: *const anyopaque, glyph_pixels: []const u8, image_pixels: []const u8, width: u32, height: u32) Submit;
pub const RecreateHook = *const fn (ctx: *anyopaque) bool;
pub const ResizeHook = *const fn (ctx: *anyopaque, width: u32, height: u32) void;
pub const Hooks = struct {
    ctx: *anyopaque,
    submit: Hook,
    recreate: ?RecreateHook = null,
    resize: ?ResizeHook = null,
};

pub const max_in_flight = 3;
pub const max_retired_resources = 128;

pub const Controller = struct {
    selection: Selection,
    hooks: ?Hooks = null,
    width: u32 = 1,
    height: u32 = 1,
    minimized: bool = false,
    frame_id: u64 = 0,
    generation: u64 = 1,
    recreate_attempted: bool = false,
    presented: u64 = 0,
    skipped: u64 = 0,
    device_losses: u32 = 0,
    fallback_count: u32 = 0,
    in_flight: [max_in_flight]Frame = @splat(.{}),
    retired: [max_retired_resources]Retired = @splat(.{}),

    pub const Frame = struct { id: u64 = 0, generation: u64 = 0, live: bool = false };
    pub const Retired = struct { resource: u64 = 0, retire_after: u64 = 0, live: bool = false };

    pub fn init(selection: Selection, width: u32, height: u32) @This() {
        return .{ .selection = selection, .width = @max(width, 1), .height = @max(height, 1) };
    }

    pub fn setHooks(self: *@This(), hooks: Hooks) void {
        self.hooks = hooks;
    }

    /// Called by a native integration once it has created its WGPU instance,
    /// surface, Vellz renderer, and persistent resource set.
    pub fn activateGpu(self: *@This(), hooks: Hooks) bool {
        if (!self.selection.gpu_compiled or !self.selection.native_surface) return false;
        self.hooks = hooks;
        self.selection.active = .wgpu;
        self.selection.reason = .gpu_selected;
        return true;
    }

    pub fn resize(self: *@This(), width: u32, height: u32) void {
        self.width = @max(width, 1);
        self.height = @max(height, 1);
        self.generation +|= 1;
        self.dropInFlight();
        if (self.hooks) |hooks| if (hooks.resize) |resize_hook| resize_hook(hooks.ctx, self.width, self.height);
    }

    pub fn setMinimized(self: *@This(), minimized: bool) void {
        self.minimized = minimized;
        if (minimized) self.dropInFlight();
    }

    /// Starts a frame only when the surface has usable dimensions. The caller
    /// must call submit() exactly once for a returned frame id.
    pub fn beginFrame(self: *@This()) ?u64 {
        if (self.minimized or self.width == 0 or self.height == 0) {
            self.skipped += 1;
            return null;
        }
        self.frame_id +|= 1;
        const slot = self.frame_id % max_in_flight;
        self.in_flight[slot] = .{ .id = self.frame_id, .generation = self.generation, .live = true };
        return self.frame_id;
    }

    pub fn submit(self: *@This(), frame_id: u64, scene: *const anyopaque, glyph_pixels: []const u8, image_pixels: []const u8) Submit {
        const result = if (self.selection.active == .wgpu) blk: {
            const hooks = self.hooks orelse break :blk Submit.unsupported;
            break :blk hooks.submit(hooks.ctx, frame_id, scene, glyph_pixels, image_pixels, self.width, self.height);
        } else Submit.presented;
        switch (result) {
            .presented => self.presented += 1,
            .skipped_minimized => self.skipped += 1,
            .device_lost => self.handleDeviceLoss(),
            .unsupported => self.fallbackToCpu(),
        }
        // A swapchain frame remains conservatively in flight for three
        // submissions. Native integrations may retire earlier via
        // retireCompleted() after an explicit fence/present callback.
        if (self.frame_id > max_in_flight) self.complete(self.frame_id - max_in_flight);
        _ = self.collect(if (self.frame_id > max_in_flight) self.frame_id - max_in_flight else 0);
        return result;
    }

    /// Native integrations that perform acquire/bridge/render/present in
    /// their own typed code can record the result without importing WGPU into
    /// this CPU-safe controller.
    pub fn recordPresented(self: *@This(), frame_id: u64) void {
        self.presented += 1;
        if (self.frame_id > max_in_flight) self.complete(self.frame_id - max_in_flight);
        _ = self.collect(if (self.frame_id > max_in_flight) self.frame_id - max_in_flight else 0);
        _ = frame_id;
    }

    /// Resources are held until all frames that could reference them have
    /// retired. This is intentionally backend-neutral; the WGPU bridge maps
    /// the resource id to its cache entry and frees it at collect().
    pub fn retireResource(self: *@This(), resource: u64) void {
        for (&self.retired) |*entry| {
            if (!entry.live) {
                entry.* = .{ .resource = resource, .retire_after = self.frame_id + max_in_flight, .live = true };
                return;
            }
        }
        // Bounded overflow is conservative: keep the old resource alive and
        // let the backend report pressure rather than free in-flight memory.
    }

    pub fn collect(self: *@This(), completed_frame: u64) usize {
        var count: usize = 0;
        for (&self.retired) |*entry| {
            if (entry.live and entry.retire_after <= completed_frame) {
                entry.live = false;
                count += 1;
            }
        }
        return count;
    }

    pub fn retireCompleted(self: *@This(), completed_frame: u64) void {
        for (&self.in_flight) |*frame| {
            if (frame.live and frame.id <= completed_frame) frame.live = false;
        }
        _ = self.collect(completed_frame);
    }

    pub fn usingCpu(self: *const @This()) bool {
        return self.selection.active != .wgpu;
    }

    fn complete(self: *@This(), frame_id: u64) void {
        self.in_flight[frame_id % max_in_flight].live = false;
    }

    fn dropInFlight(self: *@This()) void {
        for (&self.in_flight) |*frame| frame.live = false;
    }

    fn handleDeviceLoss(self: *@This()) void {
        self.device_losses += 1;
        if (!self.recreate_attempted) {
            self.recreate_attempted = true;
            self.generation +|= 1;
            self.dropInFlight();
            if (self.hooks) |hooks| {
                if (hooks.recreate) |recreate| {
                    if (!recreate(hooks.ctx)) {
                        self.fallbackToCpu();
                    }
                } else {
                    self.fallbackToCpu();
                }
            } else {
                self.fallbackToCpu();
            }
            return;
        }
        self.fallbackToCpu();
    }

    fn fallbackToCpu(self: *@This()) void {
        self.selection.active = .cpu_fallback;
        self.selection.reason = .cpu_after_loss;
        self.fallback_count += 1;
        self.dropInFlight();
    }
};

test "renderer selection keeps CPU default and requires an installed runtime" {
    try std.testing.expectEqual(Active.cpu, select(.cpu, true, true, true).active);
    try std.testing.expectEqual(Active.cpu_fallback, select(.wgpu, false, true, true).active);
    try std.testing.expectEqual(Selection.Reason.gpu_runtime_missing, select(.wgpu, true, true, false).reason);
    try std.testing.expectEqual(Active.wgpu, select(.wgpu, true, true, true).active);
}

test "renderer controller retires resources across resize and falls back after loss" {
    var controller = Controller.init(select(.wgpu, true, true, true), 100, 80);
    const first = controller.beginFrame().?;
    var scene: u8 = 0;
    try std.testing.expectEqual(Submit.unsupported, controller.submit(first, &scene, &.{}, &.{}));
    try std.testing.expect(controller.usingCpu());

    var retained = Controller.init(select(.wgpu, true, true, true), 100, 80);
    retained.retireResource(42);
    try std.testing.expectEqual(@as(usize, 0), retained.collect(1));
    try std.testing.expectEqual(@as(usize, 1), retained.collect(max_in_flight));
    retained.resize(200, 0);
    try std.testing.expectEqual(@as(u32, 1), retained.height);
    retained.setMinimized(true);
    try std.testing.expect(retained.beginFrame() == null);
}

const LossHarness = struct {
    losses_left: u8 = 1,
    recreates: u8 = 0,

    fn submit(ctx: *anyopaque, _: u64, _: *const anyopaque, _: []const u8, _: []const u8, _: u32, _: u32) Submit {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.losses_left > 0) {
            self.losses_left -= 1;
            return .device_lost;
        }
        return .presented;
    }

    fn recreate(ctx: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.recreates += 1;
        return true;
    }
};

test "renderer controller invokes one injected recreation before continuing" {
    var harness = LossHarness{};
    var controller = Controller.init(select(.wgpu, true, true, true), 64, 64);
    try std.testing.expect(controller.activateGpu(.{ .ctx = &harness, .submit = LossHarness.submit, .recreate = LossHarness.recreate }));
    var scene: u8 = 0;
    const first = controller.beginFrame().?;
    try std.testing.expectEqual(Submit.device_lost, controller.submit(first, &scene, &.{}, &.{}));
    try std.testing.expectEqual(@as(u8, 1), harness.recreates);
    try std.testing.expectEqual(Active.wgpu, controller.selection.active);
    const second = controller.beginFrame().?;
    try std.testing.expectEqual(Submit.presented, controller.submit(second, &scene, &.{}, &.{}));
    try std.testing.expectEqual(@as(u64, 1), controller.presented);
}
