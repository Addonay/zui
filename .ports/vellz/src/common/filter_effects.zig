//! Port of vello_common filter_effects.rs (Apache-2.0 OR MIT).
//!
//! Filter effects API based on the W3C Filter Effects specification. This
//! module is the data model only: the enum/struct definitions, their
//! constructors, and the pure-geometry expansion math. Upstream has no
//! rendering algorithms in this file (they live in `vello_cpu`/`vello_gpu`).
//!
//! Ownership/allocator note: `Filter` holds a reference-counted
//! `Shared(FilterGraph)` (replacing `Arc<FilterGraph>`); `clone` retains and
//! `deinit` releases. `FilterGraph.primitives` is a `std.ArrayList` (replacing
//! `SmallVec<[FilterPrimitive; 1]>`), so `add`/`clone` take an explicit
//! allocator. Variants that own heap data (`ConvolutionKernel.values` and
//! `TransferFunction.table`/`.discrete`) are freed by `FilterPrimitive.deinit`;
//! every `FilterGraph` built with `add` must be `deinit`ed. All other values
//! are plain data.
//!
//! Divergences from upstream, all forced by Zig:
//! * Infallible `Vec`-allocating constructors (`Filter::from_function`,
//!   `Filter::from_primitive`, `FilterGraph::add`, `FilterGraph::clone`)
//!   return an error union (`Allocator.Error`).
//! * `Filter::from_function` reports `error.Unsupported` for functions other
//!   than `Blur` instead of upstream's `unimplemented!` panic.
//! * `FilterGraph::add` reports `error.TooManyPrimitives` when the `u16` id
//!   counter is exhausted instead of overflowing like upstream's
//!   `next_id += 1`.
//! * The `FilterGraph::add` `inputs` parameter is still ignored (upstream
//!   names it `_inputs`): connecting primitives is part of graph execution,
//!   which is not implemented yet.
//! * Enum variants are snake_case and `CompositeOperator.In` is spelled
//!   `@"in"` because `in` is a Zig keyword.
//! * `BlendMode` is the `peniko.Mix` re-export, matching
//!   `pub type BlendMode = peniko::Mix`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const shared = @import("shared.zig");

/// The main filter system.
///
/// A filter combines a graph of filter primitives with optional spatial
/// bounds. If bounds are specified, the filter only applies within that
/// region.
pub const Filter = struct {
    /// Filter graph defining the effect pipeline.
    graph: shared.Shared(FilterGraph),
    // TODO: Add bounds restricting where the filter applies, see upstream.

    /// Errors from `fromFunction`.
    pub const FromFunctionError = error{Unsupported} || std.mem.Allocator.Error;

    /// Create a simple filter system from a filter function.
    ///
    /// Converts a high-level CSS-style filter function into a filter graph.
    /// Use this for simple effects like blur, brightness, etc.
    ///
    /// Only `Blur` is convertible, exactly as upstream; every other function
    /// returns `error.Unsupported` where upstream panics with
    /// `unimplemented!`.
    pub fn fromFunction(allocator: std.mem.Allocator, function: FilterFunction) FromFunctionError!Filter {
        const primitive: FilterPrimitive = switch (function) {
            .blur => |blur| .{ .gaussian_blur = .{
                .std_deviation = blur.radius,
                .edge_mode = EdgeMode.default,
            } },
            else => return error.Unsupported,
        };

        return fromPrimitive(allocator, primitive);
    }

    /// Create a filter system from a filter primitive.
    ///
    /// Creates a simple filter graph with a single primitive.
    /// Use this for direct access to low-level SVG filter operations.
    pub fn fromPrimitive(allocator: std.mem.Allocator, primitive: FilterPrimitive) std.mem.Allocator.Error!Filter {
        var graph = FilterGraph.new();
        errdefer graph.deinit(allocator);

        const filter_id = graph.add(allocator, primitive, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A freshly created graph starts at `next_id == 0`.
            error.TooManyPrimitives => unreachable,
        };
        graph.setOutput(filter_id);

        return .{ .graph = try shared.Shared(FilterGraph).create(allocator, graph) };
    }

    /// Add one reference and return a second owned handle.
    pub fn clone(self: Filter) Filter {
        return .{ .graph = self.graph.clone() };
    }

    /// Drop one reference, freeing the graph on the last one.
    pub fn deinit(self: Filter, allocator: std.mem.Allocator) void {
        self.graph.release(allocator);
    }

    /// Calculate how far the filtered output can extend beyond the source
    /// content.
    ///
    /// The returned `Rect` is an expansion around the source content bounds,
    /// expressed in device space after applying the linear part of
    /// `transform`. Negative `x0`/`y0` values expand to the left/top; positive
    /// `x1`/`y1` values expand to the right/bottom.
    pub fn filterExpansion(self: Filter, transform: kurbo.Affine) kurbo.Rect {
        const coeffs = transform.asCoeffs();
        const linear_only = kurbo.Affine.new(.{
            coeffs[0],
            coeffs[1],
            coeffs[2],
            coeffs[3],
            0.0,
            0.0,
        });

        return self.graph.get().filterExpansion(linear_only);
    }

    /// Calculate how far the source input must extend outside the visible
    /// source bounds to render the filter correctly.
    ///
    /// In most cases (for example for Gaussian blurs), this is the same as
    /// `filterExpansion`. However, it isn't the same for drop shadows: the
    /// filter expansion of a shadow offset to the bottom/right is positive
    /// there, while the source expansion points the other way so the shifted
    /// source is not cut off.
    pub fn sourceExpansion(self: Filter, transform: kurbo.Affine) kurbo.Rect {
        const coeffs = transform.asCoeffs();
        const linear_only = kurbo.Affine.new(.{
            coeffs[0],
            coeffs[1],
            coeffs[2],
            coeffs[3],
            0.0,
            0.0,
        });

        return self.graph.get().sourceExpansion(linear_only);
    }

    /// Compare two filters by graph contents (upstream `PartialEq`, which
    /// compares the referenced `FilterGraph`s).
    pub fn eql(a: Filter, b: Filter) bool {
        if (shared.Shared(FilterGraph).ptrEq(a.graph, b.graph)) return true;
        return a.graph.get().eql(b.graph.get().*);
    }
};

