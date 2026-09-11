//! Backend link probe: verifies the vendored `harfbuzz` and `freetype`
//! binding libraries compile and link into cozmic. Kept as a permanent smoke
//! test so a broken dependency fails loudly instead of silently disabling the
//! real backend.

const std = @import("std");
const hb = @import("harfbuzz");
const ft = @import("freetype");

test "harfbuzz module links and reports a version" {
    const version = hb.versionString();
    try std.testing.expect(version.len > 0);
}

test "freetype module links and initializes a library" {
    var lib = try ft.Library.init();
    defer lib.deinit();
    const v = lib.version();
    try std.testing.expect(v.major > 0);
}
