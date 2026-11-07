//! Parsing for file drags: text/uri-list as used by XDND and Wayland. Lines end in CRLF
//! or LF, `#` starts a comment, and paths are percent-encoded file URLs.
const std = @import("std");

/// The local paths in a uri-list. Anything else (other schemes, other hosts, malformed
/// escapes) is skipped, not fatal. The caller frees with `free_paths`.
pub fn parse_uri_list(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer free_list(allocator, &out);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t\x00");
        if (line.len == 0 or line[0] == '#') continue;
        const encoded = local_path(line) orelse continue;
        const path = decode_percent(allocator, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEscape => continue,
        };
        // A path with an embedded NUL cannot name a file, and is an attack on whoever opens it.
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
            allocator.free(path);
            continue;
        }
        out.append(allocator, path) catch |err| {
            allocator.free(path);
            return err;
        };
    }
    return out.toOwnedSlice(allocator);
}

pub fn free_paths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

fn free_list(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |p| allocator.free(p);
    list.deinit(allocator);
}

/// The encoded path of a file URL on this machine. `file:///a`, `file://localhost/a`,
/// and the old `file:/a` all count; `file://otherhost/a` is someone else's file.
fn local_path(uri: []const u8) ?[]const u8 {
    if (uri.len < 5 or !std.ascii.eqlIgnoreCase(uri[0..5], "file:")) return null;
    const rest = uri[5..];
    if (!std.mem.startsWith(u8, rest, "//")) return if (rest.len > 0 and rest[0] == '/') rest else null;
    const authority = rest[2..];
    const slash = std.mem.indexOfScalar(u8, authority, '/') orelse return null;
    const host = authority[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    return authority[slash..];
}

fn decode_percent(allocator: std.mem.Allocator, encoded: []const u8) error{ OutOfMemory, InvalidEscape }![]u8 {
    const out = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(out);
    var n: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] != '%') {
            out[n] = encoded[i];
            n += 1;
            continue;
        }
        if (i + 2 >= encoded.len) return error.InvalidEscape;
        const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidEscape;
        const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidEscape;
        out[n] = hi * 16 + lo;
        n += 1;
        i += 2;
    }
    return allocator.realloc(out, n) catch out[0..n];
}

const testing = std.testing;

fn expect_paths(text: []const u8, expected: []const []const u8) !void {
    const paths = try parse_uri_list(testing.allocator, text);
    defer free_paths(testing.allocator, paths);
    try testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |e, p| try testing.expectEqualStrings(e, p);
}

test "uri lists: plain files, CRLF, comments, blank lines" {
    try expect_paths("file:///home/a/x.txt\r\nfile:///b.png\r\n", &.{ "/home/a/x.txt", "/b.png" });
    try expect_paths("# a comment\nfile:///c\n\n", &.{"/c"});
    try expect_paths("", &.{});
    // Some sources add a trailing NUL or leave out the final newline.
    try expect_paths("file:///d\x00", &.{"/d"});
}

test "uri lists: percent escapes, including non-ASCII names" {
    try expect_paths("file:///my%20file%21.txt", &.{"/my file!.txt"});
    try expect_paths("file:///caf%C3%A9/%E4%BD%A0.txt", &.{"/caf\u{e9}/\u{4f60}.txt"});
    try expect_paths("file:///a%2Fb", &.{"/a/b"});
}

test "uri lists: hosts and schemes" {
    try expect_paths("file://localhost/e", &.{"/e"});
    try expect_paths("FILE:///f", &.{"/f"});
    try expect_paths("file:/old-style", &.{"/old-style"});
    try expect_paths("file://otherhost/g\nhttps://example.com/h\nsmb://x/y\n", &.{});
    try expect_paths("file://hostonly", &.{});
    try expect_paths("file:", &.{});
    try expect_paths("file:relative", &.{});
}

test "uri lists: bad entries are skipped and the rest kept" {
    try expect_paths("file:///bad%2\nfile:///bad%ZZ\nfile:///good\n", &.{"/good"});
    try expect_paths("file:///nul%00byte\nfile:///ok\n", &.{"/ok"});
}
