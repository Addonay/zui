//! CFF/CFF2 table parsing: INDEX, DICT, charset, FDSelect, private dicts and
//! the CFF header layouts.
//!
//! Hand-written subset of `read-fonts` 0.41.0 (`src/ps/cff/{v1,v2,index,dict,
//! charset,encoding,fd_select,stack,blend}.rs` and `src/ps/num.rs`) that the
//! `skrifa 0.44.0` CFF outline scaler needs. Scope:
//!
//! - INDEX format 1 (CFF) and 2 (CFF2), including the "empty INDEX" fast paths
//!   and `size_in_bytes` used to walk the table;
//! - DICT operand/operator scanning for the top/private/font DICTs, including
//!   binary-coded decimals, delta prefix sums and the CFF2 `blend`/`vsindex`
//!   operators;
//! - charset formats 0/1/2 plus the predefined ISOAdobe/Expert/ExpertSubset
//!   sets (only the SID -> GID direction is needed, for `seac`);
//! - FDSelect formats 0/3/4;
//! - the private DICT entries the unhinted scaler reads (`Subrs`, default and
//!   nominal widths, variation store index, FontMatrix).
//!
//! Not ported here: hinting parameters (the hinting interpreter is deferred;
//! see `cff.zig`), CFF2 delta-set decoding (the `blend` operator only consumes
//! the deltas already on the operand stack), string INDEX resolution and
//! encoding tables beyond the standard encoding. Every parse failure is a
//! typed error; nothing is silently defaulted except where `read-fonts`'s
//! generated accessors explicitly degrade (`read_array(..).ok()
//! .unwrap_or_default()`), which is called out at each site.

const std = @import("std");
const sfnt = @import("sfnt.zig");
const variations = @import("variations.zig");
const fixed = @import("../fixed.zig");

pub const Fixed = fixed.Fixed;

pub const Error = error{
    Truncated,
    OutOfBounds,
    InvalidNumber,
    InvalidDictOperator,
    InvalidIndexOffsetSize,
    ZeroOffsetInIndex,
    InvalidFormat,
    MissingBlendState,
    MissingPrivateDict,
    InvalidVariationStoreIndex,
    StackUnderflow,
    StackOverflow,
    ExpectedI32StackEntry,
};

/// A byte range inside the CFF table (private DICTs, charset offsets).
pub const Range = struct {
    start: usize,
    end: usize,
};

/// Zig 0.17 dropped the `**` array-repetition operator; this is the
/// comptime replacement for the fixed-size tables below.
pub fn repeated(comptime T: type, comptime N: usize, value: T) [N]T {
    var out: [N]T = undefined;
    @memset(&out, value);
    return out;
}

// --------------------------------------------------------------------- INDEX

