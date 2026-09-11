//! Port of cosmic-text `font/system.rs` (font database + match cache).
//!
//! Self-contained: defines local `Weight` / `Stretch` / `Style` / `Family`
//! aliases at the top instead of importing `attrs.zig`. Unify these aliases
//! with the attrs/font/fallback modules later; keep this file compiling
//! standalone until then.
//!
//! Full `Fallbacks` iteration lives in `fallback.zig` and real font parsing
//! in `font.zig` (unification TODOs below); this file owns database query,
//! `FontMatchKey` ordering, match-codepoint caches, and system-font loading.
//!
//! C-INTEROP WIRING POINTS (the only intended stubs):
//! - fontconfig: `loadSystemFonts` documents the `FcInitLoadConfigAndFonts`
//!   hookup; the manual `/usr/share/fonts` scan below is the fallback.
//! - variable-weight matching: `FontMatchKey.init` reads the face's
//!   `variable_wght_min/max` (`fvar` via FreeType `FT_Get_MM_Var` / skrifa
//!   `axes().get_by_tag("wght")` in production); see `variableWeightMatch`.

const std = @import("std");
const builtin = @import("builtin");
const shape_hb = @import("shape_hb.zig");
const shape_mod = @import("shape.zig");
const font_parse = @import("font_parse.zig");

// ---------------------------------------------------------------------------
// Local aliases (do NOT import attrs.zig yet; see header TODO).
// ---------------------------------------------------------------------------

pub const Weight = u16;
pub const WEIGHT_NORMAL: Weight = 400;

pub const Stretch = enum(u8) {
    ultra_condensed = 1,
    extra_condensed = 2,
    condensed = 3,
    semi_condensed = 4,
    normal = 5,
    semi_expanded = 6,
    expanded = 7,
    extra_expanded = 8,
    ultra_expanded = 9,

    pub fn toNumber(self: Stretch) u16 {
        return @backingInt(self);
    }

    pub fn fromNumber(n: u16) ?Stretch {
        return switch (n) {
            1 => .ultra_condensed,
            2 => .extra_condensed,
            3 => .condensed,
            4 => .semi_condensed,
            5 => .normal,
            6 => .semi_expanded,
            7 => .expanded,
            8 => .extra_expanded,
            9 => .ultra_expanded,
            else => null,
        };
    }
};

pub const Style = enum(u8) {
    normal = 0,
    italic = 1,
    oblique = 2,
};

pub const FamilyTag = enum(u8) {
    name,
    serif,
    sans_serif,
    cursive,
    fantasy,
    monospace,
};

pub const Family = union(FamilyTag) {
    name: []const u8,
    serif: void,
    sans_serif: void,
    cursive: void,
    fantasy: void,
    monospace: void,
};

pub const FontId = u32;

pub const DEFAULT_MONO_FAMILY = "Noto Sans Mono";
pub const DEFAULT_SANS_FAMILY = "Open Sans";
pub const DEFAULT_SERIF_FAMILY = "DejaVu Serif";
pub const FALLBACK_LOCALE = "en-US";

/// Attributes used for font matching (borrowed family name).
pub const AttrsForMatch = struct {
    family: Family,
    weight: Weight = WEIGHT_NORMAL,
    stretch: Stretch = .normal,
    style: Style = .normal,
};

// ---------------------------------------------------------------------------
// Face info + database.
// ---------------------------------------------------------------------------

/// Per-face metadata (mirrors the `fontdb::FaceInfo` subset cosmic-text
/// uses: id/path/index/families/post-script/weight/stretch/style/mono).
pub const FaceInfo = struct {
    id: FontId,
    path: []u8,
    index: u32,
    families: [][]u8,
    post_script_name: []u8,
    weight: Weight,
    stretch: Stretch,
    style: Style,
    monospaced: bool,
    /// Variable `wght`-axis range (from `fvar`/`FT_Get_MM_Var`); null when the
    /// face is not variable or the range is unknown. Used by
    /// `variableWeightMatch` / `FontMatchKey.init` (M2 wiring point).
    variable_wght_min: ?Weight = null,
    variable_wght_max: ?Weight = null,
};

/// Variable-weight coverage check (M2 wiring point).
/// Mirrors `FontMatchKey::new`'s `variable_weight_match` axis query
/// (`system.rs:38-44`): true when the wanted weight differs from the face's
/// nominal weight but lies inside the face's `wght` variation range.
/// Production wiring fills `variable_wght_min/max` from the font's `fvar`
/// table (FreeType `FT_Get_MM_Var` / skrifa `axes().get_by_tag("wght")`);
/// the comparison itself is already verbatim.
pub fn variableWeightMatch(wanted: Weight, nominal: Weight, wght_min: ?Weight, wght_max: ?Weight) bool {
    if (wanted == nominal) return false;
    const lo = wght_min orelse return false;
    const hi = wght_max orelse return false;
    const lo_u = if (lo <= hi) lo else hi;
    const hi_u = if (lo <= hi) hi else lo;
    return wanted >= lo_u and wanted <= hi_u;
}

