//! Port of GPUI `elements/canvas.rs`: an element for low-level custom painting
//! without defining a whole element type. Its style only affects layout.

const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const styled_mod = @import("../styled.zig");
const taffy = @import("../taffy.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;

/// Builds a canvas whose `prepaint_fn(ctx, bounds, window, cx) P` runs during prepaint
/// and whose `paint_fn(ctx, bounds, *P, window, cx)` runs during paint. `ctx` is copied
/// into the frame arena. GPUI's `prepaint` closure is `prepaint_fn`, `paint` is `paint_fn`.
pub fn canvas(ctx: anytype, comptime prepaint_fn: anytype, comptime paint_fn: anytype) *Canvas(@TypeOf(ctx), CanvasCallbacks(@TypeOf(ctx), prepaint_fn, paint_fn)) {
    const Ctx = @TypeOf(ctx);
    const Element = Canvas(Ctx, CanvasCallbacks(Ctx, prepaint_fn, paint_fn));
    const element = window_mod.frame_arena().create(Element) catch @panic("out of memory");
    element.* = .{ .ctx = ctx };
    return element;
}

/// Builds a canvas that only paints, for `paint_fn(ctx, bounds, window, cx)`.
pub fn canvas_fn(ctx: anytype, comptime paint_fn: anytype) *Canvas(@TypeOf(ctx), PaintOnly(@TypeOf(ctx), paint_fn)) {
    const Ctx = @TypeOf(ctx);
    const Element = Canvas(Ctx, PaintOnly(Ctx, paint_fn));
    const element = window_mod.frame_arena().create(Element) catch @panic("out of memory");
    element.* = .{ .ctx = ctx };
    return element;
}

/// The callbacks of a canvas, adapted to the element protocol.
fn CanvasCallbacks(comptime Ctx: type, comptime prepaint_fn: anytype, comptime paint_fn: anytype) type {
    const P = @typeInfo(@TypeOf(prepaint_fn)).@"fn".return_type.?;
    return struct {
        pub const PrepaintState = P;

        pub fn prepaint(ctx: Ctx, bounds: Bounds(Pixels), window: *Window, cx: *App) P {
            return prepaint_fn(ctx, bounds, window, cx);
        }

        pub fn paint(ctx: Ctx, bounds: Bounds(Pixels), state: *P, window: *Window, cx: *App) void {
            paint_fn(ctx, bounds, state, window, cx);
        }
    };
}

/// Hooks for `canvas_fn`: no prepaint state.
fn PaintOnly(comptime Ctx: type, comptime paint_fn: anytype) type {
    return struct {
        pub const PrepaintState = void;

        pub fn prepaint(_: Ctx, _: Bounds(Pixels), _: *Window, _: *App) void {}

        pub fn paint(ctx: Ctx, bounds: Bounds(Pixels), _: *void, window: *Window, cx: *App) void {
            paint_fn(ctx, bounds, window, cx);
        }
    };
}

/// A canvas element holding its context and its callbacks (GPUI `Canvas<T>`).
pub fn Canvas(comptime Ctx: type, comptime Callbacks: type) type {
    return struct {
        const Self = @This();
        const StyledM = styled_mod.Styled(*Self);

        pub const RequestLayoutState = void;
        pub const PrepaintState = Callbacks.PrepaintState;

        ctx: Ctx,
        style_refinement: StyleRefinement = .{},

        pub fn style(self: *Self) *StyleRefinement {
            return &self.style_refinement;
        }

        // Core sizing and positioning methods from GPUI's `Styled`; canvas only uses style for layout.
        pub const size = StyledM.size;
        pub const size_full = StyledM.size_full;
        pub const w = StyledM.w;
        pub const h = StyledM.h;
        pub const w_full = StyledM.w_full;
        pub const h_full = StyledM.h_full;
        pub const min_size = StyledM.min_size;
        pub const min_w = StyledM.min_w;
        pub const min_h = StyledM.min_h;
        pub const max_size = StyledM.max_size;
        pub const max_w = StyledM.max_w;
        pub const max_h = StyledM.max_h;
        pub const flex_1 = StyledM.flex_1;
        pub const flex_grow = StyledM.flex_grow;
        pub const flex_shrink = StyledM.flex_shrink;
        pub const relative = StyledM.relative;
        pub const absolute = StyledM.absolute;
        pub const inset_0 = StyledM.inset_0;

        pub fn request_layout(self: *Self, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
            var style_value: Style = .{};
            style_value.refine(&self.style_refinement);
            return .{ window.request_layout(&style_value, &.{}, cx), {} };
        }

        pub fn prepaint(self: *Self, _: ?*const GlobalElementId, bounds: Bounds(Pixels), _: *void, window: *Window, cx: *App) PrepaintState {
            return Callbacks.prepaint(self.ctx, bounds, window, cx);
        }

        pub fn paint(self: *Self, _: ?*const GlobalElementId, bounds: Bounds(Pixels), _: *void, state: *PrepaintState, window: *Window, cx: *App) void {
            Callbacks.paint(self.ctx, bounds, state, window, cx);
        }
    };
}
