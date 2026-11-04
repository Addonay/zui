//! Platform input events: keyboard, mouse, touch, scroll, pinch and file drop.
//! Port of gpui/src/interactive.rs (pure data; window/app dispatch lives elsewhere).
//!
//! Marker decls replace GPUI's `InputEvent`, `KeyEvent`, `MouseEvent` and `GestureEvent`
//! traits: each event type declares `is_input_event`, plus `is_key_event`,
//! `is_mouse_event` or `is_gesture_event` where GPUI implements them. Check with `@hasDecl`.

const std = @import("std");
const geometry = @import("geometry.zig");
const keystroke = @import("keystroke.zig");

const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Pixels = geometry.Pixels;
const point = geometry.point;
const Keystroke = keystroke.Keystroke;
const Modifiers = keystroke.Modifiers;
const Capslock = keystroke.Capslock;

/// A point in window coordinates, in pixels.
pub const PixelPoint = Point(Pixels);

/// The key down event equivalent for the platform.
pub const KeyDownEvent = struct {
    pub const is_input_event = true;
    pub const is_key_event = true;

    /// The keystroke that was generated.
    keystroke: Keystroke = .{},
    /// Whether the key is currently held down.
    is_held: bool = false,
    /// Whether to prefer character input over keybindings for this keystroke.
    /// In some cases, like AltGr on Windows, modifiers are significant for character input.
    prefer_character_input: bool = false,

    pub fn to_platform_input(self: KeyDownEvent) PlatformInput {
        return .{ .key_down = self };
    }
};

/// The key up event equivalent for the platform.
pub const KeyUpEvent = struct {
    pub const is_input_event = true;
    pub const is_key_event = true;

    /// The keystroke that was released.
    keystroke: Keystroke = .{},

    pub fn to_platform_input(self: KeyUpEvent) PlatformInput {
        return .{ .key_up = self };
    }
};

/// The modifiers changed event equivalent for the platform.
pub const ModifiersChangedEvent = struct {
    pub const is_input_event = true;
    pub const is_key_event = true;

    /// The new state of the modifier keys.
    modifiers: Modifiers = .{},
    /// The new state of the capslock key.
    capslock: Capslock = .{},

    pub fn to_platform_input(self: ModifiersChangedEvent) PlatformInput {
        return .{ .modifiers_changed = self };
    }
};

/// The phase of a touch motion event. Based on the winit enum of the same name.
pub const TouchPhase = enum {
    /// The touch started.
    started,
    /// The touch event is moving.
    moved,
    /// The touch phase has ended.
    ended,
    /// The touch was cancelled: the system took it and it will not end normally.
    /// Consumers must fully unwind any in-progress interaction.
    cancelled,

    pub const default: TouchPhase = .moved;
};

/// Identifies one touch (finger or stylus contact) for its lifetime. Opaque, assigned by the platform.
pub const TouchId = struct {
    value: u64 = 0,

    pub fn eql(self: TouchId, other: TouchId) bool {
        return self.value == other.value;
    }
};

/// A raw touch event from the platform.
/// Dispatch contract (core implementation pending): a touch is hit-tested once, at `started`;
/// all later events for the same `id` go to the elements under the starting position.
pub const TouchEvent = struct {
    pub const is_input_event = true;

    /// Which touch this event belongs to.
    id: TouchId = .{},
    /// The phase of the touch.
    phase: TouchPhase = TouchPhase.default,
    /// The position of the touch in window coordinates.
    position: PixelPoint = .{},
    /// Where the platform predicts the touch will be roughly one frame from now, if offered.
    /// Best-effort latency compensation only; never used for hit testing or classification.
    predicted_position: ?PixelPoint = null,
    /// Normalized touch force in `0.0..=1.0`, if the hardware reports it.
    force: ?f32 = null,

    pub fn to_platform_input(self: TouchEvent) PlatformInput {
        return .{ .touch = self };
    }
};

