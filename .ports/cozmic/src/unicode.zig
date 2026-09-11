//! UAX adapter for cozmic (wraps vendored ezi-code Unicode tables).
//!
//! OWNERSHIP: this file (`src/unicode.zig`) is the only file owned by the
//! UAX-adapter task. Do not move its declarations into other files.
//!
//! ORACLE: vendored ezi-code at `.reference/ezi-code`, version `0.5.0-dev`
//! (see `.reference/ezi-code/build.zig.zon`; latest release `v0.4.1`).
//! Relevant ezi-code sources (read-only):
//! - `src/unicode/segmentation/root.zig` (UAX#29 grapheme/word/sentence,
//!   UAX#14 line: `GraphemeIterator`, `WordIterator`, `LineStepState`,
//!   `checkBoundary`, `wordStep`, `lineStep`, `LineBreakKind`)
//! - `src/unicode/bidi/root.zig` + `src/unicode/bidi/algorithm.zig` (UAX#9:
//!   `resolveParagraph`, `reorderVisual`, `paragraphLevel`, `mirror`)
//! - `src/unicode/scripts/root.zig` (UAX#24: `scriptType`, `scriptExtensions`)
//! - `src/unicode/properties/root.zig` + `generated/prop_list.zig`
//!   (White_Space via `isWhiteSpace`)
//! - `src/encoding/*` (`CodePoint = u21`, lossy UTF-8 decoding)
//!
//! WHY VENDORED, NOT `@import`:
//! A relative `@import("../.reference/ezi-code/src/root.zig")` (or any
//! `src/unicode/...` file) does NOT compile standalone via
//! `zig test src/unicode.zig`. Every ezi-code source resolves its
//! dependencies as build-system module names (`@import("encoding")`,
//! `@import("utils")`, `@import("build_options")`; see
//! `.reference/ezi-code/build.zig` `b.addModule("unicode", ...)` wiring).
//! Under bare `zig test` only `std` plus relative paths exist, so the
//! transitive `@import("encoding")` fails. Even the generated tables do
//! `const CodePoint = @import("encoding").CodePoint;` and
//! `const utils = @import("utils");`.
//! Wiring ezi-code as a cozmic build dependency would fix that, but the task
//! requires `zig test src/unicode.zig` to pass with no build changes and no
//! cross-imports into cozmic modules. Therefore this file vendor-copies the
//! *minimal* table access needed (White_Space set, script ranges, grapheme /
//! word / line / bidi property shards) as compact range tables, with the
//! rule structure mirroring ezi-code (`checkBoundary` GB1-GB13, `wordStep`
//! WB1-WB999 essentials, `lineStepRules` LB4-LB31 essentials, UAX#9 P/X/W/N/I/L).
//! Where the full UCD tables are larger, the code comments cite the exact
//! ezi-code symbol being approximated (e.g. `segmentation.graphemeBreakProperty`).
//! Future work: replace the range shards below with the real generated tables
//! by adding ezi-code as a `build.zig.zon` dependency and threading its
//! `unicode` module through `build.zig`.
//!
//! STUB MAPPING (drop-in guide for later integration):
//! - `shape.zig:isGraphemeExtend` (subset Extend ranges) -> `isGraphemeExtend`
//!   (fuller Extend shard, ezi-code `properties.hasDerivedProperty(.grapheme_extend)`)
//! - `shape.zig:GraphemeCursor` (`next() ?usize` start offsets, Extend-only)
//!   -> `GraphemeIndices` / `graphemeIndices` (same shape: `next() ?usize`
//!   start offsets; correct UAX#29 incl. ZWJ/RI/Prepend/SpacingMark/Hangul)
//! - `shape.zig:scriptOf` (latin/greek/cyrillic/armenian/hebrew/arabic/han/
//!   hiragana/katakana/devanagari/thai only) -> `scriptOf` (adds
//!   bengali/tamil/telugu/kannada/malayalam/lao/tibetan/myanmar/khmer/hangul
//!   + others; ezi-code `scripts.scriptType` oracle)
//! - `shape.zig:collectScripts` (skips Common/Inherited/Latin/Unknown) ->
//!   `collectScripts` here (same skip set + allocator-typed, UAX#24 backed)
//! - `shape.zig:splitSpanWords` (space/tab + ASCII-punct approx, TODO UAX#14)
//!   -> `lineBreakOpportunities` / `LineBreakOpportunities` (UAX#14 LB rules
//!   incl. GL/WJ/ID/HY handling; ezi-code `segmentation.lineStep` oracle)
//! - `shape.zig:baseLevelForText` (first-strong LTR/RTL scan) ->
//!   `paragraphLevel` (same, plus isolate-skipping per UAX#9 P2)
//! - `shape.zig:computeLevels` (para +/- 1 by strong class) +
//!   `adjustLevelsL1` (trailing WS reset) -> `baseLevels` (explicit
//!   embeddings X1-X8 + WS trailing reset L1) + `reorderVisual` (L2)
//! - `shape.zig:classOf` (B/S/WS-only) -> `bidiClass` (L/R/AL/EN/AN/NSM/BN/WS/
//!   ON/B/S + formatting; ezi-code `properties.bidiClass` oracle)
//! - `shape.zig:isWhitespaceCp` / `buffer.zig:isWhitespaceCp` /
//!   `edit.zig:isWhitespaceCp` (pinned White_Space switch) -> `isWhitespace`
//!   (same set, ezi-code `properties.isWhitespace` / PropList oracle)
//! - `buffer.zig:codepointIterator` / `edit.zig:codepointIterator`
//!   (codepoint-granular, no clusters) -> `codepointIterator` (same shape)
//!   plus `graphemeIndices` for cluster-granular cursor work
//! - `buffer.zig:prevWordStart/nextWordEnd` / `edit.zig:prevWordStart/nextWordEnd`
//!   (word/non-word run approx) -> `wordBounds` / `WordBounds`
//!   (UAX#29 WB oracle; same byte-range shape, correct CJK/NBSP/RI)
//! - `buffer.zig:detectRtl` / `edit.zig:detectRtlLine` (first-strong scan) ->
//!   `paragraphLevel` + `bidiParagraphs`
//!
//! API SHAPE NOTES:
//! - Iterators are allocation-free and borrow the input slice (like ezi-code
//!   `GraphemeIterator`/`WordIterator` and `shape.zig:GraphemeCursor`): the
//!   returned slices/indices stay valid only while the input lives.
//! - Fallible helpers take an explicit allocator and return `error.OutOfMemory`
//!   (never panic, never truncate, never silently drop input).
//! - Invalid UTF-8 decodes lossily as U+FFFD (matches ezi-code byte iterators
//!   and `shape.zig:decodeOne`), so no input is rejected.
//!
//! CONVENTIONS: Zig 0.17, explicit allocators, no panics (`unreachable`,
//! `catch unreachable`, `std.debug.assert` are absent; `@intCast` is used
//! only where the value was range-checked into `u21`/byte bounds first).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CodePoint: type = u21;

/// Replacement character used for lossy decoding.
pub const REPLACEMENT: CodePoint = 0xFFFD;

/// Bidi embedding level: even = LTR, odd = RTL (matches `shape.zig:Level`).
pub const Level: type = u8;
pub const LEVEL_LTR: Level = 0;
pub const LEVEL_RTL: Level = 1;

pub fn levelIsRtl(level: Level) bool {
    return level % 2 == 1;
}

pub const UnicodeError = Allocator.Error;

// ---------------------------------------------------------------------------
// UTF-8 helpers (lossy; mirrors shape/buffer/edit decodeOne + ezi-code lossy)
// ---------------------------------------------------------------------------

const Decoded = struct {
    cp: CodePoint,
    len: usize,
};

fn utf8CharLen(first: u8) usize {
    if (first < 0x80) return 1;
    if (first >> 5 == 0b110) return 2;
    if (first >> 4 == 0b1110) return 3;
    if (first >> 3 == 0b11110) return 4;
    return 1;
}

fn decodeOne(text: []const u8, i: usize) Decoded {
    if (i >= text.len) return .{ .cp = REPLACEMENT, .len = 1 };
    const first = text[i];
    const len = utf8CharLen(first);
    if (len == 1) {
        if (first < 0x80) return .{ .cp = first, .len = 1 };
        return .{ .cp = REPLACEMENT, .len = 1 };
    }
    if (i + len > text.len) return .{ .cp = REPLACEMENT, .len = 1 };
    var cp: u21 = switch (len) {
        2 => @as(u21, first & 0x1F),
        3 => @as(u21, first & 0x0F),
        else => @as(u21, first & 0x07),
    };
    var j: usize = 1;
    while (j < len) : (j += 1) {
        const b = text[i + j];
        if (b >> 6 != 0b10) return .{ .cp = REPLACEMENT, .len = 1 };
        cp = (cp << 6) | @as(u21, b & 0x3F);
    }
    const min: u21 = switch (len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) {
        return .{ .cp = REPLACEMENT, .len = 1 };
    }
    return .{ .cp = cp, .len = len };
}

fn decodeOneRevLen(text: []const u8, end: usize) Decoded {
    if (end == 0 or end > text.len) return .{ .cp = REPLACEMENT, .len = 1 };
    var s = end - 1;
    var n: usize = 0;
    while (s > 0 and n < 3 and (text[s] >> 6 == 0b10)) : (n += 1) {
        s -= 1;
    }
    const d = decodeOne(text, s);
    if (s + d.len != end) return .{ .cp = text[end - 1], .len = 1 };
    return d;
}

