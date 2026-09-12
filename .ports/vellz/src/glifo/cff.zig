//! CFF/CFF2 outline extraction, bit-exact with `skrifa 0.44.0`.
//!
//! Port of `skrifa/src/outline/cff/mod.rs` (the `Outlines`/`Subfont` scaler)
//! plus the Type2 charstring evaluator from `read-fonts 0.41.0`
//! (`src/ps/cs.rs`), the transform sinks (`TransformSink`, `NopFilterSink`)
//! and the operand stack. All coordinates stay in 16.16 `Fixed` until the pen
//! boundary; the f32 conversion is `Fixed::to_f32` and nothing else.
//!
//! Ported scope:
//!
//! - CFF (version 1) and CFF2 (`TopDict`, FDArray/FDSelect subfonts, global
//!   and local subrs);
//! - the full Type2 path/hint operator set, including the flex operators,
//!   `seac` (explicit and the implicit `endchar` form) and the CFF2
//!   `blend`/`vsindex` variation operators (item variation store scalars are
//!   ported in `tables/variations.zig`);
//! - `FontMatrix` handling (top DICT normalizes, Font DICTs stay raw and are
//!   combined exactly like `FreeType`/`read-fonts`);
//! - the private DICT width fallbacks (`defaultWidthX`/`nominalWidthX`, then
//!   `hmtx`) and `Transform::transform_h_metric`.
//!
//! Deferred with typed errors (never approximated):
//!
//! - CFF hinting (`skrifa`'s `cff/hint.rs`, 1.5k lines): an enabled
//!   `HintInstance` on a CFF face is `error.Unsupported`. An explicitly
//!   disabled instance still draws unhinted and rounds the advance, exactly
//!   like upstream;
//! - `HVAR` advance/lsb deltas: non-empty normalized coordinates on a face
//!   with `HVAR` are `error.Unsupported` (the outline blend itself is exact);
//! - CFF2 `seac`: the format has no charset; `error.Unsupported`.

const std = @import("std");

const raw = @import("tables/cff.zig");
const variations = @import("tables/variations.zig");
const fixed = @import("fixed.zig");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const sfnt = @import("tables/sfnt.zig");

pub const Font = font_mod.Font;
pub const NormalizedCoord = font_mod.NormalizedCoord;
pub const GlyphId = font_mod.GlyphId;
pub const Fixed = fixed.Fixed;

/// The shared `glyf`/CFF draw types (`glifo`'s `OutlinePen` boundary types).
pub const DrawError = glyf.DrawError || error{
    InvalidNumber,
    InvalidDictOperator,
    InvalidCharstringOperator,
    InvalidIndexOffsetSize,
    ZeroOffsetInIndex,
    InvalidFormat,
    MissingBlendState,
    MissingPrivateDict,
    InvalidVariationStoreIndex,
    StackUnderflow,
    StackOverflow,
    ExpectedI32StackEntry,
    MissingCharset,
    InvalidSeacCode,
    CharstringNestingDepthLimitExceeded,
};
pub const DrawSettings = glyf.DrawSettings;
pub const AdjustedMetrics = glyf.AdjustedMetrics;
pub const PathStyle = glyf.PathStyle;
pub const HintInstance = glyf.HintInstance;

/// `read-fonts` `cs::NESTING_DEPTH_LIMIT`.
pub const nesting_depth_limit: u32 = 10;

const one_over_64: Fixed = .{ .bits = 0x400 };

fn shiftLeft10(value: i32) i32 {
    return @bitCast(@as(u32, @bitCast(value)) << 10);
}

fn shiftLeft16(value: i32) i32 {
    return @bitCast(@as(u32, @bitCast(value)) << 16);
}

// ------------------------------------------------------------- charstrings

const Operator = enum {
    hstem,
    vstem,
    vmove_to,
    rline_to,
    hline_to,
    vline_to,
    rr_curve_to,
    call_subr,
    return_,
    hsbw,
    end_char,
    variation_store_index,
    blend,
    hstem_hm,
    hint_mask,
    cntr_mask,
    rmove_to,
    hmove_to,
    vstem_hm,
    rcurveline,
    rlinecurve,
    vvcurveto,
    hhcurveto,
    call_gsubr,
    vhcurveto,
    hvcurveto,
    dot_section,
    vstem3,
    hstem3,
    seac,
    sbw,
    div,
    call_other_subr,
    pop,
    set_current_point,
    hflex,
    flex,
    hflex1,
    flex1,

    fn fromOpcode(opcode: u8) ?Operator {
        return switch (opcode) {
            1 => .hstem,
            3 => .vstem,
            4 => .vmove_to,
            5 => .rline_to,
            6 => .hline_to,
            7 => .vline_to,
            8 => .rr_curve_to,
            10 => .call_subr,
            11 => .return_,
            13 => .hsbw,
            14 => .end_char,
            15 => .variation_store_index,
            16 => .blend,
            18 => .hstem_hm,
            19 => .hint_mask,
            20 => .cntr_mask,
            21 => .rmove_to,
            22 => .hmove_to,
            23 => .vstem_hm,
            24 => .rcurveline,
            25 => .rlinecurve,
            26 => .vvcurveto,
            27 => .hhcurveto,
            29 => .call_gsubr,
            30 => .vhcurveto,
            31 => .hvcurveto,
            else => null,
        };
    }

    fn fromTwoByte(opcode: u8) ?Operator {
        return switch (opcode) {
            0 => .dot_section,
            1 => .vstem3,
            2 => .hstem3,
            6 => .seac,
            7 => .sbw,
            12 => .div,
            16 => .call_other_subr,
            17 => .pop,
            33 => .set_current_point,
            34 => .hflex,
            35 => .flex,
            36 => .hflex1,
            37 => .flex1,
            else => null,
        };
    }
};

const PointMode = union(enum) {
    dx_dy,
    x_dy,
    dx_y,
    dx_initial_y,
    d_larger_coord_dist,
    dx_maybe_dy: bool,
    maybe_dx_dy: bool,
};

const SeacMode = enum { explicit, implicit };

