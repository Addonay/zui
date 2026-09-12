//! ZUI — hand-rolled retained UI framework in Zig.
//!
//! One foreground thread owns state (`App`/`Entity`/`Context`); views render
//! transient elements each dirty frame, laid out by `elements/layout`,
//! painted into a `gpu.Scene`, and presented by the native `platform`
//! backend via the `gpu/software` rasterizer.
//!
//! Attribution, not copies:
//! - Windowing: one backend vtable + bootstrap probe order, `dlopen`ed
//!   WM tables, normalized events before queueing, minimal headless
//!   reference backend, dynamic loading with fallback.
//! - DVUI: tiny `Backend` contract, `@src()`-derived IDs, headless testing
//!   backend (patterns only).
//! - Gooey: Zig module layout, static caps, hand-written C `extern`
//!   bindings. `core/limits` is a direct MIT-licensed port, attributed
//!   in-file.
//! - SDL3 (`gpu/device` shape) and Taffy (the standalone `zlay` package,
//!   consumed as a dependency) are API/algorithm references; see `plan.md`
//!   for what is actually wired up.

pub const core = @import("core/root.zig");
pub const layout = @import("layout");
pub const platform = @import("platform/root.zig");
pub const gpu = @import("gpu/root.zig");
pub const atlas = @import("fonts/atlas.zig");
pub const text_engine = @import("fonts/text_engine.zig");
pub const images = @import("images/root.zig");
pub const app = @import("app/root.zig");
pub const elements = @import("elements/root.zig");
pub const widgets = @import("widgets/root.zig");

pub const Color = core.Color;
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Bounds = core.Bounds;

pub const Backend = platform.Backend;
pub const BackendKind = platform.BackendKind;
pub const Event = platform.Event;
pub const EventQueue = platform.EventQueue;
pub const Id = platform.Id;

pub const Scene = gpu.Scene;
pub const Quad = gpu.Quad;

pub const App = app.App;
pub const Window = app.Window;
pub const WindowOptions = app.WindowOptions;
pub const Renderer = app.Renderer;
pub const Context = app.Context;
pub const Entity = app.Entity;
pub const FocusHandle = app.FocusHandle;
pub const TestHarness = app.TestHarness;

pub const Element = elements.Element;
pub const TextField = widgets.TextField;
pub const SharedString = core.SharedString;
pub const string = core.string;

pub const div = elements.div;
pub const text = elements.text;
pub const textFmt = elements.textFmt;
pub const spacer = elements.spacer;
pub const when = elements.when;
pub const img = elements.img;
pub const imgPath = elements.imgPath;
pub const imgHandle = elements.imgHandle;
pub const svg = elements.svg;
pub const svgPath = elements.svgPath;
pub const ImageFit = elements.ImageFit;
pub const progressBar = elements.progressBar;
pub const progressTrack = elements.progressTrack;
pub const formatToday = elements.formatToday;

pub const point = core.geometry.point;
pub const size = core.geometry.size;
pub const rect = core.geometry.rect;

pub fn hex(value: u32) Color {
    return Color.hex(value);
}

pub fn rgb(r: f32, g: f32, b: f32) Color {
    return Color.rgb(r, g, b);
}

pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
    return Color.rgba(r, g, b, a);
}

pub fn white() Color {
    return .white;
}

pub fn transparent() Color {
    return .transparent;
}

test {
    _ = @import("core/root.zig");
    _ = @import("layout");
    _ = @import("platform/root.zig");
    _ = @import("gpu/root.zig");
    _ = @import("fonts/atlas.zig");
    _ = @import("fonts/text_engine.zig");
    _ = @import("images/root.zig");
    _ = @import("app/root.zig");
    _ = @import("elements/root.zig");
    _ = @import("widgets/root.zig");
}
