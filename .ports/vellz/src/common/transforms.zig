//! Port of vello_common transforms.rs (Apache-2.0 OR MIT).
//!
//! `Transforms` is a plain value type. `RootTransforms` replaces upstream's
//! `SmallVec<[Affine; 3]>` with an unmanaged `std.ArrayList(Affine)`, so the
//! stack takes an allocator for `init`/`pushRoot`/`reset` and a `deinit`.
//!
//! Ownership/allocator note: `Transforms` owns nothing. `RootTransforms` owns
//! its stack; the allocator passed to `init` must be used for `pushRoot`,
//! `reset`, and `deinit`. `popRoot` never allocates.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");

/// Context for holding transforms for paths and paints.
pub const Transforms = struct {
    transform: kurbo.Affine,
    paint_transform: kurbo.Affine,

    /// Identity scene and paint transforms.
    pub const default: Transforms = .{
        .transform = kurbo.Affine.IDENTITY,
        .paint_transform = kurbo.Affine.IDENTITY,
    };

    /// Create a new transforms context.
    pub fn init() Transforms {
        return default;
    }

    /// Return the current scene transform.
    ///
    /// Upstream names this `transform` and returns a reference; Zig cannot
    /// have a method and field with the same name, so the field is the
    /// canonical accessor and this method is named `getTransform`.
    pub fn getTransform(self: Transforms) kurbo.Affine {
        return self.transform;
    }

    /// Return the transform used for rendering scene geometry.
    pub fn sceneTransform(self: Transforms) kurbo.Affine {
        return self.transform;
    }

    /// Set the current scene transform.
    pub fn setTransform(self: *Transforms, transform: kurbo.Affine) void {
        self.transform = transform;
    }

    /// Reset the current scene transform.
    pub fn resetTransform(self: *Transforms) void {
        self.transform = kurbo.Affine.IDENTITY;
    }

    /// Return the current paint transform.
    pub fn paintTransform(self: Transforms) kurbo.Affine {
        return self.paint_transform;
    }

    /// Return the transform used for rendering scene paints.
    pub fn scenePaintTransform(self: Transforms) kurbo.Affine {
        return self.sceneTransform().compose(self.paintTransform());
    }

    /// Set the current paint transform.
    pub fn setPaintTransform(self: *Transforms, paint_transform: kurbo.Affine) void {
        self.paint_transform = paint_transform;
    }

    /// Reset the current paint transform.
    pub fn resetPaintTransform(self: *Transforms) void {
        self.paint_transform = kurbo.Affine.IDENTITY;
    }

    /// Return the transform used for non-isolated clip paths.
    ///
    /// Unlike `RootTransforms.effectivePathTransform`, this intentionally does
    /// not apply the root transform because clipping handles root viewport
    /// shifts separately.
    pub fn clipPathTransform(self: Transforms) kurbo.Affine {
        return self.transform;
    }
};

/// Stack of root transforms.
pub const RootTransforms = struct {
    transforms: std.ArrayList(kurbo.Affine),

    /// Create a new root transform stack containing the identity transform.
    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!RootTransforms {
        var transforms = std.ArrayList(kurbo.Affine).empty;
        errdefer transforms.deinit(allocator);
        try transforms.append(allocator, kurbo.Affine.IDENTITY);
        return .{ .transforms = transforms };
    }

    /// Release the stack.
    pub fn deinit(self: *RootTransforms, allocator: std.mem.Allocator) void {
        self.transforms.deinit(allocator);
        self.* = undefined;
    }

    /// Return the root transform of the currently active root viewport,
    /// including shifts inherited from nested filters.
    pub fn rootTransform(self: *const RootTransforms) kurbo.Affine {
        const items = self.transforms.items;
        std.debug.assert(items.len > 0);
        return items[items.len - 1];
    }

    /// Return the transform used for rendering paths.
    pub fn effectivePathTransform(
        self: *const RootTransforms,
        transforms: Transforms,
    ) kurbo.Affine {
        return self.rootTransform().compose(transforms.getTransform());
    }

    /// Return the transform used for rendering paints.
    pub fn effectivePaintTransform(
        self: *const RootTransforms,
        transforms: Transforms,
    ) kurbo.Affine {
        return self.effectivePathTransform(transforms).compose(transforms.paintTransform());
    }

    /// Push a new root transform relative to the currently active root
    /// transform.
    pub fn pushRoot(
        self: *RootTransforms,
        allocator: std.mem.Allocator,
        relative_transform: kurbo.Affine,
    ) std.mem.Allocator.Error!void {
        try self.transforms.append(
            allocator,
            relative_transform.compose(self.rootTransform()),
        );
    }

    /// Pop the last root layer.
    ///
    /// Upstream pops even the base entry and then panics in
    /// `rootTransform()`; this port keeps the stack's "never empty"
    /// invariant by ignoring a pop that would remove the identity base.
    pub fn popRoot(self: *RootTransforms) void {
        if (self.transforms.items.len > 1) _ = self.transforms.pop();
    }

    /// Reset the root transform stack.
    pub fn reset(self: *RootTransforms, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.transforms.clearRetainingCapacity();
        try self.transforms.append(allocator, kurbo.Affine.IDENTITY);
    }
};

