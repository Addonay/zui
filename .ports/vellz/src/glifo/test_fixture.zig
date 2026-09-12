//! Test-only fixture loader for the pinned font blobs.
//!
//! `zig build test` runs the test binary with the build root as the working
//! directory (the same convention `tools/scene.zig` relies on), so the pinned
//! upstream fonts are read straight from `tests/fixtures/upstream`. Blobs are
//! cached for the process and allocated from `std.heap.page_allocator` so the
//! testing allocator never sees the long-lived bytes.

const std = @import("std");

pub const roboto_path = "tests/fixtures/upstream/Roboto-Regular.ttf";
pub const noto_color_path = "tests/fixtures/upstream/NotoColorEmoji-Subset.ttf";
pub const noto_cbtf_path = "tests/fixtures/upstream/NotoColorEmoji-CBTF-Subset.ttf";
pub const colr_test_glyphs_path = "tests/fixtures/upstream/test_glyphs-glyf_colr_1.ttf";
pub const inconsolata_path = "tests/fixtures/upstream/Inconsolata.ttf";

var roboto_cache: ?[]const u8 = null;
var noto_color_cache: ?[]const u8 = null;
var noto_cbtf_cache: ?[]const u8 = null;
var colr_test_glyphs_cache: ?[]const u8 = null;
var inconsolata_cache: ?[]const u8 = null;

fn load(path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.heap.page_allocator,
        .unlimited,
    );
}

pub fn roboto() ![]const u8 {
    if (roboto_cache == null) roboto_cache = try load(roboto_path);
    return roboto_cache.?;
}

pub fn notoColor() ![]const u8 {
    if (noto_color_cache == null) noto_color_cache = try load(noto_color_path);
    return noto_color_cache.?;
}

pub fn notoCbtf() ![]const u8 {
    if (noto_cbtf_cache == null) noto_cbtf_cache = try load(noto_cbtf_path);
    return noto_cbtf_cache.?;
}

pub fn colrTestGlyphs() ![]const u8 {
    if (colr_test_glyphs_cache == null) colr_test_glyphs_cache = try load(colr_test_glyphs_path);
    return colr_test_glyphs_cache.?;
}

pub fn inconsolata() ![]const u8 {
    if (inconsolata_cache == null) inconsolata_cache = try load(inconsolata_path);
    return inconsolata_cache.?;
}

test "fixtures are readable and non-empty" {
    try std.testing.expect((try roboto()).len > 100_000);
    try std.testing.expect((try notoColor()).len > 1_000);
    try std.testing.expect((try notoCbtf()).len > 1_000);
    try std.testing.expect((try colrTestGlyphs()).len > 10_000);
    try std.testing.expect((try inconsolata()).len > 100_000);
}