/// A directed acyclic graph (DAG) of filter operations.
///
/// The graph represents a pipeline of filter primitives where outputs of some
/// primitives can be used as inputs to others. Each primitive has a unique
/// `FilterId`.
pub const FilterGraph = struct {
    /// All filter primitives in the graph, stored in insertion order.
    ///
    /// Upstream uses `SmallVec<[FilterPrimitive; 1]>`; this port uses an
    /// unmanaged `std.ArrayList` with an explicit allocator.
    primitives: std.ArrayList(FilterPrimitive),
    /// The final output filter ID whose result is the output of this graph.
    output: FilterId,
    /// Next available filter ID (monotonically increasing counter).
    next_id: u16,
    /// Accumulated filter expansion from all primitives in the graph, cached
    /// in user space.
    filter_expansion: kurbo.Rect,
    /// Accumulated source expansion from all primitives in the graph, cached
    /// in user space.
    source_expansion: kurbo.Rect,

    /// Errors from `add`.
    pub const AddError = error{ OutOfMemory, TooManyPrimitives };

    /// Create a new empty filter graph (upstream's `Default` and `new`).
    pub fn new() FilterGraph {
        return .{
            .primitives = std.ArrayList(FilterPrimitive).empty,
            .output = FilterId.zero,
            .next_id = 0,
            .filter_expansion = kurbo.Rect.ZERO,
            .source_expansion = kurbo.Rect.ZERO,
        };
    }

    /// Release the primitive list and any heap data owned by the primitives.
    pub fn deinit(self: *FilterGraph, allocator: std.mem.Allocator) void {
        for (self.primitives.items) |*primitive| primitive.deinit(allocator);
        self.primitives.deinit(allocator);
        self.* = undefined;
    }

    /// Add a filter primitive with optional inputs.
    ///
    /// Returns a `FilterId` that can be referenced by other primitives.
    /// Automatically updates the accumulated source and filter expansion
    /// requirements.
    ///
    /// Upstream ignores `inputs` (its parameter is named `_inputs`); this port
    /// keeps the parameter for API parity. Connecting primitives belongs to
    /// graph execution, which is not implemented yet.
    ///
    /// Upstream's `next_id += 1` overflows a `u16` after 65536 primitives
    /// (panicking in debug builds); this port reports
    /// `error.TooManyPrimitives` instead and supports up to 65535 primitives.
    pub fn add(
        self: *FilterGraph,
        allocator: std.mem.Allocator,
        primitive: FilterPrimitive,
        inputs: ?FilterInputs,
    ) AddError!FilterId {
        _ = inputs;

        if (self.next_id == std.math.maxInt(u16)) return error.TooManyPrimitives;
        const id = FilterId.new(self.next_id);

        try self.primitives.append(allocator, primitive);
        self.filter_expansion = self.filter_expansion.unionWith(primitive.filterExpansion());
        self.source_expansion = self.source_expansion.unionWith(primitive.sourceExpansion());
        self.next_id += 1;

        return id;
    }

    /// Set the output filter for the graph.
    pub fn setOutput(self: *FilterGraph, output: FilterId) void {
        self.output = output;
    }

    /// The filter expansion of all filters in the graph, see
    /// `Filter.filterExpansion`.
    pub fn filterExpansion(self: FilterGraph, transform: kurbo.Affine) kurbo.Rect {
        return transform.transformRectBbox(self.filter_expansion);
    }

    /// The source expansion of all filters in the graph, see
    /// `Filter.sourceExpansion`.
    pub fn sourceExpansion(self: FilterGraph, transform: kurbo.Affine) kurbo.Rect {
        return transform.transformRectBbox(self.source_expansion);
    }

    /// Deep-clone the graph (upstream `Clone`), allocating owned primitives
    /// from `allocator`.
    pub fn clone(self: FilterGraph, allocator: std.mem.Allocator) std.mem.Allocator.Error!FilterGraph {
        var primitives = std.ArrayList(FilterPrimitive).empty;
        errdefer {
            for (primitives.items) |*primitive| primitive.deinit(allocator);
            primitives.deinit(allocator);
        }

        try primitives.ensureTotalCapacity(allocator, self.primitives.items.len);
        for (self.primitives.items) |primitive| {
            primitives.appendAssumeCapacity(try primitive.clone(allocator));
        }

        return .{
            .primitives = primitives,
            .output = self.output,
            .next_id = self.next_id,
            .filter_expansion = self.filter_expansion,
            .source_expansion = self.source_expansion,
        };
    }

    /// Compare two graphs (upstream `PartialEq`).
    pub fn eql(a: FilterGraph, b: FilterGraph) bool {
        if (a.output.id != b.output.id) return false;
        if (a.next_id != b.next_id) return false;
        if (!std.meta.eql(a.filter_expansion, b.filter_expansion)) return false;
        if (!std.meta.eql(a.source_expansion, b.source_expansion)) return false;
        if (a.primitives.items.len != b.primitives.items.len) return false;

        for (a.primitives.items, b.primitives.items) |primitive_a, primitive_b| {
            if (!primitive_a.eql(primitive_b)) return false;
        }

        return true;
    }
};

/// All possible filter effects.
///
/// This enum allows choosing between high-level filter functions (simple
/// CSS-style effects) and low-level filter primitives (complex SVG-style
/// effects with full control).
pub const FilterEffect = union(enum) {
    /// Simple, high-level filter functions.
    function: FilterFunction,
    /// Low-level filter primitives (granular control).
    primitive: FilterPrimitive,

    /// Release any heap data owned by a `primitive` variant.
    pub fn deinit(self: *FilterEffect, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .primitive => self.primitive.deinit(allocator),
            .function => {},
        }
    }
};

/// High-level filter functions for common effects (CSS filter functions).
///
/// See: <https://drafts.fxtf.org/filter-effects/#filter-functions>.
pub const FilterFunction = union(enum) {
    /// Gaussian blur effect.
    ///
    /// Per the W3C Filter Effects specification, `radius` is the standard
    /// deviation (σ) of the Gaussian function. A value of 0 means no blur.
    blur: struct {
        /// Standard deviation of the Gaussian blur in pixels. Must be
        /// non-negative.
        radius: f32,
    },
    /// Brightness adjustment.
    brightness: struct {
        /// 0.0 = completely black, 1.0 = no change, >1.0 = brighter.
        amount: f32,
    },
    /// Contrast adjustment.
    contrast: struct {
        /// 0.0 = uniform gray, 1.0 = no change, >1.0 = higher contrast.
        amount: f32,
    },
    /// Grayscale conversion.
    grayscale: struct {
        /// 0.0 = original colors, 1.0 = full grayscale.
        amount: f32,
    },
    /// Hue rotation.
    hue_rotate: struct {
        /// Rotation angle in degrees. Can be negative.
        angle: f32,
    },
    /// Color inversion.
    invert: struct {
        /// 0.0 = original colors, 1.0 = fully inverted.
        amount: f32,
    },
    /// Opacity adjustment.
    opacity: struct {
        /// 0.0 = fully transparent, 1.0 = no change.
        amount: f32,
    },
    /// Saturation adjustment.
    saturate: struct {
        /// 0.0 = completely desaturated, 1.0 = no change, >1.0 = oversaturated.
        amount: f32,
    },
    /// Sepia tone effect.
    sepia: struct {
        /// 0.0 = original colors, 1.0 = full sepia tone.
        amount: f32,
    },
};

