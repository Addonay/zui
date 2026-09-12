//! Shaping support for autohinting.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/shape.rs` (BestEffort mode,
//! which the pinned vello/glifo build enables) plus the minimal `GSUB`
//! reader it needs: script/feature/lookup lists, coverage tables, single,
//! multiple, alternate, ligature and reverse substitutions, and the
//! contextual/chain-contextual lookup traversal used for style coverage.
//!
//! Shaping only affects glyph style classification and the glyphs chosen for
//! metrics; outline hinting itself never shapes. Parsing failures are
//! swallowed exactly like upstream's `.ok()` filters, so a malformed table
//! simply contributes no coverage.

const std = @import("std");
const font_mod = @import("../font.zig");
const sfnt = @import("../tables/sfnt.zig");
const styles = @import("styles.zig");

pub const ShaperMode = enum { nominal, best_effort };

/// To prevent infinite recursion in contextual lookups (matches HarfBuzz).
const max_nesting_depth: usize = 64;

pub const ShapedGlyph = struct {
    id: u32,
    /// Vertical adjustment from GPOS; always zero in this port because the
    /// subset does not apply positioning.
    y_offset: i32 = 0,
};

/// Container for the result of shaping a cluster.
pub const ShapedCluster = std.ArrayListUnmanaged(ShapedGlyph);

pub const ShaperCoverageKind = enum {
    /// Shaper coverage that traverses a specific script.
    script,
    /// Shaper coverage that also includes the `Dflt` script.
    default,
};

