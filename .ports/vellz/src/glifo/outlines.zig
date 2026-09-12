//! Outline scaler dispatch: TrueType `glyf` or CFF/CFF2.
//!
//! `Font.outlines()` resolves a face to one of the two outline engines. Both
//! expose the same API through this union, so `outline_cache.zig`, `glyph.zig`
//! and the oracle dump code stay format-agnostic (`glifo`'s
//! `OutlineGlyphCollection`/`OutlineGlyphFormat` equivalent).
//!
//! The wrapper keeps the `glyf`-specific surface (`getGlyph` for `sbix`
//! y-bearings and COLR outline clips) but callers that need a format-neutral
//! "has an outline" check use `hasGlyph`. CFF rows report
//! `error.Unsupported` for `getGlyph`, because a `read-fonts` `Glyph` value
//! only exists for `glyf`; CFF hinting is likewise `error.Unsupported`
//! (see `cff.zig`).

const std = @import("std");

const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const cff = @import("cff.zig");
const raw = @import("tables/glyf.zig");

pub const Font = font_mod.Font;
pub const GlyphId = font_mod.GlyphId;
pub const HintInstance = glyf.HintInstance;
pub const HintProgram = glyf.HintProgram;
pub const AdjustedMetrics = glyf.AdjustedMetrics;
pub const DrawSettings = glyf.DrawSettings;
pub const PathStyle = glyf.PathStyle;

/// Union of the `glyf` and CFF draw errors.
pub const DrawError = glyf.DrawError || cff.DrawError;

pub const Outlines = union(enum) {
    glyf: glyf.Outlines,
    cff: cff.Outlines,

    /// Empty outline collection for faces with no `glyf`/CFF outlines
    /// (bitmap-only): every lookup reports `error.OutOfBounds`.
    pub fn empty(font: Font) Outlines {
        return .{ .glyf = glyf.Outlines.empty(font) };
    }

    pub fn isCff(self: *const Outlines) bool {
        return switch (self.*) {
            .cff => true,
            .glyf => false,
        };
    }

    /// The `skrifa` `OutlineGlyphFormat` name used in the canonical dumps.
    pub fn formatName(self: *const Outlines) []const u8 {
        return switch (self.*) {
            .glyf => "glyf",
            .cff => |*c| if (c.version == 2) "cff2" else "cff",
        };
    }

    pub fn supportsHinting(self: *const Outlines) bool {
        return switch (self.*) {
            .glyf => true,
            .cff => false,
        };
    }

    pub fn unitsPerEm(self: *const Outlines) u16 {
        return switch (self.*) {
            .glyf => |*g| g.unitsPerEm(),
            .cff => |*c| c.unitsPerEm(),
        };
    }

    pub fn glyphCount(self: *const Outlines) usize {
        return switch (self.*) {
            .glyf => |*g| g.glyphCount(),
            .cff => |*c| c.glyphCount(),
        };
    }

    /// Format-neutral "the face has an outline for `gid`" check. For `glyf`
    /// this is the `read-fonts` `glyph(gid).is_some()` test; for CFF every id
    /// below `charstrings.count` exists.
    pub fn hasGlyph(self: *const Outlines, gid: GlyphId) bool {
        return switch (self.*) {
            .glyf => |*g| blk: {
                _ = g.getGlyph(gid) catch break :blk false;
                break :blk true;
            },
            .cff => |*c| gid < c.glyphCount(),
        };
    }

    /// `read-fonts` `Glyph` access, `glyf` only. CFF callers must use
    /// `hasGlyph` + `draw`; the metric that consumes this (`sbix` y-bearing)
    /// has no CFF fixture.
    pub fn getGlyph(self: *const Outlines, gid: GlyphId) DrawError!?raw.Glyph {
        return switch (self.*) {
            .glyf => |*g| g.getGlyph(gid),
            .cff => error.Unsupported,
        };
    }

    pub fn computeScale(self: *const Outlines, ppem: ?f32) glyf.Scale26Dot6 {
        return switch (self.*) {
            .glyf => |*g| g.computeScale(ppem),
            .cff => |*c| glyf.Scale26Dot6.init(ppem, c.upem),
        };
    }

    /// The hinted scale; for CFF this is only reachable through a code path
    /// that rejects hinting first, but the arithmetic matches `glyf`.
    pub fn computeHintedScale(self: *const Outlines, ppem: ?f32) glyf.Scale26Dot6 {
        return switch (self.*) {
            .glyf => |*g| g.computeHintedScale(ppem),
            .cff => |*c| glyf.Scale26Dot6.init(ppem, c.upem),
        };
    }

    /// `(scale, rounded ppem)` pair `HintingInstance::reconfigure` expects.
    pub fn hintedScaleAndPpem(self: *const Outlines, size: f32) struct { scale: i32, ppem: i32 } {
        return switch (self.*) {
            .glyf => |*g| blk: {
                const pair = g.hintedScaleAndPpem(size);
                break :blk .{ .scale = pair.scale, .ppem = pair.ppem };
            },
            .cff => |*c| blk: {
                const scale = glyf.Scale26Dot6.init(size, c.upem).scale_bits;
                const ppem = (glyf.fixedMul(scale, @as(i32, c.upem)) +% 32) >> 6;
                break :blk .{ .scale = scale, .ppem = ppem };
            },
        };
    }

    /// The `fpgm`/`prep` program for reconfigure; CFF has none (hinting is
    /// rejected before this is reached).
    pub fn hintProgram(self: *const Outlines) ?HintProgram {
        return switch (self.*) {
            .glyf => |*g| g.program,
            .cff => null,
        };
    }

    /// Builds and configures a `HintInstance`; `error.Unsupported` for CFF
    /// until the `skrifa` CFF hinter (`cff/hint.rs`) is ported.
    pub fn createHintInstance(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        size: f32,
        target: glyf.HintTarget,
    ) DrawError!HintInstance {
        return switch (self.*) {
            .glyf => |*g| g.createHintInstance(allocator, size, target),
            .cff => error.Unsupported,
        };
    }

    pub fn draw(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        gid: GlyphId,
        settings: DrawSettings,
        pen: anytype,
    ) DrawError!AdjustedMetrics {
        return switch (self.*) {
            .glyf => |*g| g.draw(allocator, gid, settings, pen),
            .cff => |*c| c.draw(allocator, gid, settings, pen),
        };
    }
};

test "glyf dispatch draws and rejects unused CFF pieces" {
    const testing = std.testing;
    const fixture = @import("test_fixture.zig");
    const font = try Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    try testing.expect(!outlines.isCff());
    try testing.expect(outlines.supportsHinting());
    try testing.expect(outlines.hasGlyph(37));
    try testing.expect(!outlines.hasGlyph(99999));
}

test "cff dispatch reports glyph coverage" {
    const testing = std.testing;
    const fixture = @import("test_fixture.zig");
    const font = try Font.init(try fixture.sourceSerif(), 0);
    const outlines = try font.outlines();
    try testing.expect(outlines.isCff());
    try testing.expect(!outlines.supportsHinting());
    try testing.expect(outlines.hasGlyph(36));
    try testing.expectEqual(@as(usize, 1464), outlines.glyphCount());
    try testing.expectError(error.Unsupported, outlines.createHintInstance(
        testing.allocator,
        16.0,
        glyf.glifo_hint_target,
    ));
}
