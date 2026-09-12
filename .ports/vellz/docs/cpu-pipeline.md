# CPU pipeline interfaces

Fixed signatures for the Zig port of `vello_common` (strips) and `vello_cpu`
(rows and kernels). Implementations must follow these names so separately
ported modules link into one pipeline. Upstream file references are in the
coverage ledger (`plan.md` §5).

## Strip generation (`src/common`)

Cycle-split note (Zig has no import cycles; upstream `strip_generator.rs` and
`clip.rs` import each other):

- `strip_storage.zig` owns `StripStorage`, `GenerationMode`, `PathDataRef`.
- `intersect.zig` owns the strip-intersection algorithm (`intersect` and its
  row iterators); it depends only on strip/tile/geometry/util.
- `strip_generator.zig` imports `intersect.zig` and `strip_storage.zig`;
  `clip.zig` imports `strip_generator.zig`.

```zig
// common/flatten.zig
pub const Point = struct { x: f32, y: f32 };
pub const Line = struct { p0: Point, p1: Point };
pub const FlattenCtx = struct { /* upstream fields */ };

/// Appends flattened, culled lines for `path` under `affine` to `line_buf`.
/// `line_buf` is cleared first. `cull_bbox` is in scene pixels.
pub fn fill(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path: []const kurbo.PathEl,
    affine: kurbo.Affine,
    line_buf: *std.ArrayList(Line),
    ctx: *FlattenCtx,
    cull_bbox: geometry.RectU16,
) !void;

pub fn stroke(...) !void; // M2 (needs kurbo stroke port)
```

```zig
// common/tile.zig
pub const Tile = struct {
    x: u16,
    y: u16,
    packed_winding_line_idx: u32,
    /* upstream bit accessors as methods */
};
pub const Tiles = struct {
    pub fn init(allocator: std.mem.Allocator, level: simd.Level, width: u16, height: u16) Tiles;
    pub fn deinit(self: *Tiles, allocator: std.mem.Allocator) void;
    /// Returns whether geometry left of the viewport was culled (upstream culled flag).
    pub fn makeTilesAnalyticAa(self: *Tiles, allocator: std.mem.Allocator, lines: []const flatten.Line, width: u16, height: u16) !bool;
    pub fn sortTiles(self: *Tiles) void;
    pub fn get(self: *const Tiles, idx: usize) Tile;
    pub fn items(self: *const Tiles) []const Tile; // requires sorted
};
```

```zig
// common/strip.zig
pub const Strip = struct {
    x: u16, // pixel, multiple of 4
    y: u16, // pixel, multiple of 4
    packed_alpha_idx_fill_gap: u32,
    /* alphaIdx(), setAlphaIdx(), fillGap(), setFillGap(), stripY(), widthTo(next) */
};
pub const StripAlphaFillSegment = struct { fill: peniko.Fill, alpha_idx: u32 };
pub const StripFillSegment = struct { tile_x0: u16, tile_x1: u16, tile_y: u16, /* pixel/tile rect helpers */ };

/// Port of strip.rs::render; appends strips + alphas (does not clear).
pub fn render(
    allocator: std.mem.Allocator,
    level: simd.Level,
    tiles: *const Tiles,
    strip_buf: *std.ArrayList(Strip),
    alpha_buf: *std.ArrayList(u8),
    fill_rule: peniko.Fill,
    aliasing_threshold: ?u8,
    lines: []const flatten.Line,
) !void;

pub fn visitStripFillSegments(
    strips: []const Strip,
    tile_bounds: ?geometry.RectU16,
    context: anytype, // methods onFillSegment(ctx, StripFillSegment), onAlphaSegment(ctx, StripAlphaFillSegment)
    alpha_fill: bool,
    fill: bool,
) void;

/// Moved from upstream util.rs (imports Strip/Tile).
pub fn stripBbox(strips: []const Strip) ?geometry.RectU16;
```

```zig
// common/strip_generator.zig
pub const GenerationMode = union(enum) { replace, append, replace_after: usize };
pub const StripStorage = struct { ... }; // moved to strip_storage.zig in the port
pub const PathDataRef = struct {
    strips: []const Strip,
    alphas: []const u8,
    bbox: geometry.RectU16,
};
pub const StripGenerator = struct {
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, level: simd.Level) StripGenerator;
    pub fn deinit(self: *StripGenerator, allocator: std.mem.Allocator) void;
    pub fn generateFilledPath(
        self: *StripGenerator,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: peniko.Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
        storage: *StripStorage,
        clip: ?PathDataRef,
    ) !void;
    pub fn generateFilledRectFast(...) !void; // common/rect.zig; M1 optional
    pub fn reset(self: *StripGenerator, width: u16, height: u16) void;
};
```

## CPU rows (`src/cpu`)

