//! ZUI: GPUI, the GPU-accelerated UI framework from Zed, ported to Zig.
//!
//! ```zig
//! const gpui = @import("zui");
//! const div = gpui.div;
//! const px = gpui.px;
//!
//! const HelloWorld = struct {
//!     text: []const u8,
//!     pub fn render(self: *HelloWorld, _: *gpui.Window, _: *gpui.Context(HelloWorld)) *gpui.Div {
//!         return div().flex().bg(gpui.rgb(0x2e7d32)).size(px(500)).justify_center().items_center()
//!             .text_xl().text_color(gpui.rgb(0xffffff))
//!             .child(gpui.format("Hello, {s}!", .{self.text}));
//!     }
//! };
//! ```

const std = @import("std");

pub const geometry = @import("geometry.zig");
pub const color = @import("color.zig");
pub const colors = @import("colors.zig");
pub const style = @import("style.zig");
pub const styled = @import("styled.zig");
pub const refineable = @import("refineable.zig");
pub const app = @import("app.zig");
pub const window = @import("window.zig");
pub const element = @import("element.zig");
pub const view = @import("view.zig");
pub const scene = @import("scene.zig");
pub const atlas = @import("atlas.zig");
pub const bounds_tree = @import("bounds_tree.zig");
pub const path_builder = @import("path_builder.zig");
pub const taffy = @import("taffy.zig");
pub const text_system = @import("text_system.zig");
pub const interactive = @import("interactive.zig");
pub const keystroke = @import("keystroke.zig");
pub const keymap = @import("keymap.zig");
pub const key_dispatch = @import("key_dispatch.zig");
pub const action = @import("action.zig");
pub const executor = @import("executor.zig");
pub const platform = @import("platform.zig");
pub const elements = struct {
    pub const div = @import("elements/div.zig");
    pub const text = @import("elements/text.zig");
    pub const empty = @import("elements/empty.zig");
};

// -- geometry ---------------------------------------------------------------
pub const Pixels = geometry.Pixels;
pub const ScaledPixels = geometry.ScaledPixels;
pub const DevicePixels = geometry.DevicePixels;
pub const Rems = geometry.Rems;
pub const AbsoluteLength = geometry.AbsoluteLength;
pub const DefiniteLength = geometry.DefiniteLength;
pub const Length = geometry.Length;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const Corner = geometry.Corner;
pub const Axis = geometry.Axis;
pub const px = geometry.px;
pub const rems = geometry.rems;
pub const relative = geometry.relative;
pub const phi = geometry.phi;
pub const auto = geometry.auto;
pub const point = geometry.point;
pub const size = geometry.size;
pub const bounds = geometry.bounds;

// -- color ------------------------------------------------------------------
pub const Hsla = color.Hsla;
pub const Rgba = color.Rgba;
pub const Background = color.Background;
pub const rgb = color.rgb;
pub const rgba = color.rgba;
pub const hsla = color.hsla;
pub const opaque_grey = color.opaque_grey;
pub const black = color.black;
pub const white = color.white;
pub const red = color.red;
pub const green = color.green;
pub const blue = color.blue;
pub const yellow = color.yellow;
pub const transparent_black = color.transparent_black;
pub const transparent_white = color.transparent_white;
pub const linear_gradient = color.linear_gradient;
pub const linear_color_stop = color.linear_color_stop;
pub const pattern_slash = color.pattern_slash;
pub const solid_background = color.solid_background;

// -- style ------------------------------------------------------------------
pub const Style = style.Style;
pub const StyleRefinement = style.StyleRefinement;
pub const TextStyle = style.TextStyle;
pub const TextStyleRefinement = style.TextStyleRefinement;
pub const TextRun = style.TextRun;
pub const HighlightStyle = style.HighlightStyle;
pub const UnderlineStyle = style.UnderlineStyle;
pub const StrikethroughStyle = style.StrikethroughStyle;
pub const BoxShadow = style.BoxShadow;
pub const Fill = style.Fill;
pub const CursorStyle = style.CursorStyle;
pub const ObjectFit = style.ObjectFit;
pub const Display = style.Display;
pub const Overflow = style.Overflow;
pub const Position = style.Position;
pub const FlexDirection = style.FlexDirection;
pub const FlexWrap = style.FlexWrap;
pub const AlignItems = style.AlignItems;
pub const AlignContent = style.AlignContent;
pub const JustifyContent = style.JustifyContent;
pub const WhiteSpace = style.WhiteSpace;
pub const TextAlign = style.TextAlign;
pub const TextOverflow = style.TextOverflow;
pub const BorderStyle = style.BorderStyle;
pub const Font = text_system.Font;
pub const FontWeight = text_system.FontWeight;
pub const FontStyle = text_system.FontStyle;
pub const FontFeatures = text_system.FontFeatures;
pub const font = text_system.font;

