//! Font description types from GPUI's `text_system.rs` / `font_features.rs`.

const std = @import("std");

pub const SharedString = []const u8;

/// The degree of blackness or stroke thickness of a font (CSS-style 100..900).
pub const FontWeight = struct {
    value: f32 = 400.0,

    pub const THIN: FontWeight = .{ .value = 100.0 };
    pub const EXTRA_LIGHT: FontWeight = .{ .value = 200.0 };
    pub const LIGHT: FontWeight = .{ .value = 300.0 };
    pub const NORMAL: FontWeight = .{ .value = 400.0 };
    pub const MEDIUM: FontWeight = .{ .value = 500.0 };
    pub const SEMIBOLD: FontWeight = .{ .value = 600.0 };
    pub const BOLD: FontWeight = .{ .value = 700.0 };
    pub const EXTRA_BOLD: FontWeight = .{ .value = 800.0 };
    pub const BLACK: FontWeight = .{ .value = 900.0 };
    pub const ALL = [_]FontWeight{ THIN, EXTRA_LIGHT, LIGHT, NORMAL, MEDIUM, SEMIBOLD, BOLD, EXTRA_BOLD, BLACK };

    pub fn eql(a: FontWeight, b: FontWeight) bool {
        return a.value == b.value;
    }
};

/// Allows italic or oblique faces to be selected.
pub const FontStyle = enum { normal, italic, oblique };

/// OpenType font features, e.g. `calt`, `liga`, `ss01`.
pub const FontFeatures = struct {
    /// `(tag, value)` pairs.
    features: []const FontFeature = &.{},

    pub fn disable_ligatures() FontFeatures {
        return .{ .features = &.{ .{ .tag = "calt".*, .value = 0 }, .{ .tag = "liga".*, .value = 0 } } };
    }
    pub fn tag_value_list(self: FontFeatures) []const FontFeature {
        return self.features;
    }
    pub fn is_calt_enabled(self: FontFeatures) ?bool {
        for (self.features) |f| if (std.mem.eql(u8, &f.tag, "calt")) return f.value == 1;
        return null;
    }
    pub fn eql(a: FontFeatures, b: FontFeatures) bool {
        if (a.features.len != b.features.len) return false;
        for (a.features, b.features) |x, y| if (!std.mem.eql(u8, &x.tag, &y.tag) or x.value != y.value) return false;
        return true;
    }
};

pub const FontFeature = struct { tag: [4]u8, value: u32 };

/// An ordered list of fallback font families.
pub const FontFallbacks = struct {
    families: []const SharedString = &.{},

    pub fn from_fonts(fonts: []const SharedString) FontFallbacks {
        return .{ .families = fonts };
    }
    pub fn fallback_list(self: FontFallbacks) []const SharedString {
        return self.families;
    }
};

/// A font: family name plus selection attributes.
pub const Font = struct {
    family: SharedString = ".SystemUIFont",
    features: FontFeatures = .{},
    fallbacks: ?FontFallbacks = null,
    weight: FontWeight = .NORMAL,
    style: FontStyle = .normal,

    pub fn bold(self: Font) Font {
        var f = self;
        f.weight = .BOLD;
        return f;
    }
    pub fn italic(self: Font) Font {
        var f = self;
        f.style = .italic;
        return f;
    }
    pub fn eql(a: Font, b: Font) bool {
        return std.mem.eql(u8, a.family, b.family) and a.weight.eql(b.weight) and a.style == b.style and a.features.eql(b.features);
    }
    pub fn hash(self: Font, h: *std.hash.Wyhash) void {
        h.update(self.family);
        h.update(std.mem.asBytes(&self.weight.value));
        h.update(std.mem.asBytes(&self.style));
        for (self.features.features) |f| {
            h.update(&f.tag);
            h.update(std.mem.asBytes(&f.value));
        }
    }
};

/// Construct a font with the given family (GPUI `font(family)`).
pub fn font(family: SharedString) Font {
    return .{ .family = family };
}