```zig
// cpu/coarse/cmd.zig
pub const Span = struct { start: u32, end: u32 };
pub const PaintFillAttrs = struct { paint: common.paint.Paint, blend_mode: peniko.BlendMode, mask: ?*const common.mask.Mask, draw_id: u32, thread_idx: u8, origin: common.geometry.RectU16 };
pub const LayerFillAttrs = struct { blend_mode: peniko.BlendMode, opacity: f32, mask: ?*const common.mask.Mask, draw_id: u32, thread_idx: u8 };
pub const PaintFill = struct { span: Span, alpha_idx: ?u32, attrs_idx: u32 };
pub const DepthFill = struct { bucket_range: BucketRange, attrs_idx: u32 };
pub const LayerFill = struct { span: Span, alpha_idx: ?u32, attrs_idx: u32 };
pub const RenderCmd = union(enum) {
    paint_fill: PaintFill,
    push_buf: ?Span,
    pop_buf,
    layer_fill: LayerFill,
};
```

```zig
// cpu/coarse/depth.zig
pub const DEPTH_BUCKET_WIDTH = 128;
pub const BucketRange = struct { ... };
pub fn splitOpaqueSpan(span: Span, cb: anytype) void;
pub const DepthBuffer = struct {
    pub fn forEachVisibleRun(self: *const DepthBuffer, span: Span, draw_id: u32, cb: anytype) void;
};
```

```zig
// cpu/coarse/bucketer.zig
pub const CommandBucketer = struct {
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) CommandBucketer;
    pub fn deinit(self: *CommandBucketer, allocator: std.mem.Allocator) void;
    pub fn reset(self: *CommandBucketer, allocator: std.mem.Allocator, width: u16, height: u16) void;
    pub fn bucketCommands(
        self: *CommandBucketer,
        allocator: std.mem.Allocator,
        recorder: *const common.record.CommandRecorder(cpu.record.RecordedFill),
        strips: []const Strip,
        encoded_paints: []const common.encode.EncodedPaint,
        filter_ctx: *const cpu.filter.FilterContext,
    ) !void;
    pub fn rows(self: *CommandBucketer) []RowState;
};
```

## Fine rasterization

```zig
// cpu/fine/mod.zig
pub fn Fine(comptime K: type) type { ... } // buffers + pushBuf/popBuf/pack/unpack

/// K is the kernel type (`highp.F32Kernel` or `lowp.U8Kernel`).
/// Required K surface: Numeric, Composite, NumericVec types; extractColor,
/// pack, unpack, copySolid, applyMask, applyTint, alphaCompositeSolid,
/// alphaCompositeBuffer, blend, fillSolid. Painters are selected in
/// `Fine.indexedFill` by `K.Numeric` and implement both `paint` (f32) and
/// `paintU8` (converted or native u8).
pub fn rasterizeRegion(
    comptime K: type,
    fine: *Fine(K),
    depth: *coarse.DepthBuffer,
    region: Region,
    bucketer: *const coarse.CommandBucketer,
    resources: FineResources,
    target_init: common.target.TargetInit,
    root_is_blend_target: bool,
) void;
```

`fine/mod.zig` is generic over the kernel (`highp.F32Kernel` for
`optimize_quality`, `lowp.U8Kernel` for `optimize_speed`). Operators on the
buffer are dispatched through comptime `K`, never through a runtime vtable;
`dispatch/single_threaded.zig` passes the kernel as a comptime parameter.

## Dispatch and public renderer

```zig
// cpu/dispatch/mod.zig
pub const Dispatcher = struct { ptr: *anyopaque, vtable: *const VTable, ... };
// Vtable methods mirror upstream's `Dispatcher` trait. `Dispatcher.create`
// selects `single_threaded.SingleThreadedDispatcher` for `num_threads == 0`
// and `multi_threaded.MultiThreadedDispatcher` otherwise (M4); the concrete
// dispatcher is heap-allocated so `RenderContext` stays movable.

// cpu/dispatch/multi_threaded.zig (+ multi_threaded/{task,cost,worker,sync}.zig)
// Persistent `std.Thread` workers replace rayon; a mutex/condvar queue carries
// `RenderTask` batches main -> worker and in-order completion slots carry
// strips/commands back. Rasterization splits the target into disjoint strip-row
// `Region`s claimed with an atomic cursor (row splitting as upstream). The f32
// output is byte-identical to the single-threaded path (differential test in
// `cpu/render.zig`).

// cpu/render.zig
pub const RenderMode = enum { optimize_speed, optimize_quality };
pub const PixelFormat = enum { rgba8 };
pub const RenderSettings = struct { level: simd.Level, num_threads: u16 };
pub const RasterizerSettings = struct { render_mode: RenderMode, target_init: TargetInit, pixel_format: PixelFormat, offset: struct { x: u16, y: u16 } };
pub const Resources = struct { ... };
pub const RenderContext = struct {
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, settings: RenderSettings) !RenderContext;
    pub fn deinit(self: *RenderContext, allocator: std.mem.Allocator) void;
    pub fn setPaint(self: *RenderContext, paint: anytype) void; // Into<PaintType>
    pub fn setTransform(self: *RenderContext, affine: kurbo.Affine) void;
    pub fn setFillRule(self: *RenderContext, rule: peniko.Fill) void;
    pub fn setStroke(self: *RenderContext, stroke: kurbo.Stroke) void;
    pub fn fillPath(self: *RenderContext, allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void;
    pub fn fillRect(self: *RenderContext, allocator: std.mem.Allocator, rect: kurbo.Rect) !void;
    pub fn strokePath(self: *RenderContext, allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void; // M2
    pub fn pushClipPath(self: *RenderContext, allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void;
    pub fn popClipPath(self: *RenderContext) void;
    pub fn flush(self: *RenderContext) !void; // fallible for MT dispatch (upstream panics)
    pub fn renderWith(self: *RenderContext, pixmap: *common.pixmap.Pixmap, resources: *Resources, settings: RasterizerSettings) !void;
    pub fn render(self: *RenderContext, pixmap: *common.pixmap.Pixmap, resources: *Resources) !void;
    pub fn reset(self: *RenderContext) void;
};
```

