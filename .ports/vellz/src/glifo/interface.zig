//! Comptime contracts for rendering glyphs and replaying atlas commands.
//!
//! Port of `glifo/src/interface.rs`. Upstream's `DrawSink`/`GlyphRenderer`
//! traits become comptime duck typing: the glyph renderer functions take
//! `renderer: anytype` and call the method set documented here. The
//! `assert*` helpers turn a missing or misnamed method into a compile error at
//! the instantiation site.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Methods that allocate (`fillPath`, `strokePath`, `fillRect`,
//!   `pushClipLayer`, `pushClipPath`, `saveState`) take the allocator and
//!   return an error union; upstream aborts on OOM.
//! - `setPaint` takes a fully resolved `PaintType`; the glyph atlas paint
//!   (`AtlasPaint`) is converted by `renderer.zig` before the call, so
//!   `RenderContext.setPaint` needs no glyph-specific types.
//! - `atlasImageSource`/`atlasPaintTransform` take primitive parameters
//!   instead of `AtlasSlot` so the CPU renderer does not have to import
//!   `vellz.glifo`.

const std = @import("std");

/// Compile-time check for the low-level drawing surface required by
/// `renderer.replayAtlasCommands` and the uncached glyph paths.
pub fn assertDrawSink(comptime T: type) void {
    const required = .{
        "setTransform",
        "setPaintTransform",
        "setPaint",
        "fillPath",
        "fillRect",
        "pushClipLayer",
        "pushClipPath",
        "pushBlendLayer",
        "popLayer",
        "popClipPath",
        "width",
        "height",
    };
    inline for (required) |name| {
        if (!@hasDecl(T, name)) {
            @compileError("type " ++ @typeName(T) ++ " does not implement the DrawSink contract: missing `" ++ name ++ "`");
        }
    }
}

/// Compile-time check for the stateful glyph renderer surface.
pub fn assertGlyphRenderer(comptime T: type) void {
    assertDrawSink(T);
    const required = .{
        "saveState",
        "restoreState",
        "strokePath",
        "setTint",
        "currentPaint",
        "atlasImageSource",
        "atlasPaintTransform",
    };
    inline for (required) |name| {
        if (!@hasDecl(T, name)) {
            @compileError("type " ++ @typeName(T) ++ " does not implement the GlyphRenderer contract: missing `" ++ name ++ "`");
        }
    }
}
