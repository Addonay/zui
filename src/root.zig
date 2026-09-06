//! ZUI — hand-rolled GPU UI framework in Zig.
//!
//! Low-level first: core primitives, platform backends, GPU scene, text.
//! The retained `App`/`Entity` API from `examples/todo` builds on top once
//! the frame loop, layout, and painters land.
//!
//! Architectural debts, not copies:
//! - SDL3: backend vtable + bootstrap probe order, `dlopen`ed WM/GL/VK
//!   tables, `PumpEvents` + `WaitEventTimeout` pair, `SDL_Send*`
//!   normalization before queueing.
//! - GLFW: null backend as the minimal reference template, per-platform
//!   state union, dynamic loading with fallback (Wayland then X11).
//! - DVUI: tiny `Backend` contract (begin/end, triangles, textures),
//!   `@src()`-derived IDs, headless testing backend.
//! - Gooey: Zig module layout, static caps, hand-written C `extern`
//!   bindings, `@embedFile` shaders. `core/limits` and `text/bindings`
//!   are direct MIT-licensed ports, attributed in-file.

pub const core = @import("core/root.zig");
pub const layout = @import("layout/root.zig");
pub const platform = @import("platform/root.zig");
pub const gpu = @import("gpu/root.zig");
pub const text_system = @import("text/root.zig");
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
    _ = @import("layout/root.zig");
    _ = @import("platform/root.zig");
    _ = @import("gpu/root.zig");
    _ = @import("text/root.zig");
    _ = @import("app/root.zig");
    _ = @import("elements/root.zig");
    _ = @import("widgets/root.zig");
}
