//! Measure hooks: how text and images report their intrinsic size.
//!
//! The engine never shapes text itself — no font tables, no HarfBuzz, no
//! glyph cache in this module. Instead, leaf nodes (text runs, images,
//! spacers with intrinsic ratios) provide a [`MeasureFunc`] plus an opaque
//! context pointer, mirroring Taffy's `new_leaf_with_context` and
//! `compute/leaf.rs`. The host (ZUI text system: Fontconfig discovery +
//! FreeType raster + HarfBuzz shaping, backed by `text/bindings.zig`)
//! implements the callback.
//!
//! ## Why function pointers, not closures
//!
//! Zig has no closures, and the project forbids them in public API
//! (`TODO.md` hard constraints). The `ctx: ?*anyopaque` pattern matches
//! `elements/element.zig` (`Listener.target`) and the app layer
//! (`listenerWith`): small captured state travels as an explicit pointer,
//! keeping the frame path free of allocation and dynamic dispatch tables.
//!
//! ## Contract for hook authors
//!
//! - Inputs: `known` axes are definite sizes imposed by the parent (return
//!   them clamped, not re-measured); `available` caps the axes you must
//!   measure under (definite) or names an intrinsic probe (min/max-content).
//! - Output: **content-box** size in logical pixels. The engine adds the
//!   node's own padding/border afterwards — do not include them, or every
//!   bordered text node will double-count its insets.
//! - Purity: same `(known, available)` + same generation of `ctx` data must
//!   return the same size. Generation changes (new string, new font size)
//!   must dirty the node (`tree.markDirty`), or the [`cache`] will serve
//!   the stale size with no further warning.
//! - Speed: this hook is the hottest call in text-heavy UI (every intrinsic
//!   probe invokes it). Cache shaped runs paragraph-wise on the host side
//!   (see the improvements digest: paragraph-level intrinsics LRU ≈ 10x).
//!
//! [`cache`]: cache.zig

const core = @import("../core/root.zig");
const geo = @import("geometry.zig");

/// Leaf measurement callback.
///
/// - `ctx` — host state (e.g. pointer to a shaped-run cache entry).
/// - `known` — definite sizes per axis (`null` = unconstrained).
/// - `available` — measurement caps / intrinsic probes per axis.
/// - Returns content-box size in logical pixels.
pub const MeasureFunc = *const fn (
    ctx: ?*anyopaque,
    known: geo.KnownDimensions,
    available: geo.SizeAvailable,
) core.Size;

/// Optional fast path for the min-content probe (Yoga-style
/// `measureMinContent`). When `null`, the engine derives min-content by
/// calling [`MeasureFunc`] under `AvailableSpace.min_content`, which is
/// correct but costs an extra shape pass for text.
pub const MinContentFunc = ?*const fn (ctx: ?*anyopaque) f32;

/// A hook binding for one leaf node. Stored in a parallel pool in
/// `compute.zig` (`measures: [max_nodes]LeafMeasure`), defaulting to
/// "no hook" (fixed-size fallback). Copyable, zero-sized when empty.
pub const LeafMeasure = struct {
    func: ?MeasureFunc = null,
    ctx: ?*anyopaque = null,
    min_func: MinContentFunc = null,

    /// True when a real callback is installed.
    pub fn hasHook(self: LeafMeasure) bool {
        return self.func != null;
    }

    /// Run the hook, or fall back to `fallback` (normally the style's
    /// definite size, else zero). Definite `known` axes win over the hook:
    /// a well-behaved hook returns them anyway, but the fallback path must
    /// not consult content when the parent already decided the size.
    pub fn measure(
        self: LeafMeasure,
        known: geo.KnownDimensions,
        available: geo.SizeAvailable,
        fallback: core.Size,
    ) core.Size {
        if (self.func) |f| {
            const s = f(self.ctx, known, available);
            return .{
                .w = known.w orelse s.w,
                .h = known.h orelse s.h,
            };
        }
        return .{
            .w = known.w orelse fallback.w,
            .h = known.h orelse fallback.h,
        };
    }

    /// Min-content width probe: dedicated hook if present, else the general
    /// hook under a min-content probe, else the known/fallback width.
    pub fn minContentWidth(
        self: LeafMeasure,
        known_w: ?f32,
        fallback: f32,
    ) f32 {
        if (known_w) |w| return w;
        if (self.min_func) |f| return f(self.ctx);
        if (self.func) |f| {
            const s = f(self.ctx, .{}, .{ .w = .min_content, .h = .max_content });
            return s.w;
        }
        return fallback;
    }
};

/// Fixed-size hook for tests and spacers: always reports `size`,
/// honouring definite `known` axes like a real hook must.
pub fn fixedMeasure(size: core.Size) LeafMeasure {
    const S = struct {
        var stored: core.Size = .{};
        fn hook(ctx: ?*anyopaque, known: geo.KnownDimensions, avail: geo.SizeAvailable) core.Size {
            _ = ctx;
            _ = known;
            _ = avail;
            return stored;
        }
    };
    S.stored = size;
    return .{ .func = S.hook };
}

test "leaf fallback without hook prefers known dims" {
    const testing = @import("std").testing;
    const m = LeafMeasure{};
    try testing.expect(!m.hasHook());
    const s = m.measure(.{ .w = 10 }, .{}, .{ .w = 1, .h = 2 });
    try testing.expectEqual(@as(f32, 10), s.w);
    try testing.expectEqual(@as(f32, 2), s.h);
}

test "leaf fallback with neither hook nor known returns fallback" {
    const testing = @import("std").testing;
    const m = LeafMeasure{};
    const s = m.measure(.{}, .{}, .{ .w = 3, .h = 4 });
    try testing.expectEqual(@as(f32, 3), s.w);
    try testing.expectEqual(@as(f32, 4), s.h);
}

test "hook result is clamped to known axes" {
    const testing = @import("std").testing;
    const S = struct {
        fn hook(ctx: ?*anyopaque, known: geo.KnownDimensions, avail: geo.SizeAvailable) core.Size {
            _ = ctx;
            _ = known;
            _ = avail;
            return .{ .w = 999, .h = 999 };
        }
    };
    const m = LeafMeasure{ .func = S.hook };
    try testing.expect(m.hasHook());
    const s = m.measure(.{ .w = 50 }, .{}, .{});
    // Known width wins; height flows from the hook.
    try testing.expectEqual(@as(f32, 50), s.w);
    try testing.expectEqual(@as(f32, 999), s.h);
}

test "min content width uses dedicated hook first" {
    const testing = @import("std").testing;
    const S = struct {
        fn minHook(ctx: ?*anyopaque) f32 {
            _ = ctx;
            return 37;
        }
        fn bigHook(ctx: ?*anyopaque, known: geo.KnownDimensions, avail: geo.SizeAvailable) core.Size {
            _ = ctx;
            _ = known;
            _ = avail;
            return .{ .w = 500, .h = 10 };
        }
    };
    const m = LeafMeasure{ .func = S.bigHook, .min_func = S.minHook };
    try testing.expectEqual(@as(f32, 37), m.minContentWidth(null, 0));
    // Known width short-circuits both hooks.
    try testing.expectEqual(@as(f32, 12), m.minContentWidth(12, 0));
}

test "fixed measure helper reports constant size" {
    const testing = @import("std").testing;
    const m = fixedMeasure(.{ .w = 80, .h = 24 });
    const s = m.measure(.{}, .{}, .{});
    try testing.expectEqual(@as(f32, 80), s.w);
    try testing.expectEqual(@as(f32, 24), s.h);
}
