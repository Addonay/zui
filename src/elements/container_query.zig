//! Layout-time container query contract. The callback is invoked only after
//! the assigned bounds are known; it never paints a placeholder.
const core = @import("../core/root.zig");

pub const Query = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    render: *const fn (core.Size) void,
    pub fn assignedSize(self: Query, offered: core.Size) core.Size {
        return .{ .w = self.width orelse offered.w, .h = self.height orelse offered.h };
    }
    pub fn materialize(self: Query, offered: core.Size) core.Size {
        const size = self.assignedSize(offered);
        self.render(size);
        return size;
    }
};

pub fn containerQuery(render: *const fn (core.Size) void) Query {
    return .{ .render = render };
}

test "container query receives assigned geometry exactly once" {
    const S = struct {
        var calls: u8 = 0;
        var last: core.Size = .{};
        fn render(size: core.Size) void {
            calls += 1;
            last = size;
        }
    };
    S.calls = 0;
    const query = Query{ .render = S.render };
    try @import("std").testing.expectEqual(core.size(80, 40), query.materialize(core.size(80, 40)));
    try @import("std").testing.expectEqual(@as(u8, 1), S.calls);
    try @import("std").testing.expectEqual(core.size(80, 40), S.last);
}