/// The mouse button that was pressed or released.
pub const MouseButton = union(enum) {
    /// The left mouse button.
    left,
    /// The right mouse button.
    right,
    /// The middle mouse button.
    middle,
    /// A navigation button, such as back or forward.
    navigate: NavigationDirection,

    pub const default: MouseButton = .left;

    /// All mouse buttons, in GPUI order.
    pub fn all() [5]MouseButton {
        return .{
            .left,
            .right,
            .middle,
            .{ .navigate = .back },
            .{ .navigate = .forward },
        };
    }

    pub fn eql(self: MouseButton, other: MouseButton) bool {
        return std.meta.eql(self, other);
    }
};

/// A navigation direction, such as back or forward.
pub const NavigationDirection = enum {
    /// The back button.
    back,
    /// The forward button.
    forward,

    pub const default: NavigationDirection = .back;
};

/// A mouse down event from the platform.
pub const MouseDownEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// Which mouse button was pressed.
    button: MouseButton = MouseButton.default,
    /// The position of the mouse on the window.
    position: PixelPoint = .{},
    /// The modifiers that were held down when the mouse was pressed.
    modifiers: Modifiers = .{},
    /// The number of times the button has been clicked.
    click_count: usize = 0,
    /// Whether this is the first, focusing click.
    first_mouse: bool = false,

    pub fn to_platform_input(self: MouseDownEvent) PlatformInput {
        return .{ .mouse_down = self };
    }

    /// Returns true if this mouse down event should focus the element.
    pub fn is_focusing(self: MouseDownEvent) bool {
        return self.button.eql(.left);
    }
};

/// A mouse up event from the platform.
pub const MouseUpEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// Which mouse button was released.
    button: MouseButton = MouseButton.default,
    /// The position of the mouse on the window.
    position: PixelPoint = .{},
    /// The modifiers that were held down when the mouse was released.
    modifiers: Modifiers = .{},
    /// The number of times the button has been clicked.
    click_count: usize = 0,

    pub fn to_platform_input(self: MouseUpEvent) PlatformInput {
        return .{ .mouse_up = self };
    }

    /// Returns true if this mouse up event should focus the element.
    pub fn is_focusing(self: MouseUpEvent) bool {
        return self.button.eql(.left);
    }
};

/// A click event, generated when a mouse button is pressed and released.
pub const MouseClickEvent = struct {
    /// The mouse event when the button was pressed.
    down: MouseDownEvent = .{},
    /// The mouse event when the button was released.
    up: MouseUpEvent = .{},
};

/// The stage of a pressure click event.
pub const PressureStage = enum {
    /// No pressure.
    zero,
    /// Normal click pressure.
    normal,
    /// High pressure, enough to trigger a force click.
    force,

    pub const default: PressureStage = .zero;
};

/// A mouse pressure event from the platform. Currently only implemented for macOS trackpads.
pub const MousePressureEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// Pressure of the current stage as a float between 0 and 1.
    pressure: f32 = 0,
    /// The pressure stage of the event.
    stage: PressureStage = PressureStage.default,
    /// The position of the mouse on the window.
    position: PixelPoint = .{},
    /// The modifiers that were held down when the mouse pressure changed.
    modifiers: Modifiers = .{},

    pub fn to_platform_input(self: MousePressureEvent) PlatformInput {
        return .{ .mouse_pressure = self };
    }
};

/// The keyboard button that triggered a keyboard click.
pub const KeyboardButton = enum {
    /// Enter key was clicked.
    enter,
    /// Space key was clicked.
    space,

    pub const default: KeyboardButton = .enter;
};

/// A click event generated by a keyboard button being pressed and released.
pub const KeyboardClickEvent = struct {
    /// The keyboard button that was pressed to trigger the click.
    button: KeyboardButton = KeyboardButton.default,
    /// The bounds of the element that was clicked.
    bounds: Bounds(Pixels) = .{},
};

/// A click event generated by a recognized tap gesture on a touch screen.
pub const TouchClickEvent = struct {
    /// The position of the tap in window coordinates.
    position: PixelPoint = .{},
    /// The number of consecutive taps at this location (double tap = 2).
    tap_count: usize = 0,
    /// Whether this was a long press rather than a tap. Long presses are touch's secondary activation.
    long_press: bool = false,
};

