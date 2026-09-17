//! Objective-C runtime + AppKit/CoreGraphics bindings for Cocoa.
//!
//! Tables resolved with dlopen at backend init — no headers, no link.
//! Classes/selectors resolve at startup; every AppKit call flows through
//! the `msg_send` pointer cast to a concrete signature per call site.

pub const id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const IMP = ?*const anyopaque;
pub const BOOL = c_char;
pub const NSInteger = c_long;
pub const NSUInteger = c_ulong;
pub const CGFloat = f64;

pub const NSPoint = extern struct { x: CGFloat, y: CGFloat };
pub const NSSize = extern struct { w: CGFloat, h: CGFloat };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// Objective-C runtime table, resolved from libobjc at backend init.
/// No link-time `extern` declarations here: referencing one would force the
/// test binary to link AppKit on Linux. Everything flows through
/// `msg_send`, cast to a concrete signature per call site.
pub const ObjcApi = struct {
    getClass: *const fn ([*:0]const u8) callconv(.c) Class,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL,
    allocateClassPair: *const fn (Class, [*:0]const u8, usize) callconv(.c) Class,
    registerClassPair: *const fn (Class) callconv(.c) void,
    addMethod: *const fn (Class, SEL, IMP, [*:0]const u8) callconv(.c) BOOL,
    msg_send: *anyopaque,

    pub fn load(lib: @import("../dl.zig").Library) ?ObjcApi {
        const getClass = lib.lookup(*const fn ([*:0]const u8) callconv(.c) Class, "objc_getClass") orelse return null;
        const sel_registerName = lib.lookup(*const fn ([*:0]const u8) callconv(.c) SEL, "sel_registerName") orelse return null;
        const allocateClassPair = lib.lookup(@FieldType(ObjcApi, "allocateClassPair"), "objc_allocateClassPair") orelse return null;
        const registerClassPair = lib.lookup(*const fn (Class) callconv(.c) void, "objc_registerClassPair") orelse return null;
        const addMethod = lib.lookup(*const fn (Class, SEL, IMP, [*:0]const u8) callconv(.c) BOOL, "class_addMethod") orelse return null;
        const msg_send = lib.lookup(*anyopaque, "objc_msgSend") orelse return null;
        return .{ .getClass = getClass, .sel_registerName = sel_registerName, .allocateClassPair = allocateClassPair, .registerClassPair = registerClassPair, .addMethod = addMethod, .msg_send = msg_send };
    }
};

/// CoreGraphics table, resolved from the CoreGraphics framework.
pub const CoreGraphicsApi = struct {
    bitmapContextCreate: *const fn (?*anyopaque, usize, usize, usize, usize, ?*anyopaque, u32) callconv(.c) ?*anyopaque,
    colorSpaceCreateDeviceRGB: *const fn () callconv(.c) ?*anyopaque,
    bitmapContextCreateImage: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    imageRelease: *const fn (?*anyopaque) callconv(.c) void,
    contextRelease: *const fn (?*anyopaque) callconv(.c) void,

    pub fn load(lib: @import("../dl.zig").Library) ?CoreGraphicsApi {
        return .{
            .bitmapContextCreate = lib.lookup(@FieldType(CoreGraphicsApi, "bitmapContextCreate"), "CGBitmapContextCreate") orelse return null,
            .colorSpaceCreateDeviceRGB = lib.lookup(@FieldType(CoreGraphicsApi, "colorSpaceCreateDeviceRGB"), "CGColorSpaceCreateDeviceRGB") orelse return null,
            .bitmapContextCreateImage = lib.lookup(@FieldType(CoreGraphicsApi, "bitmapContextCreateImage"), "CGBitmapContextCreateImage") orelse return null,
            .imageRelease = lib.lookup(@FieldType(CoreGraphicsApi, "imageRelease"), "CGImageRelease") orelse return null,
            .contextRelease = lib.lookup(@FieldType(CoreGraphicsApi, "contextRelease"), "CGContextRelease") orelse return null,
        };
    }
};

