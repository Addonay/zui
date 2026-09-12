//! `gvar` (glyph variations) and `cvar` (CVT variations) table parsing plus the
//! tuple-variation store, ported from `read-fonts` 0.41.0 (`tables/gvar.rs`,
//! `tables/cvar.rs`, `tables/variations.rs`) for `skrifa`'s
//! `outline/glyf/deltas.rs` consumers.
//!
//! All arithmetic that produces deltas runs in 16.16 `Fixed` exactly like
//! `read-fonts`: tuple scalars are computed with `Fixed::mul_div` (round half
//! away from zero, `0x7fffffff` for a zero divisor), packed deltas are scaled
//! with `Fixed::from_i32(delta) * scalar`, and IUP interpolation subtracts and
//! divides in `Fixed`. A f32 reimplementation is not bit-identical.
//!
//! Degradation rules deliberately mirror upstream's best-effort variation
//! handling (see `skrifa/src/outline/glyf/deltas.rs` and `mod.rs`):
//! - a malformed glyph variation *header/count* makes `glyphVariationData`
//!   return `error.OutOfBounds`/`error.Truncated`, which upstream turns into
//!   "no deltas" (but still runs the delta application path);
//! - a malformed tuple header or a serialized-data range that runs past the
//!   data ends iteration early (upstream's `Iterator::next` returns `None`);
//! - a malformed packed point/delta stream is a hard error that the glyph
//!   scaler reports as "no deltas at all", never a partial application.
//!
//! Not ported (rejected by `Font.outlines()` before reaching this module or
//! never consulted): `VVAR`, `MVAR`, and variation stores other than `gvar`
//! and `cvar`.

const std = @import("std");

const sfnt = @import("sfnt.zig");

pub const Error = error{
    Truncated,
    OutOfBounds,
    MalformedData,
};

/// 16.16 fixed-point point (`read-fonts` `Point<Fixed>`).
pub const Point16 = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn add(a: Point16, b: Point16) Point16 {
        return .{ .x = a.x +% b.x, .y = a.y +% b.y };
    }

    pub fn sub(a: Point16, b: Point16) Point16 {
        return .{ .x = a.x -% b.x, .y = a.y -% b.y };
    }
};

/// `read-fonts` `Fixed::ONE`.
pub const fixed_one: i32 = 0x10000;

/// `read-fonts` `Fixed` multiplication: round half away from zero.
pub fn fixedMul(a: i32, b: i32) i32 {
    const ab: i64 = @as(i64, a) * @as(i64, b);
    const adjust: i64 = 0x8000 - @as(i64, @intFromBool(ab < 0));
    return @truncate((ab + adjust) >> 16);
}

/// `read-fonts` `Fixed::mul_div` (used by tuple-scalar computation).
pub fn fixedMulDiv(a: i32, b: i32, d: i32) i32 {
    var sign: i64 = 1;
    var su: u64 = @as(u64, @bitCast(@as(i64, a)));
    var au: u64 = @as(u64, @bitCast(@as(i64, b)));
    var du: u64 = @as(u64, @bitCast(@as(i64, d)));
    if (a < 0) {
        su = 0 -% su;
        sign = -1;
    }
    if (b < 0) {
        au = 0 -% au;
        sign = -sign;
    }
    if (d < 0) {
        du = 0 -% du;
        sign = -sign;
    }
    const result: u64 = if (du > 0)
        (su *% au +% (du >> 1)) / du
    else
        0x7FFFFFFF;
    const truncated: i32 = @bitCast(@as(u32, @truncate(result)));
    return if (sign < 0) -%truncated else truncated;
}

/// `read-fonts` `Fixed::from_i32`: `bits << 16` with Rust shift semantics.
pub fn fixedFromI32(value: i32) i32 {
    return @bitCast(@as(u32, @bitCast(value)) << 16);
}

/// `read-fonts` `Fixed::to_i32`: round off the fractional bits.
pub fn fixedToI32(bits: i32) i32 {
    const wrapped: i32 = @bitCast(@as(u32, @bitCast(bits)) +% 0x8000);
    return wrapped >> 16;
}

/// `read-fonts` `F2Dot14::to_fixed`: `bits * 4`.
pub fn f2dot14ToFixed(value: i16) i32 {
    return @as(i32, value) * 4;
}

// ------------------------------------------------------------ packed utilities

/// Flags for packed delta runs (`read-fonts` `variations.rs`).
const deltas_are_zero: u8 = 0x80;
const deltas_are_words: u8 = 0x40;
const delta_run_count_mask: u8 = 0x3F;

const DeltaRunType = enum(u8) {
    zero = 0,
    i8 = 1,
    i16 = 2,
    i32 = 4,

    fn fromControl(control: u8) DeltaRunType {
        const are_zero = (control & deltas_are_zero) != 0;
        const are_words = (control & deltas_are_words) != 0;
        return switch (are_zero) {
            false => if (are_words) .i16 else .i8,
            true => if (are_words) .i32 else .zero,
        };
    }

    fn width(self: DeltaRunType) usize {
        return @backingInt(self);
    }
};