/// A click event, generated when a mouse button or keyboard button is pressed and released,
/// or when a tap gesture is recognized on a touch screen.
pub const ClickEvent = union(enum) {
    /// A click triggered by a mouse button being pressed and released.
    mouse: MouseClickEvent,
    /// A click triggered by a keyboard button being pressed and released.
    keyboard: KeyboardClickEvent,
    /// A click triggered by a recognized tap gesture on a touch screen.
    touch: TouchClickEvent,

    pub const default: ClickEvent = .{ .keyboard = .{} };

    /// Returns the modifiers that were held during the click.
    /// Keyboard and touch clicks never have modifiers.
    pub fn modifiers(self: ClickEvent) Modifiers {
        return switch (self) {
            .keyboard => .{},
            .mouse => |event| event.up.modifiers,
            .touch => .{},
        };
    }

    /// Returns the position of the click.
    /// Keyboard: bottom left of the clicked bounds. Mouse: release position. Touch: tap position.
    pub fn position(self: ClickEvent) PixelPoint {
        return switch (self) {
            .keyboard => |event| event.bounds.bottom_left(),
            .mouse => |event| event.up.position,
            .touch => |event| event.position,
        };
    }

    /// Returns the mouse position of the click, or null for keyboard and touch clicks.
    pub fn mouse_position(self: ClickEvent) ?PixelPoint {
        return switch (self) {
            .mouse => |event| event.up.position,
            .keyboard, .touch => null,
        };
    }

    /// Returns true if this was a right click (button pressed and released with the right button).
    pub fn is_right_click(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |event| event.down.button.eql(.right) and event.up.button.eql(.right),
            .keyboard, .touch => false,
        };
    }

    /// Returns true if this was a middle click.
    pub fn is_middle_click(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |event| event.down.button.eql(.middle) and event.up.button.eql(.middle),
            .keyboard, .touch => false,
        };
    }

    /// Returns true for a secondary activation, i.e. a context menu trigger:
    /// a right click from a mouse, or a long press on a touch screen.
    pub fn is_secondary(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |event| event.down.button.eql(.right) and event.up.button.eql(.right),
            .keyboard => false,
            .touch => |event| event.long_press,
        };
    }

    /// Returns true for a standard click: keyboard always; mouse left button; touch tap (not long press).
    pub fn standard_click(self: ClickEvent) bool {
        return switch (self) {
            .keyboard => true,
            .mouse => |event| event.down.button.eql(.left) and event.up.button.eql(.left),
            .touch => |event| !event.long_press,
        };
    }

    /// Returns true if the click focused the element (the first focusing mouse click).
    pub fn first_focus(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |event| event.down.first_mouse,
            .keyboard, .touch => false,
        };
    }

    /// Returns the click count: 1 for keyboard, mouse up count, or touch tap count.
    pub fn click_count(self: ClickEvent) usize {
        return switch (self) {
            .keyboard => 1,
            .mouse => |event| event.up.click_count,
            .touch => |event| event.tap_count,
        };
    }

    /// Returns true if the click was generated by a keyboard.
    pub fn is_keyboard(self: ClickEvent) bool {
        return switch (self) {
            .keyboard => true,
            .mouse, .touch => false,
        };
    }
};

/// A mouse move event from the platform.
pub const MouseMoveEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// The position of the mouse on the window.
    position: PixelPoint = .{},
    /// The mouse button that was pressed, if any.
    pressed_button: ?MouseButton = null,
    /// The modifiers that were held down when the mouse was moved.
    modifiers: Modifiers = .{},

    pub fn to_platform_input(self: MouseMoveEvent) PlatformInput {
        return .{ .mouse_move = self };
    }

    /// Returns true if the left mouse button is currently held down.
    pub fn dragging(self: MouseMoveEvent) bool {
        const button = self.pressed_button orelse return false;
        return button.eql(.left);
    }
};

/// The kind of input that produced a `ScrollEvent`.
pub const ScrollSource = enum {
    /// A scroll from a pointing device, such as a mouse wheel or a trackpad.
    pointer,
    /// A pan of a finger on a touchscreen, recognized by GPUI, including synthesized momentum.
    touch,

    pub const default: ScrollSource = .pointer;
};

