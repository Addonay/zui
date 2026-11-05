//! Fetching over HTTP for images (GPUI's `http_client` crate, reduced to what ZUI uses).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Replaces the built-in client with `Application.with_http_client` (GPUI `HttpClient`).
pub const HttpClient = struct {
    ctx: ?*anyopaque = null,
    /// Returns the body of a GET, owned by `allocator`. Called on a background thread, possibly on
    /// several at once. A blocking call should go through `io`, so that quitting can cancel it.
    get_fn: *const fn (ctx: ?*anyopaque, allocator: Allocator, io: Io, url: []const u8) anyerror![]u8,

    pub fn get(self: HttpClient, allocator: Allocator, io: Io, url: []const u8) anyerror![]u8 {
        return self.get_fn(self.ctx, allocator, io, url);
    }
};

/// The default client, on `std.http`: HTTP and HTTPS, following redirects.
pub const StdClient = struct {
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: Io) StdClient {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *StdClient) void {
        self.client.deinit();
    }

    pub fn get(self: *StdClient, allocator: Allocator, url: []const u8) anyerror![]u8 {
        var body: Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        const response = try self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
            .redirect_behavior = .init(8),
            // Some image hosts refuse requests that name no client.
            .headers = .{ .user_agent = .{ .override = "zui" } },
        });
        if (response.status.class() != .success) return error.HttpStatus;
        return body.toOwnedSlice();
    }
};
