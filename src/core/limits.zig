//! Static allocation limits for ZUI.
//!
//! Ported from Gooey (https://github.com/duanebester/gooey),
//! MIT licensed, Copyright 2025 Duane Bester <bester.duane@gmail.com>.
//! Permission notice: free use/copy/modify/merge/publish/distribute/
//! sublicense/sell with this notice included. Provided AS-IS, no warranty.
//!
//! Hot frame storage (scene, layout nodes, atlas) uses fixed upper bounds
//! so warm rendering avoids growing allocations. Cold paths (window
//! creation, font discovery, image decode, Taffy tree storage) may still
//! allocate; see plan M10 for the per-subsystem budget policy. Some
//! entries below are inherited Gooey caps for systems not present in this
//! tree (path/mesh pools, web renderer); they are kept for the caps they
//! still bound and will be pruned as budgets get per-owner homes.
//!
//! ## Design Philosophy
//!
//! - Bound reusable hot storage; expose overflow instead of growing it
//! - Prefer fixed-capacity arrays over growing ArrayLists during rendering
//! - Put a limit on hot buffers to prevent infinite loops and tail latency spikes
//!
//! ## Capacity policy (gap §3): one rule per overflow kind
//!
//! Hot-frame storage never grows mid-frame. When a bound is reached the
//! outcome depends on what overflowed — four disjoint cases:
//!
//! 1. Recoverable growth (cold paths only): window creation, font
//!    discovery, image decode, and Taffy tree storage may allocate through
//!    the caller-provided allocator. These run outside the frame hot loop,
//!    so growth is bounded by explicit input sizes (e.g.
//!    `MAX_IMAGE_PIXELS`, `MAX_SVG_BYTES`) and reported as errors.
//! 2. Rejected frames: the ordered scene command stream (`Scene.push`,
//!    glyph and image-blit pushes) fails fast and counts `dropped` when
//!    full. An overflowed frame is REJECTED, never presented partial:
//!    `Window.render` substitutes the diagnostic placeholder
//!    (`Scene.renderOverflowPlaceholder`), so the backend always receives
//!    a complete frame; the rejection stays observable in
//!    `dropped`/`dropped_frame`, `rejected_frames`, and benchmark gates —
//!    and oversized workloads must virtualize or shrink (see the
//!    text-benchmark overflow discussion in the gap report §3).
//! 3. Diagnostic placeholders: resource pools that cannot fail the frame
//!    degrade visibly and count the gap. The glyph atlas defers eviction
//!    and reports overflow (missing glyphs are skipped and counted in
//!    `cozmic_skipped_glyphs`, never overwritten mid-frame); hit-region
//!    overflow counts `dropped_regions` instead of losing clicks silently;
//!    image-pool exhaustion drops the image with a log line.
//! 4. Preserved critical events: the input queue (`platform/event.zig`,
//!    `MAX_EVENTS_PER_FRAME`) never silently drops key-up, button-up,
//!    text commit, close, or focus loss. Under pressure it coalesces
//!    motion/resize into queued peers and evicts the oldest coalescable
//!    entry to admit criticals; only a queue with no coalescable victim
//!    fails, and then it logs, counts `critical_overflow`, and returns an
//!    error. Droppable input (key/button-down, focus-gain, scroll) is
//!    discarded with a count in `dropped`.
//!
//! Element-node and frame-text exhaustion panic today (a programming bug,
//! not a workload signal); scene and hit-region overflow produce counted
//! partial output per (2)/(3). Do not conflate the two: panics mean the
//! caller built an oversized tree, counters mean the frame shed load.
//!
//! ## Limit Hierarchy (what exists in this tree)
//!
//! ```
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Per-frame scene limits (gpu/scene.zig)                                  │
//! │ - MAX_QUADS_PER_FRAME / MAX_SCENE_GLYPHS / MAX_IMAGE_BLITS_PER_FRAME    │
//! │ Purpose: Bound GPU upload size, fail fast on runaway rendering          │
//! └─────────────────────────────────────────────────────────────────────────┘
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Text/Atlas limits (fonts/)                                              │
//! │ - MAX_GLYPHS_PER_RUN / MAX_ATLAS_GLYPHS / MAX_ATLAS_PIXELS              │
//! │ Purpose: Bound shaping runs and the glyph pixel pool                    │
//! └─────────────────────────────────────────────────────────────────────────┘
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Image/Grid/GPU-pool limits (images/, layout/, gpu/device.zig)           │
//! │ - MAX_IMAGE_POOL_BYTES / MAX_CACHED_IMAGES / MAX_GPU_*                  │
//! │ Purpose: Bound decoded pixels and fixed driver handle pools             │
//! └─────────────────────────────────────────────────────────────────────────┘
//! ```