/// A forward cursor over packed delta runs, equivalent to combining
/// `read-fonts`' `DeltaRunIter` (bounded reads) and `PackedDeltaFetcher` (skip).
pub const DeltaCursor = struct {
    data: []const u8,
    pos: usize = 0,
    /// Number of deltas the cursor may still produce (`None` = unbounded).
    limit: ?usize = null,
    run_remaining: usize = 0,
    value_type: DeltaRunType = .i8,

    fn readControl(self: *DeltaCursor) Error!void {
        if (self.pos >= self.data.len) return error.OutOfBounds;
        const control = self.data[self.pos];
        self.pos += 1;
        self.run_remaining = @as(usize, control & delta_run_count_mask) + 1;
        self.value_type = DeltaRunType.fromControl(control);
        const needed = self.run_remaining * self.value_type.width();
        if (self.pos + needed > self.data.len) return error.OutOfBounds;
    }

    /// Next delta value, or `null` when the limit is exhausted.
    pub fn next(self: *DeltaCursor) Error!?i32 {
        if (self.limit) |limit| {
            if (limit == 0) return null;
            self.limit = limit - 1;
        }
        if (self.run_remaining == 0) try self.readControl();
        self.run_remaining -= 1;
        const value: i32 = switch (self.value_type) {
            .zero => 0,
            .i8 => blk: {
                const raw = self.data[self.pos];
                self.pos += 1;
                break :blk @as(i8, @bitCast(raw));
            },
            .i16 => blk: {
                const raw = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
                self.pos += 2;
                break :blk raw;
            },
            .i32 => blk: {
                const raw = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
                self.pos += 4;
                break :blk raw;
            },
        };
        return value;
    }

    /// Skips `n` deltas without decoding their values (`DeltaRunIter::skip_fast`).
    pub fn skip(self: *DeltaCursor, n: usize) Error!void {
        var wanted = n;
        if (self.limit) |limit| self.limit = limit -| wanted;
        var remaining = self.run_remaining;
        var value_type = self.value_type;
        while (true) {
            if (wanted > remaining) {
                self.pos += remaining * value_type.width();
                wanted -= remaining;
                self.run_remaining = 0;
                if (self.pos >= self.data.len) return error.OutOfBounds;
                const control = self.data[self.pos];
                self.pos += 1;
                remaining = @as(usize, control & delta_run_count_mask) + 1;
                value_type = DeltaRunType.fromControl(control);
                const needed = remaining * value_type.width();
                if (self.pos + needed > self.data.len) return error.OutOfBounds;
                continue;
            }
            self.run_remaining = remaining - wanted;
            self.pos += wanted * value_type.width();
            break;
        }
    }
};

/// `read-fonts` `PackedDeltas`.
pub const PackedDeltas = struct {
    data: []const u8,
    /// Expected number of values, or `null` to consume all remaining runs.
    count: ?usize = null,

    pub fn cursor(self: PackedDeltas) DeltaCursor {
        return .{ .data = self.data, .limit = self.count };
    }

    /// Number of deltas encoded in the data (`count_all_deltas`).
    fn countAll(data: []const u8) usize {
        var total: usize = 0;
        var offset: usize = 0;
        while (offset < data.len) {
            const control = data[offset];
            const run_count = @as(usize, control & delta_run_count_mask) + 1;
            total += run_count;
            offset += run_count * DeltaRunType.fromControl(control).width() + 1;
        }
        return total;
    }

    pub fn countOrCompute(self: PackedDeltas) usize {
        return self.count orelse countAll(self.data);
    }
};

/// `(count, header_len)` from the front of the packed point-number data.
pub const PointCount = struct { count: u16, bytes: usize };

/// Result of splitting packed point numbers off a data slice.
pub const PackedPointSplit = struct { point_numbers: PackedPointNumbers, rest: []const u8 };

/// A pair of intermediate-region tuples.
pub const IntermediateTuples = struct { start: Tuple, end: Tuple };

/// `(point_numbers, packed_deltas_data)` for a tuple.
pub const PointNumbersAndDeltas = struct { points: PackedPointNumbers, deltas: []const u8 };

