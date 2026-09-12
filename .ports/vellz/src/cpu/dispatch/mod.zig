//! Port of vello_cpu src/dispatch/mod.rs (Apache-2.0 OR MIT).
//!
//! The `Dispatcher` vtable and the dispatch selection (`RenderSettings +
//! num_threads == 0` uses the single-threaded dispatcher, otherwise the
//! multi-threaded one). Upstream stores a `Box<dyn Dispatcher>` in
//! `RenderContext`; this port allocates the concrete dispatcher with the
//! caller's allocator and stores a pointer + vtable, which keeps
//! `RenderContext` movable and is the one place the repository allows dynamic
//! dispatch (upstream had it).
//!
//! Error policy (`adapt`): upstream's dispatcher methods are infallible and
//! panic on invalid usage or allocation failure. This vtable returns
//! `anyerror` so both implementations can surface `error.OutOfMemory` and the
//! typed usage errors (`NoActiveLayer`, `Unsupported`, `NotFlushed`, ...)
//! through `RenderContext`. The single-threaded implementation's error sets
//! are inferred and include allocator failures, so `anyerror` loses no
//! information at this seam.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const encode_mod = @import("../../common/encode.zig");
const filter_data_mod = @import("../../common/filter.zig");
const mask_mod = @import("../../common/mask.zig");
const paint_mod = @import("../../common/paint.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const settings_mod = @import("../settings.zig");
const multi_threaded = @import("multi_threaded.zig");
const single_threaded = @import("single_threaded.zig");

const FilterData = filter_data_mod.FilterData;
const Mask = mask_mod.Mask;
const Paint = paint_mod.Paint;
const PixmapMut = pixmap_mod.PixmapMut;
const RasterizerSettings = settings_mod.RasterizerSettings;
const RenderSettings = settings_mod.RenderSettings;

/// The `Dispatcher` trait as a Zig vtable (upstream `dispatch::Dispatcher`).
///
/// Every method takes the caller's allocator because both implementations
/// allocate on paths upstream assumes infallible, and callers already own an
/// allocator (`RenderContext` stores one).
pub const Dispatcher = struct {
    /// The concrete dispatcher (a `SingleThreadedDispatcher` or
    /// `MultiThreadedDispatcher`, heap-allocated by `create`).
    ptr: *anyopaque,
    /// The implementation's function table.
    vtable: *const VTable,

    /// The vtable shape; method signatures mirror upstream's trait.
    pub const VTable = struct {
        has_layers: *const fn (ptr: *const anyopaque) bool,
        is_multi_threaded: *const fn (ptr: *const anyopaque) bool,
        fill_path: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const kurbo.PathEl,
            fill_rule: peniko.Fill,
            transform: kurbo.Affine,
            paint: Paint,
            blend_mode: peniko.BlendMode,
            aliasing_threshold: ?u8,
            mask: ?*const Mask,
        ) anyerror!void,
        stroke_path: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const kurbo.PathEl,
            stroke: *const kurbo.Stroke,
            transform: kurbo.Affine,
            paint: Paint,
            blend_mode: peniko.BlendMode,
            aliasing_threshold: ?u8,
            mask: ?*const Mask,
        ) anyerror!void,
        fill_rect_fast: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            rect: *const kurbo.Rect,
            paint: Paint,
            blend_mode: peniko.BlendMode,
            mask: ?*const Mask,
        ) anyerror!void,
        push_layer: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            clip_path: ?[]const kurbo.PathEl,
            fill_rule: peniko.Fill,
            clip_transform: kurbo.Affine,
            blend_mode: peniko.BlendMode,
            opacity: f32,
            aliasing_threshold: ?u8,
            mask: ?Mask,
            filter_data: ?FilterData,
        ) anyerror!void,
        pop_layer: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
        reset: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            width: u16,
            height: u16,
        ) anyerror!void,
        flush: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
        push_clip_path: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const kurbo.PathEl,
            fill_rule: peniko.Fill,
            transform: kurbo.Affine,
            aliasing_threshold: ?u8,
        ) anyerror!void,
        pop_clip_path: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
        rasterize: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            target: *PixmapMut,
            scene_width: u16,
            scene_height: u16,
            settings: RasterizerSettings,
            encoded_paints: []encode_mod.EncodedPaint,
            image_resolver: paint_mod.ImageResolver,
        ) anyerror!void,
        /// Release the concrete dispatcher and free its box.
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    /// Select and create a dispatcher for `settings` (upstream
    /// `RenderContext::new_with`).
    ///
    /// `settings.num_threads == 0` selects the single-threaded dispatcher; any
    /// other value selects the multi-threaded one, which is why this port does
    /// not silently ignore the setting.
    pub fn create(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        settings: RenderSettings,
    ) !Dispatcher {
        if (settings.num_threads == 0) {
            const impl = try allocator.create(single_threaded.SingleThreadedDispatcher);
            errdefer allocator.destroy(impl);
            impl.* = try single_threaded.SingleThreadedDispatcher.init(
                allocator,
                width,
                height,
                settings.level,
            );
            errdefer impl.deinit(allocator);
            return .{ .ptr = impl, .vtable = &single_vtable };
        }

        const impl = try allocator.create(multi_threaded.MultiThreadedDispatcher);
        errdefer allocator.destroy(impl);
        impl.* = try multi_threaded.MultiThreadedDispatcher.init(
            allocator,
            width,
            height,
            settings.num_threads,
            settings.level,
        );
        errdefer impl.deinit(allocator);
        return .{ .ptr = impl, .vtable = &multi_vtable };
    }

    /// Release the dispatcher (upstream `Box<dyn Dispatcher>` drop).
    pub fn destroy(self: *Dispatcher, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    /// Whether any layers are currently open.
    pub fn hasLayers(self: *const Dispatcher) bool {
        return self.vtable.has_layers(self.ptr);
    }

    /// Whether this dispatcher uses multiple threads.
    pub fn isMultiThreaded(self: *const Dispatcher) bool {
        return self.vtable.is_multi_threaded(self.ptr);
    }

    pub fn fillPath(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: peniko.Fill,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: peniko.BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        return self.vtable.fill_path(
            self.ptr,
            allocator,
            path,
            fill_rule,
            transform,
            paint,
            blend_mode,
            aliasing_threshold,
            mask,
        );
    }

    pub fn strokePath(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        stroke: *const kurbo.Stroke,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: peniko.BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        return self.vtable.stroke_path(
            self.ptr,
            allocator,
            path,
            stroke,
            transform,
            paint,
            blend_mode,
            aliasing_threshold,
            mask,
        );
    }

    pub fn fillRectFast(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        rect: *const kurbo.Rect,
        paint: Paint,
        blend_mode: peniko.BlendMode,
        mask: ?*const Mask,
    ) !void {
        return self.vtable.fill_rect_fast(self.ptr, allocator, rect, paint, blend_mode, mask);
    }

    pub fn pushLayer(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        clip_path: ?[]const kurbo.PathEl,
        fill_rule: peniko.Fill,
        clip_transform: kurbo.Affine,
        blend_mode: peniko.BlendMode,
        opacity: f32,
        aliasing_threshold: ?u8,
        mask: ?Mask,
        filter_data: ?FilterData,
    ) !void {
        return self.vtable.push_layer(
            self.ptr,
            allocator,
            clip_path,
            fill_rule,
            clip_transform,
            blend_mode,
            opacity,
            aliasing_threshold,
            mask,
            filter_data,
        );
    }

    pub fn popLayer(self: *Dispatcher, allocator: std.mem.Allocator) !void {
        return self.vtable.pop_layer(self.ptr, allocator);
    }

    pub fn reset(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) !void {
        return self.vtable.reset(self.ptr, allocator, width, height);
    }

    pub fn flush(self: *Dispatcher, allocator: std.mem.Allocator) !void {
        return self.vtable.flush(self.ptr, allocator);
    }

    pub fn pushClipPath(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: peniko.Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) !void {
        return self.vtable.push_clip_path(
            self.ptr,
            allocator,
            path,
            fill_rule,
            transform,
            aliasing_threshold,
        );
    }

    pub fn popClipPath(self: *Dispatcher, allocator: std.mem.Allocator) !void {
        return self.vtable.pop_clip_path(self.ptr, allocator);
    }

    pub fn rasterize(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        target: *PixmapMut,
        scene_width: u16,
        scene_height: u16,
        settings: RasterizerSettings,
        encoded_paints: []encode_mod.EncodedPaint,
        image_resolver: paint_mod.ImageResolver,
    ) !void {
        return self.vtable.rasterize(
            self.ptr,
            allocator,
            target,
            scene_width,
            scene_height,
            settings,
            encoded_paints,
            image_resolver,
        );
    }
};