test "root_transforms_accumulate_relative_transforms" {
    const allocator = std.testing.allocator;
    var roots = try RootTransforms.init(allocator);
    defer roots.deinit(allocator);

    const parent = kurbo.Affine.translate(kurbo.Vec2.new(10.0, 20.0));
    const child = kurbo.Affine.scale(2.0);

    try roots.pushRoot(allocator, parent);
    try roots.pushRoot(allocator, child);

    try std.testing.expectEqual(
        child.compose(parent).asCoeffs(),
        roots.rootTransform().asCoeffs(),
    );
}

test "pop_root_restores_parent_transform" {
    const allocator = std.testing.allocator;
    var roots = try RootTransforms.init(allocator);
    defer roots.deinit(allocator);

    const parent = kurbo.Affine.translate(kurbo.Vec2.new(10.0, 20.0));

    try roots.pushRoot(allocator, parent);
    try roots.pushRoot(allocator, kurbo.Affine.scale(2.0));
    roots.popRoot();

    try std.testing.expectEqual(parent.asCoeffs(), roots.rootTransform().asCoeffs());
}

test "effective_transforms_include_root_scene_and_paint_transforms" {
    const allocator = std.testing.allocator;
    var roots = try RootTransforms.init(allocator);
    defer roots.deinit(allocator);

    const root = kurbo.Affine.translate(kurbo.Vec2.new(10.0, 20.0));
    const scene = kurbo.Affine.scale(2.0);
    const paint = kurbo.Affine.translate(kurbo.Vec2.new(3.0, 4.0));
    var transforms = Transforms.init();
    transforms.setTransform(scene);
    transforms.setPaintTransform(paint);
    try roots.pushRoot(allocator, root);

    try std.testing.expectEqual(
        root.compose(scene).asCoeffs(),
        roots.effectivePathTransform(transforms).asCoeffs(),
    );
    try std.testing.expectEqual(
        root.compose(scene).compose(paint).asCoeffs(),
        roots.effectivePaintTransform(transforms).asCoeffs(),
    );
}

test "transforms reset and scene_paint_transform" {
    var transforms = Transforms.init();
    const scene = kurbo.Affine.translate(kurbo.Vec2.new(1.0, 2.0));
    const paint = kurbo.Affine.scale(3.0);
    transforms.setTransform(scene);
    transforms.setPaintTransform(paint);

    try std.testing.expectEqual(
        scene.compose(paint).asCoeffs(),
        transforms.scenePaintTransform().asCoeffs(),
    );
    try std.testing.expectEqual(scene.asCoeffs(), transforms.clipPathTransform().asCoeffs());

    transforms.resetTransform();
    transforms.resetPaintTransform();
    try std.testing.expectEqual(Transforms.default, transforms);
}

test "root transforms survive reset and guarded pop" {
    const allocator = std.testing.allocator;
    var roots = try RootTransforms.init(allocator);
    defer roots.deinit(allocator);

    try roots.pushRoot(allocator, kurbo.Affine.scale(2.0));
    roots.popRoot();
    roots.popRoot();
    try std.testing.expectEqual(kurbo.Affine.IDENTITY.asCoeffs(), roots.rootTransform().asCoeffs());

    try roots.pushRoot(allocator, kurbo.Affine.scale(4.0));
    try roots.reset(allocator);
    try std.testing.expectEqual(kurbo.Affine.IDENTITY.asCoeffs(), roots.rootTransform().asCoeffs());
}