/// [Packed point numbers](https://learn.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#packed-point-numbers).
pub const PackedPointNumbers = struct {
    data: []const u8 = &.{},

    /// `(count, header_len)` from the front of the data.
    fn countAndCountBytes(self: PackedPointNumbers) PointCount {
        const first: u8 = if (self.data.len >= 1) self.data[0] else 0;
        if (first == 0) return .{ .count = 0, .bytes = 1 };
        if (first <= 127) return .{ .count = first, .bytes = 1 };
        const raw: u16 = if (self.data.len >= 2)
            std.mem.readInt(u16, self.data[0..2], .big)
        else
            0;
        const n = raw & 0x7FFF;
        if (n == 0) return .{ .count = 0, .bytes = 2 };
        return .{ .count = n, .bytes = 2 };
    }

    pub fn count(self: PackedPointNumbers) u16 {
        return self.countAndCountBytes().count;
    }

    /// Number of bytes the packed point-number data occupies.
    fn totalLen(self: PackedPointNumbers) usize {
        const header = self.countAndCountBytes();
        var n_bytes = header.bytes;
        if (header.count == 0) return n_bytes;
        var pos = n_bytes;
        var n_seen: usize = 0;
        while (n_seen < header.count) {
            if (pos >= self.data.len) return n_bytes;
            const control = self.data[pos];
            pos += 1;
            const run_count = @as(usize, control & 0x7F) + 1;
            const word_size: usize = 1 + @as(usize, @intFromBool((control & 0x80) != 0));
            const run_size = word_size * run_count;
            n_bytes += run_size + 1;
            pos += run_size;
            n_seen += run_count;
        }
        return n_bytes;
    }

    /// Splits the packed point numbers off the front, returning the remainder
    /// (empty when the declared length runs past the data, like upstream's
    /// `unwrap_or_default`).
    pub fn splitOffFront(data: []const u8) PackedPointSplit {
        const point_numbers = PackedPointNumbers{ .data = data };
        const len = point_numbers.totalLen();
        const rest = if (len <= data.len) data[len..] else &.{};
        return .{ .point_numbers = point_numbers, .rest = rest };
    }

    /// Iterator over the decoded point numbers. A zero count yields `0, 1, 2,
    /// ...` until the coordinate space is exhausted (upstream's dense mode).
    pub fn iter(self: PackedPointNumbers) PointNumbersIter {
        const header = self.countAndCountBytes();
        return .{
            .data = self.data,
            .pos = header.bytes,
            .count = header.count,
            .seen = 0,
            .last_val = 0,
        };
    }
};

pub const PointNumbersIter = struct {
    data: []const u8,
    pos: usize,
    count: u16,
    seen: u16,
    last_val: u16,
    run_remaining: u8 = 0,
    two_bytes: bool = false,

    pub fn next(self: *PointNumbersIter) ?u16 {
        if (self.count == 0) {
            if (self.last_val == std.math.maxInt(u16)) return null;
            const result = self.last_val;
            self.last_val += 1;
            return result;
        }
        if (self.seen == self.count) return null;
        self.seen += 1;
        while (self.run_remaining == 0) {
            if (self.pos >= self.data.len) return null;
            const control = self.data[self.pos];
            self.pos += 1;
            self.run_remaining = (control & 0x7F) + 1;
            self.two_bytes = (control & 0x80) != 0;
        }
        self.run_remaining -= 1;
        var delta: u16 = 0;
        if (self.two_bytes) {
            if (self.pos + 2 > self.data.len) return null;
            delta = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
            self.pos += 2;
        } else {
            if (self.pos >= self.data.len) return null;
            delta = self.data[self.pos];
            self.pos += 1;
        }
        const sum = @as(u32, self.last_val) + delta;
        if (sum > std.math.maxInt(u16)) return null;
        self.last_val = @intCast(sum);
        return self.last_val;
    }
};

// ------------------------------------------------------------------ tuple store

/// A tuple record (peak or intermediate): `axis_count` F2Dot14 values.
pub const Tuple = struct {
    data: []const u8,
    axis_count: u16,

    pub fn len(self: Tuple) usize {
        return self.axis_count;
    }

    pub fn get(self: Tuple, idx: usize) ?i16 {
        if (idx >= self.axis_count) return null;
        return std.mem.readInt(i16, self.data[2 * idx ..][0..2], .big);
    }
};

pub const tuple_index_embedded_peak: u16 = 0x8000;
pub const tuple_index_intermediate: u16 = 0x4000;
pub const tuple_index_private_points: u16 = 0x2000;
pub const tuple_index_mask: u16 = 0x0FFF;

pub const tuple_count_shared_points: u16 = 0x8000;
pub const tuple_count_mask: u16 = 0x0FFF;

/// Shared tuple records resolved from the `gvar` header.
pub const SharedTuples = struct {
    data: []const u8 = &.{},
    axis_count: u16 = 0,
    count: u16 = 0,

    pub fn get(self: SharedTuples, idx: u16) ?Tuple {
        if (idx >= self.count) return null;
        const width = 2 * @as(usize, self.axis_count);
        const offset = @as(usize, idx) * width;
        if (offset + width > self.data.len) return null;
        return .{ .data = self.data[offset .. offset + width], .axis_count = self.axis_count };
    }
};

