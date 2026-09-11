//! Port of the `kurbo` 0.13.1 geometry subset used by Vello.
//!
//! Upstream source: `kurbo` 0.13.1 (crates.io), which `peniko` 0.6.1 re-exports
//! and `vello_common` uses directly. Types and algorithms mirror upstream
//! names, units (f64), and numerical conventions; this is not a reimagining.
//!
//! Ownership: these are plain value types (no allocator). Container types with
//! heap storage (`BezPath`) take an allocator explicitly and expose
//! `init`/`deinit`. Borrowed versus owned behavior is documented per method.
//!
//! Shape machinery: upstream's `Shape` trait becomes comptime duck typing.
//! Shape types provide `toPath(tolerance) BezPath`, `boundingBox() Rect`, and
//! where upstream defines them `area()`/`perimeter()`. Generic consumers take
//! `anytype` and never box shapes.

pub const point = @import("point.zig");
pub const vec2 = @import("vec2.zig");
pub const affine = @import("affine.zig");
pub const rect = @import("rect.zig");
pub const size = @import("size.zig");
pub const insets = @import("insets.zig");
pub const bezpath = @import("bezpath.zig");
pub const line = @import("line.zig");
pub const circle = @import("circle.zig");
pub const common = @import("common.zig");
pub const cubicbez = @import("cubicbez.zig");
pub const quadbez = @import("quadbez.zig");
pub const svg = @import("svg.zig");
pub const stroke = @import("stroke.zig");

pub const Point = point.Point;
pub const Vec2 = vec2.Vec2;
pub const Affine = affine.Affine;
pub const Rect = rect.Rect;
pub const Size = size.Size;
pub const Insets = insets.Insets;
pub const BezPath = bezpath.BezPath;
pub const PathEl = bezpath.PathEl;
pub const PathSeg = bezpath.PathSeg;
pub const Line = line.Line;
pub const Circle = circle.Circle;
pub const CubicBez = cubicbez.CubicBez;
pub const QuadBez = quadbez.QuadBez;
pub const Stroke = stroke.Stroke;
pub const Cap = stroke.Cap;
pub const Join = stroke.Join;
pub const Dashes = stroke.Dashes;
pub const StrokeOpts = stroke.StrokeOpts;
pub const StrokeOptLevel = stroke.StrokeOptLevel;
pub const StrokeCtx = stroke.StrokeCtx;
pub const strokeWith = stroke.strokeWith;
pub const dash = stroke.dash;
pub const dashIter = stroke.dashIter;
pub const DashIterator = stroke.DashIterator;

test {
    // `refAllDecls` does not reliably force analysis of imported files in this
    // Zig version, so submodule tests are pulled in explicitly.
    _ = @import("point.zig");
    _ = @import("vec2.zig");
    _ = @import("affine.zig");
    _ = @import("rect.zig");
    _ = @import("size.zig");
    _ = @import("insets.zig");
    _ = @import("bezpath.zig");
    _ = @import("line.zig");
    _ = @import("circle.zig");
    _ = @import("common.zig");
    _ = @import("cubicbez.zig");
    _ = @import("quadbez.zig");
    _ = @import("svg.zig");
    _ = @import("stroke.zig");
}
