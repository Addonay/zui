//! Application orchestration, window management, and frame loop.

pub const app = @import("app.zig");
pub const window = @import("window.zig");
pub const runtime = @import("runtime.zig");
pub const tasks = @import("tasks.zig");
pub const keymap = @import("keymap.zig");

pub const App = app.App;
pub const Window = window.Window;
pub const WindowOptions = window.WindowOptions;
pub const Renderer = window.Renderer;
pub const RenderFn = window.RenderFn;
pub const Keymap = keymap.Keymap;
pub const Keystroke = keymap.Keystroke;
pub const KeyContext = keymap.ContextFrame;
pub const Context = runtime.Context;
pub const Entity = runtime.Entity;
pub const EntityStore = runtime.EntityStore;
pub const WeakEntity = runtime.WeakEntity;
pub const FocusHandle = runtime.FocusHandle;
pub const TestHarness = runtime.TestHarness;
pub const TaskRuntime = tasks.TaskRuntime;
pub const TaskCancel = tasks.Cancel;

test {
    _ = @import("app.zig");
    _ = @import("window.zig");
    _ = @import("runtime.zig");
    _ = @import("tasks.zig");
    _ = @import("keymap.zig");
}