/// The scroll delta for a `ScrollEvent`.
pub const ScrollDelta = union(enum) {
    /// An exact scroll delta in pixels.
    pixels: PixelPoint,
    /// An inexact scroll delta in lines.
    lines: Point(f32),

    pub const default: ScrollDelta = .{ .lines = .{} };

    /// Returns true if this is a precise scroll delta in pixels.
    pub fn precise(self: ScrollDelta) bool {
        return switch (self) {
            .pixels => true,
            .lines => false,
        };
    }

    /// Converts this scroll delta into exact pixels.
    pub fn pixel_delta(self: ScrollDelta, line_height: Pixels) PixelPoint {
        return switch (self) {
            .pixels => |delta| delta,
            .lines => |delta| point(line_height * delta.x, line_height * delta.y),
        };
    }

    /// Combines two scroll deltas. Same-sign axes add up; an opposite sign takes `other`.
    /// Mixed kinds (pixels and lines) take `other`.
    pub fn coalesce(self: ScrollDelta, other: ScrollDelta) ScrollDelta {
        switch (self) {
            .pixels => |a| switch (other) {
                .pixels => |b| return .{ .pixels = coalesce_axes(a, b) },
                .lines => return other,
            },
            .lines => |a| switch (other) {
                .lines => |b| return .{ .lines = coalesce_axes(a, b) },
                .pixels => return other,
            },
        }
    }
};

/// Sign with Rust `f32::signum` semantics: +1 for +0.0, -1 for -0.0, NaN for NaN.
fn signum(x: f32) f32 {
    if (std.math.isNan(x)) return x;
    return std.math.copysign(@as(f32, 1.0), x);
}

fn coalesce_axes(a: Point(f32), b: Point(f32)) Point(f32) {
    const x = if (signum(a.x) == signum(b.x)) a.x + b.x else b.x;
    const y = if (signum(a.y) == signum(b.y)) a.y + b.y else b.y;
    return point(x, y);
}

/// One step of scrolling from a mouse wheel, trackpad, or touch pan.
pub const ScrollEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// The position the scroll targets. For touch pans, where the pan started.
    position: PixelPoint = .{},
    /// The change in scroll position for this event.
    delta: ScrollDelta = ScrollDelta.default,
    /// The modifiers that were held down when the scroll happened.
    modifiers: Modifiers = .{},
    /// The phase of the scroll gesture.
    touch_phase: TouchPhase = TouchPhase.default,
    /// The kind of input that produced this scroll.
    source: ScrollSource = ScrollSource.default,

    pub fn to_platform_input(self: ScrollEvent) PlatformInput {
        return .{ .scroll = self };
    }
};

/// The former name of `ScrollEvent`.
pub const ScrollWheelEvent = ScrollEvent;

/// A pinch-to-zoom gesture event from the platform (typically a trackpad).
pub const PinchEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;
    pub const is_gesture_event = true;

    /// The position of the pinch center on the window.
    position: PixelPoint = .{},
    /// The zoom delta: positive zooms in, negative zooms out (0.1 is a 10% increase).
    delta: f32 = 0,
    /// The modifiers that were held down during the pinch gesture.
    modifiers: Modifiers = .{},
    /// The phase of the pinch gesture.
    phase: TouchPhase = TouchPhase.default,

    pub fn to_platform_input(self: PinchEvent) PlatformInput {
        return .{ .pinch = self };
    }
};

/// A long-press gesture recognized from touch input.
pub const LongPressEvent = struct {
    pub const is_input_event = true;
    pub const is_gesture_event = true;
    pub const is_mouse_event = true;

    /// The phase of the long press.
    phase: TouchPhase = .started,
    /// The position where the touch started.
    start_position: PixelPoint = .{},
    /// The touch's current position.
    position: PixelPoint = .{},

    pub fn to_platform_input(self: LongPressEvent) PlatformInput {
        return .{ .long_press = self };
    }
};