/// Charstring evaluation context; mirrors `read-fonts`' `CharstringContext`
/// tuple `(cff_blob, charstrings, global_subrs, subrs)` plus the charset
/// lookup `seac` needs.
const Context = struct {
    /// Parsed charset, or null for the ISOAdobe fallback (also used by CFF2,
    /// where `seac` is rejected before the lookup).
    charset: ?raw.Charset,
    /// The charset table failed to parse; `seac` must report the error.
    charset_invalid: bool,
    charstrings: raw.Index,
    global_subrs: raw.Index,
    subrs: raw.Index,
    glyph_count: u32,

    fn seacComponents(self: *const Context, base_code: i32, accent_code: i32) DrawError![2][]const u8 {
        if (self.charset_invalid) return error.OutOfBounds;
        const charset = self.charset orelse raw.Charset.isoAdobe(self.glyph_count);
        const base_gid = try seacToGid(charset, base_code);
        const accent_gid = try seacToGid(charset, accent_code);
        const base = self.charstrings.get(base_gid) catch return error.InvalidSeacCode;
        const accent = self.charstrings.get(accent_gid) catch return error.InvalidSeacCode;
        return .{ base, accent };
    }

    fn seacToGid(charset: raw.Charset, code: i32) DrawError!usize {
        if (code < 0 or code > 255) return error.InvalidSeacCode;
        const sid = raw.standard_encoding[@intCast(code)];
        return charset.glyphId(sid) catch error.InvalidSeacCode;
    }

    fn globalSubr(self: *const Context, index: i32) DrawError![]const u8 {
        return subrAt(self.global_subrs, index);
    }

    fn subr(self: *const Context, index: i32) DrawError![]const u8 {
        return subrAt(self.subrs, index);
    }

    fn subrAt(index: raw.Index, operator: i32) DrawError![]const u8 {
        const biased = @as(i64, operator) + index.subrBias();
        if (biased < 0) return error.OutOfBounds;
        return try index.get(@intCast(biased));
    }
};

