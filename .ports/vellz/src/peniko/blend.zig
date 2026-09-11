//! Port of peniko 0.6.1 blend.rs (Apache-2.0 OR MIT).
//!
//! Color mixing and layer composition functions from the W3C
//! *Compositing and Blending Level 1* draft.

const std = @import("std");

/// Defines the color mixing function for a [`BlendMode`].
pub const Mix = enum(u8) {
    /// Default blending: the source color simply replaces the destination.
    normal = 0,
    /// Source color multiplied by the destination color.
    multiply = 1,
    /// Multiplies the complements of backdrop and source, then complements.
    screen = 2,
    /// Multiplies or screens, depending on the backdrop color.
    overlay = 3,
    /// Selects the darker of backdrop and source.
    darken = 4,
    /// Selects the lighter of backdrop and source.
    lighten = 5,
    /// Brightens the backdrop to reflect the source; black produces no change.
    color_dodge = 6,
    /// Darkens the backdrop to reflect the source; white produces no change.
    color_burn = 7,
    /// Multiplies or screens, depending on the source color.
    hard_light = 8,
    /// Darkens or lightens, depending on the source color.
    soft_light = 9,
    /// Subtracts the darker of the two colors from the lighter.
    difference = 10,
    /// Like difference but lower in contrast.
    exclusion = 11,
    /// Hue of the source, saturation and luminosity of the backdrop.
    hue = 12,
    /// Saturation of the source, hue and luminosity of the backdrop.
    saturation = 13,
    /// Hue and saturation of the source, luminosity of the backdrop.
    color = 14,
    /// Luminosity of the source, hue and saturation of the backdrop.
    luminosity = 15,

    pub const default: Mix = .normal;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: Mix) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back into a mixing function, or `null` if it is
    /// unknown.
    pub fn fromU8(value: u8) ?Mix {
        if (value > 15) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Defines the layer composition function for a [`BlendMode`].
pub const Compose = enum(u8) {
    /// No regions are enabled.
    clear = 0,
    /// Only the source is present.
    copy = 1,
    /// Only the destination is present.
    dest = 2,
    /// The source is placed over the destination.
    src_over = 3,
    /// The destination is placed over the source.
    dest_over = 4,
    /// The parts of the source overlapping the destination are placed.
    src_in = 5,
    /// The parts of the destination overlapping the source are placed.
    dest_in = 6,
    /// The parts of the source outside the destination are placed.
    src_out = 7,
    /// The parts of the destination outside the source are placed.
    dest_out = 8,
    /// The source overlapping the destination replaces it; the destination is
    /// placed everywhere else.
    src_atop = 9,
    /// The destination overlapping the source replaces it; the source is
    /// placed everywhere else.
    dest_atop = 10,
    /// The non-overlapping regions of source and destination are combined.
    xor = 11,
    /// The sum of source and destination.
    plus = 12,
    /// Source and destination cross-fade.
    plus_lighter = 13,

    pub const default: Compose = .src_over;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: Compose) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back into a composition function, or `null` if
    /// it is unknown.
    pub fn fromU8(value: u8) ?Compose {
        if (value > 13) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Blend mode consisting of a color mixing function and a layer composition
/// function.
pub const BlendMode = struct {
    /// The color mixing function.
    mix: Mix = .normal,
    /// The layer composition function.
    compose: Compose = .src_over,

    /// The upstream `Default` implementation.
    pub const default: BlendMode = .{ .mix = .normal, .compose = .src_over };

    /// Creates a new blend mode from mixing and composition functions.
    pub fn new(mix: Mix, compose: Compose) BlendMode {
        return .{ .mix = mix, .compose = compose };
    }

    /// Creates a blend mode from either a [`Mix`] or a [`Compose`], with the
    /// other component defaulted. Equivalent to upstream's `From` impls.
    pub fn from(value: anytype) BlendMode {
        return switch (@TypeOf(value)) {
            Mix => .{ .mix = value },
            Compose => .{ .compose = value },
            else => @compileError("BlendMode.from expects a Mix or a Compose"),
        };
    }

    /// Returns whether this blend mode might cause destructive changes in the
    /// backdrop.
    ///
    /// Destructive blend modes disallow certain optimizations, such as
    /// skipping transparent paints.
    pub fn isDestructive(self: BlendMode) bool {
        return switch (self.compose) {
            .clear, .copy, .src_in, .dest_in, .src_out, .dest_atop => true,
            else => false,
        };
    }
};

test "default blend mode" {
    try std.testing.expectEqual(Mix.normal, BlendMode.default.mix);
    try std.testing.expectEqual(Compose.src_over, BlendMode.default.compose);
    try std.testing.expectEqual(BlendMode.default, BlendMode{});
}

test "from mix and compose" {
    try std.testing.expectEqual(
        BlendMode{ .mix = .multiply, .compose = .src_over },
        BlendMode.from(Mix.multiply),
    );
    try std.testing.expectEqual(
        BlendMode{ .mix = .normal, .compose = .dest_atop },
        BlendMode.from(Compose.dest_atop),
    );
    try std.testing.expectEqual(
        BlendMode{ .mix = .screen, .compose = .plus_lighter },
        BlendMode.new(.screen, .plus_lighter),
    );
}

test "is_destructive" {
    try std.testing.expect(BlendMode.from(Compose.clear).isDestructive());
    try std.testing.expect(BlendMode.from(Compose.copy).isDestructive());
    try std.testing.expect(BlendMode.from(Compose.src_in).isDestructive());
    try std.testing.expect(BlendMode.from(Compose.dest_in).isDestructive());
    try std.testing.expect(BlendMode.from(Compose.src_out).isDestructive());
    try std.testing.expect(BlendMode.from(Compose.dest_atop).isDestructive());

    try std.testing.expect(!BlendMode.from(Compose.src_over).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.dest_over).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.dest).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.dest_out).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.xor).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.plus).isDestructive());
    try std.testing.expect(!BlendMode.from(Compose.plus_lighter).isDestructive());
}

test "discriminants match upstream bytemuck Contiguous" {
    try std.testing.expectEqual(@as(u8, 0), Mix.normal.toU8());
    try std.testing.expectEqual(@as(u8, 15), Mix.luminosity.toU8());
    try std.testing.expectEqual(@as(u8, 0), Compose.clear.toU8());
    try std.testing.expectEqual(@as(u8, 13), Compose.plus_lighter.toU8());

    inline for (0..16) |value| {
        const tag = Mix.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u8, @intCast(value)), tag.toU8());
    }
    inline for (0..14) |value| {
        const tag = Compose.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u8, @intCast(value)), tag.toU8());
    }
    try std.testing.expectEqual(@as(?Mix, null), Mix.fromU8(16));
    try std.testing.expectEqual(@as(?Compose, null), Compose.fromU8(14));
}
