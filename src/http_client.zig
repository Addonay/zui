const std = @import("std");

/// Transport-neutral HTTP request/response contracts. A transport owns the
/// storage behind response slices and may implement this synchronously or
/// bridge it to an async runtime; ZUI itself performs no network I/O here.
pub const Method = enum { get, post, put, patch, delete, head, options };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    uri: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
    timeout_ns: ?u64 = null,

    pub fn validate(self: Request) Error!void {
        if (self.uri.len == 0) return error.InvalidRequest;
        if (self.uri[0] == ' ' or std.mem.indexOfScalar(u8, self.uri, '\n') != null) {
            return error.InvalidRequest;
        }
        if (self.timeout_ns) |timeout| if (timeout == 0) return error.InvalidRequest;
    }
};

pub const Response = struct {
    status: u16,
    headers: []const Header = &.{},
    body: []const u8 = &.{},

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub const Error = error{
    Cancelled,
    InvalidRequest,
    Unsupported,
    TransportFailure,
};

const CancellationState = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const CancellationToken = struct {
    state: *CancellationState,

    pub fn isCancelled(self: CancellationToken) bool {
        return self.state.cancelled.load(.acquire);
    }

    pub fn throwIfCancelled(self: CancellationToken) Error!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub const CancellationSource = struct {
    allocator: std.mem.Allocator,
    state: *CancellationState,

    pub fn init(allocator: std.mem.Allocator) !CancellationSource {
        return .{ .allocator = allocator, .state = try allocator.create(CancellationState) };
    }

    pub fn token(self: *const CancellationSource) CancellationToken {
        return .{ .state = self.state };
    }

    pub fn cancel(self: *CancellationSource) void {
        self.state.cancelled.store(true, .release);
    }

    pub fn deinit(self: *CancellationSource) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }
};

pub const Client = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (*anyopaque, Request, CancellationToken) Error!Response,
    };

    pub fn send(self: Client, request: Request, cancellation: CancellationToken) Error!Response {
        try request.validate();
        try cancellation.throwIfCancelled();
        const response = try self.vtable.send(self.context, request, cancellation);
        try cancellation.throwIfCancelled();
        return response;
    }

    pub fn get(self: Client, uri: []const u8, cancellation: CancellationToken) Error!Response {
        return self.send(.{ .method = .get, .uri = uri }, cancellation);
    }

    pub fn postJson(self: Client, uri: []const u8, body: []const u8, cancellation: CancellationToken) Error!Response {
        return self.send(.{
            .method = .post,
            .uri = uri,
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .body = body,
        }, cancellation);
    }
};

/// Safe default provider, equivalent to GPUI's unavailable/null client.
pub const NullClient = struct {
    pub fn client(self: *NullClient) Client {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }

    fn send(_: *anyopaque, _: Request, cancellation: CancellationToken) Error!Response {
        try cancellation.throwIfCancelled();
        return error.Unsupported;
    }
};

/// Deterministic provider for unit tests and headless consumers. It records
/// the last request and returns a configured response; it never opens a
/// socket or resolves a hostname.
pub const TestClient = struct {
    response: Response = .{ .status = 404 },
    last_request: ?Request = null,
    sends: usize = 0,

    pub fn client(self: *TestClient) Client {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: Request, cancellation: CancellationToken) Error!Response {
        const self: *TestClient = @ptrCast(@alignCast(context));
        try cancellation.throwIfCancelled();
        self.last_request = request;
        self.sends += 1;
        return self.response;
    }
};

test "test client records request and returns deterministic response" {
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var fake = TestClient{ .response = .{ .status = 201, .body = "created" } };
    const response = try fake.client().postJson("https://example.invalid/items", "{}", source.token());
    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expect(response.isSuccess());
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try std.testing.expectEqual(Method.post, fake.last_request.?.method);
    try std.testing.expectEqualStrings("{}", fake.last_request.?.body);
}

test "null client is explicit and cancellation wins before transport" {
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var null_client = NullClient{};
    try std.testing.expectError(error.Unsupported, null_client.client().get("https://example.invalid", source.token()));
    source.cancel();
    try std.testing.expectError(error.Cancelled, null_client.client().get("https://example.invalid", source.token()));
}

test "request validation and cancellation are deterministic" {
    var source = try CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var fake = TestClient{};
    try std.testing.expectError(error.InvalidRequest, fake.client().send(.{ .method = .get, .uri = "" }, source.token()));
    try std.testing.expectEqual(@as(usize, 0), fake.sends);
    source.cancel();
    try std.testing.expectError(error.Cancelled, fake.client().send(.{ .method = .get, .uri = "https://example.invalid" }, source.token()));
}
