//! Port of peniko 0.6.1 style.rs (Apache-2.0 OR MIT).
//!
//! The `Style`/`StyleRef` types are not ported: this port only needs the fill
//! rule, which is owned here because `vello_common` uses `peniko::Fill`.

const std = @import("std");

/// Describes the rule that determines the interior portion of a shape.
///
/// This is only relevant for self-intersecting paths; both rules produce the
/// same result otherwise.
pub const Fill = enum(u8) {
    /// Non-zero fill rule (the default).
    non_zero = 0,
    /// Even-odd fill rule.
    even_odd = 1,

    /// The upstream `Default` implementation: [`Fill.non_zero`].
    pub const default: Fill = .non_zero;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: Fill) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back into a fill rule, or `null` if it is
    /// unknown.
    pub fn fromU8(value: u8) ?Fill {
        if (value > 1) return null;
        return @fromBackingInt(@intCast(value));
    }
};

test "fill default and discriminants" {
    try std.testing.expectEqual(Fill.non_zero, Fill.default);
    try std.testing.expectEqual(@as(u8, 0), Fill.non_zero.toU8());
    try std.testing.expectEqual(@as(u8, 1), Fill.even_odd.toU8());
    try std.testing.expectEqual(Fill.even_odd, Fill.fromU8(1).?);
    try std.testing.expectEqual(@as(?Fill, null), Fill.fromU8(2));
}
