//! Port of vello_common util.rs (Apache-2.0 OR MIT).
//!
//! This module is a leaf in the Zig dependency graph: it may use `std`,
//! `common/math`, `common/geometry`, `kurbo`, `peniko`, and `simd`, but never
//! `tile.zig` or `strip.zig`. Upstream's `strip_bbox` (which needs `Strip`)
//! therefore lives in `strip.zig`; the rectangle-snapping helpers below mirror
//! `Tile::WIDTH`/`Tile::HEIGHT` as local constants so this file stays a leaf
//! (`tile.zig` remains the owner of the canonical values).
//!
//! Ownership/allocator note: `Pool`, `VecPool`, and `RetainVec` own heap
//! storage and take an explicit allocator on every growing operation
//! (`submit`, `resizeWith`, `withLen`, `deinit`). The numeric helpers are
//! allocation-free. SIMD helpers operate on the fixed-width vectors in
//! `src/simd`; the scalar loops in consumers must produce identical results.

const std = @import("std");
const simd_backend = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const geometry = @import("geometry.zig");
const math = @import("math.zig");

const RectU16 = geometry.RectU16;

/// Mirrors `Tile::WIDTH`; kept local so this file does not import `tile.zig`.
pub const TILE_WIDTH: u16 = 4;
/// Mirrors `Tile::HEIGHT`; kept local so this file does not import `tile.zig`.
pub const TILE_HEIGHT: u16 = 4;

/// Convert `f32x16` to `u8x16`.
///
/// **Important note: The values need to be between 0.0 and 1.0, otherwise you
/// might get inconsistent results across different platforms.**
///
/// Upstream truncates `f32x16` to `u32x16` and takes the low byte of each
/// lane. On x86 that is `cvttps2dq`; on the scalar fallback it is Rust
/// `as u32` (saturating). The two differ outside 0..1, which upstream
/// documents as the only portable range. The lane loop below reproduces the
/// x86 behavior without target intrinsics.
pub fn f32ToU8(val: simd_backend.F32x16) simd_backend.U8x16 {
    var out: simd_backend.U8x16 = undefined;
    inline for (0..@typeInfo(simd_backend.F32x16).vector.len) |lane| {
        out[lane] = f32LaneToU8(val[lane]);
    }
    return out;
}

inline fn f32LaneToU8(x: f32) u8 {
    if (std.math.isNan(x)) return 0;
    const truncated = @trunc(x);
    if (truncated >= 2147483648.0 or truncated < -2147483648.0) return 0;
    const as_i32: i32 = @intFromFloat(truncated);
    return @truncate(@as(u32, @bitCast(as_i32)));
}

/// `(v + 255) >> 8` for unsigned 16-bit SIMD vectors.
///
/// Replaces upstream's sealed `Div255Ext` trait; Zig resolves this at compile
/// time and rejects non-`u16` vectors.
pub inline fn div255(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    const lanes = switch (@typeInfo(T)) {
        .vector => |info| blk: {
            if (info.child != u16) {
                @compileError("div255 expects a u16 vector, got " ++ @typeName(T));
            }
            break :blk info.len;
        },
        else => @compileError("div255 expects a u16 vector, got " ++ @typeName(T)),
    };
    const Shift = @Vector(lanes, std.math.Log2Int(u16));
    return (v + @as(T, @splat(255))) >> @as(Shift, @splat(8));
}

/// The widened counterpart of the vector types used by `widen`.
fn Widened(comptime V: type) type {
    if (V == simd_backend.U8x16) return simd_backend.U16x16;
    if (V == simd_backend.U16x16) return simd_backend.U32x16;
    @compileError("widen: unsupported vector type " ++ @typeName(V));
}

/// Widen a SIMD vector, combining the two widened halves.
pub inline fn widen(value: anytype) Widened(@TypeOf(value)) {
    return @intCast(value);
}

/// The narrowed counterpart of the vector types used by `narrow`.
fn Narrowed(comptime V: type) type {
    if (V == simd_backend.U16x16) return simd_backend.U8x16;
    if (V == simd_backend.U32x16) return simd_backend.U16x16;
    @compileError("narrow: unsupported vector type " ++ @typeName(V));
}

/// Narrow a SIMD vector, combining the two narrowed halves (truncating).
pub inline fn narrow(value: anytype) Narrowed(@TypeOf(value)) {
    return @truncate(value);
}

