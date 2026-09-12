//! Script/style classification for the autohinter.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/style.rs` plus the generated
//! script/style/range tables (`styles_data.zig`, transcribed from
//! `generated/generated_autohint_styles.rs`). A [`GlyphStyleMap`] assigns
//! each glyph a style class from GSUB coverage, the character map ranges
//! below, script coverage and finally the fixed Hani fallback.

const std = @import("std");
const bz = @import("blue_zones.zig");
const data = @import("styles_data.zig");
const shaper_mod = @import("shaper.zig");

pub const BlueZones = bz.BlueZones;

/// Group that defines how glyphs belonging to a script are hinted.
pub const ScriptGroup = enum(u8) {
    /// All scripts that are not CJK or Indic (FreeType's "Latin").
    default = 0,
    cjk = 1,
    indic = 2,
    _,
};

pub const ScriptClass = struct {
    /// The name of the script class.
    name: []const u8,
    /// Group that defines how glyphs belonging to this script are hinted.
    group: ScriptGroup,
    /// Unicode tag for the script.
    tag: [4]u8,
    /// True if outline edges are processed top to bottom.
    hint_top_to_bottom: bool,
    /// Characters used to define standard width and height of stems.
    std_chars: []const u8,
    /// "Blue" characters used to define alignment zones.
    blues: []const bz.BluePair,
};

/// Defines the basic properties for each style supported by the autohinter.
pub const StyleClass = struct {
    /// The name of the style class.
    name: []const u8,
    /// Index of self in the `STYLE_CLASSES` array.
    index: u16,
    /// Associated Unicode script.
    script: *const ScriptClass,
    /// OpenType feature tag for styles that derive coverage from layout
    /// tables.
    feature: ?[4]u8,
};

/// Associates a basic glyph style with a range of codepoints.
pub const StyleRange = struct {
    first: u32,
    last: u32,
    style: GlyphStyle,

    pub fn contains(self: StyleRange, ch: u32) bool {
        return ch >= self.first and ch <= self.last;
    }
};

/// Defines the script and style associated with a single glyph.
///
/// The flags correspond to FreeType's per-glyph style bits but with skrifa's
/// different packing (see upstream `GlyphStyle`).
pub const GlyphStyle = struct {
    bits: u16 = unassigned,

    pub const style_index_mask: u16 = 0xFF;
    pub const unassigned: u16 = style_index_mask;
    /// A non-base character, commonly a mark.
    pub const non_base: u16 = 0x100;
    pub const digit: u16 = 0x200;
    /// Intermediate state marking an appearance as GSUB output.
    pub const from_gsub_output: u16 = 0x8000;

    pub fn fromRawParts(style_index: u16, is_non_base: bool, is_digit: bool) GlyphStyle {
        var bits = style_index & style_index_mask;
        if (is_non_base) bits |= non_base;
        if (is_digit) bits |= digit;
        return .{ .bits = bits };
    }

    pub fn isUnassigned(self: GlyphStyle) bool {
        return self.bits & style_index_mask == unassigned;
    }

    pub fn isNonBase(self: GlyphStyle) bool {
        return self.bits & non_base != 0;
    }

    pub fn isDigit(self: GlyphStyle) bool {
        return self.bits & digit != 0;
    }

    pub fn styleIndex(self: GlyphStyle) ?u16 {
        const ix = self.bits & style_index_mask;
        return if (ix != unassigned) ix else null;
    }

    pub fn styleClass(self: GlyphStyle) ?*const StyleClass {
        return fromIndex(self.styleIndex() orelse return null);
    }

    pub fn fromIndex(index: u16) ?*const StyleClass {
        if (index < STYLE_CLASSES.len) return &STYLE_CLASSES[index];
        return null;
    }

    /// FreeType walks the style array in order so earlier styles have
    /// precedence. This keeps the extra bits while replacing the style
    /// index when the candidate has a lower-or-equal index.
    pub fn maybeAssign(self: *GlyphStyle, other: GlyphStyle) void {
        if (other.bits & style_index_mask <= self.bits & style_index_mask) {
            self.bits = (self.bits & ~style_index_mask) | other.bits;
        }
    }

    pub fn setFromGsubOutput(self: *GlyphStyle) void {
        self.bits |= from_gsub_output;
    }

    pub fn clearFromGsub(self: *GlyphStyle) void {
        self.bits &= ~from_gsub_output;
    }

    /// Assigns a style if marked as GSUB output and currently unassigned;
    /// clears the GSUB marker. Returns true when the style was applied.
    pub fn maybeAssignGsubOutputStyle(self: *GlyphStyle, style_class: *const StyleClass) bool {
        if (self.bits & from_gsub_output != 0 and self.isUnassigned()) {
            self.clearFromGsub();
            self.bits = (self.bits & ~style_index_mask) | style_class.index;
            return true;
        }
        return false;
    }
};

