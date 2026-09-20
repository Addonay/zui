//! Backend-neutral surface geometry. Native surface ownership is supplied by
//! a platform adapter; this module only defines lifecycle and object-fit.
const core = @import("../core/root.zig");
pub const Fit = enum { contain, cover, fill };
pub const Source = struct { id: u64, size: core.Size };
pub const Surface = struct {
    source: Source,
    fit: Fit = .contain,
    released: bool = false,
    pub fn bounds(self: Surface, destination: core.Rect) core.Rect {
        if (self.fit == .fill or self.source.size.w <= 0 or self.source.size.h <= 0) return destination;
        const sx = destination.w / self.source.size.w;
        const sy = destination.h / self.source.size.h;
        const scale = if (self.fit == .cover) @max(sx, sy) else @min(sx, sy);
        const size = core.size(self.source.size.w * scale, self.source.size.h * scale);
        return .{ .x = destination.x + (destination.w - size.w) / 2, .y = destination.y + (destination.h - size.h) / 2, .w = size.w, .h = size.h };
    }
    pub fn release(self: *Surface) void {
        self.released = true;
    }
};

pub fn surface(source: Source) Surface {
    return .{ .source = source };
}
test "surface object fit is geometry only and release is deterministic" {
    var s = Surface{ .source = .{ .id = 7, .size = core.size(200, 100) } };
    const r = s.bounds(core.rect(0, 0, 100, 100));
    try @import("std").testing.expectEqual(core.rect(0, 25, 100, 50), r);
    s.release();
    try @import("std").testing.expect(s.released);
}
