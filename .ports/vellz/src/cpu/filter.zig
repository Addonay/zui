//! Port of vello_cpu src/filter/{mod,context,flood,gaussian_blur,drop_shadow,
//! offset,shift}.rs (Apache-2.0 OR MIT).
//!
//! Filter effects for the CPU renderer: `FilterContext`/`ScratchBuffer` hold
//! the rendered filter-layer pixmaps and reusable scratch buffers, and
//! `filterLowp`/`filterHighp` dispatch a `PreparedFilter` to the concrete
//! algorithm. Upstream keeps one Rust file per primitive with a `FilterEffect`
//! trait; Zig has no methods outside the declaring file, so this port keeps
//! the algorithms as free functions in one module (the trait's two `execute_*`
//! methods map to `filterLowp`/`filterHighp`).
//!
//! Divergences from upstream (all forced by Zig's explicit-error policy):
//! * `FilterContext.init`/`setLayer` and every algorithm return
//!   `error.OutOfMemory` where upstream relies on the global allocator
//!   panicking. `getScratchBuffer` grows the scratch pixmap lazily.
//! * `filterLayer` returns a cloned `Shared(Pixmap)` handle (upstream clones
//!   the `Arc<Pixmap>`); the caller owns it and releases it with the passed
//!   allocator.
//! * `filterHighp` currently aliases the lowp implementation exactly like
//!   upstream's `execute_highp`, which delegates to `execute_lowp` for the
//!   gaussian blur and drop shadow ("TODO: Currently only lowp is implemented
//!   and used for highp as well").
//! * Kernel evaluation uses `@exp` instead of Rust's `E.powf` (libm `powf`);
//!   see `common/filter.zig`.
//!
//! Ownership/allocator note: `FilterContext` owns its layer pixmaps (one
//! `Shared` handle per layer) and the scratch pixmap; `deinit` releases both.
//! Every function that can allocate takes the allocator explicitly.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const common_filter = @import("../common/filter.zig");
const filter_effects = @import("../common/filter_effects.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const shared_mod = @import("../common/shared.zig");

const Affine = kurbo.Affine;
const EdgeMode = filter_effects.EdgeMode;
const Filter = filter_effects.Filter;
const Pixmap = pixmap_mod.Pixmap;
const PremulRgba8 = peniko.PremulRgba8;
const Shared = shared_mod.Shared;
const Srgb = peniko.Srgb;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// The rendered pixmaps of the filter layers of one scene, plus reusable
/// scratch storage (upstream `FilterContext`).
pub const FilterContext = struct {
    /// The rendered pixmaps for each filter layer (`None` until rendered).
    layers: std.ArrayList(?Shared(Pixmap)) = .empty,
    /// Reusable scratch buffer for filter application.
    scratch: ScratchBuffer = .{},

    /// Create a context for `num_layers` recorded layers.
    pub fn init(allocator: std.mem.Allocator, num_layers: usize) std.mem.Allocator.Error!FilterContext {
        var layers = std.ArrayList(?Shared(Pixmap)).empty;
        errdefer layers.deinit(allocator);
        try layers.appendNTimes(allocator, null, num_layers);
        return .{ .layers = layers };
    }

    /// Release every owned filter pixmap and the scratch buffer.
    pub fn deinit(self: *FilterContext, allocator: std.mem.Allocator) void {
        for (self.layers.items) |layer| {
            if (layer) |pixmap| pixmap.release(allocator);
        }
        self.layers.deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = undefined;
    }

    /// Borrow the reusable scratch buffer.
    pub fn scratchBuffer(self: *FilterContext) *ScratchBuffer {
        return &self.scratch;
    }

    /// Store the rendered pixmap of filter layer `id`, taking ownership.
    ///
    /// Upstream grows the layer vector with `resize_with`; this port grows it
    /// first and creates the `Shared` handle afterwards so a failure leaves
    /// the context unchanged.
    pub fn setLayer(
        self: *FilterContext,
        allocator: std.mem.Allocator,
        id: usize,
        pixmap: Pixmap,
    ) std.mem.Allocator.Error!void {
        if (id >= self.layers.items.len) {
            try self.layers.appendNTimes(allocator, null, id + 1 - self.layers.items.len);
        }
        const handle = try Shared(Pixmap).create(allocator, pixmap);
        if (self.layers.items[id]) |old| old.release(allocator);
        self.layers.items[id] = handle;
    }

    /// Resolve a rendered filter layer to an owned pixmap handle, or `null` if
    /// it has not been rendered (upstream `filter_layer`, which clones the
    /// `Arc`).
    pub fn filterLayer(self: *const FilterContext, id: usize) ?Shared(Pixmap) {
        const layer = if (id < self.layers.items.len) self.layers.items[id] else null;
        return (layer orelse return null).clone();
    }
};

/// Reusable scratch buffer for filter application (upstream `ScratchBuffer`).
pub const ScratchBuffer = struct {
    scratch_buffer: ?Pixmap = null,

    /// Release the scratch pixmap.
    pub fn deinit(self: *ScratchBuffer, allocator: std.mem.Allocator) void {
        if (self.scratch_buffer) |*pixmap| pixmap.deinit(allocator);
        self.scratch_buffer = null;
    }

    /// Return a scratch pixmap of at least `width` x `height`.
    ///
    /// The buffer only grows; once it is large enough it is reused as-is
    /// (upstream keeps the stale pixels, which the algorithms overwrite).
    pub fn getScratchBuffer(
        self: *ScratchBuffer,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) std.mem.Allocator.Error!*Pixmap {
        if (self.scratch_buffer) |*buffer| {
            if (buffer.width < width or buffer.height < height) {
                try buffer.resize(allocator, width, height);
            }
            return buffer;
        }
        self.scratch_buffer = try Pixmap.init(allocator, width, height);
        return &self.scratch_buffer.?;
    }
};

// ---------------------------------------------------------------------------
// Dispatch (upstream `filter_lowp` / `filter_highp`)
// ---------------------------------------------------------------------------

/// Apply a filter to a layer, preparing a single-primitive filter graph first
/// (upstream `filter_lowp`).
///
/// Returns `error.Unsupported` for multi-primitive graphs and primitives that
/// are not ported yet; see `common.filter.PreparedFilter.new`.
pub fn filterLowp(
    allocator: std.mem.Allocator,
    filter: *const Filter,
    pixmap: *Pixmap,
    scratch: *ScratchBuffer,
    transform: Affine,
) !void {
    const prepared = try common_filter.PreparedFilter.new(filter, transform);
    switch (prepared) {
        .flood => |flood| try floodExecute(allocator, flood, pixmap),
        .gaussian_blur => |blur| try gaussianBlurExecute(allocator, blur, pixmap, scratch),
        .offset => |offset| offsetPixels(pixmap, offset.dx, offset.dy),
        .drop_shadow => |shadow| try dropShadowExecute(allocator, shadow, pixmap, scratch),
    }
}

/// Apply a filter using the high-precision pipeline.
///
/// Upstream's `execute_highp` currently delegates to the lowp implementation
/// (`TODO: Currently only lowp is implemented and used for highp as well`), so
/// this port does the same.
pub fn filterHighp(
    allocator: std.mem.Allocator,
    filter: *const Filter,
    pixmap: *Pixmap,
    scratch: *ScratchBuffer,
    transform: Affine,
) !void {
    return filterLowp(allocator, filter, pixmap, scratch, transform);
}

// ---------------------------------------------------------------------------
// Flood (upstream `filter/flood.rs`)
// ---------------------------------------------------------------------------

/// Fill the whole pixmap with the flood color (upstream `execute_*`).
pub fn floodExecute(
    allocator: std.mem.Allocator,
    flood: common_filter.Flood,
    pixmap: *Pixmap,
) std.mem.Allocator.Error!void {
    _ = allocator;
    const pixel = flood.color.premultiply().toRgba8();
    @memset(pixmap.dataMut(), pixel);
}

// ---------------------------------------------------------------------------
// Shift (upstream `filter/shift.rs`)
// ---------------------------------------------------------------------------

/// Shift all pixels in a pixmap by the given offset.
///
/// This implements the offset operation in-place by copying pixels to their
/// new positions. The iteration order is chosen based on the shift direction
/// to avoid overwriting source pixels before they are read. Areas that become
/// exposed (due to the shift) are filled with transparent black; pixels that
/// would move outside the bounds are discarded.
pub fn offsetPixels(pixmap: *Pixmap, dx: f32, dy: f32) void {
    // Rust: `dx.round() as i32` (round half away from zero, saturating cast).
    const dx_pixels: i32 = std.math.lossyCast(i32, @round(dx));
    const dy_pixels: i32 = std.math.lossyCast(i32, @round(dy));

    // Early return if no offset.
    if (dx_pixels == 0 and dy_pixels == 0) return;

    const width = pixmap.width;
    const height = pixmap.height;
    const transparent = PremulRgba8.fromU32(0);

    // Process pixels in the correct order to avoid overwriting source data:
    // iterate away from the direction of movement.
    if (dx_pixels >= 0 and dy_pixels >= 0) {
        // Shift right+down: iterate bottom-to-top, right-to-left.
        var y: u16 = height;
        while (y > 0) {
            y -= 1;
            var x: u16 = width;
            while (x > 0) {
                x -= 1;
                processOffsetPixel(pixmap, x, y, dx_pixels, dy_pixels, width, height, transparent);
            }
        }
    } else if (dx_pixels >= 0 and dy_pixels < 0) {
        // Shift right+up: iterate top-to-bottom, right-to-left.
        for (0..height) |y| {
            var x: u16 = width;
            while (x > 0) {
                x -= 1;
                processOffsetPixel(pixmap, x, @intCast(y), dx_pixels, dy_pixels, width, height, transparent);
            }
        }
    } else if (dx_pixels < 0 and dy_pixels >= 0) {
        // Shift left+down: iterate bottom-to-top, left-to-right.
        var y: u16 = height;
        while (y > 0) {
            y -= 1;
            for (0..width) |x| {
                processOffsetPixel(pixmap, @intCast(x), y, dx_pixels, dy_pixels, width, height, transparent);
            }
        }
    } else {
        // Shift left+up: iterate top-to-bottom, left-to-right.
        for (0..height) |y| {
            for (0..width) |x| {
                processOffsetPixel(pixmap, @intCast(x), @intCast(y), dx_pixels, dy_pixels, width, height, transparent);
            }
        }
    }
}

/// Rust's `i32 as u16` cast, which truncates (used by the upstream
/// `should_clear` conditions for out-of-range offsets).
fn truncateI32ToU16(value: i32) u16 {
    return @truncate(@as(u32, @bitCast(value)));
}

/// Move one pixel during the offset operation and clear the source position
/// when it lies in the exposed region.
inline fn processOffsetPixel(
    pixmap: *Pixmap,
    x: u16,
    y: u16,
    dx_pixels: i32,
    dy_pixels: i32,
    width: u16,
    height: u16,
    transparent: PremulRgba8,
) void {
    const new_x = @as(i32, x) + dx_pixels;
    const new_y = @as(i32, y) + dy_pixels;

    if (new_x >= 0 and new_x < @as(i32, width) and new_y >= 0 and new_y < @as(i32, height)) {
        const pixel = pixmap.sample(x, y);
        pixmap.setPixel(@intCast(new_x), @intCast(new_y), pixel);
    }

    // Clear the source pixel if it is in the exposed region.
    const should_clear = (dx_pixels > 0 and x < truncateI32ToU16(dx_pixels)) or
        (dx_pixels < 0 and x >= truncateI32ToU16(@as(i32, width) + dx_pixels)) or
        (dy_pixels > 0 and y < truncateI32ToU16(dy_pixels)) or
        (dy_pixels < 0 and y >= truncateI32ToU16(@as(i32, height) + dy_pixels));

    if (should_clear) {
        pixmap.setPixel(x, y, transparent);
    }
}

// ---------------------------------------------------------------------------
// Gaussian blur (upstream `filter/gaussian_blur.rs`)
// ---------------------------------------------------------------------------

/// Run a prepared gaussian blur (upstream `execute_lowp`).
pub fn gaussianBlurExecute(
    allocator: std.mem.Allocator,
    blur: common_filter.GaussianBlur,
    pixmap: *Pixmap,
    filter_scratch: *ScratchBuffer,
) std.mem.Allocator.Error!void {
    // No blur if std_deviation is zero or negative.
    if (blur.std_deviation <= 0.0) return;

    const scratch = try filter_scratch.getScratchBuffer(allocator, pixmap.width, pixmap.height);
    applyBlur(
        pixmap,
        scratch,
        blur.n_decimations,
        blur.kernel[0..blur.kernel_size],
        blur.edge_mode,
    );
}

/// Apply Gaussian blur using multi-scale decimation and upsampling.
///
/// The `scratch` buffer is used for separable convolution and must be at least
/// as large as the source pixmap.
pub fn applyBlur(
    pixmap: *Pixmap,
    scratch: *Pixmap,
    n_decimations: usize,
    kernel: []const f32,
    edge_mode: EdgeMode,
) void {
    const radius: u8 = @intCast(kernel.len / 2);
    const width = pixmap.width;
    const height = pixmap.height;

    // Small blur: apply direct convolution at full resolution.
    if (n_decimations == 0) {
        convolve(pixmap, scratch, width, height, kernel, radius, edge_mode);
        return;
    }

    // Track logical dimensions through decimation (the physical buffer stays
    // the same size).
    var sizer = common_filter.DecimationSizer.init(width, height);

    // Downsample n times (each step reduces resolution by 2x).
    for (0..n_decimations) |_| {
        const current_w = sizer.width;
        const current_h = sizer.height;
        _ = downscale(pixmap, current_w, current_h, edge_mode);
        _ = sizer.downscale();
    }

    // Apply the reduced blur at the coarsest resolution.
    const coarse_w = sizer.width;
    const coarse_h = sizer.height;
    convolve(pixmap, scratch, coarse_w, coarse_h, kernel, radius, edge_mode);

    // Upsample back to the original resolution (each step doubles it).
    for (0..n_decimations) |_| {
        const current_w = sizer.width;
        const current_h = sizer.height;
        _ = upscale(pixmap, current_w, current_h, edge_mode);
        _ = sizer.upscale();
    }

    std.debug.assert(sizer.width == width and sizer.height == height);
}

/// Apply separable gaussian convolution with logical dimensions.
pub fn convolve(
    src: *Pixmap,
    scratch: *Pixmap,
    width: u16,
    height: u16,
    kernel: []const f32,
    radius: u8,
    edge_mode: EdgeMode,
) void {
    convolveX(src, scratch, width, height, kernel, radius, edge_mode);
    convolveY(scratch, src, width, height, kernel, radius, edge_mode);
}

/// Horizontal blur pass (1D convolution along the x-axis).
pub fn convolveX(
    src: *const Pixmap,
    dst: *Pixmap,
    src_width: u16,
    src_height: u16,
    kernel: []const f32,
    radius: u8,
    edge_mode: EdgeMode,
) void {
    for (0..src_height) |y| {
        for (0..src_width) |x| {
            var rgba = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

            for (kernel, 0..) |k, j| {
                const src_x = @as(i32, @intCast(x)) + @as(i32, @intCast(j)) - @as(i32, radius);
                const p = sampleX(src, src_x, @intCast(y), src_width, edge_mode);

                rgba[0] += @as(f32, @floatFromInt(p.r)) * k;
                rgba[1] += @as(f32, @floatFromInt(p.g)) * k;
                rgba[2] += @as(f32, @floatFromInt(p.b)) * k;
                rgba[3] += @as(f32, @floatFromInt(p.a)) * k;
            }

            dst.setPixel(@intCast(x), @intCast(y), .{
                .r = roundToU8(rgba[0]),
                .g = roundToU8(rgba[1]),
                .b = roundToU8(rgba[2]),
                .a = roundToU8(rgba[3]),
            });
        }
    }
}

/// Vertical blur pass (1D convolution along the y-axis).
pub fn convolveY(
    src: *const Pixmap,
    dst: *Pixmap,
    src_width: u16,
    src_height: u16,
    kernel: []const f32,
    radius: u8,
    edge_mode: EdgeMode,
) void {
    for (0..src_height) |y| {
        for (0..src_width) |x| {
            var rgba = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

            for (kernel, 0..) |k, j| {
                const src_y = @as(i32, @intCast(y)) + @as(i32, @intCast(j)) - @as(i32, radius);
                const p = sampleY(src, @intCast(x), src_y, src_height, edge_mode);

                rgba[0] += @as(f32, @floatFromInt(p.r)) * k;
                rgba[1] += @as(f32, @floatFromInt(p.g)) * k;
                rgba[2] += @as(f32, @floatFromInt(p.b)) * k;
                rgba[3] += @as(f32, @floatFromInt(p.a)) * k;
            }

            dst.setPixel(@intCast(x), @intCast(y), .{
                .r = roundToU8(rgba[0]),
                .g = roundToU8(rgba[1]),
                .b = roundToU8(rgba[2]),
                .a = roundToU8(rgba[3]),
            });
        }
    }
}

fn divCeil2(value: u16) u16 {
    if (value % 2 == 0) return value / 2;
    return value / 2 + 1;
}

/// Downsample an image by 2x using a separable [1,3,3,1]/8 binomial filter.
pub fn downscale(
    src: *Pixmap,
    src_width: u16,
    src_height: u16,
    edge_mode: EdgeMode,
) [2]u16 {
    const dst_width = divCeil2(src_width);
    const dst_height = divCeil2(src_height);
    downscaleX(src, src_width, src_height, dst_width, edge_mode);
    // `dst_width` replaces `src_width` here because the image was already
    // decimated horizontally.
    downscaleY(src, dst_width, src_height, dst_height, edge_mode);
    return .{ dst_width, dst_height };
}

/// Horizontal decimation pass using a [1,3,3,1]/8 filter.
fn downscaleX(
    src: *Pixmap,
    src_width: u16,
    src_height: u16,
    dst_width: u16,
    edge_mode: EdgeMode,
) void {
    for (0..src_height) |y| {
        // Sliding window: two previous pixels plus the two current ones.
        var p0 = sampleX(src, -1, @intCast(y), src_width, edge_mode);
        var p1 = sampleX(src, 0, @intCast(y), src_width, edge_mode);

        for (0..dst_width) |x| {
            // Sample 4 horizontally adjacent pixels: [x*2-1 .. x*2+2].
            const src_x: i32 = @intCast(x * 2);
            const p2 = sampleX(src, src_x + 1, @intCast(y), src_width, edge_mode);
            const p3 = sampleX(src, src_x + 2, @intCast(y), src_width, edge_mode);

            // (p0 + 3*p1 + 3*p2 + p3) / 8.
            src.setPixel(@intCast(x), @intCast(y), decimateWeighted(p0, p1, p2, p3));

            // Advance the window: previous p2/p3 become next p0/p1.
            p0 = p2;
            p1 = p3;
        }
    }
}

/// Vertical decimation pass using a [1,3,3,1]/8 filter.
fn downscaleY(
    src: *Pixmap,
    src_width: u16,
    src_height: u16,
    dst_height: u16,
    edge_mode: EdgeMode,
) void {
    for (0..src_width) |x| {
        // Sliding window: two previous pixels plus the two current ones.
        var p0 = sampleY(src, @intCast(x), -1, src_height, edge_mode);
        var p1 = sampleY(src, @intCast(x), 0, src_height, edge_mode);

        for (0..dst_height) |y| {
            // Sample 4 vertically adjacent pixels: [y*2-1 .. y*2+2].
            const src_y: i32 = @intCast(y * 2);
            const p2 = sampleY(src, @intCast(x), src_y + 1, src_height, edge_mode);
            const p3 = sampleY(src, @intCast(x), src_y + 2, src_height, edge_mode);

            src.setPixel(@intCast(x), @intCast(y), decimateWeighted(p0, p1, p2, p3));

            p0 = p2;
            p1 = p3;
        }
    }
}

/// Upsample a pixmap by 2x using phase-aligned [0.75, 0.25] interpolation.
pub fn upscale(
    src: *Pixmap,
    src_width: u16,
    src_height: u16,
    edge_mode: EdgeMode,
) [2]u16 {
    const dst_width = src_width * 2;
    const dst_height = src_height * 2;
    upscaleX(src, src_width, src_height, edge_mode);
    upscaleY(src, dst_width, src_height, edge_mode);
    return .{ dst_width, dst_height };
}

/// Horizontal upsampling pass using [0.75, 0.25] interpolation.
///
/// Operates in place by processing backwards to avoid overwriting source data.
fn upscaleX(src: *Pixmap, src_width: u16, src_height: u16, edge_mode: EdgeMode) void {
    for (0..src_height) |y| {
        // Sliding window of three pixels: prev, current, next.
        var p0 = sampleX(src, @intCast(src_width), @intCast(y), src_width, edge_mode);
        var p1 = sampleX(src, @as(i32, @intCast(src_width)) - 1, @intCast(y), src_width, edge_mode);

        var x: u16 = src_width;
        while (x > 0) {
            x -= 1;
            const src_x: i32 = @intCast(x);
            const p2 = sampleX(src, src_x - 1, @intCast(y), src_width, edge_mode);

            // output[2x]   = 0.25*p2 + 0.75*p1
            // output[2x+1] = 0.75*p1 + 0.25*p0
            const dst_x = x * 2;
            src.setPixel(dst_x, @intCast(y), interpolate25_75(p2, p1));
            src.setPixel(dst_x + 1, @intCast(y), interpolate75_25(p1, p0));

            p0 = p1;
            p1 = p2;
        }
    }
}

/// Vertical upsampling pass using [0.75, 0.25] interpolation.
///
/// Operates in place by processing backwards to avoid overwriting source data.
fn upscaleY(src: *Pixmap, src_width: u16, src_height: u16, edge_mode: EdgeMode) void {
    for (0..src_width) |x| {
        // Sliding window of three pixels: prev, current, next.
        var p0 = sampleY(src, @intCast(x), @intCast(src_height), src_height, edge_mode);
        var p1 = sampleY(src, @intCast(x), @as(i32, @intCast(src_height)) - 1, src_height, edge_mode);

        var y: u16 = src_height;
        while (y > 0) {
            y -= 1;
            const src_y: i32 = @intCast(y);
            const p2 = sampleY(src, @intCast(x), src_y - 1, src_height, edge_mode);

            // output[2y]   = 0.25*p2 + 0.75*p1
            // output[2y+1] = 0.75*p1 + 0.25*p0
            const dst_y = y * 2;
            src.setPixel(@intCast(x), dst_y, interpolate25_75(p2, p1));
            src.setPixel(@intCast(x), dst_y + 1, interpolate75_25(p1, p0));

            p0 = p1;
            p1 = p2;
        }
    }
}

/// Transparent black pixel constant.
const TRANSPARENT_BLACK = PremulRgba8{ .r = 0, .g = 0, .b = 0, .a = 0 };

/// Sample a pixel with edge-mode handling for horizontal sampling.
inline fn sampleX(src: *const Pixmap, x: i32, y: u16, width: u16, edge_mode: EdgeMode) PremulRgba8 {
    if (edge_mode == .none and (x < 0 or x >= width)) return TRANSPARENT_BLACK;
    return src.sample(extend(x, width, edge_mode), y);
}

/// Sample a pixel with edge-mode handling for vertical sampling.
inline fn sampleY(src: *const Pixmap, x: u16, y: i32, height: u16, edge_mode: EdgeMode) PremulRgba8 {
    if (edge_mode == .none and (y < 0 or y >= height)) return TRANSPARENT_BLACK;
    return src.sample(x, extend(y, height, edge_mode));
}

/// Extend a coordinate beyond image boundaries according to the edge mode.
fn extend(coord: i32, size: u16, edge_mode: EdgeMode) u16 {
    const size_i32: i32 = @intCast(size);
    switch (edge_mode) {
        .duplicate => {
            // Clamp to the image bounds: pixels outside use the nearest edge.
            return @intCast(std.math.clamp(coord, 0, size_i32 - 1));
        },
        .none => {
            // The coordinate is already validated as in-bounds by the caller.
            return @intCast(coord);
        },
        .wrap => {
            var c = @rem(coord, size_i32);
            if (c < 0) c += size_i32;
            return @intCast(c);
        },
        .mirror => {
            const period = size_i32 * 2;
            var c = @rem(coord, period);
            if (c < 0) c += period;
            if (c >= size_i32) c = period - c - 1;
            return @intCast(c);
        },
    }
}

/// Blend 4 RGBA pixels using [1,3,3,1]/8 binomial weights.
inline fn decimateWeighted(
    p0: PremulRgba8,
    p1: PremulRgba8,
    p2: PremulRgba8,
    p3: PremulRgba8,
) PremulRgba8 {
    return .{
        .r = weighted8(p0.r, p1.r, p2.r, p3.r),
        .g = weighted8(p0.g, p1.g, p2.g, p3.g),
        .b = weighted8(p0.b, p1.b, p2.b, p3.b),
        .a = weighted8(p0.a, p1.a, p2.a, p3.a),
    };
}

inline fn weighted8(c0: u8, c1: u8, c2: u8, c3: u8) u8 {
    const value = @as(u32, c0) + @as(u32, c1) * 3 + @as(u32, c2) * 3 + @as(u32, c3) + 4;
    return @intCast(value >> 3);
}

/// Blend 2 RGBA pixels using [0.25, 0.75] weights (right-weighted).
inline fn interpolate25_75(p0: PremulRgba8, p1: PremulRgba8) PremulRgba8 {
    return .{
        .r = weighted4(p0.r, p1.r),
        .g = weighted4(p0.g, p1.g),
        .b = weighted4(p0.b, p1.b),
        .a = weighted4(p0.a, p1.a),
    };
}

/// Blend 2 RGBA pixels using [0.75, 0.25] weights.
inline fn interpolate75_25(p0: PremulRgba8, p1: PremulRgba8) PremulRgba8 {
    return .{
        .r = weighted4Inverse(p0.r, p1.r),
        .g = weighted4Inverse(p0.g, p1.g),
        .b = weighted4Inverse(p0.b, p1.b),
        .a = weighted4Inverse(p0.a, p1.a),
    };
}

inline fn weighted4(c0: u8, c1: u8) u8 {
    const value = @as(u32, c0) + @as(u32, c1) * 3 + 2;
    return @intCast(value >> 2);
}

inline fn weighted4Inverse(c0: u8, c1: u8) u8 {
    const value = @as(u32, c0) * 3 + @as(u32, c1) + 2;
    return @intCast(value >> 2);
}

/// `f32` -> `u8` with Rust's `round() as u8` semantics (round half away from
/// zero; saturating cast, NaN -> 0).
inline fn roundToU8(value: f32) u8 {
    return std.math.lossyCast(u8, @round(value));
}

// ---------------------------------------------------------------------------
// Drop shadow (upstream `filter/drop_shadow.rs`)
// ---------------------------------------------------------------------------

/// Run a prepared drop shadow (upstream `execute_lowp`).
pub fn dropShadowExecute(
    allocator: std.mem.Allocator,
    shadow: common_filter.DropShadow,
    pixmap: *Pixmap,
    filter_scratch: *ScratchBuffer,
) std.mem.Allocator.Error!void {
    try applyDropShadow(
        allocator,
        pixmap,
        shadow.dx,
        shadow.dy,
        shadow.std_deviation,
        shadow.n_decimations,
        shadow.kernel[0..shadow.kernel_size],
        shadow.color,
        shadow.edge_mode,
        shadow.composite_original,
        filter_scratch,
    );
}

/// Apply the drop shadow effect:
/// 1. Offset the shadow pixels.
/// 2. Blur the already-offset shadow.
/// 3. Apply the shadow color and optionally composite with the original.
fn applyDropShadow(
    allocator: std.mem.Allocator,
    pixmap: *Pixmap,
    dx: f32,
    dy: f32,
    std_deviation: f32,
    n_decimations: usize,
    kernel: []const f32,
    color: peniko.AlphaColor(Srgb),
    edge_mode: EdgeMode,
    composite_original: bool,
    filter_scratch: *ScratchBuffer,
) std.mem.Allocator.Error!void {
    // Clone the pixmap to create the shadow buffer.
    var shadow_pixmap = try clonePixmap(allocator, pixmap);
    defer shadow_pixmap.deinit(allocator);

    // Step 1: offset the shadow pixels.
    offsetPixels(&shadow_pixmap, dx, dy);

    // Step 2: blur the already-offset shadow.
    if (std_deviation > 0.0) {
        const scratch = try filter_scratch.getScratchBuffer(
            allocator,
            shadow_pixmap.width,
            shadow_pixmap.height,
        );
        applyBlur(&shadow_pixmap, scratch, n_decimations, kernel, edge_mode);
    }

    // Step 3: apply the shadow color and optionally composite with the
    // original.
    writeColoredShadow(&shadow_pixmap, pixmap, color, composite_original);
}

/// Clone a pixmap's pixels and transparency hint.
fn clonePixmap(allocator: std.mem.Allocator, src: *const Pixmap) std.mem.Allocator.Error!Pixmap {
    var out = try Pixmap.init(allocator, src.width, src.height);
    errdefer out.deinit(allocator);
    @memcpy(out.dataMut(), src.data());
    out.setMayHaveTransparency(src.mayHaveTransparency());
    return out;
}

/// Apply the shadow color to the blurred alpha and optionally composite the
/// original over it using source-over.
fn writeColoredShadow(
    shadow: *const Pixmap,
    dst: *Pixmap,
    color: peniko.AlphaColor(Srgb),
    composite_original: bool,
) void {
    const width = dst.width;
    const height = dst.height;

    // Precompute the shadow color components.
    const shadow_r = roundToU8(color.components[0] * 255.0);
    const shadow_g = roundToU8(color.components[1] * 255.0);
    const shadow_b = roundToU8(color.components[2] * 255.0);

    for (0..height) |y| {
        for (0..width) |x| {
            // Sample the alpha directly (the shadow is already offset).
            const alpha = shadow.sample(@intCast(x), @intCast(y)).a;

            // Apply the shadow color to the alpha.
            const shadow_alpha = @min(u8ToNorm(alpha) * color.components[3], 1.0);
            const final_alpha = normToU8(shadow_alpha);

            // Premultiply RGB by alpha as required by PremulRgba8.
            const alpha_u16: u16 = final_alpha;
            const colored_shadow = PremulRgba8{
                .r = premultiplyChannel(shadow_r, alpha_u16),
                .g = premultiplyChannel(shadow_g, alpha_u16),
                .b = premultiplyChannel(shadow_b, alpha_u16),
                .a = final_alpha,
            };

            const result = if (composite_original)
                composeSrcOver(dst.sample(@intCast(x), @intCast(y)), colored_shadow)
            else
                colored_shadow;

            dst.setPixel(@intCast(x), @intCast(y), result);
        }
    }
}

inline fn premultiplyChannel(channel: u8, alpha: u16) u8 {
    return @intCast((@as(u16, channel) * alpha) / 255);
}

/// Composite two pixels using Porter-Duff "source over" on premultiplied
/// values: `result = src + dst * (1 - src_alpha)`.
fn composeSrcOver(src: PremulRgba8, dst: PremulRgba8) PremulRgba8 {
    const src_a = u8ToNorm(src.a);
    return .{
        .r = srcOverChannel(src.r, dst.r, src_a),
        .g = srcOverChannel(src.g, dst.g, src_a),
        .b = srcOverChannel(src.b, dst.b, src_a),
        .a = srcOverChannel(src.a, dst.a, src_a),
    };
}

inline fn srcOverChannel(src: u8, dst: u8, src_alpha: f32) u8 {
    const result = u8ToNorm(src) + u8ToNorm(dst) * (1.0 - src_alpha);
    return normToU8(result);
}

/// Convert a u8 color component (0-255) to normalized f32 (0.0-1.0).
inline fn u8ToNorm(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

/// Convert a normalized f32 (0.0-1.0) to a u8 color component (0-255).
inline fn normToU8(value: f32) u8 {
    return std.math.lossyCast(u8, @round(value * 255.0));
}

// ---------------------------------------------------------------------------
// Tests (ports of the upstream `#[cfg(test)]` modules)
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

fn white() PremulRgba8 {
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

test "filter context stores and resolves owned layer pixmaps" {
    const allocator = testing.allocator;

    var ctx = try FilterContext.init(allocator, 2);
    defer ctx.deinit(allocator);

    try testing.expect(ctx.filterLayer(0) == null);
    try testing.expect(ctx.filterLayer(99) == null);

    var pixmap = try Pixmap.init(allocator, 2, 1);
    pixmap.setPixel(0, 0, white());
    try ctx.setLayer(allocator, 0, pixmap);

    const resolved = ctx.filterLayer(0).?;
    defer resolved.release(allocator);
    try testing.expectEqual(@as(u8, 255), resolved.get().sample(0, 0).a);

    // Growing past the initial length also fills the gap with `null`.
    const pixmap3 = try Pixmap.init(allocator, 1, 1);
    try ctx.setLayer(allocator, 3, pixmap3);
    try testing.expect(ctx.filterLayer(1) == null);
    const resolved3 = ctx.filterLayer(3).?;
    resolved3.release(allocator);

    // Replacing a layer releases the previous handle.
    const replacement = try Pixmap.init(allocator, 1, 1);
    try ctx.setLayer(allocator, 0, replacement);
    const replaced = ctx.filterLayer(0).?;
    defer replaced.release(allocator);
    try testing.expectEqual(@as(u8, 0), replaced.get().sample(0, 0).a);
}

test "scratch buffer grows and reuses" {
    const allocator = testing.allocator;

    var scratch = ScratchBuffer{};
    defer scratch.deinit(allocator);

    const first = try scratch.getScratchBuffer(allocator, 2, 2);
    try testing.expectEqual(@as(u16, 2), first.width);
    const first_ptr = first;
    try testing.expectEqual(first_ptr, try scratch.getScratchBuffer(allocator, 1, 1));

    const bigger = try scratch.getScratchBuffer(allocator, 4, 3);
    try testing.expectEqual(@as(u16, 4), bigger.width);
    try testing.expectEqual(@as(u16, 3), bigger.height);
}

// Ported from upstream `filter/shift.rs`.

test "offset pixels positive" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    offsetPixels(&pixmap, 1.0, 1.0);

    try testing.expectEqual(@as(u8, 255), pixmap.sample(2, 2).a);
    try testing.expectEqual(@as(u8, 0), pixmap.sample(1, 1).a);
}

test "offset pixels negative" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(2, 2, white());

    offsetPixels(&pixmap, -1.0, -1.0);

    try testing.expectEqual(@as(u8, 255), pixmap.sample(1, 1).a);
    try testing.expectEqual(@as(u8, 0), pixmap.sample(2, 2).a);
}

test "offset pixels fractional rounds" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    // 0.6 rounds to 1, -0.4 rounds to 0.
    offsetPixels(&pixmap, 0.6, -0.4);
    try testing.expectEqual(@as(u8, 255), pixmap.sample(2, 1).a);
}

