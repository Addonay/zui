//! Application orchestration, window management, and frame loop.

pub const app = @import("app.zig");
pub const window = @import("window.zig");
pub const runtime = @import("runtime.zig");

pub const App = app.App;
pub const Window = window.Window;
pub const WindowOptions = window.WindowOptions;
pub const Renderer = window.Renderer;
pub const RenderFn = window.RenderFn;
pub const Context = runtime.Context;
pub const Entity = runtime.Entity;
pub const EntityStore = runtime.EntityStore;
pub const FocusHandle = runtime.FocusHandle;
pub const TestHarness = runtime.TestHarness;

test {
    _ = @import("app.zig");
    _ = @import("window.zig");
    _ = @import("runtime.zig");
}