// -- app --------------------------------------------------------------------
pub const Application = app.Application;
pub const App = app.App;
pub const AsyncApp = app.AsyncApp;
pub const Context = app.Context;
pub const Entity = app.Entity;
pub const WeakEntity = app.WeakEntity;
pub const AnyEntity = app.AnyEntity;
pub const EntityId = app.EntityId;
pub const Subscription = app.Subscription;
pub const Listener = app.Listener;
pub const Task = executor.Task;
pub const BackgroundExecutor = executor.BackgroundExecutor;
pub const ForegroundExecutor = executor.ForegroundExecutor;

// -- window -----------------------------------------------------------------
pub const Window = window.Window;
pub const WindowOptions = window.WindowOptions;
pub const WindowBounds = window.WindowBounds;
pub const WindowHandle = window.WindowHandle;
pub const WindowKind = window.WindowKind;
pub const TitlebarOptions = window.TitlebarOptions;
pub const FocusHandle = window.FocusHandle;
pub const Hitbox = window.Hitbox;
pub const HitboxBehavior = window.HitboxBehavior;
pub const ContentMask = window.ContentMask;
pub const DispatchPhase = window.DispatchPhase;
pub const PaintQuad = window.PaintQuad;
pub const quad = window.quad;
pub const fill = window.fill;
pub const outline = window.outline;
pub const format = window.format;
pub const AnyView = view.AnyView;

// -- elements ---------------------------------------------------------------
pub const AnyElement = element.AnyElement;
pub const ElementId = element.ElementId;
pub const GlobalElementId = element.GlobalElementId;
pub const ParentElement = element.ParentElement;
pub const FluentBuilder = element.FluentBuilder;
pub const into_any_element = element.into_any_element;
pub const LayoutId = taffy.LayoutId;
pub const AvailableSpace = taffy.AvailableSpace;
pub const Div = elements.div.Div;
pub const Stateful = elements.div.Stateful;
pub const StyledElement = elements.div.StyledElement;
pub const Interactivity = elements.div.Interactivity;
pub const ScrollHandle = elements.div.ScrollHandle;
pub const div = elements.div.div;
/// Builds a standalone style refinement for `.hover(...)`, `.active(...)`, etc.
pub const style_refinement = elements.div.style;
pub const StyledText = elements.text.StyledText;
pub const empty = elements.empty.empty;

// -- input ------------------------------------------------------------------
pub const Modifiers = keystroke.Modifiers;
pub const Keystroke = keystroke.Keystroke;
pub const MouseButton = interactive.MouseButton;
pub const MouseDownEvent = interactive.MouseDownEvent;
pub const MouseUpEvent = interactive.MouseUpEvent;
pub const MouseMoveEvent = interactive.MouseMoveEvent;
pub const MouseExitEvent = interactive.MouseExitEvent;
pub const ScrollWheelEvent = interactive.ScrollWheelEvent;
pub const ScrollDelta = interactive.ScrollDelta;
pub const ClickEvent = interactive.ClickEvent;
pub const KeyDownEvent = interactive.KeyDownEvent;
pub const KeyUpEvent = interactive.KeyUpEvent;
pub const ModifiersChangedEvent = interactive.ModifiersChangedEvent;
pub const PlatformInput = interactive.PlatformInput;
pub const KeyBinding = keymap.KeyBinding;
pub const KeyContext = key_dispatch.KeyContext;
pub const Action = action.Action;
pub const ClipboardItem = platform.ClipboardItem;

/// Common imports (GPUI `prelude`).
pub const prelude = struct {
    pub const App = app.App;
    pub const Context = app.Context;
    pub const Entity = app.Entity;
    pub const Window = window.Window;
    pub const div = elements.div.div;
    pub const px = geometry.px;
    pub const rems = geometry.rems;
    pub const rgb = color.rgb;
    pub const rgba = color.rgba;
    pub const format = window.format;
};

test {
    std.testing.refAllDecls(@This());
}