/// Edge mode for filter operations.
///
/// Determines how to extend the input image when filter operations require
/// sampling beyond the original image boundaries.
///
/// See: <https://drafts.fxtf.org/filter-effects/#element-attrdef-filter-primitive-edgemode>.
pub const EdgeMode = enum {
    /// Extend by duplicating edge pixels (clamp to edge).
    duplicate,
    /// Extend by wrapping to the opposite edge (repeat/tile).
    wrap,
    /// Extend by mirroring across the edge.
    mirror,
    /// Extend with transparent black (zeros).
    none,

    /// The upstream `#[default]`: `None`.
    pub const default: EdgeMode = .none;
};

/// Low-level filter primitives for granular control (SVG filter primitives).
///
/// See: <https://drafts.fxtf.org/filter-effects/#FilterPrimitivesOverview>.
pub const FilterPrimitive = union(enum) {
    /// Generate a solid color fill.
    flood: struct {
        /// Fill color with alpha channel.
        color: peniko.AlphaColor(peniko.Srgb),
    },
    /// Gaussian blur filter.
    gaussian_blur: struct {
        /// Standard deviation for the blur kernel. Must be non-negative.
        std_deviation: f32,
        /// Edge mode determining how pixels beyond the input bounds are
        /// handled.
        edge_mode: EdgeMode,
    },
    /// Drop shadow effect (compound primitive).
    drop_shadow: struct {
        /// Horizontal offset of the shadow in pixels. Positive shifts right.
        dx: f32,
        /// Vertical offset of the shadow in pixels. Positive shifts down.
        dy: f32,
        /// Blur standard deviation for the shadow.
        std_deviation: f32,
        /// Shadow color with alpha channel.
        color: peniko.AlphaColor(peniko.Srgb),
        /// Edge mode for handling boundaries during the blur operation.
        edge_mode: EdgeMode,
    },
    /// Same as `drop_shadow`, but without compositing the original layer on
    /// top of it.
    drop_shadow_only: struct {
        /// Horizontal offset of the shadow in pixels. Positive shifts right.
        dx: f32,
        /// Vertical offset of the shadow in pixels. Positive shifts down.
        dy: f32,
        /// Blur standard deviation for the shadow.
        std_deviation: f32,
        /// Color applied to the blurred, offset input alpha mask.
        color: peniko.AlphaColor(peniko.Srgb),
        /// Edge mode for handling boundaries during the blur operation.
        edge_mode: EdgeMode,
    },
    /// Matrix-based color transformation.
    color_matrix: struct {
        /// 4x5 color transformation matrix: 4 rows (R,G,B,A) x 5 columns
        /// (R,G,B,A,offset).
        matrix: [20]f32,
    },
    /// Geometric offset/translation.
    offset: struct {
        /// Horizontal offset in pixels. Positive shifts right.
        dx: f32,
        /// Vertical offset in pixels. Positive shifts down.
        dy: f32,
    },
    /// Composite two inputs using Porter-Duff compositing operations.
    composite: struct {
        /// Porter-Duff compositing operator to apply.
        operator: CompositeOperator,
    },
    /// Blend two inputs using blend modes.
    blend: struct {
        /// Blend mode determining how colors are combined.
        mode: BlendMode,
    },
    /// Morphological operations (dilate/erode).
    morphology: struct {
        /// Morphological operator determining whether to erode or dilate.
        operator: MorphologyOperator,
        /// Operation radius in pixels.
        radius: f32,
    },
    /// Custom convolution kernel for image processing.
    convolve_matrix: struct {
        /// Convolution kernel specification.
        kernel: ConvolutionKernel,
    },
    /// Generate Perlin noise/turbulence patterns.
    turbulence: struct {
        /// Base frequency for noise generation.
        base_frequency: f32,
        /// Number of octaves for fractal noise.
        num_octaves: u32,
        /// Random seed for reproducible noise generation.
        seed: u32,
        /// Type of noise: smooth fractal or more chaotic turbulence.
        turbulence_type: TurbulenceType,
    },
    /// Displace pixels using a displacement map.
    displacement_map: struct {
        /// Scale factor controlling the displacement intensity.
        scale: f32,
        /// Color channel from the displacement map used for X-axis
        /// displacement.
        x_channel: ColorChannel,
        /// Color channel from the displacement map used for Y-axis
        /// displacement.
        y_channel: ColorChannel,
    },
    /// Per-channel component transfer using lookup tables or functions.
    component_transfer: struct {
        /// Transfer function applied to the red channel (null = identity).
        red_function: ?TransferFunction,
        /// Transfer function applied to the green channel (null = identity).
        green_function: ?TransferFunction,
        /// Transfer function applied to the blue channel (null = identity).
        blue_function: ?TransferFunction,
        /// Transfer function applied to the alpha channel (null = identity).
        alpha_function: ?TransferFunction,
    },
    /// Reference an external image as filter input.
    image: struct {
        /// Identifier referencing an image in the resource atlas.
        image_id: u32,
        /// Optional 2D affine transformation matrix `[a, b, c, d, e, f]`.
        transform: ?[6]f32,
    },
    /// Tile the input to fill the filter region.
    tile,
    /// Diffuse lighting simulation.
    diffuse_lighting: struct {
        /// Surface scale factor for converting alpha values to heights.
        surface_scale: f32,
        /// Diffuse reflection constant (kd).
        diffuse_constant: f32,
        /// Kernel unit length for gradient calculations in user space.
        kernel_unit_length: f32,
        /// Configuration of the light source (point, distant, or spot).
        light_source: LightSource,
    },
    /// Specular lighting simulation.
    specular_lighting: struct {
        /// Surface scale factor for converting alpha values to heights.
        surface_scale: f32,
        /// Specular reflection constant (ks).
        specular_constant: f32,
        /// Specular reflection exponent. Higher values give sharper
        /// highlights.
        specular_exponent: f32,
        /// Kernel unit length for gradient calculations in user space.
        kernel_unit_length: f32,
        /// Configuration of the light source (point, distant, or spot).
        light_source: LightSource,
    },

    /// The filter expansion of the primitive, see `Filter.filterExpansion`.
    pub fn filterExpansion(self: FilterPrimitive) kurbo.Rect {
        switch (self) {
            .gaussian_blur => |blur| {
                const radius = blurRadius(blur.std_deviation);
                return kurbo.Rect.new(-radius, -radius, radius, radius);
            },
            .offset => |offset| {
                // Offset shifts pixels; expand bounds asymmetrically so
                // shifted content isn't cut.
                const dx: f64 = @floatCast(offset.dx);
                const dy: f64 = @floatCast(offset.dy);
                return kurbo.Rect.new(@min(dx, 0.0), @min(dy, 0.0), @max(dx, 0.0), @max(dy, 0.0));
            },
            .drop_shadow => |shadow| return dropShadowFilterExpansion(shadow.dx, shadow.dy, shadow.std_deviation),
            .drop_shadow_only => |shadow| return dropShadowFilterExpansion(shadow.dx, shadow.dy, shadow.std_deviation),
            // Most other filters don't expand bounds.
            else => return kurbo.Rect.ZERO,
        }
    }

    /// The source expansion of the primitive, see `Filter.sourceExpansion`.
    pub fn sourceExpansion(self: FilterPrimitive) kurbo.Rect {
        switch (self) {
            .offset => |offset| {
                return self.filterExpansion().subVec(kurbo.Vec2.new(offset.dx, offset.dy));
            },
            .drop_shadow => |shadow| return dropShadowSourceExpansion(shadow.dx, shadow.dy, shadow.std_deviation),
            .drop_shadow_only => |shadow| return dropShadowSourceExpansion(shadow.dx, shadow.dy, shadow.std_deviation),
            else => return self.filterExpansion(),
        }
    }

    /// Deep-clone the primitive, allocating owned payload data from
    /// `allocator` (upstream `Clone`).
    pub fn clone(self: FilterPrimitive, allocator: std.mem.Allocator) std.mem.Allocator.Error!FilterPrimitive {
        switch (self) {
            .convolve_matrix => |convolve| {
                return .{ .convolve_matrix = .{ .kernel = try convolve.kernel.clone(allocator) } };
            },
            .component_transfer => |transfer| {
                var cloned: FilterPrimitive = .{ .component_transfer = .{
                    .red_function = null,
                    .green_function = null,
                    .blue_function = null,
                    .alpha_function = null,
                } };
                errdefer cloned.deinit(allocator);

                inline for (.{ "red_function", "green_function", "blue_function", "alpha_function" }) |name| {
                    if (@field(transfer, name)) |function| {
                        @field(cloned.component_transfer, name) = try function.clone(allocator);
                    }
                }

                return cloned;
            },
            // No variant other than the two above owns heap data.
            else => return self,
        }
    }

    /// Free heap data owned by this primitive.
    pub fn deinit(self: *FilterPrimitive, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .convolve_matrix => self.convolve_matrix.kernel.deinit(allocator),
            .component_transfer => {
                if (self.component_transfer.red_function) |*function| function.deinit(allocator);
                if (self.component_transfer.green_function) |*function| function.deinit(allocator);
                if (self.component_transfer.blue_function) |*function| function.deinit(allocator);
                if (self.component_transfer.alpha_function) |*function| function.deinit(allocator);
            },
            else => {},
        }
    }

    /// Compare two primitives (upstream `PartialEq`).
    pub fn eql(a: FilterPrimitive, b: FilterPrimitive) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .flood => |value| std.meta.eql(value, b.flood),
            .gaussian_blur => |value| std.meta.eql(value, b.gaussian_blur),
            .drop_shadow => |value| std.meta.eql(value, b.drop_shadow),
            .drop_shadow_only => |value| std.meta.eql(value, b.drop_shadow_only),
            .color_matrix => |value| std.meta.eql(value, b.color_matrix),
            .offset => |value| std.meta.eql(value, b.offset),
            .composite => |value| value.operator.eql(b.composite.operator),
            .blend => |value| value.mode == b.blend.mode,
            .morphology => |value| value.operator == b.morphology.operator and value.radius == b.morphology.radius,
            .convolve_matrix => |value| value.kernel.eql(b.convolve_matrix.kernel),
            .turbulence => |value| std.meta.eql(value, b.turbulence),
            .displacement_map => |value| std.meta.eql(value, b.displacement_map),
            .component_transfer => |value| componentTransferEql(value, b.component_transfer),
            .image => |value| std.meta.eql(value, b.image),
            .tile => true,
            .diffuse_lighting => |value| std.meta.eql(value, b.diffuse_lighting),
            .specular_lighting => |value| std.meta.eql(value, b.specular_lighting),
        };
    }
};