/// A direct touch drag claimed by an element.
pub const TouchDragEvent = struct {
    pub const is_input_event = true;
    pub const is_gesture_event = true;
    pub const is_mouse_event = true;

    /// The phase of the touch drag.
    phase: TouchPhase = TouchPhase.default,
    /// The position where the touch started.
    start_position: PixelPoint = .{},
    /// The touch's current position.
    position: PixelPoint = .{},

    pub fn to_platform_input(self: TouchDragEvent) PlatformInput {
        return .{ .touch_drag = self };
    }
};

/// The phase of a `BackGestureEvent`.
pub const BackGesturePhase = enum {
    /// The gesture began. Claiming it routes the remaining phases to the same element.
    started,
    /// The gesture moved; `progress` changed.
    progressed,
    /// The gesture ended and the platform decided to go back.
    committed,
    /// The gesture ended without going back.
    cancelled,

    pub const default: BackGesturePhase = .started;
};

/// A back-navigation gesture, such as the iOS swipe from the leading screen edge.
pub const BackGestureEvent = struct {
    pub const is_input_event = true;
    pub const is_gesture_event = true;
    pub const is_mouse_event = true;

    /// The phase of the gesture.
    phase: BackGesturePhase = BackGesturePhase.default,
    /// Where the gesture started.
    start_position: PixelPoint = .{},
    /// How far the gesture has travelled toward going back, from 0 to 1.
    progress: f32 = 0,

    pub fn to_platform_input(self: BackGestureEvent) PlatformInput {
        return .{ .back_gesture = self };
    }
};

/// A mouse exit event from the platform, generated when the mouse leaves the window.
pub const MouseExitEvent = struct {
    pub const is_input_event = true;
    pub const is_mouse_event = true;

    /// The position of the mouse relative to the window.
    position: PixelPoint = .{},
    /// The mouse button that was pressed, if any.
    pressed_button: ?MouseButton = null,
    /// The modifiers that were held down when the mouse left.
    modifiers: Modifiers = .{},

    pub fn to_platform_input(self: MouseExitEvent) PlatformInput {
        return .{ .mouse_exited = self };
    }
};

/// Paths from the platform, such as from a file drop. Borrowed slices.
pub const ExternalPaths = struct {
    /// The dropped paths. They belong to the platform: copy them in a drop handler to keep them.
    items: []const []const u8 = &.{},

    /// A file drag has no picture of its own in the window: the system draws it.
    pub fn render(_: *ExternalPaths, _: anytype, _: anytype) @import("element.zig").AnyElement {
        return @import("elements/empty.zig").empty();
    }

    /// Returns the paths as a slice.
    pub fn paths(self: ExternalPaths) []const []const u8 {
        return self.items;
    }
};

/// A file drop event from the platform, generated when files are dragged onto the window.
pub const FileDropEvent = union(enum) {
    /// The files have entered the window.
    entered: struct {
        /// The position of the mouse relative to the window.
        position: PixelPoint,
        /// The paths of the files being dragged.
        paths: ExternalPaths,
    },
    /// The files are being dragged over the window.
    pending: struct {
        /// The position of the mouse relative to the window.
        position: PixelPoint,
    },
    /// The files have been dropped onto the window.
    submit: struct {
        /// The position of the mouse relative to the window.
        position: PixelPoint,
    },
    /// The user has stopped dragging the files over the window.
    exited,
    /// The platform-owned drag session has ended.
    ended,

    pub const is_input_event = true;
    pub const is_mouse_event = true;

    pub fn to_platform_input(self: FileDropEvent) PlatformInput {
        return .{ .file_drop = self };
    }
};