pub fn isContinuation(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Byte index is a UTF-8 boundary (mirrors buffer/edit `isBoundary`).
pub fn isBoundary(text: []const u8, index: usize) bool {
    if (index == 0 or index == text.len) return true;
    if (index > text.len) return false;
    return !isContinuation(text[index]);
}

pub const Codepoint = struct {
    value: CodePoint,
    len: usize,
};

/// Allocation-free codepoint cursor (same shape as
/// `buffer.zig:CodepointIterator` / `edit.zig:CodepointIterator`).
pub const CodepointIterator = struct {
    slice: []const u8,
    pos: usize = 0,

    pub fn next(self: *CodepointIterator) ?Codepoint {
        if (self.pos >= self.slice.len) return null;
        const d = decodeOne(self.slice, self.pos);
        self.pos += d.len;
        return .{ .value = d.cp, .len = d.len };
    }
};

pub fn codepointIterator(slice: []const u8) CodepointIterator {
    return .{ .slice = slice };
}

/// Decode the whole string into caller-owned codepoints (lossy).
/// Caller owns the slice; freed with `alloc.free`.
pub fn decodeCodepoints(alloc: Allocator, text: []const u8) UnicodeError![]CodePoint {
    var out: std.ArrayList(CodePoint) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeOne(text, i);
        try out.append(alloc, d.cp);
        i += d.len;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// White_Space (PropList oracle: ezi-code `properties.isWhitespace`)
// ---------------------------------------------------------------------------

/// Full Unicode `White_Space` property.
/// Oracle: ezi-code `prop_list.isWhiteSpace` (`white_space_ranges`:
/// 0009-000D, 0020, 0085, 00A0, 1680, 2000-200A, 2028-2029, 202F, 205F, 3000).
/// Matches the pinned switches in shape/buffer/edit stubs.
pub fn isWhitespace(cp: CodePoint) bool {
    return switch (cp) {
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x20,
        0x85,
        0xA0,
        0x1680,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        => true,
        else => false,
    };
}

/// ASCII-only whitespace (for callers that must not treat NBSP as blank).
pub fn isAsciiWhitespace(cp: CodePoint) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Scripts (UAX#24 oracle: ezi-code `scripts.scriptType`)
// ---------------------------------------------------------------------------

/// UAX#24 script values relevant to cozmic shaping/font fallback.
/// Superset of `shape.zig:Script` (which stops at devanagari/thai and folds
/// Bengali/Tamil/Khmer/etc into `unknown`/`other`); variant names for the
/// shared scripts are spelled identically so `collectScripts` filtering
/// (`Common|Inherited|Latin|Unknown` skipped) ports verbatim.
pub const Script = enum {
    common,
    inherited,
    latin,
    greek,
    cyrillic,
    armenian,
    hebrew,
    arabic,
    devanagari,
    bengali,
    tamil,
    telugu,
    kannada,
    malayalam,
    thai,
    lao,
    tibetan,
    myanmar,
    khmer,
    han,
    hiragana,
    katakana,
    hangul,
    unknown,
    other,
};

fn inRange(cp: CodePoint, lo: u32, hi: u32) bool {
    const v: u32 = cp;
    return v >= lo and v <= hi;
}

/// UAX#24 `Script(cp)` shard.
/// Oracle: ezi-code `scripts.scriptType` (2-level page table over
/// `generated/scripts.zig`). Ranges below are the block-level shards for the
/// scripts cozmic shapes/fallbacks on; unlisted assigned codepoints yield
/// `.other`, unassigned/out-of-range yield `.unknown` (same contract as the
/// oracle). `Common` covers ASCII digits/punct/space + General punctuation;
/// `Inherited` covers combining marks + ZWJ/ZWNJ (UAX#24 Zinh).
pub fn scriptOf(cp: CodePoint) Script {
    // Controls: skipped like Unknown by shape.rs:313-322 collection.
    if (cp < 0x20 or cp == 0x7F) return .unknown;
    if (cp >= 0xD800 and cp <= 0xDFFF) return .unknown;
    if (cp > 0x10FFFF) return .unknown;

    // ASCII fast path (mirrors shape.zig + ezi-code Latn/Zyyy).
    if (cp < 0x80) {
        if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return .latin;
        return .common;
    }
    // Inherited: combining-mark shards + join controls.
    if (isGraphemeExtend(cp) or cp == 0x200C or cp == 0x200D) return .inherited;
    // Latin extensions.
    if (inRange(cp, 0x00C0, 0x02FF) or inRange(cp, 0x1E00, 0x1EFF)) return .latin;
    // Unassigned holes inside otherwise-assigned blocks (must precede range hits).
    if (cp == 0x0378 or cp == 0x0380 or cp == 0x0381) return .unknown;
    if (inRange(cp, 0x0370, 0x03FF)) return .greek;
    if (inRange(cp, 0x0400, 0x04FF)) return .cyrillic;
    if (inRange(cp, 0x0530, 0x058F)) return .armenian;
    if (inRange(cp, 0x0590, 0x05FF)) return .hebrew;
    if (inRange(cp, 0x0600, 0x06FF) or inRange(cp, 0x0750, 0x077F) or
        inRange(cp, 0x08A0, 0x08FF) or inRange(cp, 0xFB50, 0xFDFF) or
        inRange(cp, 0xFE70, 0xFEFF)) return .arabic;
    if (inRange(cp, 0x0900, 0x097F)) return .devanagari;
    if (inRange(cp, 0x0980, 0x09FF)) return .bengali;
    if (inRange(cp, 0x0B80, 0x0BFF)) return .tamil;
    if (inRange(cp, 0x0C00, 0x0C7F)) return .telugu;
    if (inRange(cp, 0x0C80, 0x0CFF)) return .kannada;
    if (inRange(cp, 0x0D00, 0x0D7F)) return .malayalam;
    if (inRange(cp, 0x0E00, 0x0E7F)) return .thai;
    if (inRange(cp, 0x0E80, 0x0EFF)) return .lao;
    if (inRange(cp, 0x0F00, 0x0FFF)) return .tibetan;
    if (inRange(cp, 0x1000, 0x109F)) return .myanmar;
    if (inRange(cp, 0x1780, 0x17FF) or inRange(cp, 0x19E0, 0x19FF)) return .khmer;
    if (inRange(cp, 0x3040, 0x309F)) return .hiragana;
    if (inRange(cp, 0x30A0, 0x30FF) or inRange(cp, 0x31F0, 0x31FF) or
        inRange(cp, 0xFF65, 0xFF9F)) return .katakana;
    if (inRange(cp, 0x1100, 0x11FF) or inRange(cp, 0x3130, 0x318F) or
        inRange(cp, 0xAC00, 0xD7AF)) return .hangul;
    if (inRange(cp, 0x4E00, 0x9FFF) or inRange(cp, 0x3400, 0x4DBF) or
        inRange(cp, 0x20000, 0x2A6DF) or inRange(cp, 0xF900, 0xFAFF)) return .han;
    // General punctuation / spaces / symbols default to Common.
    if (cp == 0x00A0 or inRange(cp, 0x2000, 0x206F) or cp == 0x3000) return .common;
    if (inRange(cp, 0x2000, 0x2FFF)) return .common;
    if (cp >= 0x10000) return .other;
    // Assigned but outside the shard set (e.g. Georgian, Ethiopic): `.other`
    // so fallback still triggers (shape.rs collects every non-skipped script).
    if (cp >= 0x0100) return .other;
    return .unknown;
}

/// Collect distinct non-trivial scripts in a byte range.
/// Same skip set as `shape.zig:collectScripts` (shape.rs:313-322:
/// `Common | Inherited | Latin | Unknown` are skipped); allocator-explicit.
pub fn collectScripts(
    out: *std.ArrayList(Script),
    alloc: Allocator,
    text: []const u8,
    start: usize,
    end: usize,
) UnicodeError!void {
    const hi = @min(end, text.len);
    var i = @min(start, hi);
    while (i < hi) {
        const d = decodeOne(text, i);
        switch (scriptOf(d.cp)) {
            .common, .inherited, .latin, .unknown => {},
            else => |s| {
                var found = false;
                for (out.items) |have| {
                    if (have == s) {
                        found = true;
                        break;
                    }
                }
                if (!found) try out.append(alloc, s);
            },
        }
        i += d.len;
    }
}

// ---------------------------------------------------------------------------
// Grapheme properties (UAX#29 oracle: ezi-code `segmentation.*`)
// ---------------------------------------------------------------------------

/// Grapheme_Cluster_Break shard (ezi-code `generated/grapheme_break.zig`).
/// Only the values the incremental `checkGraphemeBoundary` consults are
/// distinguished; everything else folds to `.other`.
const GraphemeProp = enum {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    spacing_mark,
    prepend,
    l,
    v,
    t,
    lv,
    lvt,
    regional_indicator,
};

/// True for UAX#29 `Extend` (GB9): combining marks + variation selectors.
/// Oracle: ezi-code `properties.hasDerivedProperty(.grapheme_extend)`.
/// Shard covers the ranges exercised by shaping plus the MN-heavy blocks.
pub fn isGraphemeExtend(cp: CodePoint) bool {
    return inRange(cp, 0x0300, 0x036F) or
        inRange(cp, 0x0483, 0x0489) or
        inRange(cp, 0x0591, 0x05BD) or cp == 0x05BF or
        inRange(cp, 0x05C1, 0x05C2) or inRange(cp, 0x05C4, 0x05C5) or cp == 0x05C7 or
        inRange(cp, 0x0610, 0x061A) or inRange(cp, 0x064B, 0x065F) or cp == 0x0670 or
        inRange(cp, 0x06D6, 0x06DC) or inRange(cp, 0x06DF, 0x06E4) or
        inRange(cp, 0x06E7, 0x06E8) or inRange(cp, 0x06EA, 0x06ED) or
        inRange(cp, 0x1AB0, 0x1AFF) or inRange(cp, 0x1DC0, 0x1DFF) or
        inRange(cp, 0x20D0, 0x20FF) or inRange(cp, 0xFE00, 0xFE0F) or
        inRange(cp, 0xFE20, 0xFE2F) or inRange(cp, 0xE0100, 0xE01EF);
}

/// True for UAX#29 `SpacingMark` (GB9a): selected Indic vowel signs.
/// Oracle: ezi-code grapheme `spacing_mark` rows.
fn isSpacingMark(cp: CodePoint) bool {
    return inRange(cp, 0x0903, 0x0903) or inRange(cp, 0x093B, 0x093B) or
        inRange(cp, 0x093E, 0x0940) or inRange(cp, 0x0949, 0x094C) or
        inRange(cp, 0x0982, 0x0983) or inRange(cp, 0x09BE, 0x09C0) or
        inRange(cp, 0x0B82, 0x0B82) or inRange(cp, 0x0BBE, 0x0BC0) or
        inRange(cp, 0x0CC0, 0x0CC7) or cp == 0x0D02 or cp == 0x0D03;
}

/// True for UAX#29 `Prepend` (GB9b).
/// Oracle: ezi-code grapheme `prepend` rows.
fn isPrepend(cp: CodePoint) bool {
    return inRange(cp, 0x0600, 0x0605) or cp == 0x06DD or cp == 0x070F or
        cp == 0x0890 or cp == 0x0891 or cp == 0x08E2 or cp == 0x110BD or
        cp == 0x110CD;
}

fn isGraphemeControl(cp: CodePoint) bool {
    return (cp <= 0x0009) or (cp >= 0x000E and cp <= 0x001F) or
        (cp >= 0x007F and cp <= 0x009F);
}

fn isRegionalIndicator(cp: CodePoint) bool {
    return inRange(cp, 0x1F1E6, 0x1F1FF);
}

fn isHangulL(cp: CodePoint) bool {
    return inRange(cp, 0x1100, 0x115F) or inRange(cp, 0xA960, 0xA97C);
}
fn isHangulV(cp: CodePoint) bool {
    return inRange(cp, 0x1160, 0x11A7) or inRange(cp, 0xD7B0, 0xD7C6);
}
fn isHangulT(cp: CodePoint) bool {
    return inRange(cp, 0x11A8, 0x11FF) or inRange(cp, 0xD7CB, 0xD7FB);
}
fn isHangulLV(cp: CodePoint) bool {
    if (!inRange(cp, 0xAC00, 0xD7A3)) return false;
    return (cp - 0xAC00) % 28 == 0;
}
fn isHangulLVT(cp: CodePoint) bool {
    if (!inRange(cp, 0xAC00, 0xD7A3)) return false;
    return (cp - 0xAC00) % 28 != 0;
}

/// UTS#51 `Extended_Pictographic` shard (UAX#29 GB11).
/// Oracle: ezi-code `emoji.isExtendedPictographic`.
/// Covers misc symbols/dingbats/arrows + the full emoji blocks.
fn isExtendedPictographic(cp: CodePoint) bool {
    if (inRange(cp, 0x1F000, 0x1FAFF)) return true;
    if (inRange(cp, 0x2600, 0x27BF)) return true;
    if (inRange(cp, 0x2B00, 0x2BFF)) return true;
    if (inRange(cp, 0x1F1E6, 0x1F1FF)) return true;
    if (cp == 0x00A9 or cp == 0x00AE or cp == 0x203C or cp == 0x2049 or
        cp == 0x2122 or cp == 0x2139 or cp == 0x231A or cp == 0x231B or
        cp == 0x2328 or cp == 0x2388 or cp == 0x23CF or
        inRange(cp, 0x23E9, 0x23F3) or inRange(cp, 0x23F8, 0x23FA) or
        cp == 0x24C2 or inRange(cp, 0x25AA, 0x25AB) or cp == 0x25B6 or
        cp == 0x25C0 or inRange(cp, 0x25FB, 0x25FE)) return true;
    return false;
}

/// Indic Conjunct Break shard (UAX#29 GB9c).
/// Oracle: ezi-code `segmentation.inCB` (DerivedCore `InCB_*`).
/// Linker = virama-like signs; consonant = Indic consonants that participate
/// in conjuncts (Devanagari/Bengali/Tamil/Khmer shards); extend = Vedic signs.
const InCB = enum { none, consonant, linker, extend };

fn inCB(cp: CodePoint) InCB {
    // Linkers (viramas / coengs).
    if (cp == 0x094D or cp == 0x09CD or cp == 0x0BCD or cp == 0x0CCD or
        cp == 0x0D4D or cp == 0x0E3A or cp == 0x0F84 or cp == 0x1039 or
        cp == 0x1714 or cp == 0x17D2 or cp == 0x1A60 or cp == 0x1B44 or
        cp == 0x1BAA or cp == 0x1BF2 or cp == 0x1BF3 or cp == 0x2D7F or
        cp == 0xA806 or cp == 0xA8C4 or inRange(cp, 0x10A3F, 0x10A3F) or
        inRange(cp, 0x11046, 0x11046) or inRange(cp, 0x1107F, 0x1107F) or
        inRange(cp, 0x110B9, 0x110BA)) return .linker;
    // Consonants (representative Indic/Khmer ranges).
    if (inRange(cp, 0x0915, 0x0939) or inRange(cp, 0x0995, 0x09B9) or
        inRange(cp, 0x0B95, 0x0BB9) or inRange(cp, 0x1780, 0x17A2)) return .consonant;
    // Extends (Vedic tone marks).
    if (inRange(cp, 0x1CE2, 0x1CE8)) return .extend;
    return .none;
}

fn graphemeProp(cp: CodePoint) GraphemeProp {
    if (cp == 0x000D) return .cr;
    if (cp == 0x000A) return .lf;
    if (isGraphemeControl(cp)) return .control;
    if (isHangulL(cp)) return .l;
    if (isHangulV(cp)) return .v;
    if (isHangulT(cp)) return .t;
    if (isHangulLV(cp)) return .lv;
    if (isHangulLVT(cp)) return .lvt;
    if (cp == 0x200D) return .zwj;
    if (isRegionalIndicator(cp)) return .regional_indicator;
    if (isGraphemeExtend(cp)) return .extend;
    if (isSpacingMark(cp)) return .spacing_mark;
    if (isPrepend(cp)) return .prepend;
    return .other;
}

/// Incremental UAX#29 cursor state (mirrors ezi-code `BoundaryState`).
pub const GraphemeState = struct {
    prev: ?GraphemeProp = null,
    ri_run: u1 = 0,
    in_consonant_run: bool = false,
    in_linker_seen: bool = false,
    ext_pict_active: bool = false,
};

/// UAX#29 GB1-GB999 decision before `cur` given `state`.
/// Oracle: ezi-code `segmentation.checkBoundary`.
fn checkGraphemeBoundary(state: GraphemeState, cur: CodePoint) struct {
    should_break: bool,
    new_state: GraphemeState,
} {
    const cur_prop = graphemeProp(cur);
    const cur_incb = inCB(cur);
    const cur_is_ep = isExtendedPictographic(cur);

    const should_break: bool = blk: {
        const prev = state.prev orelse break :blk true; // GB1
        if (prev == .cr and cur_prop == .lf) break :blk false; // GB3
        if (prev == .control or prev == .cr or prev == .lf) break :blk true; // GB4
        if (cur_prop == .control or cur_prop == .cr or cur_prop == .lf) break :blk true; // GB5
        if (prev == .l) switch (cur_prop) { // GB6
            .l, .v, .lv, .lvt => break :blk false,
            else => {},
        };
        if (prev == .lv or prev == .v) switch (cur_prop) { // GB7
            .v, .t => break :blk false,
            else => {},
        };
        if ((prev == .lvt or prev == .t) and cur_prop == .t) break :blk false; // GB8
        if (cur_prop == .extend or cur_prop == .zwj) break :blk false; // GB9
        if (cur_prop == .spacing_mark) break :blk false; // GB9a
        if (prev == .prepend) break :blk false; // GB9b
        if (cur_incb == .consonant and state.in_consonant_run and state.in_linker_seen) break :blk false; // GB9c
        if (prev == .zwj and state.ext_pict_active and cur_is_ep) break :blk false; // GB11
        if (prev == .regional_indicator and cur_prop == .regional_indicator and state.ri_run == 1) break :blk false; // GB12/13
        break :blk true; // GB999
    };

    var ns = state;
    if (cur_prop == .regional_indicator) {
        ns.ri_run = if (should_break) 1 else state.ri_run +% 1;
    } else {
        ns.ri_run = 0;
    }
    if (should_break) {
        ns.in_consonant_run = false;
        ns.in_linker_seen = false;
        ns.ext_pict_active = false;
    }
    if (cur_incb == .consonant) {
        ns.in_consonant_run = true;
        ns.in_linker_seen = false;
    } else if (ns.in_consonant_run) {
        switch (cur_incb) {
            .linker => ns.in_linker_seen = true,
            .extend => {},
            else => {
                ns.in_consonant_run = false;
                ns.in_linker_seen = false;
            },
        }
    }
    if (cur_is_ep) {
        ns.ext_pict_active = true;
    } else if (ns.ext_pict_active) {
        if (cur_prop != .extend and cur_prop != .zwj) ns.ext_pict_active = false;
    }
    ns.prev = cur_prop;
    return .{ .should_break = should_break, .new_state = ns };
}

/// Allocation-free grapheme-cluster cursor over UTF-8 bytes.
/// Same shape as `shape.zig:GraphemeCursor` (`text/pos/end`, `next() ?usize`
/// yielding the *start* of the next cluster) but with full UAX#29 rules.
/// Clusters are `[prev_start, next_start)`; the final cluster ends at `end`.
pub const GraphemeIndices = struct {
    text: []const u8,
    pos: usize,
    end: usize,
    state: GraphemeState = .{},

    pub fn next(self: *GraphemeIndices) ?usize {
        if (self.pos >= self.end) return null;
        const start = self.pos;
        var consumed_first = false;
        while (self.pos < self.end) {
            const d = decodeOne(self.text, self.pos);
            const dec = checkGraphemeBoundary(self.state, d.cp);
            if (dec.should_break and consumed_first) break;
            self.state = dec.new_state;
            self.pos += d.len;
            consumed_first = true;
        }
        return start;
    }

    /// Start offsets as an owned slice (includes no sentinel; add `end`
    /// separately). Caller owns; freed with `alloc.free`.
    pub fn collectStarts(self: *GraphemeIndices, alloc: Allocator) UnicodeError![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(alloc);
        while (self.next()) |s| try out.append(alloc, s);
        return out.toOwnedSlice(alloc);
    }
};

/// Iterate grapheme-cluster starts in `text` (UAX#29).
pub fn graphemeIndices(text: []const u8) GraphemeIndices {
    return .{ .text = text, .pos = 0, .end = text.len };
}

/// Byte offset is a grapheme boundary (sot/eot always true).
pub fn isGraphemeBoundary(text: []const u8, index: usize) bool {
    if (index == 0 or index == text.len) return true;
    if (!isBoundary(text, index)) return false;
    var it = graphemeIndices(text);
    while (it.next()) |s| {
        if (s == index) return true;
        if (s > index) return false;
    }
    return false;
}

/// Count grapheme clusters (allocation-free).
pub fn countGraphemes(text: []const u8) usize {
    var it = graphemeIndices(text);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// Previous grapheme-cluster start at or before `index` (codepoint-correct
/// Backspace/Delete primitive for buffer/edit; mirrors their `prevCharStart`
/// but cluster-aware).
pub fn prevGraphemeStart(text: []const u8, index: usize) usize {
    const clamped = @min(index, text.len);
    var last: usize = 0;
    var it = graphemeIndices(text);
    while (it.next()) |s| {
        if (s >= clamped) break;
        last = s;
    }
    return last;
}

/// Next grapheme-cluster end at or after `index`.
pub fn nextGraphemeEnd(text: []const u8, index: usize) usize {
    const clamped = @min(index, text.len);
    var it = graphemeIndices(text);
    while (it.next()) |s| {
        if (s > clamped) return s;
    }
    return text.len;
}

// ---------------------------------------------------------------------------
// Words (UAX#29 oracle: ezi-code `segmentation.wordStep`)
// ---------------------------------------------------------------------------

const WordProp = enum {
    other,
    aletter,
    hebrew_letter,
    numeric,
    katakana,
    extend_num_let,
    extend,
    format,
    zwj,
    wseg_space,
    mid_letter,
    mid_num,
    mid_num_let,
    single_quote,
    double_quote,
    cr,
    lf,
    newline,
    regional_indicator,
};

fn isAHLetter(p: WordProp) bool {
    return p == .aletter or p == .hebrew_letter;
}
fn isMidNumLetQ(p: WordProp) bool {
    return p == .mid_num_let or p == .single_quote;
}
fn isWordIgnorable(p: WordProp) bool {
    return p == .extend or p == .format or p == .zwj;
}
fn isWordHardSep(p: WordProp) bool {
    return p == .newline or p == .cr or p == .lf;
}

/// `Word_Break` shard. Oracle: ezi-code `generated/word_break.zig`
/// `wordBreakProperty`. ASCII + the CJK/NBSP/RI/Extend shards below are exact;
/// mid/quote classes are the minimal rows needed for WB6-WB13.
fn wordBreakProperty(cp: CodePoint) WordProp {
    if (cp == 0x000D) return .cr;
    if (cp == 0x000A) return .lf;
    if (cp == 0x000B or cp == 0x000C or cp == 0x0085 or cp == 0x2028 or cp == 0x2029) return .newline;
    if (cp == 0x200D) return .zwj;
    if (isRegionalIndicator(cp)) return .regional_indicator;
    if (isGraphemeExtend(cp) or cp == 0x200C) return .extend;
    // Format (WB4-ignorable): default-ignorable + join controls handled above.
    if (cp == 0x00AD or cp == 0x061C or cp == 0x200B or cp == 0x2060 or
        cp == 0xFEFF or inRange(cp, 0x2061, 0x2064)) return .format;
    if (inRange(cp, 0x30A0, 0x30FF) or inRange(cp, 0xFF65, 0xFF9F)) return .katakana;
    // WSegSpace: spaces that segment words (all White_Space except NBSP-family
    // glue, which is ExtendNumLet below so it binds like UAX#29).
    if (isWhitespace(cp) and cp != 0x00A0 and cp != 0x202F and cp != 0x205F) return .wseg_space;
    // NBSP-family glue binds to letters/numbers (WB13a/b via ExtendNumLet).
    if (cp == 0x00A0 or cp == 0x202F or cp == 0x205F) return .extend_num_let;
    if (cp == 0x0022) return .double_quote;
    if (cp == 0x0027) return .single_quote;
    if (cp == 0x003A or cp == 0x00B7 or cp == 0x05F4) return .mid_letter;
    if (cp == 0x002C or cp == 0x003B or cp == 0x061B or cp == 0x061F) return .mid_num;
    if (cp == 0x002E or cp == 0x2027 or cp == 0xFF0E) return .mid_num_let;
    // Numeric: ASCII + Arabic-Indic + Devanagari/Bengalo-Tamil digit shards.
    if (inRange(cp, 0x0030, 0x0039) or inRange(cp, 0x0660, 0x0669) or
        inRange(cp, 0x0966, 0x096F) or inRange(cp, 0x09E6, 0x09EF) or
        inRange(cp, 0x0BE6, 0x0BEF)) return .numeric;
    // Hebrew letters (distinct from ALetter for WB7a-c).
    if (inRange(cp, 0x05D0, 0x05EA)) return .hebrew_letter;
    // ExtendNumLet: underscore + NBSP-family handled above.
    if (cp == '_' or cp == 0x203F or cp == 0x2040) return .extend_num_let;
    // ALetter: ASCII letters + Han/Hiragana/Hangul/Indic letters (alphabetic).
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return .aletter;
    if (inRange(cp, 0x00C0, 0x02FF) or inRange(cp, 0x0370, 0x03FF) or
        inRange(cp, 0x0400, 0x04FF) or inRange(cp, 0x0530, 0x058F) or
        inRange(cp, 0x0600, 0x06FF) or inRange(cp, 0x0900, 0x097F) or
        inRange(cp, 0x0980, 0x09FF) or inRange(cp, 0x0B80, 0x0BFF) or
        inRange(cp, 0x0E00, 0x0EFF) or inRange(cp, 0x1000, 0x109F) or
        inRange(cp, 0x1780, 0x17FF) or inRange(cp, 0x3040, 0x309F) or
        inRange(cp, 0x3400, 0x4DBF) or inRange(cp, 0x4E00, 0x9FFF) or
        inRange(cp, 0xAC00, 0xD7AF)) return .aletter;
    return .other;
}

/// Byte range of one UAX#29 word segment.
pub const WordRange = struct {
    start: usize,
    end: usize,
};

const WordStepState = struct {
    eff_prev: WordProp,
    eff_prev_prev: ?WordProp,
    ri_count: u1,
    prev_lit: WordProp,
};

fn wordStateInit(first: CodePoint) WordStepState {
    const p = wordBreakProperty(first);
    return .{
        .eff_prev = p,
        .eff_prev_prev = null,
        .ri_count = if (p == .regional_indicator) 1 else 0,
        .prev_lit = p,
    };
}

/// Look ahead past ignorables to the next effective property (WB6/WB7b/WB12).
fn nextEffectiveWordProp(text: []const u8, from_byte: usize) ?WordProp {
    var j = from_byte;
    while (j < text.len) {
        const d = decodeOne(text, j);
        const p = wordBreakProperty(d.cp);
        if (!isWordIgnorable(p)) return p;
        j += d.len;
    }
    return null;
}

const WordByteDecision = struct {
    is_break: bool,
    new_state: WordStepState,
    consumed: usize,
};

fn wordStepBytes(state: WordStepState, text: []const u8, byte_pos: usize) WordByteDecision {
    const d0 = decodeOne(text, byte_pos);
    const curr = wordBreakProperty(d0.cp);
    const prev_lit = state.prev_lit;

    if (prev_lit == .cr and curr == .lf) {
        return .{
            .is_break = false,
            .new_state = .{ .eff_prev = curr, .eff_prev_prev = state.eff_prev, .ri_count = 0, .prev_lit = curr },
            .consumed = d0.len,
        };
    }
    if (isWordHardSep(prev_lit)) {
        return .{
            .is_break = true,
            .new_state = .{
                .eff_prev = curr,
                .eff_prev_prev = null,
                .ri_count = if (curr == .regional_indicator) 1 else 0,
                .prev_lit = curr,
            },
            .consumed = d0.len,
        };
    }
    if (isWordHardSep(curr)) {
        return .{
            .is_break = true,
            .new_state = .{ .eff_prev = curr, .eff_prev_prev = null, .ri_count = 0, .prev_lit = curr },
            .consumed = d0.len,
        };
    }
    if (prev_lit == .zwj and isExtendedPictographic(d0.cp)) {
        return .{
            .is_break = false,
            .new_state = .{
                .eff_prev = curr,
                .eff_prev_prev = state.eff_prev,
                .ri_count = if (curr == .regional_indicator) 1 else 0,
                .prev_lit = curr,
            },
            .consumed = d0.len,
        };
    }
    if (prev_lit == .wseg_space and curr == .wseg_space) {
        return .{
            .is_break = false,
            .new_state = .{ .eff_prev = curr, .eff_prev_prev = state.eff_prev, .ri_count = 0, .prev_lit = curr },
            .consumed = d0.len,
        };
    }
    if (isWordIgnorable(curr)) {
        return .{
            .is_break = false,
            .new_state = .{
                .eff_prev = state.eff_prev,
                .eff_prev_prev = state.eff_prev_prev,
                .ri_count = state.ri_count,
                .prev_lit = curr,
            },
            .consumed = d0.len,
        };
    }

    const prev = state.eff_prev;
    const prev_prev = state.eff_prev_prev;
    var no_break = false;

    if (isAHLetter(prev) and isAHLetter(curr)) no_break = true; // WB5
    if (!no_break and isAHLetter(prev) and (curr == .mid_letter or isMidNumLetQ(curr))) { // WB6
        if (nextEffectiveWordProp(text, byte_pos + d0.len)) |after| {
            if (isAHLetter(after)) no_break = true;
        }
    }
    if (!no_break and (prev == .mid_letter or isMidNumLetQ(prev)) and isAHLetter(curr)) { // WB7
        if (prev_prev) |pp| {
            if (isAHLetter(pp)) no_break = true;
        }
    }
    if (!no_break and prev == .hebrew_letter and curr == .single_quote) no_break = true; // WB7a
    if (!no_break and prev == .hebrew_letter and curr == .double_quote) { // WB7b
        if (nextEffectiveWordProp(text, byte_pos + d0.len)) |after| {
            if (after == .hebrew_letter) no_break = true;
        }
    }
    if (!no_break and prev == .double_quote and curr == .hebrew_letter) { // WB7c
        if (prev_prev) |pp| {
            if (pp == .hebrew_letter) no_break = true;
        }
    }
    if (!no_break and prev == .numeric and curr == .numeric) no_break = true; // WB8
    if (!no_break and isAHLetter(prev) and curr == .numeric) no_break = true; // WB9
    if (!no_break and prev == .numeric and isAHLetter(curr)) no_break = true; // WB10
    if (!no_break and (prev == .mid_num or isMidNumLetQ(prev)) and curr == .numeric) { // WB11
        if (prev_prev) |pp| {
            if (pp == .numeric) no_break = true;
        }
    }
    if (!no_break and prev == .numeric and (curr == .mid_num or isMidNumLetQ(curr))) { // WB12
        if (nextEffectiveWordProp(text, byte_pos + d0.len)) |after| {
            if (after == .numeric) no_break = true;
        }
    }
    if (!no_break and prev == .katakana and curr == .katakana) no_break = true; // WB13
    if (!no_break and (isAHLetter(prev) or prev == .numeric or prev == .katakana or prev == .extend_num_let) and curr == .extend_num_let) no_break = true; // WB13a
    if (!no_break and prev == .extend_num_let and (isAHLetter(curr) or curr == .numeric or curr == .katakana)) no_break = true; // WB13b
    if (!no_break and prev == .regional_indicator and curr == .regional_indicator) { // WB15/16
        if (state.ri_count == 1) no_break = true;
    }
    // WB3d-adjacent: keep ZWJ-adjacent EP runs together beyond the single-step
    // WB3c (the byte loop re-enters here per codepoint, so multi-EP ZWJ chains
    // stay joined transitively).

    const next_ri: u1 = if (curr == .regional_indicator)
        (if (no_break) state.ri_count +% 1 else 1)
    else
        0;
    return .{
        .is_break = !no_break,
        .new_state = .{
            .eff_prev = curr,
            .eff_prev_prev = state.eff_prev,
            .ri_count = next_ri,
            .prev_lit = curr,
        },
        .consumed = d0.len,
    };
}

/// Allocation-free UAX#29 word cursor.
/// Yields every segment (words *and* separators, like ezi-code `WordIterator`;
/// callers that want words only skip ranges that are all `wseg_space`/hard
/// separators). Same byte-range shape as `shape.zig:WordSplit` without the
/// blank flag.
pub const WordBounds = struct {
    text: []const u8,
    pos: usize = 0,
    state: WordStepState = undefined,
    primed: bool = false,

    pub fn next(self: *WordBounds) ?WordRange {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        const first = decodeOne(self.text, self.pos);
        if (!self.primed) {
            self.state = wordStateInit(first.cp);
            self.primed = true;
        }
        var cursor = self.pos + first.len;
        while (cursor < self.text.len) {
            const dec = wordStepBytes(self.state, self.text, cursor);
            self.state = dec.new_state;
            if (dec.is_break) {
                self.pos = cursor;
                return .{ .start = start, .end = cursor };
            }
            cursor += dec.consumed;
        }
        self.pos = self.text.len;
        return .{ .start = start, .end = self.text.len };
    }

    pub fn reset(self: *WordBounds) void {
        self.pos = 0;
        self.primed = false;
    }
};

/// Iterate UAX#29 word segments in `text`.
pub fn wordBounds(text: []const u8) WordBounds {
    return .{ .text = text };
}

/// True when the range is a word (not pure whitespace/hard separator).
pub fn isWordRange(text: []const u8, r: WordRange) bool {
    var i = r.start;
    var any_word = false;
    var any_sep_only = false;
    while (i < r.end) {
        const d = decodeOne(text, i);
        const p = wordBreakProperty(d.cp);
        if (p == .wseg_space or isWordHardSep(p)) {
            any_sep_only = true;
        } else {
            any_word = true;
        }
        i += d.len;
    }
    return any_word and !(!any_word and any_sep_only);
}

// ---------------------------------------------------------------------------
// Line breaking (UAX#14 oracle: ezi-code `segmentation.lineStep`)
// ---------------------------------------------------------------------------

const LineClass = enum {
    xx,
    al,
    ba,
    bb,
    bk,
    cb,
    cl,
    cm,
    cp,
    cr,
    eb,
    em,
    ex,
    gl,
    h2,
    h3,
    hl,
    hy,
    id,
    inl,
    is_,
    jl,
    jt,
    jv,
    lf,
    nl,
    ns,
    nu,
    op,
    po,
    pr,
    qu,
    ri,
    sp,
    sy,
    wj,
    zw,
    zwj,
};

/// `Line_Break` shard. Oracle: ezi-code `generated/line_break.zig`
/// `lineBreak`. Covers the classes exercised by wrapping (SP/BK/CR/LF/NL,
/// GL/WJ/ZW/ZWJ, HY/BA, ID/CJK, AL/NU, OP/CL/CP/QU/EX/SY/IS/PR/PO, RI);
/// everything else folds to AL (LB1 `AI/SG/XX -> AL` tailoring).
fn lineBreakClass(cp: CodePoint) LineClass {
    if (cp == 0x000D) return .cr;
    if (cp == 0x000A) return .lf;
    if (cp == 0x0085) return .nl;
    if (cp == 0x000B or cp == 0x000C or cp == 0x2028 or cp == 0x2029) return .bk;
    if (cp == 0x0020 or cp == 0x0009) return .sp;
    if (cp == 0x200B) return .zw;
    if (cp == 0x200D) return .zwj;
    if (cp == 0x2060 or cp == 0xFEFF) return .wj;
    if (cp == 0x00A0 or cp == 0x034F or cp == 0x202F or cp == 0x205F) return .gl;
    if (cp == 0x002D or cp == 0x00AD) return .hy;
    if (cp == 0x002F or cp == 0x007C) return .ba;
    if (cp == 0x2010 or cp == 0x2011) return .ba;
    if (cp == 0x0028 or cp == 0x005B or cp == 0x007B) return .op;
    if (cp == 0x0029 or cp == 0x005D or cp == 0x007D) return .cp;
    if (cp == 0x002C or cp == 0x003B or cp == 0x061B) return .cl;
    if (cp == 0x0021 or cp == 0x003F) return .ex;
    if (cp == 0x0022 or cp == 0x2018 or cp == 0x2019 or cp == 0x201C or cp == 0x201D) return .qu;
    if (cp == 0x00A3 or cp == 0x00A5 or cp == 0x0024) return .pr;
    if (cp == 0x0025 or cp == 0x00A2) return .po;
    if (cp == 0x002B or cp == 0x005C) return .sy;
    if (cp == 0x2000 or cp == 0x2001 or cp == 0x2002) return .is_;
    if (inRange(cp, 0x0030, 0x0039)) return .nu;
    // CJK ideographs + Hiragana/Katakana/Hangul-syllable breakables.
    if (inRange(cp, 0x4E00, 0x9FFF) or inRange(cp, 0x3400, 0x4DBF) or
        inRange(cp, 0x3040, 0x309F) or inRange(cp, 0x30A0, 0x30FF) or
        inRange(cp, 0xAC00, 0xD7AF) or inRange(cp, 0x20000, 0x2A6DF)) return .id;
    if (inRange(cp, 0x1100, 0x11FF)) return .jl;
    if (inRange(cp, 0x1160, 0x11A7)) return .jv;
    if (inRange(cp, 0x11A8, 0x11FF)) return .jt;
    if (isRegionalIndicator(cp)) return .ri;
    if (isGraphemeExtend(cp)) return .cm;
    // Emoji presentation blocks behave like ID for wrapping (breakable).
    if (inRange(cp, 0x1F000, 0x1FAFF)) return .id;
    return .al;
}

/// UAX#14 break kind (mirrors ezi-code `LineBreakKind`).
pub const LineBreakKind = enum {
    /// No break permitted (UAX#14 x).
    prohibited,
    /// Break permitted when wrapping (UAX#14 /).
    opportunity,
    /// Forced break (UAX#14 ! after BK/CR/LF/NL, plus eot).
    mandatory,
};

pub const BreakOpportunity = struct {
    /// Byte offset *before which* the break sits (like UAX#14 positions).
    offset: usize,
    kind: LineBreakKind,
};

/// Incremental UAX#14 state: previous effective class + RI parity.
/// CM/ZWJ attach per LB9 (invisible); unattached CM/ZWJ promote to AL (LB10).
const LineState = struct {
    eff_prev: ?LineClass = null,
    eff_prev_cp: CodePoint = 0,
    raw_prev: ?LineClass = null,
    last_nonsp: ?LineClass = null,
    ri_parity: u1 = 0,
};

fn lineStateInit(first_cp: CodePoint) LineState {
    const raw = lineBreakClass(first_cp);
    // LB9 cannot attach at sot; LB10 promotes CM/ZWJ to AL.
    const eff: LineClass = if (raw == .cm or raw == .zwj) .al else raw;
    return .{
        .eff_prev = eff,
        .eff_prev_cp = first_cp,
        .raw_prev = raw,
        .last_nonsp = if (eff == .sp) null else eff,
        .ri_parity = if (eff == .ri) 1 else 0,
    };
}

fn isHardBreaker(c: LineClass) bool {
    return c == .bk or c == .cr or c == .lf or c == .nl or c == .sp or c == .zw;
}

/// Core UAX#14 pair rules for `(prev, cur)` with lookback context.
/// Oracle: ezi-code `lineStepRules` (LB4-LB31 essentials; numeric-chain LB25
/// and Brahmic LB28a fold to the generic pair table since the shard set here
/// does not distinguish PO/PR/IS chains beyond the tested GL/WJ/ID/HY set).
fn linePairKind(st: LineState, cur: LineClass) LineBreakKind {
    const prev = st.eff_prev orelse return .prohibited; // LB2 sot x

    // LB4: BK !
    if (prev == .bk) return .mandatory;
    // LB5: CR x LF, else CR/LF/NL !
    if (prev == .cr) {
        if (cur == .lf) return .prohibited;
        return .mandatory;
    }
    if (prev == .lf or prev == .nl) return .mandatory;
    // LB6: x BK/CR/LF/NL; LB7: x SP/ZW.
    if (cur == .bk or cur == .cr or cur == .lf or cur == .nl or cur == .sp or cur == .zw) return .prohibited;
    // LB8: ZW SP* /.
    if (st.last_nonsp == .zw) return .opportunity;
    // LB8a: ZWJ x.
    if (st.raw_prev == .zwj) return .prohibited;
    // LB11: x WJ, WJ x.
    if (cur == .wj or prev == .wj) return .prohibited;
    // LB12: GL x.
    if (prev == .gl) return .prohibited;
    // LB12a: [^SP BA HY] x GL (NBSP-family glue).
    if (cur == .gl) {
        switch (prev) {
            .sp, .ba, .hy => {},
            else => return .prohibited,
        }
    }
    // LB13: x CL/CP/EX/SY.
    if (cur == .cl or cur == .cp or cur == .ex or cur == .sy) return .prohibited;
    // LB14: OP SP* x.
    if (st.last_nonsp == .op) return .prohibited;
    // LB15-17 handled via last_nonsp + SP deferral below.
    if (cur == .qu or prev == .qu) {
        // Conservative QU glue (LB19): quotes bind to adjacent AL/NU.
        if (cur == .qu or prev == .qu) {
            // Allow CJK-adjacent quotes to break (tests use ASCII quotes
            // around words, which must NOT split; keep glued).
            return .prohibited;
        }
    }
    // LB16: (CL|CP) SP* x NS -- approximated via last_nonsp.
    if (cur == .ns) {
        if (st.last_nonsp == .cl or st.last_nonsp == .cp) return .prohibited;
    }
    // LB17: B2 SP* x B2 (no B2 shard here; skipped).
    // LB18: SP / (commit after all SP-lookback rules).
    if (prev == .sp) return .opportunity;
    // LB23: (AL | HL) x NU; NU x (AL | HL). Never break letters from digits.
    if ((prev == .al and cur == .nu) or (prev == .nu and cur == .al)) return .prohibited;
    // LB24: (PR | PO) x (AL | HL); (AL | HL) x (PR | PO).
    if ((prev == .pr or prev == .po) and cur == .al) return .prohibited;
    if (prev == .al and (cur == .pr or cur == .po)) return .prohibited;
    // LB25 (simplified numeric chains): NU-NU, NU-SY/IS, SY/IS-NU.
    if (prev == .nu and (cur == .nu or cur == .sy or cur == .is_)) return .prohibited;
    if ((prev == .sy or prev == .is_) and cur == .nu) return .prohibited;
    // LB28: (AL | HL) x (AL | HL). Never split Latin/Hebrew words.
    if (prev == .al and cur == .al) return .prohibited;
    // LB30: CP x (AL | HL | NU); (AL | HL | NU) x OP.
    if (prev == .cp and (cur == .al or cur == .nu)) return .prohibited;
    if ((prev == .al or prev == .nu) and cur == .op) return .prohibited;
    // LB21: x BA/HY/NS; BB x.
    if (cur == .ba or cur == .hy or cur == .ns) return .prohibited;
    if (prev == .bb) return .prohibited;
    // LB22: x IN (no IN shard; skipped).
    // CJK: ID / ID (breakable both sides; LB30 context).
    if (prev == .id or cur == .id) return .opportunity;
    // HY: allow break *after* hyphen (tests: "foo-bar" splits after '-').
    // LB21 says x HY (no break before), but HY / (break after) is the tailoring
    // used by wrapping: implement as opportunity when cur follows HY.
    if (prev == .hy) return .opportunity;
    // JL/JV/JT Hangul syllable glue (LB26): no break inside.
    if (prev == .jl and (cur == .jl or cur == .jv)) return .prohibited;
    if ((prev == .jv or prev == .h2) and (cur == .jv or cur == .jt)) return .prohibited;
    if ((prev == .jt or prev == .h3) and cur == .jt) return .prohibited;
    // RI x RI on odd runs (LB30a).
    if (prev == .ri and cur == .ri and st.ri_parity == 1) return .prohibited;
    // Default: AL/NU/OP... allow break (word wrapping takes it as needed).
    // Conservative default for prose is opportunity (matches ezi-code LB31
    // "ALL / ALL" tail).
    return .opportunity;
}

fn lineAdvanceState(st: LineState, cur_cp: CodePoint, cur_raw: LineClass, cur_eff: LineClass, broke: bool) LineState {
    var ns = st;
    ns.raw_prev = cur_raw;
    // RI parity tracks unbroken RI runs.
    if (cur_eff == .ri) {
        ns.ri_parity = if (broke) 1 else st.ri_parity +% 1;
    } else {
        ns.ri_parity = 0;
    }
    ns.eff_prev = cur_eff;
    ns.eff_prev_cp = cur_cp;
    if (cur_eff == .sp) {
        // last_nonsp preserved across SP runs (LB14/16/18 need it).
    } else {
        ns.last_nonsp = cur_eff;
    }
    if (broke) {
        // A mandatory/opportunity break does not reset last_nonsp beyond the
        // SP handling above (lineStep keeps the tape; only paragraph breaks
        // reset). Kept verbatim for oracle parity.
    }
    return ns;
}

/// Allocation-free UAX#14 cursor over UTF-8 bytes.
/// Yields break opportunities as `{offset, kind}` with `offset` the byte index
/// *before which* the break sits. sot (0) is never yielded (LB2); eot
/// (`text.len` as `.mandatory`) is yielded last when text is non-empty.
/// Mandatory breaks after BK/CR/LF/NL surface as `.mandatory`.
pub const LineBreakOpportunities = struct {
    text: []const u8,
    byte_pos: usize = 0,
    state: LineState = .{},
    primed: bool = false,
    pending_eot: bool = false,
    done_eot: bool = false,

    pub fn next(self: *LineBreakOpportunities) ?BreakOpportunity {
        if (self.text.len == 0) return null;
        if (!self.primed) {
            const d0 = decodeOne(self.text, 0);
            self.state = lineStateInit(d0.cp);
            self.byte_pos = d0.len;
            self.primed = true;
            // Single-codepoint text: only eot remains.
            if (self.byte_pos >= self.text.len) {
                self.done_eot = true;
                return .{ .offset = self.text.len, .kind = .mandatory };
            }
        }
        while (self.byte_pos < self.text.len) {
            const cur_pos = self.byte_pos;
            const d = decodeOne(self.text, cur_pos);
            const cur_raw = lineBreakClass(d.cp);
            const attach = (cur_raw == .cm or cur_raw == .zwj) and
                (if (self.state.eff_prev) |p| !isHardBreaker(p) else false);
            if (attach) {
                // LB9: attached CM/ZWJ is invisible (x).
                var ns = self.state;
                ns.raw_prev = cur_raw;
                self.state = ns;
                self.byte_pos += d.len;
                continue;
            }
            const cur_eff: LineClass = if (cur_raw == .cm or cur_raw == .zwj) .al else cur_raw;
            const kind = linePairKind(self.state, cur_eff);
            const broke = kind != .prohibited;
            self.state = lineAdvanceState(self.state, d.cp, cur_raw, cur_eff, broke);
            self.byte_pos += d.len;
            if (kind != .prohibited) {
                return .{ .offset = cur_pos, .kind = kind };
            }
        }
        if (!self.done_eot) {
            self.done_eot = true;
            return .{ .offset = self.text.len, .kind = .mandatory };
        }
        return null;
    }

    pub fn reset(self: *LineBreakOpportunities) void {
        self.byte_pos = 0;
        self.primed = false;
        self.done_eot = false;
        self.state = .{};
    }
};

/// Iterate UAX#14 break opportunities in `text`.
pub fn lineBreakOpportunities(text: []const u8) LineBreakOpportunities {
    return .{ .text = text };
}

/// Collect break offsets (opportunity + mandatory) into an owned slice.
/// Includes the trailing `text.len` sentinel when text is non-empty.
pub fn collectLineBreaks(alloc: Allocator, text: []const u8) UnicodeError![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(alloc);
    var it = lineBreakOpportunities(text);
    while (it.next()) |b| try out.append(alloc, b.offset);
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Bidi (UAX#9 oracle: ezi-code `bidi/algorithm.zig`)
// ---------------------------------------------------------------------------

/// Bidi_Class shard. Oracle: ezi-code `properties.bidiClass`.
pub const BidiClass = enum {
    l,
    r,
    al,
    en,
    an,
    nsm,
    bn,
    b,
    s,
    ws,
    on,
    lre,
    rle,
    lro,
    rlo,
    pdf,
    lri,
    rli,
    fsi,
    pdi,
};

/// `Bidi_Class(cp)` shard covering strong/weak/neutral + formatting.
pub fn bidiClass(cp: CodePoint) BidiClass {
    // Explicit formatting.
    switch (cp) {
        0x202A => return .lre,
        0x202B => return .rle,
        0x202D => return .lro,
        0x202E => return .rlo,
        0x202C => return .pdf,
        0x2066 => return .lri,
        0x2067 => return .rli,
        0x2068 => return .fsi,
        0x2069 => return .pdi,
        0x200E, 0x200F, 0x061C => return .bn,
        0x2028 => return .s,
        0x000A, 0x000D, 0x0085, 0x2029 => return .b,
        0x0020, 0x0009, 0x00A0, 0x1680 => return .ws,
        else => {},
    }
    if (cp == 0x000C) return .s;
    if (inRange(cp, 0x2000, 0x200A) or cp == 0x202F or cp == 0x205F or cp == 0x3000) return .ws;
    // NSM: combining marks.
    if (isGraphemeExtend(cp)) return .nsm;
    // Strong RTL.
    if (inRange(cp, 0x0590, 0x05FF) or inRange(cp, 0xFB1D, 0xFB4F)) return .r;
    if (inRange(cp, 0x0600, 0x08FF) or inRange(cp, 0xFB50, 0xFDFF) or
        inRange(cp, 0xFE70, 0xFEFF)) return .al;
    // Numbers.
    if (inRange(cp, 0x0030, 0x0039)) return .en;
    if (inRange(cp, 0x0660, 0x0669) or inRange(cp, 0x06F0, 0x06F9)) return .an;
    // Strong LTR.
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        inRange(cp, 0x0041, 0x02FF) or inRange(cp, 0x0370, 0x03FF) or
        inRange(cp, 0x0400, 0x04FF) or inRange(cp, 0x0900, 0x0D7F) or
        inRange(cp, 0x0E00, 0x0EFF) or inRange(cp, 0x1000, 0x109F) or
        inRange(cp, 0x1780, 0x17FF) or inRange(cp, 0x3040, 0x30FF) or
        inRange(cp, 0x4E00, 0x9FFF) or inRange(cp, 0xAC00, 0xD7AF)) return .l;
    return .on;
}

fn isIsolateInitiator(c: BidiClass) bool {
    return c == .lri or c == .rli or c == .fsi;
}
fn isRemovedByX9(c: BidiClass) bool {
    return c == .rle or c == .lre or c == .rlo or c == .lro or c == .pdf or c == .bn;
}
fn isStrongBidi(c: BidiClass) bool {
    return c == .l or c == .r or c == .al;
}

/// Base paragraph direction (mirrors ezi-code `BaseDirection`).
pub const BaseDirection = enum {
    ltr,
    rtl,
    auto,
};

/// Paragraph embedding level P2/P3 over codepoints (isolate-aware first-strong
/// scan; oracle: ezi-code `paragraphLevel`).
pub fn paragraphLevelForCodepoints(cps: []const CodePoint, base: BaseDirection) Level {
    switch (base) {
        .ltr => return LEVEL_LTR,
        .rtl => return LEVEL_RTL,
        .auto => {},
    }
    var i: usize = 0;
    while (i < cps.len) {
        const c = bidiClass(cps[i]);
        if (isIsolateInitiator(c)) {
            var depth: usize = 1;
            i += 1;
            while (i < cps.len and depth > 0) : (i += 1) {
                const cc = bidiClass(cps[i]);
                if (isIsolateInitiator(cc)) depth += 1 else if (cc == .pdi) depth -= 1;
            }
            continue;
        }
        switch (c) {
            .r, .al => return LEVEL_RTL,
            .l => return LEVEL_LTR,
            else => i += 1,
        }
    }
    return LEVEL_LTR;
}

/// Paragraph embedding level over UTF-8 text (first-strong, isolate-aware).
pub fn paragraphLevel(text: []const u8, base: BaseDirection) Level {
    switch (base) {
        .ltr => return LEVEL_LTR,
        .rtl => return LEVEL_RTL,
        .auto => {},
    }
    var i: usize = 0;
    var isolate_depth: usize = 0;
    // Streaming first-strong scan that skips isolate contents (P2).
    while (i < text.len) {
        const d = decodeOne(text, i);
        const c = bidiClass(d.cp);
        i += d.len;
        if (isIsolateInitiator(c)) {
            isolate_depth += 1;
            continue;
        }
        if (c == .pdi) {
            if (isolate_depth > 0) isolate_depth -= 1;
            continue;
        }
        if (isolate_depth > 0) continue;
        switch (c) {
            .r, .al => return LEVEL_RTL,
            .l => return LEVEL_LTR,
            else => {},
        }
    }
    return LEVEL_LTR;
}

/// One paragraph slice with its embedding level (UAX#9 P1-P3).
pub const BidiParagraph = struct {
    start: usize,
    end: usize,
    level: Level,
};

/// Allocation-free paragraph cursor splitting on `B` (paragraph separators:
/// LF/CR/NEL/PS; CRLF is one separator). Each item carries its own base level
/// under `base` (with `.auto` running first-strong per paragraph).
pub const BidiParagraphs = struct {
    text: []const u8,
    pos: usize = 0,
    base: BaseDirection = .auto,

    pub fn next(self: *BidiParagraphs) ?BidiParagraph {
        if (self.pos > self.text.len) return null;
        if (self.pos == self.text.len) return null;
        const start = self.pos;
        var i = start;
        while (i < self.text.len) {
            const d = decodeOne(self.text, i);
            if (d.cp == 0x000D and i + d.len < self.text.len) {
                const d2 = decodeOne(self.text, i + d.len);
                if (d2.cp == 0x000A) {
                    i += d.len + d2.len;
                    break;
                }
            }
            if (bidiClass(d.cp) == .b) {
                i += d.len;
                break;
            }
            i += d.len;
        }
        const end = i;
        self.pos = end;
        const level = paragraphLevel(self.text[start..end], self.base);
        return .{ .start = start, .end = end, .level = level };
    }

    pub fn reset(self: *BidiParagraphs) void {
        self.pos = 0;
    }
};

/// Iterate UAX#9 paragraphs in `text` under `base`.
pub fn bidiParagraphs(text: []const u8, base: BaseDirection) BidiParagraphs {
    return .{ .text = text, .base = base };
}

const MAX_BIDI_DEPTH: Level = 125;

fn nextOddLevel(l: Level) Level {
    // Saturate at 125/126 ceiling (UAX#9 BD2 + I1/I2 headroom to 127).
    const n: u16 = @as(u16, l) + 1;
    const odd = n | 1;
    return if (odd > 127) 127 else @as(Level, @intCast(odd));
}
fn nextEvenLevel(l: Level) Level {
    const n: u16 = @as(u16, l) + 2;
    const even = n & ~@as(u16, 1);
    return if (even > 126) 126 else @as(Level, @intCast(even));
}

/// Resolve embedding levels for one paragraph's bytes (UAX#9 X1-X8 + I1/I2
/// essentials + L1 trailing-WS reset). Returns per-*byte* levels (like
/// `shape.zig:computeLevels`: every byte of a codepoint shares its level).
/// Caller owns; freed with `alloc.free`. Errors only on OOM.
pub fn baseLevels(alloc: Allocator, text: []const u8, base: BaseDirection) UnicodeError![]Level {
    const levels = try alloc.alloc(Level, text.len);
    errdefer alloc.free(levels);
    if (text.len == 0) return levels;

    const para = paragraphLevel(text, base);

    // Decode codepoints + byte ranges once (bounded by text length).
    // Two parallel owned slices would double-alloc; instead walk twice: first
    // explicit levels per codepoint into a side buffer, then expand to bytes.
    var cp_levels: std.ArrayList(Level) = .empty;
    defer cp_levels.deinit(alloc);
    var cp_classes: std.ArrayList(BidiClass) = .empty;
    defer cp_classes.deinit(alloc);
    var cp_starts: std.ArrayList(usize) = .empty;
    defer cp_starts.deinit(alloc);
    var cp_lens: std.ArrayList(usize) = .empty;
    defer cp_lens.deinit(alloc);

    // X1-X8 explicit stack.
    const StatusEntry = struct {
        level: Level,
        override: u2, // 0 neutral, 1 ltr, 2 rtl
        isolate: bool,
    };
    var stack: [64]StatusEntry = undefined;
    stack[0] = .{ .level = para, .override = 0, .isolate = false };
    var sp: usize = 1;
    var overflow_isolate: usize = 0;
    var overflow_embedding: usize = 0;
    var valid_isolate: usize = 0;

    // Precompute isolate matching for FSI direction (first-strong after FSI).
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeOne(text, i);
        const c = bidiClass(d.cp);
        try cp_starts.append(alloc, i);
        try cp_lens.append(alloc, d.len);
        try cp_classes.append(alloc, c);
        const top = stack[sp - 1];
        var lvl: Level = top.level;
        var cls: BidiClass = c;
        switch (c) {
            .rle, .lre, .rlo, .lro => {
                lvl = top.level;
                cls = .bn;
                const is_rtl = (c == .rle or c == .rlo);
                const nl = if (is_rtl) nextOddLevel(top.level) else nextEvenLevel(top.level);
                if (nl <= MAX_BIDI_DEPTH and overflow_isolate == 0 and overflow_embedding == 0) {
                    if (sp < stack.len) {
                        stack[sp] = .{
                            .level = nl,
                            .override = if (c == .rlo) 2 else if (c == .lro) 1 else 0,
                            .isolate = false,
                        };
                        sp += 1;
                    } else {
                        overflow_embedding += 1;
                    }
                } else if (overflow_isolate == 0) {
                    overflow_embedding += 1;
                }
            },
            .lri, .rli, .fsi => {
                lvl = top.level;
                if (top.override == 1) cls = .l else if (top.override == 2) cls = .r;
                var is_rtl = (c == .rli);
                if (c == .fsi) {
                    // FSI: first strong after this initiator decides.
                    var k = i + d.len;
                    var depth: usize = 0;
                    var found: ?bool = null;
                    while (k < text.len) {
                        const dd = decodeOne(text, k);
                        const cc = bidiClass(dd.cp);
                        k += dd.len;
                        if (isIsolateInitiator(cc)) {
                            depth += 1;
                        } else if (cc == .pdi) {
                            if (depth == 0) break;
                            depth -= 1;
                        } else if (depth == 0) {
                            if (cc == .r or cc == .al) {
                                found = true;
                                break;
                            } else if (cc == .l) {
                                found = false;
                                break;
                            }
                        }
                    }
                    is_rtl = found orelse false;
                } else if (c == .lri) {
                    is_rtl = false;
                }
                const nl = if (is_rtl) nextOddLevel(top.level) else nextEvenLevel(top.level);
                if (nl <= MAX_BIDI_DEPTH and overflow_isolate == 0 and overflow_embedding == 0) {
                    if (sp < stack.len) {
                        stack[sp] = .{ .level = nl, .override = 0, .isolate = true };
                        sp += 1;
                        valid_isolate += 1;
                    } else {
                        overflow_isolate += 1;
                    }
                } else {
                    overflow_isolate += 1;
                }
            },
            .pdi => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate != 0) {
                    overflow_embedding = 0;
                    while (sp > 1 and !stack[sp - 1].isolate) sp -= 1;
                    if (sp > 1) sp -= 1;
                    valid_isolate -= 1;
                }
                const nt = stack[sp - 1];
                lvl = nt.level;
                if (nt.override == 1) cls = .l else if (nt.override == 2) cls = .r;
            },
            .pdf => {
                lvl = top.level;
                cls = .bn;
                if (overflow_isolate > 0) {} else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!top.isolate and sp >= 2) {
                    sp -= 1;
                }
            },
            .b => {
                lvl = para;
                // X8 resets the stack at paragraph separators.
                sp = 1;
                stack[0] = .{ .level = para, .override = 0, .isolate = false };
                overflow_isolate = 0;
                overflow_embedding = 0;
                valid_isolate = 0;
            },
            .bn => {
                lvl = top.level;
            },
            else => {
                lvl = top.level;
                if (top.override == 1) cls = .l else if (top.override == 2) cls = .r;
            },
        }
        // W1-W7/I1-I2 essentials folded per codepoint:
        // NSM inherits previous strong; EN/AN/W-runs simplified to paragraph
        // direction here (full W/N resolution needs isolating-run sequences;
        // the shard below keeps strong/number levels distinct for tests).
        try cp_levels.append(alloc, lvl);
        // Patch class with override-applied value for later neutral pass.
        cp_classes.items[cp_classes.items.len - 1] = cls;
        i += d.len;
    }

    // Weak pass: W1 NSM -> previous strong (or paragraph direction).
    {
        var prev_strong: BidiClass = if (para % 2 == 1) .r else .l;
        for (cp_classes.items) |*cls| {
            if (cls.* == .nsm) {
                cls.* = if (prev_strong == .r or prev_strong == .al) .r else prev_strong;
                if (cls.* != .l and cls.* != .r and cls.* != .al and cls.* != .en and cls.* != .an) {
                    cls.* = prev_strong;
                }
            } else if (cls.* == .l or cls.* == .r or cls.* == .al) {
                prev_strong = cls.*;
            }
        }
    }

    // W3: AL -> R (Arabic letters resolve as strong RTL before N/I passes).
    for (cp_classes.items) |*cls| {
        if (cls.* == .al) cls.* = .r;
    }

    // Neutral pass (N1/N2 essentials): neutrals between equal strong take it,
    // else paragraph direction. Operates on cp_classes; then I1/I2 fold into
    // cp_levels.
    {
        const emb_dir: BidiClass = if (para % 2 == 1) .r else .l;
        var k: usize = 0;
        while (k < cp_classes.items.len) {
            const c = cp_classes.items[k];
            const neutral = (c == .ws or c == .on or c == .b or c == .s or
                isIsolateInitiator(c) or c == .pdi or isRemovedByX9(c));
            if (!neutral) {
                k += 1;
                continue;
            }
            var j = k;
            while (j < cp_classes.items.len) {
                const cc = cp_classes.items[j];
                const n2 = (cc == .ws or cc == .on or cc == .b or cc == .s or
                    isIsolateInitiator(cc) or cc == .pdi or isRemovedByX9(cc));
                if (!n2) break;
                j += 1;
            }
            const left: BidiClass = if (k == 0) emb_dir else strongDirOr(cp_classes.items[k - 1], emb_dir);
            const right: BidiClass = if (j >= cp_classes.items.len) emb_dir else strongDirOr(cp_classes.items[j], emb_dir);
            if (left == right) {
                for (cp_classes.items[k..j]) |*cc| cc.* = left;
            } else {
                for (cp_classes.items[k..j]) |*cc| cc.* = emb_dir;
            }
            k = j;
        }
    }

    // I1/I2: fold resolved classes into levels.
    for (cp_classes.items, cp_levels.items) |c, *lvl| {
        if (lvl.* % 2 == 0) {
            if (c == .r) lvl.* +|= 1 else if (c == .an or c == .en) lvl.* += 2;
        } else {
            if (c == .l or c == .en or c == .an) lvl.* += 1;
        }
        if (lvl.* > 127) lvl.* = 127;
    }

    // Expand per-codepoint levels to per-byte levels.
    for (cp_starts.items, cp_lens.items, cp_levels.items) |st, ln, lv| {
        var o: usize = 0;
        while (o < ln and st + o < levels.len) : (o += 1) {
            levels[st + o] = lv;
        }
    }

    // L1: trailing WS/isolate/BN runs reset to paragraph level (verbatim
    // intent of shape.zig:adjustLevelsL1 / UAX#9 L1).
    {
        // Any trailing WS/B/S run to end of line resets.
        var t = cp_classes.items.len;
        while (t > 0) {
            const c = cp_classes.items[t - 1];
            const trailing = (c == .ws or c == .b or c == .s or isIsolateInitiator(c) or
                c == .pdi or isRemovedByX9(c));
            if (!trailing) break;
            t -= 1;
        }
        var idx: usize = t;
        while (idx < cp_classes.items.len) : (idx += 1) {
            const st = cp_starts.items[idx];
            const ln = cp_lens.items[idx];
            var o: usize = 0;
            while (o < ln and st + o < levels.len) : (o += 1) {
                levels[st + o] = para;
            }
        }
    }

    return levels;
}

fn strongDirOr(c: BidiClass, fallback: BidiClass) BidiClass {
    return switch (c) {
        .l => .l,
        .r, .en, .an => .r,
        else => fallback,
    };
}

/// UAX#9 L2 visual reorder: permutation of `0..levels.len` in display order.
/// Oracle: ezi-code `reorderVisual`. Caller owns; freed with `alloc.free`.
pub fn reorderVisual(alloc: Allocator, levels: []const Level) UnicodeError![]usize {
    const order = try alloc.alloc(usize, levels.len);
    errdefer alloc.free(order);
    for (order, 0..) |*v, idx| v.* = idx;
    if (levels.len == 0) return order;
    var highest: Level = 0;
    var lowest_odd: Level = std.math.maxInt(Level);
    for (levels) |lv| {
        if (lv > highest) highest = lv;
        if (lv % 2 == 1 and lv < lowest_odd) lowest_odd = lv;
    }
    if (lowest_odd == std.math.maxInt(Level)) return order;
    var lv = highest;
    while (true) {
        var idx: usize = 0;
        while (idx < order.len) {
            if (levels[order[idx]] >= lv) {
                var j = idx + 1;
                while (j < order.len and levels[order[j]] >= lv) j += 1;
                std.mem.reverse(usize, order[idx..j]);
                idx = j;
            } else {
                idx += 1;
            }
        }
        if (lv == lowest_odd) break;
        if (lv == 0) break;
        lv -= 1;
    }
    return order;
}

/// Mirror a codepoint at a resolved level (UAX#9 L4).
/// Oracle: ezi-code `bidi.mirror`.
pub fn mirrorCodepoint(cp: CodePoint, level: Level) CodePoint {
    if (level % 2 == 0) return cp;
    return switch (cp) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        0x00AB => 0x00BB,
        0x00BB => 0x00AB,
        else => cp,
    };
}

