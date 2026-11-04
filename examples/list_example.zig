//! Port of GPUI's `examples/list_example.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const ListAlignment = gpui.ListAlignment;
const ListState = gpui.ListState;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const list = gpui.list;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const ITEM_COUNT: usize = 40;
const SCROLLBAR_WIDTH: f32 = 12.0;

const BottomListDemo = struct {
    list_state: ListState,

    fn new() BottomListDemo {
        return .{
            .list_state = ListState.new(ITEM_COUNT, ListAlignment.bottom, px(500.0)).measure_all(),
        };
    }

    fn render_item(_: *BottomListDemo, index: usize, _: *Window, _: *Context(BottomListDemo)) AnyElement {
        const height = px(30.0 + @as(f32, @floatFromInt(index % 5)) * 10.0);
        return gpui.into_any_element(
            div()
                .h(height)
                .w_full()
                .flex()
                .items_center()
                .px_3()
                .border_b_1()
                .border_color(rgb(0xEEEEEE))
                .bg(if (index % 2 == 0) rgb(0xFAFAFA) else rgb(0xFFFFFF))
                .text_sm()
                .child(gpui.format("Item {d}", .{index})),
        );
    }

    pub fn render(self: *BottomListDemo, _: *Window, cx: *Context(BottomListDemo)) *gpui.Div {
        const max_offset = self.list_state.max_offset_for_scrollbar().y;
        const current_offset = -self.list_state.scroll_px_offset_for_scrollbar().y;

        const viewport_height = self.list_state.viewport_bounds().size.height;

        const raw_fraction: f32 = if (max_offset > px(0.0))
            current_offset / max_offset
        else
            0.0;

        const total_height = viewport_height + max_offset;
        const thumb_height = if (total_height > px(0.0))
            @max(px(viewport_height * viewport_height / total_height), px(30.0))
        else
            px(30.0);

        const track_space = viewport_height - thumb_height;
        const thumb_top = track_space * raw_fraction;

        const bug_detected = raw_fraction > 1.0;

        const status: []const u8 = if (bug_detected)
            gpui.format("BUG: fraction is {d:.3} (> 1.0) — thumb is off-track!", .{raw_fraction})
        else
            "OK: fraction <= 1.0 — thumb is within track.";

        return div()
            .size_full()
            .bg(rgb(0xFFFFFF))
            .flex()
            .flex_col()
            .p_4()
            .gap_2()
            .child(
                div()
                    .text_sm()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(gpui.format("offset: {d:.0} / max: {d:.0} | fraction: {d:.3}", .{
                        current_offset,
                        max_offset,
                        raw_fraction,
                    }))
                    .child(
                        div()
                            .text_color(if (bug_detected) rgb(0xCC0000) else rgb(0x008800))
                            .child(status),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_row()
                    .overflow_hidden()
                    .border_1()
                    .border_color(rgb(0xCCCCCC))
                    .rounded_sm()
                    .child(
                        list(self.list_state, cx.item_processor(render_item)).flex_1(),
                    )
                    // Scrollbar track
                    .child(
                        div()
                            .w(px(SCROLLBAR_WIDTH))
                            .h_full()
                            .flex_shrink_0()
                            .bg(rgb(0xE0E0E0))
                            .relative()
                            .child(
                                // Thumb — position is unclamped to expose the bug
                                div()
                                    .absolute()
                                    .top(thumb_top)
                                    .w_full()
                                    .h(thumb_height)
                                    .bg(if (bug_detected) rgb(0xCC0000) else rgb(0x888888))
                                    .rounded_sm(),
                            ),
                    ),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(400.0), px(500.0)), cx);
    _ = cx.open_window(.{ .focus = true, .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(BottomListDemo) {
            return app.new(BottomListDemo.new());
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