// ---------------------------------------------------------------------------
// Single-threaded adapters
// ---------------------------------------------------------------------------

fn singlePtr(ptr: *anyopaque) *single_threaded.SingleThreadedDispatcher {
    return @ptrCast(@alignCast(ptr));
}

fn singleConstPtr(ptr: *const anyopaque) *const single_threaded.SingleThreadedDispatcher {
    return @ptrCast(@alignCast(ptr));
}

fn singleHasLayers(ptr: *const anyopaque) bool {
    return singleConstPtr(ptr).hasLayers();
}

fn singleIsMultiThreaded(ptr: *const anyopaque) bool {
    return singleConstPtr(ptr).isMultiThreaded();
}

fn singleFillPath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    fill_rule: peniko.Fill,
    transform: kurbo.Affine,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    aliasing_threshold: ?u8,
    mask: ?*const Mask,
) anyerror!void {
    return singlePtr(ptr).fillPath(
        allocator,
        path,
        fill_rule,
        transform,
        paint,
        blend_mode,
        aliasing_threshold,
        mask,
    );
}

fn singleStrokePath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    stroke: *const kurbo.Stroke,
    transform: kurbo.Affine,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    aliasing_threshold: ?u8,
    mask: ?*const Mask,
) anyerror!void {
    return singlePtr(ptr).strokePath(
        allocator,
        path,
        stroke,
        transform,
        paint,
        blend_mode,
        aliasing_threshold,
        mask,
    );
}