/// `read-fonts` `cs::Evaluator`; comptime-generic over the command sink.
fn Evaluator(comptime Sink: type) type {
    return struct {
        const Self = @This();

        context: *const Context,
        blend_state: ?*raw.BlendState,
        sink: *Sink,
        is_open: bool = false,
        is_flexing: bool = false,
        seen_width_command: bool = false,
        have_read_width: bool = false,
        stem_count: usize = 0,
        x: Fixed = Fixed.zero,
        y: Fixed = Fixed.zero,
        sbx: Fixed = Fixed.zero,
        wx: Fixed = Fixed.zero,
        stack: raw.Stack = .{},
        stack_ix: usize = 0,
        in_seac: bool = false,

        /// `cs::evaluate`: run the charstring, simulate `endchar` when the
        /// program falls off the end (FreeType behavior) and close the open
        /// contour.
        fn evaluate(self: *Self, charstring_data: []const u8) DrawError!?Fixed {
            const seen_endchar = try self.evaluateImpl(charstring_data, 0);
            if (!seen_endchar) {
                var pos: usize = 0;
                _ = try self.evaluateOperator(.end_char, &.{}, &pos, 0);
            }
            if (self.is_open) try self.sink.close();
            try self.sink.finish();
            return if (self.have_read_width) self.wx else null;
        }

        fn evaluateImpl(self: *Self, charstring_data: []const u8, nesting_depth: u32) DrawError!bool {
            if (nesting_depth > nesting_depth_limit) {
                return error.CharstringNestingDepthLimitExceeded;
            }
            var pos: usize = 0;
            var seen_endchar = false;
            while (pos < charstring_data.len) {
                const b0 = try raw.readU8(charstring_data, &pos);
                switch (b0) {
                    28, 32...254 => {
                        try self.stack.pushI32(try raw.parseInt(charstring_data, &pos, b0));
                    },
                    255 => {
                        try self.stack.pushFixed(
                            Fixed.fromBits(try raw.readI32At(charstring_data, &pos)),
                        );
                    },
                    else => {
                        // Unknown operators clear the stack and evaluation
                        // continues (FreeType).
                        const operator = readOperator(charstring_data, &pos, b0) catch {
                            self.resetStack();
                            continue;
                        };
                        seen_endchar = seen_endchar or operator == .end_char;
                        if (!try self.evaluateOperator(operator, charstring_data, &pos, nesting_depth)) {
                            break;
                        }
                    },
                }
            }
            return seen_endchar;
        }

        fn readOperator(data: []const u8, pos: *usize, b0: u8) DrawError!Operator {
            if (b0 == 12) {
                const b1 = try raw.readU8(data, pos);
                return Operator.fromTwoByte(b1) orelse error.InvalidCharstringOperator;
            }
            return Operator.fromOpcode(b0) orelse error.InvalidCharstringOperator;
        }

        fn evaluateOperator(
            self: *Self,
            operator: Operator,
            data: []const u8,
            pos: *usize,
            nesting_depth: u32,
        ) DrawError!bool {
            switch (operator) {
                .flex => {
                    try self.emitCurves(&[_]PointMode{
                        .dx_dy, .dx_dy, .dx_dy, .dx_dy, .dx_dy, .dx_dy,
                    });
                    self.resetStack();
                },
                .hflex => {
                    try self.emitCurves(&[_]PointMode{
                        .dx_y, .dx_dy, .dx_y, .dx_y, .dx_initial_y, .dx_dy,
                    });
                    self.resetStack();
                },
                .hflex1 => {
                    try self.emitCurves(&[_]PointMode{
                        .dx_dy, .dx_dy, .dx_y, .dx_y, .dx_dy, .dx_initial_y,
                    });
                    self.resetStack();
                },
                .flex1 => {
                    try self.emitCurves(&[_]PointMode{
                        .dx_dy, .dx_dy, .dx_dy, .dx_dy, .dx_dy, .d_larger_coord_dist,
                    });
                    self.resetStack();
                },
                .variation_store_index => {
                    const state = self.blend_state orelse return error.MissingBlendState;
                    const store_index = @as(u16, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                    try state.setStoreIndex(store_index);
                },
                .blend => {
                    const state = self.blend_state orelse return error.MissingBlendState;
                    try state.applyBlend(&self.stack);
                },
                .return_ => return false,
                .end_char => {
                    const stack_len = self.stack.len();
                    if ((stack_len == 1 or stack_len == 5) and !self.seen_width_command) {
                        try self.readWidth();
                    }
                    self.seen_width_command = true;
                    if (stack_len > 1) {
                        try self.handleSeac(.implicit, nesting_depth);
                    }
                    return false;
                },
                .hstem, .vstem, .hstem_hm, .vstem_hm => {
                    var i: usize = 0;
                    const len = if (self.stack.lenIsOdd() and !self.seen_width_command) blk: {
                        try self.readWidth();
                        i = 1;
                        break :blk self.stack.len() - 1;
                    } else self.stack.len();
                    self.seen_width_command = true;
                    const is_horizontal = operator == .hstem or operator == .hstem_hm;
                    var u = Fixed.zero;
                    while (i < self.stack.len()) : (i += 2) {
                        const args = try self.stack.fixedArray(2, i);
                        u = Fixed.add(u, args[0]);
                        const w = args[1];
                        const v = Fixed.add(u, w);
                        if (is_horizontal) try self.sink.hstem(u, v) else try self.sink.vstem(u, v);
                        u = v;
                    }
                    self.stem_count += len / 2;
                    self.resetStack();
                },
                .hint_mask, .cntr_mask => {
                    var i: usize = 0;
                    const len = if (self.stack.lenIsOdd() and !self.seen_width_command) blk: {
                        try self.readWidth();
                        i = 1;
                        break :blk self.stack.len() - 1;
                    } else self.stack.len();
                    self.seen_width_command = true;
                    var u = Fixed.zero;
                    while (i < self.stack.len()) : (i += 2) {
                        const args = try self.stack.fixedArray(2, i);
                        u = Fixed.add(u, args[0]);
                        const w = args[1];
                        const v = Fixed.add(u, w);
                        try self.sink.vstem(u, v);
                        u = v;
                    }
                    self.stem_count += len / 2;
                    const count = (self.stem_count + 7) / 8;
                    if (pos.* + count > data.len) return error.OutOfBounds;
                    const mask = data[pos.* .. pos.* + count];
                    pos.* += count;
                    if (operator == .hint_mask) {
                        try self.sink.hintMask(mask);
                    } else {
                        try self.sink.counterMask(mask);
                    }
                    self.resetStack();
                },
                .rmove_to => {
                    if (self.stack.len() > 2 and !self.seen_width_command) {
                        try self.readWidth();
                    }
                    self.seen_width_command = true;
                    if (!self.is_flexing) {
                        const dy = try self.stack.popFixed();
                        const dx = try self.stack.popFixed();
                        self.x = Fixed.add(self.x, dx);
                        self.y = Fixed.add(self.y, dy);
                        if (!self.is_open) {
                            self.is_open = true;
                        } else {
                            try self.sink.close();
                        }
                        try self.sink.moveTo(self.x, self.y);
                        self.resetStack();
                    }
                },
                .hmove_to, .vmove_to => {
                    if (self.stack.len() > 1 and !self.seen_width_command) {
                        try self.readWidth();
                    }
                    self.seen_width_command = true;
                    if (self.is_flexing) {
                        try self.stack.pushI32(0);
                        if (operator == .vmove_to) try self.stack.exch();
                    } else {
                        const delta = try self.stack.popFixed();
                        if (operator == .hmove_to) {
                            self.x = Fixed.add(self.x, delta);
                        } else {
                            self.y = Fixed.add(self.y, delta);
                        }
                        if (!self.is_open) {
                            self.is_open = true;
                        } else {
                            try self.sink.close();
                        }
                        try self.sink.moveTo(self.x, self.y);
                        self.resetStack();
                    }
                },
                .rline_to => {
                    var i: usize = 0;
                    while (i < self.stack.len()) : (i += 2) {
                        const args = try self.stack.fixedArray(2, i);
                        self.x = Fixed.add(self.x, args[0]);
                        self.y = Fixed.add(self.y, args[1]);
                        try self.emitLine(self.x, self.y);
                    }
                    self.resetStack();
                },
                .hline_to, .vline_to => {
                    var is_x = operator == .hline_to;
                    var i: usize = 0;
                    while (i < self.stack.len()) : (i += 1) {
                        const delta = try self.stack.getFixed(i);
                        if (is_x) {
                            self.x = Fixed.add(self.x, delta);
                        } else {
                            self.y = Fixed.add(self.y, delta);
                        }
                        is_x = !is_x;
                        try self.emitLine(self.x, self.y);
                    }
                    self.resetStack();
                },
                .hhcurveto => {
                    const count1 = self.stack.len();
                    const count = count1 & ~@as(usize, 2);
                    self.stack_ix = count1 - count;
                    while (self.stack_ix < count) {
                        if ((count - self.stack_ix) & 1 != 0) {
                            self.y = Fixed.add(self.y, try self.stack.getFixed(self.stack_ix));
                            self.stack_ix += 1;
                        }
                        try self.emitCurves(&[_]PointMode{ .dx_y, .dx_dy, .dx_y });
                    }
                    self.resetStack();
                },
                .hvcurveto, .vhcurveto => {
                    const count1 = self.stack.len();
                    const count = count1 & ~@as(usize, 2);
                    var is_horizontal = operator == .hvcurveto;
                    self.stack_ix = count1 - count;
                    while (self.stack_ix < count) {
                        const do_last_delta = count - self.stack_ix == 5;
                        if (is_horizontal) {
                            try self.emitCurves(&[_]PointMode{
                                .dx_y, .dx_dy, .{ .maybe_dx_dy = do_last_delta },
                            });
                        } else {
                            try self.emitCurves(&[_]PointMode{
                                .x_dy, .dx_dy, .{ .dx_maybe_dy = do_last_delta },
                            });
                        }
                        is_horizontal = !is_horizontal;
                    }
                    self.resetStack();
                },
                .rr_curve_to, .rcurveline => {
                    while (self.coordsRemaining() >= 6) {
                        try self.emitCurves(&[_]PointMode{ .dx_dy, .dx_dy, .dx_dy });
                    }
                    if (operator == .rcurveline) {
                        const args = try self.stack.fixedArray(2, self.stack_ix);
                        self.x = Fixed.add(self.x, args[0]);
                        self.y = Fixed.add(self.y, args[1]);
                        try self.emitLine(self.x, self.y);
                    }
                    self.resetStack();
                },
                .rlinecurve => {
                    while (self.coordsRemaining() > 6) {
                        const args = try self.stack.fixedArray(2, self.stack_ix);
                        self.x = Fixed.add(self.x, args[0]);
                        self.y = Fixed.add(self.y, args[1]);
                        try self.emitLine(self.x, self.y);
                        self.stack_ix += 2;
                    }
                    while (self.coordsRemaining() >= 6) {
                        try self.emitCurves(&[_]PointMode{ .dx_dy, .dx_dy, .dx_dy });
                    }
                    self.resetStack();
                },
                .vvcurveto => {
                    const count1 = self.stack.len();
                    const count = count1 & ~@as(usize, 2);
                    self.stack_ix = count1 - count;
                    while (self.stack_ix < count) {
                        if ((count - self.stack_ix) & 1 != 0) {
                            self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix));
                            self.stack_ix += 1;
                        }
                        try self.emitCurves(&[_]PointMode{ .x_dy, .dx_dy, .x_dy });
                    }
                    self.resetStack();
                },
                .call_subr, .call_gsubr => {
                    const index = try self.stack.popI32();
                    const subr_charstring = if (operator == .call_subr)
                        try self.context.subr(index)
                    else
                        try self.context.globalSubr(index);
                    _ = try self.evaluateImpl(subr_charstring, nesting_depth + 1);
                },
                .hsbw => {
                    // Type1 only; `is_type1` is always false for CFF.
                },
                .seac => {
                    try self.handleSeac(.explicit, nesting_depth);
                },
                .sbw => {},
                .dot_section => {},
                .hstem3, .vstem3 => {
                    self.resetStack();
                },
                .div => {
                    try self.stack.div(false);
                },
                .call_other_subr => {
                    const subr_idx = try self.stack.popI32();
                    const num_args: usize = @intCast(@max(try self.stack.popI32(), 0));
                    switch (subr_idx) {
                        0 => {
                            if (num_args == 3) {
                                self.is_flexing = false;
                                try self.ensureOpen();
                                try self.handleFlex();
                            }
                        },
                        1 => {
                            if (num_args == 0) self.is_flexing = true;
                        },
                        12, 13 => self.resetStack(),
                        else => self.stack.drop(num_args),
                    }
                },
                .pop => {},
                .set_current_point => {},
            }
            return true;
        }

        fn readWidth(self: *Self) DrawError!void {
            self.wx = try self.stack.getFixed(0);
            self.seen_width_command = true;
            self.have_read_width = true;
        }

        /// `endchar`'s implied/explicit `seac`.
        fn handleSeac(self: *Self, mode: SeacMode, nesting_depth: u32) DrawError!void {
            if (self.in_seac) return error.CharstringNestingDepthLimitExceeded;
            self.in_seac = true;
            const accent_code = try self.stack.popI32();
            const base_code = try self.stack.popI32();
            const components = try self.context.seacComponents(base_code, accent_code);
            const dy = try self.stack.popFixed();
            const dx = try self.stack.popFixed();
            const sb: Fixed = blk: {
                if (!self.stack.is_empty() and !self.seen_width_command) {
                    self.wx = try self.stack.popFixed();
                    self.seen_width_command = true;
                }
                break :blk Fixed.zero;
            };
            var sbx = self.sbx;
            var wx = self.wx;
            const seen_width = self.seen_width_command;
            const read_width = self.have_read_width;
            const x = self.x;
            const y = self.y;
            const bx: Fixed = if (mode == .explicit) Fixed.zero else x;
            const by: Fixed = if (mode == .explicit) Fixed.zero else y;
            const comps = [2]struct {
                charstring: []const u8,
                x: Fixed,
                y: Fixed,
                maybe_use_metrics: bool,
            }{
                .{
                    .charstring = components[0],
                    .x = bx,
                    .y = by,
                    .maybe_use_metrics = mode == .explicit,
                },
                .{
                    .charstring = components[1],
                    // Adjustments only for Type1; zero for Type2 anyway.
                    .x = Fixed.sub(Fixed.add(dx, sbx), sb),
                    .y = dy,
                    .maybe_use_metrics = false,
                },
            };
            // FreeType evaluates accent first for implicit seac but base first
            // for explicit, so swap when implicit.
            const ordered = if (mode == .implicit)
                [2]@TypeOf(comps[0]){ comps[1], comps[0] }
            else
                comps;
            for (ordered) |component| {
                self.resetStack();
                self.seen_width_command = false;
                try self.sink.clearHints();
                self.stem_count = 0;
                self.x = component.x;
                self.y = component.y;
                _ = try self.evaluateImpl(component.charstring, nesting_depth + 1);
                if (component.maybe_use_metrics and !seen_width) {
                    sbx = self.sbx;
                    wx = self.wx;
                }
            }
            self.seen_width_command = seen_width;
            self.have_read_width = read_width;
            self.sbx = sbx;
            self.wx = wx;
            self.in_seac = false;
        }

        /// Emit the two curves accumulated by a Type1-style flex.
        fn handleFlex(self: *Self) DrawError!void {
            const final_y = try self.stack.popFixed();
            const final_x = try self.stack.popFixed();
            _ = try self.stack.popFixed(); // flex height, unused
            const p3y = try self.stack.popFixed();
            const p3x = try self.stack.popFixed();
            const bcp4y = try self.stack.popFixed();
            const bcp4x = try self.stack.popFixed();
            const bcp3y = try self.stack.popFixed();
            const bcp3x = try self.stack.popFixed();
            const p2y = try self.stack.popFixed();
            const p2x = try self.stack.popFixed();
            const bcp2y = try self.stack.popFixed();
            const bcp2x = try self.stack.popFixed();
            const bcp1y = try self.stack.popFixed();
            const bcp1x = try self.stack.popFixed();
            const rpy = try self.stack.popFixed();
            const rpx = try self.stack.popFixed();
            self.resetStack();
            try self.stack.pushFixed(Fixed.add(bcp1x, rpx));
            try self.stack.pushFixed(Fixed.add(bcp1y, rpy));
            try self.stack.pushFixed(bcp2x);
            try self.stack.pushFixed(bcp2y);
            try self.stack.pushFixed(p2x);
            try self.stack.pushFixed(p2y);
            try self.emitCurves(&[_]PointMode{ .dx_dy, .dx_dy, .dx_dy });
            self.resetStack();
            try self.stack.pushFixed(bcp3x);
            try self.stack.pushFixed(bcp3y);
            try self.stack.pushFixed(bcp4x);
            try self.stack.pushFixed(bcp4y);
            try self.stack.pushFixed(p3x);
            try self.stack.pushFixed(p3y);
            try self.emitCurves(&[_]PointMode{ .dx_dy, .dx_dy, .dx_dy });
            self.resetStack();
            try self.stack.pushFixed(final_x);
            try self.stack.pushFixed(final_y);
        }

        fn coordsRemaining(self: *const Self) usize {
            return self.stack.len() -| self.stack_ix;
        }

        fn ensureOpen(self: *Self) DrawError!void {
            if (!self.is_open) {
                try self.sink.moveTo(Fixed.zero, Fixed.zero);
                self.is_open = true;
            }
        }

        fn emitLine(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            try self.ensureOpen();
            try self.sink.lineTo(x, y);
        }

        fn emitCurves(self: *Self, modes: []const PointMode) DrawError!void {
            const initial_x = self.x;
            const initial_y = self.y;
            var count: usize = 0;
            var points = [2]struct { x: Fixed, y: Fixed }{
                .{ .x = Fixed.zero, .y = Fixed.zero },
                .{ .x = Fixed.zero, .y = Fixed.zero },
            };
            try self.ensureOpen();
            for (modes) |mode| {
                const stack_used: usize = switch (mode) {
                    .dx_dy => blk: {
                        self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix));
                        self.y = Fixed.add(self.y, try self.stack.getFixed(self.stack_ix + 1));
                        break :blk 2;
                    },
                    .x_dy => blk: {
                        self.y = Fixed.add(self.y, try self.stack.getFixed(self.stack_ix));
                        break :blk 1;
                    },
                    .dx_y => blk: {
                        self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix));
                        break :blk 1;
                    },
                    .dx_initial_y => blk: {
                        self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix));
                        self.y = initial_y;
                        break :blk 1;
                    },
                    .d_larger_coord_dist => blk: {
                        const delta = try self.stack.getFixed(self.stack_ix);
                        if (Fixed.sub(self.x, initial_x).abs().bits >
                            Fixed.sub(self.y, initial_y).abs().bits)
                        {
                            self.x = Fixed.add(self.x, delta);
                            self.y = initial_y;
                        } else {
                            self.y = Fixed.add(self.y, delta);
                            self.x = initial_x;
                        }
                        break :blk 1;
                    },
                    .dx_maybe_dy => |do_dy| blk: {
                        self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix));
                        if (do_dy) {
                            self.y = Fixed.add(self.y, try self.stack.getFixed(self.stack_ix + 1));
                            break :blk 2;
                        }
                        break :blk 1;
                    },
                    .maybe_dx_dy => |do_dx| blk: {
                        self.y = Fixed.add(self.y, try self.stack.getFixed(self.stack_ix));
                        if (do_dx) {
                            self.x = Fixed.add(self.x, try self.stack.getFixed(self.stack_ix + 1));
                            break :blk 2;
                        }
                        break :blk 1;
                    },
                };
                self.stack_ix += stack_used;
                if (count == 2) {
                    try self.sink.curveTo(
                        points[0].x,
                        points[0].y,
                        points[1].x,
                        points[1].y,
                        self.x,
                        self.y,
                    );
                    count = 0;
                } else {
                    points[count] = .{ .x = self.x, .y = self.y };
                    count += 1;
                }
            }
        }

        fn resetStack(self: *Self) void {
            self.stack.clear();
            self.stack_ix = 0;
        }
    };
}