test "offset pixels out of bounds clears" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    offsetPixels(&pixmap, 10.0, 10.0);

    for (0..4) |y| {
        for (0..4) |x| {
            try testing.expectEqual(@as(u8, 0), pixmap.sample(@intCast(x), @intCast(y)).a);
        }
    }
}

// Ported from upstream `filter/gaussian_blur.rs`.

test "extend duplicate" {
    try testing.expectEqual(@as(u16, 5), extend(5, 10, .duplicate));
    try testing.expectEqual(@as(u16, 0), extend(-1, 10, .duplicate));
    try testing.expectEqual(@as(u16, 0), extend(-10, 10, .duplicate));
    try testing.expectEqual(@as(u16, 9), extend(10, 10, .duplicate));
    try testing.expectEqual(@as(u16, 9), extend(20, 10, .duplicate));
}

test "extend wrap" {
    try testing.expectEqual(@as(u16, 5), extend(5, 10, .wrap));
    try testing.expectEqual(@as(u16, 0), extend(10, 10, .wrap));
    try testing.expectEqual(@as(u16, 1), extend(11, 10, .wrap));
    try testing.expectEqual(@as(u16, 5), extend(25, 10, .wrap));
    try testing.expectEqual(@as(u16, 9), extend(-1, 10, .wrap));
    try testing.expectEqual(@as(u16, 8), extend(-2, 10, .wrap));
}