// --------------------------------------------------------- generated tables

pub const SCRIPT_CLASSES: [data.SCRIPT_CLASSES.len]ScriptClass = blk: {
    var out: [data.SCRIPT_CLASSES.len]ScriptClass = undefined;
    for (data.SCRIPT_CLASSES, 0..) |raw, ix| {
        out[ix] = .{
            .name = raw.name,
            .group = @enumFromInt(raw.group),
            .tag = raw.tag,
            .hint_top_to_bottom = raw.hint_top_to_bottom,
            .std_chars = raw.std_chars,
            .blues = raw.blues,
        };
    }
    break :blk out;
};

pub const STYLE_CLASSES: [data.STYLE_CLASSES.len]StyleClass = blk: {
    var out: [data.STYLE_CLASSES.len]StyleClass = undefined;
    for (data.STYLE_CLASSES, 0..) |raw, ix| {
        out[ix] = .{
            .name = raw.name,
            .index = @intCast(ix),
            .script = &SCRIPT_CLASSES[raw.script],
            .feature = raw.feature,
        };
    }
    break :blk out;
};

pub const STYLE_RANGES: [data.STYLE_RANGES.len]StyleRange = blk: {
    var out: [data.STYLE_RANGES.len]StyleRange = undefined;
    for (data.STYLE_RANGES, 0..) |raw, ix| {
        out[ix] = .{
            .first = raw.first,
            .last = raw.last,
            .style = .{
                .bits = raw.style | (if (raw.non_base) GlyphStyle.non_base else 0),
            },
        };
    }
    break :blk out;
};

/// Named script indices (upstream `ScriptClass::*`).
pub const script = data.script_index;
/// Named style indices (upstream `StyleClass::*`).
pub const style = data.style_index;

// -------------------------------------------------------------- style map

const unmapped_style: u8 = 0xFF;
const max_styles = STYLE_CLASSES.len;