const std = @import("std");

// =============================================================================
// Rendering Limits
// =============================================================================

/// Maximum quads per frame (rectangles, backgrounds)
pub const MAX_QUADS_PER_FRAME: u32 = 65536;

/// Maximum glyphs per frame (text characters)
pub const MAX_GLYPHS_PER_FRAME: u32 = 65536;

/// Maximum shaped glyphs collected into one `Scene`. Separate from the
/// shaping-run cap: a frame holds many runs. Each entry is ~52 bytes.
pub const MAX_SCENE_GLYPHS: u32 = 16384;

/// Maximum shadows per frame
pub const MAX_SHADOWS_PER_FRAME: u32 = 4096;

/// Maximum SVG instances per frame
pub const MAX_SVGS_PER_FRAME: u32 = 8192;

/// Maximum images per frame
pub const MAX_IMAGES_PER_FRAME: u32 = 4096;

/// Maximum path instances per frame
pub const MAX_PATHS_PER_FRAME: u32 = 4096;

/// Maximum polylines per frame
pub const MAX_POLYLINES_PER_FRAME: u32 = 4096;

/// Maximum point clouds per frame
pub const MAX_POINT_CLOUDS_PER_FRAME: u32 = 4096;

/// Maximum colored point clouds per frame (per-point colors for heat maps, particle effects)
pub const MAX_COLORED_POINT_CLOUDS_PER_FRAME: u32 = 4096;

/// Maximum clip stack depth (nested clips)
pub const MAX_CLIP_STACK_DEPTH: u32 = 32;

// =============================================================================
// Layout Limits
// =============================================================================

/// Maximum layout elements in tree
pub const MAX_LAYOUT_ELEMENTS: u32 = 4096;

/// Maximum nested component depth (prevent stack overflow)
pub const MAX_NESTED_COMPONENTS: u32 = 64;

/// Maximum render commands per frame (the ordered paint stream: one entry
/// per pushed quad, glyph, or blit).
///
/// Coherence rule: this must cover a glyph-only frame, i.e. be >=
/// MAX_SCENE_GLYPHS (each glyph costs one command). The old 8192 cap bound
/// the command stream BEFORE the 16384 glyph payload filled, so the text
/// benchmark silently dropped 128 glyphs on the 256-sentence row and 1664
/// on the 64-paragraph row while payload space sat empty (gap report §3).
/// Mixed quad+glyph frames still share this one budget — see the overflow
/// policy in `gpu/scene.zig`; overflow rejects the frame, never partial
/// presents.
pub const MAX_RENDER_COMMANDS: u32 = 16384;

// =============================================================================
// Text Limits
// =============================================================================

/// Maximum glyphs in a single shaped run
pub const MAX_GLYPHS_PER_RUN: u32 = 1024;

/// Maximum cached shaped runs
pub const MAX_SHAPED_RUN_CACHE: u32 = 256;

/// Maximum text length for single-line inputs
pub const MAX_TEXT_LEN: u32 = 512;

/// Maximum font file path length for a fontconfig match copy (init-time).
pub const MAX_FONT_PATH_LEN: u32 = 512;

/// Maximum faces held open by one font collection (init-time).
pub const MAX_FONT_FACES: u32 = 8;

/// Maximum glyphs cached in the glyph atlas.
pub const MAX_ATLAS_GLYPHS: u32 = 1024;

/// Glyph atlas pixel pool in bytes (8-bit coverage, bump-allocated).
pub const MAX_ATLAS_PIXELS: u32 = 1024 * 1024;

// =============================================================================
// Accessibility Limits
// =============================================================================

/// Maximum accessibility tree elements
pub const MAX_A11Y_ELEMENTS: u32 = 1024;

/// Maximum pending announcements
pub const MAX_A11Y_ANNOUNCEMENTS: u32 = 16;

// =============================================================================
// Widget Limits
// =============================================================================

/// Maximum concurrent widgets
pub const MAX_WIDGETS: u32 = 256;

