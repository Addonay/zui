//! Public custom-element companion (gap report §6A): the thin `Canvas` over
//! `Scene` pushes for use inside `CustomVTable.paint`, plus the typed
//! `define()` vtable constructor so external packages never hand-write the
//! type-erased signatures.
//!
//! ## Lifetime (load-bearing)
//!
//! - The STATE lives app-side (a struct, an entity payload) and MUST outlive
//!   every frame it is used in. ZUI holds only the pointer + vtable and
//!   never frees the state.
//! - `teardown` runs once per built custom node at `endFrame()`. It releases
//!   per-frame retained resources; it does not (and must not) free the
//!   state itself.
//! - Entity-owned states should register with `element.trackEntityOwner` at
//!   mint time so hit regions gate on liveness like built-in listeners.
//! - Paint hooks must not reset, rebuild, or otherwise invalidate the frame
//!   they are given (appending nodes is tolerated but the additions are
//!   unlaid-out and unpainted that frame).
//!
//! ## Canvas scope
//!
//! `Canvas` is one checked `Scene` push per method with the hook's clip
//! attached — fills, gradients, rings, and a raw glyph escape. It is not a
//! renderer: overflow stays a counted drop + frame rejection, exactly like
//! built-in paint. Shaped text should compose a `text()` child element;
//! `glyph()` exists only for pre-rasterized marks whose atlas entry the
//! caller already owns.

const std = @import("std");
const core = @import("../core/root.zig");
const element = @import("element.zig");
const scene_mod = @import("../gpu/scene.zig");

pub const Canvas = struct {
    scene: *scene_mod.Scene,
    clip: core.Rect,

    pub fn init(scene: *scene_mod.Scene, clip: core.Rect) Canvas {
        return .{ .scene = scene, .clip = clip };
    }

    fn visible(self: *const Canvas, bounds: core.Rect) bool {
        if (bounds.w <= 0 or bounds.h <= 0) return false;
        const x = @max(bounds.x, self.clip.x);
        const y = @max(bounds.y, self.clip.y);
        const right = @min(bounds.x + bounds.w, self.clip.x + self.clip.w);
        const bottom = @min(bounds.y + bounds.h, self.clip.y + self.clip.h);
        return right > x and bottom > y;
    }

    /// Solid rounded rect. Skips empty, transparent, and fully-clipped
    /// draws like the built-in painter.
    pub fn fillRect(self: *Canvas, bounds: core.Rect, color: core.Color, radius: f32) void {
        if (color.a <= 0 or !self.visible(bounds)) return;
        _ = self.scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = color, .radius = radius, .clip = self.clip });
    }

    /// Horizontal gradient rect (same single-quad semantics as `bg_gradient`).
    pub fn gradientRect(self: *Canvas, bounds: core.Rect, from: core.Color, to: core.Color, radius: f32) void {
        if (from.a <= 0 and to.a <= 0) return;
        if (!self.visible(bounds)) return;
        _ = self.scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = from, .gradient_to = to, .radius = radius, .clip = self.clip });
    }

    /// Rounded-rect outline (same ring semantics as built-in borders).
    pub fn ring(self: *Canvas, bounds: core.Rect, color: core.Color, width: f32, radius: f32) void {
        if (color.a <= 0 or width <= 0 or !self.visible(bounds)) return;
        _ = self.scene.push(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .color = color, .radius = radius, .border_width = width, .clip = self.clip });
    }

    /// Raw glyph escape for pre-rasterized marks: pushes one scene glyph at
    /// the caller's atlas entry. For shaped text, compose a `text()` child
    /// instead — this performs no shaping, fallback, or rasterization.
    pub fn glyph(self: *Canvas, x: f32, y: f32, w: u32, h: u32, color: core.Color, atlas_offset: u32) void {
        if (w == 0 or h == 0 or color.a <= 0) return;
        _ = self.scene.pushGlyph(.{ .x = x, .y = y, .w = w, .h = h, .color = color, .atlas_offset = atlas_offset, .clip = self.clip });
    }
};

