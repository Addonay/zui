//! Objective-C runtime, Metal and libdispatch access for the Metal backend, from
//! sokol_gfx.h:7519-7718 (types) and 16010-18427 (calls). No C headers are imported:
//! every message is sent through objc_msgSend with a function type built at compile
//! time from the argument types, which is the ABI the Objective-C runtime expects
//! (objc_msgSend itself is a trampoline and is never called variadically).
//!
//! All runtime symbols are declared only for Apple targets. On other targets every
//! entry point returns a zero value; `Backend.init` refuses to start there, so those
//! paths are never reached at runtime, and they keep the backend type-checkable.
const std = @import("std");
const builtin = @import("builtin");

/// True when the Objective-C runtime and Metal can be used.
pub const available = builtin.os.tag.isDarwin();

/// `id`, `nil` is null.
pub const Id = ?*anyopaque;
/// `SEL`.
pub const Sel = ?*anyopaque;
/// `NSUInteger`.
pub const Uint = usize;

const native = if (available) struct {
    extern fn objc_msgSend() void;
    extern fn objc_msgSend_stret() void;
    extern fn objc_autoreleasePoolPush() ?*anyopaque;
    extern fn objc_autoreleasePoolPop(token: ?*anyopaque) void;
    extern fn MTLCreateSystemDefaultDevice() Id;
    extern fn objc_getClass(name: [*:0]const u8) Id;
    extern fn sel_registerName(name: [*:0]const u8) Sel;
    extern fn objc_retain(obj: Id) Id;
    extern fn objc_release(obj: Id) void;
    extern fn dispatch_semaphore_create(value: isize) Id;
    extern fn dispatch_semaphore_wait(sem: Id, timeout: u64) isize;
    extern fn dispatch_semaphore_signal(sem: Id) isize;
    extern fn dispatch_data_create(buffer: ?*const anyopaque, size: usize, queue: ?*anyopaque, destructor: ?*anyopaque) Id;
    // the isa of a block literal without captures, see globalBlock()
    extern var _NSConcreteGlobalBlock: u8;
    extern var _NSConcreteStackBlock: u8;
} else struct {};

/// DISPATCH_TIME_FOREVER.
pub const time_forever: u64 = ~@as(u64, 0);

/// Returns the zero value of `R` on targets without Objective-C.
fn unavailable(comptime R: type) R {
    if (R == void) return;
    return std.mem.zeroes(R);
}

// ---------------------------------------------------------------- geometry and structs

/// MTLSize.
pub const Size = extern struct { width: Uint = 0, height: Uint = 0, depth: Uint = 0 };
/// MTLOrigin.
pub const Origin = extern struct { x: Uint = 0, y: Uint = 0, z: Uint = 0 };
/// MTLRegion.
pub const Region = extern struct { origin: Origin = .{}, size: Size = .{} };
/// MTLViewport.
pub const Viewport = extern struct { origin_x: f64, origin_y: f64, width: f64, height: f64, znear: f64, zfar: f64 };
/// MTLScissorRect.
pub const ScissorRect = extern struct { x: Uint, y: Uint, width: Uint, height: Uint };
/// MTLClearColor.
pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
/// NSRange.
pub const NSRange = extern struct { location: Uint, length: Uint };

pub fn region2d(x: Uint, y: Uint, width: Uint, height: Uint) Region {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height, .depth = 1 } };
}

pub fn region3d(x: Uint, y: Uint, z: Uint, width: Uint, height: Uint, depth: Uint) Region {
    return .{ .origin = .{ .x = x, .y = y, .z = z }, .size = .{ .width = width, .height = height, .depth = depth } };
}

// ---------------------------------------------------------------- enumerations