/// Maximum deferred commands per frame
pub const MAX_DEFERRED_COMMANDS: u32 = 32;

// =============================================================================
// Window Limits
// =============================================================================

/// Maximum windows per application
pub const MAX_WINDOWS: u32 = 8;

// =============================================================================
// Per-Path Geometry Limits
// =============================================================================

/// Maximum vertices per individual path.
/// Constrains PathMesh size to ~14KB to avoid stack overflow.
/// Source: triangulator.zig, path_mesh.zig
pub const MAX_PATH_VERTICES: u32 = 512;

/// Maximum triangles per path = MAX_PATH_VERTICES - 2 (simple polygon)
pub const MAX_PATH_TRIANGLES: u32 = MAX_PATH_VERTICES - 2;

/// Maximum indices per path = triangles × 3
pub const MAX_PATH_INDICES: u32 = MAX_PATH_TRIANGLES * 3;

/// Maximum path commands per path
pub const MAX_PATH_COMMANDS: u32 = 2048;

/// Maximum data floats per path (commands like cubicTo need 6 floats)
pub const MAX_PATH_DATA: u32 = MAX_PATH_COMMANDS * 8;

/// Maximum subpaths (each moveTo starts a new subpath)
pub const MAX_SUBPATHS: u32 = 64;

// =============================================================================
// Stroke Limits
// =============================================================================

/// Maximum input points for stroke expansion
pub const MAX_STROKE_INPUT: u32 = 512;

/// Maximum output points for stroke expansion.
/// Kept small to avoid stack overflow (ExpandedStroke ~8KB at 1024 points).
/// For UI strokes, 1024 points is plenty (circles flatten to ~64 points).
pub const MAX_STROKE_OUTPUT: u32 = 1024;

/// Number of segments for round caps/joins (affects smoothness)
pub const ROUND_SEGMENTS: u32 = 8;

/// Maximum triangles for direct stroke triangulation
pub const MAX_STROKE_TRIANGLES: u32 = MAX_STROKE_OUTPUT;

/// Maximum indices for stroke triangulation (3 per triangle)
pub const MAX_STROKE_INDICES: u32 = MAX_STROKE_TRIANGLES * 3;

// =============================================================================
// Mesh Pool Limits
// =============================================================================

/// Maximum persistent meshes (cached across frames: icons, static shapes)
/// Source: mesh_pool.zig
pub const MAX_PERSISTENT_MESHES: u32 = 512;

/// Maximum per-frame meshes (dynamic paths, animations, canvas callbacks)
/// Source: mesh_pool.zig
pub const MAX_FRAME_MESHES: u32 = 256;

// =============================================================================
// GPU Buffer Limits (Web/WGPU specific)
// =============================================================================

/// Web renderer batch buffer capacity for vertices (holds multiple paths)
/// Note: This is LARGER than MAX_PATH_VERTICES because it's a batch buffer
pub const WEB_BATCH_VERTICES: u32 = 16384;

/// Web renderer batch buffer capacity for indices
pub const WEB_BATCH_INDICES: u32 = 49152;

/// Web renderer maximum paths per batch
pub const WEB_MAX_PATHS_PER_BATCH: u32 = 256;

// =============================================================================
// Shader Constants
// =============================================================================

/// Maximum gradient color stops (must match GPU shader definitions)
pub const MAX_GRADIENT_STOPS: u32 = 16;

/// Epsilon for gradient range comparisons (avoids division by zero)
/// Used in both Metal and WGSL shaders for consistency
pub const GRADIENT_RANGE_EPSILON: f32 = 0.0001;

// =============================================================================
// Memory Budget Estimates
// =============================================================================

/// Estimated memory for glyph instances (for capacity planning)
pub const GLYPH_INSTANCE_SIZE: u32 = 48; // bytes per GlyphInstance
pub const ESTIMATED_GLYPH_MEMORY: u32 = MAX_GLYPHS_PER_FRAME * GLYPH_INSTANCE_SIZE;

/// Estimated memory for quads
pub const QUAD_SIZE: u32 = 128; // bytes per Quad (with all fields)
pub const ESTIMATED_QUAD_MEMORY: u32 = MAX_QUADS_PER_FRAME * QUAD_SIZE; // 8MB at 65536 quads