// ------------------------------------------------------------------- sinks

/// `cs::PenSink`: `Fixed` -> f32 at the `OutlinePen` boundary.
fn PenSink(comptime P: type) type {
    return struct {
        const Self = @This();
        pen: *P,

        pub fn hstem(self: *Self, y: Fixed, dy: Fixed) DrawError!void {
            _ = self;
            _ = y;
            _ = dy;
        }
        pub fn vstem(self: *Self, x: Fixed, dx: Fixed) DrawError!void {
            _ = self;
            _ = x;
            _ = dx;
        }
        pub fn hintMask(self: *Self, mask: []const u8) DrawError!void {
            _ = self;
            _ = mask;
        }
        pub fn counterMask(self: *Self, mask: []const u8) DrawError!void {
            _ = self;
            _ = mask;
        }
        pub fn clearHints(self: *Self) DrawError!void {
            _ = self;
        }
        pub fn finish(self: *Self) DrawError!void {
            _ = self;
        }
        pub fn moveTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            try self.pen.moveTo(x.toF32(), y.toF32());
        }
        pub fn lineTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            try self.pen.lineTo(x.toF32(), y.toF32());
        }
        pub fn curveTo(
            self: *Self,
            cx0: Fixed,
            cy0: Fixed,
            cx1: Fixed,
            cy1: Fixed,
            x: Fixed,
            y: Fixed,
        ) DrawError!void {
            try self.pen.curveTo(
                cx0.toF32(),
                cy0.toF32(),
                cx1.toF32(),
                cy1.toF32(),
                x.toF32(),
                y.toF32(),
            );
        }
        pub fn close(self: *Self) DrawError!void {
            try self.pen.close();
        }
    };
}

