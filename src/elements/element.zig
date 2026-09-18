const std = @import("std");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const fonts = @import("../fonts/text_engine.zig");
const images = @import("../images/root.zig");
const zlog = @import("../core/log.zig");

pub const max_nodes = core.limits.MAX_LAYOUT_ELEMENTS;
pub const max_regions = 512;
pub const text_storage_len = 64 * 1024;
/// Owner-registration slots per frame (see `Frame.owner_targets`).
pub const max_owner_entries = 256;

pub const FontWeight = enum { normal, medium, semibold, bold };
pub const Direction = enum { row, column };
pub const Align = enum { start, center };
pub const Justify = enum { start, center, between };

pub const ListenerPayload = extern union {
    bytes: [16]u8,
    alignment: u128,
};

pub const Listener = struct {
    target: *anyopaque,
    payload: ListenerPayload = .{ .bytes = @splat(0) },
    call_fn: *const fn (*anyopaque, *const ListenerPayload, *anyopaque) void,

    pub fn call(self: Listener, window: *anyopaque) void {
        self.call_fn(self.target, &self.payload, window);
    }
};

pub const FocusHandle = struct {
    id: u32 = 0,
    target: ?*anyopaque = null,
    event_fn: ?*const fn (*anyopaque, platform.Event, *anyopaque) bool = null,
    /// Same subscription guard as the region owner (see `HitRegion`): the
    /// `id` doubles as the owner entity id. Dispatch after the owning
    /// entity was destroyed returns false without touching `target`.
    /// Hand-built handles leave these null and dispatch straight through.
    owner_store: ?*anyopaque = null,
    owner_generation: u32 = 0,

    pub fn eql(self: FocusHandle, other: FocusHandle) bool {
        return self.id == other.id;
    }

    pub fn dispatch(self: FocusHandle, event: platform.Event, window: *anyopaque) bool {
        if (self.owner_store) |store| {
            if (entity_is_alive_fn) |alive| {
                if (!alive(store, self.id, self.owner_generation)) return false;
            }
        }
        const callback = self.event_fn orelse return false;
        return callback(self.target orelse return false, event, window);
    }

    /// False when the owner entity is gone; unowned handles stay live.
    pub fn isLive(self: FocusHandle) bool {
        if (self.owner_store) |store| {
            if (entity_is_alive_fn) |alive| {
                return alive(store, self.id, self.owner_generation);
            }
        }
        return true;
    }
};

pub const HitRegion = struct {
    bounds: core.Rect,
    listener: ?Listener = null,
    mouse_down_listener: ?Listener = null,
    mouse_up_listener: ?Listener = null,
    mouse_move_listener: ?Listener = null,
    double_click_listener: ?Listener = null,
    scroll_listener: ?Listener = null,
    focus: ?FocusHandle = null,
    /// Hover cursor for this region, if any. Window picks the topmost
    /// region under the pointer; null means "no opinion".
    cursor: ?platform.CursorShape = null,
    /// Owning entity subscription (gap §5A), installed by the painter from
    /// the frame owner table (see `Frame.trackOwner`): the (store, id,
    /// generation) of the entity that minted this region's listeners.
    /// `Window` resolves liveness through the store *before* invoking any
    /// listener on this region, so input dispatched after
    /// `EntityStore.destroyEntity` is a safe skip instead of a
    /// use-after-free. Regions from hand-built listeners carry null and
    /// dispatch straight through, as before. All listeners on one node
    /// should share an owner; mixed-ownership nodes gate on the first
    /// registered owner (conservative: a dead first owner skips the region
    /// even if a later role's owner still lives).
    owner_store: ?*anyopaque = null,
    owner_id: u32 = 0,
    owner_generation: u32 = 0,

    /// False when the owning entity is gone; unowned regions stay live.
    /// Window dispatch consults this before every listener on the region.
    pub fn ownerAlive(self: HitRegion) bool {
        if (self.owner_store) |store| {
            if (entity_is_alive_fn) |alive| {
                return alive(store, self.owner_id, self.owner_generation);
            }
        }
        return true;
    }
};

/// Store-level entity liveness probe behind the `HitRegion`/`FocusHandle`
/// subscription guards. Wired once by `EntityStore.init` (always the same
/// function); kept here — rather than passed per value — so the hot
/// `Listener`/`Node` structs stay lean and `window.zig` can consult it
/// without importing `runtime` (which would be an import cycle). UI-thread
/// only, like everything it guards. Null means ungated: pre-wiring or
/// hand-built handles dispatch straight through, as before.
pub var entity_is_alive_fn: ?*const fn (*anyopaque, u32, u32) bool = null;

/// Entity owner reference resolved through the frame owner table
/// (`Frame.lookupOwner`) and installed on hit regions by the painter.
pub const OwnerRef = struct {
    store: *anyopaque,
    id: u32,
    generation: u32,
};