/// Unique identifier for a filter primitive in the graph.
pub const FilterId = struct {
    /// The numeric identifier. Upstream is the tuple struct `FilterId(pub u16)`.
    id: u16,

    /// The zero id, used as the default `FilterGraph.output`.
    pub const zero: FilterId = .{ .id = 0 };

    /// Create a filter id from its numeric value.
    pub fn new(id: u16) FilterId {
        return .{ .id = id };
    }

    /// Compare two ids (upstream `PartialEq`/`Eq`).
    pub fn eql(a: FilterId, b: FilterId) bool {
        return a.id == b.id;
    }
};

/// Input connections for a filter primitive.
pub const FilterInputs = struct {
    /// Primary input ("in" attribute in SVG).
    primary: FilterInput,
    /// Secondary input ("in2" attribute in SVG, for composite/blend
    /// operations).
    secondary: ?FilterInput,

    /// Create filter inputs with a single input.
    pub fn single(input: FilterInput) FilterInputs {
        return .{ .primary = input, .secondary = null };
    }

    /// Create filter inputs with two inputs (for composite, blend, etc.).
    pub fn dual(input1: FilterInput, input2: FilterInput) FilterInputs {
        return .{ .primary = input1, .secondary = input2 };
    }

    /// Compare two input descriptions (upstream `PartialEq`).
    pub fn eql(a: FilterInputs, b: FilterInputs) bool {
        return std.meta.eql(a, b);
    }
};

/// A single filter input.
pub const FilterInput = union(enum) {
    /// Input from a source (`SourceGraphic`, `SourceAlpha`, etc.).
    source: FilterSource,
    /// Input from another filter's result.
    result: FilterId,

    /// Compare two inputs (upstream `PartialEq`).
    pub fn eql(a: FilterInput, b: FilterInput) bool {
        return std.meta.eql(a, b);
    }
};

/// Filter input sources.
///
/// Defines the various built-in sources that can be used as filter inputs,
/// matching the SVG filter primitive input types.
pub const FilterSource = enum {
    /// The original graphic content being filtered.
    source_graphic,
    /// Alpha channel only of the original graphic.
    source_alpha,
    /// Background image content behind the filtered element.
    background_image,
    /// Alpha channel only of the background image.
    background_alpha,
    /// The fill paint of the element as an image input.
    fill_paint,
    /// The stroke paint of the element as an image input.
    stroke_paint,
};

/// Pre-built compound effects for common use cases.
///
/// **Note:** These are planned but not yet implemented upstream. Use
/// `FilterGraph` to manually construct these effects from primitives.
pub const CompoundFilter = union(enum) {
    /// Inner shadow effect (shadow inside the shape).
    inner_shadow: struct {
        /// Horizontal offset of the shadow in pixels.
        dx: f32,
        /// Vertical offset of the shadow in pixels.
        dy: f32,
        /// Blur radius for the shadow in pixels.
        blur: f32,
        /// Shadow color with alpha channel.
        color: peniko.AlphaColor(peniko.Srgb),
    },
    /// Glow effect around the shape.
    glow: struct {
        /// Blur radius for the glow in pixels.
        blur: f32,
        /// Glow color with alpha channel.
        color: peniko.AlphaColor(peniko.Srgb),
    },
    /// Bevel effect (3D raised/recessed appearance).
    bevel: struct {
        /// Light source angle in degrees (0 = right, 90 = up).
        angle: f32,
        /// Width of the bevel edge in pixels.
        distance: f32,
        /// Color for the highlight (lit) side of the bevel.
        highlight: peniko.AlphaColor(peniko.Srgb),
        /// Color for the shadow (dark) side of the bevel.
        shadow: peniko.AlphaColor(peniko.Srgb),
    },
    /// Emboss effect for a raised relief appearance.
    emboss: struct {
        /// Light angle in degrees determining emboss direction.
        angle: f32,
        /// Depth of the emboss effect.
        depth: f32,
        /// Overall strength/intensity of the effect (0.0 = none, 1.0 = full).
        amount: f32,
    },
};