/// Owned font database with `fontdb::Database::query` equivalent.
pub const FontDb = struct {
    faces: std.ArrayList(FaceInfo),
    next_id: FontId = 0,
    mono_family: []u8,
    sans_family: []u8,
    serif_family: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!FontDb {
        const mono = try allocator.dupe(u8, DEFAULT_MONO_FAMILY);
        errdefer allocator.free(mono);
        const sans = try allocator.dupe(u8, DEFAULT_SANS_FAMILY);
        errdefer allocator.free(sans);
        const serif = try allocator.dupe(u8, DEFAULT_SERIF_FAMILY);
        errdefer allocator.free(serif);
        return .{
            .faces = .empty,
            .mono_family = mono,
            .sans_family = sans,
            .serif_family = serif,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontDb) void {
        for (self.faces.items) |*f| {
            self.allocator.free(f.path);
            for (f.families) |fam| self.allocator.free(fam);
            self.allocator.free(f.families);
            self.allocator.free(f.post_script_name);
        }
        self.faces.deinit(self.allocator);
        self.allocator.free(self.mono_family);
        self.allocator.free(self.sans_family);
        self.allocator.free(self.serif_family);
        self.* = undefined;
    }

    pub fn setMonoFamily(self: *FontDb, name: []const u8) std.mem.Allocator.Error!void {
        const duped = try self.allocator.dupe(u8, name);
        self.allocator.free(self.mono_family);
        self.mono_family = duped;
    }

    pub fn setSansFamily(self: *FontDb, name: []const u8) std.mem.Allocator.Error!void {
        const duped = try self.allocator.dupe(u8, name);
        self.allocator.free(self.sans_family);
        self.sans_family = duped;
    }

    pub fn setSerifFamily(self: *FontDb, name: []const u8) std.mem.Allocator.Error!void {
        const duped = try self.allocator.dupe(u8, name);
        self.allocator.free(self.serif_family);
        self.serif_family = duped;
    }

    pub fn addFace(
        self: *FontDb,
        path: []const u8,
        index: u32,
        families: []const []const u8,
        post_script_name: []const u8,
        weight: Weight,
        stretch: Stretch,
        style: Style,
        monospaced: bool,
    ) std.mem.Allocator.Error!FontId {
        const id = self.next_id;
        self.next_id += 1;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_post = try self.allocator.dupe(u8, post_script_name);
        errdefer self.allocator.free(owned_post);
        var owned_families = try self.allocator.alloc([]u8, families.len);
        errdefer self.allocator.free(owned_families);
        // C4: only free slots that were actually initialized. Freeing the
        // whole slice on OOM would free uninitialized memory.
        var initialized: usize = 0;
        errdefer {
            for (owned_families[0..initialized]) |fam| self.allocator.free(fam);
        }
        for (families, 0..) |fam, i| {
            owned_families[i] = try self.allocator.dupe(u8, fam);
            initialized += 1;
        }
        try self.faces.append(self.allocator, .{
            .id = id,
            .path = owned_path,
            .index = index,
            .families = owned_families,
            .post_script_name = owned_post,
            .weight = weight,
            .stretch = stretch,
            .style = style,
            .monospaced = monospaced,
        });
        return id;
    }

    pub fn face(self: *const FontDb, id: FontId) ?*const FaceInfo {
        for (self.faces.items) |*f| {
            if (f.id == id) return f;
        }
        return null;
    }

    pub fn len(self: *const FontDb) usize {
        return self.faces.items.len;
    }

    /// Default family name for a generic selector.
    pub fn familyName(self: *const FontDb, family: Family) []const u8 {
        return switch (family) {
            .name => |n| n,
            .monospace => self.mono_family,
            .sans_serif => self.sans_family,
            .serif => self.serif_family,
            .cursive => self.sans_family,
            .fantasy => self.sans_family,
        };
    }

    pub fn faceContainsFamily(self: *const FontDb, id: FontId, name: []const u8) bool {
        const f = self.face(id) orelse return false;
        for (f.families) |fam| {
            if (std.mem.eql(u8, fam, name)) return true;
        }
        return false;
    }

    /// Set a face's variable `wght` range (M2 wiring point).
    /// Returns false for unknown ids. Production fills this from the font's
    /// `fvar` table at load time; tests use it to simulate variable fonts.
    pub fn setVariableWghtRange(self: *FontDb, id: FontId, min: Weight, max: Weight) bool {
        for (self.faces.items) |*f| {
            if (f.id == id) {
                f.variable_wght_min = min;
                f.variable_wght_max = max;
                return true;
            }
        }
        return false;
    }

    fn faceHasFamily(f: *const FaceInfo, name: []const u8) bool {
        for (f.families) |fam| {
            if (std.mem.eql(u8, fam, name)) return true;
        }
        return false;
    }

    fn familyMatches(self: *const FontDb, f: *const FaceInfo, family: Family) bool {
        switch (family) {
            .name => |n| {
                return faceHasFamily(f, n);
            },
            .monospace => return f.monospaced,
            // M1: generic families resolve via the configured default family
            // names (fontdb `set_*_family`), not "match any face". This keeps
            // `query(.sans_serif)` scoped to the sans default instead of
            // returning the globally closest weight/style face.
            .sans_serif => return faceHasFamily(f, self.sans_family),
            .serif => return faceHasFamily(f, self.serif_family),
            .cursive => return faceHasFamily(f, self.familyName(.cursive)),
            .fantasy => return faceHasFamily(f, self.familyName(.fantasy)),
        }
    }

    /// `fontdb::Database::query` equivalent for a single family.
    /// Among family-matching faces, picks the minimum by
    /// (weight_diff, stretch_diff, style_diff, id).
    pub fn query(
        self: *const FontDb,
        family: Family,
        weight: Weight,
        stretch: Stretch,
        style: Style,
    ) ?FontId {
        var best: ?FontId = null;
        var best_score: QueryScore = undefined;
        var first = true;
        for (self.faces.items) |*f| {
            if (!self.familyMatches(f, family)) continue;
            const score = QueryScore{
                .w = absDiffU16(weight, f.weight),
                .s = absDiffU16(stretch.toNumber(), f.stretch.toNumber()),
                .y = styleDiff(style, f.style),
                .id = f.id,
            };
            if (first or scoreLess(score, best_score)) {
                best = f.id;
                best_score = score;
                first = false;
            }
        }
        return best;
    }
};

const QueryScore = struct {
    w: u16,
    s: u16,
    y: u8,
    id: FontId,
};

fn scoreLess(a: QueryScore, b: QueryScore) bool {
    if (a.w != b.w) return a.w < b.w;
    if (a.s != b.s) return a.s < b.s;
    if (a.y != b.y) return a.y < b.y;
    return a.id < b.id;
}

fn absDiffU16(a: u16, b: u16) u16 {
    return if (a >= b) a - b else b - a;
}

fn styleDiff(wanted: Style, got: Style) u8 {
    if (wanted == got) return 0;
    return switch (wanted) {
        .italic => if (got == .oblique) @as(u8, 1) else @as(u8, 2),
        .oblique => if (got == .italic) @as(u8, 1) else @as(u8, 2),
        .normal => 2,
    };
}

fn isEmojiPostScript(post: []const u8) bool {
    return std.mem.containsAtLeast(u8, post, 1, "Emoji");
}

// ---------------------------------------------------------------------------
// FontMatchKey (field order is the sort order, exactly as Rust).
// ---------------------------------------------------------------------------

/// Sort key for fallback candidates.
///
/// Field declaration order IS the derived-`Ord` order in Rust
/// (`not_emoji`, `font_weight_diff`, `font_stretch_diff`,
/// `font_style_diff`, `font_weight`, `font_stretch`, `id`,
/// `variable_weight_match`), so keep this layout verbatim.
pub const FontMatchKey = struct {
    not_emoji: bool,
    font_weight_diff: u16,
    font_stretch_diff: u16,
    font_style_diff: u8,
    font_weight: u16,
    font_stretch: u16,
    id: FontId,
    variable_weight_match: bool,

    pub fn init(attrs: AttrsForMatch, face: *const FaceInfo) FontMatchKey {
        return .{
            .not_emoji = !isEmojiPostScript(face.post_script_name),
            .font_weight_diff = absDiffU16(attrs.weight, face.weight),
            .font_stretch_diff = absDiffU16(attrs.stretch.toNumber(), face.stretch.toNumber()),
            .font_style_diff = styleDiff(attrs.style, face.style),
            .font_weight = face.weight,
            .font_stretch = face.stretch.toNumber(),
            .id = face.id,
            // M2: variable-weight match when the wanted weight lies inside
            // the face's `wght` axis range despite a nominal diff.
            // `variable_wght_min/max` are filled from `fvar` at load time
            // (FreeType `FT_Get_MM_Var` / skrifa `axes().get_by_tag("wght")`);
            // see `variableWeightMatch` and `setVariableWghtRange`.
            .variable_weight_match = variableWeightMatch(
                attrs.weight,
                face.weight,
                face.variable_wght_min,
                face.variable_wght_max,
            ),
        };
    }

    pub fn lessThan(a: FontMatchKey, b: FontMatchKey) bool {
        // NOTE: this reproduces Rust's derived-`Ord` (lexicographic,
        // ascending per field) exactly, quirks included: `false < true`
        // means emoji faces (`not_emoji=false`) sort BEFORE non-emoji at
        // equal diffs. Do not "fix" the polarity here; parity beats intent.
        if (a.not_emoji != b.not_emoji) return !a.not_emoji and b.not_emoji;
        if (a.font_weight_diff != b.font_weight_diff) return a.font_weight_diff < b.font_weight_diff;
        if (a.font_stretch_diff != b.font_stretch_diff) return a.font_stretch_diff < b.font_stretch_diff;
        if (a.font_style_diff != b.font_style_diff) return a.font_style_diff < b.font_style_diff;
        if (a.font_weight != b.font_weight) return a.font_weight < b.font_weight;
        if (a.font_stretch != b.font_stretch) return a.font_stretch < b.font_stretch;
        if (a.id != b.id) return a.id < b.id;
        if (a.variable_weight_match != b.variable_weight_match) {
            return !a.variable_weight_match and b.variable_weight_match;
        }
        return false;
    }

    pub fn eql(a: FontMatchKey, b: FontMatchKey) bool {
        return a.not_emoji == b.not_emoji and
            a.font_weight_diff == b.font_weight_diff and
            a.font_stretch_diff == b.font_stretch_diff and
            a.font_style_diff == b.font_style_diff and
            a.font_weight == b.font_weight and
            a.font_stretch == b.font_stretch and
            a.id == b.id and
            a.variable_weight_match == b.variable_weight_match;
    }
};

fn matchKeyLess(_: void, a: FontMatchKey, b: FontMatchKey) bool {
    return a.lessThan(b);
}

// ---------------------------------------------------------------------------
// Match-attribute cache key.
// ---------------------------------------------------------------------------

pub const FontMatchAttrs = struct {
    family_tag: FamilyTag,
    family_name: []u8,
    weight: Weight,
    stretch: u16,
    style: u8,

    pub fn fromAttrs(allocator: std.mem.Allocator, attrs: AttrsForMatch) std.mem.Allocator.Error!FontMatchAttrs {
        const name: []const u8 = switch (attrs.family) {
            .name => |n| n,
            else => "",
        };
        return .{
            .family_tag = std.meta.activeTag(attrs.family),
            .family_name = try allocator.dupe(u8, name),
            .weight = attrs.weight,
            .stretch = attrs.stretch.toNumber(),
            .style = @backingInt(attrs.style),
        };
    }

    pub fn free(self: *FontMatchAttrs, allocator: std.mem.Allocator) void {
        allocator.free(self.family_name);
    }
};

pub const MatchContext = struct {
    pub fn hash(_: @This(), k: FontMatchAttrs) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&[_]u8{@backingInt(k.family_tag)});
        h.update(std.mem.asBytes(&k.weight));
        h.update(std.mem.asBytes(&k.stretch));
        h.update(&[_]u8{k.style});
        h.update(k.family_name);
        return h.final();
    }
    pub fn eql(_: @This(), a: FontMatchAttrs, b: FontMatchAttrs) bool {
        return a.family_tag == b.family_tag and
            a.weight == b.weight and
            a.stretch == b.stretch and
            a.style == b.style and
            std.mem.eql(u8, a.family_name, b.family_name);
    }
};