/// Narrow a SIMD vector, combining the two narrowed halves with saturation.
pub inline fn saturatingNarrow(value: anytype) Narrowed(@TypeOf(value)) {
    const T = @TypeOf(value);
    return @intCast(@min(value, @as(T, @splat(255))));
}

/// Perform a normalized multiplication for a SIMD vector of `u8` values.
pub inline fn normalizedMulU8(a: simd_backend.U8x16, b: simd_backend.U8x16) simd_backend.U16x16 {
    return div255(widen(a) * widen(b));
}

/// Check if an affine transform is a pure integer translation.
///
/// Returns true if the transform only contains integer translation (no
/// rotation, skew, or scaling), meaning rectangles will remain pixel-aligned
/// after transformation.
pub fn isIntegerTranslation(transform: kurbo.Affine) bool {
    const coeffs = transform.asCoeffs();
    return math.isNearlyZero(coeffs[0] - 1.0) and
        math.isNearlyZero(coeffs[1]) and
        math.isNearlyZero(coeffs[2]) and
        math.isNearlyZero(coeffs[3] - 1.0) and
        math.isNearlyZero(coeffs[4] - @round(coeffs[4])) and
        math.isNearlyZero(coeffs[5] - @round(coeffs[5]));
}

/// Check if an affine transform has no skewing (i.e. preserves axis
/// alignment).
pub fn isAxisAligned(transform: kurbo.Affine) bool {
    const coeffs = transform.asCoeffs();
    return math.isNearlyZero(coeffs[1]) and math.isNearlyZero(coeffs[2]);
}

/// Extract scale factors from an affine transform using singular value
/// decomposition.
///
/// Returns `[scale_x, scale_y]`, each clamped to a minimum of `1e-6` to avoid
/// division by zero. This mirrors kurbo's internal `svd()` calculation.
pub fn extractScales(transform: kurbo.Affine) [2]f32 {
    const coeffs = transform.asCoeffs();
    const a: f32 = @floatCast(coeffs[0]);
    const b: f32 = @floatCast(coeffs[1]);
    const c: f32 = @floatCast(coeffs[2]);
    const d: f32 = @floatCast(coeffs[3]);

    const a2 = a * a;
    const b2 = b * b;
    const c2 = c * c;
    const d2 = d * d;
    const s1 = a2 + b2 + c2 + d2;
    const diff = a2 - b2 + c2 - d2;
    const cross = a * b + c * d;
    const s2 = @sqrt(diff * diff + 4.0 * cross * cross);

    const scale_x = @sqrt(0.5 * (s1 + s2));
    const scale_y = @sqrt(0.5 * (s1 - s2));

    return .{ @max(scale_x, 1e-6), @max(scale_y, 1e-6) };
}

/// Replaces upstream's `RectExt` trait: Zig has no extension methods, so the
/// snapping helpers are namespace functions that dispatch on the rectangle
/// type at compile time.
pub const RectExt = struct {
    /// Snap the rect to whole tile coordinates.
    pub fn snapToTileCoordinates(rect: anytype) @TypeOf(rect) {
        const T = @TypeOf(rect);
        if (T == kurbo.Rect) return snapRectToTileCoordinates(rect);
        if (T == RectU16) return snapRectU16ToTileCoordinates(rect);
        @compileError("snapToTileCoordinates supports kurbo.Rect and RectU16, got " ++ @typeName(T));
    }
};

fn snapRectToTileCoordinates(rect: kurbo.Rect) kurbo.Rect {
    const x0 = snapDown(rect.x0, TILE_WIDTH);
    const y0 = snapDown(rect.y0, TILE_HEIGHT);

    if (rect.isZeroArea()) {
        return kurbo.Rect.new(x0, y0, x0, y0);
    }

    return kurbo.Rect.new(
        x0,
        y0,
        math.snapUp(rect.x1, TILE_WIDTH),
        math.snapUp(rect.y1, TILE_HEIGHT),
    );
}

fn snapRectU16ToTileCoordinates(rect: RectU16) RectU16 {
    // This method will panic if we have a viewport of size u16::MAX and draw
    // at the very edge, but better than returning a wrong result.
    const x0 = (rect.x0 / TILE_WIDTH) * TILE_WIDTH;
    const y0 = (rect.y0 / TILE_HEIGHT) * TILE_HEIGHT;

    if (rect.isEmpty()) {
        return RectU16.new(x0, y0, x0, y0);
    }

    return RectU16.new(
        x0,
        y0,
        nextMultipleOf(rect.x1, TILE_WIDTH),
        nextMultipleOf(rect.y1, TILE_HEIGHT),
    );
}

