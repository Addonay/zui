//! Port of vello_common target.rs (Apache-2.0 OR MIT).
//!
//! `TargetInit(C)` is generic over the clear color type, exactly like
//! upstream; `vello_cpu` aliases it to
//! `TargetInit(peniko.AlphaColor(peniko.Srgb))` and the GPU backend to its own
//! clear-settings type.
//!
//! Ownership/allocator note: a tagged value with no allocation. When `C` owns
//! resources, the caller owns them just as with any other `TargetInit` value.

const std = @import("std");

/// Controls how existing target contents are handled before drawing.
pub fn TargetInit(comptime C: type) type {
    return union(enum) {
        /// Composite rendered content over the existing target contents with
        /// src-over blending.
        src_over: void,
        /// Clear the drawing surface with the specified color before drawing.
        ///
        /// The clear color is treated as an isolated background on top of
        /// which the fully rendered scene is composited. In particular, it
        /// will not be used as the backdrop for blending operations in the
        /// main scene.
        clear: C,

        const Self = @This();

        /// The default initialization: composite over the existing contents.
        pub const DEFAULT: Self = .src_over;

        /// Transform the clear value while preserving the target
        /// initialization mode.
        ///
        /// Upstream takes an `impl FnOnce(C) -> T`; Zig receives a plain
        /// function (or any value callable as `f(clear)`) and infers `T` from
        /// its return type.
        pub fn map(self: Self, f: anytype) TargetInit(ReturnType(@TypeOf(f))) {
            const T = ReturnType(@TypeOf(f));
            return switch (self) {
                .src_over => .src_over,
                .clear => |clear| TargetInit(T).initClear(f(clear)),
            };
        }

        /// Build a `Clear` initialization.
        pub fn initClear(clear: C) Self {
            return .{ .clear = clear };
        }
    };
}

fn ReturnType(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .@"fn" => |info| info.return_type orelse
            @compileError("TargetInit.map requires a function with a concrete return type"),
        else => @compileError("TargetInit.map expects a function"),
    };
}

test "target_init_map" {
    const Init = TargetInit(u8);
    const mapped = Init.initClear(3).map(struct {
        fn double(value: u8) u16 {
            return @as(u16, value) * 2;
        }
    }.double);
    try std.testing.expectEqual(@as(u16, 6), mapped.clear);

    const untouched: Init = .src_over;
    const still: TargetInit(u16) = untouched.map(struct {
        fn double(value: u8) u16 {
            return @as(u16, value) * 2;
        }
    }.double);
    const expected: TargetInit(u16) = .src_over;
    try std.testing.expectEqual(expected, still);
    try std.testing.expectEqual(Init.DEFAULT, untouched);
}