/// `cs::NopFilterSink`: suppresses degenerate moves and zero-length lines.
fn NopFilterSink(comptime S: type) type {
    return struct {
        const Self = @This();
        const PendingElement = union(enum) {
            move: [2]Fixed,
            line: [2]Fixed,
            curve: [6]Fixed,

            fn targetPoint(self: PendingElement) [2]Fixed {
                return switch (self) {
                    .move => |xy| xy,
                    .line => |xy| xy,
                    .curve => |c| .{ c[4], c[5] },
                };
            }
        };

        is_open: bool = false,
        start: ?[2]Fixed = null,
        pending_element: ?PendingElement = null,
        inner: *S,

        fn flushPending(self: *Self, for_close: bool) DrawError!void {
            if (self.pending_element) |pending| {
                self.pending_element = null;
                switch (pending) {
                    .move => |xy| {
                        if (!for_close) {
                            self.is_open = true;
                            try self.inner.moveTo(xy[0], xy[1]);
                            self.start = xy;
                        }
                    },
                    .line => |xy| {
                        const same = if (self.start) |start|
                            start[0].bits == xy[0].bits and start[1].bits == xy[1].bits
                        else
                            false;
                        if (!for_close or !same) {
                            try self.inner.lineTo(xy[0], xy[1]);
                        }
                    },
                    .curve => |c| try self.inner.curveTo(c[0], c[1], c[2], c[3], c[4], c[5]),
                }
            }
        }

        pub fn hstem(self: *Self, y: Fixed, dy: Fixed) DrawError!void {
            try self.inner.hstem(y, dy);
        }
        pub fn vstem(self: *Self, x: Fixed, dx: Fixed) DrawError!void {
            try self.inner.vstem(x, dx);
        }
        pub fn hintMask(self: *Self, mask: []const u8) DrawError!void {
            try self.inner.hintMask(mask);
        }
        pub fn counterMask(self: *Self, mask: []const u8) DrawError!void {
            try self.inner.counterMask(mask);
        }
        pub fn clearHints(self: *Self) DrawError!void {
            try self.inner.clearHints();
        }
        pub fn moveTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            self.pending_element = .{ .move = .{ x, y } };
        }
        pub fn lineTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            if (self.pending_element) |pending| {
                const target = pending.targetPoint();
                if (target[0].bits == x.bits and target[1].bits == y.bits) return;
            }
            try self.flushPending(false);
            self.pending_element = .{ .line = .{ x, y } };
        }
        pub fn curveTo(
            self: *Self,
            cx1: Fixed,
            cy1: Fixed,
            cx2: Fixed,
            cy2: Fixed,
            x: Fixed,
            y: Fixed,
        ) DrawError!void {
            try self.flushPending(false);
            self.pending_element = .{ .curve = .{ cx1, cy1, cx2, cy2, x, y } };
        }
        pub fn close(self: *Self) DrawError!void {
            try self.flushPending(true);
            if (self.is_open) {
                try self.inner.close();
                self.is_open = false;
            }
        }
        pub fn finish(self: *Self) DrawError!void {
            try self.close();
            try self.inner.finish();
        }
    };
}