test "extend mirror" {
    try testing.expectEqual(@as(u16, 5), extend(5, 10, .mirror));
    try testing.expectEqual(@as(u16, 9), extend(10, 10, .mirror));
    try testing.expectEqual(@as(u16, 8), extend(11, 10, .mirror));
    try testing.expectEqual(@as(u16, 0), extend(19, 10, .mirror));
    try testing.expectEqual(@as(u16, 0), extend(20, 10, .mirror));
    try testing.expectEqual(@as(u16, 0), extend(-1, 10, .mirror));
    try testing.expectEqual(@as(u16, 1), extend(-2, 10, .mirror));
}

test "extend none passes the coordinate through" {
    try testing.expectEqual(@as(u16, 5), extend(5, 10, .none));
    try testing.expectEqual(@as(u16, 10), extend(10, 10, .none));
    try testing.expectEqual(@as(u16, 11), extend(11, 10, .none));
}

test "decimate weighted matches upstream rounding" {
    const p0 = PremulRgba8{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const p1 = PremulRgba8{ .r = 8, .g = 8, .b = 8, .a = 8 };
    const p2 = p1;
    const p3 = p0;

    const result = decimateWeighted(p0, p1, p2, p3);
    try testing.expectEqual(@as(u8, 6), result.r);
    try testing.expectEqual(@as(u8, 6), result.g);
    try testing.expectEqual(@as(u8, 6), result.b);
    try testing.expectEqual(@as(u8, 6), result.a);
}

test "interpolation weights and symmetry" {
    const p0 = PremulRgba8{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const p1 = PremulRgba8{ .r = 100, .g = 100, .b = 100, .a = 100 };
    try testing.expectEqual(@as(u8, 75), interpolate25_75(p0, p1).r);
    try testing.expectEqual(@as(u8, 75), interpolate75_25(p1, p0).r);

    const a = PremulRgba8{ .r = 50, .g = 100, .b = 150, .a = 200 };
    const b = PremulRgba8{ .r = 200, .g = 150, .b = 100, .a = 50 };
    try testing.expectEqual(interpolate25_75(a, b), interpolate75_25(b, a));
}

test "downscale_x non uniform" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 2);
    defer pixmap.deinit(allocator);
    // Row 0: 0, 40, 80, 120; row 1: 20, 60, 100, 140.
    for (0..2) |y| {
        for (0..4) |x| {
            const value: u8 = @intCast(y * 20 + x * 40);
            pixmap.setPixel(@intCast(x), @intCast(y), .{ .r = value, .g = 0, .b = 0, .a = 255 });
        }
    }

    downscaleX(&pixmap, 4, 2, 2, .duplicate);

    // Row 0: (0 + 0*3 + 40*3 + 80 + 4) >> 3 = 25,
    //        (40 + 80*3 + 120*3 + 120 + 4) >> 3 = 95
    // Row 1: (20 + 20*3 + 60*3 + 100 + 4) >> 3 = 45,
    //        (60 + 100*3 + 140*3 + 140 + 4) >> 3 = 115
    try testing.expectEqual(@as(u8, 25), pixmap.sample(0, 0).r);
    try testing.expectEqual(@as(u8, 95), pixmap.sample(1, 0).r);
    try testing.expectEqual(@as(u8, 45), pixmap.sample(0, 1).r);
    try testing.expectEqual(@as(u8, 115), pixmap.sample(1, 1).r);
}

