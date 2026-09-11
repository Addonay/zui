//! Port of vello_common viewport.rs (Apache-2.0 OR MIT).
//!
//! `ViewportState` owns the active `StripGenerator`, the stack of parent strip
//! generators for pushed root viewports, and the `ClipState` that tracks clip
//! paths across filter layers.
//!
//! Interface adaptation: Zig has no closures, so `withGeneratorAndClip` takes
//! an explicit `context` value and a function
//! `f(context, *StripGenerator, ?PathDataRef)` instead of a Rust `FnOnce`
//! (the same duck-typing pattern as `visitStripFillSegments`). It returns
//! whatever `f` returns, including an error union. Upstream's
//! `push_root_viewport` takes the `FilterData` by reference and derives the
//! child viewport size from `source_padding`; `pop_root_viewport` restores the
//! parent generator before rebuilding the clip context.
//!
//! Error policy: `popRootViewport` returns `error.RootViewportStackUnderflow`
//! where upstream panics. `pushRootViewport`/`popRootViewport` propagate
//! `error.OutOfMemory` from the clip-context rebuild and roll the generator
//! stack back so the caller's state is unchanged. `reset` frees all stacked
//! generators and propagates `error.OutOfMemory` from the generator resize.
//!
//! Allocator contract: every owning type has an explicit
//! `init(allocator, ...)`/`deinit(allocator)` pair; operations that can grow a
//! buffer take the allocator explicitly.

const std = @import("std");
const simd = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const clip_mod = @import("clip.zig");
const filter_mod = @import("filter.zig");
const geometry = @import("geometry.zig");
const strip_generator = @import("strip_generator.zig");
const strip_storage = @import("strip_storage.zig");

const ClipState = clip_mod.ClipState;
const FilterData = filter_mod.FilterData;
const PathDataRef = strip_storage.PathDataRef;
const RectU16 = geometry.RectU16;
const StripGenerator = strip_generator.StripGenerator;

/// Errors from the viewport state (`ClipStackUnderflow` is not reachable from
/// the viewport API but is part of the shared clip error set).
pub const Error = clip_mod.Error;