/// `Index1`/`Index2` plus the unified `read-fonts` `Index` enum semantics.
pub const Index = struct {
    /// Object data (the slice after the offset array).
    data: []const u8 = &.{},
    /// Raw `count + 1` offsets.
    offsets: []const u8 = &.{},
    count: u32 = 0,
    off_size: u8 = 0,
    is_cff2: bool = false,
    /// True only for the `data.len == 2/4 && count == 0` fast path, which has
    /// `size_in_bytes == 0` (unlike a parsed zero-length INDEX).
    empty: bool = false,

    pub const empty_index: Index = .{};

    /// `Index::new`: the caller states whether the data comes from CFF2.
    pub fn new(data: []const u8, is_cff2: bool) Error!Index {
        if (is_cff2) {
            if (data.len == 4 and sfnt.readU32(data, 0).? == 0) {
                return .{ .is_cff2 = true, .empty = true };
            }
            const count = sfnt.readU32(data, 0) orelse return error.OutOfBounds;
            if (count == 0) return .{ .is_cff2 = true };
            const off_size = data[4];
            const offsets_len = (@as(usize, count) + 1) * @as(usize, off_size);
            const start = 5;
            if (off_size < 1 or off_size > 4) return error.InvalidIndexOffsetSize;
            if (start + offsets_len > data.len) return error.OutOfBounds;
            return .{
                .data = data[start + offsets_len ..],
                .offsets = data[start .. start + offsets_len],
                .count = count,
                .off_size = off_size,
                .is_cff2 = true,
            };
        }
        if (data.len == 2 and sfnt.readU16(data, 0).? == 0) {
            return .{ .empty = true };
        }
        const count = sfnt.readU16(data, 0) orelse return error.OutOfBounds;
        if (count == 0) return .{};
        if (data.len < 3) return error.OutOfBounds;
        const off_size = data[2];
        const offsets_len = (@as(usize, count) + 1) * @as(usize, off_size);
        const start = 3;
        if (off_size < 1 or off_size > 4) return error.InvalidIndexOffsetSize;
        if (start + offsets_len > data.len) return error.OutOfBounds;
        return .{
            .data = data[start + offsets_len ..],
            .offsets = data[start .. start + offsets_len],
            .count = count,
            .off_size = off_size,
        };
    }

    /// `Index::size_in_bytes`: the bytes consumed in the table, used to walk
    /// from one INDEX to the next.
    pub fn sizeInBytes(self: Index) Error!usize {
        if (self.empty) return 0;
        if (self.count == 0) return if (self.is_cff2) 4 else 2;
        const header: usize = if (self.is_cff2) 5 else 3;
        const last = try self.getOffset(self.count);
        return header + self.offsets.len + last;
    }

    /// `read_offset`: fail-OOB check, variable-size big-endian read and the
    /// "offsets are one-based" subtraction.
    pub fn getOffset(self: Index, index: usize) Error!usize {
        if (index > self.count) return error.OutOfBounds;
        const at = index * @as(usize, self.off_size);
        const off = switch (self.off_size) {
            1 => if (at < self.offsets.len) @as(u32, self.offsets[at]) else return error.OutOfBounds,
            2 => @as(u32, sfnt.readU16(self.offsets, at) orelse return error.OutOfBounds),
            3 => blk: {
                const b = self.offsets[at..];
                if (b.len < 3) return error.OutOfBounds;
                break :blk (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | @as(u32, b[2]);
            },
            4 => sfnt.readU32(self.offsets, at) orelse return error.OutOfBounds,
            else => return error.InvalidIndexOffsetSize,
        };
        return std.math.sub(usize, off, 1) catch return error.ZeroOffsetInIndex;
    }

    /// `Index::get`: the object bytes at `index`.
    pub fn get(self: Index, index: usize) Error![]const u8 {
        if (self.empty) return error.OutOfBounds;
        const start = try self.getOffset(index);
        const end = try self.getOffset(index + 1);
        const data = self.data;
        if (start > end or end > data.len) return error.OutOfBounds;
        return data[start..end];
    }

    /// `Index::subr_bias`.
    pub fn subrBias(self: Index) i32 {
        const count = self.count;
        if (count < 1240) return 107;
        if (count < 33900) return 1131;
        return 32768;
    }
};

// ----------------------------------------------------------------- statement?

/// CFF table header + the four INDEXes (read-fonts `Cff`).
pub const Cff = struct {
    /// The full CFF table; all internal offsets resolve against it.
    data: []const u8 = &.{},
    major: u8 = 0,
    minor: u8 = 0,
    names: Index = Index.empty_index,
    top_dicts: Index = Index.empty_index,
    strings: Index = Index.empty_index,
    global_subrs: Index = Index.empty_index,

    pub fn parse(data: []const u8) Error!Cff {
        if (data.len < 4) return error.Truncated;
        // `_padding_byte_range`: `start = 4`, `end = 4 + (hdr_size - 4)
        // .saturating_sub`, so a header size below 4 still starts trailing
        // data at 4.
        const hdr_size = data[2];
        const trailing_start = if (hdr_size < 4) 4 else @min(@as(usize, hdr_size), data.len);
        var rest = data[trailing_start..];
        const names = try Index.new(rest, false);
        rest = try advance(rest, try names.sizeInBytes());
        const top_dicts = try Index.new(rest, false);
        rest = try advance(rest, try top_dicts.sizeInBytes());
        const strings = try Index.new(rest, false);
        rest = try advance(rest, try strings.sizeInBytes());
        const global_subrs = try Index.new(rest, false);
        return .{
            .data = data,
            .major = data[0],
            .minor = data[1],
            .names = names,
            .top_dicts = top_dicts,
            .strings = strings,
            .global_subrs = global_subrs,
        };
    }
};

fn advance(data: []const u8, n: usize) Error![]const u8 {
    if (n > data.len) return error.OutOfBounds;
    return data[n..];
}

/// CFF2 table header + top DICT + global subrs (read-fonts `Cff2`).
pub const Cff2 = struct {
    data: []const u8 = &.{},
    major: u8 = 0,
    header_size: u8 = 5,
    top_dict_data: []const u8 = &.{},
    global_subrs: Index = Index.empty_index,

    pub fn parse(data: []const u8) Error!Cff2 {
        if (data.len < 5) return error.Truncated;
        const header_size = data[2];
        const top_dict_length = sfnt.readU16(data, 3).?;
        // Generated accessors: `read_array(range).ok().unwrap_or_default()`,
        // so out-of-range DICT data degrades to an empty slice.
        const top_start = if (header_size < 5) 5 else @min(@as(usize, header_size), data.len);
        const top_end = @min(top_start + @as(usize, top_dict_length), data.len);
        const top_dict_data = data[top_start..top_end];
        const global_start = top_end;
        const global_subrs = try Index.new(data[global_start..], true);
        return .{
            .data = data,
            .major = data[0],
            .header_size = header_size,
            .top_dict_data = top_dict_data,
            .global_subrs = global_subrs,
        };
    }
};

// ------------------------------------------------------------- DICT operands

/// `read-fonts` `ps::num::parse_int`: the shared Type2/Type1/DICT integer
/// operand encoding. `b0` has already been consumed.
pub fn parseInt(bytes: []const u8, pos: *usize, b0: u8) Error!i32 {
    const cursor = bytes;
    switch (b0) {
        32...246 => return @as(i32, b0) - 139,
        247...250 => {
            if (pos.* >= cursor.len) return error.OutOfBounds;
            const b1 = cursor[pos.*];
            pos.* += 1;
            return (@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108;
        },
        251...254 => {
            if (pos.* >= cursor.len) return error.OutOfBounds;
            const b1 = cursor[pos.*];
            pos.* += 1;
            return -(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108;
        },
        28 => {
            const v = sfnt.readI16(cursor, pos.*) orelse return error.OutOfBounds;
            pos.* += 2;
            return v;
        },
        29 => {
            if (pos.* + 4 > cursor.len) return error.OutOfBounds;
            const v = std.mem.readInt(i32, cursor[pos.*..][0..4], .big);
            pos.* += 4;
            return v;
        },
        else => return error.InvalidNumber,
    }
}

/// `read-fonts` `ps::num::parse_int` for the charstring evaluator, which
/// expects the bounds-checked slice semantics of `Cursor`.
pub fn readU8(bytes: []const u8, pos: *usize) Error!u8 {
    if (pos.* >= bytes.len) return error.OutOfBounds;
    const b = bytes[pos.*];
    pos.* += 1;
    return b;
}

pub fn readI16At(bytes: []const u8, pos: *usize) Error!i16 {
    const v = sfnt.readI16(bytes, pos.*) orelse return error.OutOfBounds;
    pos.* += 2;
    return v;
}

pub fn readI32At(bytes: []const u8, pos: *usize) Error!i32 {
    if (pos.* + 4 > bytes.len) return error.OutOfBounds;
    const v = std.mem.readInt(i32, bytes[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}

pub fn readU32At(bytes: []const u8, pos: *usize) Error!u32 {
    if (pos.* + 4 > bytes.len) return error.OutOfBounds;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}

// -------------------------------------------------------------------- numbers

/// Unnamed constants from FreeType's `cff_parse_real`, mirrored by
/// `read-fonts` `ps::num`.
const bcd_overflow: Fixed = .{ .bits = 0x7FFFFFFF };
const bcd_underflow: Fixed = .zero;
const bcd_number_limit: i32 = 0xCCCCCCC;
const bcd_integer_limit: i32 = 0x7FFF;

pub const bcd_power_tens = [10]i32{
    1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000,
};

/// `read-fonts` `ps::num::BcdComponents`.
pub const BcdComponents = struct {
    /// Early overflow/underflow result (`BcdComponents::from(Fixed)`).
    error_value: ?Fixed = null,
    number: i32 = 0,
    sign: i32 = 1,
    exponent: i32 = 0,
    exponent_add: i32 = 0,
    integer_len: i32 = 0,
    fraction_len: i32 = 0,

    const Phase = enum { integer, fraction, exponent };

    /// Parse a binary-coded-decimal number; the leading `30` opcode has
    /// already been consumed.
    pub fn parse(bytes: []const u8, pos: *usize) Error!BcdComponents {
        var phase: Phase = .integer;
        var sign: i32 = 1;
        var exponent_sign: i32 = 1;
        var number: i32 = 0;
        var exponent: i32 = 0;
        var exponent_add: i32 = 0;
        var integer_len: i32 = 0;
        var fraction_len: i32 = 0;
        outer: while (true) {
            const b = try readU8(bytes, pos);
            const nibbles = [2]u8{ (b >> 4) & 0xF, b & 0xF };
            for (nibbles) |nibble| {
                switch (phase) {
                    .integer => switch (nibble) {
                        0x0...0x9 => {
                            if (number >= bcd_number_limit) {
                                exponent_add += 1;
                            } else if (nibble != 0 or number != 0) {
                                number = number * 10 + @as(i32, nibble);
                                integer_len += 1;
                            }
                        },
                        0xE => sign = -1,
                        0xA => phase = .fraction,
                        0xB => phase = .exponent,
                        0xC => {
                            phase = .exponent;
                            exponent_sign = -1;
                        },
                        else => break :outer,
                    },
                    .fraction => switch (nibble) {
                        0x0...0x9 => {
                            if (nibble == 0 and number == 0) {
                                exponent_add -= 1;
                            } else if (number < bcd_number_limit and fraction_len < 9) {
                                number = number * 10 + @as(i32, nibble);
                                fraction_len += 1;
                            }
                        },
                        0xB => phase = .exponent,
                        0xC => {
                            phase = .exponent;
                            exponent_sign = -1;
                        },
                        else => break :outer,
                    },
                    .exponent => switch (nibble) {
                        0x0...0x9 => {
                            if (exponent > 1000) {
                                return .{
                                    .error_value = if (exponent_sign == -1)
                                        bcd_underflow
                                    else
                                        bcd_overflow,
                                };
                            }
                            exponent = exponent * 10 + @as(i32, nibble);
                        },
                        else => break :outer,
                    },
                }
            }
        }
        return .{
            .number = number,
            .sign = sign,
            .exponent = exponent * exponent_sign,
            .exponent_add = exponent_add,
            .integer_len = integer_len,
            .fraction_len = fraction_len,
        };
    }

    /// `BcdComponents::value`; `scale_by_1000` is only used for `BlueScale`
    /// (unused without hinting, but kept for exactness).
    pub fn value(self: BcdComponents, scale_by_1000: bool) Fixed {
        if (self.error_value) |early| return early;
        var number = self.number;
        if (number == 0) return bcd_underflow;
        var exponent = self.exponent;
        var integer_len = self.integer_len;
        var fraction_len = self.fraction_len;
        if (scale_by_1000) {
            exponent += 3 + self.exponent_add;
        } else {
            exponent += self.exponent_add;
        }
        integer_len += exponent;
        fraction_len -= exponent;
        if (integer_len > 5) return bcd_overflow;
        if (integer_len < -5) return bcd_underflow;
        if (integer_len < 0) {
            number = @divTrunc(number, bcd_power_tens[@intCast(-integer_len)]);
            fraction_len += integer_len;
        }
        if (fraction_len == 10) {
            number = @divTrunc(number, 10);
            fraction_len -= 1;
        }
        var result: i32 = if (fraction_len > 0) blk: {
            const b = bcd_power_tens[@intCast(fraction_len)];
            if (@divTrunc(number, b) > bcd_integer_limit) break :blk 0;
            break :blk Fixed.fromBits(number).div(Fixed.fromBits(b)).bits;
        } else blk: {
            number = number *% bcd_power_tens[@intCast(-fraction_len)];
            if (number > bcd_integer_limit) return bcd_overflow;
            break :blk number << 16;
        };
        if (scale_by_1000) {
            result = Fixed.fromBits(result).div(Fixed.fromI32(1000)).bits;
        }
        return .{ .bits = result *% self.sign };
    }

    /// `BcdComponents::dynamically_scaled_value`, used by FontMatrix parsing.
    pub fn dynamicallyScaledValue(self: BcdComponents) ParsedFixed {
        if (self.error_value) |early| return .{ .value = early, .scaling = 0 };
        var number = self.number;
        if (number == 0) return .{ .value = bcd_underflow, .scaling = 0 };
        var exponent = self.exponent;
        const integer_len = self.integer_len;
        var fraction_len = self.fraction_len;
        exponent += self.exponent_add;
        fraction_len += integer_len;
        exponent += integer_len;
        var result: Fixed = undefined;
        var scaling: i32 = undefined;
        if (fraction_len <= 5) {
            if (number > bcd_integer_limit) {
                result = Fixed.fromBits(number).div(Fixed.fromBits(10));
                scaling = exponent - fraction_len + 1;
            } else {
                if (exponent > 0) {
                    const new_fraction_len = @min(exponent, 5);
                    const shift = new_fraction_len - fraction_len;
                    if (shift > 0) {
                        exponent -= new_fraction_len;
                        number *= bcd_power_tens[@intCast(shift)];
                        if (number > bcd_integer_limit) {
                            number = @divTrunc(number, 10);
                            exponent += 1;
                        }
                    } else {
                        exponent -= fraction_len;
                    }
                } else {
                    exponent -= fraction_len;
                }
                result = Fixed.fromBits(number << 16);
                scaling = exponent;
            }
        } else if (@divTrunc(number, bcd_power_tens[@intCast(fraction_len - 5)]) > bcd_integer_limit) {
            result = Fixed.fromBits(number).div(Fixed.fromBits(bcd_power_tens[@intCast(fraction_len - 4)]));
            scaling = exponent - 4;
        } else {
            result = Fixed.fromBits(number).div(Fixed.fromBits(bcd_power_tens[@intCast(fraction_len - 5)]));
            scaling = exponent - 5;
        }
        return .{ .value = .{ .bits = result.bits *% self.sign }, .scaling = scaling };
    }
};

/// `read-fonts` `ps::num::parse_fixed_dynamic`; used for the six FontMatrix
/// components with dynamic scaling.
pub const ParsedFixed = struct { value: Fixed, scaling: i32 };

pub fn parseFixedDynamic(bytes: []const u8, pos: *usize) Error!ParsedFixed {
    const b0 = try readU8(bytes, pos);
    switch (b0) {
        30 => return (try BcdComponents.parse(bytes, pos)).dynamicallyScaledValue(),
        28, 29, 32...254 => {
            const num = try parseInt(bytes, pos, b0);
            if (num > bcd_integer_limit) {
                var int_len: usize = 10;
                var i: usize = 5;
                while (i < bcd_power_tens.len) : (i += 1) {
                    if (num < bcd_power_tens[i]) {
                        int_len = i;
                        break;
                    }
                }
                const scaling: usize = if (num - bcd_power_tens[int_len - 5] > bcd_integer_limit)
                    int_len - 4
                else
                    int_len - 5;
                return .{
                    .value = Fixed.fromBits(num).div(Fixed.fromBits(bcd_power_tens[scaling])),
                    .scaling = @intCast(scaling),
                };
            }
            return .{ .value = Fixed.fromBits(num << 16), .scaling = 0 };
        },
        else => return error.InvalidNumber,
    }
}

// ----------------------------------------------------------- font matrices

/// `font-types::Matrix<Fixed>` restricted to the affine 6 elements.
pub const FontMatrix = struct {
    elements: [6]Fixed,

    pub const identity = FontMatrix{ .elements = .{
        Fixed.one, Fixed.zero, Fixed.zero, Fixed.one, Fixed.zero, Fixed.zero,
    } };

    pub fn fromElements(values: [6]Fixed) FontMatrix {
        return .{ .elements = values };
    }

    pub fn transform(self: FontMatrix, x: Fixed, y: Fixed) struct { x: Fixed, y: Fixed } {
        const e = self.elements;
        return .{
            .x = Fixed.add(Fixed.add(Fixed.mul(x, e[0]), Fixed.mul(y, e[2])), e[4]),
            .y = Fixed.add(Fixed.add(Fixed.mul(x, e[1]), Fixed.mul(y, e[3])), e[5]),
        };
    }
};

/// `read-fonts` `ps::transform::combine_scaled`.
pub fn combineScaled(a: FontMatrix, b: FontMatrix, scale: i32) FontMatrix {
    const ae = a.elements;
    const be = b.elements;
    const val = Fixed.fromI32(scale);
    const xx = Fixed.add(ae[0].mulDiv(be[0], val), ae[2].mulDiv(be[1], val));
    const yx = Fixed.add(ae[1].mulDiv(be[0], val), ae[3].mulDiv(be[1], val));
    const xy = Fixed.add(ae[0].mulDiv(be[2], val), ae[2].mulDiv(be[3], val));
    const yy = Fixed.add(ae[1].mulDiv(be[2], val), ae[3].mulDiv(be[3], val));
    const x = be[4];
    const y = be[5];
    const dx = Fixed.add(x.mulDiv(ae[0], val), y.mulDiv(ae[2], val));
    const dy = Fixed.add(x.mulDiv(ae[1], val), y.mulDiv(ae[3], val));
    return .{ .elements = .{ xx, yx, xy, yy, dx, dy } };
}

/// `read-fonts` `ps::transform::is_degenerate`.
pub fn isDegenerate(matrix: FontMatrix) bool {
    const e = matrix.elements;
    var xx: i64 = e[0].bits;
    var yx: i64 = e[1].bits;
    var xy: i64 = e[2].bits;
    var yy: i64 = e[3].bits;
    const val = @as(i64, @intCast(@abs(xx))) |
        @as(i64, @intCast(@abs(yx))) |
        @as(i64, @intCast(@abs(xy))) |
        @as(i64, @intCast(@abs(yy)));
    if (val == 0 or val > 0x7FFFFFFF) return true;
    const msb: i32 = 32 - @as(i32, @clz(@as(u32, @intCast(val)))) - 1;
    const shift = msb - 12;
    if (shift > 0) {
        xx >>= @intCast(shift);
        xy >>= @intCast(shift);
        yx >>= @intCast(shift);
        yy >>= @intCast(shift);
    }
    const temp1 = 32 * @abs(xx * yy - xy * yx);
    const temp2 = xx * xx + xy * xy + yx * yx + yy * yy;
    return temp1 <= temp2;
}

/// `read-fonts` `ps::transform::ScaledFontMatrix`.
pub const ScaledFontMatrix = struct {
    matrix: FontMatrix,
    scale: i32,

    /// `ScaledFontMatrix::parse` from the cursor's current position.
    pub fn parse(bytes: []const u8, pos: *usize) ?ScaledFontMatrix {
        var values = [_]Fixed{
            Fixed.zero, Fixed.zero, Fixed.zero, Fixed.zero, Fixed.zero, Fixed.zero,
        };
        var scalings = repeated(i32, 6, 0);
        var max_scaling: i32 = std.math.minInt(i32);
        var min_scaling: i32 = std.math.maxInt(i32);
        for (&values, &scalings) |*value, *scaling| {
            const parsed = parseFixedDynamic(bytes, pos) catch return null;
            if (parsed.value.bits != 0) {
                max_scaling = @max(max_scaling, parsed.scaling);
                min_scaling = @min(min_scaling, parsed.scaling);
            }
            value.* = parsed.value;
            scaling.* = parsed.scaling;
        }
        if (max_scaling < -9 or max_scaling > 0 or
            max_scaling - min_scaling < 0 or max_scaling - min_scaling > 9)
        {
            return null;
        }
        for (&values, scalings) |*value, scaling| {
            if (value.bits == 0) continue;
            const divisor = bcd_power_tens[@intCast(max_scaling - scaling)];
            const half_divisor = divisor >> 1;
            if (value.bits < 0) {
                if (std.math.minInt(i32) + half_divisor < value.bits) {
                    value.* = Fixed.fromBits(@divTrunc(value.bits - half_divisor, divisor));
                } else {
                    value.* = Fixed.fromBits(@divTrunc(std.math.minInt(i32), divisor));
                }
            } else if (std.math.maxInt(i32) - half_divisor > value.bits) {
                value.* = Fixed.fromBits(@divTrunc(value.bits + half_divisor, divisor));
            } else {
                value.* = Fixed.fromBits(@divTrunc(std.math.maxInt(i32), divisor));
            }
        }
        const matrix = FontMatrix.fromElements(values);
        if (isDegenerate(matrix)) return null;
        return .{ .matrix = matrix, .scale = bcd_power_tens[@intCast(-max_scaling)] };
    }

    /// `ScaledFontMatrix::normalize`.
    pub fn normalize(self: ScaledFontMatrix) ScaledFontMatrix {
        var matrix = self.matrix.elements;
        var scaled_upem = self.scale;
        const factor = if (matrix[3].bits != 0) matrix[3].abs() else matrix[1].abs();
        if (factor.bits != Fixed.one.bits) {
            scaled_upem = Fixed.fromBits(scaled_upem).div(factor).bits;
            for (&matrix) |*value| value.* = value.div(factor);
        }
        for (matrix[4..6]) |*offset| {
            offset.* = Fixed.fromBits(offset.bits >> 16);
        }
        return .{ .matrix = FontMatrix.fromElements(matrix), .scale = scaled_upem };
    }
};

// -------------------------------------------------------------------- stack

pub const max_stack: usize = 513;

/// `read-fonts` `ps::cff::stack::Stack`: parallel raw/integer-flag arrays with
/// FreeType's out-of-bounds-reads-yield-zero semantics.
pub const Stack = struct {
    values: [max_stack]i32 = repeated(i32, max_stack, 0),
    value_is_fixed: [max_stack]bool = repeated(bool, max_stack, false),
    top: usize = 0,

    pub fn is_empty(self: *const Stack) bool {
        return self.top == 0;
    }

    pub fn len(self: *const Stack) usize {
        return self.top;
    }

    pub fn lenIsOdd(self: *const Stack) bool {
        return self.top & 1 != 0;
    }

    pub fn clear(self: *Stack) void {
        self.top = 0;
    }

    pub fn exch(self: *Stack) Error!void {
        if (self.top < 2) return error.StackUnderflow;
        const a = self.top - 1;
        const b = a - 1;
        const v = self.values[a];
        self.values[a] = self.values[b];
        self.values[b] = v;
        const f = self.value_is_fixed[a];
        self.value_is_fixed[a] = self.value_is_fixed[b];
        self.value_is_fixed[b] = f;
    }

    pub fn pushI32(self: *Stack, value: i32) Error!void {
        try self.pushImpl(value, false);
    }

    pub fn pushFixed(self: *Stack, value: Fixed) Error!void {
        try self.pushImpl(value.bits, true);
    }

    pub fn setI32(self: *Stack, index: usize, value: i32) Error!void {
        if (index >= self.top) return error.StackOverflow;
        self.value_is_fixed[index] = false;
        self.values[index] = value;
    }

    pub fn setFixed(self: *Stack, index: usize, value: Fixed) Error!void {
        if (index >= self.top) return error.StackOverflow;
        self.value_is_fixed[index] = true;
        self.values[index] = value.bits;
    }

    /// `Stack::drop`, saturating at zero.
    pub fn drop(self: *Stack, n: usize) void {
        self.top = self.top -| n;
    }

    /// `Stack::get_i32`: OOB reads 0; a fixed entry is `ExpectedI32StackEntry`.
    pub fn getI32(self: *const Stack, index: usize) Error!i32 {
        if (index >= self.values.len) return 0;
        if (self.value_is_fixed[index]) return error.ExpectedI32StackEntry;
        return self.values[index];
    }

    /// `Stack::get_fixed`: OOB reads 0; integers convert.
    pub fn getFixed(self: *const Stack, index: usize) Error!Fixed {
        if (index >= self.values.len) return Fixed.zero;
        return if (self.value_is_fixed[index])
            Fixed.fromBits(self.values[index])
        else
            Fixed.fromI32(self.values[index]);
    }

    pub fn popI32(self: *Stack) Error!i32 {
        const i = self.pop();
        return self.getI32(i);
    }

    pub fn popFixed(self: *Stack) Error!Fixed {
        const i = self.pop();
        return self.getFixed(i);
    }

    /// `Stack::fixed_array`: OOB entries read as zero, padded.
    pub fn fixedArray(self: *const Stack, comptime N: usize, first_index: usize) Error![N]Fixed {
        var result = repeated(Fixed, N, Fixed.zero);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const index = first_index + i;
            if (index < self.top) result[i] = try self.getFixed(index);
        }
        return result;
    }

    /// `Stack::apply_delta_prefix_sum`; no-op for a stack of one element.
    pub fn applyDeltaPrefixSum(self: *Stack) void {
        if (self.top <= 1) return;
        var sum = Fixed.zero;
        for (self.values[0..self.top], 0..) |*value, i| {
            const entry = if (self.value_is_fixed[i])
                Fixed.fromBits(value.*)
            else
                Fixed.fromI32(value.*);
            sum = Fixed.add(sum, entry);
            value.* = sum.bits;
            self.value_is_fixed[i] = true;
        }
    }

    /// `Stack::div` (Type1 large-integer special case preserved).
    pub fn div(self: *Stack, is_type1: bool) Error!void {
        const b_idx = self.pop();
        const a_idx = self.pop();
        var a: Fixed = undefined;
        var b: Fixed = undefined;
        if (self.value_is_fixed[a_idx]) {
            a = try self.getFixed(a_idx);
            b = try self.getFixed(b_idx);
        } else {
            const a_raw = try self.getI32(a_idx);
            if (is_type1 and (a_raw < -32000 or a_raw > 32000)) {
                a = Fixed.fromBits(a_raw);
                b = Fixed.fromBits(try self.getI32(b_idx));
            } else {
                a = try self.getFixed(a_idx);
                b = try self.getFixed(b_idx);
            }
        }
        try self.pushFixed(a.div(b));
    }

    fn pushImpl(self: *Stack, value: i32, is_fixed: bool) Error!void {
        if (self.top == max_stack) return error.StackOverflow;
        self.values[self.top] = value;
        self.value_is_fixed[self.top] = is_fixed;
        self.top += 1;
    }

    /// FreeType/read-fonts: popping an empty stack reads slot 0 without
    /// changing the stack.
    fn pop(self: *Stack) usize {
        if (self.top > 0) {
            self.top -= 1;
            return self.top;
        }
        return 0;
    }
};

// -------------------------------------------------------------- blend state

pub const max_precomputed_scalars: usize = 16;

/// `read-fonts` `ps::cff::blend::BlendState`.
pub const BlendState = struct {
    store: variations.ItemVariationStore,
    coords: []const i16,
    store_index: u16 = 0,
    data: ?variations.ItemVariationData = null,
    region_indices: []const u8 = &.{},
    scalars: [max_precomputed_scalars]Fixed = repeated(Fixed, max_precomputed_scalars, Fixed.zero),

    pub fn init(
        store: variations.ItemVariationStore,
        coords: []const i16,
        store_index: u16,
    ) Error!BlendState {
        var state = BlendState{ .store = store, .coords = coords, .store_index = store_index };
        try state.updatePrecomputedScalars();
        return state;
    }

    pub fn setStoreIndex(self: *BlendState, store_index: u16) Error!void {
        if (self.store_index != store_index) {
            self.store_index = store_index;
            try self.updatePrecomputedScalars();
        }
    }

    pub fn regionCount(self: *const BlendState) Error!usize {
        return self.region_indices.len / 2;
    }

    /// `BlendState::scalars()` for one region index: precomputed for the first
    /// 16 regions, computed on demand beyond that.
    pub fn scalarAt(self: *const BlendState, region_ix: usize) Error!Fixed {
        if (region_ix < max_precomputed_scalars and region_ix * 2 < self.region_indices.len) {
            return self.scalars[region_ix];
        }
        const off = region_ix * 2;
        if (off + 2 > self.region_indices.len) return error.OutOfBounds;
        const index = sfnt.readU16(self.region_indices, off).?;
        const regions = try self.store.variationRegionList();
        const region = try regions.region(index);
        return region.computeScalar(self.coords);
    }

    fn updatePrecomputedScalars(self: *BlendState) Error!void {
        self.data = null;
        self.region_indices = &.{};
        const data = try self.store.itemVariationData(self.store_index);
        const region_indices = data.regionIndexes();
        const regions = try self.store.variationRegionList();
        var i: usize = 0;
        while (i < max_precomputed_scalars and i * 2 < region_indices.len) : (i += 1) {
            const index = sfnt.readU16(region_indices, i * 2).?;
            const region = try regions.region(index);
            self.scalars[i] = region.computeScalar(self.coords);
        }
        self.data = data;
        self.region_indices = region_indices;
    }

    /// `Stack::apply_blend`: consume `target_count` values plus their deltas.
    pub fn applyBlend(self: *BlendState, stack: *Stack) Error!void {
        const count_i32 = try stack.popI32();
        if (count_i32 < 0) return error.StackUnderflow;
        const target_value_count: usize = @intCast(count_i32);
        if (target_value_count > stack.top) return error.StackUnderflow;
        const region_count = try self.regionCount();
        const operand_count = target_value_count * (region_count + 1);
        if (stack.len() < operand_count) return error.StackUnderflow;
        const start = stack.len() - operand_count;
        const end = start + operand_count;
        for (stack.values[start..end], start..end) |*value, i| {
            if (!stack.value_is_fixed[i]) {
                value.* = Fixed.fromI32(value.*).bits;
                stack.value_is_fixed[i] = true;
            }
        }
        const values = stack.values[start .. start + target_value_count];
        const deltas = stack.values[start + target_value_count .. end];
        var region_ix: usize = 0;
        while (region_ix < region_count) : (region_ix += 1) {
            const scalar = try self.scalarAt(region_ix);
            if (scalar.bits == 0) continue;
            for (values, 0..) |*value, value_ix| {
                const delta = Fixed.fromBits(deltas[region_count * value_ix + region_ix]);
                value.* = Fixed.add(Fixed.fromBits(value.*), Fixed.mul(delta, scalar)).bits;
            }
        }
        stack.top = start + target_value_count;
    }
};

// --------------------------------------------------------------------- DICTs

/// `read-fonts` `ps::cff::dict::Entry` restricted to the fields the outline
/// pipeline consumes. Everything else parses into `.other` (the stack is still
/// maintained exactly, so subsequent entries see the same state).
pub const Entry = union(enum) {
    charstrings_offset: usize,
    fd_array_offset: usize,
    fd_select_offset: usize,
    private_dict_range: Range,
    font_matrix: ScaledFontMatrix,
    variation_store_offset: usize,
    charset_offset: usize,
    encoding_offset: usize,
    subrs_offset: usize,
    default_width_x: Fixed,
    nominal_width_x: Fixed,
    variation_store_index: u16,
    ros,
    other,
};

const Operator = enum(u16) {
    version = 0,
    notice = 1,
    full_name = 2,
    family_name = 3,
    weight = 4,
    font_bbox = 5,
    unique_id = 13,
    xuid = 14,
    charset = 15,
    encoding = 16,
    charstrings_offset = 17,
    private_dict_range = 18,
    variation_store_offset = 24,
    blue_values = 6,
    other_blues = 7,
    family_blues = 8,
    family_other_blues = 9,
    std_hw = 10,
    std_vw = 11,
    subrs_offset = 19,
    default_width_x = 20,
    nominal_width_x = 21,
    variation_store_index = 22,
    blend = 23,
    copyright = 12_0,
    is_fixed_pitch = 12_1,
    italic_angle = 12_2,
    underline_position = 12_3,
    underline_thickness = 12_4,
    paint_type = 12_5,
    charstring_type = 12_6,
    font_matrix = 12_7,
    stroke_width = 12_8,
    synthetic_base = 12_20,
    postscript = 12_21,
    base_font_name = 12_22,
    base_font_blend = 12_23,
    ros = 12_30,
    cid_font_version = 12_31,
    cid_font_revision = 12_32,
    cid_font_type = 12_33,
    cid_count = 12_34,
    uid_base = 12_35,
    fd_array_offset = 12_36,
    fd_select_offset = 12_37,
    font_name = 12_38,
    blue_scale = 12_9,
    blue_shift = 12_10,
    blue_fuzz = 12_11,
    stem_snap_h = 12_12,
    stem_snap_v = 12_13,
    force_bold = 12_14,
    language_group = 12_17,
    expansion_factor = 12_18,
    initial_random_seed = 12_19,
};

fn operatorFromOpcode(opcode: u8) ?Operator {
    return switch (opcode) {
        0 => .version,
        1 => .notice,
        2 => .full_name,
        3 => .family_name,
        4 => .weight,
        5 => .font_bbox,
        13 => .unique_id,
        14 => .xuid,
        15 => .charset,
        16 => .encoding,
        17 => .charstrings_offset,
        18 => .private_dict_range,
        24 => .variation_store_offset,
        6 => .blue_values,
        7 => .other_blues,
        8 => .family_blues,
        9 => .family_other_blues,
        10 => .std_hw,
        11 => .std_vw,
        19 => .subrs_offset,
        20 => .default_width_x,
        21 => .nominal_width_x,
        22 => .variation_store_index,
        23 => .blend,
        else => null,
    };
}

fn operatorFromExtended(opcode: u8) ?Operator {
    return switch (opcode) {
        0 => .copyright,
        1 => .is_fixed_pitch,
        2 => .italic_angle,
        3 => .underline_position,
        4 => .underline_thickness,
        5 => .paint_type,
        6 => .charstring_type,
        7 => .font_matrix,
        8 => .stroke_width,
        20 => .synthetic_base,
        21 => .postscript,
        22 => .base_font_name,
        23 => .base_font_blend,
        30 => .ros,
        31 => .cid_font_version,
        32 => .cid_font_revision,
        33 => .cid_font_type,
        34 => .cid_count,
        35 => .uid_base,
        36 => .fd_array_offset,
        37 => .fd_select_offset,
        38 => .font_name,
        9 => .blue_scale,
        10 => .blue_shift,
        11 => .blue_fuzz,
        12 => .stem_snap_h,
        13 => .stem_snap_v,
        14 => .force_bold,
        17 => .language_group,
        18 => .expansion_factor,
        19 => .initial_random_seed,
        else => null,
    };
}

const Token = union(enum) {
    operator: Operator,
    operand: i32,
    bcd: BcdComponents,
};

/// `read-fonts` `dict::tokens` + `dict::entries` in one streaming parser.
///
/// `blend` may be null when the DICT is not processed with a variation store;
/// `blend`/`vsindex` operators then fail with `error.MissingBlendState`
/// exactly where the upstream iterator yields an error.
pub const Dict = struct {
    data: []const u8,
    pos: usize = 0,
    stack: Stack = .{},
    last_bcd: ?BcdComponents = null,
    /// Cursor position after the last returned entry's operator, used by the
    /// FontMatrix reparse path.
    cursor_pos: usize = 0,
    blend: ?*BlendState = null,

    pub fn init(data: []const u8, blend: ?*BlendState) Dict {
        return .{ .data = data, .blend = blend };
    }

    fn readToken(self: *Dict) Error!?Token {
        while (true) {
            if (self.pos >= self.data.len) return null;
            const b0 = try readU8(self.data, &self.pos);
            if (b0 == 12) {
                const b1 = try readU8(self.data, &self.pos);
                if (operatorFromExtended(b1)) |op| return Token{ .operator = op };
                // Invalid DICT operator: clear the stack and continue, like
                // FreeType and read-fonts.
                self.stack.clear();
                continue;
            }
            switch (b0) {
                28, 29, 32...254 => return Token{ .operand = try parseInt(self.data, &self.pos, b0) },
                30 => {
                    const bcd = try BcdComponents.parse(self.data, &self.pos);
                    return Token{ .bcd = bcd };
                },
                else => {
                    if (operatorFromOpcode(b0)) |op| return Token{ .operator = op };
                    self.stack.clear();
                    continue;
                },
            }
        }
    }

    /// Next parsed entry, or null at end of DICT. Mirrors `entries()`'s
    /// iterator body including its `?`-on-`Option` early termination on
    /// malformed BlueScale values.
    pub fn next(self: *Dict) Error!?Entry {
        while (try self.readToken()) |token| {
            switch (token) {
                .operand => |value| {
                    try self.stack.pushI32(value);
                    self.last_bcd = null;
                    continue;
                },
                .bcd => |components| {
                    try self.stack.pushFixed(components.value(false));
                    self.last_bcd = components;
                    continue;
                },
                .operator => |op| {
                    if (op == .blend or op == .variation_store_index) {
                        const state = self.blend orelse return error.MissingBlendState;
                        if (op == .variation_store_index) {
                            const ix = try self.stack.getI32(0);
                            try state.setStoreIndex(@as(u16, @truncate(@as(u32, @bitCast(ix)))));
                        }
                        if (op == .blend) {
                            try state.applyBlend(&self.stack);
                            self.last_bcd = null;
                            continue;
                        }
                    }
                    if (op == .blue_scale) {
                        if (self.last_bcd) |components| {
                            self.last_bcd = null;
                            _ = self.stack.popFixed() catch return null;
                            self.stack.pushFixed(components.value(true)) catch return null;
                        }
                    }
                    if (op == .font_matrix) {
                        // Reparse the six operands with dynamic scaling. The
                        // main cursor is intentionally left untouched on both
                        // success and failure, matching read-fonts (the
                        // operands are then pushed by the next iterations).
                        self.stack.clear();
                        self.last_bcd = null;
                        const saved_pos = self.pos;
                        const parsed = ScaledFontMatrix.parse(self.data, &self.pos);
                        self.pos = saved_pos;
                        if (parsed) |matrix| return Entry{ .font_matrix = matrix };
                        continue;
                    }
                    self.last_bcd = null;
                    const entry = try self.parseEntry(op);
                    self.stack.clear();
                    self.cursor_pos = self.pos;
                    return entry;
                },
            }
        }
        return null;
    }

    fn parseEntry(self: *Dict, op: Operator) Error!Entry {
        const stack = &self.stack;
        return switch (op) {
            .charstrings_offset => .{ .charstrings_offset = asUsize(try stack.popI32()) },
            .fd_array_offset => .{ .fd_array_offset = asUsize(try stack.popI32()) },
            .fd_select_offset => .{ .fd_select_offset = asUsize(try stack.popI32()) },
            .private_dict_range => blk: {
                const len = asUsize(try stack.getI32(0));
                const start = asUsize(try stack.getI32(1));
                const end = std.math.add(usize, start, len) catch return error.OutOfBounds;
                break :blk .{ .private_dict_range = .{ .start = start, .end = end } };
            },
            .variation_store_offset => .{
                .variation_store_offset = asUsize(try stack.popI32()),
            },
            .charset => .{ .charset_offset = asUsize(try stack.popI32()) },
            .encoding => .{ .encoding_offset = asUsize(try stack.popI32()) },
            .subrs_offset => .{ .subrs_offset = asUsize(try stack.popI32()) },
            .default_width_x => .{ .default_width_x = try stack.popFixed() },
            .nominal_width_x => .{ .nominal_width_x = try stack.popFixed() },
            .variation_store_index => .{
                .variation_store_index = @truncate(@as(u32, @bitCast(try stack.popI32()))),
            },
            .ros => .ros,
            else => .other,
        };
    }
};

/// Rust `i32 as usize`: sign-extend into the pointer width.
fn asUsize(value: i32) usize {
    return @bitCast(@as(isize, value));
}

/// `skrifa::outline::cff::TopDict` subset.
pub const TopDict = struct {
    charstrings: Index = Index.empty_index,
    font_dicts: Index = Index.empty_index,
    fd_select: ?FdSelect = null,
    private_dict_start: u32 = 0,
    private_dict_end: u32 = 0,
    font_matrix: ?ScaledFontMatrix = null,
    var_store: ?variations.ItemVariationStore = null,
    charset_offset: ?usize = null,
    is_cid: bool = false,

    pub fn parse(table_data: []const u8, top_dict_data: []const u8, is_cff2: bool) Error!TopDict {
        var items = TopDict{};
        var dict = Dict.init(top_dict_data, null);
        while (try dict.next()) |entry| {
            switch (entry) {
                .charstrings_offset => |offset| {
                    items.charstrings = try Index.new(readOptional(table_data, offset), is_cff2);
                },
                .fd_array_offset => |offset| {
                    items.font_dicts = try Index.new(readOptional(table_data, offset), is_cff2);
                },
                .fd_select_offset => |offset| {
                    const data = readOptional(table_data, offset);
                    items.fd_select = try FdSelect.parse(data);
                },
                .private_dict_range => |range| {
                    // `as u32` truncation, as upstream.
                    items.private_dict_start = @truncate(range.start);
                    items.private_dict_end = @truncate(range.end);
                },
                .font_matrix => |matrix| {
                    items.font_matrix = matrix.normalize();
                },
                .variation_store_offset => |offset| {
                    if (is_cff2) {
                        // IVS is preceded by a 2-byte length; reject overflow.
                        const with_len = std.math.add(usize, offset, 2) catch
                            return error.OutOfBounds;
                        items.var_store = try variations.ItemVariationStore.parse(
                            readOptional(table_data, with_len),
                        );
                    }
                },
                .charset_offset => |offset| items.charset_offset = offset,
                else => {},
            }
        }
        return items;
    }
};

/// `table_data.get(offset..).unwrap_or_default()`.
pub fn sliceFrom(data: []const u8, offset: usize) []const u8 {
    if (offset > data.len) return &.{};
    return data[offset..];
}

/// Alias used by the outline scaler for private DICT subrs.
pub const readOptionalView = sliceFrom;

fn readOptional(data: []const u8, offset: usize) []const u8 {
    return sliceFrom(data, offset);
}

/// `skrifa::outline::cff::PrivateDict` subset (hint parameters omitted).
pub const PrivateDict = struct {
    subrs_offset: ?usize = null,
    store_index: u16 = 0,
    default_width: ?Fixed = null,
    nominal_width: Fixed = Fixed.zero,

    pub fn parse(data: []const u8, range: Range, blend: ?*BlendState) Error!PrivateDict {
        const private_data = readRange(data, range) orelse return error.OutOfBounds;
        var dict = PrivateDict{};
        var it = Dict.init(private_data, blend);
        while (try it.next()) |entry| {
            switch (entry) {
                .default_width_x => |width| dict.default_width = width.floor(),
                .nominal_width_x => |width| dict.nominal_width = width.floor(),
                .subrs_offset => |subrs| {
                    // "Subrs offset is relative to the private DICT".
                    dict.subrs_offset = std.math.add(usize, range.start, subrs) catch
                        return error.OutOfBounds;
                },
                .variation_store_index => |index| dict.store_index = index,
                else => {},
            }
        }
        return dict;
    }
};

/// `read-fonts` `FontDict` (private DICT range plus the unnormalized matrix).
pub const FontDict = struct {
    private_dict_range: Range,
    font_matrix: ?ScaledFontMatrix = null,

    pub fn parse(font_dict_data: []const u8) Error!FontDict {
        var range: ?Range = null;
        var font_matrix: ?ScaledFontMatrix = null;
        var dict = Dict.init(font_dict_data, null);
        while (try dict.next()) |entry| {
            switch (entry) {
                .private_dict_range => |r| range = r,
                .font_matrix => |matrix| font_matrix = matrix,
                else => {},
            }
        }
        return .{
            .private_dict_range = range orelse return error.MissingPrivateDict,
            .font_matrix = font_matrix,
        };
    }
};

/// `data.read_array(range)` (all-or-nothing).
fn readRange(data: []const u8, range: Range) ?[]const u8 {
    if (range.start > range.end or range.end > data.len) return null;
    return data[range.start..range.end];
}

// ------------------------------------------------------------------ charset

const expert_charset = [_]u16{
    0,   1,   229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 13,  14,
    15,  99,  239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 27,  28,
    249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262,
    263, 264, 265, 266, 109, 110, 267, 268, 269, 270, 271, 272, 273, 274,
    275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288,
    289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302,
    303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316,
    317, 318, 158, 155, 163, 319, 320, 321, 322, 323, 324, 325, 326, 150,
    164, 169, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338,
    339, 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352,
    353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366,
    367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378,
};

const expert_subset_charset = [_]u16{
    0,   1,   231, 232, 235, 236, 237, 238, 13,  14,  15,  99,  239, 240,
    241, 242, 243, 244, 245, 246, 247, 248, 27,  28,  249, 250, 251, 253,
    254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109,
    110, 267, 268, 269, 270, 272, 300, 301, 302, 305, 314, 315, 158, 155,
    163, 320, 321, 322, 323, 324, 325, 326, 150, 164, 169, 327, 328, 329,
    330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343,
    344, 345, 346,
};

pub const CharsetKind = enum { iso_adobe, expert, expert_subset, format0, format1, format2 };

/// `read-fonts` `ps::cff::charset::Charset`; only the SID -> GID direction is
/// implemented because `seac` is the only consumer.
pub const Charset = struct {
    data: []const u8 = &.{},
    kind: CharsetKind = .iso_adobe,
    num_glyphs: u32 = 0,
    /// Offset of the charset table itself inside `data`.
    offset: usize = 0,

    pub fn init(cff_data: []const u8, charset_offset: usize, num_glyphs: u32) Error!Charset {
        return switch (charset_offset) {
            0 => .{ .data = cff_data, .kind = .iso_adobe, .num_glyphs = num_glyphs },
            1 => .{ .data = cff_data, .kind = .expert, .num_glyphs = num_glyphs },
            2 => .{ .data = cff_data, .kind = .expert_subset, .num_glyphs = num_glyphs },
            else => blk: {
                if (charset_offset >= cff_data.len) return error.OutOfBounds;
                const format = cff_data[charset_offset];
                const kind: CharsetKind = switch (format) {
                    0 => .format0,
                    1 => .format1,
                    2 => .format2,
                    else => return error.InvalidFormat,
                };
                break :blk .{
                    .data = cff_data,
                    .kind = kind,
                    .num_glyphs = num_glyphs,
                    .offset = charset_offset,
                };
            },
        };
    }

    /// Predefined ISOAdobe fallback used by `seac` when the font has no
    /// charset (or is CID-keyed): `Charset::new(FontData::default(), 0, count)`.
    pub fn isoAdobe(num_glyphs: u32) Charset {
        return .{ .kind = .iso_adobe, .num_glyphs = num_glyphs };
    }

    /// `Charset::glyph_id`.
    pub fn glyphId(self: Charset, sid: u16) Error!u32 {
        switch (self.kind) {
            .iso_adobe => {
                if (sid <= 228) return @as(u32, sid);
                return error.OutOfBounds;
            },
            .expert => {
                for (expert_charset, 0..) |n, pos| {
                    if (n == sid) return @intCast(pos);
                }
                return error.OutOfBounds;
            },
            .expert_subset => {
                for (expert_subset_charset, 0..) |n, pos| {
                    if (n == sid) return @intCast(pos);
                }
                return error.OutOfBounds;
            },
            .format0 => {
                if (sid == 0) return 0;
                const count = self.rangeCount0();
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const value = sfnt.readU16(self.data, self.offset + 1 + i * 2) orelse
                        return error.OutOfBounds;
                    if (value == sid) return @intCast(i + 1);
                }
                return error.OutOfBounds;
            },
            .format1 => {
                const count = self.rangeCount1();
                var gid: u32 = 1;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const at = self.offset + 1 + i * 3;
                    const first = sfnt.readU16(self.data, at) orelse return error.OutOfBounds;
                    const n_left = self.data[at + 2];
                    if (first <= sid and sid <= @as(u32, first) + n_left) {
                        return gid + @as(u32, sid) - first;
                    }
                    gid += @as(u32, n_left) + 1;
                }
                return error.OutOfBounds;
            },
            .format2 => {
                const count = self.rangeCount2();
                var gid: u32 = 1;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const at = self.offset + 1 + i * 4;
                    const first = sfnt.readU16(self.data, at) orelse return error.OutOfBounds;
                    const n_left = sfnt.readU16(self.data, at + 2) orelse return error.OutOfBounds;
                    if (first <= sid and sid <= @as(u32, first) + n_left) {
                        return gid + @as(u32, sid) - first;
                    }
                    gid += @as(u32, n_left) + 1;
                }
                return error.OutOfBounds;
            },
        }
    }

    fn glyphOffset0(self: Charset, gid: u32) usize {
        return self.offset + 1 + @as(usize, gid - 1) * 2;
    }

    fn rangeCount0(self: Charset) u32 {
        const available = (self.data.len -| (self.offset + 1)) / 2;
        return @intCast(available);
    }

    fn rangeCount1(self: Charset) usize {
        const available = (self.data.len -| (self.offset + 1)) / 3;
        return available;
    }

    fn rangeCount2(self: Charset) usize {
        const available = (self.data.len -| (self.offset + 1)) / 4;
        return available;
    }
};

// ----------------------------------------------------------------- FDSelect

/// `read-fonts` `ps::cff::fd_select::FdSelect`.
pub const FdSelect = struct {
    data: []const u8,
    format: u8,

    pub fn parse(data: []const u8) Error!FdSelect {
        if (data.len < 1) return error.OutOfBounds;
        const format = data[0];
        switch (format) {
            0, 3, 4 => return .{ .data = data, .format = format },
            else => return error.InvalidFormat,
        }
    }

    /// `FdSelect::font_index`; a missing/empty table reads as 0.
    pub fn fontIndex(self: FdSelect, gid: u32) u16 {
        switch (self.format) {
            0 => {
                if (gid >= self.data.len - 1) return 0;
                return self.data[1 + gid];
            },
            3 => {
                const count = sfnt.readU16(self.data, 1) orelse return 0;
                if (count == 0) return 0;
                const gid16: u16 = @truncate(gid);
                var ix: usize = 0;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const first = sfnt.readU16(self.data, 3 + i * 3) orelse return 0;
                    if (first > gid16) break;
                    ix = i;
                }
                const fd = self.data[3 + ix * 3 + 2];
                return fd;
            },
            4 => {
                const count = sfnt.readU32(self.data, 1) orelse return 0;
                if (count == 0) return 0;
                var ix: usize = 0;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const first = sfnt.readU32(self.data, 5 + i * 6) orelse return 0;
                    if (first > gid) break;
                    ix = i;
                }
                return sfnt.readU16(self.data, 5 + ix * 6 + 4) orelse 0;
            },
            else => return 0,
        }
    }
};