pub const EdgeValues = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) EdgeValues {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

pub const Style = struct {
    direction: Direction = .column,
    alignment: Align = .start,
    justify: Justify = .start,
    gap: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    square: ?f32 = null,
    full_width: bool = false,
    full_height: bool = false,
    max_width_full: bool = false,
    flex_grow: f32 = 0,
    padding: EdgeValues = .{},
    absolute: bool = false,
    inset_value: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    left: ?f32 = null,
    background: ?core.Color = null,
    gradient_to: ?core.Color = null,
    hover_background: ?core.Color = null,
    border_color: ?core.Color = null,
    hover_border: ?core.Color = null,
    /// Row flex containers wrap children onto new lines when they would
    /// exceed the content width (only meaningful with a definite width).
    flex_wrap: bool = false,
    /// Scroll translation applied to children (clipping already happens for
    /// every container; the offset is owned by the caller's state).
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    border_width: f32 = 0,
    border_bottom_only: bool = false,
    dashed_border: bool = false,
    radius: f32 = 0,
    opacity: f32 = 1,
    blur: f32 = 0,
    shadow: bool = false,
    text_color: ?core.Color = null,
    /// Hover cursor override for this node's hit region (see HitRegion).
    cursor: ?platform.CursorShape = null,
};

pub const TextStyle = struct {
    size: f32 = 14,
    line_height: ?f32 = null,
    tracking: f32 = 0,
    font: []const u8 = "",
    weight: FontWeight = .normal,
    color: ?core.Color = null,
    strike: bool = false,
};

pub const NodeKind = enum { container, text, spacer, image };

/// Object-fit behavior for image nodes (GPUI `ObjectFit` parity).
pub const ImageFit = enum { contain, cover, fill };

/// Image content source. Slices are borrowed (same contract as text_value):
/// static bytes, `@embedFile`, or a caller-owned path string.
pub const ImageSource = union(enum) {
    bytes: []const u8,
    path: []const u8,
    handle: images.Handle,
    asset: images.AssetHandle,
};

pub const ImageDesc = struct {
    source: ImageSource = .{ .bytes = &.{} },
    /// True for `svg()`: rasterize as vector at draw size with tint.
    /// False for `img()`: decode raster bytes (SVG bytes still accepted
    /// and rasterized at intrinsic size, GPUI `img()` parity).
    svg: bool = false,
    fit: ImageFit = .contain,
    gray: bool = false,
    /// Replaces `currentColor` in SVGs (GPUI icon tint); multiplies alpha
    /// into raster blits together with style opacity.
    tint: ?core.Color = null,
    /// Intrinsic size from preloaded metadata; unknown sources use a 24px
    /// diagnostic placeholder rather than collapsing silently.
    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
};

pub const Node = struct {
    kind: NodeKind = .container,
    style: Style = .{},
    text_style: TextStyle = .{},
    text_value: []const u8 = "",
    image: ImageDesc = .{},
    first_child: ?u16 = null,
    last_child: ?u16 = null,
    next_sibling: ?u16 = null,
    bounds: core.Rect = .{},
    measured: core.Size = .{},
    /// Optional stable identity for keyed elements (gap §5A). Zero means
    /// unkeyed; nonzero values are `platform.id` hashes that survive across
    /// frames so row state can follow data when reordered (`platform.id`
    /// never mints zero, so zero is an unambiguous sentinel). The frame
    /// diagnoses duplicate keys per frame (see `Frame.duplicate_keys`).
    stable_key: u64 = 0,
    listener: ?Listener = null,
    mouse_down_listener: ?Listener = null,
    mouse_up_listener: ?Listener = null,
    mouse_move_listener: ?Listener = null,
    double_click_listener: ?Listener = null,
    scroll_listener: ?Listener = null,
    focus: ?FocusHandle = null,
    /// True when `layout.measure` actually ran the cozmic layout for this
    /// text node; false when no engine was installed or the shape failed.
    /// Paint gates on this flag (plus `Frame.engine`) so one node can never
    /// be measured with one engine and painted with another.
    cozmic_measured: bool = false,
    /// Measure→paint handoff: the cozmic layout `layout.measure`
    /// shaped for this node, retained so `painter.paintShapedCozmic` emits
    /// from it instead of shaping a second time. Owned by this node's
    /// `Frame` (the entry owns a `cozmic.Buffer` and is heap-allocated on the
    /// frame allocator):
    ///   - installed by `text_engine.measureCached` when the intrinsic
    ///     cozmic measure ran for the exact inputs paint will replay;
    ///   - reused only through `text_engine.retainedLayout`, which rejects a
    ///     layout whose key (engine, text, attrs, wrap width) no longer
    ///     matches the node's current inputs;
    ///   - freed by `clearCozmicLayout` (re-measure / node reuse),
    ///     `Frame.clearCozmicLayouts` (new frame, end of paint) and before it
    ///     is replaced.
    /// Null when no valid handoff exists — paint then reshapes from the same
    /// inputs.
    cozmic_layout: ?*fonts.CachedLayout = null,
    /// Cozmic paint observability for this node (frame-wide aggregates live
    /// on `Frame`): max laid-out glyph extent (`glyph.x + glyph.w`), glyphs
    /// emitted into the scene, laid-out glyphs that emitted no ink (spaces,
    /// `.notdef`, atlas misses) and layout/mismatch failures that skipped
    /// the whole node. Reset at the start of every paint of this node, so
    /// the values describe the most recent paint; all zero when nothing was
    /// painted.
    cozmic_painted_extent: f32 = 0,
    cozmic_painted_glyphs: u64 = 0,
    cozmic_skipped_glyphs: u64 = 0,
    cozmic_paint_failures: u64 = 0,

    /// Free and drop the retained measure→paint layout. Idempotent. Called
    /// before every re-measure of the node and for every live node by
    /// `Frame.clearCozmicLayouts` (frame reset / end of paint).
    ///
    /// Cache-owned entries (cross-frame layout cache, gap §3.4) are only
    /// UNPINNED here — the cache owns their memory and frees them at
    /// eviction or engine teardown. Never frees a pinned entry's buffer.
    pub fn clearCozmicLayout(self: *Node) void {
        if (self.cozmic_layout) |cached| {
            if (cached.cache_owned) {
                cached.pinned -|= 1;
            } else {
                cached.deinit();
            }
        }
        self.cozmic_layout = null;
    }

    /// Install a retained layout, freeing any previous one first, so
    /// re-measuring a node mid-frame cannot leak the earlier handoff.
    pub fn setCozmicLayout(self: *Node, cached: *fonts.CachedLayout) void {
        self.clearCozmicLayout();
        self.cozmic_layout = cached;
    }
};

/// Transient per-frame element tree (~2.5MB inline). Lives in the heap
/// `Window` (`ui_frame`); hold at most one of Frame/Scene per stack in tests
/// too (heap-allocate the rest). See the "hot frame structs stay within stack
/// budget" test in painter.zig.
pub const Frame = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    regions: [max_regions]HitRegion = undefined,
    region_count: usize = 0,
    /// Cumulative addRegion drops (table full). Hit regions gate clicks:
    /// a silent drop makes a live control unclickable, so the count keeps
    /// the failure observable (plan M10). Never reset by reset().
    dropped_regions: u64 = 0,
    text_storage: [text_storage_len]u8 = undefined,
    text_len: usize = 0,
    window: ?*anyopaque = null,
    pointer: core.Point = .{ .x = -10000, .y = -10000 },
    /// Borrowed cozmic text engine. When set, text measure and paint both go
    /// through cozmic layouts; null means text draws nothing (no legacy
    /// fallback). Installed per frame from the owning App/Window; never owned
    /// here, and this struct is only valid while the engine outlives it.
    engine: ?*fonts.Engine = null,
    /// Cozmic paint observability: frame-wide aggregates over every text
    /// node painted by the cozmic path (per-node values live on `Node`).
    /// `cozmic_painted_extent` is the max laid-out glyph extent across those
    /// nodes (one layout's `width`, which is `measured.w` when no explicit
    /// width clamps the box); `cozmic_painted_glyphs` sums glyphs actually
    /// emitted into the scene; `cozmic_skipped_glyphs` sums laid-out glyphs
    /// that emitted no ink; `cozmic_paint_failures` counts nodes whose
    /// layout could not be shaped at paint time or whose node measured on
    /// cozmic while the engine was gone. Reset by `reset()` and at the start
    /// of every `painter.paint` (the values describe one paint, never the sum
    /// of two).
    cozmic_painted_extent: f32 = 0,
    cozmic_painted_glyphs: u64 = 0,
    cozmic_skipped_glyphs: u64 = 0,
    cozmic_paint_failures: u64 = 0,
    /// Borrowed image cache for img()/svg() resolution. Null drops images.
    /// Set per frame from `Window.images`; never owned here.
    images: ?*images.Cache = null,
    image_placeholders: u64 = 0,
    /// Owning App's step counter at render; pins image-cache entries.
    frame_id: u64 = 0,
    /// Allocator for frame text/layout work. Images never allocate here.
    allocator: ?std.mem.Allocator = null,
    /// Frame identity for transient-handle checks (gap §5A). Bumped by
    /// every `reset()`; each `Element` stamps the generation it was built
    /// in, so a handle that escapes its frame (used after `endFrame` or
    /// after the next `reset`) fails predictably via `Element.isAlive`
    /// instead of silently indexing a recycled node slot.
    generation: u64 = 0,
    /// Stable keys seen this frame (parallel to node slots; only keyed
    /// nodes append). A second `keyed()` with an already-seen key counts
    /// `duplicate_keys` and logs — duplicate keys would alias retained
    /// state, focus, and semantics, so they are diagnosed, not ignored.
    seen_keys: [max_nodes]u64 = undefined,
    seen_key_count: usize = 0,
    /// Duplicate stable keys diagnosed this frame. Observable; never reset
    /// by anything except `reset()` (a new frame starts a new key scope).
    duplicate_keys: u64 = 0,
    /// Entity→owner registrations for this frame (gap §5A subscription
    /// cleanup). `runtime` registers every listener/focus target it mints
    /// while a frame is active (`trackOwner`, a no-op without one); the
    /// painter resolves each emitted hit region's owner through this table
    /// instead of dereferencing possibly-stale targets. Entries are
    /// per-frame values: `reset()` clears them, so regions can never
    /// outlive the registrations they were resolved from. 256 slots cover
    /// ordinary frames (distinct listener owners per frame are usually a
    /// handful); overflow counts `owner_overflows` and leaves the region
    /// ungated rather than dropping input.
    owner_targets: [max_owner_entries]*anyopaque = undefined,
    owner_stores: [max_owner_entries]*anyopaque = undefined,
    owner_ids: [max_owner_entries]u32 = undefined,
    owner_generations: [max_owner_entries]u32 = undefined,
    owner_count: usize = 0,
    /// Owner registrations dropped while the table was full. Observable;
    /// cleared by `reset()`.
    owner_overflows: u64 = 0,

    semantic_bindings: [@import("../a11y/root.zig").capacity]@import("../a11y/root.zig").Binding = undefined,
    /// Transient top-layer roots, laid out and painted after the main tree.
    portals: [32]@import("../widgets/overlay.zig").Portal = undefined,
    portal_count: usize = 0,
    /// Passive observers (hover leave, context menus), generation checked.
    observers: [32]FocusHandle = undefined,
    observer_count: usize = 0,
    semantic_count: usize = 0,
    semantic_dropped: usize = 0,
    semantic_tree: @import("../a11y/root.zig").Tree = .{},

    pub fn reset(self: *Frame, window: *anyopaque, pointer: core.Point) void {
        self.portal_count = 0;
        self.observer_count = 0;
        self.semantic_count = 0;
        self.semantic_dropped = 0;
        self.semantic_tree = .{};
        // A new frame owns no retained layouts from the previous one: free
        // them before node slots are overwritten (createNode starts writing
        // at index 0, which would otherwise drop the only pointer to them).
        // Non-text nodes are null, so this is a cheap pass.
        self.clearCozmicLayouts();
        self.node_count = 0;
        self.region_count = 0;
        self.text_len = 0;
        self.window = window;
        self.pointer = pointer;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.seen_key_count = 0;
        self.duplicate_keys = 0;
        self.owner_count = 0;
        self.owner_overflows = 0;
        // New frame installs its own engine (`runtime.mountView` does it
        // right after reset): text without an install draws nothing.
        self.engine = null;
        self.cozmic_painted_extent = 0;
        self.cozmic_painted_glyphs = 0;
        self.cozmic_skipped_glyphs = 0;
        self.cozmic_paint_failures = 0;
    }

    /// Free every retained cozmic layout for nodes built in this frame.
    /// Called by `reset` (new frame) and at the end of `painter.paint` (the
    /// measure→paint handoff is consumed there), so a frame never leaks
    /// layouts even when a caller repaints, tears down, or drives
    /// layout+paint in a loop without calling `reset` in between.
    pub fn clearCozmicLayouts(self: *Frame) void {
        for (self.nodes[0..self.node_count]) |*node| node.clearCozmicLayout();
    }

    /// Deinitialize the frame, freeing any retained cozmic layouts.
    /// Safe to call on a fresh frame (no-op beyond clearing layouts).
    pub fn deinit(self: *Frame) void {
        self.clearCozmicLayouts();
        self.node_count = 0;
        self.region_count = 0;
        self.text_len = 0;
    }

    /// Clone the frame into a new allocation. The clone shares the same
    /// engine and images pointers but has independent node data, allowing
    /// two layout paths to run on identical trees without interfering.
    pub fn clone(self: *const Frame) !Frame {
        var copy = Frame{
            .node_count = self.node_count,
            .region_count = self.region_count,
            .dropped_regions = self.dropped_regions,
            .text_len = self.text_len,
            .window = self.window,
            .pointer = self.pointer,
            .engine = self.engine,
            .images = self.images,
            .frame_id = self.frame_id,
            .allocator = self.allocator,
            .generation = self.generation,
            .seen_key_count = self.seen_key_count,
            .duplicate_keys = self.duplicate_keys,
            .owner_count = self.owner_count,
            .owner_overflows = self.owner_overflows,
            .cozmic_painted_extent = self.cozmic_painted_extent,
            .cozmic_painted_glyphs = self.cozmic_painted_glyphs,
            .cozmic_skipped_glyphs = self.cozmic_skipped_glyphs,
            .cozmic_paint_failures = self.cozmic_paint_failures,
        };
        copy.semantic_count = self.semantic_count;
        copy.semantic_dropped = self.semantic_dropped;
        @memcpy(copy.semantic_bindings[0..self.semantic_count], self.semantic_bindings[0..self.semantic_count]);
        // Like text_value on cloned nodes, semantic strings borrow the source
        // frame. Keep it alive until the comparison clone is consumed.
        @memcpy(copy.nodes[0..self.node_count], self.nodes[0..self.node_count]);
        @memcpy(copy.regions[0..self.region_count], self.regions[0..self.region_count]);
        @memcpy(copy.text_storage[0..self.text_len], self.text_storage[0..self.text_len]);
        @memcpy(copy.seen_keys[0..self.seen_key_count], self.seen_keys[0..self.seen_key_count]);
        @memcpy(copy.owner_targets[0..self.owner_count], self.owner_targets[0..self.owner_count]);
        @memcpy(copy.owner_stores[0..self.owner_count], self.owner_stores[0..self.owner_count]);
        @memcpy(copy.owner_ids[0..self.owner_count], self.owner_ids[0..self.owner_count]);
        @memcpy(copy.owner_generations[0..self.owner_count], self.owner_generations[0..self.owner_count]);
        return copy;
    }

    fn createNode(self: *Frame, kind: NodeKind) u16 {
        if (self.node_count >= self.nodes.len) @panic("ZUI element limit exceeded");
        const index: u16 = @intCast(self.node_count);
        self.node_count += 1;
        self.nodes[index] = .{ .kind = kind };
        return index;
    }

    /// Allocate one node and stamp the handle with this frame's generation
    /// so escaped handles fail predictably (see `Element.isAlive`).
    fn makeElement(self: *Frame, kind: NodeKind) Element {
        return .{ .index = self.createNode(kind), .generation = self.generation };
    }

    /// Record a stable key for duplicate diagnosis. Called by
    /// `Element.keyed`; duplicates count `duplicate_keys` and log with the
    /// frame generation so the offending frame is identifiable.
    fn trackKey(self: *Frame, key: u64) void {
        std.debug.assert(key != 0);
        for (self.seen_keys[0..self.seen_key_count]) |seen| {
            if (seen == key) {
                self.duplicate_keys += 1;
                zlog.log("element", "duplicate stable key {d} in frame {d}", .{ key, self.generation });
                return;
            }
        }
        if (self.seen_key_count < self.seen_keys.len) {
            self.seen_keys[self.seen_key_count] = key;
            self.seen_key_count += 1;
        }
    }

    /// Register an entity-owned listener/focus target minted while this
    /// frame is active. Called by `runtime` at mint time (the entity is
    /// provably live there), so the painter can later resolve region owners
    /// without touching possibly-destroyed targets. Re-registers refresh
    /// the entry; a full table counts `owner_overflows` and leaves the
    /// region ungated rather than dropping input.
    pub fn trackOwner(self: *Frame, target: *anyopaque, store: *anyopaque, id: u32, generation: u32) void {
        for (self.owner_targets[0..self.owner_count], 0..) |t, i| {
            if (t == target) {
                self.owner_stores[i] = store;
                self.owner_ids[i] = id;
                self.owner_generations[i] = generation;
                return;
            }
        }
        if (self.owner_count < self.owner_targets.len) {
            self.owner_targets[self.owner_count] = target;
            self.owner_stores[self.owner_count] = store;
            self.owner_ids[self.owner_count] = id;
            self.owner_generations[self.owner_count] = generation;
            self.owner_count += 1;
        } else {
            self.owner_overflows += 1;
        }
    }

    /// Resolve a region listener target to its (store, id, generation).
    /// Returns null for hand-built targets and table overflow — those
    /// regions dispatch ungated, exactly as before this feature.
    pub fn lookupOwner(self: *const Frame, target: *anyopaque) ?OwnerRef {
        for (self.owner_targets[0..self.owner_count], 0..) |t, i| {
            if (t == target) return .{ .store = self.owner_stores[i], .id = self.owner_ids[i], .generation = self.owner_generations[i] };
        }
        return null;
    }

    pub fn copyText(self: *Frame, value: []const u8) []const u8 {
        if (self.text_len + value.len > self.text_storage.len) @panic("ZUI frame text storage exceeded");
        const out = self.text_storage[self.text_len..][0..value.len];
        @memcpy(out, value);
        self.text_len += value.len;
        return out;
    }

    /// Returns false (and counts the drop) when the table is full instead
    /// of silently losing a clickable control.
    pub fn addRegion(self: *Frame, region: HitRegion) bool {
        if (self.region_count >= self.regions.len) {
            self.dropped_regions += 1;
            return false;
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;
        return true;
    }
};

threadlocal var active_frame: ?*Frame = null;

pub fn beginFrame(frame: *Frame) void {
    std.debug.assert(active_frame == null);
    active_frame = frame;
}

pub fn endFrame() void {
    // The element-build scope ends: release any measure→paint layout still
    // retained (paint normally consumes it, see `painter.paint`). This
    // covers callers that measure and never paint; `Frame.reset` and the end
    // of `painter.paint` cover layout+paint loops driven outside begin/end.
    if (active_frame) |frame| frame.clearCozmicLayouts();
    active_frame = null;
}

pub fn currentFrame() *Frame {
    return active_frame orelse @panic("ZUI elements must be built during render");
}

pub fn currentWindow() *anyopaque {
    return currentFrame().window orelse @panic("ZUI render frame has no window");
}

/// Register an entity-owned listener/focus target with the active frame's
/// owner table (gap §5A). Called by `runtime` at mint time; a no-op when no
/// frame is active (listeners minted outside render dispatch ungated, as
/// before). Never touches the target — registration carries the live
/// (store, id, generation) by value.
pub fn trackEntityOwner(target: *anyopaque, store: *anyopaque, id: u32, generation: u32) void {
    const frame = active_frame orelse return;
    frame.trackOwner(target, store, id, generation);
}

pub const Element = struct {
    index: u16,
    /// Frame generation this handle was built in (stamped by `Frame`).
    /// Zero means "pre-generation" (hand-built); any handle whose
    /// generation differs from the active frame's is an escaped handle and
    /// fails predictably (panic in `node()`, false in `isAlive()`).
    generation: u64 = 0,

    fn node(self: Element) *Node {
        const frame = currentFrame();
        if (self.generation != frame.generation) @panic("ZUI element handle escaped its frame");
        if (self.index >= frame.node_count) @panic("ZUI element handle out of range");
        return &frame.nodes[self.index];
    }

    /// False when no frame is active, when this handle was built in an
    /// older frame, or when its slot is not (or no longer) allocated — the
    /// non-panicking probe for escaped-handle checks.
    pub fn isAlive(self: Element) bool {
        const frame = active_frame orelse return false;
        return self.generation == frame.generation and self.index < frame.node_count;
    }

    /// Attach a stable key (gap §5A): a `platform.id` hash that identifies
    /// this element across frames (e.g. per-row keys so state follows data
    /// when a list reorders). The frame tracks seen keys and diagnoses
    /// duplicates via `Frame.duplicate_keys`. Zero is reserved for unkeyed
    /// nodes and panics (a real `platform.id` is never zero).
    pub fn keyed(self: Element, key: u64) Element {
        if (key == 0) @panic("ZUI stable key must be nonzero");
        self.node().stable_key = key;
        currentFrame().trackKey(key);
        return self;
    }

    /// `keyed()` from a call-site source location plus an index extra
    /// (row id, tab id, ...), using the collision-fixed `platform.id`.
    pub fn keyedAuto(self: Element, parent: platform.Id, src: std.builtin.SourceLocation, extra: u64) Element {
        return self.keyed(platform.id.fromSrc(parent, src, extra));
    }

    pub fn flex_row(self: Element) Element {
        self.node().style.direction = .row;
        return self;
    }
    pub fn flex_col(self: Element) Element {
        self.node().style.direction = .column;
        return self;
    }
    pub fn flex_1(self: Element) Element {
        self.node().style.flex_grow = 1;
        return self;
    }
    pub fn items_center(self: Element) Element {
        self.node().style.alignment = .center;
        return self;
    }
    pub fn justify_center(self: Element) Element {
        self.node().style.justify = .center;
        return self;
    }
    pub fn justify_between(self: Element) Element {
        self.node().style.justify = .between;
        return self;
    }
    pub fn gap(self: Element, value: f32) Element {
        self.node().style.gap = value;
        return self;
    }
    pub fn w(self: Element, value: f32) Element {
        self.node().style.width = value;
        return self;
    }
    pub fn h(self: Element, value: f32) Element {
        self.node().style.height = value;
        return self;
    }
    pub fn w_full(self: Element) Element {
        self.node().style.full_width = true;
        return self;
    }
    /// Fill the parent's content height (`style.full_height`).
    pub fn h_full(self: Element) Element {
        self.node().style.full_height = true;
        return self;
    }
    pub fn size(self: Element, value: f32) Element {
        self.node().style.square = value;
        return self;
    }
    pub fn size_full(self: Element) Element {
        self.node().style.full_width = true;
        self.node().style.full_height = true;
        return self;
    }
    pub fn max_w_full(self: Element) Element {
        self.node().style.max_width_full = true;
        return self;
    }
    pub fn p(self: Element, value: f32) Element {
        self.node().style.padding = EdgeValues.all(value);
        return self;
    }
    pub fn px(self: Element, value: f32) Element {
        self.node().style.padding.left = value;
        self.node().style.padding.right = value;
        return self;
    }
    pub fn py(self: Element, value: f32) Element {
        self.node().style.padding.top = value;
        self.node().style.padding.bottom = value;
        return self;
    }
    pub fn pl(self: Element, value: f32) Element {
        self.node().style.padding.left = value;
        return self;
    }
    pub fn pr(self: Element, value: f32) Element {
        self.node().style.padding.right = value;
        return self;
    }
    pub fn pt(self: Element, value: f32) Element {
        self.node().style.padding.top = value;
        return self;
    }
    pub fn pb(self: Element, value: f32) Element {
        self.node().style.padding.bottom = value;
        return self;
    }
    pub fn absolute(self: Element) Element {
        self.node().style.absolute = true;
        return self;
    }
    pub fn inset(self: Element, value: f32) Element {
        self.node().style.inset_value = value;
        return self;
    }
    pub fn top(self: Element, value: f32) Element {
        self.node().style.top = value;
        return self;
    }
    pub fn right(self: Element, value: f32) Element {
        self.node().style.right = value;
        return self;
    }
    pub fn left(self: Element, value: f32) Element {
        self.node().style.left = value;
        return self;
    }
    pub fn bg(self: Element, value: core.Color) Element {
        self.node().style.background = value;
        return self;
    }
    pub fn bg_gradient(self: Element, from: core.Color, to: core.Color) Element {
        self.node().style.background = from;
        self.node().style.gradient_to = to;
        return self;
    }
    pub fn opacity(self: Element, value: f32) Element {
        self.node().style.opacity = std.math.clamp(value, 0, 1);
        return self;
    }
    pub fn blur(self: Element, value: f32) Element {
        self.node().style.blur = value;
        return self;
    }
    pub fn rounded_lg(self: Element) Element {
        self.node().style.radius = 8;
        return self;
    }
    /// Arbitrary corner radius in px (the named helpers set 8/12/16/999).
    pub fn rounded(self: Element, value: f32) Element {
        self.node().style.radius = value;
        return self;
    }
    pub fn rounded_xl(self: Element) Element {
        self.node().style.radius = 12;
        return self;
    }
    pub fn rounded_2xl(self: Element) Element {
        self.node().style.radius = 16;
        return self;
    }
    pub fn rounded_full(self: Element) Element {
        self.node().style.radius = 999;
        return self;
    }
    pub fn border_1(self: Element) Element {
        self.node().style.border_width = 1;
        return self;
    }
    pub fn border_2(self: Element) Element {
        self.node().style.border_width = 2;
        return self;
    }
    pub fn border_b_1(self: Element) Element {
        self.node().style.border_width = 1;
        self.node().style.border_bottom_only = true;
        return self;
    }
    pub fn border_dashed(self: Element) Element {
        self.node().style.dashed_border = true;
        return self;
    }
    pub fn border_color(self: Element, value: core.Color) Element {
        self.node().style.border_color = value;
        return self;
    }
    pub fn shadow_lg(self: Element) Element {
        self.node().style.shadow = true;
        return self;
    }
    pub fn text_color(self: Element, value: core.Color) Element {
        self.node().style.text_color = value;
        return self;
    }
    pub fn cursor_pointer(self: Element) Element {
        self.node().style.cursor = .pointer;
        return self;
    }
    pub fn cursor_text(self: Element) Element {
        self.node().style.cursor = .text;
        return self;
    }
    pub fn object_fit(self: Element, fit: ImageFit) Element {
        self.node().image.fit = fit;
        return self;
    }
    pub fn grayscale(self: Element) Element {
        self.node().image.gray = true;
        return self;
    }
    pub fn tint(self: Element, value: core.Color) Element {
        self.node().image.tint = value;
        return self;
    }
    pub fn hover_bg(self: Element, value: core.Color) Element {
        self.node().style.hover_background = value;
        return self;
    }
    pub fn hover_border(self: Element, value: core.Color) Element {
        self.node().style.hover_border = value;
        return self;
    }
    pub fn on_click(self: Element, listener: Listener) Element {
        self.node().listener = listener;
        return self;
    }
    pub fn on_mouse_down(self: Element, listener: Listener) Element {
        self.node().mouse_down_listener = listener;
        return self;
    }
    pub fn on_mouse_up(self: Element, listener: Listener) Element {
        self.node().mouse_up_listener = listener;
        return self;
    }
    pub fn on_mouse_move(self: Element, listener: Listener) Element {
        self.node().mouse_move_listener = listener;
        return self;
    }
    pub fn on_scroll(self: Element, listener: Listener) Element {
        self.node().scroll_listener = listener;
        return self;
    }
    pub fn flex_wrap(self: Element) Element {
        self.node().style.flex_wrap = true;
        return self;
    }
    pub fn scroll_x(self: Element, value: f32) Element {
        self.node().style.scroll_x = value;
        return self;
    }
    pub fn scroll_y(self: Element, value: f32) Element {
        self.node().style.scroll_y = value;
        return self;
    }
    pub fn on_double_click(self: Element, listener: Listener) Element {
        self.node().double_click_listener = listener;
        return self;
    }

    /// Attach semantics to a keyed element. Strings are copied into the frame;
    /// targets must outlive this frame (or be registered with trackOwner).
    pub fn semantic(self: Element, properties: @import("../a11y/root.zig").Properties) Element {
        _ = self.node();
        const frame = currentFrame();
        if (frame.semantic_count == frame.semantic_bindings.len) {
            frame.semantic_dropped += 1;
            return self;
        }
        var owned = properties;
        owned.name = frame.copyText(properties.name);
        owned.text_value = frame.copyText(properties.text_value);
        frame.semantic_bindings[frame.semantic_count] = .{ .index = self.index, .properties = owned };
        frame.semantic_count += 1;
        return self;
    }

    pub fn withFocus(self: Element, focus: FocusHandle) Element {
        self.node().focus = focus;
        return self;
    }

    pub fn child(self: Element, value: anytype) Element {
        const T = @TypeOf(value);
        const child_element: Element = if (T == Element)
            value
        else if (@typeInfo(T) == .optional)
            if (value) |present| present else return self
        else if (@hasDecl(T, "toElement"))
            value.toElement()
        else
            @compileError("unsupported ZUI child type: " ++ @typeName(T));

        const frame = currentFrame();
        if (!child_element.isAlive()) @panic("ZUI child element handle escaped its frame");
        const parent = self.node();
        const child_node = &frame.nodes[child_element.index];
        child_node.next_sibling = null;
        if (parent.last_child) |last| {
            frame.nodes[last].next_sibling = child_element.index;
        } else {
            parent.first_child = child_element.index;
        }
        parent.last_child = child_element.index;
        return self;
    }

    pub fn children(self: Element, values: anytype, owner: anytype, render_fn: anytype, cx: anytype) Element {
        _ = owner;
        var result = self;
        for (values) |value| {
            if (render_fn(cx.current.?.value, value, cx)) |rendered| {
                result = result.child(rendered);
            }
        }
        return result;
    }
};

pub fn div() Element {
    const frame = currentFrame();
    return frame.makeElement(.container);
}

pub fn spacer() Element {
    const frame = currentFrame();
    const result = frame.makeElement(.spacer);
    return result.flex_1();
}

/// Resolve a preloaded source identity. No I/O, probing, decoding or hashing.
pub fn sourceAsset(source: ImageSource, cache: *images.Cache) ?images.AssetHandle {
    return switch (source) {
        .asset => |h| h,
        .path => |path| cache.assets.findPath(path),
        .bytes => |bytes| cache.assets.findBytes(bytes),
        .handle => null,
    };
}

fn resolveIntrinsic(source: ImageSource, cache: ?*images.Cache) struct { w: f32, h: f32 } {
    if (source == .handle) return .{ .w = @floatFromInt(source.handle.w), .h = @floatFromInt(source.handle.h) };
    if (cache) |c| {
        if (sourceAsset(source, c)) |h| {
            if (c.assets.metadata(h)) |m| return .{ .w = m.w, .h = m.h };
        }
    }
    // Unrequested/loading/failed assets have a visible natural placeholder.
    return .{ .w = 24, .h = 24 };
}

/// Image element from raw bytes (PNG/JPEG/GIF/BMP, or SVG which rasterizes
/// at intrinsic size — GPUI `img()` parity).
pub fn img(source: []const u8) Element {
    return makeImage(.{ .bytes = source }, false);
}

/// Image from a preloaded file path; unknown paths show a placeholder.
pub fn imgPath(path: []const u8) Element {
    return makeImage(.{ .path = path }, false);
}

/// Image element from a decoded cache handle.
pub fn imgHandle(handle: images.Handle) Element {
    return makeImage(.{ .handle = handle }, false);
}

/// Stable service handle, independent of decoded-pool slot generations.
pub fn imgAsset(handle: images.AssetHandle) Element {
    return makeImage(.{ .asset = handle }, false);
}

/// SVG element from raw bytes, tinted through `currentColor` (GPUI icon
/// parity: `.tint(text_color)` recolors lucide-style stroke icons).
pub fn svg(source: []const u8) Element {
    return makeImage(.{ .bytes = source }, true);
}

/// SVG element from a file path.
pub fn svgPath(path: []const u8) Element {
    return makeImage(.{ .path = path }, true);
}

fn makeImage(source: ImageSource, is_svg: bool) Element {
    const frame = currentFrame();
    const result = frame.makeElement(.image);
    const n = result.node();
    n.image.source = source;
    n.image.svg = is_svg;
    const size = resolveIntrinsic(source, frame.images);
    n.image.intrinsic_w = size.w;
    n.image.intrinsic_h = size.h;
    return result;
}

pub fn text(value: []const u8, options: anytype) Element {
    const frame = currentFrame();
    const result = frame.makeElement(.text);
    const n = result.node();
    n.text_value = value;
    const T = @TypeOf(options);
    if (@hasField(T, "size")) n.text_style.size = options.size;
    if (@hasField(T, "line_height")) n.text_style.line_height = options.line_height;
    if (@hasField(T, "tracking")) n.text_style.tracking = options.tracking;
    if (@hasField(T, "font")) n.text_style.font = options.font;
    if (@hasField(T, "weight")) n.text_style.weight = options.weight;
    if (@hasField(T, "color")) n.text_style.color = options.color;
    if (@hasField(T, "strike")) n.text_style.strike = options.strike;
    return result;
}

pub fn textFmt(comptime format: []const u8, args: anytype, options: anytype) Element {
    const frame = currentFrame();
    var buffer: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buffer, format, args) catch "text too long";
    return text(frame.copyText(formatted), options);
}

