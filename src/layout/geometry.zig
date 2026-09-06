//! Layout geometry: the constraint vocabulary every kernel speaks.
//!
//! This module ports two Taffy sources:
//! - `geometry.rs` — `Size<T>`, `Point<T>`, `Rect<T>` generic containers.
//! - `style/available_space.rs` — `AvailableSpace::{Definite, MinContent,
//!   MaxContent}`.
//!
//! ## Why a separate vocabulary?
//!
//! Storage geometry (`core/geometry.zig`: `Point`, `Size`, `Rect`) answers
//! "where is it". Constraint geometry answers "how much room may it take".
//! Mixing the two is the classic source of layout bugs (a definite `100`
//! and a max-content probe both look like `f32` but mean opposite things).
//! [`AvailableSpace`] makes the meaning explicit at the type level, so each
//! kernel documents which sizing pass it is running:
//!
//! - `Definite(px)` — parent promises exactly this much (minus insets).
//! - `MinContent` — "how narrow can you be without overflowing?" Used for
//!   `min-content` widths, auto-minimums (§4.5), and shrink-to-fit.
//! - `MaxContent` — "how wide do you *want* to be?" Used for `max-content`
//!   widths and the flex-basis content fallback.
//!
//! ## Data flow (Flutter-style constraints-down / sizes-up)
//!
//! ```text
//!  parent ── LayoutInput{known, available} ──▶ child
//!  parent ◀── core.Size (border-box outer) ─── child
//! ```
//!
//! `known` dimensions are definite sizes imposed by the parent (e.g. a
//! stretched cross size). `available` is the most the child may take.
//! The child returns its border-box outer size; the parent positions it.
//! A `null` known axis means "unconstrained — measure your content".
//!
//! ## Caching
//!
//! [`LayoutInput`] plus [`SizingMode`] is exactly the [`cache.CacheKey`]:
//! same input ⇒ same output, which is what makes the per-node multi-slot
//! cache sound. Keep these structs in sync — if you add a field here that
//! affects output, add it to the cache key too.

const core = @import("../core/root.zig");

/// How much space is available on one axis.
///
/// Mirrors `taffy::style::AvailableSpace`. The two intrinsic variants are
/// *probes*, not sizes: a kernel receiving `MinContent` must return the
/// smallest size that does not overflow its content (for text: the longest
/// word; for containers: the largest min-content contribution of children).
pub const AvailableSpace = union(enum) {
    /// Exactly this many logical pixels are available.
    definite: f32,
    /// Size under a min-content constraint (shrink-to-fit floor).
    min_content,
    /// Size under a max-content constraint (preferred / natural size).
    max_content,

    /// Definite space of `v` logical pixels.
    pub fn px(v: f32) AvailableSpace {
        return .{ .definite = v };
    }

    /// True only for `.definite`. Percentage resolution, flex-line breaking,
    /// and grid `fr` distribution all branch on this.
    pub fn isDefinite(self: AvailableSpace) bool {
        return self == .definite;
    }

    /// Definite value, or `fallback` for intrinsic probes. Handy for code
    /// paths (e.g. gap resolution) that need *some* number but must not
    /// crash on indefinite space — percentages resolve against `0` there
    /// and behave as `auto`, per Taffy flexbox step 3b.
    pub fn unwrapOr(self: AvailableSpace, fallback: f32) f32 {
        return switch (self) {
            .definite => |v| v,
            else => fallback,
        };
    }

    /// Definite value, or `null` for intrinsic probes. Prefer this over
    /// [`unwrapOr`] when the caller must distinguish "zero space" from
    /// "unbounded probe" (e.g. `%` track resolution).
    pub fn opt(self: AvailableSpace) ?f32 {
        return switch (self) {
            .definite => |v| v,
            else => null,
        };
    }
};

