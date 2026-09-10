//! First-pass port of Taffy's `style/compact_length.rs`.
//!
//! Taffy stores its tagged values in one pointer-sized word. This file keeps
//! every semantic tag as an explicit union while the literal port is being
//! validated. PORT STATUS: replace the representation with a packed `u64`
//! after bit-for-bit tests cover all constructors and keyword predicates.

pub const CompactLength = union(enum) {
    auto,
    length: f32,
    percent: f32,
    fr: f32,
    min_content,
    max_content,
    fit_content,
    fit_content_length: f32,
    fit_content_percent: f32,
    stretch,
    content,
    calc: *const anyopaque,

    pub fn tag(self: CompactLength) CompactLengthTag {
        return switch (self) {
            .auto => .auto,
            .length => .length,
            .percent => .percent,
            .fr => .fr,
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content => .fit_content_keyword,
            .fit_content_length => .fit_content_px,
            .fit_content_percent => .fit_content_percent,
            .stretch => .stretch,
            .content => .content,
            .calc => .calc,
        };
    }

    pub fn value(self: CompactLength) f32 {
        return numericValue(self);
    }

    pub fn is_zero(self: CompactLength) bool {
        return self == .{ .length = 0 };
    }
    pub fn is_length_or_percentage(self: CompactLength) bool {
        return self == .length or self == .percent;
    }
    pub fn is_auto(self: CompactLength) bool {
        return self == .auto;
    }
    pub fn is_content(self: CompactLength) bool {
        return self == .content;
    }
    pub fn is_min_content(self: CompactLength) bool {
        return self == .min_content;
    }
    pub fn is_max_content(self: CompactLength) bool {
        return self == .max_content;
    }
    pub fn is_fit_content(self: CompactLength) bool {
        return self == .fit_content_length or self == .fit_content_percent;
    }
    pub fn is_sizing_keyword(self: CompactLength) bool {
        return self.is_min_content() or self.is_max_content() or self == .fit_content or self.is_fit_content() or self == .stretch;
    }
    pub fn is_max_or_fit_content(self: CompactLength) bool {
        return self.is_max_content() or self.is_fit_content();
    }
    pub fn is_max_content_alike(self: CompactLength) bool {
        return self == .auto or self.is_max_content() or self.is_fit_content();
    }
    pub fn is_min_or_max_content(self: CompactLength) bool {
        return self.is_min_content() or self.is_max_content();
    }
    pub fn is_intrinsic(self: CompactLength) bool {
        return self == .auto or self.is_min_content() or self.is_max_content() or self.is_fit_content();
    }
    pub fn is_fr(self: CompactLength) bool {
        return self == .fr;
    }
    pub fn uses_percentage(self: CompactLength) bool {
        return self == .percent or self == .fit_content_percent or self == .calc;
    }

    pub fn is_calc(self: CompactLength) bool {
        return self == .calc;
    }
    pub fn calc_value(self: CompactLength) ?*const anyopaque {
        return switch (self) {
            .calc => |pointer| pointer,
            else => null,
        };
    }
    pub fn resolved_percentage_size(self: CompactLength, parent_size: f32) ?f32 {
        return switch (self) {
            .percent => |number| number * parent_size,
            .fit_content_percent => |number| number * parent_size,
            else => null,
        };
    }

    pub fn serialized(self: CompactLength) u64 {
        const tag_value: u64 = @backingInt(self.tag());
        const value_bits: u64 = switch (self) {
            .length => |number| @as(u64, @as(u32, @bitCast(number))),
            .percent => |number| @as(u64, @as(u32, @bitCast(number))),
            .fr => |number| @as(u64, @as(u32, @bitCast(number))),
            .fit_content_length => |number| @as(u64, @as(u32, @bitCast(number))),
            .fit_content_percent => |number| @as(u64, @as(u32, @bitCast(number))),
            else => 0,
        };
        // Taffy's 64-bit representation serializes as `(tag << 32) | bits`.
        // Keeping this exact wire layout makes semantic values round-trip
        // against the Rust implementation even though the in-memory Zig
        // representation remains a tagged union during the port.
        return (tag_value << 32) | value_bits;
    }
};