// ---------------------------------------------------------------------------
// Codepoint support cache (per-font caps 512/1024, verbatim logic).
// ---------------------------------------------------------------------------

pub const CodepointSupport = struct {
    pub const SUPPORTED_MAX: usize = 512;
    pub const NOT_SUPPORTED_MAX: usize = 1024;

    supported: std.ArrayList(u32),
    not_supported: std.ArrayList(u32),

    pub fn init() CodepointSupport {
        return .{ .supported = .empty, .not_supported = .empty };
    }

    pub fn deinit(self: *CodepointSupport, allocator: std.mem.Allocator) void {
        self.supported.deinit(allocator);
        self.not_supported.deinit(allocator);
    }

    const Bound = struct {
        found: bool,
        pos: usize,
    };

    fn lowerBound(items: []const u32, v: u32) Bound {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < v) {
                lo = mid + 1;
            } else if (items[mid] > v) {
                hi = mid;
            } else {
                return .{ .found = true, .pos = mid };
            }
        }
        return .{ .found = false, .pos = lo };
    }

    fn unknownHas(
        self: *CodepointSupport,
        allocator: std.mem.Allocator,
        font_codepoints: []const u32,
        cp: u32,
        sup_pos: usize,
        not_pos: usize,
    ) std.mem.Allocator.Error!bool {
        var present = false;
        for (font_codepoints) |c| {
            if (c == cp) {
                present = true;
                break;
            }
        }
        if (present) {
            if (sup_pos != SUPPORTED_MAX) {
                try self.supported.insert(allocator, sup_pos, cp);
                if (self.supported.items.len > SUPPORTED_MAX) {
                    self.supported.items.len = SUPPORTED_MAX;
                }
            }
        } else {
            if (not_pos != NOT_SUPPORTED_MAX) {
                try self.not_supported.insert(allocator, not_pos, cp);
                if (self.not_supported.items.len > NOT_SUPPORTED_MAX) {
                    self.not_supported.items.len = NOT_SUPPORTED_MAX;
                }
            }
        }
        return present;
    }

    /// Mirrors `FontCachedCodepointSupportInfo::has_codepoint`.
    pub fn hasCodepoint(
        self: *CodepointSupport,
        allocator: std.mem.Allocator,
        font_codepoints: []const u32,
        cp: u32,
    ) std.mem.Allocator.Error!bool {
        const s = lowerBound(self.supported.items, cp);
        if (s.found) return true;
        const n = lowerBound(self.not_supported.items, cp);
        if (n.found) return false;
        return self.unknownHas(allocator, font_codepoints, cp, s.pos, n.pos);
    }
};

// ---------------------------------------------------------------------------
// Font system.
// ---------------------------------------------------------------------------