/// The `gvar` table header plus its offset array.
pub const Gvar = struct {
    data: []const u8,
    axis_count: u16,
    shared_tuple_count: u16,
    shared_tuples_offset: u32,
    glyph_count: u16,
    long_offsets: bool,
    glyph_data_array_offset: u32,

    pub fn parse(data: []const u8) Error!Gvar {
        // `Gvar::read` requires the 20-byte header; the generated field
        // accessors then cannot fail for a header this long.
        if (data.len < 20) return error.Truncated;
        return .{
            .data = data,
            .axis_count = std.mem.readInt(u16, data[4..6], .big),
            .shared_tuple_count = std.mem.readInt(u16, data[6..8], .big),
            .shared_tuples_offset = std.mem.readInt(u32, data[8..12], .big),
            .glyph_count = std.mem.readInt(u16, data[12..14], .big),
            .long_offsets = (std.mem.readInt(u16, data[14..16], .big) & 1) != 0,
            .glyph_data_array_offset = std.mem.readInt(u32, data[16..20], .big),
        };
    }

    fn sharedTuples(self: Gvar) Error!SharedTuples {
        const start: usize = self.shared_tuples_offset;
        const width = 2 * @as(usize, self.axis_count) * @as(usize, self.shared_tuple_count);
        if (start > self.data.len or width > self.data.len - start) return error.OutOfBounds;
        return .{
            .data = self.data[start .. start + width],
            .axis_count = self.axis_count,
            .count = self.shared_tuple_count,
        };
    }

    fn offsetAt(self: Gvar, idx: usize) Error!u32 {
        if (idx > self.glyph_count) return error.OutOfBounds;
        const base = 20;
        if (self.long_offsets) {
            const off = base + idx * 4;
            if (off + 4 > self.data.len) return error.OutOfBounds;
            return std.mem.readInt(u32, self.data[off..][0..4], .big);
        }
        const off = base + idx * 2;
        if (off + 2 > self.data.len) return error.OutOfBounds;
        return @as(u32, std.mem.readInt(u16, self.data[off..][0..2], .big)) * 2;
    }

    /// Raw variation data for `gid`, or `null` when the glyph has none.
    pub fn dataForGid(self: Gvar, gid: u32) Error!?[]const u8 {
        if (gid >= self.glyph_count) return error.OutOfBounds;
        const start_off = try self.offsetAt(gid);
        const end_off = try self.offsetAt(gid + 1);
        const base: usize = self.glyph_data_array_offset;
        const start = std.math.add(usize, base, start_off) catch return error.OutOfBounds;
        const end = std.math.add(usize, base, end_off) catch return error.OutOfBounds;
        if (start > end) return error.OutOfBounds;
        if (end > self.data.len) return error.OutOfBounds;
        if (start == end) return null;
        return self.data[start..end];
    }

    /// Parsed tuple-variation data for `gid`. Mirrors
    /// `Gvar::glyph_variation_data`: a missing table is `null`, malformed data
    /// is an error.
    pub fn glyphVariationData(self: Gvar, gid: u32) Error!?GlyphVariationData {
        const raw = (try self.dataForGid(gid)) orelse return null;
        return try GlyphVariationData.init(raw, self, try self.sharedTuples());
    }
};

/// `GlyphVariationDataHeader` + the tuple headers and serialized data.
pub const GlyphVariationData = struct {
    /// The whole `GlyphVariationData` slice (header included).
    data: []const u8,
    axis_count: u16,
    shared_tuples: SharedTuples,
    tuple_count: u16,
    has_shared_point_numbers: bool,
    shared_point_numbers: PackedPointNumbers,
    /// Tuple header records (starting at offset 4).
    header_data: []const u8,
    /// Serialized data (after any shared point numbers).
    serialized_data: []const u8,

    pub fn init(data: []const u8, gvar: Gvar, shared_tuples: SharedTuples) Error!GlyphVariationData {
        if (data.len < 4) return error.Truncated;
        const count_raw = std.mem.readInt(u16, data[0..2], .big);
        const serialized_offset = std.mem.readInt(u16, data[2..4], .big);
        if (serialized_offset > data.len) return error.OutOfBounds;
        const serialized_all = data[serialized_offset..];
        var shared_point_numbers = PackedPointNumbers{};
        var serialized_data = serialized_all;
        if ((count_raw & tuple_count_shared_points) != 0) {
            const split = PackedPointNumbers.splitOffFront(serialized_all);
            shared_point_numbers = split.point_numbers;
            serialized_data = split.rest;
        }
        return .{
            .data = data,
            .axis_count = gvar.axis_count,
            .shared_tuples = shared_tuples,
            .tuple_count = count_raw & tuple_count_mask,
            .has_shared_point_numbers = (count_raw & tuple_count_shared_points) != 0,
            .shared_point_numbers = shared_point_numbers,
            .header_data = data[4..],
            .serialized_data = serialized_data,
        };
    }

    /// Iterator over the tuples that are active at `coords`, mirroring
    /// `TupleVariationData::active_tuples_at`.
    pub fn activeTuples(self: *const GlyphVariationData, coords: []const i16) ActiveTupleIter {
        return .{ .parent = self, .coords = coords };
    }
};