/// Composite operators for combining filter inputs.
///
/// These are the Porter-Duff compositing operators used to combine two
/// images.
pub const CompositeOperator = union(enum) {
    /// Source over destination (standard alpha blending).
    over,
    /// Source in destination (intersection).
    ///
    /// Upstream's `In`; `@"in"` because `in` is a Zig keyword.
    in,
    /// Source out destination (subtract).
    out,
    /// Source atop destination.
    atop,
    /// Source XOR destination (exclusive or).
    xor,
    /// Arithmetic combination with custom coefficients:
    /// `result = k1*src*dst + k2*src + k3*dst + k4`.
    arithmetic: struct {
        /// Coefficient k1 for the (source * destination) term.
        k1: f32,
        /// Coefficient k2 for the source term.
        k2: f32,
        /// Coefficient k3 for the destination term.
        k3: f32,
        /// Constant offset k4 added to the result.
        k4: f32,
    },

    /// Compare two operators (upstream `PartialEq`).
    pub fn eql(a: CompositeOperator, b: CompositeOperator) bool {
        return std.meta.eql(a, b);
    }
};

/// Blend modes for combining colors.
///
/// Upstream: `pub type BlendMode = peniko::Mix`.
pub const BlendMode = peniko.Mix;

/// Morphological operators for dilate/erode operations.
pub const MorphologyOperator = enum {
    /// Erode operation (shrink/thin shapes).
    erode,
    /// Dilate operation (expand/thicken shapes).
    dilate,
};

/// Convolution kernel for custom filtering operations.
///
/// Defines a square matrix of weights used for convolution-based image
/// processing.
///
/// Ownership: `values` is an owned list. Upstream builds this struct with a
/// `Vec<f32>` literal; Zig needs an explicit allocator, so use `init` to copy
/// a slice and `deinit` to free it.
pub const ConvolutionKernel = struct {
    /// Kernel size (e.g., 3 for a 3x3 kernel, 5 for 5x5). The kernel must be
    /// square, so this defines both width and height.
    size: u32,
    /// Kernel weight values in row-major order. Length must equal
    /// `size * size`.
    values: std.ArrayList(f32),
    /// Normalization divisor applied to the convolution result.
    divisor: f32,
    /// Bias value added to the result after normalization.
    bias: f32,
    /// Whether to preserve the alpha channel unchanged.
    preserve_alpha: bool,

    /// Create a kernel by copying `values` into an owned list.
    pub fn init(
        allocator: std.mem.Allocator,
        size: u32,
        values: []const f32,
        divisor: f32,
        bias: f32,
        preserve_alpha: bool,
    ) std.mem.Allocator.Error!ConvolutionKernel {
        var owned = std.ArrayList(f32).empty;
        errdefer owned.deinit(allocator);
        try owned.appendSlice(allocator, values);

        return .{
            .size = size,
            .values = owned,
            .divisor = divisor,
            .bias = bias,
            .preserve_alpha = preserve_alpha,
        };
    }

    /// Free the kernel weights.
    pub fn deinit(self: *ConvolutionKernel, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    /// Deep-clone the kernel (upstream `Clone`).
    pub fn clone(self: ConvolutionKernel, allocator: std.mem.Allocator) std.mem.Allocator.Error!ConvolutionKernel {
        return .{
            .size = self.size,
            .values = try self.values.clone(allocator),
            .divisor = self.divisor,
            .bias = self.bias,
            .preserve_alpha = self.preserve_alpha,
        };
    }

    /// Compare two kernels by all fields and weight contents (upstream
    /// `PartialEq`).
    pub fn eql(a: ConvolutionKernel, b: ConvolutionKernel) bool {
        return a.size == b.size and
            a.divisor == b.divisor and
            a.bias == b.bias and
            a.preserve_alpha == b.preserve_alpha and
            f32SliceEql(a.values.items, b.values.items);
    }
};

/// Types of turbulence noise generation.
pub const TurbulenceType = enum {
    /// Fractal noise (smooth, natural-looking Perlin noise).
    fractal_noise,
    /// Turbulence noise (more chaotic and energetic).
    turbulence,
};

/// Color channels for displacement mapping and channel selection.
pub const ColorChannel = enum {
    /// Red color channel.
    red,
    /// Green color channel.
    green,
    /// Blue color channel.
    blue,
    /// Alpha channel.
    alpha,
};

/// Transfer functions for component transfer operations.
///
/// Ownership: `table` and `discrete` own their value lists. Upstream builds
/// them with `Vec<f32>` literals; Zig needs an explicit allocator, so use
/// `initTable`/`initDiscrete` and `deinit`.
pub const TransferFunction = union(enum) {
    /// Identity function (output = input, no change).
    identity,
    /// Table lookup with linear interpolation.
    table: struct {
        /// Lookup table values defining the transfer curve. Minimum 2 values
        /// required upstream.
        values: std.ArrayList(f32),
    },
    /// Discrete step function (posterization).
    discrete: struct {
        /// Step values for each discrete output level.
        values: std.ArrayList(f32),
    },
    /// Linear function: `output = slope * input + intercept`.
    linear: struct {
        /// Slope coefficient.
        slope: f32,
        /// Intercept offset.
        intercept: f32,
    },
    /// Gamma correction: `output = amplitude * input^exponent + offset`.
    gamma: struct {
        /// Amplitude multiplier.
        amplitude: f32,
        /// Gamma exponent (< 1 brightens, > 1 darkens midtones).
        exponent: f32,
        /// Offset added to the final result.
        offset: f32,
    },

    /// Create a table transfer function by copying `values`.
    pub fn initTable(allocator: std.mem.Allocator, values: []const f32) std.mem.Allocator.Error!TransferFunction {
        var owned = std.ArrayList(f32).empty;
        errdefer owned.deinit(allocator);
        try owned.appendSlice(allocator, values);
        return .{ .table = .{ .values = owned } };
    }

    /// Create a discrete transfer function by copying `values`.
    pub fn initDiscrete(allocator: std.mem.Allocator, values: []const f32) std.mem.Allocator.Error!TransferFunction {
        var owned = std.ArrayList(f32).empty;
        errdefer owned.deinit(allocator);
        try owned.appendSlice(allocator, values);
        return .{ .discrete = .{ .values = owned } };
    }

    /// Free the value list of `table`/`discrete` variants.
    pub fn deinit(self: *TransferFunction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .table => self.table.values.deinit(allocator),
            .discrete => self.discrete.values.deinit(allocator),
            else => {},
        }
    }

    /// Deep-clone the transfer function (upstream `Clone`).
    pub fn clone(self: TransferFunction, allocator: std.mem.Allocator) std.mem.Allocator.Error!TransferFunction {
        return switch (self) {
            .table => |table| .{ .table = .{ .values = try table.values.clone(allocator) } },
            .discrete => |discrete| .{ .discrete = .{ .values = try discrete.values.clone(allocator) } },
            else => self,
        };
    }

    /// Compare two transfer functions (upstream `PartialEq`).
    pub fn eql(a: TransferFunction, b: TransferFunction) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .identity => true,
            .table => |table| f32SliceEql(table.values.items, b.table.values.items),
            .discrete => |discrete| f32SliceEql(discrete.values.items, b.discrete.values.items),
            .linear => |value| std.meta.eql(value, b.linear),
            .gamma => |value| std.meta.eql(value, b.gamma),
        };
    }
};