test "downscale_y non uniform" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 4);
    defer pixmap.deinit(allocator);
    const rows = [_][2]u8{ .{ 25, 95 }, .{ 45, 115 }, .{ 35, 105 }, .{ 55, 125 } };
    for (rows, 0..) |row, y| {
        for (row, 0..) |value, x| {
            pixmap.setPixel(@intCast(x), @intCast(y), .{ .r = value, .g = 0, .b = 0, .a = 255 });
        }
    }

    downscaleY(&pixmap, 2, 4, 2, .duplicate);

    // Col 0: (25 + 25*3 + 45*3 + 35 + 4) >> 3 = 34,
    //        (45 + 35*3 + 55*3 + 55 + 4) >> 3 = 46
    // Col 1: (95 + 95*3 + 115*3 + 105 + 4) >> 3 = 104,
    //        (115 + 105*3 + 125*3 + 125 + 4) >> 3 = 116
    try testing.expectEqual(@as(u8, 34), pixmap.sample(0, 0).r);
    try testing.expectEqual(@as(u8, 104), pixmap.sample(1, 0).r);
    try testing.expectEqual(@as(u8, 46), pixmap.sample(0, 1).r);
    try testing.expectEqual(@as(u8, 116), pixmap.sample(1, 1).r);
}

test "upscale_x non uniform" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 2);
    defer pixmap.deinit(allocator);
    const rows = [_][2]u8{ .{ 34, 104 }, .{ 46, 116 } };
    for (rows, 0..) |row, y| {
        for (row, 0..) |value, x| {
            pixmap.setPixel(@intCast(x), @intCast(y), .{ .r = value, .g = 0, .b = 0, .a = 255 });
        }
    }

    upscaleX(&pixmap, 2, 2, .duplicate);

    try testing.expectEqual(@as(u8, 34), pixmap.sample(0, 0).r);
    try testing.expectEqual(@as(u8, 52), pixmap.sample(1, 0).r);
    try testing.expectEqual(@as(u8, 87), pixmap.sample(2, 0).r);
    try testing.expectEqual(@as(u8, 104), pixmap.sample(3, 0).r);
    try testing.expectEqual(@as(u8, 46), pixmap.sample(0, 1).r);
    try testing.expectEqual(@as(u8, 64), pixmap.sample(1, 1).r);
    try testing.expectEqual(@as(u8, 99), pixmap.sample(2, 1).r);
    try testing.expectEqual(@as(u8, 116), pixmap.sample(3, 1).r);
}

