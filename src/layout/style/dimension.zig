//! Direct semantic port of Taffy's `style/dimension.rs`.

const available = @import("available_space.zig");
const compact = @import("compact_length.zig");
const std = @import("std");

pub const DimensionParseError = error{ InvalidDimension, InvalidNumber };

fn parse_numeric(input: []const u8) DimensionParseError!f32 {
    return std.fmt.parseFloat(f32, input) catch error.InvalidNumber;
}

fn trim_dimension_input(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

pub const LengthPercentage = struct {
    value: compact.CompactLength,

    pub fn from_length(value: anytype) LengthPercentage {
        return .{ .value = compact.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) LengthPercentage {
        return .{ .value = compact.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!LengthPercentage {
        const source = trim_dimension_input(input);
        if (std.mem.endsWith(u8, source, "%")) return LengthPercentage.percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return LengthPercentage.length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        return error.InvalidDimension;
    }

    pub fn length(value: f32) LengthPercentage {
        return .{ .value = .{ .length = value } };
    }

    pub fn percent(value: f32) LengthPercentage {
        return .{ .value = .{ .percent = value } };
    }

    pub fn resolve(self: LengthPercentage, basis: f32) f32 {
        return switch (self.value) {
            .length => |value| value,
            .percent => |value| value * basis,
            else => unreachable,
        };
    }

    pub fn resolve_to_option(self: LengthPercentage, basis: ?f32) ?f32 {
        return if (basis) |value| self.resolve(value) else null;
    }

    pub fn zero() LengthPercentage {
        return .{ .value = .{ .length = 0 } };
    }
    pub fn into_raw(self: LengthPercentage) compact.CompactLength {
        return self.value;
    }
    pub fn expand(self: LengthPercentage) ExpandedLengthPercentage {
        return switch (self.value) {
            .length => |v| .{ .length = v },
            .percent => |v| .{ .percent = v },
            else => unreachable,
        };
    }
};

pub const ExpandedLengthPercentage = union(enum) { length: f32, percent: f32 };

pub const LengthPercentageAuto = struct {
    value: compact.CompactLength,

    pub fn from_length(value: anytype) LengthPercentageAuto {
        return .{ .value = compact.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) LengthPercentageAuto {
        return .{ .value = compact.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!LengthPercentageAuto {
        const source = trim_dimension_input(input);
        if (std.ascii.eqlIgnoreCase(source, "auto")) return .auto();
        if (std.mem.endsWith(u8, source, "%")) return LengthPercentageAuto.percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return .length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        return error.InvalidDimension;
    }

    pub fn auto() LengthPercentageAuto {
        return .{ .value = .auto };
    }

    pub fn length(value: f32) LengthPercentageAuto {
        return .{ .value = .{ .length = value } };
    }

    pub fn percent(value: f32) LengthPercentageAuto {
        return .{ .value = .{ .percent = value } };
    }

    pub fn resolve(self: LengthPercentageAuto, basis: f32) ?f32 {
        return switch (self.value) {
            .auto => null,
            .length => |value| value,
            .percent => |value| value * basis,
            else => unreachable,
        };
    }

    pub fn resolve_to_option(self: LengthPercentageAuto, basis: ?f32) ?f32 {
        return if (basis) |value| self.resolve(value) else null;
    }

    pub fn zero() LengthPercentageAuto {
        return .{ .value = .{ .length = 0 } };
    }
    pub fn is_auto(self: LengthPercentageAuto) bool {
        return self.value == .auto;
    }
    pub fn into_raw(self: LengthPercentageAuto) compact.CompactLength {
        return self.value;
    }
    pub fn expand(self: LengthPercentageAuto) ExpandedLengthPercentageAuto {
        return switch (self.value) {
            .auto => .auto,
            .length => |v| .{ .length = v },
            .percent => |v| .{ .percent = v },
            else => unreachable,
        };
    }
};

pub const ExpandedLengthPercentageAuto = union(enum) { auto, length: f32, percent: f32 };

pub const Dimension = struct {
    value: compact.CompactLength,

    pub const auto: Dimension = .{ .value = .auto };
    pub const min_content: Dimension = .{ .value = .min_content };
    pub const max_content: Dimension = .{ .value = .max_content };
    pub const fit_content: Dimension = .{ .value = .fit_content };
    pub const stretch: Dimension = .{ .value = .stretch };
    pub const content: Dimension = .{ .value = .content };

    pub fn length(value: f32) Dimension {
        return .{ .value = .{ .length = value } };
    }

    pub fn from_length(value: anytype) Dimension {
        return .{ .value = compact.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) Dimension {
        return .{ .value = compact.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!Dimension {
        const source = trim_dimension_input(input);
        if (std.ascii.eqlIgnoreCase(source, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(source, "min-content")) return .min_content;
        if (std.ascii.eqlIgnoreCase(source, "max-content")) return .max_content;
        if (std.ascii.eqlIgnoreCase(source, "fit-content")) return .fit_content;
        if (std.ascii.eqlIgnoreCase(source, "stretch")) return .stretch;
        if (std.ascii.eqlIgnoreCase(source, "content")) return .content;
        if (std.mem.endsWith(u8, source, "%")) return .percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return .length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        if (std.mem.startsWith(u8, source, "fit-content(") and std.mem.endsWith(u8, source, ")")) {
            const inner = source[12 .. source.len - 1];
            if (std.mem.endsWith(u8, inner, "%")) return .fit_content_percent((parse_numeric(inner[0 .. inner.len - 1]) catch return error.InvalidNumber) / 100.0);
            if (std.mem.endsWith(u8, inner, "px")) return .fit_content_length(parse_numeric(inner[0 .. inner.len - 2]) catch return error.InvalidNumber);
        }
        return error.InvalidDimension;
    }
    pub fn calc(value: *const anyopaque) Dimension {
        return .{ .value = .{ .calc = value } };
    }
    pub fn from_raw(value: compact.CompactLength) Dimension {
        return .{ .value = value };
    }

    pub fn percent(value: f32) Dimension {
        return .{ .value = .{ .percent = value } };
    }

    pub fn fit_content_length(value: f32) Dimension {
        return .{ .value = .{ .fit_content_length = value } };
    }

    pub fn fit_content_px(value: f32) Dimension {
        return fit_content_length(value);
    }

    pub fn fit_content_percent(value: f32) Dimension {
        return .{ .value = .{ .fit_content_percent = value } };
    }

    pub fn resolve(self: Dimension, basis: ?f32) ?f32 {
        return switch (self.value) {
            .length => |value| value,
            .percent => |value| if (basis) |b| value * b else null,
            else => null,
        };
    }

    pub fn resolve_to_option(self: Dimension, basis: ?f32) ?f32 {
        return self.resolve(basis);
    }

    pub fn is_definite(self: Dimension) bool {
        return self.value == .length or self.value == .percent;
    }

    pub fn into_option(self: Dimension) ?f32 {
        return switch (self.value) {
            .length => |v| v,
            else => null,
        };
    }

    pub fn is_auto(self: Dimension) bool {
        return self.value == .auto;
    }
    pub fn is_sizing_keyword(self: Dimension) bool {
        return !self.is_definite() and !self.is_auto();
    }
    pub fn is_stretch(self: Dimension) bool {
        return self.value == .stretch;
    }
    pub fn is_content(self: Dimension) bool {
        return self.value == .content;
    }
    pub fn tag(self: Dimension) compact.CompactLengthTag {
        return self.value.tag();
    }
    pub fn numeric_value(self: Dimension) f32 {
        return self.value.numericValue();
    }

    pub fn calc_handle(self: Dimension) ?*const anyopaque {
        return switch (self.value) {
            .calc => |value| value,
            else => null,
        };
    }
    pub fn into_raw(self: Dimension) compact.CompactLength {
        return self.value;
    }
    pub fn expand(self: Dimension) ExpandedDimension {
        return switch (self.value) {
            .auto => .auto,
            .length => |v| .{ .length = v },
            .percent => |v| .{ .percent = v },
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content => .fit_content,
            .fit_content_length => |v| .{ .fit_content_length = v },
            .fit_content_percent => |v| .{ .fit_content_percent = v },
            .stretch => .stretch,
            .content => .content,
            .calc => .calc,
        };
    }
};

pub const ExpandedDimension = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,
    fit_content,
    fit_content_length: f32,
    fit_content_percent: f32,
    stretch,
    content,
    calc,
};

pub fn dimensionToAvailable(value: Dimension) available.AvailableSpace {
    return switch (value.value) {
        .min_content => .min_content,
        .max_content => .max_content,
        else => .max_content,
    };
}

pub fn dimension_value(value: Dimension) compact.CompactLength {
    return value.value;
}

pub fn clamp_resolved_size(value: f32, minimum: LengthPercentageAuto, maximum: LengthPercentageAuto, basis: f32) f32 {
    const min_value = minimum.resolve(basis) orelse 0;
    // An auto max is unbounded (infinity), never the value itself: using
    // the value here would swallow the min clamp whenever max is unset.
    const max_value = maximum.resolve(basis) orelse std.math.inf(f32);
    return @min(max_value, @max(min_value, value));
}

pub fn dimension_auto() Dimension {
    return Dimension.auto;
}
pub fn from(value: compact.CompactLength) Dimension {
    return Dimension.from_raw(value);
}
pub fn dimension_raw_value(value: Dimension) compact.CompactLength {
    return value.value;
}
pub fn min_content() Dimension {
    return Dimension.min_content;
}
pub fn max_content() Dimension {
    return Dimension.max_content;
}
pub fn fit_content() Dimension {
    return Dimension.fit_content;
}
pub fn stretch() Dimension {
    return Dimension.stretch;
}
pub fn content() Dimension {
    return Dimension.content;
}
pub fn dimension_min_content() Dimension {
    return Dimension.min_content;
}
pub fn dimension_max_content() Dimension {
    return Dimension.max_content;
}
pub fn dimension_fit_content() Dimension {
    return Dimension.fit_content;
}
pub fn dimension_stretch() Dimension {
    return Dimension.stretch;
}
pub fn dimension_content() Dimension {
    return Dimension.content;
}

pub fn rect_dimension_from_length(left: f32, right: f32, top: f32, bottom: f32) @import("../geometry.zig").Rect(Dimension) {
    return .{ .left = Dimension.length(left), .right = Dimension.length(right), .top = Dimension.length(top), .bottom = Dimension.length(bottom) };
}

pub fn rect_dimension_from_percent(left: f32, right: f32, top: f32, bottom: f32) @import("../geometry.zig").Rect(Dimension) {
    return .{ .left = Dimension.percent(left), .right = Dimension.percent(right), .top = Dimension.percent(top), .bottom = Dimension.percent(bottom) };
}

pub fn dimension_from_expanded(value: ExpandedDimension) Dimension {
    return switch (value) {
        .auto => Dimension.auto,
        .length => |number| Dimension.length(number),
        .percent => |number| Dimension.percent(number),
        .min_content => Dimension.min_content,
        .max_content => Dimension.max_content,
        .fit_content => Dimension.fit_content,
        .fit_content_length => |number| Dimension.fit_content_length(number),
        .fit_content_percent => |number| Dimension.fit_content_percent(number),
        .stretch => Dimension.stretch,
        .content => Dimension.content,
        .calc => @panic("calc dimension conversion requires an opaque handle"),
    };
}

test "dimension keeps keyword values distinct" {
    const testing = @import("std").testing;
    try testing.expect(Dimension.auto.value == .auto);
    try testing.expect((Dimension{ .value = .{ .length = 20 } }).is_definite());
    try testing.expect((Dimension{ .value = .{ .percent = 0.5 } }).resolve(null) == null);
    try testing.expect(Dimension.percent(0.5).into_option() == null);
    try testing.expectEqual(@as(?f32, 12), Dimension.length(12).into_option());
}

test "dimension CSS spellings preserve percentage and fit-content values" {
    const testing = @import("std").testing;
    const percent = try Dimension.from_str("50%");
    try testing.expectEqual(@as(f32, 0.5), percent.value.percent);
    const fit = try Dimension.from_str("fit-content(24px)");
    try testing.expectEqual(@as(f32, 24), fit.value.fit_content_length);
    try testing.expect((try LengthPercentageAuto.from_str("auto")).is_auto());
}
