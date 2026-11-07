//! Port of GPUI's `examples/mouse_pressure.rs`.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - No ZUI platform emits `MousePressureEvent` yet. GPUI only reports pressure from macOS
//!   trackpads, so on Linux the box keeps showing "Zero" and 0.00. Press with a force-touch
//!   trackpad on macOS once that platform exists.
//! - `{:?}` on `PressureStage` prints `Zero`, `Normal` or `Force` in Rust. `stage_name` does the
//!   same, since Zig's `@tagName` would print lowercase.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const MousePressureEvent = gpui.MousePressureEvent;
const PressureStage = gpui.PressureStage;
const Pixels = gpui.Pixels;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const MousePressureExample = struct {
    pressure_stage: PressureStage,
    pressure_amount: f32,

    fn stage_name(stage: PressureStage) []const u8 {
        return switch (stage) {
            .zero => "Zero",
            .normal => "Normal",
            .force => "Force",
        };
    }

    pub fn render(self: *MousePressureExample, _: *Window, cx: *Context(MousePressureExample)) *Div {
        return div()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0x505050))
            .size(px(500.0))
            .justify_center()
            .items_center()
            .shadow_lg()
            .border_1()
            .border_color(rgb(0x0000ff))
            .text_xl()
            .text_color(rgb(0xffffff))
            .child(gpui.format("Pressure stage: {s}", .{stage_name(self.pressure_stage)}))
            .child(gpui.format("Pressure amount: {d:.2}", .{self.pressure_amount}))
            .on_mouse_pressure(cx.listener(on_mouse_pressure));
    }

    fn on_mouse_pressure(self: *MousePressureExample, pressure_event: *const MousePressureEvent, _: *Window, cx: *Context(MousePressureExample)) void {
        self.pressure_amount = pressure_event.pressure;
        self.pressure_stage = pressure_event.stage;

        cx.notify();
    }
};

fn build_root(_: *Window, app: *App) gpui.Entity(MousePressureExample) {
    return app.new(MousePressureExample{
        .pressure_stage = .zero,
        .pressure_amount = 0.0,
    });
}

fn run_example(cx: *App) void {
    const bounds = Bounds(Pixels).centered(null, size(px(500.0), px(500.0)), cx);

    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
    }, build_root) catch unreachable;

    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