test "upscale_y non uniform" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    const rows = [_][4]u8{ .{ 34, 52, 87, 104 }, .{ 46, 64, 99, 116 } };
    for (rows, 0..) |row, y| {
        for (row, 0..) |value, x| {
            pixmap.setPixel(@intCast(x), @intCast(y), .{ .r = value, .g = 0, .b = 0, .a = 255 });
        }
    }

    upscaleY(&pixmap, 4, 2, .duplicate);

    const expected = [_][4]u8{
        .{ 34, 52, 87, 104 },
        .{ 37, 55, 90, 107 },
        .{ 43, 61, 96, 113 },
        .{ 46, 64, 99, 116 },
    };
    for (expected, 0..) |row, y| {
        for (row, 0..) |value, x| {
            try testing.expectEqual(value, pixmap.sample(@intCast(x), @intCast(y)).r);
        }
    }
}

test "convolve preserves uniform colors" {
    const allocator = testing.allocator;
    var src = try Pixmap.init(allocator, 5, 3);
    defer src.deinit(allocator);
    var dst = try Pixmap.init(allocator, 5, 3);
    defer dst.deinit(allocator);
    @memset(src.dataMut(), .{ .r = 128, .g = 128, .b = 128, .a = 255 });

    const kernel = common_filter.computeGaussianKernel(1.0);
    convolveX(
        &src,
        &dst,
        5,
        3,
        kernel.kernel[0..kernel.kernel_size],
        kernel.kernel_size / 2,
        .duplicate,
    );

    for (0..3) |y| {
        for (0..5) |x| {
            try testing.expectEqual(
                PremulRgba8{ .r = 128, .g = 128, .b = 128, .a = 255 },
                dst.sample(@intCast(x), @intCast(y)),
            );
        }
    }
}