/// Per-path memory (at MAX_PATH_VERTICES=512):
///   - PathMesh: ~14KB (512 vertices × 16B + 1530 indices × 4B)
pub const ESTIMATED_PATH_MESH_SIZE: u32 = MAX_PATH_VERTICES * 16 + MAX_PATH_INDICES * 4;

/// Mesh pool memory estimates
pub const ESTIMATED_PERSISTENT_MESH_MEMORY: u32 = MAX_PERSISTENT_MESHES * ESTIMATED_PATH_MESH_SIZE;
pub const ESTIMATED_FRAME_MESH_MEMORY: u32 = MAX_FRAME_MESHES * ESTIMATED_PATH_MESH_SIZE;

// =============================================================================
// ZUI Additions (not in Gooey upstream)
// =============================================================================

/// Maximum input events queued per frame. Backends drop (and count) beyond
/// this instead of growing, mirroring SDL's fixed queue sizing.
pub const MAX_EVENTS_PER_FRAME: u32 = 256;

// =============================================================================
// GPU Resource Limits (`gpu/device.zig` fixed handle pools)
// =============================================================================

/// Maximum GPU buffers alive at once (vertex/index/indirect/storage).
pub const MAX_GPU_BUFFERS: u32 = 1024;

/// Maximum GPU transfer (staging) buffers alive at once.
pub const MAX_GPU_TRANSFER_BUFFERS: u32 = 256;

/// Maximum GPU textures alive at once (includes swapchain images acquired
/// per frame, which are driver-owned and never enter this pool).
pub const MAX_GPU_TEXTURES: u32 = 1024;

/// Maximum GPU samplers alive at once.
pub const MAX_GPU_SAMPLERS: u32 = 256;

/// Maximum compiled shaders alive at once.
pub const MAX_GPU_SHADERS: u32 = 256;

/// Maximum graphics pipelines alive at once.
pub const MAX_GPU_GRAPHICS_PIPELINES: u32 = 256;

/// Maximum compute pipelines alive at once.
pub const MAX_GPU_COMPUTE_PIPELINES: u32 = 128;

/// Maximum fences alive at once. Must cover frames in flight plus readbacks.
pub const MAX_GPU_FENCES: u32 = 256;

/// Maximum frames a device may keep in flight (SDL default is 2; 3 allows
/// triple-buffered present modes).
pub const MAX_GPU_FRAMES_IN_FLIGHT: u32 = 3;

/// Maximum color targets in one render pass (matches SDL_gpu).
pub const MAX_GPU_COLOR_TARGETS: u32 = 4;

/// Maximum vertex buffer slots bound in one draw.
pub const MAX_GPU_VERTEX_BUFFER_SLOTS: u32 = 16;

/// Maximum bytes pushed as uniforms in one call (drivers stage these into
/// a ring buffer; large constants belong in storage buffers instead).
pub const MAX_GPU_UNIFORM_PUSH_BYTES: u32 = 4096;

/// Maximum clipboard UTF-8 bytes kept by the null backend (real backends
/// stream through the OS; this only bounds headless copy/paste tests).
pub const MAX_CLIPBOARD_BYTES: u32 = 65536;

/// Maximum keymap bindings per window (single chords and sequences).
pub const MAX_KEYMAP_BINDINGS: u32 = 64;

/// Maximum predicate nodes per binding (fits u8 child indices).
pub const MAX_KEYMAP_PREDICATE_NODES: u32 = 24;

/// Maximum entries per keymap context frame.
pub const MAX_KEYMAP_CONTEXT_ENTRIES: u32 = 8;
/// Scratch bytes the null/software devices expose for transfer-buffer
/// mapping tests. Real drivers map real staging memory instead.
pub const NULL_DEVICE_MAP_BYTES: u32 = 65536;

// =============================================================================
// Image Limits
// =============================================================================

/// Maximum decoded image dimension (width or height) in pixels.
pub const MAX_IMAGE_DIMENSION: u32 = 4096;

/// Maximum decoded image pixels (w*h); bounds single-image CPU/RAM cost.
pub const MAX_IMAGE_PIXELS: u32 = 2048 * 2048;

/// Decoded RGBA8 pool bytes owned by the App image cache (bump-allocated).
/// Measured working set (2026-09-17): the shadcn-zui charts gallery holds
/// ~8.4MB of rasterized chart/icon SVGs at 1400px width, so 8MB left the
/// trailing sections silently blank (ImageCacheFull is swallowed by the
/// painter). 16MB restores ~2x headroom; revisit if pages grow further.
pub const MAX_IMAGE_POOL_BYTES: u32 = 16 * 1024 * 1024;