fn singleFillRectFast(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    rect: *const kurbo.Rect,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    mask: ?*const Mask,
) anyerror!void {
    return singlePtr(ptr).fillRectFast(allocator, rect, paint, blend_mode, mask);
}

fn singlePushLayer(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    clip_path: ?[]const kurbo.PathEl,
    fill_rule: peniko.Fill,
    clip_transform: kurbo.Affine,
    blend_mode: peniko.BlendMode,
    opacity: f32,
    aliasing_threshold: ?u8,
    mask: ?Mask,
    filter_data: ?FilterData,
) anyerror!void {
    return singlePtr(ptr).pushLayer(
        allocator,
        clip_path,
        fill_rule,
        clip_transform,
        blend_mode,
        opacity,
        aliasing_threshold,
        mask,
        filter_data,
    );
}

fn singlePopLayer(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    return singlePtr(ptr).popLayer(allocator);
}

fn singleReset(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
) anyerror!void {
    return singlePtr(ptr).reset(allocator, width, height);
}

fn singleFlush(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    _ = allocator;
    singlePtr(ptr).flush();
}

fn singlePushClipPath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    fill_rule: peniko.Fill,
    transform: kurbo.Affine,
    aliasing_threshold: ?u8,
) anyerror!void {
    return singlePtr(ptr).pushClipPath(
        allocator,
        path,
        fill_rule,
        transform,
        aliasing_threshold,
    );
}

fn singlePopClipPath(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    _ = allocator;
    singlePtr(ptr).popClipPath();
}

fn singleRasterize(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    target: *PixmapMut,
    scene_width: u16,
    scene_height: u16,
    settings: RasterizerSettings,
    encoded_paints: []encode_mod.EncodedPaint,
    image_resolver: paint_mod.ImageResolver,
) anyerror!void {
    return singlePtr(ptr).rasterize(
        allocator,
        target,
        scene_width,
        scene_height,
        settings,
        encoded_paints,
        image_resolver,
    );
}

fn singleDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const impl = singlePtr(ptr);
    impl.deinit(allocator);
    allocator.destroy(impl);
}

const single_vtable = Dispatcher.VTable{
    .has_layers = singleHasLayers,
    .is_multi_threaded = singleIsMultiThreaded,
    .fill_path = singleFillPath,
    .stroke_path = singleStrokePath,
    .fill_rect_fast = singleFillRectFast,
    .push_layer = singlePushLayer,
    .pop_layer = singlePopLayer,
    .reset = singleReset,
    .flush = singleFlush,
    .push_clip_path = singlePushClipPath,
    .pop_clip_path = singlePopClipPath,
    .rasterize = singleRasterize,
    .deinit = singleDeinit,
};