pub fn when(condition: bool, value: Element) Element {
    if (condition) return value;
    return div().size(0);
}

pub fn progressBar(value: f32, width: f32) Element {
    const fraction = std.math.clamp(value, 0, 1);
    return div().w(width).h(6).rounded_full().bg(core.Color.hex(0xffffff14))
        .child(div().w(width * fraction).h(6).rounded_full().bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8)));
}

pub fn progressTrack(value: f32) Element {
    // Flex-proportioned fill: the old fixed 520px child overflowed windows
    // narrower than the design 560px column. Fill flexes with `fraction`,
    // spacer takes the rest, so the track always fits its parent.
    const fraction = std.math.clamp(value, 0, 1);
    var track = div().w_full().h(4).flex_row().rounded_full().bg(core.Color.hex(0xffffff10));
    if (fraction > 0.0001) {
        var fill = div().h(4).rounded_full().bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8));
        fill.node().style.flex_grow = @max(0.0001, fraction);
        track = track.child(fill);
    }
    if (fraction < 0.9999) {
        var rest = spacer();
        rest.node().style.flex_grow = @max(0.0001, 1 - fraction);
        track = track.child(rest);
    }
    return track;
}

pub fn formatToday() []const u8 {
    return "TODAY";
}

test "keyed elements track keys and diagnose duplicates" {
    const t = std.testing;
    const frame = try t.allocator.create(Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    beginFrame(frame);
    defer endFrame();

    const a = div().keyed(101);
    try t.expect(a.isAlive());
    try t.expectEqual(@as(u64, 101), frame.nodes[a.index].stable_key);
    try t.expectEqual(@as(u64, 0), frame.duplicate_keys);

    // Distinct keys are fine.
    _ = div().keyed(102);
    try t.expectEqual(@as(u64, 0), frame.duplicate_keys);

    // A repeated key is diagnosed, not silently aliased.
    _ = div().keyed(101);
    try t.expectEqual(@as(u64, 1), frame.duplicate_keys);
    try t.expectEqual(@as(usize, 2), frame.seen_key_count);
}

test "escaped element handles fail predictably" {
    const t = std.testing;
    const frame = try t.allocator.create(Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    beginFrame(frame);
    const stale = div().keyed(7);
    try t.expect(stale.isAlive());
    endFrame();
    // No active frame: every handle reads dead.
    try t.expect(!stale.isAlive());
    // Next frame recycles slot 0: the old handle stays dead while the new
    // handle at the same index is alive — generations distinguish them.
    frame.reset(@ptrFromInt(1), .{});
    beginFrame(frame);
    defer endFrame();
    try t.expect(!stale.isAlive());
    const fresh = div();
    try t.expect(fresh.isAlive());
    try t.expectEqual(stale.index, fresh.index);
    try t.expect(stale.generation != fresh.generation);
    // A fresh frame starts a fresh key scope.
    try t.expectEqual(@as(u64, 0), frame.duplicate_keys);
}

test "keyedAuto derives stable ids from call-site identity" {
    const t = std.testing;
    const frame = try t.allocator.create(Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    beginFrame(frame);
    defer endFrame();

    const a = div().keyedAuto(platform.id.NO_PARENT, @src(), 3);
    const b = div().keyedAuto(platform.id.NO_PARENT, @src(), 3);
    // Same file but different columns => different keys (id.zig overlap
    // regression would collide these).
    try t.expect(frame.nodes[a.index].stable_key != frame.nodes[b.index].stable_key);
    try t.expectEqual(@as(u64, 0), frame.duplicate_keys);
}

test "owner table registers mint-time owners without touching targets" {
    const t = std.testing;
    const frame = try t.allocator.create(Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    // No active frame: registration is a safe no-op.
    var store_token: u8 = 0;
    var target_token: u8 = 0;
    trackEntityOwner(&target_token, &store_token, 9, 3);
    try t.expectEqual(@as(usize, 0), frame.owner_count);

    beginFrame(frame);
    defer endFrame();
    trackEntityOwner(&target_token, &store_token, 9, 3);
    try t.expectEqual(@as(usize, 1), frame.owner_count);
    const hit = frame.lookupOwner(&target_token) orelse return error.TestExpectedHit;
    try t.expect(hit.store == @as(*anyopaque, &store_token));
    try t.expectEqual(@as(u32, 9), hit.id);
    try t.expectEqual(@as(u32, 3), hit.generation);
    // Re-registering the same target refreshes instead of growing.
    trackEntityOwner(&target_token, &store_token, 9, 4);
    try t.expectEqual(@as(usize, 1), frame.owner_count);
    try t.expectEqual(@as(u32, 4), frame.lookupOwner(&target_token).?.generation);
    // Unknown targets miss (ungated dispatch, as before).
    var stranger: u8 = 0;
    try t.expect(frame.lookupOwner(&stranger) == null);
}