pub const FontCacheKey = struct {
    id: FontId,
    weight: Weight,
};

/// Placeholder for a loaded font entry.
/// Production wiring stores the real `font.zig` `Font` here
/// (see header unification TODO); the cache behavior (insert-once,
/// failed loads cached as null) is already exact.
pub const FontCacheEntry = struct {
    id: FontId,
    weight: Weight,
};

pub const LoadStats = struct {
    dirs_scanned: usize = 0,
    dirs_missing: usize = 0,
    files_seen: usize = 0,
    faces_added: usize = 0,
    file_errors: usize = 0,
};

pub const FontSystem = struct {
    pub const MATCHES_CACHE_LIMIT: usize = 256;

    allocator: std.mem.Allocator,
    locale: []u8,
    db: FontDb,
    font_cache: std.AutoHashMap(FontCacheKey, ?FontCacheEntry),
    matches_cache: std.HashMap(FontMatchAttrs, []FontMatchKey, MatchContext, 80),
    support_cache: std.AutoHashMap(FontId, CodepointSupport),
    monospace_ids: std.ArrayList(FontId),
    /// Scratch buffer for shaping/layout (mirrors `shape_buffer` role).
    shape_scratch: std.ArrayList(u8),
    /// Scratch buffer for monospace fallback iteration
    /// (mirrors `monospace_fallbacks_buffer` role).
    mono_scratch: std.ArrayList(FontId),
    /// HarfBuzz shaping backend. `null` until `addFontData` is called, in
    /// which case consumers fall back to the charmap stand-in.
    shaper_backend: ?shape_hb.Backend = null,
    /// Ids registered through `addFontData`, in registration order. Used by
    /// the raster bridge to enumerate fonts.
    font_ids: std.ArrayList(FontId) = .empty,

    /// Take ownership of `db` and `locale`, apply default families
    /// (mono "Noto Sans Mono", sans "Open Sans", serif "DejaVu Serif"),
    /// and build the sorted monospace id list.
    /// Mirrors `finish_with_db` + `new_with_locale_and_db`.
    pub fn initWithDb(
        allocator: std.mem.Allocator,
        db: FontDb,
        locale: []const u8,
    ) std.mem.Allocator.Error!FontSystem {
        var owned_db = db;
        errdefer owned_db.deinit();
        try owned_db.setMonoFamily(DEFAULT_MONO_FAMILY);
        try owned_db.setSansFamily(DEFAULT_SANS_FAMILY);
        try owned_db.setSerifFamily(DEFAULT_SERIF_FAMILY);
        const owned_locale = try allocator.dupe(u8, locale);
        errdefer allocator.free(owned_locale);
        var self = FontSystem{
            .allocator = allocator,
            .locale = owned_locale,
            .db = owned_db,
            .font_cache = std.AutoHashMap(FontCacheKey, ?FontCacheEntry).init(allocator),
            .matches_cache = std.HashMap(FontMatchAttrs, []FontMatchKey, MatchContext, 80).init(allocator),
            .support_cache = std.AutoHashMap(FontId, CodepointSupport).init(allocator),
            .monospace_ids = .empty,
            .shape_scratch = .empty,
            .mono_scratch = .empty,
        };
        errdefer self.deinit();
        try self.rebuildMonospaceIds();
        return self;
    }

    /// Empty system with the default locale ("en-US").
    /// App code that wants the host locale resolves it via
    /// `systemLocaleFromEnv` (from `init.environ` values) and calls
    /// `initWithDb` instead.
    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!FontSystem {
        const locale = try defaultLocale(allocator);
        errdefer allocator.free(locale);
        const db = try FontDb.init(allocator);
        errdefer {
            var owned = db;
            owned.deinit();
        }
        const owned_locale = try allocator.dupe(u8, locale);
        allocator.free(locale);
        errdefer allocator.free(owned_locale);
        var self = FontSystem{
            .allocator = allocator,
            .locale = owned_locale,
            .db = db,
            .font_cache = std.AutoHashMap(FontCacheKey, ?FontCacheEntry).init(allocator),
            .matches_cache = std.HashMap(FontMatchAttrs, []FontMatchKey, MatchContext, 80).init(allocator),
            .support_cache = std.AutoHashMap(FontId, CodepointSupport).init(allocator),
            .monospace_ids = .empty,
            .shape_scratch = .empty,
            .mono_scratch = .empty,
        };
        errdefer self.deinit();
        try self.db.setMonoFamily(DEFAULT_MONO_FAMILY);
        try self.db.setSansFamily(DEFAULT_SANS_FAMILY);
        try self.db.setSerifFamily(DEFAULT_SERIF_FAMILY);
        return self;
    }

    pub fn deinit(self: *FontSystem) void {
        self.clearMatchesCache();
        self.matches_cache.deinit();
        self.font_cache.deinit();
        var it = self.support_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.support_cache.deinit();
        self.monospace_ids.deinit(self.allocator);
        self.shape_scratch.deinit(self.allocator);
        self.mono_scratch.deinit(self.allocator);
        if (self.shaper_backend) |*b| b.deinit();
        self.font_ids.deinit(self.allocator);
        self.allocator.free(self.locale);
        self.db.deinit();
        self.* = undefined;
    }

    pub fn getLocale(self: *const FontSystem) []const u8 {
        return self.locale;
    }

    /// Mutable db access clears the match cache (mirrors `db_mut`).
    pub fn dbMut(self: *FontSystem) *FontDb {
        self.clearMatchesCache();
        return &self.db;
    }

    /// Register font bytes with the HarfBuzz shaping backend under `id`
    /// (lazily creates the backend). The backend copies the bytes; the caller
    /// keeps ownership. Pair it with `dbMut().addFace` so family matching and
    /// shaping use the same `id`.
    pub fn addFontData(
        self: *FontSystem,
        id: FontId,
        bytes: []const u8,
        index: u32,
        italic_or_oblique: bool,
        monospace_em_width: ?f32,
    ) (std.mem.Allocator.Error || error{InvalidFont})!void {
        if (self.shaper_backend == null) {
            self.shaper_backend = try shape_hb.Backend.init(self.allocator);
        }
        try self.shaper_backend.?.addFont(id, bytes, index, italic_or_oblique, monospace_em_width);
        for (self.font_ids.items) |existing| {
            if (existing == id) return;
        }
        try self.font_ids.append(self.allocator, id);
    }

    /// Ids registered through `addFontData`, in registration order.
    pub fn fontIds(self: *const FontSystem) []const FontId {
        return self.font_ids.items;
    }

    /// HarfBuzz-backed `ShapeAdapter`, or `null` when no font data has been
    /// registered (callers then use the charmap stand-in).
    pub fn shaper(self: *FontSystem) ?shape_mod.ShapeAdapter {
        if (self.shaper_backend) |*b| return b.adapter();
        return null;
    }

    /// Bytes of a registered font, by `FontId` (borrowed from the backend).
    /// Used by the FreeType raster bridge.
    pub fn fontBytes(self: *const FontSystem, id: FontId) ?[]const u8 {
        if (self.shaper_backend) |*b| {
            for (b.entries.items) |*e| {
                if (e.id == id) return e.blob;
            }
        }
        return null;
    }

    pub fn hasShaper(self: *const FontSystem) bool {
        return self.shaper_backend != null;
    }

    pub fn clearMatchesCache(self: *FontSystem) void {
        var it = self.matches_cache.iterator();
        while (it.next()) |entry| {
            var key = entry.key_ptr;
            key.free(self.allocator);
            self.allocator.free(entry.value_ptr.*);
        }
        self.matches_cache.clearRetainingCapacity();
    }

    pub fn matchesCacheSize(self: *const FontSystem) usize {
        return self.matches_cache.count();
    }

    pub fn rebuildMonospaceIds(self: *FontSystem) std.mem.Allocator.Error!void {
        self.monospace_ids.clearRetainingCapacity();
        for (self.db.faces.items) |*f| {
            if (f.monospaced and !isEmojiPostScript(f.post_script_name)) {
                try self.monospace_ids.append(self.allocator, f.id);
            }
        }
        std.mem.sort(FontId, self.monospace_ids.items, {}, std.sort.asc(FontId));
    }

    pub fn isMonospace(self: *const FontSystem, id: FontId) bool {
        for (self.monospace_ids.items) |m| {
            if (m == id) return true;
            if (m > id) break;
        }
        return false;
    }

    /// Cached font load. Real parsing (`font.zig` `Font.init`) plugs in at
    /// the marked line; misses for unknown ids cache as null like Rust's
    /// `or_insert_with` warning path.
    pub fn getFont(self: *FontSystem, id: FontId, weight: Weight) std.mem.Allocator.Error!?FontCacheEntry {
        const key = FontCacheKey{ .id = id, .weight = weight };
        if (self.font_cache.get(key)) |cached| return cached;
        const entry: ?FontCacheEntry = if (self.db.face(id) != null) .{
            // C-INTEROP: replace with `font.zig` Font load
            // (`Font.init` on the face bytes at `weight`).
            .id = id,
            .weight = weight,
        } else null;
        try self.font_cache.put(key, entry);
        return entry;
    }

    /// Sorted match list with `db.query` move-to-front, exactly as Rust's
    /// `get_font_matches`. Clears the cache at >= 256 entries first.
    /// The returned slice is owned by the cache; copy it if the cache
    /// may be cleared before use.
    ///
    /// C3: the `errdefer` below removes the map entry BEFORE freeing the
    /// key's `family_name` bytes. Reversing that order would hash/free
    /// use-after-free memory (`remove` hashes `family_name`). The key is
    /// copied by value for `remove`, then the copy's allocation is freed;
    /// `gop.key_ptr` is not dereferenced after `remove`.
    pub fn getFontMatches(self: *FontSystem, attrs: AttrsForMatch) std.mem.Allocator.Error![]const FontMatchKey {
        if (self.matches_cache.count() >= MATCHES_CACHE_LIMIT) {
            self.clearMatchesCache();
        }
        var owned_key = try FontMatchAttrs.fromAttrs(self.allocator, attrs);
        // If `getOrPut` itself OOMs the map keeps nothing, so free the
        // owned key here (otherwise it leaks). After a successful
        // `getOrPut` the key is owned by the map (miss) or redundant (hit).
        const gop = self.matches_cache.getOrPut(owned_key) catch |e| {
            owned_key.free(self.allocator);
            return e;
        };
        if (gop.found_existing) {
            owned_key.free(self.allocator);
            return gop.value_ptr.*;
        }
        errdefer {
            // Copy first: `remove` hashes the key, so it must run while
            // `family_name` is still alive. Free only afterwards.
            const key_copy = gop.key_ptr.*;
            const removed = self.matches_cache.remove(key_copy);
            std.debug.assert(removed);
            std.debug.assert(self.matches_cache.get(key_copy) == null);
            var tmp = key_copy;
            tmp.free(self.allocator);
        }

        var keys = std.ArrayList(FontMatchKey).empty;
        defer keys.deinit(self.allocator);
        for (self.db.faces.items) |*f| {
            try keys.append(self.allocator, FontMatchKey.init(attrs, f));
        }
        std.mem.sort(FontMatchKey, keys.items, {}, matchKeyLess);

        // db.query is better than the sort above but returns one font:
        // move it to the front (or prepend it) exactly as Rust does.
        if (self.db.query(attrs.family, attrs.weight, attrs.stretch, attrs.style)) |qid| {
            var found: ?usize = null;
            for (keys.items, 0..) |k, i| {
                if (k.id == qid) {
                    found = i;
                    break;
                }
            }
            if (found) |i| {
                const k = keys.orderedRemove(i);
                try keys.insert(self.allocator, 0, k);
            } else if (self.db.face(qid)) |face| {
                try keys.insert(self.allocator, 0, FontMatchKey.init(attrs, face));
            }
        }

        const owned = try self.allocator.dupe(FontMatchKey, keys.items);
        gop.value_ptr.* = owned;
        return owned;
    }

    /// Count of `word` codepoints covered by `font_codepoints`, using the
    /// per-font support cache. Returns null for unknown font ids.
    pub fn countSupportedCodepoints(
        self: *FontSystem,
        id: FontId,
        font_codepoints: []const u32,
        word: []const u8,
    ) std.mem.Allocator.Error!?usize {
        if (self.db.face(id) == null) return null;
        const gop = try self.support_cache.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = CodepointSupport.init();
        }
        var count: usize = 0;
        var iter = std.unicode.Utf8View.init(word) catch return @as(?usize, 0);
        var it = iter.iterator();
        while (it.nextCodepoint()) |cp| {
            if (try gop.value_ptr.hasCodepoint(self.allocator, font_codepoints, cp)) {
                count += 1;
            }
        }
        return count;
    }

    /// Load system fonts: fontconfig hookup point, then a manual scan of
    /// well-known directories. Never fails on missing dirs; per-file
    /// problems are counted in `LoadStats` instead of silently dropped.
    ///
    /// C-INTEROP: wire fontconfig here (`FcInitLoadConfigAndFonts`,
    /// `FcFontList` -> `db.addFace`); see `.reference/fontconfig`
    /// discussions. The scan below stays as the fallback.
    ///
    /// M4: user dirs come from `XDG_DATA_HOME`/`HOME` (see
    /// `resolveUserFontDirs`), never hardcoded home paths. System dirs are
    /// `/usr/share/fonts` + `/usr/local/share/fonts`.
    pub fn loadSystemFonts(self: *FontSystem, io: std.Io) LoadStats {
        return self.loadSystemFontsWithEnv(io, getenvSpan("XDG_DATA_HOME"), getenvSpan("HOME"));
    }

    /// Env-injectable variant for tests/embedders (pure given the env
    /// strings; `loadSystemFonts` passes the process env).
    pub fn loadSystemFontsWithEnv(
        self: *FontSystem,
        io: std.Io,
        xdg_data_home: ?[]const u8,
        home: ?[]const u8,
    ) LoadStats {
        var stats = LoadStats{};
        self.scanFontDir(io, "/usr/share/fonts", &stats);
        self.scanFontDir(io, "/usr/local/share/fonts", &stats);
        const user_dirs = resolveUserFontDirs(self.allocator, xdg_data_home, home) catch {
            stats.file_errors += 1;
            return stats;
        };
        defer {
            for (user_dirs) |d| self.allocator.free(d);
            self.allocator.free(user_dirs);
        }
        for (user_dirs) |dir| {
            self.scanFontDir(io, dir, &stats);
        }
        // Keep derived state exact after bulk inserts.
        self.rebuildMonospaceIds() catch {
            stats.file_errors += 1;
        };
        self.clearMatchesCache();
        return stats;
    }

    fn scanFontDir(self: *FontSystem, io: std.Io, dir_path: []const u8, stats: *LoadStats) void {
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            stats.dirs_missing += 1;
            return;
        };
        defer dir.close(io);
        stats.dirs_scanned += 1;
        var walker = dir.walk(self.allocator) catch {
            stats.file_errors += 1;
            return;
        };
        defer walker.deinit();
        // M4: walker errors must be counted, not mistaken for clean EOF.
        while (true) {
            const entry_opt = walker.next(io) catch {
                stats.file_errors += 1;
                break;
            };
            const entry = entry_opt orelse break;
            if (entry.kind != .file) continue;
            if (!hasFontExtension(entry.basename)) continue;
            stats.files_seen += 1;
            self.addScannedFile(dir_path, entry.path, stats);
        }
    }

    fn addScannedFile(self: *FontSystem, dir_path: []const u8, rel_path: []const u8, stats: *LoadStats) void {
        const full = std.fs.path.join(self.allocator, &.{ dir_path, rel_path }) catch {
            stats.file_errors += 1;
            return;
        };
        defer self.allocator.free(full);
        const stem = std.fs.path.stem(rel_path);
        const families = [_][]const u8{stem};
        // Weight/style/mono are best-effort filename guesses; real values
        // come from parsing the file at load time (see `font.zig`).
        const mono = std.mem.containsAtLeast(u8, stem, 1, "Mono");
        // NOTE: `_ =` because benches/tests are the first callers to reach
        // this path; ignoring the returned FontId keeps the scan best-effort.
        _ = self.db.addFace(full, 0, &families, stem, WEIGHT_NORMAL, .normal, .normal, mono) catch {
            stats.file_errors += 1;
            return;
        };
        stats.faces_added += 1;
    }
};