/// Maps glyph identifiers to glyph styles.
///
/// Also keeps track of the styles that are actually used so metrics can be
/// allocated lazily per style class (this port keys lazily computed metrics
/// by style index directly, so only `styles`/`metricsIndex` are needed).
pub const GlyphStyleMap = struct {
    styles: []GlyphStyle = &.{},

    pub fn deinit(self: *GlyphStyleMap, allocator: std.mem.Allocator) void {
        allocator.free(self.styles);
        self.* = .{};
    }

    /// Computes a new glyph style map for the given glyph count and shaper.
    ///
    /// Roughly based on FreeType's `af_face_globals_compute_style_coverage`.
    pub fn init(
        allocator: std.mem.Allocator,
        glyph_count: u32,
        shaper: *const shaper_mod.Shaper,
    ) !GlyphStyleMap {
        var map = GlyphStyleMap{ .styles = try allocator.alloc(GlyphStyle, glyph_count) };
        errdefer allocator.free(map.styles);
        @memset(map.styles, .{});

        // Step 1: styles for glyphs covered by OpenType features.
        var visited = try shaper_mod.VisitedLookupSet.init(allocator, shaper.lookupCount());
        defer visited.deinit(allocator);
        for (&STYLE_CLASSES) |*style_class| {
            if (style_class.feature != null) {
                _ = shaper.computeCoverage(style_class, .script, map.styles, &visited);
            }
        }
        // Step 2: styles for glyphs contained in the character map.
        // Charmap entries are sorted; remember the last matching range to
        // avoid a binary search per character.
        var last_range: ?struct { ix: usize, range: StyleRange } = null;
        var mappings = shaper.charmap().mappings();
        while (mappings.next()) |mapping| {
            const gid = mapping.gid;
            if (gid >= map.styles.len) continue;
            const style_ptr = &map.styles[gid];
            if (last_range) |last| {
                if (last.range.contains(mapping.codepoint)) {
                    style_ptr.maybeAssign(last.range.style);
                    continue;
                }
            }
            const ix = switch (styleRangeBinarySearch(mapping.codepoint)) {
                .found => |i| i,
                .not_found => |i| if (i == 0) 0 else i - 1,
            };
            if (ix >= STYLE_RANGES.len) continue;
            const range = STYLE_RANGES[ix];
            if (range.contains(mapping.codepoint)) {
                style_ptr.maybeAssign(range.style);
                last_range = .{ .ix = ix, .range = range };
            }
        }
        // Step 3a: script-based coverage.
        for (&STYLE_CLASSES) |*style_class| {
            if (style_class.feature == null) {
                _ = shaper.computeCoverage(style_class, .script, map.styles, &visited);
            }
        }
        // Step 3b: coverage for the "default" script, always Latin in
        // FreeType.
        {
            const default_style = &STYLE_CLASSES[style.latn];
            _ = shaper.computeCoverage(default_style, .default, map.styles, &visited);
        }
        // Step 4: assign Hani to all remaining glyphs (FreeType's fallback).
        for (map.styles) |*glyph_style| {
            if (glyph_style.isUnassigned()) {
                glyph_style.bits &= ~GlyphStyle.style_index_mask;
                glyph_style.bits |= @intCast(style.hani);
            }
        }
        // Step 5: mark ASCII digits.
        var digit: u21 = '0';
        while (digit <= '9') : (digit += 1) {
            if (shaper.charmap().map(digit)) |gid| {
                if (gid < map.styles.len) map.styles[gid].bits |= GlyphStyle.digit;
            }
        }
        return map;
    }

    pub fn styleFor(self: *const GlyphStyleMap, gid: u32) ?GlyphStyle {
        if (gid >= self.styles.len) return null;
        return self.styles[gid];
    }
};

const SearchResult = union(enum) { found: usize, not_found: usize };

fn styleRangeBinarySearch(ch: u32) SearchResult {
    var lo: usize = 0;
    var hi: usize = STYLE_RANGES.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const first = STYLE_RANGES[mid].first;
        if (first == ch) return .{ .found = mid };
        if (first < ch) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return .{ .not_found = lo };
}

test "style range table is sorted and covers ASCII" {
    for (STYLE_RANGES[1..], 0..) |range, ix| {
        try std.testing.expect(range.first > STYLE_RANGES[ix].first);
    }
    // 'A' is Latin (style index 61) per the generated table.
    try std.testing.expectEqual(@as(u16, style.latn), STYLE_RANGES[0].style.styleIndex().?);
    try std.testing.expect(STYLE_RANGES[0].contains('A'));
    try std.testing.expect(STYLE_RANGES[0].contains('z') == false);
    try std.testing.expect(STYLE_RANGES[2].contains('z'));
}

test "glyph style flags" {
    const s = GlyphStyle.fromRawParts(style.latn, true, true);
    try std.testing.expect(s.isNonBase());
    try std.testing.expect(s.isDigit());
    try std.testing.expectEqual(@as(u16, style.latn), s.styleIndex().?);
    try std.testing.expect(s.styleClass().? == &STYLE_CLASSES[style.latn]);
    var other = GlyphStyle{};
    other.setFromGsubOutput();
    try std.testing.expect(other.maybeAssignGsubOutputStyle(&STYLE_CLASSES[style.latn]));
    try std.testing.expectEqual(@as(u16, style.latn), other.styleIndex().?);
    try std.testing.expect(other.bits & GlyphStyle.from_gsub_output == 0);
}