test "apply blur with decimation does not panic on small images" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);
    var scratch = try Pixmap.init(allocator, 1, 1);
    defer scratch.deinit(allocator);

    const plan = common_filter.planDecimatedBlur(2.0);
    applyBlur(
        &pixmap,
        &scratch,
        plan.n_decimations,
        plan.kernel[0..plan.kernel_size],
        .none,
    );
}

test "gaussian blur execute fills small sigma identity and skips zero" {
    const allocator = testing.allocator;
    var scratch = ScratchBuffer{};
    defer scratch.deinit(allocator);

    var pixmap = try Pixmap.init(allocator, 3, 3);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    // zero sigma is a no-op
    try gaussianBlurExecute(allocator, common_filter.GaussianBlur.new(0.0, .none), &pixmap, &scratch);
    try testing.expectEqual(@as(u8, 255), pixmap.sample(1, 1).a);

    // 1.0 sigma blurs the single pixel outward
    try gaussianBlurExecute(allocator, common_filter.GaussianBlur.new(1.0, .duplicate), &pixmap, &scratch);
    try testing.expect(pixmap.sample(0, 0).a > 0);
    try testing.expect(pixmap.sample(1, 1).a < 255);
}

// Ported from upstream `filter/flood.rs`.

test "flood semi transparent premultiplies" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    var scratch = ScratchBuffer{};
    defer scratch.deinit(allocator);

    const color = peniko.Color.fromRgba8(255, 255, 255, 128);
    try floodExecute(allocator, common_filter.Flood.new(color), &pixmap);
    for (0..2) |y| {
        for (0..2) |x| {
            const pixel = pixmap.sample(@intCast(x), @intCast(y));
            try testing.expectEqual(@as(u8, 128), pixel.r);
            try testing.expectEqual(@as(u8, 128), pixel.g);
            try testing.expectEqual(@as(u8, 128), pixel.b);
            try testing.expectEqual(@as(u8, 128), pixel.a);
        }
    }
}

