//! Deferred atlas rendering commands.
//!
//! Port of `glifo/src/atlas/commands.rs`. During glyph encoding, outline (and,
//! once ported, COLR) glyph draw commands are recorded into an
//! `AtlasCommandRecorder` rather than being executed immediately. At render
//! time the application drains the pending recorders (grouped by atlas page)
//! and replays them into a single glyph renderer that is reset between pages.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - `Arc<BezPath>` commands own a `kurbo.BezPath` directly; every command
//!   that clones a path takes the allocator and can fail with
//!   `error.OutOfMemory` (upstream's `Vec::push`/`Arc::new` abort).
//! - `AtlasPaint::Gradient` is only representable once COLR lands and returns
//!   `error.Unsupported` here instead of being silently stored.

const std = @import("std");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const paint_mod = @import("../../common/paint.zig");

/// Paint type for atlas commands.
pub const AtlasPaint = union(enum) {
    /// A solid color (used for outlines and COLR solid fills).
    solid: peniko.Color,
    /// A gradient (used for COLR gradient fills).
    gradient: peniko.Gradient,

    /// Convert to the renderer paint type. Gradients clone their stops, so the
    /// conversion takes an allocator; gradients are deferred until COLR lands.
    pub fn toPaintType(self: *const AtlasPaint, allocator: std.mem.Allocator) !paint_mod.PaintType {
        return switch (self.*) {
            .solid => |color| paint_mod.PaintType.fromAlphaColor(color),
            .gradient => |gradient| blk: {
                var copy = gradient;
                const cloned = try copy.clone(allocator);
                break :blk paint_mod.PaintType.fromGradient(cloned);
            },
        };
    }
};

/// A single draw command recorded for deferred atlas rendering.
///
/// The variants correspond to the renderer's low-level drawing surface
/// (`fillPath`/`fillRect`/clip/layer calls).
pub const AtlasCommand = union(enum) {
    /// Set the current transform.
    set_transform: kurbo.Affine,
    /// Set the current paint.
    set_paint: AtlasPaint,
    /// Set the paint transform.
    set_paint_transform: kurbo.Affine,
    /// Fill a path with the current paint and transform (owned path).
    fill_path: kurbo.BezPath,
    /// Fill a rectangle with the current paint and transform.
    fill_rect: kurbo.Rect,
    /// Push a clip layer defined by a path (owned path).
    push_clip_layer: kurbo.BezPath,
    /// Push a clip path (owned path).
    push_clip_path: kurbo.BezPath,
    /// Push a blend/compositing layer.
    push_blend_layer: peniko.BlendMode,
    /// Pop the most recent clip or blend layer.
    pop_layer,
    /// Pop the most recent clip path.
    pop_clip_path,

    /// Release any owned path.
    pub fn deinit(self: *AtlasCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .fill_path, .push_clip_layer, .push_clip_path => |*path| path.deinit(allocator),
            else => {},
        }
    }
};