/// Round `value` up to the next multiple of `factor`.
///
/// Mirrors upstream `checked_next_multiple_of(factor).unwrap()`: panics (with
/// an explicit message) if rounding up would exceed `u16`, which upstream also
/// deliberately panics on rather than returning a wrong rectangle.
fn nextMultipleOf(value: u16, factor: u16) u16 {
    if (value % factor == 0) return value;
    const next = value / factor + 1;
    return std.math.mul(u16, next, factor) catch
        @panic("snapping to tile coordinates overflowed u16 (upstream panics here too)");
}

/// Round `value` down to the previous multiple of `step`.
fn snapDown(value: f64, step: u16) f64 {
    const step_f = @as(f64, @floatFromInt(step));
    return @floor(value / step_f) * step_f;
}

/// Clear a pool entry in place.
///
/// Replaces upstream's `Clear` trait (`fn clear(&mut self)`); `value` must be
/// a pointer to a type with a `clear` method. `Pool` calls this through
/// `methodClear` for its default `T`.
pub fn clear(value: anytype) void {
    value.clear();
}

fn methodClear(entry: anytype) void {
    clear(entry);
}

fn arrayListClear(list: anytype) void {
    list.clearRetainingCapacity();
}

/// Pool for reusing allocations.
///
/// Upstream's `Default` is `Pool::new(true)`; call `init(true)` for that.
/// `take` takes the default value explicitly because Zig has no `Default`
/// trait, and `submit` takes the allocator because the backing
/// `std.ArrayList` is unmanaged.
pub fn Pool(comptime T: type) type {
    return PoolWithClear(T, methodClear);
}

/// Pool for reusing vector allocations (upstream `Pool<Vec<T>>`).
///
/// Zig's unmanaged `std.ArrayList` clears via `clearRetainingCapacity`, so
/// this uses a dedicated clear function instead of `T.clear()`.
pub fn VecPool(comptime T: type) type {
    return PoolWithClear(std.ArrayList(T), arrayListClear);
}

fn PoolWithClear(comptime T: type, comptime clearFn: anytype) type {
    return struct {
        entries: std.ArrayList(T),
        clear_on_submit: bool,

        const Self = @This();

        /// Create a new pool.
        ///
        /// `clear_on_submit` decides whether submitted values should be
        /// cleared when they are submitted or whether they should retain their
        /// original contents.
        pub fn init(clear_on_submit: bool) Self {
            return .{ .entries = .empty, .clear_on_submit = clear_on_submit };
        }

        /// Release the pooled allocations.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.* = undefined;
        }

        /// Take an object from the pool or return `default`.
        pub fn take(self: *Self, default: T) T {
            return self.entries.pop() orelse default;
        }

        /// Return an object to the pool.
        ///
        /// On `error.OutOfMemory` the entry is dropped (the pool failed to
        /// retain it); the caller still owns the value that was passed in by
        /// value and cannot recover it, so callers should treat the pool as an
        /// optimization and be able to rebuild the entry. This matches
        /// upstream, where `submit` is infallible only because Rust panics on
        /// allocation failure.
        pub fn submit(self: *Self, allocator: std.mem.Allocator, entry: T) std.mem.Allocator.Error!void {
            var owned = entry;
            if (self.clear_on_submit) clearFn(&owned);
            try self.entries.append(allocator, owned);
        }
    };
}