/// Typed vtable constructor. `Impl` declares:
///   `measure(*State, *element.Frame) core.Size`
///   `paint(*State, *element.Frame, u16, core.Rect, *Scene, core.Rect) void`
/// and optionally:
///   `prepaint(*State, *element.Frame, u16, core.Rect, core.Rect) void`
///   `teardown(*State) void`
/// Returns a static erased vtable (no allocation); the state pointer passed
/// to `element.custom` must be a `*State` (it coerces to `*anyopaque`) that
/// outlives the frame.
pub fn define(comptime State: type, comptime Impl: type) *const element.CustomVTable {
    const Thunks = struct {
        fn measure(state: *anyopaque, frame: *element.Frame) core.Size {
            const s: *State = @ptrCast(@alignCast(state));
            return Impl.measure(s, frame);
        }
        fn prepaint(state: *anyopaque, frame: *element.Frame, index: u16, bounds: core.Rect, clip: core.Rect) void {
            const s: *State = @ptrCast(@alignCast(state));
            Impl.prepaint(s, frame, index, bounds, clip);
        }
        fn paint(state: *anyopaque, frame: *element.Frame, index: u16, bounds: core.Rect, scene: *scene_mod.Scene, clip: core.Rect) void {
            const s: *State = @ptrCast(@alignCast(state));
            Impl.paint(s, frame, index, bounds, scene, clip);
        }
        fn teardown(state: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(state));
            Impl.teardown(s);
        }
    };
    const holder = struct {
        const vtable: element.CustomVTable = .{
            .measure = Thunks.measure,
            .prepaint = if (@hasDecl(Impl, "prepaint")) Thunks.prepaint else null,
            .paint = Thunks.paint,
            .teardown = if (@hasDecl(Impl, "teardown")) Thunks.teardown else null,
        };
    };
    return &holder.vtable;
}

// ---------------------------------------------------------------------------
// Headless lifecycle tests (gap §6A exit-gate behaviors, no engine needed).
// ---------------------------------------------------------------------------

const TestState = struct {
    prepaint_calls: u32 = 0,
    paint_calls: u32 = 0,
    teardown_calls: u32 = 0,
    clicks: u32 = 0,
    seen_bounds: core.Rect = .{},
};

const TestImpl = struct {
    pub fn measure(state: *TestState, frame: *element.Frame) core.Size {
        _ = state;
        _ = frame;
        return .{ .w = 50, .h = 20 };
    }

    pub fn prepaint(state: *TestState, frame: *element.Frame, index: u16, bounds: core.Rect, clip: core.Rect) void {
        _ = clip;
        state.prepaint_calls += 1;
        state.seen_bounds = bounds;
        // Viewport-dependent work through the same public paths as
        // built-ins: own-node listener + semantic binding for own index.
        frame.nodes[index].mouse_down_listener = .{ .target = state, .call_fn = onDown };
        const el: element.Element = .{ .index = index, .generation = frame.generation };
        _ = el.semantic(.{ .role = .group, .name = "chart" });
    }

    fn onDown(target: *anyopaque, _: *const element.ListenerPayload, _: *anyopaque) void {
        const s: *TestState = @ptrCast(@alignCast(target));
        s.clicks += 1;
    }

    pub fn paint(state: *TestState, frame: *element.Frame, index: u16, bounds: core.Rect, scene: *scene_mod.Scene, clip: core.Rect) void {
        _ = frame;
        _ = index;
        state.paint_calls += 1;
        var canvas = Canvas.init(scene, clip);
        canvas.fillRect(bounds, core.Color.hex(0x112233), 0);
        canvas.fillRect(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w / 2, .h = bounds.h }, core.Color.hex(0x445566), 0);
    }

    pub fn teardown(state: *TestState) void {
        state.teardown_calls += 1;
    }
};

var test_owner_alive = true;