/// Maximum cached images (pool entries) at once.
pub const MAX_CACHED_IMAGES: u32 = 64;

/// Maximum image blits per frame (rectangles referencing pool bytes).
pub const MAX_IMAGE_BLITS_PER_FRAME: u32 = 64;

/// Maximum SVG source bytes parsed in one go (cold path).
pub const MAX_SVG_BYTES: u32 = 1024 * 1024;

// =============================================================================
// Compile-time Validation
// =============================================================================

comptime {
    // Sanity checks - fail compilation if limits are unreasonable
    std.debug.assert(MAX_GLYPHS_PER_FRAME >= MAX_GLYPHS_PER_RUN);
    std.debug.assert(MAX_NESTED_COMPONENTS <= 256); // Stack safety
    std.debug.assert(MAX_CLIP_STACK_DEPTH <= 64); // Reasonable nesting

    // Ensure web batch can hold at least a few max-size paths
    std.debug.assert(WEB_BATCH_VERTICES >= MAX_PATH_VERTICES * 4);
    std.debug.assert(WEB_BATCH_INDICES >= MAX_PATH_INDICES * 4);

    // Ensure frame mesh limit doesn't exceed persistent limit
    // (persistent is the "premium" tier, should have more capacity)
    std.debug.assert(MAX_FRAME_MESHES <= MAX_PERSISTENT_MESHES);

    // Ensure per-frame instance limit is reasonable
    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);

    // The ordered command stream must cover a glyph-only frame: every
    // payload push records one command, so a command cap below the glyph
    // cap would silently re-bind glyph-heavy frames (gap report §3).
    std.debug.assert(MAX_RENDER_COMMANDS >= MAX_SCENE_GLYPHS);
    std.debug.assert(MAX_PATH_INDICES == MAX_PATH_TRIANGLES * 3);

    // GPU pools stay balanced: fences must cover in-flight frames with
    // headroom for readbacks, and every pool holds at least one entry.
    std.debug.assert(MAX_GPU_FENCES >= MAX_GPU_FRAMES_IN_FLIGHT * 2);
    std.debug.assert(MAX_GPU_COLOR_TARGETS >= 1);
    std.debug.assert(MAX_GPU_COLOR_TARGETS <= 4);
    std.debug.assert(MAX_GPU_BUFFERS >= 1);
    std.debug.assert(MAX_GPU_TEXTURES >= 1);
    std.debug.assert(NULL_DEVICE_MAP_BYTES >= 4096);

    // Stroke limits are self-consistent
    std.debug.assert(MAX_STROKE_OUTPUT >= MAX_STROKE_INPUT);
    std.debug.assert(MAX_STROKE_TRIANGLES == MAX_STROKE_OUTPUT);
    std.debug.assert(MAX_STROKE_INDICES == MAX_STROKE_TRIANGLES * 3);
    std.debug.assert(ROUND_SEGMENTS >= 4); // Minimum for visual smoothness
}

// =============================================================================
// Tests
// =============================================================================

test "limit relationships" {
    // Indices are derived from vertices correctly
    try std.testing.expectEqual(MAX_PATH_TRIANGLES, MAX_PATH_VERTICES - 2);
    try std.testing.expectEqual(MAX_PATH_INDICES, MAX_PATH_TRIANGLES * 3);

    // Web batch can hold multiple paths
    const paths_per_batch = WEB_BATCH_VERTICES / MAX_PATH_VERTICES;
    try std.testing.expect(paths_per_batch >= 4);
}

test "memory estimates are reasonable" {
    // Glyph memory should be under 4MB
    try std.testing.expect(ESTIMATED_GLYPH_MEMORY < 4 * 1024 * 1024);

    // Quad memory should be under 16MB
    try std.testing.expect(ESTIMATED_QUAD_MEMORY < 16 * 1024 * 1024);

    // Total mesh pool memory should be under 16MB
    const total_mesh_memory = ESTIMATED_PERSISTENT_MESH_MEMORY + ESTIMATED_FRAME_MESH_MEMORY;
    try std.testing.expect(total_mesh_memory < 16 * 1024 * 1024);
}