/// Light source configurations for lighting effects.
pub const LightSource = union(enum) {
    /// Distant light source (infinitely far away, like the sun).
    distant: struct {
        /// Azimuth angle in degrees (0 = pointing right, 90 = pointing up).
        azimuth: f32,
        /// Elevation angle in degrees (0 = horizon, 90 = overhead).
        elevation: f32,
    },
    /// Point light source at a specific 3D position.
    point: struct {
        /// Light source X coordinate in user space.
        x: f32,
        /// Light source Y coordinate in user space.
        y: f32,
        /// Light source Z coordinate (height above the surface).
        z: f32,
    },
    /// Spot light with position, direction, and cone angle.
    spot: struct {
        /// Light source X coordinate in user space.
        x: f32,
        /// Light source Y coordinate in user space.
        y: f32,
        /// Light source Z coordinate (height above the surface).
        z: f32,
        /// X coordinate the spotlight is aimed at.
        points_at_x: f32,
        /// Y coordinate the spotlight is aimed at.
        points_at_y: f32,
        /// Z coordinate the spotlight is aimed at.
        points_at_z: f32,
        /// Specular exponent controlling the focus of the spotlight beam.
        specular_exponent: f32,
        /// Optional cone angle in degrees limiting the spotlight spread.
        limiting_cone_angle: ?f32,
    },

    /// Compare two light sources (upstream `PartialEq`).
    pub fn eql(a: LightSource, b: LightSource) bool {
        return std.meta.eql(a, b);
    }
};

/// Gaussian blur expands uniformly by `3 * sigma` (covers 99.7% of the
/// distribution).
///
/// Upstream computes `std_deviation * 3.0` in `f32` and only then converts to
/// `f64`; the same order is kept here.
fn blurRadius(std_deviation: f32) f64 {
    const scaled: f32 = std_deviation * 3.0;
    return @floatCast(scaled);
}

fn dropShadowFilterExpansion(dx: f32, dy: f32, std_deviation: f32) kurbo.Rect {
    const radius = blurRadius(std_deviation);
    const dx64: f64 = @floatCast(dx);
    const dy64: f64 = @floatCast(dy);

    return kurbo.Rect.new(
        @min(dx64 - radius, 0.0),
        @min(dy64 - radius, 0.0),
        @max(dx64 + radius, 0.0),
        @max(dy64 + radius, 0.0),
    );
}

fn dropShadowSourceExpansion(dx: f32, dy: f32, std_deviation: f32) kurbo.Rect {
    const radius = blurRadius(std_deviation);
    const dx64: f64 = -@as(f64, @floatCast(dx));
    const dy64: f64 = -@as(f64, @floatCast(dy));

    return kurbo.Rect.new(
        @min(dx64 - radius, 0.0),
        @min(dy64 - radius, 0.0),
        @max(dx64 + radius, 0.0),
        @max(dy64 + radius, 0.0),
    );
}

fn componentTransferEql(a: anytype, b: @TypeOf(a)) bool {
    inline for (.{ "red_function", "green_function", "blue_function", "alpha_function" }) |name| {
        const function_a = @field(a, name);
        const function_b = @field(b, name);

        if (function_a) |value_a| {
            const value_b = function_b orelse return false;
            if (!value_a.eql(value_b)) return false;
        } else if (function_b != null) {
            return false;
        }
    }

    return true;
}

fn f32SliceEql(a: []const f32, b: []const f32) bool {
    if (a.len != b.len) return false;
    for (a, b) |value_a, value_b| {
        if (value_a != value_b) return false;
    }
    return true;
}

/// Common color transformation matrices.
///
/// These 4x5 matrices are used with the `color_matrix` filter primitive.
/// Each row transforms a color channel: `[R, G, B, A, offset]`.
pub const matrices = struct {
    /// Identity matrix (no change).
    pub const IDENTITY: [20]f32 = .{
        1.0, 0.0, 0.0, 0.0, 0.0, // Red
        0.0, 1.0, 0.0, 0.0, 0.0, // Green
        0.0, 0.0, 1.0, 0.0, 0.0, // Blue
        0.0, 0.0, 0.0, 1.0, 0.0, // Alpha
    };

    /// Extract alpha channel to RGB (for shadow effects).
    pub const ALPHA_TO_BLACK: [20]f32 = .{
        0.0, 0.0, 0.0, 1.0, 0.0, // Red = Alpha
        0.0, 0.0, 0.0, 1.0, 0.0, // Green = Alpha
        0.0, 0.0, 0.0, 1.0, 0.0, // Blue = Alpha
        0.0, 0.0, 0.0, 1.0, 0.0, // Alpha = Alpha
    };

    /// Grayscale conversion matrix using luminosity weights.
    pub const GRAYSCALE: [20]f32 = .{
        0.2126, 0.7152, 0.0722, 0.0, 0.0, // Red
        0.2126, 0.7152, 0.0722, 0.0, 0.0, // Green
        0.2126, 0.7152, 0.0722, 0.0, 0.0, // Blue
        0.0, 0.0, 0.0, 1.0, 0.0, // Alpha
    };

    /// Sepia tone matrix for vintage photo effect.
    pub const SEPIA: [20]f32 = .{
        0.393, 0.769, 0.189, 0.0, 0.0, // Red
        0.349, 0.686, 0.168, 0.0, 0.0, // Green
        0.272, 0.534, 0.131, 0.0, 0.0, // Blue
        0.0, 0.0, 0.0, 1.0, 0.0, // Alpha
    };
};

