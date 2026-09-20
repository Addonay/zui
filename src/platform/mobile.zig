//! Platform-neutral mobile lifecycle, insets, and appearance contract.
//!
//! The vocabulary is aligned with GPUI's `AppLifecyclePhase` and
//! `WindowInsets` in `.references/gpui/crates/gpui/src/platform.rs`.  This
//! file intentionally contains no Android JNI, UIKit, or Objective-C code.
//! `NullMobilePlatform` is deterministic headless plumbing for tests; the
//! adapter boundary below is the explicit place where native work belongs.

const std = @import("std");
const services = @import("services.zig");

pub const MobileError = error{
    Unsupported,
    InvalidInsets,
};

/// Maps to iOS didBecomeActive/willResignActive/didEnterBackground/
/// willEnterForeground and Android onResume/onPause/onStop/onStart.
pub const LifecyclePhase = enum {
    active,
    inactive,
    background,
    foreground,
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn isValid(self: @This()) bool {
        return valid(self.top) and valid(self.right) and
            valid(self.bottom) and valid(self.left);
    }
};

/// System-reserved geometry that mobile content may need to avoid.
pub const WindowInsets = struct {
    safe_area: Edges = .{},
    ime: Edges = .{},

    pub fn isValid(self: @This()) bool {
        return self.safe_area.isValid() and self.ime.isValid();
    }

    /// GPUI's effective inset: content avoids the larger safe-area/IME edge.
    pub fn effective(self: @This()) Edges {
        return .{
            .top = @max(self.safe_area.top, self.ime.top),
            .right = @max(self.safe_area.right, self.ime.right),
            .bottom = @max(self.safe_area.bottom, self.ime.bottom),
            .left = @max(self.safe_area.left, self.ime.left),
        };
    }
};

/// Shared with the existing platform-services appearance vocabulary.
pub const WindowAppearance = services.WindowAppearance;

pub const LifecycleCallback = *const fn (context: *anyopaque, phase: LifecyclePhase) void;
pub const InsetsCallback = *const fn (context: *anyopaque, insets: WindowInsets) void;
pub const MemoryWarningCallback = *const fn (context: *anyopaque) void;

/// A bounded, deterministic backend for lifecycle/insets tests.
///
/// It models state and callback delivery only. It does not claim to receive
/// events from a mobile OS or to keep an Android/iOS surface alive.
pub const NullMobilePlatform = struct {
    phase: LifecyclePhase = .foreground,
    insets: WindowInsets = .{},
    appearance: WindowAppearance = .light,
    lifecycle_context: ?*anyopaque = null,
    lifecycle_callback: ?LifecycleCallback = null,
    insets_context: ?*anyopaque = null,
    insets_callback: ?InsetsCallback = null,
    memory_context: ?*anyopaque = null,
    memory_callback: ?MemoryWarningCallback = null,

    pub fn onLifecycle(self: *@This(), context: *anyopaque, callback: LifecycleCallback) void {
        self.lifecycle_context = context;
        self.lifecycle_callback = callback;
    }

    pub fn onInsetsChanged(self: *@This(), context: *anyopaque, callback: InsetsCallback) void {
        self.insets_context = context;
        self.insets_callback = callback;
    }

    pub fn onMemoryWarning(self: *@This(), context: *anyopaque, callback: MemoryWarningCallback) void {
        self.memory_context = context;
        self.memory_callback = callback;
    }

    pub fn setLifecycle(self: *@This(), phase: LifecyclePhase) void {
        self.phase = phase;
        if (self.lifecycle_callback) |callback| callback(self.lifecycle_context.?, phase);
    }

    pub fn setInsets(self: *@This(), insets: WindowInsets) MobileError!void {
        if (!insets.isValid()) return error.InvalidInsets;
        self.insets = insets;
        if (self.insets_callback) |callback| callback(self.insets_context.?, insets);
    }

    pub fn setAppearance(self: *@This(), appearance: WindowAppearance) void {
        self.appearance = appearance;
    }

    pub fn emitMemoryWarning(self: *@This()) void {
        if (self.memory_callback) |callback| callback(self.memory_context.?);
    }
};

/// Native implementation boundary. Each operation is deliberately explicit
/// until an adapter owns JNI/Activity and UIKit/UIApplication integration.
pub const NativeAdapter = enum { android, ios };

pub const AdapterBoundary = struct {
    adapter: NativeAdapter,

    pub fn installLifecycleHooks(_: @This()) MobileError!void {
        return error.Unsupported;
    }

    pub fn readInsets(_: @This()) MobileError!WindowInsets {
        return error.Unsupported;
    }

    pub fn setAppearance(_: @This(), _: WindowAppearance) MobileError!void {
        return error.Unsupported;
    }

    pub fn requestMemoryWarningSubscription(_: @This()) MobileError!void {
        return error.Unsupported;
    }
};

fn valid(value: f32) bool {
    return value >= 0 and !std.math.isNan(value) and !std.math.isInf(value);
}

test "null mobile backend computes effective insets and emits lifecycle" {
    const Probe = struct {
        phase: LifecyclePhase = .background,
        insets: WindowInsets = .{},
        warnings: u8 = 0,

        fn lifecycle(context: *anyopaque, phase: LifecyclePhase) void {
            @as(*@This(), @ptrCast(@alignCast(context))).phase = phase;
        }
        fn insetsChanged(context: *anyopaque, insets: WindowInsets) void {
            @as(*@This(), @ptrCast(@alignCast(context))).insets = insets;
        }
        fn warning(context: *anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(context))).warnings += 1;
        }
    };

    var probe: Probe = .{};
    var platform: NullMobilePlatform = .{};
    platform.onLifecycle(&probe, Probe.lifecycle);
    platform.onInsetsChanged(&probe, Probe.insetsChanged);
    platform.onMemoryWarning(&probe, Probe.warning);
    platform.setLifecycle(.active);
    try platform.setInsets(.{
        .safe_area = .{ .top = 24, .bottom = 34 },
        .ime = .{ .bottom = 280 },
    });
    platform.emitMemoryWarning();

    try std.testing.expectEqual(LifecyclePhase.active, probe.phase);
    try std.testing.expectEqual(@as(f32, 280), probe.insets.effective().bottom);
    try std.testing.expectEqual(@as(u8, 1), probe.warnings);
}

test "null mobile backend rejects invalid insets" {
    var platform: NullMobilePlatform = .{};
    try std.testing.expectError(error.InvalidInsets, platform.setInsets(.{
        .safe_area = .{ .top = -1 },
    }));
    try std.testing.expectError(error.InvalidInsets, platform.setInsets(.{
        .ime = .{ .bottom = std.math.nan(f32) },
    }));
}

test "android and ios boundaries remain explicitly unsupported" {
    const adapters = [_]AdapterBoundary{ .{ .adapter = .android }, .{ .adapter = .ios } };
    for (adapters) |adapter| {
        try std.testing.expectError(error.Unsupported, adapter.installLifecycleHooks());
        try std.testing.expectError(error.Unsupported, adapter.readInsets());
        try std.testing.expectError(error.Unsupported, adapter.setAppearance(.dark));
        try std.testing.expectError(error.Unsupported, adapter.requestMemoryWarningSubscription());
    }
}
