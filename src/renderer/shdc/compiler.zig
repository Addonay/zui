//! Native prebuilt shader compilers. Emulation layers are not assumed.
const std = @import("std");
pub fn bundledPath(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "bin/linux/sokol-shdc",
            .aarch64 => "bin/linux_arm64/sokol-shdc",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "bin/osx/sokol-shdc",
            .aarch64 => "bin/osx_arm64/sokol-shdc",
            else => null,
        },
        .windows => if (arch == .x86_64) "bin/win32/sokol-shdc.exe" else null,
        else => null,
    };
}
test "unsupported hosts can use a custom compiler without selecting a wrong binary" {
    try std.testing.expectEqualStrings("bin/linux/sokol-shdc", bundledPath(.linux, .x86_64).?);
    try std.testing.expectEqualStrings("bin/osx_arm64/sokol-shdc", bundledPath(.macos, .aarch64).?);
    try std.testing.expectEqualStrings("bin/win32/sokol-shdc.exe", bundledPath(.windows, .x86_64).?);
    try std.testing.expect(bundledPath(.linux, .riscv64) == null);
    try std.testing.expect(bundledPath(.freebsd, .x86_64) == null);
    try std.testing.expect(bundledPath(.windows, .aarch64) == null);
    try std.testing.expect(bundledPath(.windows, .x86) == null);
}