// --------------------------------------------------------- standard encoding

/// `read-fonts` `ps::encoding::STANDARD_ENCODING` (character code -> SID).
pub const standard_encoding = [256]u8{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    1,   2,   3,   4,   5,   6,   7,   104, 9,   10,  11,  12,  13,  14,  15,  16,
    17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
    33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,
    49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
    65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,
    81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    1,   161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 14,  173, 174,
    175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206,
    207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222,
    223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238,
    239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254,
};

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "parse a CFF1 table's INDEXes" {
    // Build: header (4 bytes) + Name INDEX (1 object "Test") +
    // Top DICT INDEX (empty) + String INDEX (empty) + Global Subr INDEX
    // (empty, encoded as 0x0000 with the empty two-byte form).
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    buf[n] = 1;
    buf[n + 1] = 0;
    buf[n + 2] = 4;
    buf[n + 3] = 4;
    n += 4;
    // Name INDEX: count 1, off_size 1, offsets 1,5, data "Test"
    std.mem.writeInt(u16, buf[n..][0..2], 1, .big);
    n += 2;
    buf[n] = 1;
    n += 1;
    buf[n] = 1;
    buf[n + 1] = 5;
    n += 2;
    @memcpy(buf[n .. n + 4], "Test");
    n += 4;
    // Top DICT INDEX empty (two-byte form).
    std.mem.writeInt(u16, buf[n..][0..2], 0, .big);
    n += 2;
    // String/Global Subr INDEXes empty.
    std.mem.writeInt(u16, buf[n..][0..2], 0, .big);
    n += 2;
    std.mem.writeInt(u16, buf[n..][0..2], 0, .big);
    n += 2;
    const cff = try Cff.parse(buf[0..n]);
    try testing.expectEqual(@as(u32, 1), cff.names.count);
    try testing.expectEqualStrings("Test", try cff.names.get(0));
    try testing.expectEqual(@as(u32, 0), cff.top_dicts.count);
    try testing.expectEqual(@as(u32, 0), cff.global_subrs.count);
    try testing.expectEqual(@as(u8, 1), cff.major);
}