/// Viewport state storing information about clip state and active strip
/// generators in currently active root viewports.
pub const ViewportState = struct {
    clip_state: ClipState,
    strip_generator: StripGenerator,
    strip_generator_stack: std.ArrayList(StripGenerator),
    level: simd.Level,

    /// Create a new viewport state.
    pub fn init(
        allocator: std.mem.Allocator,
        new_width: u16,
        new_height: u16,
        level: simd.Level,
    ) ViewportState {
        return .{
            .clip_state = ClipState.init(),
            .strip_generator = StripGenerator.init(allocator, new_width, new_height, level),
            .strip_generator_stack = .empty,
            .level = level,
        };
    }

    /// Release the clip state, the active generator, and all stacked
    /// generators.
    pub fn deinit(self: *ViewportState, allocator: std.mem.Allocator) void {
        self.clip_state.deinit(allocator);
        self.strip_generator.deinit(allocator);
        for (self.strip_generator_stack.items) |*generator| {
            generator.deinit(allocator);
        }
        self.strip_generator_stack.deinit(allocator);
        self.* = undefined;
    }

    /// Width of the active viewport.
    pub fn width(self: *const ViewportState) u16 {
        return self.strip_generator.width();
    }

    /// Height of the active viewport.
    pub fn height(self: *const ViewportState) u16 {
        return self.strip_generator.height();
    }

    /// Return the current clip path.
    pub fn clip(self: *const ViewportState) ?PathDataRef {
        return self.clip_state.get();
    }

    /// Whether any root viewports are currently pushed.
    pub fn hasRootViewports(self: *const ViewportState) bool {
        return self.strip_generator_stack.items.len != 0;
    }

    /// Use the active strip generator together with the current clip.
    ///
    /// `f` is called as `f(context, generator, clip)`; its return value
    /// (including an error union) is returned unchanged.
    pub fn withGeneratorAndClip(
        self: *ViewportState,
        context: anytype,
        f: anytype,
    ) @TypeOf(f(context, &self.strip_generator, @as(?PathDataRef, null))) {
        const clip_path = self.clip_state.get();
        return f(context, &self.strip_generator, clip_path);
    }

    /// Push a new clip path.
    pub fn pushClip(
        self: *ViewportState,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: peniko.Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) !void {
        try self.clip_state.pushClip(
            allocator,
            path,
            &self.strip_generator,
            fill_rule,
            transform,
            aliasing_threshold,
        );
    }

    /// Pop the last clip path.
    pub fn popClip(self: *ViewportState) !void {
        try self.clip_state.popClip();
    }

    /// Push a new root viewport.
    ///
    /// The active strip generator is replaced by a larger one that includes
    /// the filter's source padding, and the clip context is rebuilt for the
    /// accumulated source shift. On failure the parent generator is restored
    /// and the stack is unchanged.
    pub fn pushRootViewport(
        self: *ViewportState,
        allocator: std.mem.Allocator,
        filter_data: *const FilterData,
    ) Error!void {
        const padding = filter_data.source_padding;
        const new_width = self.strip_generator.width() +| padding.left +| padding.right;
        const new_height = self.strip_generator.height() +| padding.top +| padding.bottom;

        try self.strip_generator_stack.ensureUnusedCapacity(allocator, 1);

        const parent_generator = self.strip_generator;
        self.strip_generator = StripGenerator.init(allocator, new_width, new_height, self.level);
        self.clip_state.pushRootViewport(
            allocator,
            filter_data.sourceShift(),
            &self.strip_generator,
        ) catch |err| {
            // The filter generator may have grown buffers while rebuilding
            // the clip context; free them and restore the parent.
            self.strip_generator.deinit(allocator);
            self.strip_generator = parent_generator;
            return err;
        };
        self.strip_generator_stack.appendAssumeCapacity(parent_generator);
    }

    /// Pop the last root viewport.
    pub fn popRootViewport(self: *ViewportState, allocator: std.mem.Allocator) Error!void {
        const parent_generator = self.strip_generator_stack.pop() orelse
            return error.RootViewportStackUnderflow;

        var filter_generator = self.strip_generator;
        self.strip_generator = parent_generator;
        self.clip_state.popRootViewport(allocator, &self.strip_generator) catch |err| {
            filter_generator.deinit(allocator);
            return err;
        };
        filter_generator.deinit(allocator);
    }

    /// Reset strip generation and clipping for a new viewport.
    pub fn reset(
        self: *ViewportState,
        allocator: std.mem.Allocator,
        new_width: u16,
        new_height: u16,
    ) !void {
        self.clip_state.reset(allocator);

        for (self.strip_generator_stack.items) |*generator| {
            generator.deinit(allocator);
        }
        self.strip_generator_stack.clearRetainingCapacity();

        try self.strip_generator.reset(allocator, new_width, new_height);
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// Upstream `viewport.rs` has no `#[cfg(test)]`; these are the focused tests
// required by the port plan.
// ---------------------------------------------------------------------------

const testing = std.testing;
const filter_effects = @import("filter_effects.zig");

/// Closure context for `withGeneratorAndClip` tests.
const ClipProbe = struct {
    saw_clip: bool = false,
    generator_width: u16 = 0,

    fn run(self: *ClipProbe, generator: *StripGenerator, clip_path: ?PathDataRef) !void {
        self.saw_clip = clip_path != null;
        self.generator_width = generator.width();
    }
};

test "viewport with generator and clip" {
    const allocator = testing.allocator;

    var viewport = ViewportState.init(allocator, 32, 32, .baseline);
    defer viewport.deinit(allocator);

    try testing.expectEqual(@as(u16, 32), viewport.width());
    try testing.expectEqual(@as(u16, 32), viewport.height());
    try testing.expect(viewport.clip() == null);
    try testing.expect(!viewport.hasRootViewports());

    var probe = ClipProbe{};
    try viewport.withGeneratorAndClip(&probe, ClipProbe.run);
    try testing.expect(!probe.saw_clip);
    try testing.expectEqual(@as(u16, 32), probe.generator_width);

    var path = try kurbo.Rect.new(0.0, 0.0, 8.0, 8.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try viewport.pushClip(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    try testing.expect(viewport.clip() != null);

    var clipped_probe = ClipProbe{};
    try viewport.withGeneratorAndClip(&clipped_probe, ClipProbe.run);
    try testing.expect(clipped_probe.saw_clip);

    try viewport.popClip();
    try testing.expect(viewport.clip() == null);
}

test "viewport root padding and source shift" {
    const allocator = testing.allocator;

    const filter = try filter_effects.Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    var filter_data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer filter_data.deinit(allocator);

    // 3 * sigma = 9 snaps up to 12 on each side.
    try testing.expectEqual(@as(u16, 12), filter_data.source_padding.left);

    var viewport = ViewportState.init(allocator, 32, 32, .baseline);
    defer viewport.deinit(allocator);

    try viewport.pushRootViewport(allocator, &filter_data);
    try testing.expect(viewport.hasRootViewports());
    try testing.expectEqual(@as(u16, 32 + 12 + 12), viewport.width());
    try testing.expectEqual(@as(u16, 32 + 12 + 12), viewport.height());

    // A clip pushed inside the root viewport is shifted by the source
    // padding (12, 12).
    var path = try kurbo.Rect.new(0.0, 0.0, 8.0, 8.0).toPath(0.1, allocator);
    defer path.deinit(allocator);
    try viewport.pushClip(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const shifted = viewport.clip() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(12, 12, 24, 20), shifted.bbox);
    try viewport.popClip();

    try viewport.popRootViewport(allocator);
    try testing.expect(!viewport.hasRootViewports());
    try testing.expectEqual(@as(u16, 32), viewport.width());
    try testing.expectEqual(@as(u16, 32), viewport.height());
    try testing.expect(viewport.clip() == null);

    try testing.expectError(
        error.RootViewportStackUnderflow,
        viewport.popRootViewport(allocator),
    );
}

test "viewport reset resizes and clears" {
    const allocator = testing.allocator;

    const filter = try filter_effects.Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    var filter_data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer filter_data.deinit(allocator);

    var viewport = ViewportState.init(allocator, 32, 32, .baseline);
    defer viewport.deinit(allocator);

    var path = try kurbo.Rect.new(0.0, 0.0, 8.0, 8.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try viewport.pushClip(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    try viewport.pushRootViewport(allocator, &filter_data);
    try testing.expect(viewport.hasRootViewports());

    try viewport.reset(allocator, 48, 40);
    try testing.expectEqual(@as(u16, 48), viewport.width());
    try testing.expectEqual(@as(u16, 40), viewport.height());
    try testing.expect(!viewport.hasRootViewports());
    try testing.expect(viewport.clip() == null);

    // The reset viewport is reusable.
    try viewport.pushClip(
        allocator,
        path.elementsSlice(),
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    try testing.expect(viewport.clip() != null);
}