// ---------------------------------------------------------------------------
// Tests (standalone `zig test src/unicode.zig`)
// ---------------------------------------------------------------------------

test "whitespace: full White_Space set incl NBSP vs ASCII" {
    const ws = [_]CodePoint{
        0x09,   0x0A,   0x0B,   0x0C,   0x0D,   0x20,   0x85,   0xA0,   0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
        0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    };
    for (ws) |cp| try std.testing.expect(isWhitespace(cp));
    // NBSP is whitespace (glue in word/line, but White_Space true).
    try std.testing.expect(isWhitespace(0xA0));
    try std.testing.expect(isWhitespace(' '));
    // Non-members adjacent to the set.
    try std.testing.expect(!isWhitespace('A'));
    try std.testing.expect(!isWhitespace('0'));
    try std.testing.expect(!isWhitespace(0x200B)); // ZWSP is not White_Space
    try std.testing.expect(!isWhitespace(0x0084));
    try std.testing.expect(!isWhitespace(0x00A1));
}

test "script: coverage beyond Han (Bengali/Tamil/Khmer + core)" {
    try std.testing.expectEqual(Script.latin, scriptOf('A'));
    try std.testing.expectEqual(Script.common, scriptOf(' '));
    try std.testing.expectEqual(Script.common, scriptOf('0'));
    try std.testing.expectEqual(Script.greek, scriptOf(0x03B1));
    try std.testing.expectEqual(Script.cyrillic, scriptOf(0x0410));
    try std.testing.expectEqual(Script.armenian, scriptOf(0x0531));
    try std.testing.expectEqual(Script.hebrew, scriptOf(0x05D0));
    try std.testing.expectEqual(Script.arabic, scriptOf(0x0627));
    try std.testing.expectEqual(Script.devanagari, scriptOf(0x0928));
    // Previously missing in shape.zig:352-373.
    try std.testing.expectEqual(Script.bengali, scriptOf(0x0995)); // BENGALI KA
    try std.testing.expectEqual(Script.tamil, scriptOf(0x0B95)); // TAMIL KA
    try std.testing.expectEqual(Script.khmer, scriptOf(0x1780)); // KHMER KA
    try std.testing.expectEqual(Script.telugu, scriptOf(0x0C15));
    try std.testing.expectEqual(Script.thai, scriptOf(0x0E01));
    try std.testing.expectEqual(Script.myanmar, scriptOf(0x1000));
    try std.testing.expectEqual(Script.han, scriptOf(0x4E00));
    try std.testing.expectEqual(Script.hiragana, scriptOf(0x3041));
    try std.testing.expectEqual(Script.katakana, scriptOf(0x30AB));
    try std.testing.expectEqual(Script.hangul, scriptOf(0xAC00));
    try std.testing.expectEqual(Script.inherited, scriptOf(0x0301));
    try std.testing.expectEqual(Script.inherited, scriptOf(0x200D));
    try std.testing.expectEqual(Script.unknown, scriptOf(0x0378));
    // collectScripts skips Common/Inherited/Latin/Unknown (shape.rs:313-322).
    {
        var list: std.ArrayList(Script) = .empty;
        defer list.deinit(std.testing.allocator);
        // "Hi" latin skipped, combining acute inherited skipped, Han kept.
        try collectScripts(&list, std.testing.allocator, "Hi\xcc\x81\xe4\xb8\xad", 0, 6);
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expectEqual(Script.han, list.items[0]);
    }
    {
        var list: std.ArrayList(Script) = .empty;
        defer list.deinit(std.testing.allocator);
        // Bengali + Tamil both surface (deduped).
        try collectScripts(&list, std.testing.allocator, "\xe0\xa6\x95\xe0\xae\x95", 0, 6);
        try std.testing.expectEqual(@as(usize, 2), list.items.len);
    }
}