test "dict parses offsets, private range and subrs" {
    // 123 17 (CharstringsOffset), then len=10 start=20 18 (PrivateDictRange).
    const data = [_]u8{
        28, 0,  123, 17,
        28, 0,  10,  28,
        0,  20, 18,
    };
    var dict = Dict.init(&data, null);
    const first = (try dict.next()).?;
    try testing.expectEqual(@as(usize, 123), first.charstrings_offset);
    const second = (try dict.next()).?;
    try testing.expectEqual(@as(usize, 20), second.private_dict_range.start);
    try testing.expectEqual(@as(usize, 30), second.private_dict_range.end);
    try testing.expect((try dict.next()) == null);
}

test "decimal numbers match read-fonts' BCD examples" {
    // -2.25: e2 a2 5f
    var pos: usize = 0;
    const components = try BcdComponents.parse(&[_]u8{ 0xE2, 0xA2, 0x5F }, &pos);
    try testing.expectEqual(@as(i32, -147456), components.value(false).bits);
    // 0.140541E-3: 0a 14 05 41 c3 ff
    pos = 0;
    const small = try BcdComponents.parse(
        &[_]u8{ 0x0A, 0x14, 0x05, 0x41, 0xC3, 0xFF },
        &pos,
    );
    try testing.expectEqual(@as(i32, 9), small.value(false).bits);
    // 375e-4 -> 0.0370025634765625 (FreeType-matching less-precise parse)
    pos = 0;
    const rounded = try BcdComponents.parse(&[_]u8{ 0x37, 0x5C, 0x4F }, &pos);
    try testing.expectEqual(@as(i32, 2425), rounded.value(false).bits);
}

