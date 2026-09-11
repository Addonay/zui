//! Minimal equivalent of the parts of `fearless_simd` 0.7.0 that the Vello
//! port uses, built on Zig's native `@Vector`.
//!
//! Upstream algorithm code is generic over a `Simd` backend and dispatches at
//! runtime over `Level`. The port keeps the same fixed vector widths and lane
//! semantics; the `Level` here selects an implementation only for functions
//! that genuinely differ per architecture (today: none). All helpers are
//! `inline` and operate on `@Vector` values, so LLVM lowers them to the
//! host's SIMD instructions when available and keeps IEEE semantics otherwise.
//!
//! Porting rules:
//! - Upstream `f32x16` etc. map to the aliases below.
//! - Upstream method calls map to the free functions here with the same
//!   semantics (`min`, `max`, `mul_add`, `select`, `splat`, slice load/store,
//!   bitcast, zip/unzip/split/combine).
//! - No `@setFloatMode(.optimized)`: results must not depend on reassociation.
//! - Integer narrowing/`div_255` etc. live in `common/util.zig` because they
//!   are shared by scalar paths too.

const std = @import("std");

/// Runtime-selected SIMD level, mirroring `fearless_simd::Level`.
///
/// Vellz currently implements one portable backend; the variants exist so
/// public settings and cache keys match upstream and so architecture-specific
/// refinements can be added without changing callers.
pub const Level = enum {
    /// Pure scalar semantics. Always available in vellz (unlike upstream,
    /// where the variant may be compiled out on native SIMD targets).
    fallback,
    /// The platform's guaranteed baseline (SSE2 on x86-64, Neon on aarch64-64).
    baseline,
    sse2,
    sse4_2,
    avx2,
    avx512,
    neon,
    wasm_simd128,

    pub fn new() Level {
        return @This().baseline();
    }

    pub fn tryDetect() ?Level {
        return @This().baseline();
    }

    pub fn isFallback(self: Level) bool {
        return self == .fallback;
    }
};

/// Alias kept for ported call sites.
pub const Simd = Level;

// ---------------------------------------------------------------------------
// Vector types (fixed widths used by the upstream crates)
// ---------------------------------------------------------------------------

pub fn Vec(comptime n: usize, comptime T: type) type {
    return @Vector(n, T);
}

pub const F32x4 = Vec(4, f32);
pub const F32x8 = Vec(8, f32);
pub const F32x16 = Vec(16, f32);
pub const F64x2 = Vec(2, f64);
pub const F64x4 = Vec(4, f64);

pub const U8x16 = Vec(16, u8);
pub const U8x32 = Vec(32, u8);
pub const U8x64 = Vec(64, u8);
pub const U16x16 = Vec(16, u16);
pub const U32x4 = Vec(4, u32);
pub const U32x16 = Vec(16, u32);
pub const I32x4 = Vec(4, i32);

pub fn Mask(comptime V: type) type {
    return @Vector(laneCount(V), bool);
}

pub const Mask32x4 = Mask(F32x4);
pub const Mask32x16 = Mask(F32x16);
pub const Mask8x16 = Mask(U8x16);

pub fn laneCount(comptime V: type) usize {
    return @typeInfo(V).vector.len;
}

pub fn Lane(comptime V: type) type {
    return @typeInfo(V).vector.child;
}

// ---------------------------------------------------------------------------
// Construction, loading, storing
// ---------------------------------------------------------------------------

pub inline fn splat(comptime V: type, value: Lane(V)) V {
    return @splat(value);
}

/// Upstream `Splat4thExt::splat_4th`: broadcast the fourth lane of **every
/// 4-lane block** to the other three lanes of that block.
///
/// For 16-lane RGBA-block vectors (`[r,g,b,a, r,g,b,a, ...]`) this replaces
/// each block with its alpha, which is what the highp kernel and the gradient
/// LUT need. Upstream implements it with `zip_high`; the lane loop below is
/// equivalent and exact.
pub inline fn splat4th(v: anytype) @TypeOf(v) {
    const V = @TypeOf(v);
    const n = comptime laneCount(V);
    comptime std.debug.assert(n % 4 == 0);
    var out: V = undefined;
    inline for (0..n / 4) |block| {
        inline for (0..4) |lane| {
            out[block * 4 + lane] = v[block * 4 + 3];
        }
    }
    return out;
}

pub inline fn fromSlice(comptime V: type, slice: []const Lane(V)) V {
    const n = comptime laneCount(V);
    std.debug.assert(slice.len >= n);
    var out: V = undefined;
    inline for (0..n) |i| out[i] = slice[i];
    return out;
}