/// `cs::TransformSink`: FreeType's scale dance (multiply by 1/64, truncate
/// the low 10 bits, apply the matrix, then scale back to 16.16).
fn TransformSink(comptime S: type) type {
    return struct {
        const Self = @This();
        inner: *S,
        matrix: ?raw.FontMatrix,
        scale: ?Fixed,

        fn transform(self: *const Self, x: Fixed, y: Fixed) struct { x: Fixed, y: Fixed } {
            const ax = Fixed.mul(x, one_over_64);
            const ay = Fixed.mul(y, one_over_64);
            const bx = Fixed.fromBits(ax.bits >> 10);
            const by = Fixed.fromBits(ay.bits >> 10);
            var cx = bx;
            var cy = by;
            if (self.matrix) |matrix| {
                const t = matrix.transform(bx, by);
                cx = t.x;
                cy = t.y;
            }
            if (self.scale) |scale| {
                const dx = Fixed.mul(cx, scale);
                const dy = Fixed.mul(cy, scale);
                return .{ .x = Fixed.fromBits(shiftLeft10(dx.bits)), .y = Fixed.fromBits(shiftLeft10(dy.bits)) };
            }
            return .{ .x = Fixed.fromBits(shiftLeft16(cx.bits)), .y = Fixed.fromBits(shiftLeft16(cy.bits)) };
        }

        pub fn hstem(self: *Self, y: Fixed, dy: Fixed) DrawError!void {
            try self.inner.hstem(y, dy);
        }
        pub fn vstem(self: *Self, x: Fixed, dx: Fixed) DrawError!void {
            try self.inner.vstem(x, dx);
        }
        pub fn hintMask(self: *Self, mask: []const u8) DrawError!void {
            try self.inner.hintMask(mask);
        }
        pub fn counterMask(self: *Self, mask: []const u8) DrawError!void {
            try self.inner.counterMask(mask);
        }
        pub fn clearHints(self: *Self) DrawError!void {
            try self.inner.clearHints();
        }
        pub fn moveTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            const t = self.transform(x, y);
            try self.inner.moveTo(t.x, t.y);
        }
        pub fn lineTo(self: *Self, x: Fixed, y: Fixed) DrawError!void {
            const t = self.transform(x, y);
            try self.inner.lineTo(t.x, t.y);
        }
        pub fn curveTo(
            self: *Self,
            cx1: Fixed,
            cy1: Fixed,
            cx2: Fixed,
            cy2: Fixed,
            x: Fixed,
            y: Fixed,
        ) DrawError!void {
            const t0 = self.transform(cx1, cy1);
            const t1 = self.transform(cx2, cy2);
            const t2 = self.transform(x, y);
            try self.inner.curveTo(t0.x, t0.y, t1.x, t1.y, t2.x, t2.y);
        }
        pub fn close(self: *Self) DrawError!void {
            try self.inner.close();
        }
        pub fn finish(self: *Self) DrawError!void {
            try self.inner.finish();
        }
    };
}

// ------------------------------------------------------------------ subfont