/// An enum corresponding to all kinds of platform input events.
pub const PlatformInput = union(enum) {
    /// A key was pressed.
    key_down: KeyDownEvent,
    /// A key was released.
    key_up: KeyUpEvent,
    /// The keyboard modifiers were changed.
    modifiers_changed: ModifiersChangedEvent,
    /// The mouse was pressed.
    mouse_down: MouseDownEvent,
    /// The mouse was released.
    mouse_up: MouseUpEvent,
    /// Mouse pressure.
    mouse_pressure: MousePressureEvent,
    /// The mouse was moved.
    mouse_move: MouseMoveEvent,
    /// The mouse exited the window.
    mouse_exited: MouseExitEvent,
    /// A mouse wheel or trackpad scrolled. Touch pans arrive as `touch` and are recognized into scrolls.
    scroll_wheel: ScrollEvent,
    /// A pinch gesture was performed.
    pinch: PinchEvent,
    /// A long-press gesture recognized from touch input.
    long_press: LongPressEvent,
    /// A direct touch drag claimed by an element.
    touch_drag: TouchDragEvent,
    /// A back-navigation gesture recognized by the platform.
    back_gesture: BackGestureEvent,
    /// Files were dragged and dropped onto the window.
    file_drop: FileDropEvent,
    /// A raw touch event on a touch screen.
    touch: TouchEvent,

    /// Returns true for mouse-style inputs (mouse, scroll, pinch, gesture, file drop).
    /// Touch and keyboard inputs return false, as in GPUI's `mouse_event`.
    pub fn is_mouse_event(self: PlatformInput) bool {
        return switch (self) {
            .key_down, .key_up, .modifiers_changed, .touch => false,
            else => true,
        };
    }

    /// Returns true for keyboard inputs (key down/up and modifier changes).
    pub fn is_keyboard_event(self: PlatformInput) bool {
        return switch (self) {
            .key_down, .key_up, .modifiers_changed => true,
            else => false,
        };
    }

    /// A short static name for this input's variant, for diagnostics and telemetry.
    pub fn kind_name(self: PlatformInput) []const u8 {
        return @tagName(self);
    }

    /// Returns the touch event contained in this input, if any.
    pub fn touch_event(self: *const PlatformInput) ?*const TouchEvent {
        return switch (self.*) {
            .touch => |*event| event,
            else => null,
        };
    }
};

test "marker decls" {
    try std.testing.expect(@hasDecl(MouseDownEvent, "is_mouse_event"));
    try std.testing.expect(@hasDecl(KeyDownEvent, "is_key_event"));
    try std.testing.expect(!@hasDecl(KeyDownEvent, "is_mouse_event"));
    try std.testing.expect(@hasDecl(PinchEvent, "is_gesture_event"));
}

test "to_platform_input wraps the event" {
    const ev = MouseMoveEvent{ .position = point(1.0, 2.0) };
    const input = ev.to_platform_input();
    try std.testing.expect(input == .mouse_move);
    try std.testing.expectEqual(@as(f32, 2.0), input.mouse_move.position.y);
    try std.testing.expectEqualStrings("mouse_move", input.kind_name());
}

test "PlatformInput classification" {
    const down = PlatformInput{ .key_down = .{} };
    try std.testing.expect(down.is_keyboard_event());
    try std.testing.expect(!down.is_mouse_event());

    const touch = PlatformInput{ .touch = .{ .id = .{ .value = 7 } } };
    try std.testing.expect(!touch.is_mouse_event());
    try std.testing.expectEqual(@as(u64, 7), touch.touch_event().?.id.value);

    const scroll = PlatformInput{ .scroll_wheel = .{} };
    try std.testing.expect(scroll.is_mouse_event());
    try std.testing.expect(scroll.touch_event() == null);
    try std.testing.expectEqualStrings("scroll_wheel", scroll.kind_name());
}

test "MouseButton all and eql" {
    const buttons = MouseButton.all();
    try std.testing.expectEqual(@as(usize, 5), buttons.len);
    try std.testing.expect(buttons[3].eql(.{ .navigate = .back }));
    try std.testing.expect(!buttons[3].eql(buttons[4]));
    try std.testing.expect(MouseButton.default.eql(.left));
}

test "dragging and focusing" {
    const moving = MouseMoveEvent{ .pressed_button = .left };
    try std.testing.expect(moving.dragging());
    try std.testing.expect(!(MouseMoveEvent{ .pressed_button = .right }).dragging());
    try std.testing.expect(!(MouseMoveEvent{}).dragging());

    try std.testing.expect((MouseDownEvent{}).is_focusing());
    try std.testing.expect(!(MouseUpEvent{ .button = .middle }).is_focusing());
}