/// Taffy's inner compact representation is an implementation detail; keeping
/// the alias makes the type-level name available to ports that inspect it.
pub const CompactLengthInner = CompactLength;

pub const CompactLengthTag = enum(u8) {
    calc,
    length = 0b0000_0001,
    percent = 0b0000_0010,
    auto = 0b0000_0011,
    fr = 0b0000_0100,
    min_content = 0b0000_0111,
    max_content = 0b0000_1111,
    fit_content_px = 0b0001_0111,
    fit_content_percent = 0b0001_1111,
    fit_content_keyword = 0b0010_0111,
    stretch = 0b0010_1111,
    content = 0b0011_0111,
};

pub fn f32_to_bits(value: f32) u32 {
    return @bitCast(value);
}
pub fn f32_from_bits(value: u32) f32 {
    return @bitCast(value);
}

pub fn from_serialized(serialized: u64) CompactLength {
    const tag_value: u8 = @intCast(serialized >> 32);
    const value: f32 = f32_from_bits(@intCast(serialized & 0xffff_ffff));
    return switch (tag_value) {
        @backingInt(CompactLengthTag.length) => .{ .length = value },
        @backingInt(CompactLengthTag.percent) => .{ .percent = value },
        @backingInt(CompactLengthTag.fr) => .{ .fr = value },
        @backingInt(CompactLengthTag.fit_content_px) => .{ .fit_content_length = value },
        @backingInt(CompactLengthTag.fit_content_percent) => .{ .fit_content_percent = value },
        @backingInt(CompactLengthTag.auto) => .auto,
        @backingInt(CompactLengthTag.min_content) => .min_content,
        @backingInt(CompactLengthTag.max_content) => .max_content,
        @backingInt(CompactLengthTag.fit_content_keyword) => .fit_content,
        @backingInt(CompactLengthTag.stretch) => .stretch,
        @backingInt(CompactLengthTag.content) => .content,
        else => @panic("invalid serialized Taffy compact length"),
    };
}

pub fn compact_length_from_length(value: anytype) CompactLength {
    return .{ .length = @floatCast(value) };
}
pub fn compact_length_from_percent(value: anytype) CompactLength {
    return .{ .percent = @floatCast(value) };
}
pub fn compact_length_from_fr(value: anytype) CompactLength {
    return .{ .fr = @floatCast(value) };
}
pub fn compact_length_auto() CompactLength {
    return .auto;
}
pub fn compact_length_min_content() CompactLength {
    return .min_content;
}
pub fn compact_length_max_content() CompactLength {
    return .max_content;
}
pub fn compact_length_fit_content_px(value: f32) CompactLength {
    return .{ .fit_content_length = value };
}
pub fn compact_length_fit_content_percent(value: f32) CompactLength {
    return .{ .fit_content_percent = value };
}
pub fn compact_length_fit_content_keyword() CompactLength {
    return .fit_content;
}
pub fn compact_length_stretch() CompactLength {
    return .stretch;
}
pub fn compact_length_content() CompactLength {
    return .content;
}
pub fn compact_length_calc(value: *const anyopaque) CompactLength {
    return .{ .calc = value };
}

