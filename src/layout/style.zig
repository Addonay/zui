//! Style types for the ZUI layout engine.
//!
//! This module is the Zig-native port of Taffy's `style/` directory:
//! `style/mod.rs` (the `Style` struct), `style/dimension.rs`
//! (`Dimension`, `LengthPercentage`), `style/alignment.rs` (`AlignItems`,
//! `AlignContent`, `JustifyContent`), `style/flex.rs` (flexbox fields),
//! `style/grid.rs` (grid tracks and placement), and `style/block.rs`.
//!
//! ## Design decisions (why this is not a line-for-line port)
//!
//! - Taffy packs lengths into a `CompactLength` bitfield to save memory.
//!   We use a plain `union(enum)` of `f32` instead. On 64-bit targets the
//!   size difference is negligible for a 4096-node pool, and plain floats
//!   keep the hot math branchless-friendly and easy to inspect in a
//!   debugger — a deliberate trade of a few KB for debuggability.
//! - Percentages are stored as fractions (`0.5` = 50%), matching Taffy's
//!   internal representation after parsing. Callers that parse CSS `%`
//!   strings must divide by 100 before constructing a style.
//! - `GridTrack.repeat` covers Taffy's `repeat(n, ...)` for integer counts.
//!   `auto-fit` / `auto-fill` (which need container-size-dependent repetition)
//!   are resolved in `grid.zig` during track sizing, not stored here.
//! - Subgrid and masonry (`display: grid-lanes`, WD Dec 2025) are
//!   intentionally absent. Taffy itself has no full subgrid implementation,
//!   and the bookkeeping cost (span counting, line renumbering, no implicit
//!   tracks on the subgridded axis) buys nothing for app/game HUD UI.
//!
//! ## Coordinate system
//!
//! All lengths are logical pixels (`f32`). The painter converts to physical
//! pixels once via content scale; layout itself is scale-independent so the
//! [`cache.CacheKey`] stays valid across DPI changes. Device-pixel snapping
//! happens in [`round`] as a final post-pass (GPUI pattern).

const core = @import("../core/root.zig");

/// Which layout algorithm owns a node. Mirrors `taffy::style::Display`.
/// `none` removes the node and its subtree from layout (zero size, children
/// are not visited). There is no `contents` variant yet: use `none` plus
/// manual child hoisting if you need it.
pub const Display = enum {
    /// Flexbox row/column container (`compute/flexbox.rs`).
    flex,
    /// CSS Grid container (`compute/grid/`).
    grid,
    /// Vertical block stack (`compute/block.rs`).
    block,
    /// Excluded from layout. Children are skipped, size is zero.
    none,
};

/// In-flow vs out-of-flow positioning. Mirrors `taffy::style::Position`.
/// Absolute nodes are scoped out of flex/grid line formation by `compute.zig`
/// (Taffy #917 pattern) and placed afterwards from inset rules.
pub const Position = enum {
    relative,
    absolute,
};

/// Whether a declared width/height includes padding and border.
/// Taffy's default is `border_box`; keeping this explicit prevents the
/// common mistake of adding padding twice when a fixed card size is used.
pub const BoxSizing = enum {
    border_box,
    content_box,
};

/// Inline direction. This is intentionally separate from flex direction:
/// `row` follows the inline direction, while `column` remains block-flow.
/// It also controls grid's column numbering and the physical meaning of
/// `start`/`end` alignment.
pub const Direction = enum {
    ltr,
    rtl,
};

/// Main-axis direction. Mirrors `taffy::style::FlexDirection`.
/// Reverse variants flip visual order AND the start edge used by
/// `justify_content` and auto-margin resolution.
pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,

    /// True for horizontal main axes. Lets kernels write axis-agnostic code
    /// by swapping `(w,h)` / `(x,y)` once instead of duplicating branches.
    pub fn isRow(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }

    /// True when layout proceeds from high to low coordinates (RTL / bottom-up).
    pub fn isReverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }
};