/// A tuple variation together with its serialized body.
pub const TupleVariation = struct {
    axis_count: u16,
    tuple_index: u16,
    /// Embedded peak tuple bytes (may be empty when shared).
    peak_embedded: []const u8 = &.{},
    /// Embedded intermediate start tuple bytes.
    intermediate_start: []const u8 = &.{},
    /// Embedded intermediate end tuple bytes.
    intermediate_end: []const u8 = &.{},
    shared_tuples: SharedTuples = .{},
    /// Serialized body of this tuple (point numbers and deltas).
    data: []const u8 = &.{},
    /// Shared point numbers, when the store provides them.
    shared_point_numbers: PackedPointNumbers = .{},
    has_shared_point_numbers: bool = false,

    pub fn embeddedPeak(self: TupleVariation) bool {
        return (self.tuple_index & tuple_index_embedded_peak) != 0;
    }

    pub fn privatePointNumbers(self: TupleVariation) bool {
        return (self.tuple_index & tuple_index_private_points) != 0;
    }

    pub fn peak(self: TupleVariation) ?Tuple {
        if (self.embeddedPeak()) {
            if (self.peak_embedded.len < 2 * @as(usize, self.axis_count)) return null;
            return .{ .data = self.peak_embedded, .axis_count = self.axis_count };
        }
        return self.shared_tuples.get(self.tuple_index & tuple_index_mask);
    }

    pub fn intermediate(self: TupleVariation) ?IntermediateTuples {
        if ((self.tuple_index & tuple_index_intermediate) == 0) return null;
        if (self.intermediate_start.len < 2 * @as(usize, self.axis_count)) return null;
        if (self.intermediate_end.len < 2 * @as(usize, self.axis_count)) return null;
        return .{
            .start = .{ .data = self.intermediate_start, .axis_count = self.axis_count },
            .end = .{ .data = self.intermediate_end, .axis_count = self.axis_count },
        };
    }

    /// `TupleVariation::has_deltas_for_all_points`.
    pub fn hasDeltasForAllPoints(self: TupleVariation) bool {
        if (self.privatePointNumbers()) {
            const pn = PackedPointNumbers{ .data = self.data };
            return (pn.count() == 0);
        }
        if (self.has_shared_point_numbers) {
            return self.shared_point_numbers.count() == 0;
        }
        return false;
    }

    /// `(point_numbers, packed_deltas_data)` for this tuple.
    fn pointNumbersAndDeltas(self: TupleVariation) PointNumbersAndDeltas {
        if (self.privatePointNumbers()) {
            const split = PackedPointNumbers.splitOffFront(self.data);
            return .{ .points = split.point_numbers, .deltas = split.rest };
        }
        return .{
            .points = if (self.has_shared_point_numbers) self.shared_point_numbers else PackedPointNumbers{},
            .deltas = self.data,
        };
    }

    /// Fixed-point scalar for this tuple at `coords`
    /// (`read_fonts::tables::variations::compute_scalar`).
    pub fn computeScalar(self: TupleVariation, coords: []const i16) ?i32 {
        var scalar: i32 = fixed_one;
        const peak_tuple = self.peak() orelse return null;
        if (peak_tuple.len() != self.axis_count) return null;
        const intermediate_tuples = self.intermediate();
        var i: usize = 0;
        while (i < self.axis_count) : (i += 1) {
            const peak_value = peak_tuple.get(i) orelse return null;
            if (peak_value == 0) continue;
            const coord: i16 = if (i < coords.len) coords[i] else 0;
            if (coord == 0) return null;
            if (peak_value == coord) continue;
            if (intermediate_tuples) |inter| {
                const start = inter.start.get(i) orelse return null;
                const end = inter.end.get(i) orelse return null;
                if (coord <= start or coord >= end) return null;
                const coord_fixed = f2dot14ToFixed(coord);
                const peak_fixed = f2dot14ToFixed(peak_value);
                if (coord_fixed < peak_fixed) {
                    scalar = fixedMulDiv(
                        scalar,
                        coord_fixed -% f2dot14ToFixed(start),
                        peak_fixed -% f2dot14ToFixed(start),
                    );
                } else {
                    scalar = fixedMulDiv(
                        scalar,
                        f2dot14ToFixed(end) -% coord_fixed,
                        f2dot14ToFixed(end) -% peak_fixed,
                    );
                }
            } else {
                const peak_min: i16 = @min(peak_value, 0);
                const peak_max: i16 = @max(peak_value, 0);
                if (coord < peak_min or coord > peak_max) return null;
                scalar = fixedMulDiv(scalar, f2dot14ToFixed(coord), f2dot14ToFixed(peak_value));
            }
        }
        return if (scalar != 0) scalar else null;
    }

    /// Accumulates dense deltas for all points (`accumulate_dense_deltas`).
    pub fn accumulateDenseDeltas(self: TupleVariation, out_deltas: []Point16, scalar: i32) Error!void {
        const packed_deltas = self.pointNumbersAndDeltas().deltas;
        var cursor = DeltaCursor{ .data = packed_deltas };
        readDenseRun(&cursor, out_deltas, scalar, .x) catch |err| return err;
        readDenseRun(&cursor, out_deltas, scalar, .y) catch |err| return err;
    }

    /// Accumulates sparse deltas and sets the `HAS_DELTA` marker (0x04) on the
    /// points that receive one (`accumulate_sparse_deltas`).
    pub fn accumulateSparseDeltas(
        self: TupleVariation,
        out_deltas: []Point16,
        flags: []u8,
        scalar: i32,
    ) Error!void {
        const split = self.pointNumbersAndDeltas();
        var cursor = DeltaCursor{ .data = split.deltas };
        const point_count = split.points.count();
        readSparseRun(&cursor, split.points, point_count, out_deltas, flags, scalar, .x) catch |err| return err;
        readSparseRun(&cursor, split.points, point_count, out_deltas, flags, scalar, .y) catch |err| return err;
    }

    /// Iterator over explicitly encoded deltas (`TupleVariation::deltas`),
    /// used by composite glyphs and `cvar`.
    pub fn deltas(self: TupleVariation, is_point: bool) DeltaIter {
        const split = self.pointNumbersAndDeltas();
        const point_count = split.points.count();
        const packed_deltas = if (point_count == 0)
            PackedDeltas{ .data = split.deltas }
        else
            PackedDeltas{ .data = split.deltas, .count = if (is_point) @as(usize, point_count) * 2 else point_count };
        return DeltaIter.init(split.points, packed_deltas, is_point);
    }
};