// Ported from upstream `filter/drop_shadow.rs`.

test "norm conversions round trip" {
    for ([_]u8{ 0, 1, 50, 127, 128, 200, 254, 255 }) |value| {
        try testing.expectEqual(value, normToU8(u8ToNorm(value)));
    }
}

test "compose src over opaque and transparent" {
    const opaque_result = composeSrcOver(
        PremulRgba8{ .r = 255, .g = 0, .b = 0, .a = 255 },
        PremulRgba8{ .r = 0, .g = 255, .b = 0, .a = 255 },
    );
    try testing.expectEqual(PremulRgba8{ .r = 255, .g = 0, .b = 0, .a = 255 }, opaque_result);

    const transparent = composeSrcOver(
        PremulRgba8{ .r = 0, .g = 0, .b = 0, .a = 0 },
        PremulRgba8{ .r = 0, .g = 255, .b = 0, .a = 255 },
    );
    try testing.expectEqual(PremulRgba8{ .r = 0, .g = 255, .b = 0, .a = 255 }, transparent);

    const half = composeSrcOver(
        PremulRgba8{ .r = 128, .g = 0, .b = 0, .a = 128 },
        PremulRgba8{ .r = 0, .g = 128, .b = 0, .a = 128 },
    );
    try testing.expectEqual(PremulRgba8{ .r = 128, .g = 64, .b = 0, .a = 192 }, half);
}