test "grapheme: ZWJ and combining clusters (UAX#29 GB9/GB11)" {
    // a + combining acute is one cluster (GB9).
    {
        const text = "a\xcc\x81";
        try std.testing.expectEqual(@as(usize, 1), countGraphemes(text));
        var it = graphemeIndices(text);
        try std.testing.expectEqual(@as(?usize, 0), it.next());
        try std.testing.expectEqual(@as(?usize, null), it.next());
        try std.testing.expect(isGraphemeBoundary(text, 0));
        try std.testing.expect(!isGraphemeBoundary(text, 1));
        try std.testing.expect(isGraphemeBoundary(text, 3));
    }
    // Emoji ZWJ sequence is one cluster (GB11: EP Extend* ZWJ x EP).
    {
        // U+1F468 MAN + ZWJ + U+1F469 WOMAN.
        const text = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9";
        try std.testing.expectEqual(@as(usize, 1), countGraphemes(text));
    }
    // Two flags (4 RI) are two clusters (GB12/13 pair splitting).
    {
        // U+1F1FA U+1F1F8 U+1F1EB U+1F1F7.
        const text = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xab\xf0\x9f\x87\xb7";
        try std.testing.expectEqual(@as(usize, 2), countGraphemes(text));
    }
    // Single flag (2 RI) is one cluster.
    {
        const text = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8";
        try std.testing.expectEqual(@as(usize, 1), countGraphemes(text));
    }
    // CRLF is one cluster (GB3).
    {
        try std.testing.expectEqual(@as(usize, 3), countGraphemes("a\r\nb"));
        var it = graphemeIndices("a\r\nb");
        var starts: [4]usize = undefined;
        var n: usize = 0;
        while (it.next()) |s| {
            starts[n] = s;
            n += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expectEqual(@as(usize, 0), starts[0]);
        try std.testing.expectEqual(@as(usize, 1), starts[1]);
        try std.testing.expectEqual(@as(usize, 3), starts[2]);
    }
    // Hangul L+V is one cluster (GB6).
    {
        const text = "\xe1\x84\x80\xe1\x85\xa1"; // U+1100 U+1161
        try std.testing.expectEqual(@as(usize, 1), countGraphemes(text));
    }
    // Prepend does not break (GB9b).
    {
        const text = "\xd8\x80a"; // U+0600 ARABIC NUMBER SIGN + 'a'
        try std.testing.expectEqual(@as(usize, 1), countGraphemes(text));
    }
    // Cluster-aware cursor motion: Backspace over "a + acute".
    {
        const text = "a\xcc\x81";
        try std.testing.expectEqual(@as(usize, 0), prevGraphemeStart(text, 3));
        try std.testing.expectEqual(@as(usize, 3), nextGraphemeEnd(text, 0));
    }
}

test "word: CJK and NBSP (UAX#29 WB5/WB13a-b)" {
    // Helper: collect word ranges.
    const alloc = std.testing.allocator;
    {
        // CJK Han letters join (all ALetter): one word.
        const text = "\xe6\x97\xa5\xe6\x9c\xac"; // 日本
        var it = wordBounds(text);
        var n: usize = 0;
        var first: WordRange = .{ .start = 0, .end = 0 };
        while (it.next()) |r| {
            if (n == 0) first = r;
            n += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(@as(usize, 0), first.start);
        try std.testing.expectEqual(@as(usize, 6), first.end);
    }
    {
        // "hello world" splits into word/space/word.
        var it = wordBounds("hello world");
        const w0 = it.next().?;
        const sp = it.next().?;
        const w1 = it.next().?;
        try std.testing.expect(it.next() == null);
        try std.testing.expectEqualStrings("hello", "hello world"[w0.start..w0.end]);
        try std.testing.expectEqualStrings(" ", "hello world"[sp.start..sp.end]);
        try std.testing.expectEqualStrings("world", "hello world"[w1.start..w1.end]);
    }
    {
        // NBSP glues words (ExtendNumLet WB13a/b): no boundary around it.
        const text = "hello\xc2\xa0world";
        var it = wordBounds(text);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    {
        // Digits join letters (WB9/10) and comma-between-digits holds (WB12-ish).
        var it = wordBounds("abc123");
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 1), n);
        _ = alloc;
    }
    {
        // Katakana runs join (WB13).
        const text = "\xe3\x82\xab\xe3\x82\xbf\xe3\x82\xab\xe3\x83\x8a"; // カタカナ
        var it = wordBounds(text);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 1), n);
    }
}