// Framework paths resolved with dlopen at backend init.
pub const appkit_path: [*:0]const u8 = "/System/Library/Frameworks/AppKit.framework/AppKit";
pub const foundation_path: [*:0]const u8 = "/System/Library/Frameworks/Foundation.framework/Foundation";
pub const quartzcore_path: [*:0]const u8 = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
pub const coregraphics_path: [*:0]const u8 = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
pub const objc_path: [*:0]const u8 = "/usr/lib/libobjc.A.dylib";

// Class names.
pub const NSApplication = "NSApplication";
pub const NSWindow = "NSWindow";
pub const NSView = "NSView";
pub const NSString = "NSString";
pub const NSAutoreleasePool = "NSAutoreleasePool";
pub const NSDate = "NSDate";
pub const NSPasteboard = "NSPasteboard";
pub const NSCursor = "NSCursor";
pub const CATransaction = "CATransaction";

// AppKit ABI values (stable across releases; pinned by backend tests).
pub const NS_APPLICATION_ACTIVATION_POLICY_REGULAR: NSInteger = 0;
pub const NS_WINDOW_STYLE_TITLED: NSUInteger = 1;
pub const NS_WINDOW_STYLE_CLOSABLE: NSUInteger = 2;
pub const NS_WINDOW_STYLE_MINIATURIZABLE: NSUInteger = 4;
pub const NS_WINDOW_STYLE_RESIZABLE: NSUInteger = 8;
pub const NS_WINDOW_STYLE_FULL_SIZE_CONTENT_VIEW: NSUInteger = 1 << 15;
pub const NS_BACKING_STORE_BUFFERED: NSUInteger = 2;
pub const NS_WINDOW_TITLE_VISIBLE: NSInteger = 0;
pub const NS_WINDOW_TITLE_HIDDEN: NSInteger = 1;
pub const NS_VIEW_WIDTH_SIZABLE: NSUInteger = 2;
pub const NS_VIEW_HEIGHT_SIZABLE: NSUInteger = 16;
pub const NS_EVENT_MASK_ANY: NSUInteger = ~@as(NSUInteger, 0);

// NSEventType values (AppKit ABI).
pub const NS_EVENT_LEFT_MOUSE_DOWN: NSInteger = 1;
pub const NS_EVENT_LEFT_MOUSE_UP: NSInteger = 2;
pub const NS_EVENT_RIGHT_MOUSE_DOWN: NSInteger = 3;
pub const NS_EVENT_RIGHT_MOUSE_UP: NSInteger = 4;
pub const NS_EVENT_MOUSE_MOVED: NSInteger = 5;
pub const NS_EVENT_LEFT_MOUSE_DRAGGED: NSInteger = 6;
pub const NS_EVENT_RIGHT_MOUSE_DRAGGED: NSInteger = 7;
pub const NS_EVENT_OTHER_MOUSE_DOWN: NSInteger = 25;
pub const NS_EVENT_OTHER_MOUSE_UP: NSInteger = 26;
pub const NS_EVENT_KEY_DOWN: NSInteger = 10;
pub const NS_EVENT_KEY_UP: NSInteger = 11;
pub const NS_EVENT_FLAGS_CHANGED: NSInteger = 12;
pub const NS_EVENT_SCROLL_WHEEL: NSInteger = 22;

// NSEventModifierFlags (AppKit ABI).
pub const NS_MOD_SHIFT: NSUInteger = 1 << 17;
pub const NS_MOD_CONTROL: NSUInteger = 1 << 18;
pub const NS_MOD_OPTION: NSUInteger = 1 << 19;
pub const NS_MOD_COMMAND: NSUInteger = 1 << 20;

// Pasteboard + cursor string constants.
pub const NS_STRING_PBOARD_TYPE: [*:0]const u8 = "NSStringPboardType";
pub const NS_DEFAULT_RUN_LOOP_MODE: [*:0]const u8 = "kCFRunLoopDefaultMode";

// CoreGraphics bitmap constants (stable ABI).
pub const CG_IMAGE_ALPHA_PREMULTIPLIED_LAST: u32 = 1;
pub const CG_BITMAP_BYTE_ORDER_32_BIG: u32 = 4 << 12;
