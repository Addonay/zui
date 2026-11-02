//! Default colors used by GPUI for base components.
const std = @import("std");
const color = @import("color.zig");

const Rgba = color.Rgba;
const rgb = color.rgb;

/// The appearance of the base colors, which varies with the system window appearance.
pub const DefaultAppearance = enum {
    /// Light appearance colors.
    light,
    /// Dark appearance colors.
    dark,

    pub const default: DefaultAppearance = .light;
};

/// The default set of colors used for styling base components.
pub const Colors = struct {
    /// Text color.
    text: Rgba,
    /// Selected text color.
    selected_text: Rgba,
    /// Background color.
    background: Rgba,
    /// Disabled color.
    disabled: Rgba,
    /// Selected color.
    selected: Rgba,
    /// Border color.
    border: Rgba,
    /// Separator color.
    separator: Rgba,
    /// Container color.
    container: Rgba,

    pub const default: Colors = Colors.light();

    /// Returns the default dark colors.
    pub fn dark() Colors {
        return .{
            .text = rgb(0xffffff),
            .selected_text = rgb(0xffffff),
            .disabled = rgb(0x565656),
            .selected = rgb(0x2457ca),
            .background = rgb(0x222222),
            .border = rgb(0x000000),
            .separator = rgb(0xd9d9d9),
            .container = rgb(0x262626),
        };
    }

    /// Returns the default light colors.
    pub fn light() Colors {
        return .{
            .text = rgb(0x252525),
            .selected_text = rgb(0xffffff),
            .background = rgb(0xffffff),
            .disabled = rgb(0xb0b0b0),
            .selected = rgb(0x2a63d9),
            .border = rgb(0xd9d9d9),
            .separator = rgb(0xe6e6e6),
            .container = rgb(0xf4f5f5),
        };
    }
};

test "light and dark palettes differ in background" {
    try std.testing.expect(Colors.light().background.to_u32() != Colors.dark().background.to_u32());
    try std.testing.expectEqual(@as(u32, 0xffffffff), Colors.default.background.to_u32());
}
