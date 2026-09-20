//! ZUI — hand-rolled retained UI framework in Zig.
//!
//! One foreground thread owns state (`App`/`Entity`/`Context`); views render
//! transient elements each dirty frame, laid out by `elements/layout`,
//! painted into a `gpu.Scene`, and presented by the native `platform`
//! backend via the `gpu.vellz` renderer.
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
pub const text_document = @import("fonts/document.zig");
pub const images = @import("images/root.zig");
pub const app = @import("app/root.zig");
pub const animation = app.animation;
pub const a11y = @import("a11y/root.zig");
pub const elements = @import("elements/root.zig");
pub const widgets = @import("widgets/root.zig");
pub const debug = @import("debug/root.zig");
pub const colors = @import("colors.zig");
pub const prelude = @import("prelude.zig");

pub const Color = core.Color;
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Bounds = core.Bounds;

pub const Backend = platform.Backend;
pub const BackendKind = platform.BackendKind;
pub const PlatformServices = platform.services;
pub const MobilePlatform = platform.mobile;
pub const Event = platform.Event;
pub const EventQueue = platform.EventQueue;
pub const Id = platform.Id;

pub const Scene = gpu.Scene;
pub const Quad = gpu.Quad;
pub const Stroke = gpu.Stroke;
pub const StrokeStorage = gpu.StrokeStorage;
pub const RendererBackend = gpu.render_backend;

pub const App = app.App;
pub const Window = app.Window;
pub const WindowOptions = app.WindowOptions;
pub const Renderer = app.Renderer;
pub const Context = app.Context;
pub const Entity = app.Entity;
pub const WeakEntity = app.WeakEntity;
pub const FocusHandle = app.FocusHandle;
pub const TestHarness = app.TestHarness;
pub const GlobalError = app.GlobalError;
pub const GlobalReservation = app.GlobalReservation;
pub const InvalidationScope = app.InvalidationScope;
pub const Subscription = app.Subscription;
pub const SubscriptionError = app.SubscriptionError;
pub const TimerId = app.TimerId;

pub const Element = elements.Element;
pub const Listener = elements.Listener;
pub const TextField = widgets.TextField;
pub const SharedString = core.SharedString;
pub const SharedUri = core.SharedUri;
pub const ArcCow = core.ArcCow;
pub const http_client = @import("http_client.zig");
pub const HttpClient = http_client.Client;
pub const HttpRequest = http_client.Request;
pub const HttpResponse = http_client.Response;
pub const CancellationSource = http_client.CancellationSource;
pub const CancellationToken = http_client.CancellationToken;
pub const Priority = core.Priority;
pub const PriorityQueue = core.PriorityQueue;
pub const PriorityQueueSender = core.PriorityQueueSender;
pub const PriorityQueueReceiver = core.PriorityQueueReceiver;
pub const Refinement = core.Refinement;
pub const StyleValue = core.StyleValue;
pub const Cascade = core.Cascade;
pub const Action = app.Action;
pub const ActionDispatch = app.ActionDispatch;
pub const makeAction = app.makeAction;
pub const blockOn = app.blockOn;
pub const string = core.string;

pub const div = elements.div;
pub const text = elements.text;
pub const textFmt = elements.textFmt;
pub const spacer = elements.spacer;
pub const custom = elements.custom;
pub const CustomVTable = elements.CustomVTable;
pub const Canvas = elements.Canvas;
pub const when = elements.when;
pub const img = elements.img;
pub const imgPath = elements.imgPath;
pub const imgHandle = elements.imgHandle;
pub const imgAsset = elements.imgAsset;
pub const withImageCache = elements.withImageCache;
pub const svg = elements.svg;
pub const svgPath = elements.svgPath;
pub const ImageFit = elements.ImageFit;
pub const progressBar = elements.progressBar;
pub const progressTrack = elements.progressTrack;
pub const formatToday = elements.formatToday;
pub const Anchored = elements.Anchored;
pub const ContainerQuery = elements.ContainerQuery;
pub const DeferredQueue = elements.DeferredQueue;
pub const Surface = elements.Surface;
pub const ImageCache = elements.ImageCache;
pub const UniformList = elements.UniformList;
pub const Composition = elements.Composition;
pub const ElementFrame = elements.ElementFrame;
pub const CompositionScope = elements.CompositionScope;
pub const ElementContext = elements.ElementContext;
pub const RetainedElementState = elements.RetainedElementState;
pub const compose = elements.compose;
pub const renderView = elements.renderView;
pub const renderOnce = elements.renderOnce;
pub const view = elements.view;
pub const containerQuery = elements.containerQuery;
pub const surfaceElement = elements.surfaceElement;
pub const imageCache = elements.imageCache;
pub const uniformList = elements.uniformList;

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
    _ = @import("fonts/document.zig");
    _ = @import("images/root.zig");
    _ = @import("app/root.zig");
    _ = @import("a11y/root.zig");
    _ = @import("elements/root.zig");
    _ = @import("widgets/root.zig");
    _ = @import("debug/root.zig");
    _ = @import("http_client.zig");
}