/// Available space on both axes. This is what flows *down* the tree.
pub const SizeAvailable = struct {
    w: AvailableSpace = .max_content,
    h: AvailableSpace = .max_content,

    /// Both axes definite — the fast path where intrinsic measurement can
    /// be skipped entirely.
    pub fn bothDefinite(self: SizeAvailable) bool {
        return self.w.isDefinite() and self.h.isDefinite();
    }
};

/// Which sizing pass is running. Mirrors `taffy::SizingMode`.
///
/// - `content_box` — normal layout; measure hooks receive content-box
///   constraints and return content size.
/// - `inherent` — intrinsic probe (`min-content` / `max-content`); hooks
///   must ignore extrinsic clamps and report natural size.
pub const SizingMode = enum {
    content_box,
    inherent,
};

/// Definite sizes imposed by the parent (`null` = unconstrained).
///
/// Mirrors Taffy's `Size<Option<f32>>` "known dimensions". A stretched flex
/// child, for example, arrives with `known` set on the cross axis and must
/// return exactly that size (clamped only by its own min/max).
pub const KnownDimensions = struct {
    w: ?f32 = null,
    h: ?f32 = null,
};

/// Computed layout for one node: border-box origin + size, logical pixels.
///
/// Mirrors the `location` + `size` subset of `taffy::Layout`. Taffy also
/// carries `content_size`, `scrollbar_size`, `border`, `padding`, and
/// `margin` per node; we keep those in [`style.Style`] (inputs) rather than
/// duplicating them in the output, since our painter reads style directly.
/// If a future virtual-scrolling widget needs `content_size`, add it here
/// *and* to the cache key — it is output, not input.
///
/// Coordinates are relative to the containing block's **padding box**
/// origin (i.e. inside the parent's border, at the parent's padding edge).
/// The root node is relative to the viewport passed to `computeRoot`.
pub const Layout = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn rect(self: Layout) core.Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }

    pub fn size(self: Layout) core.Size {
        return .{ .w = self.w, .h = self.h };
    }

    pub fn isEmpty(self: Layout) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// Full constraint input for one node computation.
///
/// Bundles everything a kernel may read so the dispatcher (`compute.zig`)
/// has a single thing to construct, log, and hash into [`cache.CacheKey`].
pub const LayoutInput = struct {
    known: KnownDimensions = .{},
    available: SizeAvailable = .{},
    sizing_mode: SizingMode = .content_box,
};

test "available space unwrap and opt" {
    const testing = @import("std").testing;
    const def: AvailableSpace = .{ .definite = 10 };
    const mc: AvailableSpace = .max_content;
    const minc: AvailableSpace = .min_content;
    try testing.expect(def.isDefinite());
    try testing.expect(!mc.isDefinite());
    try testing.expectEqual(@as(f32, 10), def.unwrapOr(0));
    try testing.expectEqual(@as(f32, 7), mc.unwrapOr(7));
    try testing.expectEqual(@as(?f32, 10), def.opt());
    try testing.expect(minc.opt() == null);
}

test "available space px constructor" {
    const testing = @import("std").testing;
    const a = AvailableSpace.px(42);
    try testing.expect(a.isDefinite());
    try testing.expectEqual(@as(f32, 42), a.unwrapOr(0));
}

test "size available both-definite fast path" {
    const testing = @import("std").testing;
    const both = SizeAvailable{ .w = .{ .definite = 1 }, .h = .{ .definite = 2 } };
    const mixed = SizeAvailable{ .w = .{ .definite = 1 }, .h = .max_content };
    try testing.expect(both.bothDefinite());
    try testing.expect(!mixed.bothDefinite());
    try testing.expect((SizeAvailable{}).bothDefinite() == false);
}

test "layout converts to rect and size" {
    const testing = @import("std").testing;
    const l = Layout{ .x = 1, .y = 2, .w = 10, .h = 20 };
    try testing.expectEqual(@as(f32, 1), l.rect().x);
    try testing.expectEqual(@as(f32, 10), l.rect().w);
    try testing.expect(l.size().h == 20);
    try testing.expect(!l.isEmpty());
    try testing.expect((Layout{}).isEmpty());
}