/// A resizable vector that retains inner elements upon resizing.
///
/// The upstream `len` field is called `active_len` here because Zig does not
/// allow a field and a method to share the name `len`; the `len()` method
/// keeps the upstream API.
pub fn RetainVec(comptime T: type) type {
    return struct {
        inner: std.ArrayList(T),
        active_len: usize,

        const Self = @This();

        /// Create an empty `RetainVec`.
        pub fn init() Self {
            return .{ .inner = .empty, .active_len = 0 };
        }

        /// Create a `RetainVec` with `len` initialized entries.
        pub fn withLen(
            allocator: std.mem.Allocator,
            count: usize,
            initFn: anytype,
        ) std.mem.Allocator.Error!Self {
            var inner = std.ArrayList(T).empty;
            errdefer inner.deinit(allocator);
            try inner.resize(allocator, count);
            for (inner.items) |*item| item.* = initFn();
            return .{ .inner = inner, .active_len = count };
        }

        /// Release the backing storage.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.inner.deinit(allocator);
            self.* = undefined;
        }

        /// Return the length.
        pub fn len(self: *const Self) usize {
            return self.active_len;
        }

        /// Return `true` if the vector is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.active_len == 0;
        }

        /// Return the entries as a slice.
        pub fn asSlice(self: *const Self) []const T {
            return self.inner.items[0..self.active_len];
        }

        /// Return the entries as a mutable slice.
        pub fn asMutSlice(self: *Self) []T {
            return self.inner.items[0..self.active_len];
        }

        /// Return an entry by index (`Index` in upstream).
        pub fn get(self: *const Self, index: usize) *const T {
            std.debug.assert(index < self.active_len);
            return &self.inner.items[index];
        }

        /// Return a mutable entry by index (`IndexMut` in upstream).
        pub fn getMut(self: *Self, index: usize) *T {
            std.debug.assert(index < self.active_len);
            return &self.inner.items[index];
        }

        /// Clear the elements in this vector, retaining the allocations.
        pub fn clear(self: *Self) void {
            self.active_len = 0;
        }

        /// Resize the vector, retaining already-created entries.
        pub fn resizeWith(
            self: *Self,
            allocator: std.mem.Allocator,
            new_len: usize,
            initFn: anytype,
        ) std.mem.Allocator.Error!void {
            const old_len = self.active_len;
            const old_inner_len = self.inner.items.len;
            if (new_len > old_inner_len) {
                try self.inner.resize(allocator, new_len);
                for (self.inner.items[old_inner_len..new_len]) |*item| {
                    item.* = initFn();
                }
            }
            self.active_len = new_len;

            // Make sure to actually reset the newly added values since they are
            // not reset when shrinking the vector.
            if (new_len > old_len) {
                for (self.inner.items[old_len..new_len]) |*item| {
                    item.clear();
                }
            }
        }
    };
}

/// Un-premultiplication helpers, ported from the private `unpremultiply`
/// module in upstream `util.rs`.
///
/// Unlike premultiplication, un-premultiplication needs a per-pixel division;
/// upstream precomputes `255 / alpha` for every alpha value in 8-fractional-
/// digit fixed point so the per-component work is a multiply and a shift. The
/// scalar and SIMD paths must agree.
pub const unpremultiply = struct {
    fn computeReciprocals() [256]u16 {
        var values: [256]u16 = @splat(0);
        // When alpha is 0, so are the RGB channels so it just stays 0.
        var alpha: u32 = 1;
        while (alpha < 256) : (alpha += 1) {
            const round_factor = alpha / 2;
            values[alpha] = @intCast((255 * 256 + round_factor) / alpha);
        }
        return values;
    }

    const RECIPROCALS: [256]u16 = computeReciprocals();

    /// The fixed-point reciprocal `255 / alpha`, rounded to 8 fractional
    /// digits.
    pub fn reciprocal(alpha: u8) u16 {
        return RECIPROCALS[alpha];
    }

    /// Divide by 256, rounding to the nearest integer. Values must not exceed
    /// `u16::MAX - 128`; callers with invalid premultiplied input rely on the
    /// arithmetic wrapping exactly like Rust's `wrapping_mul`.
    inline fn div256(product: u16) u16 {
        return (product +% 128) >> 8;
    }

    /// Un-premultiply a single component.
    pub fn scalar(component: u8, reciprocal_value: u16) u8 {
        const product = @as(u16, component) *% reciprocal_value;
        return @truncate(div256(product));
    }

    /// Un-premultiply a vector of components.
    pub fn simd(component: simd_backend.U8x16, reciprocal_vector: simd_backend.U16x16) simd_backend.U8x16 {
        const wide = widen(component);
        const product = wide *% reciprocal_vector;
        const Shift = @Vector(16, std.math.Log2Int(u16));
        const divided = (product +% @as(simd_backend.U16x16, @splat(128))) >>
            @as(Shift, @splat(8));
        return narrow(divided);
    }

    fn assertAccurate(component: u8, alpha: u8, actual: u8) !void {
        // For 0 and 255 we want exact matches, otherwise we tolerate a delta
        // of at most 1 compared to f32.
        if (component == 0 or alpha == 0 or alpha == 255) {
            try std.testing.expectEqual(component, actual);
        } else if (component == alpha) {
            try std.testing.expectEqual(@as(u8, 255), actual);
        } else {
            const expected: u8 = @intFromFloat(
                @as(f32, @floatFromInt(component)) * 255.0 /
                    @as(f32, @floatFromInt(alpha)) + 0.5,
            );
            const difference = if (actual > expected) actual - expected else expected - actual;
            if (difference > 1) {
                std.debug.print(
                    "component {d} with alpha {d} produced {d} instead of {d}\n",
                    .{ component, alpha, actual, expected },
                );
                return error.TestUnexpectedResult;
            }
        }
    }

    test "scalar_exhaustive" {
        var alpha: u16 = 0;
        while (alpha <= 255) : (alpha += 1) {
            var component: u16 = 0;
            while (component <= alpha) : (component += 1) {
                const alpha_u8: u8 = @intCast(alpha);
                const component_u8: u8 = @intCast(component);
                try assertAccurate(
                    component_u8,
                    alpha_u8,
                    scalar(component_u8, reciprocal(alpha_u8)),
                );
            }
        }
    }

    test "simd_exhaustive" {
        var alpha_usize: u16 = 0;
        while (alpha_usize <= 255) : (alpha_usize += 1) {
            const alpha: u8 = @intCast(alpha_usize);
            const reciprocal_vector: simd_backend.U16x16 = @splat(reciprocal(alpha));

            var start: u16 = 0;
            while (start <= alpha_usize) : (start += 16) {
                var component: simd_backend.U8x16 = undefined;
                inline for (0..16) |lane| {
                    const candidate = start + lane;
                    component[lane] = @intCast(@min(candidate, alpha_usize));
                }
                const actual = simd(component, reciprocal_vector);
                inline for (0..16) |lane| {
                    try assertAccurate(component[lane], alpha, actual[lane]);
                }
            }
        }
    }
};