/// `skrifa::outline::cff::Subfont` (hint state omitted).
pub const Subfont = struct {
    is_cff2: bool,
    scale: ?Fixed,
    scale_requested: bool,
    subrs_offset: ?usize,
    store_index: u16,
    font_matrix: ?raw.FontMatrix,
    default_width: ?Fixed,
    nominal_width: Fixed,
};

/// The CFF/CFF2 scaler for one face.
pub const Outlines = struct {
    font: Font,
    /// CFF or CFF2 table bytes.
    data: []const u8,
    version: u16,
    upem: u16,
    cff: raw.Cff = .{},
    cff2: raw.Cff2 = .{},
    top: raw.TopDict = .{},
    global_subrs: raw.Index = raw.Index.empty_index,
    glyph_count: u32,
    /// Precomputed charset for `seac`; null is the ISOAdobe fallback.
    charset: ?raw.Charset = null,
    /// `Cff::charset(0)` failed to parse; `seac` must report the error.
    charset_invalid: bool = false,
    /// The face carries `HVAR`; non-empty coordinates then need its deltas.
    has_hvar: bool = false,

    pub fn init(font: Font, data: []const u8) DrawError!Outlines {
        if (data.len == 0) return error.Truncated;
        const major = data[0];
        var outlines = Outlines{
            .font = font,
            .data = data,
            .version = if (major == 2) 2 else 1,
            .upem = font.unitsPerEm(),
            .glyph_count = font.numGlyphs(),
            .has_hvar = font.face.table(sfnt.tag_hvar) != null,
        };
        if (major == 2) {
            outlines.cff2 = try raw.Cff2.parse(data);
            outlines.top = try raw.TopDict.parse(data, outlines.cff2.top_dict_data, true);
            outlines.global_subrs = outlines.cff2.global_subrs;
        } else {
            outlines.cff = try raw.Cff.parse(data);
            const top_dict_data = try outlines.cff.top_dicts.get(0);
            outlines.top = try raw.TopDict.parse(data, top_dict_data, false);
            outlines.global_subrs = outlines.cff.global_subrs;
            if (outlines.top.charset_offset) |offset| {
                if (!outlines.top.is_cid) {
                    if (raw.Charset.init(data, offset, outlines.top.charstrings.count)) |charset| {
                        outlines.charset = charset;
                    } else |_| {
                        outlines.charset_invalid = true;
                    }
                }
            }
        }
        outlines.glyph_count = outlines.top.charstrings.count;
        return outlines;
    }

    pub fn glyphCount(self: *const Outlines) usize {
        return self.top.charstrings.count;
    }

    pub fn unitsPerEm(self: *const Outlines) u16 {
        return self.upem;
    }

    /// `skrifa::outline::cff::Outlines::subfont_index`.
    pub fn subfontIndex(self: *const Outlines, gid: GlyphId) u32 {
        if (self.top.fd_select) |fd_select| {
            return fd_select.fontIndex(gid);
        }
        return 0;
    }

    fn subfont(self: *const Outlines, index: u32, size: ?f32, coords: []const NormalizedCoord) DrawError!Subfont {
        var private_range = raw.Range{
            .start = self.top.private_dict_start,
            .end = self.top.private_dict_end,
        };
        var font_dict_matrix: ?raw.ScaledFontMatrix = null;
        if (self.top.font_dicts.count != 0) {
            const font_dict_data = try self.top.font_dicts.get(index);
            const font_dict = try raw.FontDict.parse(font_dict_data);
            private_range = font_dict.private_dict_range;
            font_dict_matrix = font_dict.font_matrix;
        }
        // `BlendState::new(store, coords, 0).transpose()?`.
        var blend: ?raw.BlendState = null;
        if (self.top.var_store) |store| {
            blend = try raw.BlendState.init(store, coords, 0);
        }
        const private_dict = try raw.PrivateDict.parse(
            self.data,
            private_range,
            if (blend) |*state| state else null,
        );
        const upem: i32 = self.upem;
        var scale: ?Fixed = null;
        if (size) |ppem| {
            if (upem > 0) {
                scale = Fixed.fromBits(fixed.saturatingF32ToI32(ppem * 64.0)).div(
                    Fixed.fromBits(upem),
                );
            }
        }
        const scale_requested = size != null;
        // Font matrix handling, mirroring FreeType/skrifa exactly.
        var resolved: ?raw.ScaledFontMatrix = null;
        if (self.top.font_matrix) |top_matrix| {
            if (font_dict_matrix) |sub_matrix| {
                const scaling: i32 = if (top_matrix.scale > 1 and sub_matrix.scale > 1)
                    @min(top_matrix.scale, sub_matrix.scale)
                else
                    1;
                const matrix = raw.combineScaled(top_matrix.matrix, sub_matrix.matrix, scaling);
                const upem_scaled = Fixed.fromBits(sub_matrix.scale).mulDiv(
                    Fixed.fromBits(top_matrix.scale),
                    Fixed.fromBits(scaling),
                );
                resolved = (raw.ScaledFontMatrix{
                    .matrix = matrix,
                    .scale = upem_scaled.bits,
                }).normalize();
            } else {
                resolved = top_matrix;
            }
        } else if (font_dict_matrix) |sub_matrix| {
            resolved = sub_matrix.normalize();
        }
        var font_matrix: ?raw.FontMatrix = null;
        if (resolved) |matrix| {
            if (matrix.scale != upem) {
                const original_scale = scale orelse Fixed.fromI32(64);
                scale = original_scale.mulDiv(
                    Fixed.fromBits(upem),
                    Fixed.fromBits(matrix.scale),
                );
            }
            font_matrix = matrix.matrix;
        }
        if (font_matrix) |matrix| {
            if (matrixEqual(matrix, raw.FontMatrix.identity)) font_matrix = null;
        }
        return .{
            .is_cff2 = self.version == 2,
            .scale = scale,
            .scale_requested = scale_requested,
            .subrs_offset = private_dict.subrs_offset,
            .store_index = private_dict.store_index,
            .font_matrix = font_matrix,
            .default_width = private_dict.default_width,
            .nominal_width = private_dict.nominal_width,
        };
    }

    fn subrs(self: *const Outlines, subfont_value: Subfont) DrawError!raw.Index {
        if (subfont_value.subrs_offset) |offset| {
            return raw.Index.new(raw.readOptionalView(self.data, offset), subfont_value.is_cff2);
        }
        return raw.Index.empty_index;
    }

    /// `skrifa::outline::cff::Outlines::draw`: evaluate one glyph into `pen`
    /// and return its adjusted metrics.
    pub fn draw(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        gid: GlyphId,
        settings: DrawSettings,
        pen: anytype,
    ) DrawError!AdjustedMetrics {
        _ = allocator;
        // CFF output is cubic regardless of `PathStyle`; upstream ignores the
        // setting for CFF, so a HarfBuzz request is exact here too.
        // `HVAR` deltas are not ported: a non-empty location would change the
        // advance width, so reject it instead of approximating.
        if (settings.coords.len != 0 and self.has_hvar) return error.Unsupported;

        var size = settings.size;
        var round_advance = false;
        if (settings.hint_instance) |instance| {
            if (instance.isEnabled()) {
                // CFF hinting (skrifa `cff/hint.rs`) is not ported.
                return error.Unsupported;
            }
            // Upstream's disabled-instance path draws unhinted at the
            // instance's size and rounds the advance.
            size = instance.size;
            round_advance = true;
        }

        const subfont_index = self.subfontIndex(gid);
        const subfont_value = try self.subfont(subfont_index, size, settings.coords);
        const charstrings = self.top.charstrings;
        const charstring_data = try charstrings.get(gid);
        const subrs_index = try self.subrs(subfont_value);
        var blend: ?raw.BlendState = null;
        if (self.top.var_store) |store| {
            blend = raw.BlendState.init(store, settings.coords, subfont_value.store_index) catch null;
        }
        const context = Context{
            .charset = if (self.charset_invalid) null else self.charset,
            .charset_invalid = self.charset_invalid,
            .charstrings = charstrings,
            .global_subrs = self.global_subrs,
            .subrs = subrs_index,
            .glyph_count = self.glyph_count,
        };

        var pen_sink = PenSink(@TypeOf(pen.*)){ .pen = pen };
        var nop_sink = NopFilterSink(@TypeOf(pen_sink)){ .inner = &pen_sink };
        var matrix_sink = TransformSink(@TypeOf(nop_sink)){
            .inner = &nop_sink,
            .matrix = subfont_value.font_matrix,
            .scale = subfont_value.scale,
        };
        var evaluator = Evaluator(@TypeOf(matrix_sink)){
            .context = &context,
            .blend_state = if (blend) |*state| state else null,
            .sink = &matrix_sink,
        };
        const maybe_width = try evaluator.evaluate(charstring_data);

        const width = if (maybe_width) |w|
            Fixed.add(w, subfont_value.nominal_width)
        else if (subfont_value.default_width) |default_width|
            default_width
        else
            Fixed.fromI32(self.font.advanceWidth(gid));
        const transformed = transformHMetric(width, subfont_value.font_matrix, subfont_value.scale);
        const advance_f32 = if (round_advance) transformed.round().toF32() else transformed.toF32();
        const advance: ?f32 = if (advance_f32 >= 0.0) advance_f32 else null;
        return .{
            .has_overlaps = false,
            .lsb = null,
            .advance_width = advance,
        };
    }
};