test "charset format 0 lookup" {
    // offset 0 is the predefined ISOAdobe charset's table start only for
    // offsets 0/1/2; use a custom table at offset 4.
    var buf = [_]u8{ 0, 0, 0, 0, 0, 0, 8, 0, 9, 0, 10 };
    const charset = try Charset.init(&buf, 4, 4);
    try testing.expectEqual(@as(u32, 0), try charset.glyphId(0));
    try testing.expectEqual(@as(u32, 1), try charset.glyphId(8));
    try testing.expectEqual(@as(u32, 3), try charset.glyphId(10));
    try testing.expectError(error.OutOfBounds, charset.glyphId(11));
    _ = &buf;
}

test "fdselect formats 0 and 3" {
    const format0 = [_]u8{ 0, 3, 1, 0, 2 };
    const fd0 = try FdSelect.parse(&format0);
    try testing.expectEqual(@as(u16, 3), fd0.fontIndex(0));
    try testing.expectEqual(@as(u16, 1), fd0.fontIndex(1));
    try testing.expectEqual(@as(u16, 2), fd0.fontIndex(3));

    var format3: [12]u8 = undefined;
    format3[0] = 3;
    std.mem.writeInt(u16, format3[1..3], 2, .big);
    std.mem.writeInt(u16, format3[3..5], 0, .big);
    format3[5] = 1;
    std.mem.writeInt(u16, format3[6..8], 2, .big);
    format3[8] = 4;
    std.mem.writeInt(u16, format3[9..11], 5, .big);
    const fd3 = try FdSelect.parse(&format3);
    try testing.expectEqual(@as(u16, 1), fd3.fontIndex(0));
    try testing.expectEqual(@as(u16, 1), fd3.fontIndex(1));
    try testing.expectEqual(@as(u16, 4), fd3.fontIndex(2));
    try testing.expectEqual(@as(u16, 4), fd3.fontIndex(4));
}

