//! The HTTP client as a static library, always built optimized (see `build.zig`).
//!
//! TLS in a Debug build of `std.crypto` adds about 0.9 s to each new connection, which a Debug app
//! feels on every image it fetches. Zig compiles `std` once per artifact with that artifact's mode,
//! so the only way to get a fast handshake in a Debug app is a separate artifact, and so this file
//! speaks a C ABI and owns its own `std.Io`.

const std = @import("std");
const Io = std.Io;
const gpa = std.heap.smp_allocator;

const Client = struct {
    threaded: Io.Threaded,
    client: std.http.Client,
};

const Job = struct {
    client: *Client,
    url: []u8,
    body: []u8 = &.{},
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    future: Io.Future(void) = undefined,

    fn run(job: *Job) void {
        defer job.done.store(true, .release);
        job.body = fetch(&job.client.client, job.url) catch |err| {
            job.failure = err;
            return;
        };
    }
};

fn fetch(client: *std.http.Client, url: []const u8) anyerror![]u8 {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .redirect_behavior = .init(8),
        // Some image hosts refuse requests that name no client.
        .headers = .{ .user_agent = .{ .override = "zui" } },
    });
    if (response.status.class() != .success) return error.HttpStatus;
    return body.toOwnedSlice();
}

export fn zui_http_create() ?*Client {
    const self = gpa.create(Client) catch return null;
    self.* = .{ .threaded = Io.Threaded.init(gpa, .{}), .client = undefined };
    self.client = .{ .allocator = gpa, .io = self.threaded.io() };
    return self;
}

/// Every job must have finished.
export fn zui_http_destroy(self: *Client) void {
    self.client.deinit();
    self.threaded.deinit();
    gpa.destroy(self);
}

/// Starts a fetch and returns at once. Each job must end with `zui_http_finish`.
export fn zui_http_start(self: *Client, url: [*]const u8, url_len: usize) ?*Job {
    const job = gpa.create(Job) catch return null;
    const owned = gpa.dupe(u8, url[0..url_len]) catch {
        gpa.destroy(job);
        return null;
    };
    job.* = .{ .client = self, .url = owned };
    job.future = self.threaded.io().concurrent(Job.run, .{job}) catch {
        gpa.free(owned);
        gpa.destroy(job);
        return null;
    };
    return job;
}

export fn zui_http_is_done(job: *Job) bool {
    return job.done.load(.acquire);
}

/// Ends the job, cancelling it if it is still running, which blocks only until it notices. Returns 0
/// with `out` set (free it with `zui_http_free`), 1 if it was cancelled, or 2 with `reason` set to a
/// static error name.
export fn zui_http_finish(job: *Job, cancel: bool, out: *[*]u8, out_len: *usize, reason: *[*:0]const u8) c_int {
    const io = job.client.threaded.io();
    if (cancel) job.future.cancel(io) else job.future.await(io);
    defer {
        gpa.free(job.url);
        gpa.destroy(job);
    }
    if (job.failure) |err| {
        if (err == error.Canceled) return 1;
        reason.* = @errorName(err);
        return 2;
    }
    if (cancel) {
        gpa.free(job.body);
        return 1;
    }
    out.* = job.body.ptr;
    out_len.* = job.body.len;
    return 0;
}

export fn zui_http_free(body: [*]u8, len: usize) void {
    gpa.free(body[0..len]);
}