fn readDenseRun(cursor: *DeltaCursor, deltas: []Point16, scalar: i32, comptime coord: enum { x, y }) Error!void {
    const count = deltas.len;
    var cur: usize = 0;
    while (cur < count) {
        if (cursor.run_remaining == 0) try cursor.readControl();
        const run_count = cursor.run_remaining;
        if (cur + run_count > count) return error.OutOfBounds;
        var i: usize = 0;
        while (i < run_count) : (i += 1) {
            const raw = (try cursor.next()).?;
            if (scalar == fixed_one) {
                // Fast path: `D::from_i32(delta)` without the multiply.
                const converted = fixedFromI32(raw);
                switch (coord) {
                    .x => deltas[cur + i].x +%= converted,
                    .y => deltas[cur + i].y +%= converted,
                }
            } else {
                const scaled = fixedMul(fixedFromI32(raw), scalar);
                switch (coord) {
                    .x => deltas[cur + i].x +%= scaled,
                    .y => deltas[cur + i].y +%= scaled,
                }
            }
        }
        cur += run_count;
    }
}

fn readSparseRun(
    cursor: *DeltaCursor,
    point_numbers: PackedPointNumbers,
    point_count: usize,
    deltas: []Point16,
    flags: []u8,
    scalar: i32,
    comptime coord: enum { x, y },
) Error!void {
    // Upstream creates a fresh point-number iterator for the x and y passes.
    var points = point_numbers.iter();
    var cur: usize = 0;
    while (cur < point_count) {
        if (cursor.run_remaining == 0) try cursor.readControl();
        const run_count = cursor.run_remaining;
        var i: usize = 0;
        while (i < run_count) : (i += 1) {
            const point_ix: usize = points.next() orelse return error.OutOfBounds;
            const raw = (try cursor.next()).?;
            if (point_ix >= deltas.len or point_ix >= flags.len) continue;
            if (scalar == fixed_one) {
                const converted = fixedFromI32(raw);
                switch (coord) {
                    .x => {
                        deltas[point_ix].x +%= converted;
                        flags[point_ix] |= 0x04;
                    },
                    .y => deltas[point_ix].y +%= converted,
                }
            } else {
                const scaled = fixedMul(fixedFromI32(raw), scalar);
                switch (coord) {
                    .x => {
                        deltas[point_ix].x +%= scaled;
                        flags[point_ix] |= 0x04;
                    },
                    .y => deltas[point_ix].y +%= scaled,
                }
            }
        }
        cur += run_count;
    }
}

/// Iterator over tuple variation headers that apply at a location. Equivalent
/// to `ActiveTupleVariationIter`; malformed headers or truncated bodies end the
/// iteration early rather than failing, exactly like the upstream iterator
/// chain.
pub const ActiveTupleIter = struct {
    parent: *const GlyphVariationData,
    coords: []const i16,
    header_pos: usize = 0,
    data_offset: usize = 0,
    index: usize = 0,

    pub const Item = struct {
        tuple: TupleVariation,
        scalar: i32,
    };

    pub fn next(self: *ActiveTupleIter) ?Item {
        while (self.index < self.parent.tuple_count) {
            self.index += 1;
            const header = self.readHeader() orelse return null;
            self.header_pos = header.next_pos;
            const data_start = self.data_offset;
            const data_end = std.math.add(usize, data_start, header.data_size) catch return null;
            self.data_offset = data_end;
            var tuple = TupleVariation{
                .axis_count = self.parent.axis_count,
                .tuple_index = header.tuple_index,
                .peak_embedded = header.peak,
                .intermediate_start = header.intermediate_start,
                .intermediate_end = header.intermediate_end,
                .shared_tuples = self.parent.shared_tuples,
                .has_shared_point_numbers = self.parent.has_shared_point_numbers,
                .shared_point_numbers = self.parent.shared_point_numbers,
            };
            if (data_end > self.parent.serialized_data.len) return null;
            tuple.data = self.parent.serialized_data[data_start..data_end];
            if (tuple.computeScalar(self.coords)) |scalar| {
                return .{ .tuple = tuple, .scalar = scalar };
            }
        }
        return null;
    }

    const Header = struct {
        tuple_index: u16,
        data_size: usize,
        next_pos: usize,
        peak: []const u8 = &.{},
        intermediate_start: []const u8 = &.{},
        intermediate_end: []const u8 = &.{},
    };

    fn readHeader(self: *ActiveTupleIter) ?Header {
        const data = self.parent.header_data;
        const pos = self.header_pos;
        if (pos + 4 > data.len) return null;
        const data_size = std.mem.readInt(u16, data[pos..][0..2], .big);
        const tuple_index = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        const axis_count = @as(usize, self.parent.axis_count);
        const tuple_bytes = 2 * axis_count;
        var cursor = pos + 4;
        var peak: []const u8 = &.{};
        var intermediate_start: []const u8 = &.{};
        var intermediate_end: []const u8 = &.{};
        if ((tuple_index & tuple_index_embedded_peak) != 0) {
            if (cursor + tuple_bytes > data.len) return null;
            peak = data[cursor .. cursor + tuple_bytes];
            cursor += tuple_bytes;
        }
        if ((tuple_index & tuple_index_intermediate) != 0) {
            if (cursor + 2 * tuple_bytes > data.len) return null;
            intermediate_start = data[cursor .. cursor + tuple_bytes];
            cursor += tuple_bytes;
            intermediate_end = data[cursor .. cursor + tuple_bytes];
            cursor += tuple_bytes;
        }
        return .{
            .tuple_index = tuple_index,
            .data_size = data_size,
            .next_pos = cursor,
            .peak = peak,
            .intermediate_start = intermediate_start,
            .intermediate_end = intermediate_end,
        };
    }
};