/// Common convolution kernels.
///
/// These kernels are used with the `convolve_matrix` filter primitive for
/// various image processing effects. All provided kernels are 3x3.
///
/// The upstream functions are infallible because `Vec` uses the global
/// allocator; these take an explicit allocator and return
/// `Allocator.Error`.
pub const kernels = struct {
    /// 3x3 Gaussian blur kernel for basic smoothing.
    pub fn gaussian3x3(allocator: std.mem.Allocator) std.mem.Allocator.Error!ConvolutionKernel {
        return ConvolutionKernel.init(
            allocator,
            3,
            &[_]f32{ 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 },
            16.0,
            0.0,
            false,
        );
    }

    /// 3x3 sharpen kernel to enhance edges and details.
    pub fn sharpen3x3(allocator: std.mem.Allocator) std.mem.Allocator.Error!ConvolutionKernel {
        return ConvolutionKernel.init(
            allocator,
            3,
            &[_]f32{ 0.0, -1.0, 0.0, -1.0, 5.0, -1.0, 0.0, -1.0, 0.0 },
            1.0,
            0.0,
            true,
        );
    }

    /// 3x3 edge detection kernel (Laplacian operator).
    pub fn edgeDetect3x3(allocator: std.mem.Allocator) std.mem.Allocator.Error!ConvolutionKernel {
        return ConvolutionKernel.init(
            allocator,
            3,
            &[_]f32{ -1.0, -1.0, -1.0, -1.0, 8.0, -1.0, -1.0, -1.0, -1.0 },
            1.0,
            0.0,
            true,
        );
    }

    /// 3x3 emboss kernel for creating a raised/beveled appearance.
    pub fn emboss3x3(allocator: std.mem.Allocator) std.mem.Allocator.Error!ConvolutionKernel {
        return ConvolutionKernel.init(
            allocator,
            3,
            &[_]f32{ -2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0 },
            1.0,
            0.5,
            true,
        );
    }
};

// Ported from upstream `mod expansion_tests`.

test "offset expands in direction of shift" {
    const primitive = FilterPrimitive{ .offset = .{ .dx = 2.5, .dy = -3.0 } };
    try std.testing.expectEqual(
        kurbo.Rect.new(0.0, -3.0, 2.5, 0.0),
        primitive.filterExpansion(),
    );
}

test "drop shadow expansion combines blur and offset tightly" {
    const primitive = FilterPrimitive{ .drop_shadow = .{
        .dx = 20.0,
        .dy = -10.0,
        .std_deviation = 8.0,
        .color = peniko.palette.css.RED,
        .edge_mode = .none,
    } };

    try std.testing.expectEqual(kurbo.Rect.new(-4.0, -34.0, 44.0, 14.0), primitive.filterExpansion());
    try std.testing.expectEqual(kurbo.Rect.new(-44.0, -14.0, 4.0, 34.0), primitive.sourceExpansion());
}

test "edge mode default is none" {
    try std.testing.expectEqual(EdgeMode.none, EdgeMode.default);
}

test "color matrix constants match upstream defaults" {
    try std.testing.expectEqual(@as(f32, 1.0), matrices.IDENTITY[0]);
    try std.testing.expectEqual(@as(f32, 0.0), matrices.IDENTITY[4]);
    try std.testing.expectEqual(@as(f32, 1.0), matrices.IDENTITY[18]);
    try std.testing.expectEqual(@as(f32, 0.2126), matrices.GRAYSCALE[0]);
    try std.testing.expectEqual(@as(f32, 0.7152), matrices.GRAYSCALE[1]);
    try std.testing.expectEqual(@as(f32, 0.0722), matrices.GRAYSCALE[2]);
    try std.testing.expectEqual(@as(f32, 1.0), matrices.ALPHA_TO_BLACK[3]);
    try std.testing.expectEqual(@as(f32, 0.393), matrices.SEPIA[0]);
    try std.testing.expectEqual(@as(f32, 0.769), matrices.SEPIA[1]);
    try std.testing.expectEqual(@as(f32, 0.189), matrices.SEPIA[2]);
}

test "filter from primitive builds a single-primitive graph" {
    const allocator = std.testing.allocator;
    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    defer filter.deinit(allocator);

    const graph = filter.graph.get();
    try std.testing.expectEqual(@as(usize, 1), graph.primitives.items.len);
    try std.testing.expectEqual(FilterId.new(0), graph.output);
    try std.testing.expectEqual(@as(u16, 1), graph.next_id);
    try std.testing.expectEqual(kurbo.Rect.new(-9.0, -9.0, 9.0, 9.0), graph.filter_expansion);
    try std.testing.expectEqual(kurbo.Rect.new(-9.0, -9.0, 9.0, 9.0), graph.source_expansion);
}

test "filter graph construction, defaults and expansion accumulation" {
    const allocator = std.testing.allocator;

    var graph = FilterGraph.new();
    defer graph.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), graph.primitives.items.len);
    try std.testing.expectEqual(FilterId.zero, graph.output);
    try std.testing.expectEqual(@as(u16, 0), graph.next_id);
    try std.testing.expectEqual(kurbo.Rect.ZERO, graph.filter_expansion);
    try std.testing.expectEqual(kurbo.Rect.ZERO, graph.source_expansion);

    const first = try graph.add(allocator, .{
        .gaussian_blur = .{ .std_deviation = 4.0, .edge_mode = .none },
    }, null);
    try std.testing.expectEqual(FilterId.new(0), first);
    try std.testing.expectEqual(@as(u16, 1), graph.next_id);
    try std.testing.expectEqual(kurbo.Rect.new(-12.0, -12.0, 12.0, 12.0), graph.filter_expansion);

    const second = try graph.add(allocator, .{ .offset = .{ .dx = 20.0, .dy = -30.0 } }, null);
    try std.testing.expectEqual(FilterId.new(1), second);
    graph.setOutput(second);
    try std.testing.expectEqual(FilterId.new(1), graph.output);
    // Filter expansion unions in the offset's (0, -30, 20, 0).
    try std.testing.expectEqual(kurbo.Rect.new(-12.0, -30.0, 20.0, 12.0), graph.filter_expansion);
    // Source expansion unions in the offset's (-20, 0, 0, 30).
    try std.testing.expectEqual(kurbo.Rect.new(-20.0, -12.0, 12.0, 30.0), graph.source_expansion);

    // Cached expansions transform with the linear part into device space.
    try std.testing.expectEqual(
        kurbo.Rect.new(-24.0, -60.0, 40.0, 24.0),
        graph.filterExpansion(kurbo.Affine.scale(2.0)),
    );
    try std.testing.expectEqual(
        kurbo.Rect.new(-40.0, -24.0, 24.0, 60.0),
        graph.sourceExpansion(kurbo.Affine.scale(2.0)),
    );
}

test "filter graph reports id exhaustion instead of overflowing" {
    const allocator = std.testing.allocator;

    var graph = FilterGraph.new();
    defer graph.deinit(allocator);
    graph.next_id = std.math.maxInt(u16);

    try std.testing.expectError(error.TooManyPrimitives, graph.add(allocator, .tile, null));
    try std.testing.expectEqual(@as(usize, 0), graph.primitives.items.len);
    try std.testing.expectEqual(std.math.maxInt(u16), graph.next_id);
}