pub inline fn storeSlice(v: anytype, slice: []Lane(@TypeOf(v))) void {
    const n = comptime laneCount(@TypeOf(v));
    std.debug.assert(slice.len >= n);
    inline for (0..n) |i| slice[i] = v[i];
}

/// `element_wise_splat`: build a vector from four scalars.
pub inline fn splat4(a: anytype, b: @TypeOf(a), c: @TypeOf(a), d: @TypeOf(a)) F32x4 {
    return .{ a, b, c, d };
}

pub inline fn blockSplat(a: F32x4, b: F32x4, c: F32x4, d: F32x4) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..4) |i| {
        out[i] = a[i];
        out[i + 4] = b[i];
        out[i + 8] = c[i];
        out[i + 12] = d[i];
    }
    return out;
}

/// `element_wise_splat`: broadcast each lane of a four-lane vector to its own
/// group of four lanes. Lane order matches upstream `combine_f32x8(
/// combine_f32x4(splat(input[0]), splat(input[1])),
/// combine_f32x4(splat(input[2]), splat(input[3])))`.
pub inline fn elementWiseSplat(input: F32x4) F32x16 {
    return blockSplat(
        splat(F32x4, input[0]),
        splat(F32x4, input[1]),
        splat(F32x4, input[2]),
        splat(F32x4, input[3]),
    );
}

/// Alias of [`splat4th`] kept for the gradient/LUT call sites that already
/// spell out the per-group intent.
pub inline fn splat4thPerGroup(v: anytype) @TypeOf(v) {
    return splat4th(v);
}

// ---------------------------------------------------------------------------
// Arithmetic helpers not spelled as operators
// ---------------------------------------------------------------------------

pub inline fn mulAdd(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    return @mulAdd(@TypeOf(a), a, b, c);
}

/// Multiply-add matching upstream's non-FMA `fearless_simd` backends
/// (`fallback` and `sse4_2`, which is what `Level::baseline()` selects on
/// x86-64 without FMA target features): a separate multiply followed by an
/// add, as written upstream (`a * b + c`). Zig's default strict float mode
/// does not contract the two operations into an FMA, so this is bit-identical
/// to upstream `mul_add` on those backends. Use [`mulAdd`] (fused) only where
/// upstream ran on an FMA backend.
pub inline fn mulAddUnfused(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    return a * b + c;
}

pub inline fn abs(v: anytype) @TypeOf(v) {
    return @abs(v);
}

pub inline fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @min(a, b);
}

pub inline fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @max(a, b);
}

/// Upstream `max_precise` (IEEE max with NaN semantics), matching ARM's
/// `fmaxnm`/`maxnm` behavior used after line-slope computations.
pub inline fn maxPrecise(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @max(a, b);
}

pub inline fn simdGe(a: anytype, b: @TypeOf(a)) Mask(@TypeOf(a)) {
    return a >= b;
}

pub inline fn simdEq(a: anytype, b: @TypeOf(a)) Mask(@TypeOf(a)) {
    return a == b;
}

pub inline fn select(comptime V: type, mask: Mask(V), t: V, f: V) V {
    return @select(Lane(V), mask, t, f);
}

pub inline fn bitcast(comptime V: type, v: anytype) V {
    return @bitCast(v);
}

pub inline fn reduceAdd(v: anytype) Lane(@TypeOf(v)) {
    return @reduce(.Add, v);
}

// ---------------------------------------------------------------------------
// Lane rearrangement
// ---------------------------------------------------------------------------

pub inline fn combineF32x4(lo: F32x4, hi: F32x4) F32x8 {
    var out: F32x8 = undefined;
    inline for (0..4) |i| {
        out[i] = lo[i];
        out[i + 4] = hi[i];
    }
    return out;
}

/// `combine_f32x8`: concatenate two `f32x8` into an `f32x16`.
///
/// Used by strip generation to pack the four per-column `f32x4` winding
/// accumulators into the column-major 16-byte alpha block before
/// `util.f32ToU8`.
pub inline fn combineF32x8(lo: F32x8, hi: F32x8) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..8) |i| {
        out[i] = lo[i];
        out[i + 8] = hi[i];
    }
    return out;
}

pub inline fn splitF32x8(v: F32x8) [2]F32x4 {
    var lo: F32x4 = undefined;
    var hi: F32x4 = undefined;
    inline for (0..4) |i| {
        lo[i] = v[i];
        hi[i] = v[i + 4];
    }
    return .{ lo, hi };
}

/// `unzip_low_f32x8`/`unzip_high_f32x8`.
pub inline fn unzipLowF32x8(a: F32x8, b: F32x8) F32x4 {
    return .{ a[0], a[2], b[0], b[2] };
}

pub inline fn unzipHighF32x8(a: F32x8, b: F32x8) F32x4 {
    return .{ a[1], a[3], b[1], b[3] };
}