/// Line-wrapping policy. Mirrors `taffy::style::FlexWrap`.
/// `wrap_reverse` flips the cross-axis stacking direction (first line at the
/// bottom/right). The `balance` / `line-count` DP variant from Taffy
/// `3090-3424` is not implemented; greedy wrapping matches Yoga and covers
/// the fixtures that matter for HUD layout.
pub const FlexWrap = enum {
    no_wrap,
    wrap,
    wrap_reverse,
};

/// Cross-axis default alignment for items. Mirrors `taffy::style::AlignItems`.
pub const AlignItems = enum {
    start,
    end,
    flex_start,
    flex_end,
    center,
    baseline,
    stretch,
};

/// Cross-axis distribution of flex *lines*. Mirrors `AlignContent`.
/// Only matters when wrapping produced more than one line.
pub const AlignContent = enum {
    start,
    end,
    flex_start,
    flex_end,
    center,
    stretch,
    space_between,
    space_around,
    space_evenly,
};

/// Per-item cross-axis override. `auto` inherits the container's
/// `align_items`. Mirrors `taffy::style::AlignSelf`.
pub const AlignSelf = enum {
    auto,
    start,
    end,
    flex_start,
    flex_end,
    center,
    baseline,
    stretch,
};

/// Main-axis distribution of items within a line. Mirrors `JustifyContent`.
/// `space_*` variants need 2+ items and positive free space; otherwise they
/// fall back to `start`/`center` per `common/alignment.rs` fallback rules.
pub const JustifyContent = enum {
    start,
    end,
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
};

/// An absolute length or a fraction of the containing block.
///
/// Mirrors `taffy::style::LengthPercentage`. Percentages resolve against the
/// *content-box* size of the containing block on the same axis, except
/// margins which resolve against the containing block *width* on both axes
/// (CSS rule — vertical margin `%` still uses width).
pub const LengthPercentage = union(enum) {
    length: f32,
    percent: f32,

    /// Absolute logical pixels.
    pub fn px(v: f32) LengthPercentage {
        return .{ .length = v };
    }

    /// Fraction of containing block (`0.5` = 50%).
    pub fn pct(v: f32) LengthPercentage {
        return .{ .percent = v };
    }

    pub fn zero() LengthPercentage {
        return .{ .length = 0 };
    }

    /// Resolve to pixels. Percent values outside `0..1` are allowed and
    /// extrapolate (e.g. `1.5` = 150%), matching Taffy behavior.
    pub fn resolve(self: LengthPercentage, parent: f32) f32 {
        return switch (self) {
            .length => |v| v,
            .percent => |p| parent * p,
        };
    }
};

/// A size that may be automatic or intrinsic.
///
/// Mirrors `taffy::style::Dimension`. `min_content` / `max_content` request
/// intrinsic sizing passes: the engine measures the subtree under
/// `AvailableSpace.min_content` / `.max_content` instead of using definite
/// space. Percentages that cannot resolve (indefinite containing block)
/// behave as `auto`, per Taffy flexbox step 3b.
pub const Dimension = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,

    /// Absolute logical pixels.
    pub fn px(v: f32) Dimension {
        return .{ .length = v };
    }

    /// Fraction of containing block (`1.0` = 100%).
    pub fn pct(v: f32) Dimension {
        return .{ .percent = v };
    }

    /// True for `length` / `percent` — sizes that can resolve without
    /// measuring content. Definite sizes short-circuit measure callbacks.
    pub fn isDefinite(self: Dimension) bool {
        return switch (self) {
            .length, .percent => true,
            else => false,
        };
    }

    pub fn isAuto(self: Dimension) bool {
        return self == .auto;
    }

    /// Resolve against a definite containing-block size.
    /// Returns `null` for `auto` and intrinsic keywords, or when `parent`
    /// itself is indefinite (`null`). Callers treat `null` as "measure me".
    pub fn resolve(self: Dimension, parent: ?f32) ?f32 {
        return switch (self) {
            .auto, .min_content, .max_content => null,
            .length => |v| v,
            .percent => |p| if (parent) |pp| pp * p else null,
        };
    }
};

