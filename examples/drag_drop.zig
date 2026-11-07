//! Port of GPUI's `examples/drag_drop.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Hsla = gpui.Hsla;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const Window = gpui.Window;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const DragInfo = struct {
    ix: usize,
    color: Hsla,
    position: Point(Pixels) = .{ .x = 0, .y = 0 },

    fn new(ix: usize, color: Hsla) DragInfo {
        return .{ .ix = ix, .color = color };
    }

    fn with_position(self: DragInfo, pos: Point(Pixels)) DragInfo {
        var out = self;
        out.position = pos;
        return out;
    }

    pub fn render(self: *DragInfo, _: *Window, _: *Context(DragInfo)) *gpui.Div {
        const item_size = gpui.size(px(120.0), px(50.0));
        return div()
            .pl(self.position.x - item_size.width / 2)
            .pt(self.position.y - item_size.height / 2)
            .child(
                div()
                    .flex()
                    .justify_center()
                    .items_center()
                    .w(item_size.width)
                    .h(item_size.height)
                    .bg(self.color.opacity(0.5))
                    .text_color(gpui.white())
                    .text_xs()
                    .shadow_md()
                    .child(gpui.format("Item {d}", .{self.ix})),
            );
    }
};

const DragDrop = struct {
    drop_on: ?DragInfo = null,

    fn make_preview(info: *const DragInfo, position: Point(Pixels), _: *Window, cx: *App) gpui.Entity(DragInfo) {
        return cx.new(info.with_position(position));
    }

    fn on_drop_item(self: *DragDrop, info: *const DragInfo, _: *Window, _: *Context(DragDrop)) void {
        self.drop_on = info.*;
    }

    pub fn render(self: *DragDrop, _: *Window, cx: *Context(DragDrop)) *gpui.Div {
        const items = [_]Hsla{ gpui.blue(), gpui.red(), gpui.green() };

        const row = div()
            .w_full()
            .mb_10()
            .justify_center()
            .flex()
            .flex_row()
            .gap_4()
            .items_center();
        for (items, 0..) |item_color, ix| {
            _ = row.child(
                div()
                    .id(.{ "item", ix })
                    .size_32()
                    .flex()
                    .justify_center()
                    .items_center()
                    .border_2()
                    .border_color(item_color)
                    .text_color(item_color)
                    .cursor_move()
                    .hover(gpui.style_refinement().bg(item_color.opacity(0.2)))
                    .child(gpui.format("Item ({d})", .{ix}))
                    .on_drag(DragInfo.new(ix, item_color), make_preview),
            );
        }

        const target = div()
            .id("drop-target")
            .w_128()
            .h_32()
            .flex()
            .justify_center()
            .items_center()
            .border_3()
            .border_color(if (self.drop_on) |info| info.color else gpui.black())
            .on_drop(DragInfo, cx.listener(on_drop_item))
            .child("Drop items here");
        if (self.drop_on) |info| _ = target.bg(info.color.opacity(0.5));

        return div()
            .size_full()
            .flex()
            .flex_col()
            .gap_5()
            .bg(gpui.white())
            .justify_center()
            .items_center()
            .text_color(rgb(0x333333))
            .child(div().text_xl().text_center().child("Drop & Drop"))
            .child(row)
            .child(target);
    }
};

fn run_example(cx: *App) void {
    const bounds = Bounds(Pixels).centered(null, size(px(800.0), px(600.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(DragDrop) {
            return app.new(DragDrop{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
