//! Deterministic app context for headless app/view tests.
//!
//! This is intentionally backend-free. It supplies the same entity,
//! invalidation, and entity-scoped task boundaries used by App while making
//! frame advancement explicit for tests.

const std = @import("std");
const runtime = @import("runtime.zig");
const tasks = @import("tasks.zig");

pub const TestAppContext = struct {
    harness: runtime.TestHarness,
    task_runtime: tasks.TaskRuntime,
    quit_requested: bool = false,
    drawing_skipped: bool = false,

    pub fn init(allocator: std.mem.Allocator) !TestAppContext {
        var harness = try runtime.TestHarness.init(allocator);
        errdefer harness.deinit();
        var task_runtime = tasks.TaskRuntime.init(allocator, .{ .workers = 0 });
        task_runtime.start();
        return .{ .harness = harness, .task_runtime = task_runtime };
    }

    pub fn deinit(self: *TestAppContext) void {
        self.task_runtime.deinit();
        self.harness.deinit();
    }

    pub fn new(self: *TestAppContext, comptime T: type, options: T.Options) runtime.Entity(T) {
        return self.harness.new(T, options);
    }

    pub fn update(self: *TestAppContext, entity: anytype, comptime callback: anytype) @TypeOf(entity.update(callback)) {
        _ = self;
        return entity.update(callback);
    }

    pub fn invalidate(self: *TestAppContext) void {
        self.harness.store.invalidate();
    }

    pub fn step(self: *TestAppContext) void {
        self.task_runtime.drainTimers(0);
        self.task_runtime.drainCompletions();
    }

    pub fn skipDrawing(self: *TestAppContext) void {
        self.drawing_skipped = true;
    }

    pub fn quit(self: *TestAppContext) void {
        self.quit_requested = true;
    }

    pub fn shouldQuit(self: *const TestAppContext) bool {
        return self.quit_requested;
    }
};

test "test app context schedules entity completion and invalidation" {
    const t = std.testing;
    const Counter = struct {
        pub const Options = struct {};
        value: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    var app = try TestAppContext.init(t.allocator);
    defer app.deinit();
    const entity = app.new(Counter, .{});
    var state: u32 = 0;
    var cx = runtime.Context(Counter){ .store = &app.harness.store, .current = entity, .window = null };
    _ = try cx.spawn(&app.task_runtime, &state, struct {
        fn run(value: **u32, _: tasks.Cancel) void {
            value.*.* = 4;
        }
    }.run, struct {
        fn done(value: *Counter, context: *runtime.Context(Counter), result: **u32) void {
            value.value = result.*.*;
            context.notify();
        }
    }.done);
    app.step();
    try t.expectEqual(@as(u32, 4), entity.read().value);
    try t.expect(app.harness.store.dirty);
}