/// Records atlas draw commands for a single atlas page.
///
/// The recorder exposes the same method surface as the renderers
/// (`RenderContext`), with the allocator made explicit because appending a
/// path command clones it. `renderer.zig` replays the recorded commands into a
/// `DrawSink`.
pub const AtlasCommandRecorder = struct {
    /// Which atlas page these commands target.
    page_index: u32,
    /// The recorded commands.
    commands: std.ArrayListUnmanaged(AtlasCommand) = .empty,
    /// Width of the glyph renderer / atlas page (pixels).
    ///
    /// Named `page_width` because Zig cannot have a field and a method with
    /// the same name; the upstream accessor `width()` is preserved.
    page_width: u16,
    /// Height of the glyph renderer / atlas page (pixels).
    page_height: u16,

    /// Create a new recorder for the given atlas page.
    ///
    /// `width`/`height` must match the glyph renderer dimensions (i.e. the
    /// atlas page size) so COLR `fill_solid`/`fill_gradient` produce
    /// correctly-sized fill rects.
    pub fn init(page_index: u32, page_width: u16, page_height: u16) AtlasCommandRecorder {
        return .{ .page_index = page_index, .page_width = page_width, .page_height = page_height };
    }

    /// Release every recorded command and the command storage.
    pub fn deinit(self: *AtlasCommandRecorder, allocator: std.mem.Allocator) void {
        self.clearCommands(allocator);
        self.commands.deinit(allocator);
        self.* = undefined;
    }

    /// Drop all recorded commands, keeping the command allocation for reuse.
    pub fn clearCommands(self: *AtlasCommandRecorder, allocator: std.mem.Allocator) void {
        for (self.commands.items) |*command| command.deinit(allocator);
        self.commands.clearRetainingCapacity();
    }

    fn append(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, command: AtlasCommand) !void {
        self.commands.append(allocator, command) catch |err| {
            var owned = command;
            owned.deinit(allocator);
            return err;
        };
    }

    pub fn setTransform(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, t: kurbo.Affine) !void {
        try self.append(allocator, .{ .set_transform = t });
    }

    pub fn setPaint(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, paint: AtlasPaint) !void {
        // The solid color is a plain value; no owned payload is cloned.
        switch (paint) {
            .solid => try self.append(allocator, .{ .set_paint = paint }),
            // Deferred until COLR lands: never silently drop the gradient.
            .gradient => return error.Unsupported,
        }
    }

    pub fn setPaintTransform(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, t: kurbo.Affine) !void {
        try self.append(allocator, .{ .set_paint_transform = t });
    }

    pub fn fillPath(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, path: *const kurbo.BezPath) !void {
        const cloned = try path.clone(allocator);
        errdefer {
            var owned = cloned;
            owned.deinit(allocator);
        }
        try self.append(allocator, .{ .fill_path = cloned });
    }

    pub fn fillRect(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, rect: kurbo.Rect) !void {
        try self.append(allocator, .{ .fill_rect = rect });
    }

    pub fn pushClipLayer(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, clip: *const kurbo.BezPath) !void {
        const cloned = try clip.clone(allocator);
        errdefer {
            var owned = cloned;
            owned.deinit(allocator);
        }
        try self.append(allocator, .{ .push_clip_layer = cloned });
    }

    pub fn pushClipPath(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, clip: *const kurbo.BezPath) !void {
        const cloned = try clip.clone(allocator);
        errdefer {
            var owned = cloned;
            owned.deinit(allocator);
        }
        try self.append(allocator, .{ .push_clip_path = cloned });
    }

    pub fn pushBlendLayer(self: *AtlasCommandRecorder, allocator: std.mem.Allocator, blend_mode: peniko.BlendMode) !void {
        try self.append(allocator, .{ .push_blend_layer = blend_mode });
    }

    pub fn popLayer(self: *AtlasCommandRecorder, allocator: std.mem.Allocator) !void {
        try self.append(allocator, .pop_layer);
    }

    pub fn popClipPath(self: *AtlasCommandRecorder, allocator: std.mem.Allocator) !void {
        try self.append(allocator, .pop_clip_path);
    }

    pub fn width(self: *const AtlasCommandRecorder) u16 {
        return self.page_width;
    }

    pub fn height(self: *const AtlasCommandRecorder) u16 {
        return self.page_height;
    }
};

const testing = std.testing;

test "recorder clones paths and frees them on clear" {
    const allocator = testing.allocator;
    const path = kurbo.BezPath.fromElements(allocator, &.{
        .{ .MoveTo = kurbo.Point.new(0.0, 0.0) },
        .{ .LineTo = kurbo.Point.new(1.0, 1.0) },
    }) catch unreachable;
    var path_mut = path;
    defer path_mut.deinit(allocator);

    var recorder = AtlasCommandRecorder.init(2, 64, 64);
    defer recorder.deinit(allocator);
    try recorder.setTransform(allocator, kurbo.Affine.IDENTITY);
    try recorder.setPaint(allocator, .{ .solid = peniko.Color.BLACK });
    try recorder.fillPath(allocator, &path);
    try recorder.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
    try recorder.pushClipPath(allocator, &path);
    try recorder.popClipPath(allocator);
    try testing.expectEqual(@as(usize, 6), recorder.commands.items.len);
    try testing.expectEqual(@as(u32, 2), recorder.page_index);
    try testing.expectEqual(@as(u16, 64), recorder.width());

    recorder.clearCommands(allocator);
    try testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
}

test "gradient paint is a typed unsupported error" {
    const allocator = testing.allocator;
    var recorder = AtlasCommandRecorder.init(0, 64, 64);
    defer recorder.deinit(allocator);
    try testing.expectError(
        error.Unsupported,
        recorder.setPaint(allocator, .{ .gradient = .{} }),
    );
}