test "f32_to_u8_truncates" {
    const input: simd_backend.F32x16 = .{
        0.0, 0.25, 0.5,   0.75, 0.999, 1.0,  1.5,               2.0,
        2.5, 3.0,  100.0, 1e9,  -0.5,  -1.5, std.math.nan(f32), -1e9,
    };
    const expected: simd_backend.U8x16 = .{
        0, 0, 0,   0, 0, 1,   1, 2,
        2, 3, 100, 0, 0, 255, 0, 0,
    };
    try std.testing.expectEqual(expected, f32ToU8(input));
}

test "div255 and normalized_mul_u8" {
    const values: simd_backend.U16x16 = @splat(255);
    try std.testing.expectEqual(@as(u16, 1), div255(values)[0]);
    try std.testing.expectEqual(@as(u16, 0), div255(@as(simd_backend.U16x16, @splat(0)))[0]);

    const a: simd_backend.U8x16 = @splat(200);
    const b: simd_backend.U8x16 = @splat(128);
    try std.testing.expectEqual(@as(u16, 100), normalizedMulU8(a, b)[0]);
    try std.testing.expectEqual(simd_backend.U16x16, @TypeOf(normalizedMulU8(a, b)));
}

test "widen, narrow and saturating_narrow" {
    const bytes: simd_backend.U8x16 = @splat(200);
    const widened = widen(bytes);
    try std.testing.expectEqual(simd_backend.U16x16, @TypeOf(widened));
    try std.testing.expectEqual(@as(u16, 200), widened[0]);
    try std.testing.expectEqual(bytes, narrow(widened));

    const words: simd_backend.U16x16 = @splat(300);
    try std.testing.expectEqual(@as(u8, 44), narrow(words)[0]);
    try std.testing.expectEqual(@as(u8, 255), saturatingNarrow(words)[0]);
    try std.testing.expectEqual(@as(u16, 300), narrow(widen(words))[0]);
}

test "snap_to_tile_coordinates_rounds_outward" {
    const rect = RectExt.snapToTileCoordinates(kurbo.Rect.new(-4.1, -0.1, 4.1, 8.0));
    try std.testing.expectEqual(kurbo.Rect.new(-8.0, -4.0, 8.0, 8.0), rect);
}

