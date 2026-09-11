//! Port of vello_cpu src/coarse/mod.rs (Apache-2.0 OR MIT).
//!
//! Coarse rasterization: bucketing render commands per strip row and tracking
//! coarse depth. `bucketCommands` (solid paints, regular layers, depth
//! culling) is implemented in `bucketer.zig`; filter layers and indexed paints
//! fail with `error.Unsupported` until M2.

pub const bucketer = @import("bucketer.zig");
pub const cmd = @import("cmd.zig");
pub const depth = @import("depth.zig");

pub const RowState = bucketer.RowState;
pub const CommandBucketer = bucketer.CommandBucketer;
pub const RenderCmd = cmd.RenderCmd;
pub const PaintFill = cmd.PaintFill;
pub const DepthFill = cmd.DepthFill;
pub const LayerFill = cmd.LayerFill;
pub const PaintFillAttrs = cmd.PaintFillAttrs;
pub const LayerFillAttrs = cmd.LayerFillAttrs;
pub const Span = cmd.Span;

pub const BucketRange = depth.BucketRange;
pub const DepthBuffer = depth.DepthBuffer;
pub const DepthState = depth.DepthState;
pub const DEPTH_BUCKET_WIDTH = depth.DEPTH_BUCKET_WIDTH;

test {
    @import("std").testing.refAllDecls(@This());
}
