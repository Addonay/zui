//! Fetching over HTTP for images (GPUI's `http_client` crate, reduced to what ZUI uses).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zui_http);

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

/// The default client, on `std.http` in an always-optimized library (`http_native.zig`): HTTP and
/// HTTPS, following redirects.
pub const StdClient = struct {
    native: ?*NativeClient,

    const NativeClient = opaque {};
    const NativeJob = opaque {};
    extern fn zui_http_create() ?*NativeClient;
    extern fn zui_http_destroy(client: *NativeClient) void;
    extern fn zui_http_start(client: *NativeClient, url: [*]const u8, url_len: usize) ?*NativeJob;
    extern fn zui_http_is_done(job: *NativeJob) bool;
    extern fn zui_http_finish(job: *NativeJob, cancel: bool, out: *[*]u8, out_len: *usize, reason: *[*:0]const u8) c_int;
    extern fn zui_http_free(body: [*]u8, len: usize) void;

    pub fn init() StdClient {
        return .{ .native = zui_http_create() };
    }

    /// Every `get` must have returned.
    pub fn deinit(self: *StdClient) void {
        if (self.native) |native| zui_http_destroy(native);
        self.native = null;
    }

    /// Blocks until the body is here, or until `io` cancels the caller, which cancels the fetch. The
    /// library has an `Io` of its own, so a short poll in the caller's is what makes that possible;
    /// next to a network round trip it costs nothing. The cause of a failure goes to the log.
    pub fn get(self: *StdClient, allocator: Allocator, io: Io, url: []const u8) anyerror![]u8 {
        const native = self.native orelse return error.OutOfMemory;
        const job = zui_http_start(native, url.ptr, url.len) orelse return error.OutOfMemory;
        var cancel = false;
        while (!zui_http_is_done(job)) {
            io.sleep(.fromMilliseconds(2), .awake) catch {
                cancel = true;
                break;
            };
        }
        var body: [*]u8 = undefined;
        var len: usize = 0;
        var reason: [*:0]const u8 = "";
        switch (zui_http_finish(job, cancel, &body, &len, &reason)) {
            0 => {},
            1 => return error.Canceled,
            else => {
                log.warn("{s}: {s}", .{ url, std.mem.span(reason) });
                return error.HttpFailed;
            },
        }
        defer zui_http_free(body, len);
        return allocator.dupe(u8, body[0..len]);
    }
};
