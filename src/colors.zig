//! GPUI-shaped default color tokens.
const core = @import("core/root.zig");

pub const Colors = struct {
    text: core.Color,
    selected_text: core.Color,
    background: core.Color,
    disabled: core.Color,
    selected: core.Color,
    border: core.Color,
    separator: core.Color,
    container: core.Color,

    pub fn light() @This() {
        return .{
            .text = core.Color.hex(0x252525),
            .selected_text = core.Color.white,
            .background = core.Color.white,
            .disabled = core.Color.hex(0xb0b0b0),
            .selected = core.Color.hex(0x2a63d9),
            .border = core.Color.hex(0xd9d9d9),
            .separator = core.Color.hex(0xe6e6e6),
            .container = core.Color.hex(0xf4f5f5),
        };
    }

    pub fn dark() @This() {
        return .{
            .text = core.Color.white,
            .selected_text = core.Color.white,
            .background = core.Color.hex(0x222222),
            .disabled = core.Color.hex(0x565656),
            .selected = core.Color.hex(0x2457ca),
            .border = core.Color.black,
            .separator = core.Color.hex(0xd9d9d9),
            .container = core.Color.hex(0x262626),
        };
    }
};

pub const DefaultAppearance = enum { light, dark };

pub fn defaults(appearance: DefaultAppearance) Colors {
    return if (appearance == .dark) Colors.dark() else Colors.light();
}

test "default color tokens provide light and dark palettes" {
    const light = defaults(.light);
    const dark = defaults(.dark);
    try @import("std").testing.expect(light.background.a == 1 and dark.background.a == 1);
    try @import("std").testing.expect(light.background.r != dark.background.r);
}