pub const PixelFormat = enum(Uint) {
    invalid = 0,
    r8unorm = 10,
    r8unorm_srgb = 11,
    r8snorm = 12,
    r8uint = 13,
    r8sint = 14,
    r16unorm = 20,
    r16snorm = 22,
    r16uint = 23,
    r16sint = 24,
    r16float = 25,
    rg8unorm = 30,
    rg8unorm_srgb = 31,
    rg8snorm = 32,
    rg8uint = 33,
    rg8sint = 34,
    r32uint = 53,
    r32sint = 54,
    r32float = 55,
    rg16unorm = 60,
    rg16snorm = 62,
    rg16uint = 63,
    rg16sint = 64,
    rg16float = 65,
    rgba8unorm = 70,
    rgba8unorm_srgb = 71,
    rgba8snorm = 72,
    rgba8uint = 73,
    rgba8sint = 74,
    bgra8unorm = 80,
    bgra8unorm_srgb = 81,
    rgb10a2unorm = 90,
    rgb10a2uint = 91,
    rg11b10float = 92,
    rgb9e5float = 93,
    rg32uint = 103,
    rg32sint = 104,
    rg32float = 105,
    rgba16unorm = 110,
    rgba16snorm = 112,
    rgba16uint = 113,
    rgba16sint = 114,
    rgba16float = 115,
    rgba32uint = 123,
    rgba32sint = 124,
    rgba32float = 125,
    bc1_rgba = 130,
    bc1_rgba_srgb = 131,
    bc2_rgba = 132,
    bc2_rgba_srgb = 133,
    bc3_rgba = 134,
    bc3_rgba_srgb = 135,
    bc4_runorm = 140,
    bc4_rsnorm = 141,
    bc5_rgunorm = 142,
    bc5_rgsnorm = 143,
    bc6h_rgbfloat = 150,
    bc6h_rgbufloat = 151,
    bc7_rgbaunorm = 152,
    bc7_rgbaunorm_srgb = 153,
    eac_r11unorm = 170,
    eac_r11snorm = 172,
    eac_rg11unorm = 174,
    eac_rg11snorm = 176,
    eac_rgba8 = 178,
    eac_rgba8_srgb = 179,
    etc2_rgb8 = 180,
    etc2_rgb8_srgb = 181,
    etc2_rgb8a1 = 182,
    etc2_rgb8a1_srgb = 183,
    astc_4x4_srgb = 186,
    astc_4x4_ldr = 204,
    depth32float = 252,
    stencil8 = 253,
    depth32float_stencil8 = 260,
    _,
};

pub const VertexFormat = enum(Uint) {
    invalid = 0,
    uchar4 = 3,
    char4 = 6,
    uchar4normalized = 9,
    char4normalized = 12,
    ushort2 = 13,
    ushort4 = 15,
    short2 = 16,
    short4 = 18,
    ushort2normalized = 19,
    ushort4normalized = 21,
    short2normalized = 22,
    short4normalized = 24,
    half2 = 25,
    half4 = 27,
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 31,
    int = 32,
    int2 = 33,
    int3 = 34,
    int4 = 35,
    uint = 36,
    uint2 = 37,
    uint3 = 38,
    uint4 = 39,
    int1010102normalized = 40,
    uint1010102normalized = 41,
    _,
};

pub const VertexStepFunction = enum(Uint) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
    _,
};

pub const PrimitiveType = enum(Uint) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
    _,
};

pub const IndexType = enum(Uint) {
    uint16 = 0,
    uint32 = 1,
    _,
};

pub const CullMode = enum(Uint) {
    none = 0,
    front = 1,
    back = 2,
    _,
};

pub const Winding = enum(Uint) {
    clockwise = 0,
    counter_clockwise = 1,
    _,
};

pub const LoadAction = enum(Uint) {
    dont_care = 0,
    load = 1,
    clear = 2,
    _,
};

pub const StoreAction = enum(Uint) {
    dont_care = 0,
    store = 1,
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
    _,
};

pub const CompareFunction = enum(Uint) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
    _,
};

pub const StencilOperation = enum(Uint) {
    keep = 0,
    zero = 1,
    replace = 2,
    increment_clamp = 3,
    decrement_clamp = 4,
    invert = 5,
    increment_wrap = 6,
    decrement_wrap = 7,
    _,
};

pub const BlendOperation = enum(Uint) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
    _,
};

pub const BlendFactor = enum(Uint) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    destination_color = 6,
    one_minus_destination_color = 7,
    destination_alpha = 8,
    one_minus_destination_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
    source1_color = 15,
    one_minus_source1_color = 16,
    source1_alpha = 17,
    one_minus_source1_alpha = 18,
    _,
};

/// MTLColorWriteMask bits.
pub const color_write_mask_none: Uint = 0;
pub const color_write_mask_red: Uint = 1 << 3;
pub const color_write_mask_green: Uint = 1 << 2;
pub const color_write_mask_blue: Uint = 1 << 1;
pub const color_write_mask_alpha: Uint = 1 << 0;
pub const color_write_mask_all: Uint = 0xF;

pub const SamplerAddressMode = enum(Uint) {
    clamp_to_edge = 0,
    mirror_clamp_to_edge = 1,
    repeat = 2,
    mirror_repeat = 3,
    clamp_to_zero = 4,
    clamp_to_border_color = 5,
    _,
};

pub const SamplerBorderColor = enum(Uint) {
    transparent_black = 0,
    opaque_black = 1,
    opaque_white = 2,
    _,
};

