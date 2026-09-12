//! Engine-neutral hinting instance.
//!
//! Mirrors `skrifa`'s `outline::HintingInstance`/`HinterKind`: for
//! `Engine::AutoFallback` an instruction-carrying TrueType font uses the
//! interpreter, and an instruction-less font falls back to the autohinter.
//! glifo always configures `HintingOptions::default()` (AutoFallback) with
//! `hint.glifo_target`, so this is the only selection logic needed.
//!
//! The `outlines.zig` dispatch union is the input: CFF faces have neither
//! engine ported (`error.Unsupported`), and the autohinter path takes the
//! `glyf` collection directly so it can hint instruction-less outlines that
//! `glyf.Outlines.draw` would reject an interpreter instance for.

const std = @import("std");
const glyf = @import("glyf.zig");
const outlines_mod = @import("outlines.zig");
const hint_mod = @import("hint.zig");
const autohint = @import("autohint/root.zig");

pub const Error = outlines_mod.DrawError;

pub const Kind = union(enum) {
    /// The embedded TrueType interpreter (`fpgm`/`prep` present).
    interpreter: hint_mod.HintInstance,
    /// The automatic hinter (instruction-less TrueType fonts).
    auto: autohint.Instance,
};

pub const HintingInstance = struct {
    /// The requested ppem (`Size::new(size)` upstream).
    size: f32 = 0,
    kind: Kind,

    pub fn deinit(self: *HintingInstance) void {
        switch (self.kind) {
            .interpreter => |*instance| instance.deinit(),
            .auto => |*instance| instance.deinit(),
        }
    }

    /// True when hinting should actually be applied for this instance.
    pub fn isEnabled(self: *const HintingInstance) bool {
        return switch (self.kind) {
            .interpreter => |*instance| instance.isEnabled(),
            .auto => |*instance| instance.isEnabled(),
        };
    }

    /// Normalized coordinates the instance was configured with (empty for the
    /// autohinter, which only takes empty coordinates). `HintCache` compares
    /// these for exact-match reuse.
    pub fn location(self: *const HintingInstance) []const glyf.NormalizedCoord {
        return switch (self.kind) {
            .interpreter => |*instance| instance.location(),
            .auto => &.{},
        };
    }
};

/// `Engine::AutoFallback` resolution: `prefer_interpreter` selects the
/// interpreter, everything else the autohinter. CFF has neither engine.
pub fn usesInterpreter(outlines: *const outlines_mod.Outlines) bool {
    return switch (outlines.*) {
        .glyf => |*g| g.prefer_interpreter,
        .cff => false,
    };
}

/// Creates and configures a hinting instance for `size`.
pub fn create(
    allocator: std.mem.Allocator,
    outlines: *const outlines_mod.Outlines,
    size: f32,
    coords: []const glyf.NormalizedCoord,
    target: hint_mod.Target,
) Error!HintingInstance {
    switch (outlines.*) {
        .cff => return error.Unsupported,
        .glyf => |*g| {
            if (g.prefer_interpreter) {
                return .{
                    .size = size,
                    .kind = .{ .interpreter = try outlines.createHintInstance(
                        allocator,
                        size,
                        coords,
                        target,
                    ) },
                };
            }
            // The autohinter draws the varied outlines itself; the port has
            // not threaded `gvar` deltas into it, so non-empty coordinates
            // stay a typed error instead of being silently dropped.
            return .{
                .size = size,
                .kind = .{ .auto = try autohint.Instance.init(allocator, g, target, coords) },
            };
        },
    }
}

/// Resets an existing instance for a (possibly different) font/size.
pub fn reconfigure(
    self: *HintingInstance,
    allocator: std.mem.Allocator,
    outlines: *const outlines_mod.Outlines,
    size: f32,
    coords: []const glyf.NormalizedCoord,
    target: hint_mod.Target,
) Error!void {
    self.size = size;
    switch (self.kind) {
        .interpreter => |*instance| {
            switch (outlines.*) {
                .cff => return error.Unsupported,
                .glyf => |*g| {
                    if (!g.prefer_interpreter) {
                        instance.deinit();
                        self.kind = .{ .auto = try autohint.Instance.init(
                            allocator,
                            g,
                            target,
                            coords,
                        ) };
                        return;
                    }
                    const sp = outlines.hintedScaleAndPpem(size);
                    const program = outlines.hintProgram() orelse return error.Unsupported;
                    instance.reconfigure(
                        program,
                        sp.scale,
                        sp.ppem,
                        target,
                        coords,
                        size,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.HintError,
                    };
                },
            }
        },
        .auto => |*instance| {
            switch (outlines.*) {
                .cff => return error.Unsupported,
                .glyf => |*g| {
                    if (g.prefer_interpreter) {
                        instance.deinit();
                        self.kind = .{ .interpreter = try outlines.createHintInstance(
                            allocator,
                            size,
                            coords,
                            target,
                        ) };
                        return;
                    }
                    // The autohint instance is per (font, location); rebuild it
                    // for the new outline collection like upstream's
                    // Engine::Auto path.
                    instance.deinit();
                    self.kind = .{ .auto = try autohint.Instance.init(allocator, g, target, coords) };
                },
            }
        },
    }
}

test "AutoFallback selects the autohinter for an instruction-less font" {
    const fixture = @import("test_fixture.zig");
    const font = try glyf.Font.init(try fixture.notoSans(), 0);
    const outlines = try font.outlines();
    try std.testing.expect(!usesInterpreter(&outlines));

    var instance = try create(
        std.testing.allocator,
        &outlines,
        16.0,
        &.{},
        glyf.glifo_hint_target,
    );
    defer instance.deinit();
    try std.testing.expect(instance.isEnabled());
    try std.testing.expectEqual(Kind.auto, std.meta.activeTag(instance.kind));
}

test "AutoFallback selects the interpreter for Roboto" {
    const fixture = @import("test_fixture.zig");
    const font = try glyf.Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    try std.testing.expect(usesInterpreter(&outlines));

    var instance = try create(
        std.testing.allocator,
        &outlines,
        16.0,
        &.{},
        glyf.glifo_hint_target,
    );
    defer instance.deinit();
    try std.testing.expectEqual(Kind.interpreter, std.meta.activeTag(instance.kind));
}