test "blend state applies region scalars to the stack" {
    // One-axis item variation store: region 0 = (-1, -0.5, 0), region 1 =
    // (-1, -1, 0), one item variation data subtable referencing both regions.
    var ivs: [38]u8 = undefined;
    std.mem.writeInt(u16, ivs[0..2], 1, .big); // format
    std.mem.writeInt(u32, ivs[2..6], 12, .big); // region list offset
    std.mem.writeInt(u16, ivs[6..8], 1, .big); // item variation data count
    std.mem.writeInt(u32, ivs[8..12], 28, .big); // subtable offset
    std.mem.writeInt(u16, ivs[12..14], 1, .big); // axis count
    std.mem.writeInt(u16, ivs[14..16], 2, .big); // region count
    std.mem.writeInt(i16, ivs[16..18], @bitCast(@as(u16, 0xC000)), .big);
    std.mem.writeInt(i16, ivs[18..20], @bitCast(@as(u16, 0xE000)), .big);
    std.mem.writeInt(i16, ivs[20..22], 0, .big);
    std.mem.writeInt(i16, ivs[22..24], @bitCast(@as(u16, 0xC000)), .big);
    std.mem.writeInt(i16, ivs[24..26], @bitCast(@as(u16, 0xC000)), .big);
    std.mem.writeInt(i16, ivs[26..28], 0, .big);
    std.mem.writeInt(u16, ivs[28..30], 1, .big); // item count
    std.mem.writeInt(u16, ivs[30..32], 0, .big); // word delta count
    std.mem.writeInt(u16, ivs[32..34], 2, .big); // region index count
    std.mem.writeInt(u16, ivs[34..36], 0, .big); // region 0
    std.mem.writeInt(u16, ivs[36..38], 1, .big); // region 1

    const store = try variations.ItemVariationStore.parse(&ivs);
    var blend = try BlendState.init(store, &.{@bitCast(@as(u16, 0xD000))}, 0);
    try testing.expectEqual(@as(usize, 2), try blend.regionCount());
    // region 0 scalar: (coord - start)/(peak - start) = 0.25/0.5 = 0.5
    // region 1 scalar: (end - coord)/(end - peak) = 0.75/1 = 0.75
    var stack = Stack{};
    try stack.pushI32(10);
    try stack.pushI32(20);
    try stack.pushI32(4);
    try stack.pushI32(-8);
    try stack.pushI32(-60);
    try stack.pushI32(2);
    try stack.pushI32(2); // target value count
    try blend.applyBlend(&stack);
    const values = try stack.fixedArray(2, 0);
    try testing.expectEqual(@as(i32, 6 << 16), values[0].bits);
    try testing.expectEqual(@as(i32, -557056), values[1].bits);
    try testing.expectEqual(@as(usize, 2), stack.len());
}
