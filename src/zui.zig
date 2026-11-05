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
pub const test_context = @import("app/test_context.zig");
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
pub const input = @import("input.zig");
/// Grapheme segmentation and friends, which GPUI code gets from the unicode_segmentation crate.
pub const unicode = @import("cozmic").unicode;
pub const ElementInputHandler = input.ElementInputHandler;
pub const TooltipBuilder = elements.div.TooltipBuilder;
pub const AnyDrag = app.AnyDrag;
pub const AnyDragValue = app.AnyDragValue;
pub const assert_entity_input_handler = input.assert_entity_input_handler;
pub const action = @import("action.zig");
pub const executor = @import("executor.zig");
pub const platform = @import("platform.zig");
pub const renderer = struct {
    pub const cpu = @import("renderer/cpu.zig");
    pub const gpu = @import("renderer/gpu.zig");
    pub const vulkan = @import("renderer/vulkan.zig");
    pub const window_renderer = @import("renderer/window_renderer.zig");
    test {
        _ = @import("renderer/gpu_test.zig");
    }
};
pub const elements = struct {
    pub const div = @import("elements/div.zig");
    pub const text = @import("elements/text.zig");
    pub const empty = @import("elements/empty.zig");
    pub const anchored = @import("elements/anchored.zig");
    pub const deferred = @import("elements/deferred.zig");
    pub const canvas = @import("elements/canvas.zig");
    pub const animation = @import("elements/animation.zig");
    pub const img = @import("elements/img.zig");
    pub const svg = @import("elements/svg.zig");
    pub const uniform_list = @import("elements/uniform_list.zig");
    pub const list = @import("elements/list.zig");
};
pub const assets = @import("assets.zig");
pub const svg_renderer = @import("svg_renderer.zig");
pub const spring = @import("spring.zig");

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
pub const Anchor = geometry.Anchor;
pub const px = geometry.px;
pub const half = geometry.half;
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
pub const TestAppContext = test_context.TestAppContext;
pub const VisualTestContext = test_context.VisualTestContext;
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
pub const WindowBackgroundAppearance = window.WindowBackgroundAppearance;
pub const TitlebarOptions = window.TitlebarOptions;
pub const WindowDecorations = window.WindowDecorations;
pub const WindowId = window.WindowId;
pub const WindowIdValue = window.WindowIdValue;
pub const AnyWindowHandle = window.AnyWindowHandle;
pub const Decorations = window.Decorations;
pub const Tiling = window.Tiling;
pub const ResizeEdge = window.ResizeEdge;
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
pub const Img = elements.img.Img;
/// Creates an image element (GPUI `img`).
pub const img = elements.img.img;
pub const Svg = elements.svg.Svg;
/// Creates an SVG element (GPUI `svg`).
pub const svg = elements.svg.svg;
pub const Transformation = elements.svg.Transformation;
pub const ImageSource = assets.ImageSource;
pub const Image = assets.Image;
pub const ImageFormat = assets.ImageFormat;
pub const RenderImage = assets.RenderImage;
pub const AssetSource = assets.AssetSource;
pub const Resource = assets.Resource;
pub const ImageCacheError = assets.ImageCacheError;
pub const SvgRenderer = svg_renderer.SvgRenderer;

// -- anchored / deferred / canvas -------------------------------------------
pub const Anchored = elements.anchored.Anchored;
pub const AnchoredFitMode = elements.anchored.AnchoredFitMode;
pub const AnchoredPositionMode = elements.anchored.AnchoredPositionMode;
pub const anchored = elements.anchored.anchored;
pub const Deferred = elements.deferred.Deferred;
pub const deferred = elements.deferred.deferred;
pub const Canvas = elements.canvas.Canvas;
pub const canvas = elements.canvas.canvas;
pub const canvas_fn = elements.canvas.canvas_fn;