test "ScrollDelta pixel_delta and precise" {
    const lines = ScrollDelta{ .lines = point(@as(f32, 1.0), @as(f32, -2.0)) };
    try std.testing.expect(!lines.precise());
    const px = lines.pixel_delta(10);
    try std.testing.expectEqual(@as(f32, 10), px.x);
    try std.testing.expectEqual(@as(f32, -20), px.y);

    const exact = ScrollDelta{ .pixels = point(@as(f32, 3.0), @as(f32, 4.0)) };
    try std.testing.expect(exact.precise());
    try std.testing.expectEqual(@as(f32, 3.0), exact.pixel_delta(10).x);
}

test "ScrollDelta coalesce" {
    const a = ScrollDelta{ .pixels = point(@as(f32, 1.0), @as(f32, 5.0)) };
    const b = ScrollDelta{ .pixels = point(@as(f32, 2.0), @as(f32, -3.0)) };
    const c = a.coalesce(b).pixels;
    // Same sign on x adds; opposite sign on y takes the second delta.
    try std.testing.expectEqual(@as(f32, 3.0), c.x);
    try std.testing.expectEqual(@as(f32, -3.0), c.y);

    const l = (ScrollDelta{ .lines = point(@as(f32, 1.0), @as(f32, 1.0)) })
        .coalesce(.{ .lines = point(@as(f32, 0.5), @as(f32, 1.0)) }).lines;
    try std.testing.expectEqual(@as(f32, 1.5), l.x);
    try std.testing.expectEqual(@as(f32, 2.0), l.y);

    // Mixed kinds take the second delta.
    const mixed = a.coalesce(.{ .lines = point(@as(f32, 1.0), @as(f32, 1.0)) });
    try std.testing.expect(mixed == .lines);
}

test "ClickEvent helpers for mouse clicks" {
    const right = ClickEvent{ .mouse = .{
        .down = .{ .button = .right, .position = point(@as(f32, 1.0), @as(f32, 2.0)) },
        .up = .{ .button = .right, .position = point(@as(f32, 3.0), @as(f32, 4.0)), .click_count = 2 },
    } };
    try std.testing.expect(right.is_right_click());
    try std.testing.expect(right.is_secondary());
    try std.testing.expect(!right.standard_click());
    try std.testing.expect(!right.is_keyboard());
    try std.testing.expectEqual(@as(usize, 2), right.click_count());
    try std.testing.expectEqual(@as(f32, 4.0), right.position().y);
    try std.testing.expectEqual(@as(f32, 3.0), right.mouse_position().?.x);
}

test "ClickEvent helpers for keyboard and touch" {
    const kb = ClickEvent{ .keyboard = .{ .bounds = .{
        .origin = point(@as(f32, 10.0), @as(f32, 10.0)),
        .size = .{ .width = 20, .height = 30 },
    } } };
    try std.testing.expect(kb.is_keyboard());
    try std.testing.expect(kb.standard_click());
    try std.testing.expectEqual(@as(usize, 1), kb.click_count());
    try std.testing.expectEqual(@as(f32, 40.0), kb.position().y);
    try std.testing.expect(kb.mouse_position() == null);

    const long = ClickEvent{ .touch = .{ .long_press = true, .tap_count = 1 } };
    try std.testing.expect(long.is_secondary());
    try std.testing.expect(!long.standard_click());

    const tap = ClickEvent{ .touch = .{ .tap_count = 2 } };
    try std.testing.expect(tap.standard_click());
    try std.testing.expectEqual(@as(usize, 2), tap.click_count());
}

test "FileDropEvent variants" {
    const drop = FileDropEvent{ .submit = .{ .position = point(@as(f32, 5.0), @as(f32, 6.0)) } };
    const input = drop.to_platform_input();
    try std.testing.expect(input == .file_drop);
    try std.testing.expect(input.is_mouse_event());
    try std.testing.expect(input.file_drop == .submit);
}