fn hasFontExtension(basename: []const u8) bool {
    const ext = std.fs.path.extension(basename);
    if (std.ascii.eqlIgnoreCase(ext, ".ttf")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".otf")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".ttc")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".otc")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".woff")) return true;
    if (std.ascii.eqlIgnoreCase(ext, ".woff2")) return true;
    return false;
}

/// Process-env lookup without hidden globals in pure code paths: returns the
/// env value span or null when unlinked/empty/missing. Pure callers pass
/// explicit strings to `resolveUserFontDirs` instead.
fn getenvSpan(name: [*:0]const u8) ?[]const u8 {
    if (!builtin.link_libc) return null;
    const raw = std.c.getenv(name) orelse return null;
    const s = std.mem.span(raw);
    if (s.len == 0) return null;
    return s;
}

/// User font dirs from XDG/HOME env (M4, pure for tests).
/// Returns owned strings (caller frees each + the slice):
/// - `$XDG_DATA_HOME/fonts` when set, else `$HOME/.local/share/fonts`
/// - plus legacy `$HOME/.fonts`
/// Empty inputs yield an empty slice. Never returns hardcoded `/home/*`.
pub fn resolveUserFontDirs(
    allocator: std.mem.Allocator,
    xdg_data_home: ?[]const u8,
    home: ?[]const u8,
) std.mem.Allocator.Error![][]u8 {
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |d| allocator.free(d);
        list.deinit(allocator);
    }
    const xdg = if (xdg_data_home) |v| (if (v.len > 0) v else null) else null;
    const h = if (home) |v| (if (v.len > 0) v else null) else null;
    if (xdg) |x| {
        const p = try std.fs.path.join(allocator, &.{ x, "fonts" });
        try list.append(allocator, p);
    } else if (h) |home_dir| {
        const p = try std.fs.path.join(allocator, &.{ home_dir, ".local/share/fonts" });
        try list.append(allocator, p);
    }
    if (h) |home_dir| {
        const p = try std.fs.path.join(allocator, &.{ home_dir, ".fonts" });
        try list.append(allocator, p);
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Locale helpers.
// ---------------------------------------------------------------------------

/// Normalize "en_US.UTF-8" / "en_US@euro" -> "en-US".
pub fn normalizeLocale(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var end = raw.len;
    for (raw, 0..) |c, i| {
        if (c == '.' or c == '@') {
            end = i;
            break;
        }
    }
    const trimmed = if (end == 0) "en-US" else raw[0..end];
    const out = try allocator.dupe(u8, trimmed);
    for (out) |*c| {
        if (c.* == '_') c.* = '-';
    }
    if (out.len == 0) {
        allocator.free(out);
        return allocator.dupe(u8, FALLBACK_LOCALE);
    }
    return out;
}

/// Host locale selection from `LC_ALL`/`LANG` values, or "en-US".
///
/// Pure function so library code never reads the process environment
/// directly (no hidden globals; explicit allocators only). App code that
/// owns a `std.process.Init` passes its values in:
/// `init.environ.getAlloc(gpa, "LC_ALL")` / `getAlloc(gpa, "LANG")`.
/// `LC_ALL` wins when set and non-empty; empty values and bare
/// `"C"`/`"POSIX"` are skipped; anything else is normalized.
/// Pass `null` for a missing variable.
pub fn systemLocaleFromEnv(
    allocator: std.mem.Allocator,
    lang: ?[]const u8,
    lc_all: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const vars = [_]?[]const u8{ lc_all, lang };
    for (vars) |maybe| {
        const raw = maybe orelse continue;
        if (raw.len == 0) continue;
        // "C"/"POSIX" carry no language; keep looking.
        if (std.mem.eql(u8, raw, "C") or std.mem.eql(u8, raw, "POSIX")) continue;
        return normalizeLocale(allocator, raw);
    }
    return allocator.dupe(u8, FALLBACK_LOCALE);
}

/// Default locale when no environment values are available ("en-US").
pub fn defaultLocale(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return allocator.dupe(u8, FALLBACK_LOCALE);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "font match key ordering matches rust derived ord" {
    const t = std.testing;
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    defer db.deinit();
    const plain = try db.addFace("/a.ttf", 0, &.{"Test"}, "Test-Regular", 400, .normal, .normal, false);
    const emoji = try db.addFace("/e.ttf", 0, &.{"Test"}, "Noto Color Emoji", 400, .normal, .normal, false);
    const attrs = AttrsForMatch{ .family = .{ .name = "Test" } };
    const kp = FontMatchKey.init(attrs, db.face(plain).?);
    const ke = FontMatchKey.init(attrs, db.face(emoji).?);
    try t.expect(!ke.not_emoji);
    try t.expect(kp.not_emoji);
    // Rust derived-Ord quirk: `false < true`, so the emoji key sorts
    // FIRST at equal diffs. Ported verbatim; see `lessThan` NOTE.
    try t.expect(ke.lessThan(kp));
    try t.expect(!kp.lessThan(ke));

    // Field order dominates: not_emoji is compared before weight diff,
    // so the emoji key (diff 0) still sorts before bold (diff 300).
    const bold = try db.addFace("/b.ttf", 0, &.{"Test"}, "Test-Bold", 700, .normal, .normal, false);
    const kb = FontMatchKey.init(attrs, db.face(bold).?);
    try t.expect(ke.lessThan(kb));

    // Style diff table: italic/oblique swap costs 1, normal mismatch 2.
    try t.expectEqual(@as(u8, 0), styleDiff(.italic, .italic));
    try t.expectEqual(@as(u8, 1), styleDiff(.italic, .oblique));
    try t.expectEqual(@as(u8, 1), styleDiff(.oblique, .italic));
    try t.expectEqual(@as(u8, 2), styleDiff(.normal, .italic));
    try t.expectEqual(@as(u8, 2), styleDiff(.italic, .normal));
}

test "face query picks closest weight and style" {
    const t = std.testing;
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    defer db.deinit();
    _ = try db.addFace("/r.ttf", 0, &.{"Q"}, "Q-Regular", 400, .normal, .normal, false);
    const bold_id = try db.addFace("/b.ttf", 0, &.{"Q"}, "Q-Bold", 700, .normal, .normal, false);
    const got = db.query(.{ .name = "Q" }, 700, .normal, .normal);
    try t.expectEqual(@as(?FontId, bold_id), got);
    try t.expect(db.query(.{ .name = "Missing" }, 400, .normal, .normal) == null);
    // Style diff: italic request prefers the italic face.
    _ = try db.addFace("/i.ttf", 0, &.{"S"}, "S-Italic", 400, .normal, .italic, false);
    _ = try db.addFace("/n.ttf", 0, &.{"S"}, "S-Regular", 400, .normal, .normal, false);
    const picked = db.query(.{ .name = "S" }, 400, .normal, .italic);
    try t.expect(picked != null);
    try t.expectEqualStrings("S-Italic", db.face(picked.?).?.post_script_name);
}

test "get font matches sorts and moves query to front" {
    const t = std.testing;
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    const rid = try db.addFace("/r.ttf", 0, &.{"Fam"}, "Fam-Regular", 400, .normal, .normal, false);
    const bid = try db.addFace("/b.ttf", 0, &.{"Fam"}, "Fam-Bold", 700, .normal, .normal, false);
    _ = try db.addFace("/e.ttf", 0, &.{"Fam"}, "Fam Emoji", 400, .normal, .normal, false);
    var sys = try FontSystem.initWithDb(alloc, db, "en-US");
    defer sys.deinit();

    const attrs = AttrsForMatch{ .family = .{ .name = "Fam" }, .weight = 700 };
    const matches = try sys.getFontMatches(attrs);
    try t.expect(matches.len >= 3);
    // Query hit (bold) moves to front even though sort already favors it.
    try t.expectEqual(bid, matches[0].id);
    // Raw sort order after the moved query hit: emoji (not_emoji=false)
    // before regular at equal weight diff (Rust derived-Ord quirk).
    try t.expectEqual(rid, matches[2].id);
    var emoji_pos: ?usize = null;
    var regular_pos: ?usize = null;
    for (matches, 0..) |k, i| {
        if (k.id == rid) regular_pos = i;
        if (std.mem.containsAtLeast(u8, sys.db.face(k.id).?.post_script_name, 1, "Emoji")) emoji_pos = i;
    }
    try t.expect(regular_pos != null and emoji_pos != null);
    try t.expect(emoji_pos.? < regular_pos.?);
    // Cached second call returns the same backing slice.
    const again = try sys.getFontMatches(attrs);
    try t.expectEqual(matches.ptr, again.ptr);
    try t.expectEqual(@as(usize, 1), sys.matchesCacheSize());
}

test "locale normalize and env selection fallback" {
    const t = std.testing;
    const alloc = t.allocator;
    const a = try normalizeLocale(alloc, "en_US.UTF-8");
    defer alloc.free(a);
    try t.expectEqualStrings("en-US", a);
    const b = try normalizeLocale(alloc, "zh_HK@euro");
    defer alloc.free(b);
    try t.expectEqualStrings("zh-HK", b);
    // LC_ALL wins over LANG; C/POSIX/empty fall through to en-US.
    const c = try systemLocaleFromEnv(alloc, "fr_FR.UTF-8", "de_DE.UTF-8");
    defer alloc.free(c);
    try t.expectEqualStrings("de-DE", c);
    const d = try systemLocaleFromEnv(alloc, "C", null);
    defer alloc.free(d);
    try t.expectEqualStrings("en-US", d);
    const e = try systemLocaleFromEnv(alloc, null, null);
    defer alloc.free(e);
    try t.expectEqualStrings("en-US", e);
    const f = try systemLocaleFromEnv(alloc, "", "POSIX");
    defer alloc.free(f);
    try t.expectEqualStrings("en-US", f);
}

test "codepoint support cache caps and hits" {
    const t = std.testing;
    const alloc = t.allocator;
    var sup = CodepointSupport.init();
    defer sup.deinit(alloc);
    const font_cps = [_]u32{ 65, 66, 67 };
    try t.expect(try sup.hasCodepoint(alloc, &font_cps, 65));
    try t.expect(try sup.hasCodepoint(alloc, &font_cps, 65)); // cached hit
    try t.expect(!try sup.hasCodepoint(alloc, &font_cps, 90));
    try t.expect(!try sup.hasCodepoint(alloc, &font_cps, 90)); // cached miss
    try t.expectEqual(@as(usize, 1), sup.supported.items.len);
    try t.expectEqual(@as(usize, 1), sup.not_supported.items.len);
}

test "db mut clears matches cache" {
    const t = std.testing;
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    _ = try db.addFace("/r.ttf", 0, &.{"Fam"}, "Fam-Regular", 400, .normal, .normal, false);
    var sys = try FontSystem.initWithDb(alloc, db, "en-US");
    defer sys.deinit();
    _ = try sys.getFontMatches(.{ .family = .{ .name = "Fam" } });
    try t.expectEqual(@as(usize, 1), sys.matchesCacheSize());
    _ = sys.dbMut();
    try t.expectEqual(@as(usize, 0), sys.matchesCacheSize());
}

fn addFaceOomHelper(allocator: std.mem.Allocator) !void {
    var db = try FontDb.init(allocator);
    defer db.deinit();
    _ = try db.addFace("/a.ttf", 0, &.{ "FamA", "FamB" }, "Post", 400, .normal, .normal, false);
}

test "addFace OOM frees only initialized slots (C4)" {
    // Exercises every allocation-failure point in init+addFace; the fixed
    // errdefer frees [0..initialized] so no uninitialized slot is freed
    // and no leak remains.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addFaceOomHelper, .{});
}

fn getFontMatchesOomHelper(allocator: std.mem.Allocator) !void {
    var db_opt: ?FontDb = try FontDb.init(allocator);
    errdefer if (db_opt) |*d| d.deinit();
    _ = try db_opt.?.addFace("/r.ttf", 0, &.{"Fam"}, "Fam-Regular", 400, .normal, .normal, false);
    const db = db_opt.?;
    db_opt = null;
    var sys = try FontSystem.initWithDb(allocator, db, "en-US");
    defer sys.deinit();
    _ = try sys.getFontMatches(.{ .family = .{ .name = "Fam" } });
}

test "getFontMatches OOM removes entry before freeing key (C3)" {
    // The errdefer copies the key, removes by value, then frees; every
    // failure point must leave no leak and no use-after-free (caught as
    // MemoryLeakDetected / crash under the failing allocator).
    try std.testing.checkAllAllocationFailures(std.testing.allocator, getFontMatchesOomHelper, .{});
}

test "generic families resolve via configured defaults (M1)" {
    const t = std.testing;
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    defer db.deinit();
    // Default sans is "Open Sans", serif is "DejaVu Serif".
    _ = try db.addFace("/sans.ttf", 0, &.{"Open Sans"}, "OpenSans-Regular", 400, .normal, .normal, false);
    _ = try db.addFace("/other.ttf", 0, &.{"Other"}, "Other-Regular", 400, .normal, .normal, false);
    _ = try db.addFace("/serif.ttf", 0, &.{"DejaVu Serif"}, "DejaVuSerif-Regular", 400, .normal, .normal, false);
    const sans_hit = db.query(.sans_serif, 400, .normal, .normal);
    try t.expect(sans_hit != null);
    try t.expectEqualStrings("OpenSans-Regular", db.face(sans_hit.?).?.post_script_name);
    const serif_hit = db.query(.serif, 400, .normal, .normal);
    try t.expect(serif_hit != null);
    try t.expectEqualStrings("DejaVuSerif-Regular", db.face(serif_hit.?).?.post_script_name);
    // Unknown named family still misses (generic must not match-all).
    try t.expect(db.query(.{ .name = "Missing" }, 400, .normal, .normal) == null);
    // Custom default retargets the generic.
    try db.setSansFamily("Other");
    const retarget = db.query(.sans_serif, 400, .normal, .normal);
    try t.expect(retarget != null);
    try t.expectEqualStrings("Other-Regular", db.face(retarget.?).?.post_script_name);
}

test "variable weight match covers wght range (M2)" {
    const t = std.testing;
    try t.expect(!variableWeightMatch(600, 400, null, null));
    try t.expect(!variableWeightMatch(400, 400, 100, 900));
    try t.expect(variableWeightMatch(600, 400, 100, 900));
    try t.expect(!variableWeightMatch(50, 400, 100, 900));
    try t.expect(!variableWeightMatch(950, 400, 100, 900));
    const alloc = t.allocator;
    var db = try FontDb.init(alloc);
    defer db.deinit();
    const vid = try db.addFace("/v.ttf", 0, &.{"V"}, "V-Regular", 400, .normal, .normal, false);
    try t.expect(db.setVariableWghtRange(vid, 100, 900));
    const attrs = AttrsForMatch{ .family = .{ .name = "V" }, .weight = 600 };
    const key = FontMatchKey.init(attrs, db.face(vid).?);
    try t.expectEqual(@as(u16, 200), key.font_weight_diff);
    try t.expect(key.variable_weight_match);
    const plain = FontMatchKey.init(.{ .family = .{ .name = "V" } }, db.face(vid).?);
    try t.expect(!plain.variable_weight_match);
}

test "user font dirs use XDG/HOME, never hardcoded (M4)" {
    const t = std.testing;
    const alloc = t.allocator;
    // XDG set: XDG/fonts + HOME/.fonts.
    {
        const dirs = try resolveUserFontDirs(alloc, "/tmp/xdg", "/home/user");
        defer {
            for (dirs) |d| alloc.free(d);
            alloc.free(dirs);
        }
        try t.expectEqual(@as(usize, 2), dirs.len);
        try t.expectEqualStrings("/tmp/xdg/fonts", dirs[0]);
        try t.expectEqualStrings("/home/user/.fonts", dirs[1]);
        for (dirs) |d| try t.expect(std.mem.indexOf(u8, d, "/home/addo") == null);
    }
    // XDG unset: HOME/.local/share/fonts + HOME/.fonts.
    {
        const dirs = try resolveUserFontDirs(alloc, null, "/home/user");
        defer {
            for (dirs) |d| alloc.free(d);
            alloc.free(dirs);
        }
        try t.expectEqual(@as(usize, 2), dirs.len);
        try t.expectEqualStrings("/home/user/.local/share/fonts", dirs[0]);
        try t.expectEqualStrings("/home/user/.fonts", dirs[1]);
    }
    // No env: no user dirs.
    {
        const dirs = try resolveUserFontDirs(alloc, null, null);
        defer alloc.free(dirs);
        try t.expectEqual(@as(usize, 0), dirs.len);
    }
    // Empty strings count as unset.
    {
        const dirs = try resolveUserFontDirs(alloc, "", "");
        defer alloc.free(dirs);
        try t.expectEqual(@as(usize, 0), dirs.len);
    }
}
