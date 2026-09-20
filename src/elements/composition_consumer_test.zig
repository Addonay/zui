//! External-consumer smoke root. This file intentionally imports only the
//! public `zui` module, never `src/elements/*` internals.
const std = @import("std");
const zui = @import("zui");

const Card = struct {
    pub fn render(self: *@This(), ctx: *zui.ElementContext) zui.Element {
        _ = self;
        const state = ctx.useKeyed(State, 41, initState);
        state.visits += 1;
        return zui.div().keyed(ctx.key(41));
    }

    const State = struct { visits: u32 = 0 };
    fn initState() State {
        return .{};
    }
};

test "an external zui consumer composes a typed view through public exports" {
    var frame = try std.testing.allocator.create(zui.ElementFrame);
    defer std.testing.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(undefined, .{});
    var retained = zui.RetainedElementState.init(std.testing.allocator);
    defer retained.deinit();
    var scope = zui.CompositionScope.begin(frame, &retained, 1);
    var card = Card{};
    _ = scope.view(&card);
    _ = scope.view(struct {
        pub fn renderOnce(_: @This(), _: *zui.ElementContext) zui.Element {
            return zui.div().keyed(42);
        }
    }{});
    scope.end();
    try std.testing.expectEqual(@as(usize, 1), retained.len);
}