pub const SamplerMinMagFilter = enum(Uint) {
    nearest = 0,
    linear = 1,
    _,
};

pub const SamplerMipFilter = enum(Uint) {
    not_mipmapped = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const TextureType = enum(Uint) {
    type_1d = 0,
    type_1d_array = 1,
    type_2d = 2,
    type_2d_array = 3,
    type_2d_multisample = 4,
    type_cube = 5,
    type_cube_array = 6,
    type_3d = 7,
    type_2d_multisample_array = 8,
    _,
};

/// MTLTextureUsage bits.
pub const texture_usage_shader_read: Uint = 1;
pub const texture_usage_shader_write: Uint = 2;
pub const texture_usage_render_target: Uint = 4;

/// MTLResourceOptions values.
pub const resource_cpu_cache_write_combined: Uint = 1;
pub const resource_storage_shared: Uint = 0;
pub const resource_storage_managed: Uint = 1 << 4;
pub const resource_storage_private: Uint = 2 << 4;

/// MTLMutability.
pub const mutability_immutable: Uint = 2;

/// MTLGPUFamily.
pub const gpu_family_apple1: Uint = 1001;
pub const gpu_family_apple7: Uint = 1007;
pub const gpu_family_mac2: Uint = 2002;
pub const gpu_family_metal3: Uint = 5001;

// ---------------------------------------------------------------- messages

/// Returns the `SEL` for `name`, registered once per call site and cached.
pub fn selector(comptime name: [:0]const u8) Sel {
    if (comptime !available) return unavailable(Sel);
    const Cache = struct {
        var value: std.atomic.Value(Sel) = .init(null);
    };
    if (Cache.value.load(.acquire)) |value| return value;
    const value = native.sel_registerName(name.ptr);
    Cache.value.store(value, .release);
    return value;
}

/// Returns the class object `name`, looked up once per call site and cached.
pub fn cls(comptime name: [:0]const u8) Id {
    if (comptime !available) return unavailable(Id);
    const Cache = struct {
        var value: std.atomic.Value(Id) = .init(null);
    };
    if (Cache.value.load(.acquire)) |value| return value;
    const value = native.objc_getClass(name.ptr);
    Cache.value.store(value, .release);
    return value;
}

/// Sends `name` to `target` and returns the result of type `R`. `args` is a tuple of
/// typed values, each passed with its own type in the function type of objc_msgSend.
pub fn msg(comptime R: type, target: Id, comptime name: [:0]const u8, args: anytype) R {
    if (comptime !available) return unavailable(R);
    const field_types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    comptime var param_types: [field_types.len + 2]type = undefined;
    comptime var param_attrs: [field_types.len + 2]std.lang.Type.Fn.ParamAttributes = undefined;
    param_types[0] = Id;
    param_types[1] = Sel;
    param_attrs[0] = .{};
    param_attrs[1] = .{};
    inline for (field_types, 0..) |FieldType, i| {
        param_types[i + 2] = switch (FieldType) {
            comptime_int => Uint,
            comptime_float => f64,
            else => FieldType,
        };
        param_attrs[i + 2] = .{};
    }
    const Fn = @Fn(&param_types, &param_attrs, R, .{ .@"callconv" = .c });
    const aggregate = @typeInfo(R) == .@"struct" or @typeInfo(R) == .@"union";
    const stret = builtin.cpu.arch == .x86_64 and aggregate and @sizeOf(R) > 16;
    const send: *const Fn = @ptrCast(if (stret) &native.objc_msgSend_stret else &native.objc_msgSend);
    return @call(.auto, send, .{ target, selector(name) } ++ args);
}

/// Returns `[[class alloc] init]`, an owned reference.
pub fn allocInit(comptime class_name: [:0]const u8) Id {
    const object = msg(Id, cls(class_name), "alloc", .{});
    return msg(Id, object, "init", .{});
}

/// Adds a reference to an Objective-C object.
pub fn retain(obj: Id) Id {
    if (comptime !available) return unavailable(Id);
    return native.objc_retain(obj);
}

/// Drops a reference to an Objective-C object (null is ignored).
pub fn release(obj: Id) void {
    if (comptime !available) return unavailable(void);
    if (obj) |_| native.objc_release(obj);
}

/// `[NSString stringWithUTF8String:]`, the result is autoreleased.
pub fn nsString(text: [*:0]const u8) Id {
    return msg(Id, cls("NSString"), "stringWithUTF8String:", .{text});
}

/// `[object UTF8String]`, valid while `object` lives.
pub fn utf8(object: Id) ?[*:0]const u8 {
    return msg(?[*:0]const u8, object, "UTF8String", .{});
}

/// `[error localizedDescription]` as a C string, or null when there is no error.
pub fn errorText(err: Id) ?[*:0]const u8 {
    const description = msg(Id, err, "localizedDescription", .{});
    return utf8(description);
}

// ---------------------------------------------------------------- dispatch

pub fn semaphoreCreate(value: isize) Id {
    if (comptime !available) return unavailable(Id);
    return native.dispatch_semaphore_create(value);
}

pub fn semaphoreWait(sem: Id) void {
    if (comptime !available) return unavailable(void);
    _ = native.dispatch_semaphore_wait(sem, time_forever);
}

pub fn semaphoreSignal(sem: Id) void {
    if (comptime !available) return unavailable(void);
    _ = native.dispatch_semaphore_signal(sem);
}

/// dispatch_data_create() with the default destructor, which copies the bytes.
pub fn dispatchDataCopy(bytes: [*]const u8, len: usize) Id {
    if (comptime !available) return unavailable(Id);
    return native.dispatch_data_create(bytes, len, null, null);
}

/// Objective-C block literal layout (Apple Block ABI).
pub const BlockDescriptor = extern struct { reserved: usize = 0, size: usize = 0 };
pub const BlockLiteral = extern struct {
    isa: ?*const anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (?*anyopaque, Id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

/// A block without captures, usable by any method that copies its block argument.
/// `invoke` receives the block pointer and the single object argument.
pub fn globalBlock(comptime invoke: *const fn (?*anyopaque, Id) callconv(.c) void) Id {
    if (comptime !available) return unavailable(Id);
    const Static = struct {
        const descriptor: BlockDescriptor = .{ .size = @sizeOf(BlockLiteral) };
        const literal: BlockLiteral = .{
            .isa = @ptrCast(&native._NSConcreteGlobalBlock),
            .flags = 1 << 28, // BLOCK_IS_GLOBAL
            .reserved = 0,
            .invoke = invoke,
            .descriptor = &descriptor,
        };
    };
    return @ptrCast(@constCast(&Static.literal));
}

/// A captured stack block. Metal copies its completion handler; the copy/dispose
/// helpers retain the captured semaphore until the runtime releases that copy.
pub const CompletionDescriptor = extern struct {
    reserved: usize = 0,
    size: usize = @sizeOf(CompletionBlock),
    copy: *const fn (*CompletionBlock, *const CompletionBlock) callconv(.c) void,
    dispose: *const fn (*const CompletionBlock) callconv(.c) void,
};
pub const CompletionBlock = extern struct {
    isa: ?*const anyopaque,
    flags: i32 = 1 << 25, // BLOCK_HAS_COPY_DISPOSE
    reserved: i32 = 0,
    invoke: *const fn (?*anyopaque, Id) callconv(.c) void,
    descriptor: *const CompletionDescriptor,
    semaphore: Id,
    loss: ?*std.atomic.Value(i32),
};
fn copyCompletion(dst: *CompletionBlock, src: *const CompletionBlock) callconv(.c) void {
    dst.semaphore = retain(src.semaphore);
}
fn disposeCompletion(block: *const CompletionBlock) callconv(.c) void {
    release(block.semaphore);
}
pub fn completionBlock(comptime invoke: *const fn (?*anyopaque, Id) callconv(.c) void, semaphore: Id, loss: ?*std.atomic.Value(i32)) CompletionBlock {
    const Static = struct {
        const descriptor: CompletionDescriptor = .{ .copy = copyCompletion, .dispose = disposeCompletion };
    };
    return .{ .isa = if (available) @ptrCast(&native._NSConcreteStackBlock) else null, .invoke = invoke, .descriptor = &Static.descriptor, .semaphore = semaphore, .loss = loss };
}

/// An owned default Metal device for native hosts; release it with release().
pub fn defaultDevice() Id {
    if (comptime !available) return null;
    return native.MTLCreateSystemDefaultDevice();
}
/// Headless hosts need an autorelease pool on every thread using Objective-C.
/// Cocoa applications normally provide one through their event loop.
pub const AutoreleasePool = struct {
    token: ?*anyopaque,
    pub fn init() AutoreleasePool {
        return .{ .token = if (available) native.objc_autoreleasePoolPush() else null };
    }
    pub fn deinit(self: *AutoreleasePool) void {
        if (comptime available) native.objc_autoreleasePoolPop(self.token);
        self.* = undefined;
    }
};
