//! Cocoa backend: NSApplication/NSWindow/NSView through the objc runtime.
//!
//! Window creation, manual event pump (no `NSApplication run` — the App
//! frame loop drives), key/mouse/scroll translation, clipboard, cursors,
//! and software presentation via a CGBitmapContext pushed to the view
//! layer. Only macOS constructs it (`isAvailable()` is false elsewhere).

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const bindings = @import("bindings.zig");
const event = @import("../event.zig");
const geometry = @import("../../core/geometry.zig");
const limits = @import("../../core/limits.zig");
const gpu = @import("../../gpu/root.zig");
const dl = @import("../dl.zig");

const b = bindings;

/// macOS virtual keycode (USB HID usage) → normalized key. Pure for
/// testability. Values are the stable HIToolbox ABI.
fn keycodeToKey(code: u16) event.Key {
    return switch (code) {
        0x00 => .a,
        0x01 => .s,
        0x02 => .d,
        0x03 => .f,
        0x04 => .h,
        0x05 => .g,
        0x06 => .z,
        0x07 => .x,
        0x08 => .c,
        0x09 => .v,
        0x0B => .b,
        0x0C => .q,
        0x0D => .w,
        0x0E => .e,
        0x0F => .r,
        0x10 => .y,
        0x11 => .t,
        0x12 => .n1,
        0x13 => .n2,
        0x14 => .n3,
        0x15 => .n4,
        0x16 => .n6,
        0x17 => .n5,
        0x19 => .n9,
        0x1A => .n7,
        0x1B => .n8,
        0x1C => .n0,
        0x1F => .o,
        0x20 => .u,
        0x22 => .i,
        0x23 => .p,
        0x24 => .enter,
        0x25 => .l,
        0x26 => .j,
        0x28 => .k,
        0x2B => .n,
        0x2C => .m,
        0x30 => .tab,
        0x31 => .space,
        0x33 => .backspace,
        0x35 => .escape,
        0x60 => .f5,
        0x61 => .f6,
        0x62 => .f7,
        0x63 => .f3,
        0x64 => .f8,
        0x65 => .f9,
        0x67 => .f11,
        0x6D => .f10,
        0x6F => .f12,
        0x73 => .home,
        0x75 => .delete, // forward delete
        0x76 => .f4,
        0x77 => .end,
        0x78 => .f2,
        0x7A => .f1,
        0x7B => .left,
        0x7C => .right,
        0x7D => .down,
        0x7E => .up,
        // Punctuation, keypad, F13+, help/page-up arrive through the
        // characters text path or have no normalized key: .unknown.
        else => .unknown,
    };
}

fn modifiersFromFlags(flags: b.NSUInteger) event.Modifiers {
    return .{
        .shift = flags & b.NS_MOD_SHIFT != 0,
        .ctrl = flags & b.NS_MOD_CONTROL != 0,
        .alt = flags & b.NS_MOD_OPTION != 0,
        .super = flags & b.NS_MOD_COMMAND != 0,
    };
}

/// Call objc_msgSend with a concrete signature. The cast is checked at
/// compile time; signatures below mirror AppKit declarations. The dispatch
/// pointer comes from the loaded libobjc table (never a link-time extern,
/// which would force the test binary to link AppKit on Linux).
var msg_send_fn: ?*anyopaque = null;

fn send(comptime Fn: type) Fn {
    // Same alignment story as dl.Library.lookup: the dispatch pointer is
    // *anyopaque (align 1) while concrete signatures need fn alignment.
    return @as(Fn, @ptrCast(@alignCast(msg_send_fn.?)));
}

