# ZUI

GPUI — the GPU-accelerated UI framework behind the Zed editor — ported to Zig.

ZUI keeps GPUI's design and API: an `App` that owns all state in entities,
views that `render` a tree of elements each frame, a Tailwind-style `Styled`
builder, flexbox/grid layout, actions and key bindings, focus, and a scene of
GPU primitives. If you know GPUI, you know ZUI:

```zig
const gpui = @import("zui");
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;

const HelloWorld = struct {
    text: []const u8,

    pub fn render(self: *HelloWorld, _: *gpui.Window, _: *gpui.Context(HelloWorld)) *gpui.Div {
        return div()
            .flex()
            .bg(rgb(0x505050))
            .size(px(500.0))
            .justify_center()
            .items_center()
            .text_xl()
            .text_color(rgb(0xffffff))
            .child(gpui.format("Hello, {s}!", .{self.text}));
    }
};

pub fn main() void {
    gpui.Application.new().run(struct {
        fn run(cx: *gpui.App) void {
            const bounds = gpui.Bounds(gpui.Pixels).centered(null, gpui.size(px(500), px(500)), cx);
            _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
                fn build(_: *gpui.Window, app: *gpui.App) gpui.Entity(HelloWorld) {
                    return app.new(HelloWorld{ .text = "World" });
                }
            }.build) catch unreachable;
        }
    }.run);
}
```

## Differences from GPUI

Zig has no closures, traits or `async`, so a few things read differently:

- Listeners: `cx.listener(Self.on_click)` where `on_click(self, event, window, cx)`;
  capture extra data with `cx.listener_with(data, f)`.
- Styles for states take a style builder: `.hover(gpui.style_refinement().bg(gpui.red()))`.
- `entity.update(cx, T.method, .{args})` instead of a closure.
- Background work: `cx.background_executor().spawn(f, args)` returns a `Task(T)`.
- Element text: `gpui.format("...", .{...})` allocates in the frame arena.
- Entities are released explicitly (`entity.release(cx)`); windows release their root view.

## Building

Requires Zig 0.17.0.

```sh
zig build test              # unit tests
zig build run-hello_world   # run an example
ZUI_HEADLESS=1 zig build run-hello_world
```

Dependencies: [cozmic](https://github.com/Addonay/cozmic) (text shaping and
layout) and [zafi](https://github.com/Addonay/zafi) (flexbox/grid layout).
System window libraries are loaded at runtime; nothing is linked at build time.

## License

MIT. GPUI is Apache-2.0, Copyright Zed Industries; see `NOTICE.md`.
