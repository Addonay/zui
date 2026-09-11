//! Port of the `peniko` 0.6.1 types used by Vello, on top of the `color` 0.3.3
//! subset.
//!
//! Upstream source: `peniko` 0.6.1 and `color` 0.3.3 (crates.io). `vello_common`
//! consumes these through `peniko::{...}`.
//!
//! Ownership:
//! - Color/geometry types are plain values (no allocator).
//! - `Gradient` owns its stops; `Image` carries a borrowed-or-owned image
//!   source. Font/brush resource handles follow the renderer's resource
//!   contract and are documented in `src/glifo`.

pub const color = @import("color.zig");
pub const rgba8 = @import("rgba8.zig");
pub const palette = @import("palette.zig");
pub const blend = @import("blend.zig");
pub const fill = @import("fill.zig");
pub const gradient = @import("gradient.zig");
pub const image = @import("image.zig");

pub const AlphaColor = color.AlphaColor;
pub const OpaqueColor = color.OpaqueColor;
pub const PremulColor = color.PremulColor;
pub const Color = color.Color;
pub const Srgb = color.Srgb;
pub const Rgba8 = rgba8.Rgba8;
pub const PremulRgba8 = rgba8.PremulRgba8;

pub const BlendMode = blend.BlendMode;
pub const Mix = blend.Mix;
pub const Compose = blend.Compose;
pub const Fill = fill.Fill;
pub const Extend = gradient.Extend;
pub const InterpolationAlphaSpace = gradient.InterpolationAlphaSpace;
pub const ColorStop = gradient.ColorStop;
pub const ColorStops = gradient.ColorStops;
pub const Gradient = gradient.Gradient;
pub const GradientKind = gradient.GradientKind;
pub const LinearGradientPosition = gradient.LinearGradientPosition;
pub const RadialGradientPosition = gradient.RadialGradientPosition;
pub const SweepGradientPosition = gradient.SweepGradientPosition;
pub const Image = image.Image;
pub const ImageBrush = image.ImageBrush;
pub const ImageData = image.ImageData;
pub const ImageSource = image.ImageSource;
pub const ImageSampler = image.ImageSampler;
pub const ImageAlphaType = image.ImageAlphaType;
pub const ImageFormat = image.ImageFormat;
pub const ImageQuality = image.ImageQuality;

test {
    // `refAllDecls` does not reliably force analysis of imported files in this
    // Zig version, so submodule tests are pulled in explicitly.
    _ = @import("color.zig");
    _ = @import("rgba8.zig");
    _ = @import("palette.zig");
    _ = @import("blend.zig");
    _ = @import("fill.zig");
    _ = @import("gradient.zig");
    _ = @import("image.zig");
}