// -- uniform_list / list ----------------------------------------------------
pub const uniform_list = elements.uniform_list.uniform_list;
pub const UniformList = elements.uniform_list.UniformList;
pub const UniformListScrollHandle = elements.uniform_list.UniformListScrollHandle;
pub const UniformListScrollState = elements.uniform_list.UniformListScrollState;
pub const UniformListDecoration = elements.uniform_list.UniformListDecoration;
pub const ScrollStrategy = elements.uniform_list.ScrollStrategy;
pub const RangeRenderer = elements.uniform_list.RangeRenderer;
pub const Range = elements.uniform_list.Range;
pub const list = elements.list.list;
pub const List = elements.list.List;
pub const ListState = elements.list.ListState;
pub const ListAlignment = elements.list.ListAlignment;
pub const ListOffset = elements.list.ListOffset;
pub const ListScrollEvent = elements.list.ListScrollEvent;
pub const ListSizingBehavior = elements.list.ListSizingBehavior;
pub const ListHorizontalSizingBehavior = elements.list.ListHorizontalSizingBehavior;
pub const ListMeasuringBehavior = elements.list.ListMeasuringBehavior;
pub const FollowMode = elements.list.FollowMode;
pub const ItemRenderer = elements.list.ItemRenderer;

// -- animation / spring -------------------------------------------------------
pub const Animation = elements.animation.Animation;
pub const AnimationExt = elements.animation.AnimationExt;
pub const AnimationElement = elements.animation.AnimationElement;
pub const SpringAnimationElement = elements.animation.SpringAnimationElement;
pub const with_animation = elements.animation.with_animation;
pub const with_animations = elements.animation.with_animations;
pub const with_spring = elements.animation.with_spring;
pub const EasingFn = elements.animation.EasingFn;
pub const linear = elements.animation.linear;
pub const quadratic = elements.animation.quadratic;
pub const ease_in_out = elements.animation.ease_in_out;
pub const ease_out_quint = elements.animation.ease_out_quint;
pub const bounce = elements.animation.bounce;
pub const pulsating_between = elements.animation.pulsating_between;
pub const SpringConfig = spring.SpringConfig;
pub const SpringState = spring.SpringState;
pub const SpringPlayback = spring.SpringPlayback;
pub const SpringAnimation = spring.SpringAnimation;
pub const AnimationPhase = spring.AnimationPhase;
pub const sampled_easing = spring.sampled_easing;

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
pub const KeystrokeEvent = app.KeystrokeEvent;
pub const http_client = @import("http_client.zig");
pub const image_disk_cache = @import("image_disk_cache.zig");
pub const HttpClient = http_client.HttpClient;
pub const KeyContext = key_dispatch.KeyContext;
pub const Action = action.Action;
pub const ClipboardItem = platform.ClipboardItem;
pub const NoAction = action.NoAction;
pub const PressureStage = interactive.PressureStage;
pub const MousePressureEvent = interactive.MousePressureEvent;
pub const app_menu = platform.app_menu;
pub const Menu = app_menu.Menu;
pub const MenuItem = app_menu.MenuItem;
pub const OwnedMenu = app_menu.OwnedMenu;
pub const OwnedMenuItem = app_menu.OwnedMenuItem;
pub const OsMenu = app_menu.OsMenu;
pub const OsAction = app_menu.OsAction;
pub const SystemMenuType = app_menu.SystemMenuType;
pub const SystemNotification = platform.SystemNotification;
pub const SystemNotificationAction = platform.SystemNotificationAction;
pub const SystemNotificationResponse = platform.SystemNotificationResponse;

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
    // Backends are chosen at run time, so nothing else pulls their tests in.
    if (@import("builtin").os.tag == .linux) {
        _ = @import("platform/linux/xkb.zig");
        _ = @import("platform/linux/text_input_state.zig");
        _ = @import("platform/linux/xim_preedit.zig");
        _ = @import("platform/linux/x11_scroll.zig");
        _ = @import("platform/linux/wayland_scroll.zig");
        _ = @import("platform/linux/xdnd.zig");
        _ = @import("platform/linux/input.zig");
        _ = @import("platform/linux/x11.zig");
        _ = @import("platform/linux/wayland.zig");
        _ = @import("platform/linux/wayland_proto.zig");
        _ = @import("platform/linux/x11_proto.zig");
        _ = @import("platform/linux.zig");
    }
    std.testing.refAllDecls(@This());
    _ = @import("spring.zig");
    _ = @import("elements/anchored.zig");
    _ = @import("elements/deferred.zig");
    _ = @import("elements/canvas.zig");
    _ = @import("platform/app_menu.zig");
    _ = @import("elements/animation.zig");
}