/// Iterator over explicitly encoded deltas (`TupleDeltaIter`).
pub const DeltaIter = struct {
    is_point: bool,
    points: PointNumbersIter = .{ .data = &.{}, .pos = 0, .count = 0, .seen = 0, .last_val = 0 },
    has_points: bool = false,
    next_point: usize = 0,
    cur: usize = 0,
    x: DeltaCursor = .{ .data = &.{} },
    y: DeltaCursor = .{ .data = &.{} },
    scalars: DeltaCursor = .{ .data = &.{} },

    pub const Delta = struct {
        position: u16,
        x: i32,
        y: i32,
    };

    fn init(points: PackedPointNumbers, packed_deltas: PackedDeltas, is_point: bool) DeltaIter {
        var result = DeltaIter{ .is_point = is_point };
        var iter = points.iter();
        if (iter.next()) |first| {
            result.points = iter;
            result.has_points = true;
            result.next_point = first;
        }
        const total = packed_deltas.countOrCompute();
        if (is_point) {
            result.x = .{ .data = packed_deltas.data, .limit = total / 2 };
            result.y = .{ .data = packed_deltas.data, .limit = total };
            result.y.skip(total / 2) catch {
                // Mirror the iterator ending on a malformed stream.
                result.y.limit = 0;
            };
        } else {
            result.scalars = .{ .data = packed_deltas.data, .limit = total };
        }
        return result;
    }

    pub fn next(self: *DeltaIter) ?Delta {
        while (true) {
            const position: usize = if (self.has_points) blk: {
                if (self.cur > self.next_point) {
                    self.next_point = self.points.next() orelse return null;
                }
                break :blk self.next_point;
            } else self.cur;
            if (position == self.cur) {
                if (self.is_point) {
                    const dx = (self.x.next() catch return null) orelse return null;
                    const dy = (self.y.next() catch return null) orelse return null;
                    self.cur += 1;
                    return .{ .position = @intCast(position), .x = dx, .y = dy };
                }
                const value = (self.scalars.next() catch return null) orelse return null;
                self.cur += 1;
                return .{ .position = @intCast(position), .x = value, .y = 0 };
            }
            self.cur += 1;
        }
    }
};

// ----------------------------------------------------------------------- cvar

/// The `cvar` table: CVT variation deltas (no axis count field).
pub const Cvar = struct {
    data: []const u8,

    pub fn parse(data: []const u8) Error!Cvar {
        if (data.len < 4) return error.Truncated;
        return .{ .data = data };
    }

    /// Parsed tuple-variation data with `axis_count` supplied by the caller
    /// (upstream reads it from `fvar`; the port uses the `gvar` axis count).
    pub fn variationData(self: Cvar, axis_count: u16) Error!GlyphVariationData {
        if (self.data.len < 4) return error.Truncated;
        const count_raw = std.mem.readInt(u16, self.data[0..2], .big);
        const serialized_offset = std.mem.readInt(u16, self.data[2..4], .big);
        if (serialized_offset > self.data.len) return error.OutOfBounds;
        const serialized_all = self.data[serialized_offset..];
        var shared_point_numbers = PackedPointNumbers{};
        var serialized_data = serialized_all;
        if ((count_raw & tuple_count_shared_points) != 0) {
            const split = PackedPointNumbers.splitOffFront(serialized_all);
            shared_point_numbers = split.point_numbers;
            serialized_data = split.rest;
        }
        return .{
            .data = self.data,
            .axis_count = axis_count,
            .shared_tuples = .{},
            .tuple_count = count_raw & tuple_count_mask,
            .has_shared_point_numbers = (count_raw & tuple_count_shared_points) != 0,
            .shared_point_numbers = shared_point_numbers,
            .header_data = self.data[4..],
            .serialized_data = serialized_data,
        };
    }

    /// Accumulates the 16.16 deltas for `coords` into `deltas` (capped to the
    /// slice length, like upstream's `get_mut`).
    pub fn deltas(
        self: Cvar,
        axis_count: u16,
        coords: []const i16,
        out_deltas: []i32,
    ) Error!void {
        const var_data = try self.variationData(axis_count);
        var iter = var_data.activeTuples(coords);
        while (iter.next()) |active| {
            var delta_iter = active.tuple.deltas(false);
            while (delta_iter.next()) |delta| {
                const ix: usize = delta.position;
                if (ix >= out_deltas.len) continue;
                const scaled = fixedMul(fixedFromI32(delta.x), active.scalar);
                out_deltas[ix] +%= scaled;
            }
        }
    }
};

