//! Application orchestration, window management, and frame loop.

pub const app = @import("app.zig");
pub const window = @import("window.zig");
pub const runtime = @import("runtime.zig");
pub const tasks = @import("tasks.zig");
pub const keymap = @import("keymap.zig");
pub const animation = @import("animation.zig");
pub const action = @import("action.zig");
pub const executor = @import("executor.zig");
pub const view = @import("view.zig");
pub const test_context = @import("test_context.zig");

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
pub const GlobalError = runtime.GlobalError;
pub const GlobalReservation = runtime.GlobalReservation;
pub const InvalidationScope = runtime.InvalidationScope;
pub const Subscription = runtime.Subscription;
pub const SubscriptionError = runtime.SubscriptionError;
pub const TaskRuntime = tasks.TaskRuntime;
pub const TaskCancel = tasks.Cancel;
pub const TimerId = tasks.TimerId;
pub const Action = action.Action;
pub const ActionDispatch = action.Dispatch;
pub const ActionError = action.ActionError;
pub const makeAction = action.make;
pub const blockOn = executor.blockOn;
pub const ViewHandle = view.ViewHandle;
pub const WeakView = view.WeakView;
pub const AnyView = view.AnyView;
pub const AnyWeakView = view.AnyWeakView;
pub const TestAppContext = test_context.TestAppContext;

test {
    _ = @import("app.zig");
    _ = @import("window.zig");
    _ = @import("runtime.zig");
    _ = @import("tasks.zig");
    _ = @import("animation.zig");
    _ = @import("keymap.zig");
    _ = @import("action.zig");
    _ = @import("executor.zig");
    _ = @import("view.zig");
    _ = @import("test_context.zig");
}
