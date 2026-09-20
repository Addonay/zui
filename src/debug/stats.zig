//! Read-only UI-thread diagnostics. Counts retain their source's scope; no
//! resource lookup, engine initialization, counter reset, or scheduling occurs.
const std = @import("std");
const builtin = @import("builtin");
const Scene = @import("../gpu/scene.zig").Scene;

pub const SceneStats = struct {
    commands: usize = 0,
    quads: usize = 0,
    glyphs: usize = 0,
    blits: usize = 0,
    dropped: u64 = 0,
    dropped_frame: u64 = 0,

    pub fn capture(scene: *const Scene) SceneStats {
        return .{ .commands = scene.command_len, .quads = scene.len, .glyphs = scene.glyph_len, .blits = scene.blit_len, .dropped = scene.dropped, .dropped_frame = scene.dropped_frame };
    }
};

pub const Durations = struct {
    /// Null for raw scene renderers which do not use the element lifecycle.
    layout_ns: ?u64 = null,
    paint_ns: ?u64 = null,
};

pub const WindowStats = struct {
    frames: u64 = 0,
    rejected_frames: u64 = 0,
    scene: SceneStats = .{},
    durations: Durations = .{},
    dropped_regions: u64 = 0,
    duplicate_keys: u64 = 0,
    overlay_skipped: u64 = 0,
    inspector_failures: u64 = 0,
};

/// Lifetime totals, including windows already destroyed. Timing excludes
/// inspection, debug overlays, rasterization and presentation.
pub const Totals = struct {
    frames: u64 = 0,
    rejected_frames: u64 = 0,
    scene_dropped: u64 = 0,
    dropped_regions: u64 = 0,
    layout_ns: u64 = 0,
    paint_ns: u64 = 0,
    overlay_skipped: u64 = 0,
    inspector_failures: u64 = 0,

    pub fn add(self: *Totals, other: Totals) void {
        self.frames += other.frames;
        self.rejected_frames += other.rejected_frames;
        self.scene_dropped += other.scene_dropped;
        self.dropped_regions += other.dropped_regions;
        self.layout_ns += other.layout_ns;
        self.paint_ns += other.paint_ns;
        self.overlay_skipped += other.overlay_skipped;
        self.inspector_failures += other.inspector_failures;
    }
};

pub const Snapshot = struct {
    totals: Totals = .{},
    /// App.step rejection count (direct Window.render calls are not included).
    rejected_frames: u64 = 0,
    image_pool_used: usize = 0,
    image_pool_capacity: usize = 0,
    image_entries: usize = 0,
    image_evictions: u64 = 0,
    image_stale_drops: u64 = 0,
    event_drops: u64 = 0,
    event_coalesced: u64 = 0,
    event_critical_overflow: u64 = 0,
    event_critical_evictions: u64 = 0,
    atlas_hits: u64 = 0,
    atlas_misses: u64 = 0,
    atlas_evictions: u64 = 0,
    atlas_drops: u64 = 0,
    atlas_bytes: usize = 0,
    text_layout_cache_hits: u64 = 0,
    text_layout_cache_misses: u64 = 0,
    text_layout_cache_evictions: u64 = 0,
    engine_failures: u64 = 0,
};

pub fn capture(app: anytype) Snapshot {
    var result = Snapshot{
        .totals = app.retired_diagnostics,
        .rejected_frames = app.rejected_frames,
        .event_drops = app.event_queue.dropped,
        .event_coalesced = app.event_queue.coalesced,
        .event_critical_overflow = app.event_queue.critical_overflow,
        .event_critical_evictions = app.event_queue.critical_evictions,
        .engine_failures = app.cozmic_engine_failures,
    };
    for (app.windows) |maybe_window| {
        if (maybe_window) |window| result.totals.add(window.diagnosticTotals());
    }
    if (app.image_cache) |cache| {
        result.image_pool_used = cache.used;
        result.image_pool_capacity = cache.pool.len;
        result.image_evictions = cache.slot_evictions;
        result.image_stale_drops = cache.stale_drops;
        for (cache.entries) |entry| {
            if (entry.live) result.image_entries += 1;
        }
    }
    if (app.cozmic_engine) |engine| {
        result.atlas_hits = engine.glyphs.hits;
        result.atlas_misses = engine.glyphs.misses;
        result.atlas_evictions = engine.glyphs.evictions;
        result.atlas_drops = engine.glyphs.overflow_drops;
        result.atlas_bytes = engine.glyphs.storageUsed();
        // Cross-frame text layout cache (gap §3.4).
        result.text_layout_cache_hits = engine.layout_cache_hits;
        result.text_layout_cache_misses = engine.layout_cache_misses;
        result.text_layout_cache_evictions = engine.layout_cache_evictions;
    }
    return result;
}

pub fn logExit(app: anytype) void {
    if (!@import("../core/log.zig").enabled()) return;
    const bytes = std.json.Stringify.valueAlloc(app.allocator, capture(app), .{}) catch return;
    defer app.allocator.free(bytes);
    std.debug.print("[zui:stats] exit {s}\n", .{bytes});
}

/// Monotonic nanoseconds; zero on clock failure. Not a wall-clock timestamp.
pub fn nowNs() u64 {
    if (builtin.target.os.tag == .windows) {
        var counter: std.os.windows.LARGE_INTEGER = undefined;
        var frequency: std.os.windows.LARGE_INTEGER = undefined;
        if (std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() and
            std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() and frequency > 0 and counter >= 0)
            return @intCast(@divTrunc(@as(i128, counter) * 1_000_000_000, frequency));
    } else if (builtin.link_libc) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) == 0)
            return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

pub fn elapsed(start: u64) u64 {
    return nowNs() -| start;
}