## Glyph rendering (`vellz.glifo` + `vellz.cpu.text`)

```zig
// glifo/glyph.zig
pub const GlyphRun = struct {
    font: FontData, font_size: f32, font_embolden: FontEmbolden,
    transform: Affine, scene_paint_transform: Affine,
    glyph_transform: ?Affine, normalized_coords: []const NormalizedCoord, hint: bool,
};
pub fn prepareGlyphRun(run: GlyphRun) Error!PreparedGlyphRun; // error.Unsupported: hinting/embolden/coords
pub fn GlyphRunBuilder(comptime Backend: type) type; // fontSize/fontEmbolden/glyphTransform/hint/
                                                     // normalizedCoords/atlasCache/fillGlyphs/strokeGlyphs
pub fn buildRenderer(run, glyphs, prep_cache, atlas_cacher) Error!GlyphRunRenderer(Glyphs);

// glifo/renderer.zig: fillGlyph / strokeGlyph / renderCachedGlyph /
// replayAtlasCommands / calculateRasterMetrics / supportsAtlasCaching.
// glifo/interface.zig holds the comptime duck-typing contracts (`DrawSink`,
// `GlyphRenderer`) and the `assert*` helpers renderer.zig instantiates.

// cpu/render.zig
pub const Resources = struct {
    image_registry: ImageRegistry,
    glyph_prep_cache: glifo.GlyphPrepCache,
    glyph_resources: ?text.GlyphAtlasResources, // lazily created
};
pub fn RenderContext.glyphRun(self, resources, font) GlyphRunBuilder;

// Frame protocol, same order as upstream `render_with`:
//   beforeRender  -> replay pending atlas commands into the page pixmaps,
//                    register atlas pages in the image registry
//   target clear  -> rasterize (image ids >= ATLAS_IMAGE_ID_BASE resolve pages)
//   afterRender   -> maintain/evict, unregister pages, clear evicted regions
```

- `text.GlyphAtlasResources` owns the atlas cache, the image allocator, one
  page-sized `RenderContext` (always `num_threads = 0`, as upstream) and one
  shared `Pixmap` per atlas page; `renderWith` drives the protocol above.
- `GlyphCacheKey` carries font id/index, gid, size bits, hinted, the four
  subpixel buckets, the packed context color and the embolden bits;
  `var_coords` is excluded from equality (upstream's second-level map; only
  empty coordinates are supported here).
- Determinism divergence: the glyph cache map uses fixed-seed Wyhash instead
  of upstream's fixed-seed `foldhash`. Eviction/iteration order can differ;
  pixels cannot, because atlas slots are disjoint and sampled at integer
  offsets.
- Decoration (`renderDecoration`) is ported: underline/overline/
  strikethrough spans with skip-ink exclusions, using the prep cache's
  `underline_exclusions` buffer. Upstream's lazy span iterator becomes one
  pass over the merged exclusion list; rectangle values and order match the
  pinned oracle (`--dump-decoration`).
- Deferred with typed errors, never approximated: hinting interpreter/autohint
  (an eligible hinted run fails up front), `gvar`/`HVAR` coordinates, CFF/CFF2,
  CBDT/CBLC/sbix bitmaps and COLR/CPAL. A font carrying a COLR/CBDT/CBLC/sbix
  table rejects the whole run with `error.Unsupported` instead of silently
  dropping the color/bitmap representation.

## Error policy

- Invalid usage (unpopped layers at render, mismatched mask sizes, missing
  image ids) returns a typed error where upstream would panic or assert; the
  upstream behavior and message are referenced in a comment.
- Unsupported upstream features (external textures, multi-primitive filter
  graphs, MT filters) return `error.Unsupported`; they are never silently
  skipped.
- `flush` is required before `renderWith` in the MT configuration and returns
  `error.NotFlushed` otherwise (upstream panics); the single-threaded
  implementation is a no-op like upstream.
- Multi-threaded dispatch with more than 255 threads returns
  `error.TooManyThreads` (worker ids are `u8` upstream and silently wrap).