/// Primary-axis flow for auto-placed grid items. Mirrors `GridAutoFlow`.
/// Dense variants backfill holes left by spanned items (may reorder visuals);
/// sparse (default) keeps source order with a persistent cursor.
pub const GridAutoFlow = enum {
    row,
    column,
    row_dense,
    column_dense,

    pub fn isDense(self: GridAutoFlow) bool {
        return self == .row_dense or self == .column_dense;
    }

    pub fn isColumn(self: GridAutoFlow) bool {
        return self == .column or self == .column_dense;
    }
};

/// One grid track template: `minmax(min, max)`, optionally repeated.
///
/// Covers the GPUI subset (`repeat(n, minmax(0|min|max, 1fr|max))`) and all
/// fixed-size cases. Fractional tracks use the explicit `fr` field so `1fr`
/// and `100%` remain distinct. `auto-fit` / `auto-fill` repetition counts
/// are computed at layout time, so only integer `repeat` is stored here.
pub const GridTrack = struct {
    min: Dimension = .auto,
    max: Dimension = .auto,
    /// Fractional share of leftover free space (`1` = `1fr`).
    fr: f32 = 0,
    repeat: u16 = 1,

    pub fn flex(f: f32) GridTrack {
        return .{ .fr = f };
    }

    pub fn fixed(v: f32) GridTrack {
        return .{ .min = .{ .length = v }, .max = .{ .length = v } };
    }

    pub fn isAutoSized(self: GridTrack) bool {
        return self.fr == 0 and !self.min.isDefinite() and !self.max.isDefinite();
    }
};

/// Four-sided box edge values. Unlike `core.Rect` (which is a geometric
/// rectangle with x/y/w/h), these are semantic CSS edges and cannot be
/// accidentally read as a position. Order follows Taffy's `Rect<T>`:
/// top, right, bottom, left.
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

/// Full style for one layout node.
///
/// Field order groups by subsystem (box, spacing, flex, grid, absolute) so
/// debugger views read naturally. Defaults reproduce a column flex container
/// with `align_items: stretch` — the same default Taffy uses, so an empty
/// `Style{}` behaves like a block-level `<div>`.
pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    box_sizing: BoxSizing = .border_box,
    direction: Direction = .ltr,

    /// Legacy fixed size in logical px (kept for migration from
    /// `elements/layout.zig`). Prefer `width`/`height` below: a nonzero
    /// legacy size acts as a definite dimension when the new field is `auto`.
    size: core.Size = .{},
    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: Dimension = .auto,
    min_height: Dimension = .auto,
    max_width: Dimension = .auto,
    max_height: Dimension = .auto,

    /// Absolute padding/border/margin in logical px. Percentage insets live
    /// in the `*_pct` companions during migration; fully-percentage boxes
    /// resolve in `compute.zig` via `LengthPercentage`.
    padding: Edges = .{},
    border: Edges = .{},
    margin: Edges = .{},
    /// CSS auto margins: absorb leftover free space on their axis (centering
    /// idiom). Main-axis autos beat `justify_content`; cross-axis autos beat
    /// `align_self`. Each flag corresponds to its `margin` edge.
    margin_left_auto: bool = false,
    margin_right_auto: bool = false,
    margin_top_auto: bool = false,
    margin_bottom_auto: bool = false,

    /// Main-axis and cross-axis gaps. Taffy stores one `gap: Size`; we keep
    /// row/col separate because grid needs independent axes and flex uses
    /// `gap_row` on the main axis after axis resolution.
    gap_row: LengthPercentage = .{ .length = 0 },
    gap_col: LengthPercentage = .{ .length = 0 },

    // -- Flexbox (`style/flex.rs`) -------------------------------------------
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .no_wrap,
    /// Free-space share when growing (`0` = inflexible).
    flex_grow: f32 = 0,
    /// Shrink weight scaled by base size (`1` = CSS default, `0` = refuse).
    flex_shrink: f32 = 1,
    /// Initial main size before growing/shrinking. `auto` falls back to the
    /// main-axis `width`/`height`, then to content measurement.
    flex_basis: Dimension = .auto,
    align_items: AlignItems = .stretch,
    align_content: AlignContent = .stretch,
    align_self: AlignSelf = .auto,
    justify_content: JustifyContent = .start,
    /// `width / height`. Applied after clamping; `null` disables transfer.
    aspect_ratio: ?f32 = null,

    // -- Grid (`style/grid.rs` subset) ----------------------------------------
    grid_columns: []const GridTrack = &.{},
    grid_rows: []const GridTrack = &.{},
    grid_auto_flow: GridAutoFlow = .row,
    grid_row_start: ?i16 = null,
    grid_row_span: u16 = 1,
    grid_col_start: ?i16 = null,
    grid_col_span: u16 = 1,

    // -- Absolute inset ---------------------------------------------------------
    inset_left: ?LengthPercentage = null,
    inset_right: ?LengthPercentage = null,
    inset_top: ?LengthPercentage = null,
    inset_bottom: ?LengthPercentage = null,

    /// Layout-relevant overflow only (scrollable overflow size). Painting and
    /// clipping are owned by the painter, not the layout engine.
    overflow_x_hidden: bool = false,
    overflow_y_hidden: bool = false,

    /// Main-axis gap in px (percentage gaps resolve in `compute.zig`).
    pub fn gap(self: Style) f32 {
        return switch (self.gap_row) {
            .length => |v| v,
            else => 0,
        };
    }

    /// Effective cross-axis alignment for a child: its `align_self` unless
    /// `auto`, in which case the container's `align_items`.
    pub fn effectiveAlign(self: Style, child_self: AlignSelf) AlignItems {
        return switch (child_self) {
            .auto => self.align_items,
            .start => .start,
            .end => .end,
            .flex_start => .flex_start,
            .flex_end => .flex_end,
            .center => .center,
            .baseline => .baseline,
            .stretch => .stretch,
        };
    }

    /// True when the main-axis size is content-driven (used by block fill
    /// and grid stretch to decide whether a child may be widened).
    /// `horizontal` selects the axis: row main = width.
    pub fn isAutoOnAxis(self: Style, horizontal: bool) bool {
        if (horizontal) {
            if (!self.width.isAuto()) return false;
            if (self.size.w != 0) return false;
            return true;
        } else {
            if (!self.height.isAuto()) return false;
            if (self.size.h != 0) return false;
            return true;
        }
    }
};