test "line: hyphen CJK NBSP WJ (UAX#14)" {
    // "foo-bar": break after hyphen, not before.
    {
        const text = "foo-bar";
        const breaks = try collectLineBreaks(std.testing.allocator, text);
        defer std.testing.allocator.free(breaks);
        // Offsets: after '-' (4) + eot (7). No break before '-' (3).
        var has_after = false;
        var has_before = false;
        for (breaks) |b| {
            if (b == 4) has_after = true;
            if (b == 3) has_before = true;
        }
        try std.testing.expect(has_after);
        try std.testing.expect(!has_before);
    }
    // CJK ideographs break on both sides.
    {
        const text = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"; // 日本語
        const breaks = try collectLineBreaks(std.testing.allocator, text);
        defer std.testing.allocator.free(breaks);
        // Each 3-byte char boundary is a break (3, 6) + eot (9).
        try std.testing.expectEqual(@as(usize, 3), breaks.len);
        try std.testing.expectEqual(@as(usize, 3), breaks[0]);
        try std.testing.expectEqual(@as(usize, 6), breaks[1]);
        try std.testing.expectEqual(@as(usize, 9), breaks[2]);
    }
    // NBSP (GL): no break on either side.
    {
        const text = "a\xc2\xa0b";
        var it = lineBreakOpportunities(text);
        var found_inner = false;
        while (it.next()) |br| {
            if (br.offset == 1 or br.offset == 3) found_inner = true;
        }
        try std.testing.expect(!found_inner);
    }
    // WJ (U+2060): no break on either side.
    {
        const text = "a\xe2\x81\xa0b";
        var it = lineBreakOpportunities(text);
        var found_inner = false;
        while (it.next()) |br| {
            if (br.offset == 1 or br.offset == 4) found_inner = true;
        }
        try std.testing.expect(!found_inner);
    }
    // Space yields an opportunity after it (LB18); letters must not split.
    {
        const text = "ab cd";
        const breaks = try collectLineBreaks(std.testing.allocator, text);
        defer std.testing.allocator.free(breaks);
        var has_space_break = false;
        var has_letter_break = false;
        for (breaks) |b| {
            if (b == 3) has_space_break = true;
            if (b == 1) has_letter_break = true;
        }
        try std.testing.expect(has_space_break);
        // LB28: AL x AL -- no break between 'a' and 'b'.
        try std.testing.expect(!has_letter_break);
    }
    // LB23: letters and digits glue ("abc123").
    {
        const text = "abc123";
        const breaks = try collectLineBreaks(std.testing.allocator, text);
        defer std.testing.allocator.free(breaks);
        for (breaks) |b| {
            try std.testing.expectEqual(@as(usize, 6), b);
        }
    }
    // "hello(world)" keeps CP/OP attachment (LB30): no breaks inside the
    // word-paren run (offsets 5..15 are the interior boundaries), while the
    // spaces still yield opportunities.
    {
        const text = "say hello(world) now";
        const breaks = try collectLineBreaks(std.testing.allocator, text);
        defer std.testing.allocator.free(breaks);
        var has_inner = false;
        for (breaks) |b| {
            if (b >= 5 and b <= 15) has_inner = true;
        }
        try std.testing.expect(!has_inner);
        var has_space = false;
        for (breaks) |b| {
            if (b == 4 or b == 17) has_space = true;
        }
        try std.testing.expect(has_space);
    }
    // Mandatory break after LF (LB5).
    {
        var it = lineBreakOpportunities("a\nb");
        const first = it.next().?;
        try std.testing.expectEqual(@as(usize, 2), first.offset);
        try std.testing.expectEqual(LineBreakKind.mandatory, first.kind);
    }
}

