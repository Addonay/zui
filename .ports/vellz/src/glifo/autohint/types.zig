//! Small autohint enums shared by metrics and topology.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/topo/mod.rs` `Dimension` (the
//! rest of `topo` lives in `topo.zig`).

/// The dimension of an axis.
pub const Dimension = enum(u1) {
    /// Metrics and geometry in the horizontal direction.
    horizontal = 0,
    /// Metrics and geometry in the vertical direction.
    vertical = 1,
};