pub const CocoaBackend = struct {
    allocator: std.mem.Allocator,
    /// Vellz-backed frame renderer, persistent across presents.
    renderer: gpu.vellz.Renderer,
    appkit: dl.Library,
    foundation: dl.Library,
    quartzcore: dl.Library,
    coregraphics: dl.Library,
    objc_lib: dl.Library,
    objc: b.ObjcApi,
    cg: b.CoreGraphicsApi,
    sel: Sels,
    app: b.id,
    window: b.id,
    view: b.id,
    pool: b.id,
    size: geometry.Size,
    scale_factor: f32 = 2.0,
    focused: bool = true,
    presents: u32 = 0,
    wakeups: u32 = 0,
    pixels: []u8,
    bitmap_ctx: ?*anyopaque = null,
    colorspace: ?*anyopaque = null,
    image: ?*anyopaque = null,
    decorated: bool = true,
    /// Last mouse-down event, retained for titlebar drags.
    drag_event: b.id = null,
    /// Active frameless edge resize (cleared on mouse-up).
    resize_edge: ?backend.ResizeEdge = null,
    resize_origin: b.NSPoint = .{ .x = 0, .y = 0 },
    resize_frame: b.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 0, .h = 0 } },
    target_queue: ?*event.EventQueue = null,
    /// Events pumped by wait() surface here on the next poll.
    stash: event.EventQueue = .{},
    debug_events: bool = false,

    const Sels = struct {
        sharedApplication: b.SEL,
        setActivationPolicy: b.SEL,
        activateIgnoringOtherApps: b.SEL,
        finishLaunching: b.SEL,
        alloc: b.SEL,
        init: b.SEL,
        initWithContentRect: b.SEL,
        setTitle: b.SEL,
        setTitlebarAppearsTransparent: b.SEL,
        setTitleVisibility: b.SEL,
        setStyleMask: b.SEL,
        styleMask: b.SEL,
        standardWindowButton: b.SEL,
        setHidden: b.SEL,
        miniaturize: b.SEL,
        zoom: b.SEL,
        setFrame: b.SEL,
        performWindowDragWithEvent: b.SEL,
        makeKeyAndOrderFront: b.SEL,
        contentView: b.SEL,
        setContentView: b.SEL,
        setWantsLayer: b.SEL,
        layer: b.SEL,
        setAutoresizingMask: b.SEL,
        makeFirstResponder: b.SEL,
        setContentSize: b.SEL,
        frame: b.SEL,
        backingScaleFactor: b.SEL,
        nextEventMatchingMask: b.SEL,
        sendEvent: b.SEL,
        updateWindows: b.SEL,
        distantPast: b.SEL,
        dateWithTimeIntervalSinceNow: b.SEL,
        drain: b.SEL,
        type: b.SEL,
        keyCode: b.SEL,
        modifierFlags: b.SEL,
        characters: b.SEL,
        utf8String: b.SEL,
        timestamp: b.SEL,
        locationInWindow: b.SEL,
        buttonNumber: b.SEL,
        scrollingDeltaX: b.SEL,
        scrollingDeltaY: b.SEL,
        isARepeat: b.SEL,
        stringWithUTF8String: b.SEL,
        generalPasteboard: b.SEL,
        declareTypes: b.SEL,
        setString: b.SEL,
        stringForType: b.SEL,
        arrayWithObject: b.SEL,
        arrowCursor: b.SEL,
        iBeamCursor: b.SEL,
        pointingHandCursor: b.SEL,
        set: b.SEL,
        flush: b.SEL,
        postEvent: b.SEL,
        otherEventWithType: b.SEL,
    };

    const vtable: backend.VTable = .{
        .kind = kindFn,
        .poll = pollFn,
        .waitTimeoutNs = waitFn,
        .wakeup = wakeupFn,
        .windowInfo = infoFn,
        .setTitle = titleFn,
        .setSize = sizeFn,
        .setDecorated = decoratedFn,
        .dragWindow = dragFn,
        .resizeWindow = resizeFn,
        .minimizeWindow = minimizeFn,
        .toggleMaximizeWindow = maximizeFn,
        .setCursor = cursorFn,
        .setClipboardText = setClipboardFn,
        .clipboardText = getClipboardFn,
        .present = presentFn,
    };

    /// File-scope active backend for delegate/view callbacks (single
    /// native window per backend, matching the Wayland/X11 structs).
    var active: ?*CocoaBackend = null;

    pub fn isAvailable() bool {
        return builtin.os.tag == .macos;
    }

    fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
        if (!builtin.link_libc) return null;
        return std.c.getenv(name);
    }

    fn openLib(path: [*:0]const u8) !dl.Library {
        return dl.Library.open(&.{path}) orelse error.LibraryNotFound;
    }

    fn registerSels(objc: *const b.ObjcApi) Sels {
        const r = objc.sel_registerName;
        return .{
            .sharedApplication = r("sharedApplication"),
            .setActivationPolicy = r("setActivationPolicy:"),
            .activateIgnoringOtherApps = r("activateIgnoringOtherApps:"),
            .finishLaunching = r("finishLaunching"),
            .alloc = r("alloc"),
            .init = r("init"),
            .initWithContentRect = r("initWithContentRect:styleMask:backing:defer:"),
            .setTitle = r("setTitle:"),
            .setTitlebarAppearsTransparent = r("setTitlebarAppearsTransparent:"),
            .setTitleVisibility = r("setTitleVisibility:"),
            .setStyleMask = r("setStyleMask:"),
            .styleMask = r("styleMask"),
            .standardWindowButton = r("standardWindowButton:"),
            .setHidden = r("setHidden:"),
            .miniaturize = r("miniaturize:"),
            .zoom = r("zoom:"),
            .setFrame = r("setFrame:display:"),
            .performWindowDragWithEvent = r("performWindowDragWithEvent:"),
            .makeKeyAndOrderFront = r("makeKeyAndOrderFront:"),
            .contentView = r("contentView"),
            .setContentView = r("setContentView:"),
            .setWantsLayer = r("setWantsLayer:"),
            .layer = r("layer"),
            .setAutoresizingMask = r("setAutoresizingMask:"),
            .makeFirstResponder = r("makeFirstResponder:"),
            .setContentSize = r("setContentSize:"),
            .frame = r("frame"),
            .backingScaleFactor = r("backingScaleFactor"),
            .nextEventMatchingMask = r("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            .sendEvent = r("sendEvent:"),
            .updateWindows = r("updateWindows"),
            .distantPast = r("distantPast"),
            .dateWithTimeIntervalSinceNow = r("dateWithTimeIntervalSinceNow:"),
            .drain = r("drain"),
            .type = r("type"),
            .keyCode = r("keyCode"),
            .modifierFlags = r("modifierFlags"),
            .characters = r("characters"),
            .utf8String = r("UTF8String"),
            .timestamp = r("timestamp"),
            .locationInWindow = r("locationInWindow"),
            .buttonNumber = r("buttonNumber"),
            .scrollingDeltaX = r("scrollingDeltaX"),
            .scrollingDeltaY = r("scrollingDeltaY"),
            .isARepeat = r("isARepeat"),
            .stringWithUTF8String = r("stringWithUTF8String:"),
            .generalPasteboard = r("generalPasteboard"),
            .declareTypes = r("declareTypes:owner:"),
            .setString = r("setString:forType:"),
            .stringForType = r("stringForType:"),
            .arrayWithObject = r("arrayWithObject:"),
            .arrowCursor = r("arrowCursor"),
            .iBeamCursor = r("IBEAMCursor"),
            .pointingHandCursor = r("pointingHandCursor"),
            .set = r("set"),
            .flush = r("flush"),
            .postEvent = r("postEvent:atStart:"),
            .otherEventWithType = r("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
        };
    }

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !*CocoaBackend {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        var appkit = try openLib(b.appkit_path);
        errdefer appkit.close();
        var foundation = try openLib(b.foundation_path);
        errdefer foundation.close();
        var quartzcore = try openLib(b.quartzcore_path);
        errdefer quartzcore.close();
        var coregraphics = try openLib(b.coregraphics_path);
        errdefer coregraphics.close();
        var objc_lib = try openLib(b.objc_path);
        errdefer objc_lib.close();
        const objc = b.ObjcApi.load(objc_lib) orelse return error.MissingSymbols;
        const cg = b.CoreGraphicsApi.load(coregraphics) orelse return error.MissingSymbols;
        msg_send_fn = objc.msg_send;

        const sel = registerSels(&objc);
        const ns_app = objc.getClass(b.NSApplication) orelse return error.MissingClasses;
        const app = send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(ns_app, sel.sharedApplication);
        _ = send(*const fn (b.id, b.SEL, b.NSInteger) callconv(.c) void)(app, sel.setActivationPolicy, b.NS_APPLICATION_ACTIVATION_POLICY_REGULAR);
        _ = send(*const fn (b.id, b.SEL) callconv(.c) void)(app, sel.finishLaunching);
        _ = send(*const fn (b.id, b.SEL, b.BOOL) callconv(.c) void)(app, sel.activateIgnoringOtherApps, 1);

        // View subclass carrying input + layer presentation.
        const ns_view = objc.getClass(b.NSView) orelse return error.MissingClasses;
        const view_cls = objc.allocateClassPair(ns_view, "ZUIView", 0) orelse return error.ClassPairFailed;
        _ = objc.addMethod(view_cls, objc.sel_registerName("acceptsFirstResponder"), @ptrCast(&viewAcceptsFirstResponder), "c@:");
        _ = objc.addMethod(view_cls, objc.sel_registerName("drawRect:"), @ptrCast(&viewDrawRect), "v@:{NSRect={NSPoint=dd}{NSSize=dd}}");
        _ = objc.addMethod(view_cls, objc.sel_registerName("keyDown:"), @ptrCast(&viewKeyDown), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("keyUp:"), @ptrCast(&viewKeyUp), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("flagsChanged:"), @ptrCast(&viewFlagsChanged), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("mouseDown:"), @ptrCast(&viewMouseDown), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("mouseUp:"), @ptrCast(&viewMouseUp), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("rightMouseDown:"), @ptrCast(&viewRightMouseDown), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("rightMouseUp:"), @ptrCast(&viewRightMouseUp), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("otherMouseDown:"), @ptrCast(&viewOtherMouseDown), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("otherMouseUp:"), @ptrCast(&viewOtherMouseUp), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("mouseMoved:"), @ptrCast(&viewMouseMoved), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("mouseDragged:"), @ptrCast(&viewMouseMoved), "v@:@");
        _ = objc.addMethod(view_cls, objc.sel_registerName("scrollWheel:"), @ptrCast(&viewScrollWheel), "v@:@");
        objc.registerClassPair(view_cls);

        // Window delegate for close/resize/focus.
        const ns_obj = objc.getClass("NSObject") orelse return error.MissingClasses;
        const del_cls = objc.allocateClassPair(ns_obj, "ZUIWindowDelegate", 0) orelse return error.ClassPairFailed;
        _ = objc.addMethod(del_cls, objc.sel_registerName("windowShouldClose:"), @ptrCast(&delegateShouldClose), "c@:@");
        _ = objc.addMethod(del_cls, objc.sel_registerName("windowDidResize:"), @ptrCast(&delegateDidResize), "v@:@");
        _ = objc.addMethod(del_cls, objc.sel_registerName("windowDidBecomeKey:"), @ptrCast(&delegateDidBecomeKey), "v@:@");
        _ = objc.addMethod(del_cls, objc.sel_registerName("windowDidResignKey:"), @ptrCast(&delegateDidResignKey), "v@:@");
        objc.registerClassPair(del_cls);

        const ns_window = objc.getClass(b.NSWindow) orelse return error.MissingClasses;
        const rect = b.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) } };
        const style: b.NSUInteger = b.NS_WINDOW_STYLE_TITLED | b.NS_WINDOW_STYLE_CLOSABLE | b.NS_WINDOW_STYLE_MINIATURIZABLE | b.NS_WINDOW_STYLE_RESIZABLE;
        const alloced = send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(ns_window, sel.alloc);
        const window = send(*const fn (b.id, b.SEL, b.NSRect, b.NSUInteger, b.NSUInteger, b.BOOL) callconv(.c) b.id)(alloced, sel.initWithContentRect, rect, style, b.NS_BACKING_STORE_BUFFERED, 0);

        const view_alloced = send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(view_cls, sel.alloc);
        const view = send(*const fn (b.id, b.SEL, b.NSRect) callconv(.c) b.id)(view_alloced, sel.init, rect);
        _ = send(*const fn (b.id, b.SEL, b.BOOL) callconv(.c) void)(view, sel.setWantsLayer, 1);
        _ = send(*const fn (b.id, b.SEL, b.NSUInteger) callconv(.c) void)(view, sel.setAutoresizingMask, b.NS_VIEW_WIDTH_SIZABLE | b.NS_VIEW_HEIGHT_SIZABLE);
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(window, sel.setContentView, view);
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(window, sel.makeFirstResponder, view);

        const delegate_alloced = send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(del_cls, sel.alloc);
        const delegate = send(*const fn (b.id, b.SEL) callconv(.c) b.id)(delegate_alloced, sel.init);
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(window, objc.sel_registerName("setDelegate:"), delegate);

        const ns_string = objc.getClass(b.NSString) orelse return error.MissingClasses;
        const title_str = send(*const fn (b.Class, b.SEL, [*:0]const u8) callconv(.c) b.id)(ns_string, sel.stringWithUTF8String, title);
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(window, sel.setTitle, title_str);
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(window, sel.makeKeyAndOrderFront, null);

        const pool_cls = objc.getClass(b.NSAutoreleasePool) orelse return error.MissingClasses;
        const pool = send(*const fn (b.id, b.SEL) callconv(.c) b.id)(
            send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(pool_cls, sel.alloc),
            sel.init,
        );

        const scale = send(*const fn (b.id, b.SEL) callconv(.c) b.CGFloat)(window, sel.backingScaleFactor);
        // §5G DPI: the pixel buffer is PHYSICAL backing pixels (points *
        // scale); app-visible size stays logical points.
        const pw: usize = @intFromFloat(@as(f32, @floatFromInt(width)) * @max(1.0, @as(f32, @floatCast(scale))));
        const ph: usize = @intFromFloat(@as(f32, @floatFromInt(height)) * @max(1.0, @as(f32, @floatCast(scale))));
        const pixels = try allocator.alloc(u8, pw * ph * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        const self = try allocator.create(CocoaBackend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .appkit = appkit,
            .foundation = foundation,
            .quartzcore = quartzcore,
            .coregraphics = coregraphics,
            .objc_lib = objc_lib,
            .objc = objc,
            .cg = cg,
            .sel = sel,
            .app = app,
            .window = window,
            .view = view,
            .pool = pool,
            .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
            .scale_factor = @floatCast(@max(1.0, scale)),
            .pixels = pixels,
            .debug_events = getenv("ZUI_DEBUG_EVENTS") != null,
            .renderer = gpu.vellz.Renderer.init(allocator),
        };
        active = self;
        self.recreateBitmap();
        return self;
    }

    pub fn deinit(self: *CocoaBackend) void {
        self.renderer.deinit();
        if (active == self) {
            active = null;
            msg_send_fn = null;
        }
        if (self.image) |img| {
            self.cg.imageRelease(img);
            self.image = null;
        }
        if (self.bitmap_ctx) |ctx| {
            self.cg.contextRelease(ctx);
            self.bitmap_ctx = null;
        }
        self.allocator.free(self.pixels);
        _ = send(*const fn (b.id, b.SEL) callconv(.c) void)(self.pool, self.sel.drain);
        self.appkit.close();
        self.foundation.close();
        self.quartzcore.close();
        self.coregraphics.close();
        self.objc_lib.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *CocoaBackend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// §5G DPI: PHYSICAL backing-pixel dimensions (points * scale). The
    /// bitmap context and raster target are backing pixels; `size`,
    /// NSView frames and `windowInfo().size` are logical points.
    pub fn physW(self: *const CocoaBackend) usize {
        return @intFromFloat(@max(1, @round(self.size.w * self.scale_factor)));
    }
    pub fn physH(self: *const CocoaBackend) usize {
        return @intFromFloat(@max(1, @round(self.size.h * self.scale_factor)));
    }

    fn recreateBitmap(self: *CocoaBackend) void {
        if (self.image) |img| {
            self.cg.imageRelease(img);
            self.image = null;
        }
        if (self.bitmap_ctx) |ctx| {
            self.cg.contextRelease(ctx);
            self.bitmap_ctx = null;
        }
        if (self.colorspace == null) self.colorspace = self.cg.colorSpaceCreateDeviceRGB();
        // §5G DPI: the backing context is PHYSICAL pixels for sharp text.
        const w: usize = self.physW();
        const h: usize = self.physH();
        if (w == 0 or h == 0) return;
        self.bitmap_ctx = self.cg.bitmapContextCreate(self.pixels.ptr, w, h, 8, w * 4, self.colorspace, b.CG_IMAGE_ALPHA_PREMULTIPLIED_LAST | b.CG_BITMAP_BYTE_ORDER_32_BIG);
    }

    fn nsString(self: *CocoaBackend, text: [*:0]const u8) b.id {
        const ns_string = self.objc.getClass(b.NSString);
        return send(*const fn (b.Class, b.SEL, [*:0]const u8) callconv(.c) b.id)(ns_string, self.sel.stringWithUTF8String, text);
    }

    fn pushEvent(self: *CocoaBackend, ev: event.Event) void {
        if (self.target_queue) |q| {
            _ = q.push(ev);
        }
    }

    fn modsOf(self: *CocoaBackend, nev: b.id) event.Modifiers {
        const flags = send(*const fn (b.id, b.SEL) callconv(.c) b.NSUInteger)(nev, self.sel.modifierFlags);
        return modifiersFromFlags(flags);
    }

    fn posOf(self: *CocoaBackend, nev: b.id) geometry.Point {
        const pt = send(*const fn (b.id, b.SEL) callconv(.c) b.NSPoint)(nev, self.sel.locationInWindow);
        // AppKit origin is bottom-left; ZUI origin is top-left.
        return .{ .x = @floatCast(pt.x), .y = @floatCast(self.size.h - pt.y) };
    }

    fn timeOf(self: *CocoaBackend, nev: b.id) i64 {
        const t = send(*const fn (b.id, b.SEL) callconv(.c) f64)(nev, self.sel.timestamp);
        return @intFromFloat(t * 1000.0);
    }

    fn translateMouse(self: *CocoaBackend, nev: b.id, button: event.MouseButton, pressed: bool) void {
        self.pushEvent(.{ .mouse = .{
            .pos = self.posOf(nev),
            .button = button,
            .pressed = pressed,
            .modifiers = self.modsOf(nev),
            .time_ms = self.timeOf(nev),
        } });
    }

    fn translateKey(self: *CocoaBackend, nev: b.id, pressed: bool) void {
        const code = send(*const fn (b.id, b.SEL) callconv(.c) u16)(nev, self.sel.keyCode);
        const mods = self.modsOf(nev);
        const repeat = if (pressed)
            send(*const fn (b.id, b.SEL) callconv(.c) b.BOOL)(nev, self.sel.isARepeat) != 0
        else
            false;
        self.pushEvent(.{ .key = .{
            .key = keycodeToKey(code),
            .pressed = pressed,
            .modifiers = mods,
            .repeat = repeat,
        } });
        // Committed text rides the key-down (command combos excluded —
        // those are shortcuts, and the .key event already covers them).
        if (pressed and !mods.super and !mods.ctrl) {
            const chars = send(*const fn (b.id, b.SEL) callconv(.c) b.id)(nev, self.sel.characters);
            if (chars != null) {
                const utf8 = send(*const fn (b.id, b.SEL) callconv(.c) [*:0]const u8)(chars, self.sel.utf8String);
                const bytes = std.mem.span(utf8);
                if (bytes.len > 0 and bytes.len <= 32 and (bytes[0] >= 0x20 or std.mem.eql(u8, bytes, "\t"))) {
                    var text_ev = event.TextEvent{};
                    @memcpy(text_ev.text[0..bytes.len], bytes);
                    text_ev.len = @intCast(bytes.len);
                    self.pushEvent(.{ .text = text_ev });
                }
            }
        }
    }

    fn translateScroll(self: *CocoaBackend, nev: b.id) void {
        const dx = send(*const fn (b.id, b.SEL) callconv(.c) b.CGFloat)(nev, self.sel.scrollingDeltaX);
        const dy = send(*const fn (b.id, b.SEL) callconv(.c) b.CGFloat)(nev, self.sel.scrollingDeltaY);
        // AppKit reports lines (positive = up); matches ScrollEvent.
        if (dx != 0 or dy != 0) {
            self.pushEvent(.{ .scroll = .{
                .pos = self.posOf(nev),
                .dx = @floatCast(dx),
                .dy = @floatCast(dy),
                .modifiers = self.modsOf(nev),
            } });
        }
    }

    // -- view/delegate callbacks (C ABI, backend via `active`) ----------

    fn viewAcceptsFirstResponder(_: b.id, _: b.SEL) callconv(.c) b.BOOL {
        return 1;
    }

    fn viewDrawRect(_: b.id, _: b.SEL, _: b.NSRect) callconv(.c) void {
        // Layer-backed presentation bypasses drawRect entirely.
    }

    fn viewKeyDown(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| self.translateKey(nev, true);
    }

    fn viewKeyUp(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| self.translateKey(nev, false);
    }

    fn viewFlagsChanged(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        // Modifier press/release arrives without keyDown/keyUp. The key
        // itself has no normalized code (modifiers live in Modifiers);
        // pressed-ness comes from the post-change flag state.
        if (active) |self| {
            const code = send(*const fn (b.id, b.SEL) callconv(.c) u16)(nev, self.sel.keyCode);
            const mods = self.modsOf(nev);
            const pressed = switch (code) {
                0x38, 0x3C => mods.shift,
                0x3B, 0x3E => mods.ctrl,
                0x3A, 0x3D => mods.alt,
                0x36, 0x37 => mods.super,
                else => true,
            };
            self.pushEvent(.{ .key = .{ .key = .unknown, .pressed = pressed, .modifiers = mods } });
        }
    }

    fn viewMouseDown(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| {
            self.drag_event = nev;
            self.translateMouse(nev, .left, true);
        }
    }

    fn viewMouseUp(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| {
            self.resize_edge = null;
            self.translateMouse(nev, .left, false);
        }
    }

    fn viewRightMouseDown(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| self.translateMouse(nev, .right, true);
    }

    fn viewRightMouseUp(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| self.translateMouse(nev, .right, false);
    }

    fn viewOtherMouseDown(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| {
            const n = send(*const fn (b.id, b.SEL) callconv(.c) c_long)(nev, self.sel.buttonNumber);
            const btn: event.MouseButton = if (n == 2) .middle else if (n == 3) .back else .forward;
            self.translateMouse(nev, btn, true);
        }
    }

    fn viewOtherMouseUp(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| {
            const n = send(*const fn (b.id, b.SEL) callconv(.c) c_long)(nev, self.sel.buttonNumber);
            const btn: event.MouseButton = if (n == 2) .middle else if (n == 3) .back else .forward;
            self.translateMouse(nev, btn, false);
        }
    }

    fn viewMouseMoved(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| {
            if (self.resize_edge != null) self.trackResize(nev);
            self.pushEvent(.{ .mouse = .{
                .pos = self.posOf(nev),
                .button = .left,
                .pressed = false,
                .motion = true,
                .modifiers = self.modsOf(nev),
                .time_ms = self.timeOf(nev),
            } });
        }
    }

    fn viewScrollWheel(_: b.id, _: b.SEL, nev: b.id) callconv(.c) void {
        if (active) |self| self.translateScroll(nev);
    }

    fn delegateShouldClose(_: b.id, _: b.SEL, _: b.id) callconv(.c) b.BOOL {
        if (active) |self| self.pushEvent(.{ .window = .close_requested });
        return 0; // App tears down on its own quit path.
    }

    fn delegateDidResize(_: b.id, _: b.SEL, _: b.id) callconv(.c) void {
        if (active) |self| {
            // NSView frame is logical POINTS; re-query the backing scale so
            // a window moved between Retina densities stays sharp.
            const frame = send(*const fn (b.id, b.SEL) callconv(.c) b.NSRect)(self.view, self.sel.frame);
            const w: f32 = @floatCast(frame.size.w);
            const h: f32 = @floatCast(frame.size.h);
            const scale: f32 = @floatCast(@max(1.0, send(*const fn (b.id, b.SEL) callconv(.c) b.CGFloat)(self.window, self.sel.backingScaleFactor)));
            const scale_changed = scale != self.scale_factor;
            if (scale_changed) self.scale_factor = scale;
            if (w != self.size.w or h != self.size.h) {
                self.size.w = w;
                self.size.h = h;
                const npx: usize = self.physW() * self.physH() * 4;
                if (npx != self.pixels.len) {
                    if (self.allocator.realloc(self.pixels, npx)) |buf| {
                        self.pixels = buf;
                        self.recreateBitmap();
                    } else |_| {}
                }
                self.pushEvent(.{ .window = .resized });
            } else if (scale_changed) {
                // Same point size on a different backing density: buffers
                // heal at the next present; report the new scale now.
                self.recreateBitmap();
                self.pushEvent(.{ .window = .scale_changed });
            }
        }
    }

    fn delegateDidBecomeKey(_: b.id, _: b.SEL, _: b.id) callconv(.c) void {
        if (active) |self| {
            self.focused = true;
            self.pushEvent(.{ .window = .focused });
        }
    }

    fn delegateDidResignKey(_: b.id, _: b.SEL, _: b.id) callconv(.c) void {
        if (active) |self| {
            self.focused = false;
            self.pushEvent(.{ .window = .unfocused });
        }
    }

    // -- vtable ----------------------------------------------------------

    fn kindFn(_: *anyopaque) backend.BackendKind {
        return .cocoa;
    }

    fn drainEvents(self: *CocoaBackend, out: *event.EventQueue, seconds: f64) void {
        self.target_queue = out;
        const ns_date = self.objc.getClass(b.NSDate);
        const mode = self.nsString(b.NS_DEFAULT_RUN_LOOP_MODE);
        const until = if (seconds < 0)
            send(*const fn (b.id, b.SEL) callconv(.c) b.id)(ns_date, self.sel.distantPast)
        else
            send(*const fn (b.Class, b.SEL, f64) callconv(.c) b.id)(ns_date, self.sel.dateWithTimeIntervalSinceNow, seconds);
        while (true) {
            const nev = send(*const fn (b.id, b.SEL, b.NSUInteger, b.id, b.id, b.BOOL) callconv(.c) b.id)(self.app, self.sel.nextEventMatchingMask, b.NS_EVENT_MASK_ANY, until, mode, 1);
            if (nev == null) break;
            _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(self.app, self.sel.sendEvent, nev);
        }
        _ = send(*const fn (b.id, b.SEL) callconv(.c) void)(self.app, self.sel.updateWindows);
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        while (self.stash.len > 0 and out.len < limits.MAX_EVENTS_PER_FRAME) {
            if (!out.push(self.stash.pop().?)) break;
        }
        if (out.len < limits.MAX_EVENTS_PER_FRAME) self.drainEvents(out, -1);
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const seconds: f64 = @min(@as(f64, @floatFromInt(ns)) / 1e9, 1.0);
        var q = event.EventQueue{};
        self.drainEvents(&q, seconds);
        while (q.pop()) |ev| {
            if (self.stash.len < self.stash.buf.len) _ = self.stash.push(ev);
        }
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
        // Post an empty application-defined event so a blocked wait wakes.
        const nev = send(*const fn (b.Class, b.SEL, b.NSInteger, b.NSPoint, b.NSUInteger, f64, b.NSInteger, b.id, c_short, c_long, c_long) callconv(.c) b.id)(
            self.objc.getClass("NSEvent"),
            self.sel.otherEventWithType,
            27, // NSEventTypeApplicationDefined
            b.NSPoint{ .x = 0, .y = 0 },
            0,
            0,
            0,
            null,
            0,
            0,
            0,
        );
        _ = send(*const fn (b.id, b.SEL, b.id, b.BOOL) callconv(.c) void)(self.app, self.sel.postEvent, nev, 0);
    }

    fn infoFn(ptr: *anyopaque) backend.WindowInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{ .size = self.size, .scale_factor = self.scale_factor, .focused = self.focused };
    }

    fn titleFn(ptr: *anyopaque, title: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(self.window, self.sel.setTitle, self.nsString(@ptrCast(&buf)));
    }

    fn showStandardButtons(self: *@This(), show: bool) void {
        // Standard window buttons: 0 close, 1 miniaturize, 2 zoom.
        // Custom chrome draws its own; framed keeps the traffic lights.
        var kind: b.NSUInteger = 0;
        while (kind < 3) : (kind += 1) {
            const btn = send(*const fn (b.id, b.SEL, b.NSUInteger) callconv(.c) b.id)(self.window, self.sel.standardWindowButton, kind);
            _ = send(*const fn (b.id, b.SEL, b.BOOL) callconv(.c) void)(btn, self.sel.setHidden, if (show) 0 else 1);
        }
    }

    /// Framed keeps the native titlebar; frameless goes transparent with
    /// full-size content and hides the traffic lights (the app draws its
    /// own controls, like the todo titlebar does).
    fn decoratedFn(ptr: *anyopaque, decorated: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.decorated = decorated;
        _ = send(*const fn (b.id, b.SEL, b.BOOL) callconv(.c) void)(self.window, self.sel.setTitlebarAppearsTransparent, if (decorated) 0 else 1);
        _ = send(*const fn (b.id, b.SEL, b.NSInteger) callconv(.c) void)(self.window, self.sel.setTitleVisibility, if (decorated) b.NS_WINDOW_TITLE_VISIBLE else b.NS_WINDOW_TITLE_HIDDEN);
        var mask = send(*const fn (b.id, b.SEL) callconv(.c) b.NSUInteger)(self.window, self.sel.styleMask);
        if (decorated) {
            mask &= ~b.NS_WINDOW_STYLE_FULL_SIZE_CONTENT_VIEW;
        } else {
            mask |= b.NS_WINDOW_STYLE_FULL_SIZE_CONTENT_VIEW;
        }
        _ = send(*const fn (b.id, b.SEL, b.NSUInteger) callconv(.c) void)(self.window, self.sel.setStyleMask, mask);
        self.showStandardButtons(decorated);
    }

    fn dragFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const nev = self.drag_event orelse return;
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(self.window, self.sel.performWindowDragWithEvent, nev);
    }

    fn resizeFn(ptr: *anyopaque, edge: backend.ResizeEdge) void {
        // Frameless edge resize runs as a drag state machine: the next
        // mouseDragged events adjust the frame until mouseUp clears it
        // (AppKit only auto-resizes windows that keep their frame).
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.resize_edge = edge;
        const nev = self.drag_event orelse return;
        self.resize_origin = send(*const fn (b.id, b.SEL) callconv(.c) b.NSPoint)(nev, self.sel.locationInWindow);
        self.resize_frame = send(*const fn (b.id, b.SEL) callconv(.c) b.NSRect)(self.window, self.sel.frame);
    }

    /// Pure frameless-resize geometry (AppKit y grows upward: top-edge
    /// drags move origin.y with height). Tested below; trackResize feeds it
    /// live mouse deltas.
    fn resizeFrameGeometry(frame: b.NSRect, edge: backend.ResizeEdge, dx: f64, dy: f64) b.NSRect {
        var out = frame;
        // AppKit y grows upward: top-edge drags move origin.y + height.
        switch (edge) {
            .left => {
                out.origin.x += dx;
                out.size.w -= dx;
            },
            .right => out.size.w += dx,
            .bottom => {
                out.size.h -= dy;
                out.origin.y += dy;
            },
            .top => out.size.h += dy,
            .top_left => {
                out.origin.x += dx;
                out.size.w -= dx;
                out.size.h += dy;
            },
            .top_right => {
                out.size.w += dx;
                out.size.h += dy;
            },
            .bottom_left => {
                out.origin.x += dx;
                out.size.w -= dx;
                out.size.h -= dy;
                out.origin.y += dy;
            },
            .bottom_right => {
                out.size.w += dx;
                out.size.h -= dy;
                out.origin.y += dy;
            },
        }
        return out;
    }

    fn trackResize(self: *@This(), nev: b.id) void {
        const edge = self.resize_edge orelse return;
        const at = send(*const fn (b.id, b.SEL) callconv(.c) b.NSPoint)(nev, self.sel.locationInWindow);
        const frame = resizeFrameGeometry(self.resize_frame, edge, at.x - self.resize_origin.x, at.y - self.resize_origin.y);
        if (frame.size.w < 200 or frame.size.h < 200) return;
        _ = send(*const fn (b.id, b.SEL, b.NSRect, b.BOOL) callconv(.c) void)(self.window, self.sel.setFrame, frame, 1);
    }

    fn minimizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(self.window, self.sel.miniaturize, null);
    }

    fn maximizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(self.window, self.sel.zoom, null);
    }

    /// Resize the content area; the delegate's resize event resizes our
    /// buffers through the same path as a user resize.
    fn sizeFn(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (w == 0 or h == 0) return;
        const size = b.NSSize{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        _ = send(*const fn (b.id, b.SEL, b.NSSize) callconv(.c) void)(self.window, self.sel.setContentSize, size);
    }

    fn cursorFn(ptr: *anyopaque, shape: backend.CursorShape) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const cls = self.objc.getClass(b.NSCursor) orelse return;
        const sel_name = switch (shape) {
            .default => self.sel.arrowCursor,
            .text => self.sel.iBeamCursor,
            .pointer => self.sel.pointingHandCursor,
        };
        const cursor = send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(cls, sel_name);
        _ = send(*const fn (b.id, b.SEL) callconv(.c) void)(cursor, self.sel.set);
    }

    fn pasteboard(self: *CocoaBackend) b.id {
        const cls = self.objc.getClass(b.NSPasteboard) orelse return null;
        return send(*const fn (b.Class, b.SEL) callconv(.c) b.id)(cls, self.sel.generalPasteboard);
    }

    fn setClipboardFn(ptr: *anyopaque, text: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const pb = self.pasteboard();
        if (pb == null) return false;
        var buf: [limits.MAX_CLIPBOARD_BYTES]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        const str = self.nsString(@ptrCast(&buf));
        const arr_cls = self.objc.getClass("NSArray") orelse return false;
        const types = send(*const fn (b.Class, b.SEL, b.id) callconv(.c) b.id)(arr_cls, self.sel.arrayWithObject, self.nsString(b.NS_STRING_PBOARD_TYPE));
        _ = send(*const fn (b.id, b.SEL, b.id, b.id) callconv(.c) b.NSUInteger)(pb, self.sel.declareTypes, types, null);
        const ok = send(*const fn (b.id, b.SEL, b.id, b.id) callconv(.c) b.BOOL)(pb, self.sel.setString, str, self.nsString(b.NS_STRING_PBOARD_TYPE));
        return ok != 0;
    }

    fn getClipboardFn(ptr: *anyopaque, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (out.len == 0) return 0;
        const pb = self.pasteboard();
        if (pb == null) return 0;
        const str = send(*const fn (b.id, b.SEL, b.id) callconv(.c) b.id)(pb, self.sel.stringForType, self.nsString(b.NS_STRING_PBOARD_TYPE));
        if (str == null) return 0;
        const utf8 = send(*const fn (b.id, b.SEL) callconv(.c) [*:0]const u8)(str, self.sel.utf8String);
        const bytes = std.mem.span(utf8);
        const n = @min(bytes.len, out.len);
        @memcpy(out[0..n], bytes[0..n]);
        return n;
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        // §5G DPI: logical scene in, PHYSICAL backing pixels out.
        const w: u32 = @intCast(self.physW());
        const h: u32 = @intCast(self.physH());
        self.renderer.scale_factor = self.scale_factor;
        if (self.bitmap_ctx) |_| {
            self.renderer.render(self.pixels, w, h, .rgba32, gpu.vellz.Color.hex(0x0e0e13), scene, glyph_pixels, image_pixels) catch |err| {
                std.debug.print("cocoa: vellz render failed: {s}\n", .{@errorName(err)});
                return;
            };
            const image = self.cg.bitmapContextCreateImage(self.bitmap_ctx);
            if (image) |img| {
                if (self.image) |old| self.cg.imageRelease(old);
                self.image = img;
                const layer = send(*const fn (b.id, b.SEL) callconv(.c) b.id)(self.view, self.sel.layer);
                _ = send(*const fn (b.id, b.SEL, b.id) callconv(.c) void)(layer, self.objc.sel_registerName("setContents:"), img);
                const tx = self.objc.getClass(b.CATransaction) orelse return;
                _ = send(*const fn (b.Class, b.SEL) callconv(.c) void)(tx, self.sel.flush);
            }
        }
        self.presents += 1;
    }
};

