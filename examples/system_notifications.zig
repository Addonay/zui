//! Port of GPUI's `examples/system_notifications.rs`: post, replace, dismiss and respond to
//! system notifications.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - Linux posts through the freedesktop notification service (`org.freedesktop.Notifications`)
//!   on the session bus, with ZUI's own D-Bus client (`platform/linux/dbus.zig`). GPUI does the
//!   same through `notify-rust`. The bus is connected on the first notification. Without a session
//!   bus or a notification server nothing appears and the status line still updates; the first
//!   failure is logged once. Posting again with the same tag replaces the notification, and
//!   Dismiss closes it. Clicks on the body or a button reach the handler through
//!   `App.dispatch_system_notification_response`, from the event loop.
//! - `on_system_notification_response` is registered in `build_root`, because Zig closures cannot
//!   capture the view. The handler receives the entity as its context.
//! - Strings sent to `show_system_notification` are only valid during the call, so the title is
//!   formatted into a stack buffer. The status line is stored in a fixed buffer for the same
//!   reason: frame-arena strings do not survive two frames.
//! - `.when(cfg!(target_os = "macos"), ..)` is an `if` on the root element.

const std = @import("std");
const builtin = @import("builtin");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Pixels = gpui.Pixels;
const SystemNotification = gpui.SystemNotification;
const SystemNotificationAction = gpui.SystemNotificationAction;
const SystemNotificationResponse = gpui.SystemNotificationResponse;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const NOTIFICATION_TAG = "gpui-system-notification-example";

const SystemNotificationExample = struct {
    revision: usize,
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,

    fn set_status(self: *SystemNotificationExample, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(self.status_buf[0..], fmt, args) catch self.status_buf[0..];
        self.status_len = text.len;
    }

    fn status(self: *const SystemNotificationExample) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn on_show_click(this: *SystemNotificationExample, _: *const ClickEvent, _: *Window, cx: *Context(SystemNotificationExample)) void {
        this.revision += 1;
        const revision = this.revision;
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Example notification {d}", .{revision}) catch unreachable;
        const actions = [_]SystemNotificationAction{
            .{ .id = "open", .label = "Open" },
            .{ .id = "snooze", .label = "Snooze" },
        };
        cx.app.show_system_notification(SystemNotification{
            .tag = NOTIFICATION_TAG,
            .title = title,
            .body = "This notification was posted by the GPUI example.",
            .actions = &actions,
        });
        this.set_status("Posted notification revision {d}", .{revision});
        cx.notify();
    }

    fn on_dismiss_click(this: *SystemNotificationExample, _: *const ClickEvent, _: *Window, cx: *Context(SystemNotificationExample)) void {
        cx.app.dismiss_system_notification(NOTIFICATION_TAG);
        this.set_status("Dismissed the notification", .{});
        cx.notify();
    }

    /// Runs when the platform reports a click on a notification (see `on_notification_response`).
    fn apply_response(this: *SystemNotificationExample, response: SystemNotificationResponse, cx: *Context(SystemNotificationExample)) void {
        if (response.action_id) |action_id| {
            this.set_status("Received action '{s}' for tag '{s}'", .{ action_id, response.tag });
        } else {
            this.set_status("Notification body clicked for tag '{s}'", .{response.tag});
        }
        cx.notify();
    }

    pub fn render(self: *SystemNotificationExample, _: *Window, cx: *Context(SystemNotificationExample)) *Div {
        const root = div()
            .flex()
            .flex_col()
            .size_full()
            .gap_4()
            .p_8()
            .bg(rgb(0x18181b))
            .text_color(rgb(0xf4f4f5))
            .child(div().text_2xl().child("GPUI system notifications"))
            .child(div().text_sm().text_color(rgb(0xa1a1aa)).child(
                "Post repeatedly to replace the notification with the same tag. Click the notification body or an action button to send a response back to GPUI.",
            ))
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(button("show", "Show or replace").on_click(cx.listener(on_show_click)))
                    .child(button("dismiss", "Dismiss").on_click(cx.listener(on_dismiss_click))),
            )
            .child(
                div()
                    .mt_2()
                    .p_4()
                    .rounded_md()
                    .bg(rgb(0x27272a))
                    .child(self.status()),
            );
        if (builtin.os.tag == .macos) {
            _ = root.child(div().mt_2().text_xs().text_color(rgb(0x71717a)).child(
                "macOS only delivers notifications when this example runs from an app bundle.",
            ));
        }
        return root;
    }
};

fn button(id: []const u8, label: []const u8) *Div {
    return div()
        .id(id)
        .px_4()
        .py_2()
        .rounded_md()
        .bg(rgb(0x3f3f46))
        .hover(gpui.style_refinement().bg(rgb(0x52525b)))
        .active(gpui.style_refinement().bg(rgb(0x71717a)))
        .cursor_pointer()
        .child(label);
}

/// The platform's response handler: forwards the response to the view.
fn on_notification_response(view: Entity(SystemNotificationExample), response: SystemNotificationResponse, app: *App) void {
    _ = view.update(app, SystemNotificationExample.apply_response, .{response});
}

fn build_root(_: *Window, app: *App) Entity(SystemNotificationExample) {
    const view = app.new(SystemNotificationExample{
        .revision = 0,
    });
    // Set the status line before anything is posted.
    _ = view.update(app, struct {
        fn init_status(this: *SystemNotificationExample, _: *Context(SystemNotificationExample)) void {
            this.set_status("No notification posted yet", .{});
        }
    }.init_status, .{});
    app.on_system_notification_response(view, on_notification_response);
    return view;
}

fn run_example(cx: *App) void {
    cx.set_app_identity("dev.zed.gpui.system-notifications", "GPUI Notifications");

    const bounds = Bounds(Pixels).centered(null, size(px(560.0), px(360.0)), cx);
    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
        .titlebar = .{ .title = "System Notifications Example" },
    }, build_root) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