fn testOwnerAlive(_: *anyopaque, _: u32, _: u32) bool {
    return test_owner_alive;
}

fn clickTarget(target: *anyopaque, _: *const element.ListenerPayload, _: *anyopaque) void {
    const s: *TestState = @ptrCast(@alignCast(target));
    s.clicks += 1;
}

test "custom element full lifecycle: measure, prepaint, ordered paint, hit dispatch, semantics, teardown" {
    const t = std.testing;
    const gpu = @import("../gpu/root.zig");
    const layout = @import("layout.zig");
    const painter = @import("painter.zig");

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.allocator = t.allocator;

    // Entity-backed owner gating: register the state before paint, then
    // flip liveness and confirm the region gate follows it.
    const prev_alive = element.entity_is_alive_fn;
    element.entity_is_alive_fn = &testOwnerAlive;
    defer element.entity_is_alive_fn = prev_alive;
    test_owner_alive = true;
    defer test_owner_alive = true;

    element.beginFrame(frame);
    // endFrame must run even when an assertion below fails: it both closes
    // the build scope and fires custom teardown, and a leaked open frame
    // trips the next test's beginFrame.
    errdefer element.endFrame();

    var st = TestState{};
    const vt = define(TestState, TestImpl);
    try t.expect(vt.prepaint != null);
    try t.expect(vt.teardown != null);

    var store_token: u8 = 0;
    element.trackEntityOwner(@ptrCast(&st), &store_token, 5, 9);

    const root = element.div().w(200).h(100)
        .child(element.custom(&st, vt).keyed(4242).on_click(.{ .target = @ptrCast(&st), .call_fn = clickTarget }))
        .child(element.div().w(200).h(10).bg(core.Color.hex(0xffffff)));
    layout.layout(frame, root, .{ .w = 200, .h = 100 });

    // Intrinsic measurement: 50x20 at the container origin.
    const custom_index = frame.nodes[root.index].first_child.?;
    const custom_node = &frame.nodes[custom_index];
    try t.expectEqual(element.NodeKind.custom, custom_node.kind);
    try t.expectApproxEqAbs(@as(f32, 50), custom_node.measured.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 20), custom_node.measured.h, 0.001);
    try t.expectApproxEqAbs(@as(f32, 50), custom_node.bounds.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 20), custom_node.bounds.h, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0), custom_node.bounds.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0), custom_node.bounds.y, 0.001);

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    painter.paint(frame, root, scene);

    // Prepaint ran once with final bounds, before paint.
    try t.expectEqual(@as(u32, 1), st.prepaint_calls);
    try t.expectEqual(@as(u32, 1), st.paint_calls);
    try t.expectApproxEqAbs(@as(f32, 50), st.seen_bounds.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 20), st.seen_bounds.h, 0.001);

    // Ordered paint: two custom quads, then the trailing sibling's quad.
    const quads = scene.slice();
    try t.expectEqual(@as(usize, 3), quads.len);
    try t.expectApproxEqAbs(@as(f32, 50), quads[0].w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 20), quads[0].h, 0.001);
    try t.expectApproxEqAbs(@as(f32, 25), quads[1].w, 0.001);
    try t.expect(quads[0].color.r != quads[1].color.r or quads[0].color.g != quads[1].color.g or quads[0].color.b != quads[1].color.b);
    try t.expectApproxEqAbs(@as(f32, 10), quads[2].h, 0.001);
    // Paint-order stream agrees: all three quads in emission order.
    const cmds = scene.commandSlice();
    try t.expectEqual(@as(usize, 3), cmds.len);
    for (cmds) |c| try t.expectEqual(scene_mod.CommandKind.quad, c.kind);

    // Hit dispatch: the custom node installed a mouse-down listener in
    // prepaint AND carries a build-time on_click; both fire through the
    // same region machinery as built-ins.
    var custom_region: ?element.HitRegion = null;
    for (frame.regions[0..frame.region_count]) |r| {
        if (r.mouse_down_listener) |l| {
            if (l.target == @as(*anyopaque, @ptrCast(&st))) custom_region = r;
        }
    }
    const region = custom_region orelse return error.TestExpectedHit;
    try t.expect(region.bounds.contains(.{ .x = 5, .y = 5 }));
    region.mouse_down_listener.?.call(@ptrFromInt(1));
    try t.expectEqual(@as(u32, 1), st.clicks);
    region.listener.?.call(@ptrFromInt(1));
    try t.expectEqual(@as(u32, 2), st.clicks);

    // Owner gating follows the entity table, not the raw target.
    try t.expectEqual(@as(u32, 5), region.owner_id);
    try t.expectEqual(@as(u32, 9), region.owner_generation);
    try t.expect(region.ownerAlive());
    test_owner_alive = false;
    try t.expect(!region.ownerAlive());

    // Semantics: prepaint's binding reached the same tree as built-ins.
    const found = frame.semantic_tree.find(4242) orelse return error.TestExpectedSemantic;
    try t.expectEqual(@import("../a11y/root.zig").Role.group, found.properties.role);
    try t.expectEqualStrings("chart", found.properties.name);

    // Teardown runs once at frame end; state memory stays valid (app-owned).
    try t.expectEqual(@as(u32, 0), st.teardown_calls);
    element.endFrame();
    try t.expectEqual(@as(u32, 1), st.teardown_calls);
    try t.expectEqual(@as(u32, 2), st.clicks); // state untouched by teardown
}