// ---------------------------------------------------------------------- tests

const testing = std.testing;

test "cvar applies packed scalar deltas" {
    // One tuple: embedded peak 1.0 on a single axis, dense I8 delta of 8.
    const table = [_]u8{
        0x00, 0x01, // tupleVariationCount = 1
        0x00, 0x0A, // serializedDataOffset = 10
        0x00, 0x02, // variationDataSize = 2
        0x80, 0x00, // tupleIndex: embedded peak
        0x40, 0x00, // peak = 1.0
        0x00, 0x08, // one I8 delta: 8
    };
    const cvar = try Cvar.parse(&table);
    var deltas = [_]i32{0};
    try cvar.deltas(1, &.{0x4000}, deltas[0..]);
    try testing.expectEqual(@as(i32, 8 << 16), deltas[0]);

    // Outside the peak's extent the tuple is inactive.
    deltas[0] = 0;
    try cvar.deltas(1, &.{-0x4000}, deltas[0..]);
    try testing.expectEqual(@as(i32, 0), deltas[0]);

    // Positions past the output slice are ignored, not written.
    var small = [_]i32{0};
    try cvar.deltas(1, &.{0x4000}, small[0..0]);
    try testing.expectEqual(@as(i32, 0), small[0]);
}

test "fixed point helpers match read-fonts" {
    try testing.expectEqual(@as(i32, 0x10000), fixedMul(0x10000, 0x10000));
    try testing.expectEqual(@as(i32, 0x8000), fixedMul(0x8000, 0x10000));
    try testing.expectEqual(@as(i32, 0x30000), fixedMulDiv(0x30000, 0x10000, 0x10000));
    try testing.expectEqual(@as(i32, 0x18000), fixedMulDiv(0x30000, 0x10000, 0x20000));
    // `(a*b + b/2) / b`, sign applied afterwards.
    try testing.expectEqual(@as(i32, 1), fixedMulDiv(1, 1, 1));
    try testing.expectEqual(@as(i32, -1), fixedMulDiv(-1, 1, 1));
    try testing.expectEqual(@as(i32, 0x7FFFFFFF), fixedMulDiv(1, 1, 0));
    try testing.expectEqual(@as(i32, 0x00010000), fixedFromI32(1));
    try testing.expectEqual(@as(i32, 1), fixedToI32(0x8000));
    try testing.expectEqual(@as(i32, 0), fixedToI32(0x7FFF));
    try testing.expectEqual(@as(i32, 0x4000), f2dot14ToFixed(0x1000));
}

test "packed point numbers decode dense and sparse runs" {
    // Count 3, then one run: control 0x02 => three 1-byte deltas, two bytes.
    const data = [_]u8{ 3, 0x02, 1, 2, 3 };
    const point_numbers = PackedPointNumbers{ .data = &data };
    try testing.expectEqual(@as(u16, 3), point_numbers.count());
    var iter = point_numbers.iter();
    try testing.expectEqual(@as(u16, 1), iter.next().?);
    try testing.expectEqual(@as(u16, 3), iter.next().?);
    try testing.expectEqual(@as(u16, 6), iter.next().?);
    try testing.expectEqual(@as(?u16, null), iter.next());
    const split = PackedPointNumbers.splitOffFront(&data);
    try testing.expectEqual(@as(usize, 0), split.rest.len);
}

test "zero-count packed points iterate densely" {
    const data = [_]u8{0};
    const point_numbers = PackedPointNumbers{ .data = &data };
    try testing.expectEqual(@as(u16, 0), point_numbers.count());
    var iter = point_numbers.iter();
    try testing.expectEqual(@as(u16, 0), iter.next().?);
    try testing.expectEqual(@as(u16, 1), iter.next().?);
    try testing.expectEqual(@as(u16, 2), iter.next().?);
}

test "Inconsolata exposes the pinned gvar header" {
    const fixture = @import("../test_fixture.zig");
    const font = try @import("../font.zig").Font.init(try fixture.inconsolata(), 0);
    const data = font.face.table(sfnt.Tag{ 'g', 'v', 'a', 'r' }).?;
    const gvar = try Gvar.parse(data);
    try testing.expectEqual(@as(u16, 2), gvar.axis_count);
    try testing.expectEqual(@as(u16, 8), gvar.shared_tuple_count);
    try testing.expectEqual(@as(u16, 962), gvar.glyph_count);
    try testing.expect(gvar.long_offsets);
    const tuples = try gvar.sharedTuples();
    try testing.expectEqual(@as(u16, 8), tuples.count);
    // Pinned shared tuples: (0, 1), (0, -1), (1, 0), ...
    try testing.expectEqual(@as(i16, 0), tuples.get(0).?.get(0).?);
    try testing.expectEqual(@as(i16, 0x4000), tuples.get(0).?.get(1).?);
    try testing.expectEqual(@as(i16, 0x4000), tuples.get(2).?.get(0).?);
    try testing.expectEqual(@as(i16, 0), tuples.get(2).?.get(1).?);
}