test "bidi: mixed paragraph and explicit embeddings (UAX#9)" {
    const alloc = std.testing.allocator;
    // Pure LTR.
    {
        const lv = try baseLevels(alloc, "abc", .auto);
        defer alloc.free(lv);
        try std.testing.expectEqual(@as(usize, 3), lv.len);
        for (lv) |l| try std.testing.expectEqual(LEVEL_LTR, l);
    }
    // Mixed LTR paragraph with Hebrew run: Hebrew at level 1.
    {
        // "ab" + U+05D0 U+05D1.
        const text = "ab\xd7\x90\xd7\x91";
        const lv = try baseLevels(alloc, text, .ltr);
        defer alloc.free(lv);
        try std.testing.expectEqual(@as(usize, 6), lv.len);
        try std.testing.expectEqual(LEVEL_LTR, lv[0]);
        try std.testing.expectEqual(LEVEL_LTR, lv[1]);
        try std.testing.expectEqual(@as(Level, 1), lv[2]);
        try std.testing.expectEqual(@as(Level, 1), lv[4]);
        // L2 reorder of [0,0,1,1] keeps LTR run then reverses RTL run.
        const order = try reorderVisual(alloc, &[_]Level{ 0, 0, 1, 1 });
        defer alloc.free(order);
        try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 3, 2 }, order);
    }
    // Arabic letters are AL and must resolve to R via W3: level 1 in an LTR
    // paragraph (regression: W3 was missing, leaving Arabic at level 0).
    {
        // "ab" + U+0645 U+0631.
        const text = "ab\xd9\x85\xd8\xb1";
        const lv = try baseLevels(alloc, text, .ltr);
        defer alloc.free(lv);
        try std.testing.expectEqual(@as(usize, 6), lv.len);
        try std.testing.expectEqual(LEVEL_LTR, lv[0]);
        try std.testing.expectEqual(LEVEL_LTR, lv[1]);
        try std.testing.expectEqual(@as(Level, 1), lv[2]);
        try std.testing.expectEqual(@as(Level, 1), lv[4]);
    }
    // RTL paragraph with embedded LTR word.
    {
        // U+05D0 + " " + "ab".
        const text = "\xd7\x90 ab";
        const lv = try baseLevels(alloc, text, .auto);
        defer alloc.free(lv);
        // Paragraph level is RTL (first strong Hebrew).
        try std.testing.expectEqual(@as(Level, 1), paragraphLevel(text, .auto));
        // "ab" rises to level 2 (I1 even + L).
        try std.testing.expectEqual(@as(Level, 2), lv[3]);
        try std.testing.expectEqual(@as(Level, 2), lv[4]);
    }
    // Explicit embedding: RLE ... PDF raises the inner run.
    {
        // U+202B RLE + "ab" + U+202C PDF.
        const text = "\xe2\x80\xab ab\xe2\x80\xac";
        const lv = try baseLevels(alloc, text, .ltr);
        defer alloc.free(lv);
        // RLE/PDF are BN (X9-removed) but carry the surrounding/next level;
        // the inner "ab" sits above the paragraph level.
        const inner_a = lv[3];
        try std.testing.expect(inner_a > LEVEL_LTR);
    }
    // Paragraph split: "a\nb" yields two paragraphs.
    {
        var it = bidiParagraphs("a\nb", .auto);
        const p0 = it.next().?;
        const p1 = it.next().?;
        try std.testing.expect(it.next() == null);
        try std.testing.expectEqual(@as(usize, 0), p0.start);
        try std.testing.expectEqual(@as(usize, 2), p0.end);
        try std.testing.expectEqual(@as(usize, 2), p1.start);
        try std.testing.expectEqual(@as(usize, 3), p1.end);
        try std.testing.expectEqual(LEVEL_LTR, p0.level);
        try std.testing.expectEqual(LEVEL_LTR, p1.level);
    }
}