// Module-level spellings mirror Taffy's associated constructors. They avoid
// colliding with Zig union tag names while keeping call sites source-shaped.
pub fn from_length(value: anytype) CompactLength {
    return compact_length_from_length(value);
}
pub fn from_percent(value: anytype) CompactLength {
    return compact_length_from_percent(value);
}
pub fn from_fr(value: anytype) CompactLength {
    return compact_length_from_fr(value);
}
pub fn length(value: f32) CompactLength {
    return .{ .length = value };
}
pub fn percent(value: f32) CompactLength {
    return .{ .percent = value };
}
pub fn calc(value: *const anyopaque) CompactLength {
    return compact_length_calc(value);
}
pub fn auto() CompactLength {
    return .auto;
}
pub fn fr(value: f32) CompactLength {
    return .{ .fr = value };
}
pub fn min_content() CompactLength {
    return .min_content;
}
pub fn max_content() CompactLength {
    return .max_content;
}
pub fn fit_content_px(value: f32) CompactLength {
    return .{ .fit_content_length = value };
}
pub fn fit_content_percent(value: f32) CompactLength {
    return .{ .fit_content_percent = value };
}
pub fn fit_content_keyword() CompactLength {
    return .fit_content;
}
pub fn stretch() CompactLength {
    return .stretch;
}
pub fn content() CompactLength {
    return .content;
}

pub fn from_tag(tag: CompactLengthTag) CompactLength {
    return switch (tag) {
        .calc => @panic("calc compact length requires an opaque pointer"),
        .length => .{ .length = 0 },
        .percent => .{ .percent = 0 },
        .auto => .auto,
        .fr => .{ .fr = 0 },
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content_px => .{ .fit_content_length = 0 },
        .fit_content_percent => .{ .fit_content_percent = 0 },
        .fit_content_keyword => .fit_content,
        .stretch => .stretch,
        .content => .content,
    };
}

pub fn from_val(value: f32, tag: CompactLengthTag) CompactLength {
    return switch (tag) {
        .length => .{ .length = value },
        .percent => .{ .percent = value },
        .fr => .{ .fr = value },
        .fit_content_px => .{ .fit_content_length = value },
        .fit_content_percent => .{ .fit_content_percent = value },
        else => from_tag(tag),
    };
}

pub fn from_ptr(pointer: *const anyopaque, tag: CompactLengthTag) CompactLength {
    if (tag == .calc) return .{ .calc = pointer };
    return from_tag(tag);
}

pub fn ptr(value: CompactLength) ?*const anyopaque {
    return value.calc_value();
}
pub fn calc_tag(value: CompactLength) CompactLengthTag {
    return value.tag();
}
pub fn serialize(value: CompactLength) u64 {
    return value.serialized();
}
pub fn deserialize(value: u64) CompactLength {
    return from_serialized(value);
}

pub fn compact_length_fit_content(value: anytype) CompactLength {
    return switch (value.value) {
        .length => |number| .{ .fit_content_length = number },
        .percent => |number| .{ .fit_content_percent = number },
        else => @panic("Taffy fit-content requires a length or percentage"),
    };
}

pub fn fit_content(value: anytype) CompactLength {
    return compact_length_fit_content(value);
}

pub fn tag_ptr(value: CompactLength) ?*const anyopaque {
    return value.calc_value();
}

pub fn isAuto(value: CompactLength) bool {
    return value == .auto;
}

pub fn isDefinite(value: CompactLength) bool {
    return switch (value) {
        .length, .percent => true,
        else => false,
    };
}

pub fn numericValue(value: CompactLength) f32 {
    return switch (value) {
        .length => |number| number,
        .percent => |number| number,
        .fit_content_length => |number| number,
        .fit_content_percent => |number| number,
        .fr => |number| number,
        else => 0,
    };
}

pub fn isCalc(value: CompactLength) bool {
    return value == .calc;
}

test "compact length tags and serialized bits match Taffy wire values" {
    const testing = @import("std").testing;
    const length_value = CompactLength{ .length = 12.5 };
    try testing.expectEqual(@as(u8, 1), @backingInt(length_value.tag()));
    try testing.expectEqual(length_value, from_serialized(length_value.serialized()));
    try testing.expectEqual(@as(u8, 39), @backingInt((CompactLength{ .fit_content = {} }).tag()));
    const auto_value = CompactLength{ .auto = {} };
    try testing.expectEqual(auto_value, from_serialized(auto_value.serialized()));
}
