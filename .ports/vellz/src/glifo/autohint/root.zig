//! `vellz.glifo.autohint` — the automatic hinter.

pub const fixed = @import("fixed.zig");
pub const blue_zones = @import("blue_zones.zig");
pub const metrics = @import("metrics.zig");
pub const styles = @import("styles.zig");
pub const shaper = @import("shaper.zig");
pub const outline = @import("outline.zig");
pub const topo = @import("topo.zig");
pub const blues = @import("blues.zig");
pub const widths = @import("widths.zig");
pub const style_metrics = @import("style_metrics.zig");
pub const hint = @import("hint.zig");
pub const hint_edges = @import("hint_edges.zig");
pub const align_points = @import("align_points.zig");
pub const instance = @import("instance.zig");

pub const Instance = instance.Instance;
pub const ScriptGroup = styles.ScriptGroup;
pub const GlyphStyle = styles.GlyphStyle;
pub const HintedMetrics = hint.HintedMetrics;
pub const EdgeMetrics = hint.EdgeMetrics;
