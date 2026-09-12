//! Alignment-zone flags shared by the autohint metrics and style tables.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/metrics/blues.rs`
//! `BlueZones` (a transparent `u16` bit set). The constants match
//! FreeType's `AF_BLUE_PROPERTY_*` values after the skrifa remapping
//! documented in the upstream source.

const std = @import("std");

pub const BlueZones = struct {
    bits: u16 = 0,

    pub const none: BlueZones = .{ .bits = 0 };
    pub const top: BlueZones = .{ .bits = 1 << 1 };
    pub const sub_top: BlueZones = .{ .bits = 1 << 2 };
    pub const neutral: BlueZones = .{ .bits = 1 << 3 };
    pub const adjustment: BlueZones = .{ .bits = 1 << 4 };
    pub const x_height: BlueZones = .{ .bits = 1 << 5 };
    pub const long: BlueZones = .{ .bits = 1 << 6 };
    /// Alias for `sub_top` used by CJK horizontal zones.
    pub const horizontal: BlueZones = sub_top;
    /// Alias for `top` used by CJK right zones.
    pub const right: BlueZones = top;

    pub fn contains(self: BlueZones, other: BlueZones) bool {
        return self.bits & other.bits == other.bits;
    }

    pub fn unionWith(self: BlueZones, other: BlueZones) BlueZones {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn intersect(self: BlueZones, other: BlueZones) BlueZones {
        return .{ .bits = self.bits & other.bits };
    }

    pub fn isTopLike(self: BlueZones) bool {
        return self.intersect(top.unionWith(sub_top)).bits != 0;
    }

    pub fn isTop(self: BlueZones) bool {
        return self.contains(top);
    }

    pub fn isSubTop(self: BlueZones) bool {
        return self.contains(sub_top);
    }

    pub fn isNeutral(self: BlueZones) bool {
        return self.contains(neutral);
    }

    pub fn isXHeight(self: BlueZones) bool {
        return self.contains(x_height);
    }

    pub fn isLong(self: BlueZones) bool {
        return self.contains(long);
    }

    pub fn isHorizontal(self: BlueZones) bool {
        return self.contains(horizontal);
    }

    pub fn isRight(self: BlueZones) bool {
        return self.contains(right);
    }

    pub fn retainTopLikeOrNeutral(self: BlueZones) BlueZones {
        return self.intersect(top.unionWith(sub_top).unionWith(neutral));
    }
};

/// One `(characters, zones)` pair from a script's blue-string table.
pub const BluePair = struct {
    chars: []const u8,
    zones: BlueZones,
};

test "blue zone predicates" {
    const z = BlueZones.top.unionWith(BlueZones.x_height);
    try std.testing.expect(z.isTop());
    try std.testing.expect(!z.isSubTop());
    try std.testing.expect(z.isTopLike());
    try std.testing.expect(z.isXHeight());
    try std.testing.expect(!z.isNeutral());
    try std.testing.expect(z.retainTopLikeOrNeutral().contains(BlueZones.top));
    try std.testing.expect(!z.retainTopLikeOrNeutral().contains(BlueZones.x_height));
    try std.testing.expect(BlueZones.right.contains(BlueZones.top));
}
