//! Font discovery via fontconfig (init-time only).
//!
//! `Discovery` owns one `dlopen`ed libfontconfig plus one loaded config and
//! answers "which file holds this family?" with a bounded path copy. All
//! heap-free after `init`: the match path lands in a fixed buffer, so the
//! frame path never touches fontconfig.

const std = @import("std");
const dl = @import("../platform/dl.zig");
const tb = @import("../text/bindings.zig");
const limits = @import("../core/limits.zig");
const tables = @import("tables.zig");

/// UI-facing weight; mapped to `FC_WEIGHT_*` for the query pattern.
pub const Weight = enum {
    regular,
    medium,
    semibold,
    bold,

    pub fn toFc(self: Weight) c_int {
        return switch (self) {
            .regular => tb.FC_WEIGHT_REGULAR,
            .medium => tb.FC_WEIGHT_MEDIUM,
            .semibold => tb.FC_WEIGHT_SEMIBOLD,
            .bold => tb.FC_WEIGHT_BOLD,
        };
    }
};

/// UI-facing slant; mapped to `FC_SLANT_*` for the query pattern.
pub const Slant = enum {
    roman,
    italic,
    oblique,

    pub fn toFc(self: Slant) c_int {
        return switch (self) {
            .roman => tb.FC_SLANT_ROMAN,
            .italic => tb.FC_SLANT_ITALIC,
            .oblique => tb.FC_SLANT_OBLIQUE,
        };
    }
};

/// A resolved font file. The path buffer carries its own NUL so it can go
/// straight to `FT_New_Face` with no further allocation or copy.
pub const Match = struct {
    path: [limits.MAX_FONT_PATH_LEN + 1]u8 = undefined,
    path_len: usize = 0,
    index: c_int = 0,

    pub fn pathSlice(self: *const Match) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn pathZ(self: *Match) [*:0]const u8 {
        self.path[self.path_len] = 0;
        return self.path[0..self.path_len :0];
    }
};

pub const Discovery = struct {
    lib: dl.Library,
    api: tables.FontconfigApi,
    config: *tb.FcConfig,

    pub fn init() !Discovery {
        var lib = dl.Library.open(tables.fontconfig_lib_names) orelse return error.FontconfigUnavailable;
        errdefer lib.close();
        const api = tables.FontconfigApi.load(lib) orelse return error.FontconfigSymbolsMissing;
        const config = api.init_load_config_and_fonts() orelse return error.FontconfigInitFailed;
        return .{ .lib = lib, .api = api, .config = config };
    }

    pub fn deinit(self: *Discovery) void {
        self.api.config_destroy(self.config);
        self.lib.close();
    }

    /// Resolve `family` (e.g. `"sans-serif"`, `"monospace"`) to a file.
    /// Fontconfig always returns its best match, so this only fails on
    /// API misuse or an over-long path.
    pub fn find(self: *Discovery, family: [*:0]const u8, weight: Weight, slant: Slant) !Match {
        const pat = self.api.pattern_create() orelse return error.OutOfMemory;
        defer self.api.pattern_destroy(pat);

        if (self.api.pattern_add_string(pat, tb.FC_FAMILY, family) == 0) return error.PatternAddFailed;
        if (self.api.pattern_add_integer(pat, tb.FC_WEIGHT, weight.toFc()) == 0) return error.PatternAddFailed;
        if (self.api.pattern_add_integer(pat, tb.FC_SLANT, slant.toFc()) == 0) return error.PatternAddFailed;
        if (self.api.pattern_add_bool(pat, tb.FC_SCALABLE, 1) == 0) return error.PatternAddFailed;

        _ = self.api.config_substitute(self.config, pat, .FcMatchPattern);
        self.api.default_substitute(pat);

        var result: tb.FcResult = .FcResultNoMatch;
        const match = self.api.font_match(self.config, pat, &result) orelse return error.NoMatch;
        defer self.api.pattern_destroy(match);

        var file: ?[*:0]const tb.FcChar8 = null;
        if (self.api.pattern_get_string(match, tb.FC_FILE, 0, &file) != .FcResultMatch) return error.NoFile;
        const path = std.mem.span(file.?);

        var index: c_int = 0;
        // Index may be absent for single-face files; 0 is the right default.
        _ = self.api.pattern_get_integer(match, tb.FC_INDEX, 0, &index);

        if (path.len == 0 or path.len > limits.MAX_FONT_PATH_LEN) return error.PathTooLong;
        var out = Match{ .index = index, .path_len = path.len };
        @memcpy(out.path[0..path.len], path);
        out.path[path.len] = 0;
        return out;
    }

    pub fn findSans(self: *Discovery) !Match {
        return self.find("sans-serif", .regular, .roman);
    }

    pub fn findMono(self: *Discovery) !Match {
        return self.find("monospace", .regular, .roman);
    }
};

test "weight and slant map to fontconfig constants" {
    const t = std.testing;
    try t.expectEqual(tb.FC_WEIGHT_REGULAR, Weight.regular.toFc());
    try t.expectEqual(tb.FC_WEIGHT_MEDIUM, Weight.medium.toFc());
    try t.expectEqual(tb.FC_WEIGHT_SEMIBOLD, Weight.semibold.toFc());
    try t.expectEqual(tb.FC_WEIGHT_BOLD, Weight.bold.toFc());
    try t.expectEqual(tb.FC_SLANT_ROMAN, Slant.roman.toFc());
    try t.expectEqual(tb.FC_SLANT_ITALIC, Slant.italic.toFc());
    try t.expectEqual(tb.FC_SLANT_OBLIQUE, Slant.oblique.toFc());
}

test "match path slice and NUL handling" {
    const t = std.testing;
    var m = Match{};
    const sample = "/usr/share/fonts/x.ttf";
    @memcpy(m.path[0..sample.len], sample);
    m.path_len = sample.len;
    m.path[m.path_len] = 0;
    try t.expectEqualStrings(sample, m.pathSlice());
    try t.expectEqualStrings(sample, std.mem.span(m.pathZ()));
}

test "discovery resolves sans and mono" {
    const t = std.testing;
    if (!tables.FontconfigApi.isAvailable()) return;
    var d = try Discovery.init();
    defer d.deinit();

    const sans = try d.findSans();
    try t.expect(sans.path_len > 0);
    try t.expect(sans.index >= 0);

    const mono = try d.findMono();
    try t.expect(mono.path_len > 0);

    // Unknown families still resolve (fontconfig falls back to a default).
    const fallback = try d.find("this-family-does-not-exist-zzz", .regular, .roman);
    try t.expect(fallback.path_len > 0);
}