test "snap_u16_to_tile_coordinates_rounds_outward" {
    const rect = RectExt.snapToTileCoordinates(RectU16.new(5, 3, 9, 7));
    try std.testing.expectEqual(RectU16.new(4, 0, 12, 8), rect);
}

test "snap_to_tile_coordinates_preserves_empty_rects" {
    try std.testing.expectEqual(
        kurbo.Rect.new(4.0, 0.0, 4.0, 0.0),
        RectExt.snapToTileCoordinates(kurbo.Rect.new(5.0, 3.0, 5.0, 7.0)),
    );
    try std.testing.expectEqual(
        RectU16.new(4, 0, 4, 0),
        RectExt.snapToTileCoordinates(RectU16.new(5, 3, 9, 3)),
    );
}

test "transform classification" {
    const identity = kurbo.Affine.IDENTITY;
    try std.testing.expect(isIntegerTranslation(identity));
    try std.testing.expect(isAxisAligned(identity));

    const integer_translation = kurbo.Affine.translate(kurbo.Vec2.new(10.0, 20.0));
    try std.testing.expect(isIntegerTranslation(integer_translation));
    try std.testing.expect(isAxisAligned(integer_translation));

    const fractional_translation = kurbo.Affine.translate(kurbo.Vec2.new(10.5, 20.0));
    try std.testing.expect(!isIntegerTranslation(fractional_translation));

    const scaled = kurbo.Affine.scale(2.0);
    try std.testing.expect(!isIntegerTranslation(scaled));
    try std.testing.expect(isAxisAligned(scaled));
    try std.testing.expectEqual([2]f32{ 2.0, 2.0 }, extractScales(scaled));

    const rotated = kurbo.Affine.rotate(std.math.pi / 2.0);
    try std.testing.expect(!isIntegerTranslation(rotated));
    try std.testing.expect(!isAxisAligned(rotated));
    const rotated_scales = extractScales(rotated);
    try std.testing.expect(@abs(rotated_scales[0] - 1.0) < 1e-5);
    try std.testing.expect(@abs(rotated_scales[1] - 1.0) < 1e-5);
}

test "retain_vec resets new entries and retains shrunk ones" {
    const allocator = std.testing.allocator;
    const Counters = struct {
        value: u32 = 0,
        pub fn clear(self: *@This()) void {
            self.value = 0;
        }
    };
    const Init = struct {
        fn zero() Counters {
            return .{};
        }
        fn five() Counters {
            return .{ .value = 5 };
        }
    };

    var vec = RetainVec(Counters).init();
    defer vec.deinit(allocator);

    try vec.resizeWith(allocator, 4, Init.zero);
    try std.testing.expectEqual(@as(usize, 4), vec.len());
    vec.getMut(2).value = 9;

    // Shrinking keeps the entries, growing again resets them.
    try vec.resizeWith(allocator, 1, Init.zero);
    try std.testing.expectEqual(@as(u32, 0), vec.get(0).value);
    try vec.resizeWith(allocator, 3, Init.zero);
    try std.testing.expectEqual(@as(u32, 0), vec.get(2).value);

    var with_len = try RetainVec(Counters).withLen(allocator, 2, Init.five);
    defer with_len.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 5), with_len.get(1).value);
    try std.testing.expect(with_len.asSlice().len == 2);
}

test "pool reuses entries" {
    const allocator = std.testing.allocator;
    const Counters = struct {
        value: u32 = 0,
        pub fn clear(self: *@This()) void {
            self.value = 0;
        }
    };

    var pool = Pool(Counters).init(true);
    defer pool.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), pool.take(.{}).value);
    try pool.submit(allocator, .{ .value = 3 });
    // Cleared on submit, then reused.
    const reused = pool.take(.{});
    try std.testing.expectEqual(@as(u32, 0), reused.value);

    var raw_pool = Pool(Counters).init(false);
    defer raw_pool.deinit(allocator);
    try raw_pool.submit(allocator, .{ .value = 7 });
    try std.testing.expectEqual(@as(u32, 7), raw_pool.take(.{}).value);

    var vec_pool = VecPool(u32).init(false);
    defer vec_pool.deinit(allocator);
    var list = std.ArrayList(u32).empty;
    try list.append(allocator, 1);
    try vec_pool.submit(allocator, list);
    var taken = vec_pool.take(.empty);
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    try std.testing.expect(taken.capacity >= 1);
    taken.deinit(allocator);
}