test "filter graph clone is deep and equality compares contents" {
    const allocator = std.testing.allocator;

    var graph = FilterGraph.new();
    defer graph.deinit(allocator);
    _ = try graph.add(allocator, .{
        .convolve_matrix = .{
            .kernel = try ConvolutionKernel.init(
                allocator,
                3,
                &[_]f32{ 1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0 },
                16.0,
                0.0,
                false,
            ),
        },
    }, null);

    var copy = try graph.clone(allocator);
    defer copy.deinit(allocator);

    try std.testing.expect(graph.eql(copy));
    // Deep clone: the weight buffers are distinct.
    try std.testing.expect(graph.primitives.items[0].convolve_matrix.kernel.values.items.ptr !=
        copy.primitives.items[0].convolve_matrix.kernel.values.items.ptr);

    copy.primitives.items[0].convolve_matrix.kernel.values.items[0] = 5.0;
    try std.testing.expect(!graph.eql(copy));
}

test "filter from function maps blur and uses the default edge mode" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromFunction(allocator, .{ .blur = .{ .radius = 7.0 } });
    defer filter.deinit(allocator);

    const graph = filter.graph.get();
    try std.testing.expectEqual(@as(usize, 1), graph.primitives.items.len);
    try std.testing.expectEqual(FilterId.zero, graph.output);

    const primitive = graph.primitives.items[0];
    try std.testing.expectEqual(@as(f32, 7.0), primitive.gaussian_blur.std_deviation);
    try std.testing.expectEqual(EdgeMode.none, primitive.gaussian_blur.edge_mode);

    // Other functions are data-model-only, as upstream's `unimplemented!`.
    try std.testing.expectError(
        error.Unsupported,
        Filter.fromFunction(allocator, .{ .invert = .{ .amount = 1.0 } }),
    );
}

test "filter clone retains the shared graph" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{ .offset = .{ .dx = 2.0, .dy = 3.0 } });
    defer filter.deinit(allocator);

    const copy = filter.clone();
    defer copy.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), filter.graph.refCount());
    try std.testing.expect(filter.eql(copy));
    try std.testing.expect(shared.Shared(FilterGraph).ptrEq(filter.graph, copy.graph));
}

test "convolution kernel helpers own their weights" {
    const allocator = std.testing.allocator;

    var kernel = try kernels.gaussian3x3(allocator);
    defer kernel.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), kernel.size);
    try std.testing.expectEqual(@as(usize, 9), kernel.values.items.len);
    try std.testing.expectEqual(@as(f32, 4.0), kernel.values.items[4]);
    try std.testing.expectEqual(@as(f32, 16.0), kernel.divisor);
    try std.testing.expect(!kernel.preserve_alpha);

    var copy = try kernel.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expect(kernel.eql(copy));

    copy.values.items[0] = 99.0;
    try std.testing.expect(!kernel.eql(copy));

    var sharpen = try kernels.sharpen3x3(allocator);
    defer sharpen.deinit(allocator);
    try std.testing.expect(sharpen.preserve_alpha);
    try std.testing.expectEqual(@as(f32, 5.0), sharpen.values.items[4]);

    var edge = try kernels.edgeDetect3x3(allocator);
    defer edge.deinit(allocator);
    try std.testing.expectEqual(@as(f32, 8.0), edge.values.items[4]);

    var emboss = try kernels.emboss3x3(allocator);
    defer emboss.deinit(allocator);
    try std.testing.expectEqual(@as(f32, 0.5), emboss.bias);
    try std.testing.expectEqual(@as(f32, 2.0), emboss.values.items[8]);
}

test "transfer functions and composite operators compare by contents" {
    const allocator = std.testing.allocator;

    var table = try TransferFunction.initTable(allocator, &[_]f32{ 0.0, 1.0 });
    defer table.deinit(allocator);
    var table_copy = try table.clone(allocator);
    defer table_copy.deinit(allocator);
    try std.testing.expect(table.eql(table_copy));

    var discrete = try TransferFunction.initDiscrete(allocator, &[_]f32{ 0.0, 1.0 });
    defer discrete.deinit(allocator);
    try std.testing.expect(!table.eql(discrete));

    table.table.values.items[0] = 0.5;
    try std.testing.expect(!table.eql(table_copy));

    const arithmetic = CompositeOperator{ .arithmetic = .{ .k1 = 1.0, .k2 = 2.0, .k3 = 3.0, .k4 = 4.0 } };
    const arithmetic_same = CompositeOperator{ .arithmetic = .{ .k1 = 1.0, .k2 = 2.0, .k3 = 3.0, .k4 = 4.0 } };
    try std.testing.expect(arithmetic.eql(arithmetic_same));
    try std.testing.expect(!arithmetic.eql(CompositeOperator.in));

    // `component_transfer` owns its optional transfer functions.
    var primitive = FilterPrimitive{ .component_transfer = .{
        .red_function = try TransferFunction.initTable(allocator, &[_]f32{ 0.0, 1.0 }),
        .green_function = null,
        .blue_function = null,
        .alpha_function = TransferFunction{ .linear = .{ .slope = 2.0, .intercept = 1.0 } },
    } };
    defer primitive.deinit(allocator);

    var primitive_copy = try primitive.clone(allocator);
    defer primitive_copy.deinit(allocator);
    try std.testing.expect(primitive.eql(primitive_copy));
}

test "filter inputs connect sources and results" {
    const single = FilterInputs.single(.{ .source = .source_graphic });
    try std.testing.expectEqual(@as(?FilterInput, null), single.secondary);
    try std.testing.expectEqual(FilterInput{ .source = .source_graphic }, single.primary);

    const dual = FilterInputs.dual(
        .{ .source = .fill_paint },
        .{ .result = FilterId.new(3) },
    );
    try std.testing.expectEqual(FilterInput{ .result = FilterId.new(3) }, dual.secondary.?);
    try std.testing.expect(FilterInputs.eql(dual, dual));
    try std.testing.expect(!FilterInputs.eql(dual, single));

    try std.testing.expect(FilterId.eql(FilterId.new(3), FilterId.new(3)));
    try std.testing.expect(!FilterId.eql(FilterId.new(3), FilterId.zero));
}

test "filter effect deinit releases primitive payloads" {
    const allocator = std.testing.allocator;

    var effect = FilterEffect{ .primitive = .{ .component_transfer = .{
        .red_function = try TransferFunction.initTable(allocator, &[_]f32{ 0.0, 1.0 }),
        .green_function = null,
        .blue_function = null,
        .alpha_function = null,
    } } };
    effect.deinit(allocator);

    var function_effect = FilterEffect{ .function = .{ .blur = .{ .radius = 1.0 } } };
    function_effect.deinit(allocator);
}

test "light source equality follows the tag and payload" {
    const distant = LightSource{ .distant = .{ .azimuth = 45.0, .elevation = 30.0 } };
    const same = LightSource{ .distant = .{ .azimuth = 45.0, .elevation = 30.0 } };
    const other = LightSource{ .point = .{ .x = 1.0, .y = 2.0, .z = 3.0 } };

    try std.testing.expect(LightSource.eql(distant, same));
    try std.testing.expect(!LightSource.eql(distant, other));
}