pub inline fn zipLowF64x2(a: F64x2, b: F64x2) F64x4 {
    return .{ a[0], a[1], b[0], b[1] };
}

pub inline fn zipHighF64x2(a: F64x2, b: F64x2) F64x4 {
    return .{ a[0], a[1], b[0], b[1] };
}

pub inline fn combineU8x16(lo: U8x16, hi: U8x16) U8x32 {
    var out: U8x32 = undefined;
    inline for (0..16) |i| {
        out[i] = lo[i];
        out[i + 16] = hi[i];
    }
    return out;
}

pub inline fn splitU8x32(v: U8x32) [2]U8x16 {
    var lo: U8x16 = undefined;
    var hi: U8x16 = undefined;
    inline for (0..16) |i| {
        lo[i] = v[i];
        hi[i] = v[i + 16];
    }
    return .{ lo, hi };
}

test "combineF32x8 concatenates lanes" {
    const lo: F32x8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const hi: F32x8 = .{ 9, 10, 11, 12, 13, 14, 15, 16 };
    const combined = combineF32x8(lo, hi);
    try std.testing.expectEqual(@as(F32x16, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }), combined);
}

test "mulAddUnfused is a separate multiply and add" {
    const a: F32x4 = .{ 1.0, -2.0, 0.5, 3.0 };
    const b: F32x4 = .{ 4.0, 0.25, -1.0, 2.0 };
    const c: F32x4 = .{ 0.5, 1.0, 2.0, -0.5 };
    var expected: F32x4 = undefined;
    inline for (0..4) |i| {
        const product = a[i] * b[i];
        expected[i] = product + c[i];
    }
    try std.testing.expectEqual(expected, mulAddUnfused(a, b, c));
}

test "mulAddUnfused does not contract into an FMA" {
    // (1 + 2^-20) * (1 - 2^-20) - 1: the exact product is 1 - 2^-40, which
    // rounds to 1.0 as a separate multiply and yields -2^-40 when fused.
    // This guards the strict float mode that `common/flatten.zig` and
    // `common/tile.zig` rely on. The array + `doNotOptimizeAway` keeps the
    // operands out of comptime constant folding.
    var inputs = [_]f32{ 1.0 + 0x1p-20, 1.0 - 0x1p-20, -1.0 };
    std.mem.doNotOptimizeAway(&inputs);
    try std.testing.expectEqual(@as(f32, 0.0), mulAddUnfused(inputs[0], inputs[1], inputs[2]));
    // `mulAdd` is the fused variant and must differ for these operands.
    try std.testing.expect(@mulAdd(f32, inputs[0], inputs[1], inputs[2]) != 0.0);
}

test "splat4th is block-local (upstream Splat4thExt)" {
    const v: F32x4 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(F32x4{ 4, 4, 4, 4 }, splat4th(v));

    // Four RGBA pixels: each block keeps its own alpha.
    const pixels: F32x16 = .{
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    };
    try std.testing.expectEqual(F32x16{
        4,  4,  4,  4,  8,  8,  8,  8,
        12, 12, 12, 12, 16, 16, 16, 16,
    }, splat4th(pixels));

    const combined = combineF32x4(v, v);
    const parts = splitF32x8(combined);
    try std.testing.expectEqual(v, parts[0]);
    try std.testing.expectEqual(v, parts[1]);

    const a: F32x8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b: F32x8 = .{ 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqual(F32x4{ 1, 3, 9, 11 }, unzipLowF32x8(a, b));
    try std.testing.expectEqual(F32x4{ 2, 4, 10, 12 }, unzipHighF32x8(a, b));
}

test "elementWiseSplat broadcasts each lane to a group of four" {
    const input: F32x4 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(
        F32x16{ 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4 },
        elementWiseSplat(input),
    );
}

test "splat4thPerGroup broadcasts each block's fourth lane" {
    const wide: F32x16 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqual(
        F32x16{ 4, 4, 4, 4, 8, 8, 8, 8, 12, 12, 12, 12, 16, 16, 16, 16 },
        splat4thPerGroup(wide),
    );

    // For a single four-lane block this agrees with `splat4th`.
    const narrow: F32x4 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(F32x4{ 4, 4, 4, 4 }, splat4thPerGroup(narrow));
    try std.testing.expectEqual(splat4th(narrow), splat4thPerGroup(narrow));
}

test "select and comparisons" {
    const a: F32x4 = .{ 1, 2, 3, 4 };
    const b: F32x4 = .{ 4, 3, 2, 1 };
    const m = simdGe(a, b);
    try std.testing.expectEqual(F32x4{ 4, 3, 3, 4 }, select(F32x4, m, a, b));
}