test "write colored shadow applies color and composites" {
    const allocator = testing.allocator;
    var shadow = try Pixmap.init(allocator, 2, 2);
    defer shadow.deinit(allocator);
    var dst = try Pixmap.init(allocator, 2, 2);
    defer dst.deinit(allocator);

    shadow.setPixel(0, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    writeColoredShadow(&shadow, &dst, peniko.palette.css.RED, true);

    const result = dst.sample(0, 0);
    try testing.expectEqual(@as(u8, 255), result.r);
    try testing.expectEqual(@as(u8, 0), result.g);
    try testing.expectEqual(@as(u8, 0), result.b);
    try testing.expectEqual(@as(u8, 255), result.a);
}

test "drop shadow only leaves the shadow without the original" {
    const allocator = testing.allocator;
    var scratch = ScratchBuffer{};
    defer scratch.deinit(allocator);

    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    const shadow = common_filter.DropShadow.newShadowOnly(
        1.0,
        1.0,
        0.0,
        .none,
        peniko.palette.css.RED,
    );
    try dropShadowExecute(allocator, shadow, &pixmap, &scratch);

    // The opaque white source becomes the colored shadow at (2, 2) and the
    // original pixel is not composited back.
    try testing.expectEqual(@as(u8, 255), pixmap.sample(2, 2).a);
    try testing.expectEqual(@as(u8, 0), pixmap.sample(1, 1).a);
}

test "drop shadow composites the original over the shadow" {
    const allocator = testing.allocator;
    var scratch = ScratchBuffer{};
    defer scratch.deinit(allocator);

    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(1, 1, white());

    const shadow = common_filter.DropShadow.new(1.0, 1.0, 0.0, .none, peniko.palette.css.RED);
    try dropShadowExecute(allocator, shadow, &pixmap, &scratch);

    // Original white is composited over the red shadow at its own position.
    const original = pixmap.sample(1, 1);
    try testing.expectEqual(@as(u8, 255), original.r);
    try testing.expectEqual(@as(u8, 255), original.g);
    try testing.expectEqual(@as(u8, 255), original.b);
    try testing.expectEqual(@as(u8, 255), original.a);

    // The shadow is visible where the original is transparent.
    const shadow_pixel = pixmap.sample(2, 2);
    try testing.expectEqual(@as(u8, 255), shadow_pixel.r);
    try testing.expectEqual(@as(u8, 255), shadow_pixel.a);
}
