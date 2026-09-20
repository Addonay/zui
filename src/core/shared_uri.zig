//! Owned URI value with lightweight component parsing.

const std = @import("std");
const SharedString = @import("shared_string.zig").SharedString;

pub const UriError = error{ InvalidUri, OutOfMemory };

pub const SharedUri = struct {
    owned: SharedString,
    scheme_end: ?usize,
    authority_start: usize,
    authority_end: usize,
    path_start: usize,
    path_end: usize,
    query_start: ?usize,
    fragment_start: ?usize,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) UriError!@This() {
        if (text.len == 0 or std.mem.indexOfScalar(u8, text, ' ') != null or std.mem.indexOfScalar(u8, text, '\n') != null) return error.InvalidUri;
        var scheme_end: ?usize = null;
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            if (colon == 0) return error.InvalidUri;
            for (text[0..colon], 0..) |c, i| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) {
                _ = i;
                return error.InvalidUri;
            };
            scheme_end = colon;
        }
        const frag = std.mem.indexOfScalar(u8, text, '#');
        const before_frag = frag orelse text.len;
        const query_pos = std.mem.indexOfScalar(u8, text[0..before_frag], '?');
        const before_query = query_pos orelse before_frag;
        const authority_start = if (scheme_end) |s| if (text.len >= s + 3 and std.mem.eql(u8, text[s + 1 .. s + 3], "//")) s + 3 else before_query else 0;
        const path_start = if (authority_start != 0) std.mem.indexOfScalarPos(u8, text, authority_start, '/') orelse before_query else 0;
        const authority_end = if (authority_start != 0) path_start else 0;
        const owned = SharedString.init(allocator, text) catch return error.OutOfMemory;
        return .{ .owned = owned, .scheme_end = scheme_end, .authority_start = authority_start, .authority_end = authority_end, .path_start = path_start, .path_end = before_query, .query_start = query_pos, .fragment_start = frag };
    }
    pub fn deinit(self: *@This()) void {
        self.owned.release();
        self.* = undefined;
    }
    pub fn slice(self: *const @This()) []const u8 {
        return self.owned.slice();
    }
    pub fn scheme(self: *const @This()) []const u8 {
        return if (self.scheme_end) |e| self.slice()[0..e] else "";
    }
    pub fn authority(self: *const @This()) []const u8 {
        return self.slice()[self.authority_start..self.authority_end];
    }
    pub fn path(self: *const @This()) []const u8 {
        return self.slice()[self.path_start..self.path_end];
    }
    pub fn query(self: *const @This()) []const u8 {
        const start = self.query_start orelse return "";
        return self.slice()[start + 1 .. self.fragment_start orelse self.slice().len];
    }
    pub fn fragment(self: *const @This()) []const u8 {
        const start = self.fragment_start orelse return "";
        return self.slice()[start + 1 ..];
    }
};

test "shared uri owns and exposes components" {
    var uri = try SharedUri.init(std.testing.allocator, "https://example.test/a?q=1#top");
    defer uri.deinit();
    try std.testing.expectEqualStrings("https", uri.scheme());
    try std.testing.expectEqualStrings("example.test", uri.authority());
    try std.testing.expectEqualStrings("/a", uri.path());
    try std.testing.expectEqualStrings("q=1", uri.query());
    try std.testing.expectEqualStrings("top", uri.fragment());
}