test "cocoa backend reports kind and honors the platform gate" {
    var backend_instance = CocoaBackend{
        .allocator = std.testing.allocator,
        .renderer = gpu.vellz.Renderer.init(std.testing.allocator),
        .appkit = undefined,
        .foundation = undefined,
        .quartzcore = undefined,
        .coregraphics = undefined,
        .objc_lib = undefined,
        .objc = undefined,
        .cg = undefined,
        .sel = undefined,
        .app = null,
        .window = null,
        .view = null,
        .pool = null,
        .size = .{ .w = 64, .h = 64 },
        .pixels = @constCast(&[_]u8{}),
    };
    const handle = backend_instance.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.cocoa, handle.kind());
    try std.testing.expect(!CocoaBackend.isAvailable());
    if (builtin.os.tag != .macos) {
        try std.testing.expectError(error.UnsupportedPlatform, CocoaBackend.init(std.testing.allocator, "t", 100, 100));
    }
    const scene = gpu.Scene{};
    handle.present(&scene, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), backend_instance.presents);
}

test "cocoa keycodes map USB HID usages" {
    try std.testing.expectEqual(event.Key.a, keycodeToKey(0x00));
    try std.testing.expectEqual(event.Key.z, keycodeToKey(0x06));
    try std.testing.expectEqual(event.Key.space, keycodeToKey(0x31));
    try std.testing.expectEqual(event.Key.backspace, keycodeToKey(0x33));
    try std.testing.expectEqual(event.Key.escape, keycodeToKey(0x35));
    try std.testing.expectEqual(event.Key.enter, keycodeToKey(0x24));
    try std.testing.expectEqual(event.Key.tab, keycodeToKey(0x30));
    try std.testing.expectEqual(event.Key.left, keycodeToKey(0x7B));
    try std.testing.expectEqual(event.Key.right, keycodeToKey(0x7C));
    try std.testing.expectEqual(event.Key.down, keycodeToKey(0x7D));
    try std.testing.expectEqual(event.Key.up, keycodeToKey(0x7E));
    try std.testing.expectEqual(event.Key.f1, keycodeToKey(0x7A));
    try std.testing.expectEqual(event.Key.f2, keycodeToKey(0x78));
    try std.testing.expectEqual(event.Key.unknown, keycodeToKey(0x2F)); // period: text path only
    try std.testing.expectEqual(event.Key.unknown, keycodeToKey(0xFF));
}