fn matrixEqual(a: raw.FontMatrix, b: raw.FontMatrix) bool {
    for (a.elements, b.elements) |x, y| {
        if (x.bits != y.bits) return false;
    }
    return true;
}

/// `read_fonts::ps::transform::Transform::transform_h_metric`.
fn transformHMetric(metric: Fixed, matrix: ?raw.FontMatrix, scale: ?Fixed) Fixed {
    var value = Fixed.fromBits(metric.toI32());
    const m = matrix orelse raw.FontMatrix.identity;
    if (m.elements[0].bits != Fixed.one.bits) {
        value = Fixed.mul(value, m.elements[0]);
    }
    value = Fixed.add(value, m.elements[4]);
    if (scale) |s| {
        return Fixed.fromBits(shiftLeft10(Fixed.mul(value, s).bits));
    }
    return Fixed.fromBits(shiftLeft16(value.bits));
}

/// `seac` needs a charset; the CFF2 deferral is documented in the module docs.
pub fn seacSupported(outlines: *const Outlines) bool {
    return outlines.version == 1 and !outlines.charset_invalid;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const fixture = @import("test_fixture.zig");

test "static CFF face draws a non-empty outline" {
    const font = try Font.init(try fixture.sourceSerif(), 0);
    const outlines = try font.outlines();
    var pen = @import("pen.zig").PathElementPen.init(testing.allocator);
    defer pen.deinit();
    const metrics = try outlines.draw(testing.allocator, 36, .{ .size = 16.0 }, &pen);
    try testing.expect(pen.elements.items.len > 0);
    try testing.expect(metrics.lsb == null);
    try testing.expect(metrics.advance_width != null);
    try testing.expect(!metrics.has_overlaps);
}

test "CFF advances at the default size match the font units" {
    const font = try Font.init(try fixture.sourceSerif(), 0);
    const outlines = try font.outlines();
    var pen = @import("pen.zig").PathElementPen.init(testing.allocator);
    defer pen.deinit();
    // Unscaled draw (size null) keeps font units: `nominalWidthX` fallback is
    // 603 for this face, but hmtx takes precedence when the charstring has no
    // width.
    _ = try outlines.draw(testing.allocator, 36, .{}, &pen);
    try testing.expectEqual(@as(u32, 1464), @as(u32, @intCast(outlines.glyphCount())));
}

test "CFF hinting and non-default HVAR coordinates are typed errors" {
    const font = try Font.init(try fixture.sourceSerifVariable(), 0);
    const outlines = try font.outlines();
    var pen = @import("pen.zig").PathElementPen.init(testing.allocator);
    defer pen.deinit();
    // The variable face carries HVAR, so non-empty coords are rejected.
    try testing.expectError(
        error.Unsupported,
        outlines.draw(testing.allocator, 36, .{ .size = 16.0, .coords = &.{0} }, &pen),
    );
}
