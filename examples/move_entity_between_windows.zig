//! Port of GPUI's `examples/move_entity_between_windows.rs`.
//!
//! An entity registers callbacks, then gets re-hosted in a new window by a click. The callbacks
//! that run after the move must reach the entity's *current* window, not the one it was in when
//! they were registered.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - No async: the tick task is a chain of one-second timers on the background executor, each
//!   one running on the main thread and re-arming itself. It stops when the entity is in no
//!   window (GPUI stops when the update fails, which is when the entity is released).
//! - The tick and the move look up the entity's current window with `App.window_for_entity`,
//!   which finds the window that drew the entity last. `subscribe_in` does the same for its
//!   callback. GPUI's `window.window_handle()` is `Window.window_handle()`, and `update_in`
//!   becomes `Entity.update` with the window passed as an argument.
//! - `open_window` and `defer` take plain functions that cannot capture, so the entity and the
//!   window being moved go through `moving` and `moved_entity`. Both are read synchronously.
//! - Closing the old window keeps the entity alive, as the new window still shows it. The
//!   `window.remove_window()` of the old window runs through `AnyWindowHandle.update`.
//! - Ticks are printed with `std.debug.print`, as `println!` is in the Rust code.
//! - The tick count is written but not redrawn on its own, as in GPUI: the rendered count
//!   changes when something else redraws the window.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnyWindowHandle = gpui.AnyWindowHandle;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const MouseDownEvent = gpui.MouseDownEvent;
const Pixels = gpui.Pixels;
const Subscription = gpui.Subscription;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const ONE_SECOND_NS: u64 = 1_000_000_000;

const MoveToNewWindow = struct {};

const HelloWorld = struct {
    pub const Event = MoveToNewWindow;

    text: []const u8,
    tick_count: u32,
    move_count: u32,
    _subscriptions: ?Subscription = null,

    /// Registers the move callback in the window the entity is shown in.
    fn setup(self: *HelloWorld, window: *Window, cx: *Context(HelloWorld)) void {
        self._subscriptions = cx.subscribe_in(cx.entity(), window, on_move_to_new_window);
    }

    fn on_move_to_new_window(self: *HelloWorld, _: Entity(HelloWorld), _: *const MoveToNewWindow, window: *Window, cx: *Context(HelloWorld)) void {
        const entered_window_id = window.window_handle().window_id().as_u64();
        std.debug.print("MoveToNewWindow handler fired in entity's current window {d}\n", .{entered_window_id});

        self.move_count += 1;
        cx.notify();

        moving = .{ .entity = cx.entity(), .old_window = window.window_handle() };
        cx.defer_(open_moved_window);
    }

    fn tick_once(self: *HelloWorld, window: *Window, _: *Context(HelloWorld)) void {
        self.tick_count += 1;
        std.debug.print("tick #{d} fired in entity's current window {d}\n", .{
            self.tick_count,
            window.window_handle().window_id().as_u64(),
        });
    }

    fn on_move_click(_: *HelloWorld, _: *const MouseDownEvent, _: *Window, cx: *Context(HelloWorld)) void {
        cx.emit(MoveToNewWindow{});
    }

    pub fn render(self: *HelloWorld, window: *Window, cx: *Context(HelloWorld)) *Div {
        const window_id = window.window_handle().window_id().as_u64();

        return div()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0x505050))
            .size(px(500.0))
            .justify_center()
            .items_center()
            .text_xl()
            .text_color(rgb(0xffffff))
            .child(gpui.format("Hello, {s}!", .{self.text}))
            .child(gpui.format("Rendering in window: {d}", .{window_id}))
            .child(gpui.format("Ticks observed by entity: {d}", .{self.tick_count}))
            .child(gpui.format("Moves observed by entity: {d}", .{self.move_count}))
            .child(
                div()
                    .px_4()
                    .py_2()
                    .bg(rgb(0x4040ff))
                    .rounded_md()
                    .child("Move me to a new window")
                    .on_mouse_down(gpui.MouseButton.left, cx.listener(HelloWorld.on_move_click)),
            );
    }
};

/// The entity and window of the move in progress, read by `open_moved_window`.
var moving: struct { entity: Entity(HelloWorld), old_window: AnyWindowHandle } = undefined;
/// The entity the window builder returns for the moved window.
var moved_entity: Entity(HelloWorld) = undefined;

fn open_moved_window(cx: *App) void {
    moved_entity = moving.entity;
    const bounds = Bounds(Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
    }, return_moved_entity) catch unreachable;
    moving.old_window.update(cx, close_window, .{}) catch {};
}

fn return_moved_entity(_: *Window, _: *App) Entity(HelloWorld) {
    return moved_entity;
}

fn close_window(window: *Window, _: *App) void {
    window.remove_window();
}

fn build_first_window(window: *Window, app: *App) Entity(HelloWorld) {
    const entity = app.new(HelloWorld{ .text = "World", .tick_count = 0, .move_count = 0 });
    entity.update(app, HelloWorld.setup, .{window});
    start_ticking(app, entity);
    return entity;
}

const Ticker = struct {
    app: *App,
    entity: Entity(HelloWorld),
};

fn start_ticking(app: *App, entity: Entity(HelloWorld)) void {
    app.background_executor().after(app.foreground_executor(), ONE_SECOND_NS, tick, Ticker{ .app = app, .entity = entity });
}

fn tick(ticker: Ticker) void {
    const window = ticker.app.window_for_entity(ticker.entity.entity_id()) orelse {
        std.debug.print("tick task giving up: entity is not in any window\n", .{});
        return;
    };
    ticker.entity.update(ticker.app, HelloWorld.tick_once, .{window});
    start_ticking(ticker.app, ticker.entity);
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
    }, build_first_window) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