/// Bit set of already-visited lookup indices.
pub const VisitedLookupSet = struct {
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, lookup_count: u16) !VisitedLookupSet {
        const len = (@as(usize, lookup_count) + 7) / 8;
        const bytes = try allocator.alloc(u8, len);
        @memset(bytes, 0);
        return .{ .bytes = bytes };
    }

    pub fn deinit(self: *VisitedLookupSet, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = .{ .bytes = &.{} };
    }

    /// Follows `HashSet::insert`: true when the lookup was not present.
    pub fn insert(self: *VisitedLookupSet, lookup_index: u16) bool {
        const byte_ix = @as(usize, lookup_index) / 8;
        const bit_mask: u8 = @as(u8, 1) << @intCast(lookup_index % 8);
        if (byte_ix < self.bytes.len) {
            if (self.bytes[byte_ix] & bit_mask == 0) {
                self.bytes[byte_ix] |= bit_mask;
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *VisitedLookupSet) void {
        @memset(self.bytes, 0);
    }
};

pub const Shaper = struct {
    font: font_mod.Font,
    mode: ShaperMode,
    cmap: font_mod.Charmap,
    gsub: ?[]const u8,

    pub fn init(font: font_mod.Font, mode: ShaperMode) Shaper {
        const gsub = if (mode == .best_effort) font.face.table(sfnt.tag_gsub) else null;
        return .{
            .font = font,
            .mode = mode,
            .cmap = font.charmap(),
            .gsub = gsub,
        };
    }

    pub fn charmap(self: *const Shaper) font_mod.Charmap {
        return self.cmap;
    }

    pub fn lookupCount(self: *const Shaper) u16 {
        const gsub = self.gsub orelse return 0;
        return lookupListCount(gsub) orelse 0;
    }

    pub fn clusterShaper(self: *const Shaper, style: *const styles.StyleClass) ClusterShaper {
        if (self.mode == .best_effort) {
            if (style.feature) |feature_tag| {
                if (self.gsub) |gsub| {
                    if (resolveFeature(gsub, style.script.tag, feature_tag)) |feature| {
                        return .{
                            .shaper = self,
                            .gsub = gsub,
                            .kind = .{ .single_feature = feature },
                        };
                    }
                }
            }
        }
        return .{ .shaper = self, .gsub = null, .kind = .nominal };
    }

    /// Uses layout tables to compute coverage for the given style.
    ///
    /// Returns true if any glyph styles were updated for this style.
    pub fn computeCoverage(
        self: *const Shaper,
        style: *const styles.StyleClass,
        coverage_kind: ShaperCoverageKind,
        glyph_styles: []styles.GlyphStyle,
        visited_set: *VisitedLookupSet,
    ) bool {
        const gsub = self.gsub orelse return false;
        const script_list_base = scriptListOffset(gsub) orelse return false;
        const feature_list_base = featureListOffset(gsub) orelse return false;
        const lookup_list_base = lookupListOffset(gsub) orelse return false;

        var script_tags: [3]?[4]u8 = .{ null, null, null };
        const unicode_tags = ScriptTags.fromUnicode(style.script.tag);
        for (unicode_tags.slice(), 0..) |tag, ix| script_tags[ix] = tag;
        // FreeType's default-script handling.
        const default_script: [4]u8 = .{ 'D', 'F', 'L', 'T' };
        if (coverage_kind == .default) {
            if (script_tags[0] == null) {
                script_tags[0] = default_script;
            } else if (script_tags[1] == null) {
                script_tags[1] = default_script;
            } else if (!std.mem.eql(u8, &script_tags[1].?, &default_script)) {
                script_tags[2] = default_script;
            }
        } else {
            // Non-standard script tags used for special purposes.
            const khms: [4]u8 = .{ 'K', 'h', 'm', 's' };
            const latb: [4]u8 = .{ 'L', 'a', 't', 'b' };
            const latp: [4]u8 = .{ 'L', 'a', 't', 'p' };
            if (script_tags[0]) |tag| {
                if (std.mem.eql(u8, &tag, &khms) or
                    std.mem.eql(u8, &tag, &latb) or
                    std.mem.eql(u8, &tag, &latp))
                {
                    return false;
                }
            }
        }

        var handler = GsubHandler{
            .gsub = gsub,
            .lookup_list_base = lookup_list_base,
            .charmap = self.cmap,
            .style = style,
            .glyph_styles = glyph_styles,
            .need_blue_substs = style.feature != null,
            .min_gid = glyph_styles.len,
            .max_gid = 0,
            .lookup_depth = 0,
            .visited_set = visited_set,
        };

        for (script_tags) |maybe_tag| {
            const tag = maybe_tag orelse continue;
            const script_base = scriptIndexForTag(gsub, script_list_base, tag) orelse continue;
            // All language systems for each script, then the default one.
            const lang_sys_count = u16At(gsub, script_base + 2) orelse continue;
            var lang_ix: usize = 0;
            while (lang_ix < lang_sys_count) : (lang_ix += 1) {
                const record = script_base + 4 + lang_ix * 6;
                const lang_base = offsetAt(gsub, record + 4, script_base) orelse continue;
                handler.processLangSys(gsub, lang_base, feature_list_base);
            }
            if (u16At(gsub, script_base)) |default_off| {
                if (default_off != 0) {
                    if (script_base + default_off < gsub.len) {
                        handler.processLangSys(gsub, script_base + default_off, feature_list_base);
                    }
                }
            }
        }
        if (handler.finish()) |range| {
            var result = false;
            for (glyph_styles[range.start..range.end]) |*glyph_style| {
                result = glyph_style.maybeAssignGsubOutputStyle(style) or result;
            }
            return result;
        }
        return false;
    }
};

pub const ClusterShaper = struct {
    shaper: *const Shaper,
    gsub: ?[]const u8,
    kind: Kind,

    const Kind = union(enum) {
        nominal,
        single_feature: FeatureRef,
    };

    const FeatureRef = struct {
        feature_base: usize,
        lookup_list_base: usize,
    };

    /// Shapes `input` into `output`, mapping characters to glyphs and
    /// applying single substitutions for feature styles.
    pub fn shape(
        self: *ClusterShaper,
        allocator: std.mem.Allocator,
        input: []const u8,
        output: *ShapedCluster,
    ) !void {
        output.clearRetainingCapacity();
        var view = std.unicode.Utf8View.initUnchecked(input);
        var iter = view.iterator();
        while (iter.nextCodepoint()) |ch| {
            try output.append(allocator, .{
                .id = self.shaper.cmap.map(ch) orelse 0,
            });
        }
        switch (self.kind) {
            .nominal => {
                // In nominal mode, reject clusters with multiple glyphs.
                if (self.shaper.mode == .nominal and output.items.len > 1) {
                    output.clearRetainingCapacity();
                }
            },
            .single_feature => |feature| {
                const gsub = self.gsub.?;
                var did_subst = false;
                const lookup_count = u16At(gsub, feature.feature_base + 2) orelse 0;
                var lookup_ix: usize = 0;
                while (lookup_ix < lookup_count) : (lookup_ix += 1) {
                    const lookup_index = u16At(gsub, feature.feature_base + 4 + lookup_ix * 2) orelse continue;
                    var glyph_ix: usize = 0;
                    while (glyph_ix < output.items.len) : (glyph_ix += 1) {
                        did_subst = self.applyLookup(
                            gsub,
                            feature.lookup_list_base,
                            lookup_index,
                            output,
                            glyph_ix,
                            0,
                        ) or did_subst;
                    }
                }
                // Reject clusters that were not modified by the feature.
                if (!did_subst) output.clearRetainingCapacity();
            },
        }
    }

    fn applyLookup(
        self: *ClusterShaper,
        gsub: []const u8,
        lookup_list_base: usize,
        lookup_index: u16,
        cluster: *ShapedCluster,
        glyph_ix: usize,
        nesting_depth: usize,
    ) bool {
        _ = self;
        if (nesting_depth > max_nesting_depth) return false;
        if (glyph_ix >= cluster.items.len) return false;
        const glyph = &cluster.items[glyph_ix];
        const lookup_base = lookupOffset(gsub, lookup_list_base, lookup_index) orelse return false;
        const lookup_type = u16At(gsub, lookup_base) orelse return false;
        const subtable_count = u16At(gsub, lookup_base + 4) orelse return false;
        var sub_ix: usize = 0;
        while (sub_ix < subtable_count) : (sub_ix += 1) {
            const sub_off = u16At(gsub, lookup_base + 6 + sub_ix * 2) orelse continue;
            if (sub_off == 0) continue;
            const raw_base = lookup_base + sub_off;
            if (raw_base >= gsub.len) continue;
            var effective_type = lookup_type;
            var sub_base = raw_base;
            if (lookup_type == 7) {
                // Extension: resolve to the inner subtable.
                if (u16At(gsub, raw_base) != 1) continue;
                effective_type = u16At(gsub, raw_base + 2) orelse continue;
                const ext_off = u32At(gsub, raw_base + 4) orelse continue;
                const off: usize = @intCast(ext_off);
                sub_base = raw_base + off;
                if (sub_base >= gsub.len) continue;
            }
            // Only single substitutions are applied by the cluster shaper.
            if (effective_type != 1) continue;
            if (singleSubstApply(gsub, sub_base, glyph)) return true;
        }
        return false;
    }
};

// ------------------------------------------------------------- GSUB handler

const GsubHandler = struct {
    gsub: []const u8,
    lookup_list_base: usize,
    charmap: font_mod.Charmap,
    style: *const styles.StyleClass,
    glyph_styles: []styles.GlyphStyle,
    need_blue_substs: bool,
    min_gid: usize,
    max_gid: usize,
    lookup_depth: usize,
    visited_set: *VisitedLookupSet,

    fn processLangSys(
        self: *GsubHandler,
        gsub: []const u8,
        lang_base: usize,
        feature_list_base: usize,
    ) void {
        const count = u16At(gsub, lang_base + 4) orelse return;
        var ix: usize = 0;
        while (ix < count) : (ix += 1) {
            const feature_ix = u16At(gsub, lang_base + 6 + ix * 2) orelse return;
            const record = feature_list_base + 2 + @as(usize, feature_ix) * 6;
            const feature_tag = tagAt(gsub, record) orelse continue;
            // If the style has a feature tag, only that feature is handled;
            // otherwise all of them are.
            if (self.style.feature) |want| {
                if (!std.mem.eql(u8, &want, &feature_tag)) continue;
            }
            const feature_off = u16At(gsub, record + 4) orelse continue;
            if (feature_off == 0) continue;
            // `featureOffset` is relative to the beginning of FeatureList.
            const feature_base = feature_list_base + feature_off;
            if (feature_base + 4 > gsub.len) continue;
            const lookup_count = u16At(gsub, feature_base + 2) orelse continue;
            var lookup_ix: usize = 0;
            while (lookup_ix < lookup_count) : (lookup_ix += 1) {
                const lookup_index = u16At(gsub, feature_base + 4 + lookup_ix * 2) orelse continue;
                self.processLookup(lookup_index) catch {};
            }
        }
    }

    fn processLookup(self: *GsubHandler, lookup_index: u16) !void {
        if (self.lookup_depth == max_nesting_depth) return error.ExceededMaxDepth;
        if (!self.visited_set.insert(lookup_index)) return;
        self.lookup_depth += 1;
        defer self.lookup_depth -= 1;
        try self.processLookupInner(lookup_index);
    }

    fn processLookupInner(self: *GsubHandler, lookup_index: u16) !void {
        const gsub = self.gsub;
        const lookup_base = lookupOffset(gsub, self.lookup_list_base, lookup_index) orelse return;
        const lookup_type = u16At(gsub, lookup_base) orelse return;
        const subtable_count = u16At(gsub, lookup_base + 4) orelse return;
        if (subtable_count == 0) return;
        // Resolve extension lookups to their effective type, scanning until
        // one resolves (read-fonts does the same).
        var effective_type = lookup_type;
        if (lookup_type == 7) {
            effective_type = 0;
            var sub_ix: usize = 0;
            while (sub_ix < subtable_count) : (sub_ix += 1) {
                const sub_off = u16At(gsub, lookup_base + 6 + sub_ix * 2) orelse continue;
                if (sub_off == 0) continue;
                const raw_base = lookup_base + sub_off;
                if (u16At(gsub, raw_base) != 1) continue;
                effective_type = u16At(gsub, raw_base + 2) orelse continue;
                break;
            }
            if (effective_type == 0) return;
        }
        if (effective_type > 8) return;
        var sub_ix: usize = 0;
        while (sub_ix < subtable_count) : (sub_ix += 1) {
            const sub_off = u16At(gsub, lookup_base + 6 + sub_ix * 2) orelse continue;
            if (sub_off == 0) continue;
            const raw_base = lookup_base + sub_off;
            if (raw_base >= gsub.len) continue;
            var sub_base = raw_base;
            if (lookup_type == 7) {
                if (u16At(gsub, raw_base) != 1) continue;
                const ext_off = u32At(gsub, raw_base + 4) orelse continue;
                sub_base = raw_base + @as(usize, @intCast(ext_off));
                if (sub_base >= gsub.len) continue;
            }
            self.processSubtable(effective_type, sub_base);
        }
    }

    fn processSubtable(self: *GsubHandler, lookup_type: u16, base: usize) void {
        switch (lookup_type) {
            1 => self.captureSingle(base),
            2 => self.captureMultiple(base),
            3 => self.captureAlternate(base),
            4 => self.captureLigature(base),
            5 => self.captureContextual(base),
            6 => self.captureChainContextual(base),
            8 => self.captureReverse(base),
            else => {},
        }
    }

    fn captureSingle(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const format = u16At(gsub, base) orelse return;
        switch (format) {
            1 => {
                const coverage_off = u16At(gsub, base + 2) orelse return;
                const delta = i16At(gsub, base + 4) orelse return;
                var cover = Coverage.init(gsub, base + coverage_off);
                while (cover.next()) |gid| {
                    self.captureGlyph(wrapGid(@as(i32, @intCast(gid)) +% delta));
                }
                if (self.need_blue_substs and self.lookup_depth == 1) {
                    self.checkBlueCoverage(base + coverage_off);
                }
            },
            2 => {
                const count = u16At(gsub, base + 4) orelse return;
                const coverage_off = u16At(gsub, base + 2) orelse return;
                var ix: usize = 0;
                while (ix < count) : (ix += 1) {
                    const gid = u16At(gsub, base + 6 + ix * 2) orelse return;
                    self.captureGlyph(gid);
                }
                if (self.need_blue_substs and self.lookup_depth == 1) {
                    self.checkBlueCoverage(base + coverage_off);
                }
            },
            else => {},
        }
    }

    fn captureMultiple(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const coverage_off = u16At(gsub, base + 2) orelse return;
        const count = u16At(gsub, base + 4) orelse return;
        var ix: usize = 0;
        while (ix < count) : (ix += 1) {
            const seq_off = u16At(gsub, base + 6 + ix * 2) orelse continue;
            const seq_base = base + seq_off;
            const glyph_count = u16At(gsub, seq_base) orelse continue;
            var g_ix: usize = 0;
            while (g_ix < glyph_count) : (g_ix += 1) {
                const gid = u16At(gsub, seq_base + 2 + g_ix * 2) orelse continue;
                self.captureGlyph(gid);
            }
        }
        if (self.need_blue_substs and self.lookup_depth == 1) {
            self.checkBlueCoverage(base + coverage_off);
        }
    }

    fn captureAlternate(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const count = u16At(gsub, base + 4) orelse return;
        var ix: usize = 0;
        while (ix < count) : (ix += 1) {
            const set_off = u16At(gsub, base + 6 + ix * 2) orelse continue;
            const set_base = base + set_off;
            const glyph_count = u16At(gsub, set_base) orelse continue;
            var g_ix: usize = 0;
            while (g_ix < glyph_count) : (g_ix += 1) {
                const gid = u16At(gsub, set_base + 2 + g_ix * 2) orelse continue;
                self.captureGlyph(gid);
            }
        }
    }

    fn captureLigature(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const set_count = u16At(gsub, base + 4) orelse return;
        var set_ix: usize = 0;
        while (set_ix < set_count) : (set_ix += 1) {
            const set_off = u16At(gsub, base + 6 + set_ix * 2) orelse continue;
            const set_base = base + set_off;
            const lig_count = u16At(gsub, set_base) orelse continue;
            var lig_ix: usize = 0;
            while (lig_ix < lig_count) : (lig_ix += 1) {
                const lig_off = u16At(gsub, set_base + 2 + lig_ix * 2) orelse continue;
                const gid = u16At(gsub, set_base + lig_off) orelse continue;
                self.captureGlyph(gid);
            }
        }
    }

    fn captureReverse(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        // Format 1: coverage, backtrack coverage offsets (ignored),
        // lookahead coverage offsets (ignored), glyph count, substitutes.
        const coverage_off = u16At(gsub, base + 2) orelse return;
        const backtrack_count = u16At(gsub, base + 4) orelse return;
        var off = base + 6 + @as(usize, backtrack_count) * 2;
        const lookahead_count = u16At(gsub, off) orelse return;
        off += 2 + @as(usize, lookahead_count) * 2;
        const glyph_count = u16At(gsub, off) orelse return;
        var ix: usize = 0;
        while (ix < glyph_count) : (ix += 1) {
            const gid = u16At(gsub, off + 2 + ix * 2) orelse return;
            self.captureGlyph(gid);
        }
        _ = coverage_off;
    }

    fn captureContextual(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const format = u16At(gsub, base) orelse return;
        switch (format) {
            1 => {
                const set_count = u16At(gsub, base + 4) orelse return;
                var set_ix: usize = 0;
                while (set_ix < set_count) : (set_ix += 1) {
                    const set_off = u16At(gsub, base + 6 + set_ix * 2) orelse continue;
                    if (set_off == 0) continue;
                    const set_base = base + set_off;
                    const rule_count = u16At(gsub, set_base) orelse continue;
                    var rule_ix: usize = 0;
                    while (rule_ix < rule_count) : (rule_ix += 1) {
                        const rule_off = u16At(gsub, set_base + 2 + rule_ix * 2) orelse continue;
                        self.processSequenceRule(set_base + rule_off);
                    }
                }
            },
            2 => {
                const set_count = u16At(gsub, base + 6) orelse return;
                var set_ix: usize = 0;
                while (set_ix < set_count) : (set_ix += 1) {
                    const set_off = u16At(gsub, base + 8 + set_ix * 2) orelse continue;
                    if (set_off == 0) continue;
                    const set_base = base + set_off;
                    const rule_count = u16At(gsub, set_base) orelse continue;
                    var rule_ix: usize = 0;
                    while (rule_ix < rule_count) : (rule_ix += 1) {
                        const rule_off = u16At(gsub, set_base + 2 + rule_ix * 2) orelse continue;
                        self.processSequenceRule(set_base + rule_off);
                    }
                }
            },
            3 => {
                const glyph_count = u16At(gsub, base + 2) orelse return;
                const lookup_count = u16At(gsub, base + 4) orelse return;
                const records = base + 6 + @as(usize, glyph_count) * 2;
                self.processLookupRecords(records, lookup_count);
            },
            else => {},
        }
    }

    fn captureChainContextual(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const format = u16At(gsub, base) orelse return;
        switch (format) {
            1 => {
                const set_count = u16At(gsub, base + 4) orelse return;
                var set_ix: usize = 0;
                while (set_ix < set_count) : (set_ix += 1) {
                    const set_off = u16At(gsub, base + 6 + set_ix * 2) orelse continue;
                    if (set_off == 0) continue;
                    const set_base = base + set_off;
                    const rule_count = u16At(gsub, set_base) orelse continue;
                    var rule_ix: usize = 0;
                    while (rule_ix < rule_count) : (rule_ix += 1) {
                        const rule_off = u16At(gsub, set_base + 2 + rule_ix * 2) orelse continue;
                        self.processChainedSequenceRule(set_base + rule_off);
                    }
                }
            },
            2 => {
                const set_count = u16At(gsub, base + 10) orelse return;
                var set_ix: usize = 0;
                while (set_ix < set_count) : (set_ix += 1) {
                    const set_off = u16At(gsub, base + 12 + set_ix * 2) orelse continue;
                    if (set_off == 0) continue;
                    const set_base = base + set_off;
                    const rule_count = u16At(gsub, set_base) orelse continue;
                    var rule_ix: usize = 0;
                    while (rule_ix < rule_count) : (rule_ix += 1) {
                        const rule_off = u16At(gsub, set_base + 2 + rule_ix * 2) orelse continue;
                        self.processChainedSequenceRule(set_base + rule_off);
                    }
                }
            },
            3 => {
                // Backtrack glyph count, backtrack coverages, input glyph
                // count, input coverages, lookahead glyph count, lookahead
                // coverages, lookup records.
                var off = base + 2;
                const backtrack_count = u16At(gsub, off) orelse return;
                off += 2 + @as(usize, backtrack_count) * 2;
                const input_count = u16At(gsub, off) orelse return;
                off += 2 + @as(usize, input_count) * 2;
                const lookahead_count = u16At(gsub, off) orelse return;
                off += 2 + @as(usize, lookahead_count) * 2;
                const lookup_count = u16At(gsub, off) orelse return;
                self.processLookupRecords(off + 2, lookup_count);
            },
            else => {},
        }
    }

    fn processSequenceRule(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        const glyph_count = u16At(gsub, base) orelse return;
        const lookup_count = u16At(gsub, base + 2) orelse return;
        const records = base + 4 + (if (glyph_count > 0) @as(usize, glyph_count - 1) * 2 else 0);
        self.processLookupRecords(records, lookup_count);
    }

    fn processChainedSequenceRule(self: *GsubHandler, base: usize) void {
        const gsub = self.gsub;
        var off = base;
        const backtrack_count = u16At(gsub, off) orelse return;
        off += 2 + @as(usize, backtrack_count) * 2;
        const input_count = u16At(gsub, off) orelse return;
        off += 2 + (if (input_count > 0) @as(usize, input_count - 1) * 2 else 0);
        const lookahead_count = u16At(gsub, off) orelse return;
        off += 2 + @as(usize, lookahead_count) * 2;
        const lookup_count = u16At(gsub, off) orelse return;
        self.processLookupRecords(off + 2, lookup_count);
    }

    fn processLookupRecords(self: *GsubHandler, records: usize, count: u16) void {
        var ix: usize = 0;
        while (ix < count) : (ix += 1) {
            const lookup_index = u16At(self.gsub, records + 2 + ix * 4) orelse return;
            self.processLookup(lookup_index) catch {};
        }
    }

    /// Finishes processing for this set of GSUB lookups and returns the range
    /// of touched glyphs.
    fn finish(self: *GsubHandler) ?TouchedRange {
        self.visited_set.clear();
        if (self.min_gid > self.max_gid) return null;
        const range = TouchedRange{ .start = self.min_gid, .end = self.max_gid + 1 };
        if (self.need_blue_substs) {
            for (self.glyph_styles[range.start..range.end]) |*glyph| {
                glyph.clearFromGsub();
            }
            return null;
        }
        return range;
    }

    fn checkBlueCoverage(self: *GsubHandler, coverage_base: usize) void {
        var cover = Coverage.init(self.gsub, coverage_base);
        for (self.style.script.blues) |blue| {
            var view = std.unicode.Utf8View.initUnchecked(blue.chars);
            var iter = view.iterator();
            while (iter.nextCodepoint()) |ch| {
                const gid = self.charmap.map(ch) orelse continue;
                if (cover.get(gid) != null) {
                    self.need_blue_substs = false;
                    return;
                }
            }
        }
    }

    fn captureGlyph(self: *GsubHandler, gid: u32) void {
        const ix = @as(usize, gid);
        if (ix < self.glyph_styles.len) {
            self.glyph_styles[ix].setFromGsubOutput();
            self.min_gid = @min(self.min_gid, ix);
            self.max_gid = @max(self.max_gid, ix);
        }
    }
};

const TouchedRange = struct { start: usize, end: usize };

/// Wrapping `gid + delta` cast through `u16` then `u32` (read-fonts does the
/// same for single substitution format 1).
fn wrapGid(value: i32) u32 {
    const truncated: u16 = @truncate(@as(u32, @bitCast(value)));
    return truncated;
}

// ------------------------------------------------------------ GSUB readers

fn u16At(data: []const u8, off: usize) ?u16 {
    if (off + 2 > data.len) return null;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

fn i16At(data: []const u8, off: usize) ?i16 {
    const v = u16At(data, off) orelse return null;
    return @bitCast(v);
}

fn u32At(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

fn tagAt(data: []const u8, off: usize) ?[4]u8 {
    if (off + 4 > data.len) return null;
    return data[off..][0..4].*;
}

fn offsetAt(data: []const u8, off_ix: usize, parent_base: usize) ?usize {
    const rel = u16At(data, off_ix) orelse return null;
    if (rel == 0) return null;
    return parent_base + rel;
}

fn scriptListOffset(gsub: []const u8) ?usize {
    const value = u16At(gsub, 4) orelse return null;
    return value;
}

fn featureListOffset(gsub: []const u8) ?usize {
    const value = u16At(gsub, 6) orelse return null;
    return value;
}

fn lookupListOffset(gsub: []const u8) ?usize {
    const value = u16At(gsub, 8) orelse return null;
    return value;
}

fn lookupListCount(gsub: []const u8) ?u16 {
    const base = lookupListOffset(gsub) orelse return null;
    return u16At(gsub, base);
}

fn lookupOffset(gsub: []const u8, lookup_list_base: usize, lookup_index: u16) ?usize {
    const count = u16At(gsub, lookup_list_base) orelse return null;
    if (lookup_index >= count) return null;
    const rel = u16At(gsub, lookup_list_base + 2 + @as(usize, lookup_index) * 2) orelse return null;
    return lookup_list_base + rel;
}

/// Returns the base offset of the script with the given tag, if present.
fn scriptIndexForTag(gsub: []const u8, script_list_base: usize, tag: [4]u8) ?usize {
    const count = u16At(gsub, script_list_base) orelse return null;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const record = script_list_base + 2 + mid * 6;
        const record_tag = tagAt(gsub, record) orelse return null;
        switch (std.mem.order(u8, &record_tag, &tag)) {
            .eq => {
                const rel = u16At(gsub, record + 4) orelse return null;
                return script_list_base + rel;
            },
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Resolves a feature tag to its `(feature base, lookup list base)` pair.
///
/// Mirrors `ScriptList::select` + `Script::default_lang_sys` +
/// `LangSys::feature_index_for_tag` from read-fonts.
fn resolveFeature(gsub: []const u8, script_tag: [4]u8, feature_tag: [4]u8) ?ClusterShaper.FeatureRef {
    const script_list_base = scriptListOffset(gsub) orelse return null;
    const feature_list_base = featureListOffset(gsub) orelse return null;
    const lookup_list_base = lookupListOffset(gsub) orelse return null;
    // `ScriptTags::select`: try candidate tags, then DFLT / dflt / latn.
    var candidates: [6]?[4]u8 = .{ null, null, null, null, null, null };
    const tags = ScriptTags.fromUnicode(script_tag);
    for (tags.slice(), 0..) |tag, ix| candidates[ix] = tag;
    candidates[3] = .{ 'D', 'F', 'L', 'T' };
    candidates[4] = .{ 'd', 'f', 'l', 't' };
    candidates[5] = .{ 'l', 'a', 't', 'n' };
    var script_base: ?usize = null;
    for (candidates) |maybe_tag| {
        const tag = maybe_tag orelse continue;
        if (scriptIndexForTag(gsub, script_list_base, tag)) |base| {
            script_base = base;
            break;
        }
    }
    const script = script_base orelse return null;
    // Cluster shaping only consults the default language system.
    const default_off = u16At(gsub, script) orelse return null;
    if (default_off == 0) return null;
    const lang_base = script + default_off;
    const count = u16At(gsub, lang_base + 4) orelse return null;
    const feature_count = u16At(gsub, feature_list_base) orelse return null;
    var ix: usize = 0;
    while (ix < count) : (ix += 1) {
        const feature_ix = u16At(gsub, lang_base + 6 + ix * 2) orelse return null;
        if (feature_ix >= feature_count) continue;
        const record = feature_list_base + 2 + @as(usize, feature_ix) * 6;
        const tag = tagAt(gsub, record) orelse continue;
        if (!std.mem.eql(u8, &tag, &feature_tag)) continue;
        const rel = u16At(gsub, record + 4) orelse continue;
        if (rel == 0) continue;
        // `featureOffset` is relative to the beginning of FeatureList.
        if (feature_list_base + rel + 4 > gsub.len) continue;
        return .{ .feature_base = feature_list_base + rel, .lookup_list_base = lookup_list_base };
    }
    return null;
}

/// Port of `read-fonts`'s `ScriptTags::from_unicode`.
pub const ScriptTags = struct {
    tags: [3][4]u8 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
    len: usize = 0,

    pub fn fromUnicode(unicode_script: [4]u8) ScriptTags {
        var result = ScriptTags{};
        if (newTagFromUnicode(unicode_script)) |new_tag| {
            var bytes = new_tag;
            const mym2: [4]u8 = .{ 'm', 'y', 'm', '2' };
            if (!std.mem.eql(u8, &new_tag, &mym2)) {
                bytes[3] = '3';
                result.tags[result.len] = bytes;
                result.len += 1;
            }
            result.tags[result.len] = new_tag;
            result.len += 1;
        }
        result.tags[result.len] = oldTagFromUnicode(unicode_script);
        result.len += 1;
        return result;
    }

    pub fn slice(self: *const ScriptTags) []const [4]u8 {
        return self.tags[0..self.len];
    }
};

fn newTagFromUnicode(unicode_script: [4]u8) ?[4]u8 {
    const mapping = [_]struct { unicode: [4]u8, tag: [4]u8 }{
        .{ .unicode = .{ 'B', 'e', 'n', 'g' }, .tag = .{ 'b', 'n', 'g', '2' } },
        .{ .unicode = .{ 'D', 'e', 'v', 'a' }, .tag = .{ 'd', 'e', 'v', '2' } },
        .{ .unicode = .{ 'G', 'u', 'j', 'r' }, .tag = .{ 'g', 'j', 'r', '2' } },
        .{ .unicode = .{ 'G', 'u', 'r', 'u' }, .tag = .{ 'g', 'u', 'r', '2' } },
        .{ .unicode = .{ 'K', 'n', 'd', 'a' }, .tag = .{ 'k', 'n', 'd', '2' } },
        .{ .unicode = .{ 'M', 'l', 'y', 'm' }, .tag = .{ 'm', 'l', 'm', '2' } },
        .{ .unicode = .{ 'M', 'y', 'm', 'r' }, .tag = .{ 'm', 'y', 'm', '2' } },
        .{ .unicode = .{ 'O', 'r', 'y', 'a' }, .tag = .{ 'o', 'r', 'y', '2' } },
        .{ .unicode = .{ 'T', 'a', 'm', 'l' }, .tag = .{ 't', 'm', 'l', '2' } },
        .{ .unicode = .{ 'T', 'e', 'l', 'u' }, .tag = .{ 't', 'e', 'l', '2' } },
    };
    for (mapping) |entry| {
        if (std.mem.eql(u8, &entry.unicode, &unicode_script)) return entry.tag;
    }
    return null;
}

fn oldTagFromUnicode(unicode_script: [4]u8) [4]u8 {
    var bytes = unicode_script;
    if (std.mem.eql(u8, &bytes, "Zmth")) return .{ 'm', 'a', 't', 'h' };
    if (std.mem.eql(u8, &bytes, "Hira")) return .{ 'k', 'a', 'n', 'a' };
    if (std.mem.eql(u8, &bytes, "Laoo")) return .{ 'l', 'a', 'o', ' ' };
    if (std.mem.eql(u8, &bytes, "Yiii")) return .{ 'y', 'i', ' ', ' ' };
    if (std.mem.eql(u8, &bytes, "Nkoo")) return .{ 'n', 'k', 'o', ' ' };
    if (std.mem.eql(u8, &bytes, "Vaii")) return .{ 'v', 'a', 'i', ' ' };
    bytes[0] = std.ascii.toLower(bytes[0]);
    return bytes;
}

/// Coverage table cursor and membership lookup.
const Coverage = struct {
    data: []const u8,
    base: usize,
    format: u16,
    count: usize,
    /// Format 1 cursor.
    glyph_ix: usize,
    /// Format 2 cursor.
    range_ix: usize,
    range_gid: u32,
    range_end: u32,
    has_range: bool,

    fn init(data: []const u8, base: usize) Coverage {
        const format = u16At(data, base) orelse 0;
        const count: usize = if (format == 1 or format == 2)
            (u16At(data, base + 2) orelse 0)
        else
            0;
        return .{
            .data = data,
            .base = base,
            .format = format,
            .count = count,
            .glyph_ix = 0,
            .range_ix = 0,
            .range_gid = 0,
            .range_end = 0,
            .has_range = false,
        };
    }

    fn get(self: Coverage, gid: u32) ?u16 {
        switch (self.format) {
            1 => {
                var lo: usize = 0;
                var hi: usize = self.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const value = u16At(self.data, self.base + 4 + mid * 2) orelse return null;
                    if (value == gid) return @intCast(mid);
                    if (value < gid) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return null;
            },
            2 => {
                var lo: usize = 0;
                var hi: usize = self.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const record = self.base + 4 + mid * 6;
                    const start = u16At(self.data, record) orelse return null;
                    const end = u16At(self.data, record + 2) orelse return null;
                    if (gid < start) {
                        hi = mid;
                    } else if (gid > end) {
                        lo = mid + 1;
                    } else {
                        const start_index = u16At(self.data, record + 4) orelse return null;
                        return start_index + @as(u16, @intCast(gid - start));
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Iterates every covered glyph in file order.
    fn next(self: *Coverage) ?u32 {
        switch (self.format) {
            1 => {
                if (self.glyph_ix >= self.count) return null;
                const value = u16At(self.data, self.base + 4 + self.glyph_ix * 2) orelse return null;
                self.glyph_ix += 1;
                return value;
            },
            2 => {
                while (true) {
                    if (self.has_range) {
                        if (self.range_gid <= self.range_end) {
                            const value = self.range_gid;
                            self.range_gid += 1;
                            return value;
                        }
                        self.has_range = false;
                    }
                    if (self.range_ix >= self.count) return null;
                    const record = self.base + 4 + self.range_ix * 6;
                    self.range_ix += 1;
                    const start = u16At(self.data, record) orelse return null;
                    const end = u16At(self.data, record + 2) orelse return null;
                    if (start > end) continue;
                    self.range_gid = start;
                    self.range_end = end;
                    self.has_range = true;
                }
            },
            else => return null,
        }
    }
};

/// Applies a single substitution to `glyph`, returning true on success.
fn singleSubstApply(gsub: []const u8, base: usize, glyph: *ShapedGlyph) bool {
    const format = u16At(gsub, base) orelse return false;
    const coverage_off = u16At(gsub, base + 2) orelse return false;
    var cover = Coverage.init(gsub, base + coverage_off);
    switch (format) {
        1 => {
            const delta = i16At(gsub, base + 4) orelse return false;
            if (cover.get(glyph.id) == null) return false;
            glyph.id = wrapGid(@as(i32, @intCast(glyph.id)) +% delta);
            return true;
        },
        2 => {
            const cover_ix = cover.get(glyph.id) orelse return false;
            const gid = u16At(gsub, base + 6 + @as(usize, cover_ix) * 2) orelse return false;
            glyph.id = gid;
            return true;
        },
        else => return false,
    }
}

test "script tags follow read-fonts" {
    const latn = ScriptTags.fromUnicode(.{ 'L', 'a', 't', 'n' });
    try std.testing.expectEqual(@as(usize, 1), latn.len);
    try std.testing.expectEqualSlices(u8, "latn", &latn.slice()[0]);

    const mymr = ScriptTags.fromUnicode(.{ 'M', 'y', 'm', 'r' });
    try std.testing.expectEqual(@as(usize, 2), mymr.len);
    try std.testing.expectEqualSlices(u8, "mym2", &mymr.slice()[0]);
    try std.testing.expectEqualSlices(u8, "mymr", &mymr.slice()[1]);

    const deva = ScriptTags.fromUnicode(.{ 'D', 'e', 'v', 'a' });
    try std.testing.expectEqual(@as(usize, 3), deva.len);
    try std.testing.expectEqualSlices(u8, "dev3", &deva.slice()[0]);
    try std.testing.expectEqualSlices(u8, "dev2", &deva.slice()[1]);
    try std.testing.expectEqualSlices(u8, "deva", &deva.slice()[2]);

    const hira = ScriptTags.fromUnicode(.{ 'H', 'i', 'r', 'a' });
    try std.testing.expectEqualSlices(u8, "kana", &hira.slice()[0]);
}

test "visited lookup set" {
    var set = try VisitedLookupSet.init(std.testing.allocator, 2341);
    defer set.deinit(std.testing.allocator);
    var i: u16 = 0;
    while (i < 2341) : (i += 1) {
        try std.testing.expect(set.insert(i));
        try std.testing.expect(!set.insert(i));
    }
    for (set.bytes[0 .. set.bytes.len - 1]) |byte| try std.testing.expectEqual(@as(u8, 0xFF), byte);
    try std.testing.expectEqual(@as(u8, 0b00011111), set.bytes[set.bytes.len - 1]);
    set.clear();
    try std.testing.expect(set.insert(0));
}