test "cocoa AppKit ABI pins" {
    try std.testing.expectEqual(@as(b.NSInteger, 10), b.NS_EVENT_KEY_DOWN);
    try std.testing.expectEqual(@as(b.NSInteger, 11), b.NS_EVENT_KEY_UP);
    try std.testing.expectEqual(@as(b.NSInteger, 22), b.NS_EVENT_SCROLL_WHEEL);
    try std.testing.expectEqual(@as(b.NSUInteger, 1 << 17), b.NS_MOD_SHIFT);
    try std.testing.expectEqual(@as(b.NSUInteger, 1 << 20), b.NS_MOD_COMMAND);
    const mods = modifiersFromFlags(b.NS_MOD_SHIFT | b.NS_MOD_COMMAND);
    try std.testing.expect(mods.shift and mods.super and !mods.ctrl);
    try std.testing.expectEqual(@as(u32, 1 | (4 << 12)), b.CG_IMAGE_ALPHA_PREMULTIPLIED_LAST | b.CG_BITMAP_BYTE_ORDER_32_BIG);
}

test "cocoa frameless resize geometry" {
    const start = b.NSRect{ .origin = .{ .x = 100, .y = 100 }, .size = .{ .w = 680, .h = 760 } };
    const right = CocoaBackend.resizeFrameGeometry(start, .right, 20, 0);
    try std.testing.expectEqual(@as(f64, 700), right.size.w);
    try std.testing.expectEqual(@as(f64, 100), right.origin.x);
    const top_left = CocoaBackend.resizeFrameGeometry(start, .top_left, 10, 30);
    try std.testing.expectEqual(@as(f64, 110), top_left.origin.x);
    try std.testing.expectEqual(@as(f64, 670), top_left.size.w);
    try std.testing.expectEqual(@as(f64, 790), top_left.size.h);
    const bottom = CocoaBackend.resizeFrameGeometry(start, .bottom, 0, -40);
    try std.testing.expectEqual(@as(f64, 800), bottom.size.h);
    try std.testing.expectEqual(@as(f64, 60), bottom.origin.y);
}