// ---------------------------------------------------------------------------
// Multi-threaded adapters
// ---------------------------------------------------------------------------

fn multiPtr(ptr: *anyopaque) *multi_threaded.MultiThreadedDispatcher {
    return @ptrCast(@alignCast(ptr));
}

fn multiConstPtr(ptr: *const anyopaque) *const multi_threaded.MultiThreadedDispatcher {
    return @ptrCast(@alignCast(ptr));
}

fn multiHasLayers(ptr: *const anyopaque) bool {
    return multiConstPtr(ptr).hasLayers();
}

fn multiIsMultiThreaded(ptr: *const anyopaque) bool {
    return multiConstPtr(ptr).isMultiThreaded();
}

fn multiFillPath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    fill_rule: peniko.Fill,
    transform: kurbo.Affine,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    aliasing_threshold: ?u8,
    mask: ?*const Mask,
) anyerror!void {
    return multiPtr(ptr).fillPath(
        allocator,
        path,
        fill_rule,
        transform,
        paint,
        blend_mode,
        aliasing_threshold,
        mask,
    );
}

fn multiStrokePath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    stroke: *const kurbo.Stroke,
    transform: kurbo.Affine,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    aliasing_threshold: ?u8,
    mask: ?*const Mask,
) anyerror!void {
    return multiPtr(ptr).strokePath(
        allocator,
        path,
        stroke,
        transform,
        paint,
        blend_mode,
        aliasing_threshold,
        mask,
    );
}

fn multiFillRectFast(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    rect: *const kurbo.Rect,
    paint: Paint,
    blend_mode: peniko.BlendMode,
    mask: ?*const Mask,
) anyerror!void {
    return multiPtr(ptr).fillRectFast(allocator, rect, paint, blend_mode, mask);
}

fn multiPushLayer(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    clip_path: ?[]const kurbo.PathEl,
    fill_rule: peniko.Fill,
    clip_transform: kurbo.Affine,
    blend_mode: peniko.BlendMode,
    opacity: f32,
    aliasing_threshold: ?u8,
    mask: ?Mask,
    filter_data: ?FilterData,
) anyerror!void {
    return multiPtr(ptr).pushLayer(
        allocator,
        clip_path,
        fill_rule,
        clip_transform,
        blend_mode,
        opacity,
        aliasing_threshold,
        mask,
        filter_data,
    );
}

fn multiPopLayer(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    return multiPtr(ptr).popLayer(allocator);
}

fn multiReset(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
) anyerror!void {
    return multiPtr(ptr).reset(allocator, width, height);
}

fn multiFlush(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    return multiPtr(ptr).flush(allocator);
}

fn multiPushClipPath(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    fill_rule: peniko.Fill,
    transform: kurbo.Affine,
    aliasing_threshold: ?u8,
) anyerror!void {
    return multiPtr(ptr).pushClipPath(
        allocator,
        path,
        fill_rule,
        transform,
        aliasing_threshold,
    );
}

fn multiPopClipPath(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    return multiPtr(ptr).popClipPath(allocator);
}

fn multiRasterize(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    target: *PixmapMut,
    scene_width: u16,
    scene_height: u16,
    settings: RasterizerSettings,
    encoded_paints: []encode_mod.EncodedPaint,
    image_resolver: paint_mod.ImageResolver,
) anyerror!void {
    return multiPtr(ptr).rasterize(
        allocator,
        target,
        scene_width,
        scene_height,
        settings,
        encoded_paints,
        image_resolver,
    );
}

fn multiDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const impl = multiPtr(ptr);
    impl.deinit(allocator);
    allocator.destroy(impl);
}