test "custom element without hooks renders as an empty container" {
    const t = std.testing;
    const gpu = @import("../gpu/root.zig");
    const layout = @import("layout.zig");
    const painter = @import("painter.zig");

    const Bare = struct {
        pub fn measure(_: *@This(), _: *element.Frame) core.Size {
            return .{ .w = 30, .h = 10 };
        }
        pub fn paint(_: *@This(), _: *element.Frame, _: u16, _: core.Rect, _: *scene_mod.Scene, _: core.Rect) void {}
    };
    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();

    var bare: Bare = .{};
    const vt = define(Bare, Bare);
    try t.expect(vt.prepaint == null);
    try t.expect(vt.teardown == null);

    const root = element.div().w(100).h(100).child(element.custom(&bare, vt));
    layout.layout(frame, root, .{ .w = 100, .h = 100 });
    const idx = frame.nodes[root.index].first_child.?;
    try t.expectApproxEqAbs(@as(f32, 30), frame.nodes[idx].bounds.w, 0.001);

    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    painter.paint(frame, root, scene);
    try t.expectEqual(@as(usize, 0), scene.slice().len);
    try t.expectEqual(@as(usize, 0), frame.region_count);
}

test "custom canvas primitives push checked quads with the hook clip" {
    const t = std.testing;
    const gpu = @import("../gpu/root.zig");
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    var canvas = Canvas.init(scene, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    canvas.fillRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, core.Color.hex(0xffffff), 2);
    canvas.gradientRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, core.Color.hex(0x000000), core.Color.hex(0xffffff), 0);
    canvas.ring(.{ .x = 1, .y = 1, .w = 8, .h = 8 }, core.Color.hex(0xffffff), 1, 3);
    // Degenerate draws are skipped, never pushed.
    canvas.fillRect(.{ .x = 0, .y = 0, .w = 0, .h = 5 }, core.Color.hex(0xffffff), 0);
    canvas.fillRect(.{ .x = 50, .y = 50, .w = 5, .h = 5 }, core.Color.hex(0xffffff), 0);
    canvas.fillRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, core.Color.transparent, 0);
    try t.expectEqual(@as(usize, 3), scene.slice().len);
    try t.expectApproxEqAbs(@as(f32, 2), scene.slice()[0].radius, 0.001);
    try t.expect(scene.slice()[1].gradient_to != null);
    try t.expectApproxEqAbs(@as(f32, 1), scene.slice()[2].border_width, 0.001);
    try t.expect(!scene.overflowed());
}
