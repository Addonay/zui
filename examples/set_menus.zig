//! Port of GPUI's `examples/set_menus.rs`.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - Linux has no menu bar, so, as in GPUI's Linux platform, `App.set_menus` only stores the menus
//!   (`App.get_menus` returns them). Nothing is drawn, so the items cannot be chosen, and the
//!   actions (`Quit`, `ToggleCheck`) are never dispatched on Linux. The "Services" OS submenu is
//!   likewise stored only. Only the window's text is visible.
//! - `impl Into<SharedString> for ViewMode` is `ViewMode.label()`.
//! - `MenuItem::action(ViewMode::List, ToggleCheck)` passes `ViewMode.list.label()` as the name.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Context = gpui.Context;
const Div = gpui.Div;
const Menu = gpui.Menu;
const MenuItem = gpui.MenuItem;
const SystemMenuType = gpui.SystemMenuType;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;

const SetMenus = struct {
    pub fn render(_: *SetMenus, _: *Window, _: *Context(SetMenus)) *Div {
        return div()
            .flex()
            .bg(gpui.white())
            .size_full()
            .justify_center()
            .items_center()
            .text_xl()
            .text_color(gpui.black())
            .child("Set Menus Example");
    }
};

const ViewMode = enum {
    list,
    grid,

    fn toggle(self: *ViewMode) void {
        self.* = switch (self.*) {
            .list => .grid,
            .grid => .list,
        };
    }

    fn label(self: ViewMode) []const u8 {
        return switch (self) {
            .list => "List",
            .grid => "Grid",
        };
    }
};

const AppState = struct {
    view_mode: ViewMode,

    fn new() AppState {
        return .{ .view_mode = .list };
    }
};

fn set_app_menus(cx: *App) void {
    const app_state = cx.global(AppState);
    const mode_items = [_]MenuItem{
        MenuItem.action(ViewMode.list.label(), ToggleCheck{}).checked(app_state.view_mode == .list),
        MenuItem.action(ViewMode.grid.label(), ToggleCheck{}).checked(app_state.view_mode == .grid),
    };
    const items = [_]MenuItem{
        MenuItem.os_submenu("Services", SystemMenuType.services),
        MenuItem.separator_item(),
        MenuItem.action("Disabled Item", gpui.NoAction{}).disabled(true),
        MenuItem.submenu(Menu.new("Disabled Submenu").disabled(true)),
        MenuItem.separator_item(),
        MenuItem.action("List Mode", ToggleCheck{}).checked(app_state.view_mode == .list),
        MenuItem.submenu(Menu.new("Mode").items(&mode_items)),
        MenuItem.separator_item(),
        MenuItem.action("Quit", Quit{}),
    };
    const menus = [_]Menu{Menu.new("set_menus").items(&items)};
    cx.set_menus(&menus);
}

// Associate actions using the `actions!` macro (or `Action` derive macro)
const Quit = gpui.Action("set_menus", "Quit");
const ToggleCheck = gpui.Action("set_menus", "ToggleCheck");

// Define the quit function that is registered with the App
fn quit(_: *const Quit, cx: *App) void {
    std.debug.print("Gracefully quitting the application...\n", .{});
    cx.quit();
}

fn toggle_check(_: *const ToggleCheck, cx: *App) void {
    const app_state = cx.global(AppState);
    app_state.view_mode.toggle();
    set_app_menus(cx);
}

fn build_root(_: *Window, app: *App) gpui.Entity(SetMenus) {
    return app.new(SetMenus{});
}

fn run_example(cx: *App) void {
    cx.set_global(AppState.new());

    // Bring the menu bar to the foreground (so you can see the menu bar)
    cx.activate(true);
    // Register the `quit` function so it can be referenced
    // by the `MenuItem::action` in the menu bar
    cx.on_action(Quit, quit);
    cx.on_action(ToggleCheck, toggle_check);
    // Add menu items
    set_app_menus(cx);
    _ = cx.open_window(WindowOptions{}, build_root) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