const multi_vtable = Dispatcher.VTable{
    .has_layers = multiHasLayers,
    .is_multi_threaded = multiIsMultiThreaded,
    .fill_path = multiFillPath,
    .stroke_path = multiStrokePath,
    .fill_rect_fast = multiFillRectFast,
    .push_layer = multiPushLayer,
    .pop_layer = multiPopLayer,
    .reset = multiReset,
    .flush = multiFlush,
    .push_clip_path = multiPushClipPath,
    .pop_clip_path = multiPopClipPath,
    .rasterize = multiRasterize,
    .deinit = multiDeinit,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

test "dispatch selection honours num_threads" {
    const allocator = testing.allocator;

    var single = try Dispatcher.create(allocator, 16, 16, .{
        .level = .baseline,
        .num_threads = 0,
    });
    defer single.destroy(allocator);
    try testing.expect(!single.isMultiThreaded());

    var multi = try Dispatcher.create(allocator, 16, 16, .{
        .level = .baseline,
        .num_threads = 2,
    });
    defer multi.destroy(allocator);
    try testing.expect(multi.isMultiThreaded());

    // Thread-count limits are checked before any thread is spawned.
    try testing.expectError(
        error.TooManyThreads,
        Dispatcher.create(allocator, 16, 16, .{ .level = .baseline, .num_threads = 256 }),
    );
}

test "single- and multi-threaded dispatchers agree byte for byte" {
    const allocator = testing.allocator;
    const width: u16 = 32;
    const height: u16 = 32;

    var reference = try renderWithThreads(allocator, width, height, 0);
    defer reference.deinit(allocator);

    for (1..5) |threads| {
        var actual = try renderWithThreads(allocator, width, height, @intCast(threads));
        defer actual.deinit(allocator);
        try testing.expectEqualSlices(
            u8,
            reference.dataAsU8Slice(),
            actual.dataAsU8Slice(),
        );
    }
}

/// Render a small layered scene through the dispatcher seam (solid paints,
/// overlapping translucent rects, a clip path, and a stroke) and return the
/// pixmap.
fn renderWithThreads(
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    num_threads: u16,
) !pixmap_mod.Pixmap {
    var dispatcher = try Dispatcher.create(allocator, width, height, .{
        .level = .baseline,
        .num_threads = num_threads,
    });
    defer dispatcher.destroy(allocator);

    const settings = RasterizerSettings{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    };

    const clip_rect = [_]kurbo.PathEl{
        .{ .MoveTo = kurbo.Point.new(4.0, 4.0) },
        .{ .LineTo = kurbo.Point.new(20.0, 4.0) },
        .{ .LineTo = kurbo.Point.new(20.0, 20.0) },
        .{ .LineTo = kurbo.Point.new(4.0, 20.0) },
        .ClosePath,
    };
    try dispatcher.pushClipPath(
        allocator,
        &clip_rect,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );

    // Opaque background across every strip row.
    var path = try kurbo.Rect.new(0.0, 0.0, @floatFromInt(width), @floatFromInt(height)).toPath(0.1, allocator);
    defer path.deinit(allocator);
    try dispatcher.fillPath(
        allocator,
        path.elements.items,
        .non_zero,
        kurbo.Affine.IDENTITY,
        Paint.fromAlphaColor(palette.BLUE),
        peniko.BlendMode.default,
        null,
        null,
    );

    // Overlapping translucent rects recorded as separate tasks.
    for (0..6) |i| {
        const offset: f64 = 2.0 + @as(f64, @floatFromInt(i)) * 3.0;
        var rect = try kurbo.Rect.new(offset, offset, offset + 16.0, offset + 16.0).toPath(0.1, allocator);
        defer rect.deinit(allocator);
        try dispatcher.fillPath(
            allocator,
            rect.elements.items,
            .non_zero,
            kurbo.Affine.IDENTITY,
            Paint.fromAlphaColor(palette.RED.withAlpha(0.5)),
            peniko.BlendMode.default,
            null,
            null,
        );
    }

    // A stroke (exercises stroke expansion in the workers).
    var stroke_path = try kurbo.Rect.new(2.0, 2.0, 28.0, 28.0).toPath(0.1, allocator);
    defer stroke_path.deinit(allocator);
    var stroke = kurbo.Stroke.new(2.0);
    stroke = stroke.withJoin(.round).withCaps(.round);
    try dispatcher.strokePath(
        allocator,
        stroke_path.elements.items,
        &stroke,
        kurbo.Affine.IDENTITY,
        Paint.fromAlphaColor(palette.GREEN),
        peniko.BlendMode.default,
        null,
        null,
    );

    try dispatcher.popClipPath(allocator);

    try dispatcher.flush(allocator);

    var pixmap = try pixmap_mod.Pixmap.init(allocator, width, height);
    errdefer pixmap.deinit(allocator);
    var target = pixmap.asMut();
    try dispatcher.rasterize(
        allocator,
        &target,
        width,
        height,
        settings,
        &.{},
        paint_mod.NO_OP_IMAGE_RESOLVER,
    );
    return pixmap;
}