test "dimension definite vs auto" {
    const testing = @import("std").testing;
    const px: Dimension = .{ .length = 10 };
    const auto: Dimension = .auto;
    const mc: Dimension = .min_content;
    try testing.expect(px.isDefinite());
    try testing.expect(auto.isAuto());
    try testing.expect(!mc.isDefinite());
}

test "dimension resolve needs definite parent for percent" {
    const testing = @import("std").testing;
    const p: Dimension = .{ .percent = 0.5 };
    try testing.expectEqual(@as(?f32, 50), p.resolve(100));
    try testing.expect(p.resolve(null) == null);
    const auto: Dimension = .auto;
    try testing.expect(auto.resolve(100) == null);
}

test "length percentage resolves" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 5), LengthPercentage.px(5).resolve(100));
    try testing.expectEqual(@as(f32, 50), LengthPercentage.pct(0.5).resolve(100));
    // Out-of-range percents extrapolate (Taffy behavior).
    try testing.expectEqual(@as(f32, 150), LengthPercentage.pct(1.5).resolve(100));
}

test "flex direction axis helpers" {
    const testing = @import("std").testing;
    try testing.expect(FlexDirection.row.isRow());
    try testing.expect(!FlexDirection.column.isRow());
    try testing.expect(FlexDirection.row_reverse.isReverse());
    try testing.expect(!FlexDirection.column.isReverse());
}

test "effective align inherits container on auto" {
    const testing = @import("std").testing;
    const s = Style{ .align_items = .center };
    try testing.expect(s.effectiveAlign(.auto) == .center);
    try testing.expect(s.effectiveAlign(.stretch) == .stretch);
}

test "grid auto flow helpers" {
    const testing = @import("std").testing;
    try testing.expect(GridAutoFlow.row_dense.isDense());
    try testing.expect(!GridAutoFlow.row.isDense());
    try testing.expect(GridAutoFlow.column.isColumn());
}
