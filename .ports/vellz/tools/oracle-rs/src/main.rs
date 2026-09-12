//! vellz oracle driver.
//!
//! Renders a scene from the shared JSON corpus with the pinned upstream
//! `vello_cpu` and writes premultiplied RGBA8 pixels plus a metadata sidecar.
//! The Zig implementation consumes the same scene files through
//! `tools/vellz_cli`, so scene construction is shared rather than re-created.
//!
//! `--dump-glyphs` and `--dump-cmap` are the ground truth for the M3 `glifo`
//! port: they emit the exact `skrifa 0.44.0` outline path elements (f32 bit
//! patterns) and cmap mappings that `glifo 0.3.0` caches, so the Zig side can
//! be byte-compared without rasterizing. `--dump-decoration` prints the
//! skip-ink rectangles of a `glyph_run` scene's `decoration` (f64 bit
//! patterns), the ground truth for the Zig decoration port.
//!
//! This binary is development tooling. It is not distributed with the package.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use serde::Deserialize;
use skrifa::MetadataProvider as _;
use skrifa::instance::Size as SkrifaSize;
use skrifa::outline::pen::PathElement;
use skrifa::outline::{
    DrawSettings as SkrifaDrawSettings, Engine as SkrifaEngine, HintingInstance, HintingOptions,
    SmoothMode as SkrifaSmoothMode, Target as SkrifaTarget,
};
use vello_cpu::color::{AlphaColor, Srgb};
use vello_cpu::filter_effects::{EdgeMode, Filter, FilterPrimitive};
use vello_cpu::kurbo::{Affine, BezPath, Cap, Join, Point, Rect, Stroke};
use vello_cpu::peniko::{
    BlendMode, Blob, ColorStop, ColorStops, Compose, Extend, Fill, FontData, Gradient,
    ImageAlphaType, ImageQuality, ImageSampler, LinearGradientPosition, Mix,
    RadialGradientPosition, SweepGradientPosition,
};
use vello_cpu::{
    Glyph, Image, ImageSource, Level, Mask, PaintType, PixelFormat, PixelMetadata, Pixmap,
    RasterizerSettings, RenderContext, RenderMode, RenderSettings, TargetInit,
};

#[derive(Debug, Deserialize)]
struct Scene {
    #[serde(default = "default_version")]
    version: u32,
    width: u16,
    height: u16,
    #[serde(default)]
    settings: Settings,
    #[serde(default)]
    target_init: TargetInitSpec,
    #[serde(default)]
    commands: Vec<Command>,
}

fn default_version() -> u32 {
    1
}

#[derive(Debug, Default, Deserialize)]
struct Settings {
    /// "quality" (f32 pipeline) or "speed" (u8 pipeline). Defaults to quality
    /// so oracle output does not depend on integer-pipeline quantization.
    #[serde(default)]
    mode: Option<String>,
    /// Additional renderer threads. Defaults to 0 (single-threaded).
    #[serde(default)]
    threads: Option<u16>,
    /// "fallback" (scalar/portable SIMD) or "native" (runtime-dispatched SIMD).
    #[serde(default)]
    level: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TargetInitSpec {
    /// Transparent clear (upstream default).
    #[default]
    Clear,
    /// Composite over existing (undefined) target contents.
    SrcOver,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Command {
    SetTransform {
        affine: [f64; 6],
    },
    ResetTransform,
    SetPaintTransform {
        affine: [f64; 6],
    },
    ResetPaintTransform,
    /// One of solid `rgba8`, `gradient` or `image` (exactly one).
    SetPaint(PaintSpec),
    SetFillRule {
        rule: String,
    },
    SetStroke {
        width: f64,
        #[serde(default)]
        join: Option<String>,
        #[serde(default)]
        start_cap: Option<String>,
        #[serde(default)]
        end_cap: Option<String>,
        #[serde(default)]
        miter_limit: Option<f64>,
        #[serde(default)]
        dash: Option<Vec<f64>>,
        #[serde(default)]
        dash_offset: Option<f64>,
    },
    SetAliasingThreshold {
        value: Option<u8>,
    },
    FillRect {
        rect: [f64; 4],
    },
    StrokeRect {
        rect: [f64; 4],
    },
    /// Analytic blurred rounded rectangle (inset shadow when `invert`).
    FillBlurredRoundedRect {
        rect: [f64; 4],
        radius: f32,
        std_dev: f32,
        #[serde(default)]
        invert: bool,
    },
    FillPath {
        path: String,
    },
    StrokePath {
        path: String,
    },
    PushClipPath {
        path: String,
    },
    PopClipPath,
    PushClipLayer {
        path: String,
    },
    /// Generic layer: clip, blend, opacity or mask.
    PushLayer(LayerSpec),
    PopLayer,
    /// Set a paint-level filter; wraps each subsequent draw in a filter layer.
    SetFilterEffect { filter: FilterSpec },
    /// Clear the paint-level filter.
    ResetFilterEffect,
    /// Draw an explicitly positioned glyph run through the `glifo` stack.
    GlyphRun(GlyphRunSpec),
    Reset,
}

/// Font asset for a positioned glyph run.
#[derive(Debug, Deserialize)]
struct FontSpec {
    /// Path relative to the scene file's directory.
    asset: String,
    #[serde(default)]
    index: u32,
}

/// One positioned glyph: font glyph id plus run-space position.
#[derive(Debug, Deserialize)]
struct PositionedGlyphSpec {
    id: u32,
    x: f32,
    y: f32,
}

/// Decoration placement (T5); parsed so scenes that request it fail loudly.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct DecorationSpec {
    x_range: [f32; 2],
    baseline_y: f32,
    offset: f32,
    size: f32,
    buffer: f32,
}

fn default_hint() -> bool {
    true
}

/// A positioned glyph run drawn through the `glifo` stack.
#[derive(Debug, Deserialize)]
struct GlyphRunSpec {
    font: FontSpec,
    font_size: f32,
    #[serde(default = "default_hint")]
    hint: bool,
    #[serde(default)]
    glyph_transform: Option<[f64; 6]>,
    #[serde(default)]
    embolden: Option<[f32; 2]>,
    #[serde(default)]
    normalized_coords: Option<Vec<i16>>,
    #[serde(default)]
    atlas_cache: bool,
    /// "fill" (default) or "stroke".
    #[serde(default)]
    style: Option<String>,
    glyphs: Vec<PositionedGlyphSpec>,
    #[serde(default)]
    decoration: Option<DecorationSpec>,
}

/// `set_paint` payload; exactly one variant must be present.
#[derive(Debug, Deserialize)]
struct PaintSpec {
    #[serde(default)]
    rgba8: Option<[u8; 4]>,
    #[serde(default)]
    gradient: Option<GradientSpec>,
    #[serde(default)]
    image: Option<ImageSpec>,
}

#[derive(Debug, Deserialize)]
struct GradientSpec {
    kind: GradientKindSpec,
    stops: Vec<ColorStopSpec>,
    extend: ExtendSpec,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum GradientKindSpec {
    Linear {
        start: [f64; 2],
        end: [f64; 2],
    },
    Radial {
        start_center: [f64; 2],
        start_radius: f32,
        end_center: [f64; 2],
        end_radius: f32,
    },
    Sweep {
        center: [f64; 2],
        start_angle: f32,
        end_angle: f32,
    },
}

#[derive(Debug, Deserialize)]
struct ColorStopSpec {
    offset: f32,
    rgba8: [u8; 4],
}

#[derive(Debug, Deserialize)]
struct ImageSpec {
    /// Path relative to the scene file's directory.
    asset: String,
    width: u16,
    height: u16,
    format: FormatSpec,
    alpha_type: AlphaTypeSpec,
    sampler: SamplerSpec,
}

#[derive(Debug, Deserialize)]
struct SamplerSpec {
    x_extend: ExtendSpec,
    y_extend: ExtendSpec,
    quality: QualitySpec,
    alpha: f32,
}

#[derive(Debug, Deserialize)]
struct MaskSpec {
    /// Path relative to the scene file's directory.
    asset: String,
    width: u16,
    height: u16,
    format: FormatSpec,
    alpha_type: AlphaTypeSpec,
    kind: MaskKindSpec,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum LayerSpec {
    Clip { path: String },
    Blend { blend: BlendSpec },
    Opacity { opacity: f32 },
    Mask { mask: MaskSpec },
    Filter {
        filter: FilterSpec,
        #[serde(default)]
        clip: Option<String>,
        #[serde(default)]
        blend: Option<BlendSpec>,
        #[serde(default)]
        opacity: Option<f32>,
        #[serde(default)]
        mask: Option<MaskSpec>,
    },
}

/// A single-primitive filter (upstream supports no other graphs yet).
#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum FilterSpec {
    Flood {
        rgba8: [u8; 4],
    },
    GaussianBlur {
        std_deviation: f32,
        #[serde(default)]
        edge_mode: EdgeModeSpec,
    },
    Offset {
        dx: f32,
        dy: f32,
    },
    DropShadow {
        dx: f32,
        dy: f32,
        std_deviation: f32,
        rgba8: [u8; 4],
        #[serde(default)]
        edge_mode: EdgeModeSpec,
    },
    DropShadowOnly {
        dx: f32,
        dy: f32,
        std_deviation: f32,
        rgba8: [u8; 4],
        #[serde(default)]
        edge_mode: EdgeModeSpec,
    },
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EdgeModeSpec {
    Duplicate,
    Wrap,
    Mirror,
    #[default]
    None,
}

impl From<EdgeModeSpec> for EdgeMode {
    fn from(spec: EdgeModeSpec) -> Self {
        match spec {
            EdgeModeSpec::Duplicate => Self::Duplicate,
            EdgeModeSpec::Wrap => Self::Wrap,
            EdgeModeSpec::Mirror => Self::Mirror,
            EdgeModeSpec::None => Self::None,
        }
    }
}

#[derive(Debug, Deserialize)]
struct BlendSpec {
    mix: MixSpec,
    compose: ComposeSpec,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExtendSpec {
    Pad,
    Repeat,
    Reflect,
}

impl From<ExtendSpec> for Extend {
    fn from(spec: ExtendSpec) -> Self {
        match spec {
            ExtendSpec::Pad => Self::Pad,
            ExtendSpec::Repeat => Self::Repeat,
            ExtendSpec::Reflect => Self::Reflect,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum QualitySpec {
    Low,
    Medium,
    High,
}

impl From<QualitySpec> for ImageQuality {
    fn from(spec: QualitySpec) -> Self {
        match spec {
            QualitySpec::Low => Self::Low,
            QualitySpec::Medium => Self::Medium,
            QualitySpec::High => Self::High,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FormatSpec {
    Rgba8,
    Bgra8,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AlphaTypeSpec {
    Alpha,
    Premultiplied,
}

impl From<AlphaTypeSpec> for ImageAlphaType {
    fn from(spec: AlphaTypeSpec) -> Self {
        match spec {
            AlphaTypeSpec::Alpha => Self::Alpha,
            AlphaTypeSpec::Premultiplied => Self::AlphaPremultiplied,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MaskKindSpec {
    Alpha,
    Luminance,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MixSpec {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
}

impl From<MixSpec> for Mix {
    fn from(spec: MixSpec) -> Self {
        match spec {
            MixSpec::Normal => Self::Normal,
            MixSpec::Multiply => Self::Multiply,
            MixSpec::Screen => Self::Screen,
            MixSpec::Overlay => Self::Overlay,
            MixSpec::Darken => Self::Darken,
            MixSpec::Lighten => Self::Lighten,
            MixSpec::ColorDodge => Self::ColorDodge,
            MixSpec::ColorBurn => Self::ColorBurn,
            MixSpec::HardLight => Self::HardLight,
            MixSpec::SoftLight => Self::SoftLight,
            MixSpec::Difference => Self::Difference,
            MixSpec::Exclusion => Self::Exclusion,
            MixSpec::Hue => Self::Hue,
            MixSpec::Saturation => Self::Saturation,
            MixSpec::Color => Self::Color,
            MixSpec::Luminosity => Self::Luminosity,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ComposeSpec {
    Clear,
    Copy,
    Dest,
    SrcOver,
    DestOver,
    SrcIn,
    DestIn,
    SrcOut,
    DestOut,
    SrcAtop,
    DestAtop,
    Xor,
    Plus,
    PlusLighter,
}

impl From<ComposeSpec> for Compose {
    fn from(spec: ComposeSpec) -> Self {
        match spec {
            ComposeSpec::Clear => Self::Clear,
            ComposeSpec::Copy => Self::Copy,
            ComposeSpec::Dest => Self::Dest,
            ComposeSpec::SrcOver => Self::SrcOver,
            ComposeSpec::DestOver => Self::DestOver,
            ComposeSpec::SrcIn => Self::SrcIn,
            ComposeSpec::DestIn => Self::DestIn,
            ComposeSpec::SrcOut => Self::SrcOut,
            ComposeSpec::DestOut => Self::DestOut,
            ComposeSpec::SrcAtop => Self::SrcAtop,
            ComposeSpec::DestAtop => Self::DestAtop,
            ComposeSpec::Xor => Self::Xor,
            ComposeSpec::Plus => Self::Plus,
            ComposeSpec::PlusLighter => Self::PlusLighter,
        }
    }
}

fn parse_affine(a: [f64; 6]) -> Affine {
    Affine::new(a)
}

fn parse_join(name: &str) -> Join {
    match name {
        "miter" => Join::Miter,
        "round" => Join::Round,
        "bevel" => Join::Bevel,
        other => panic!("unknown join {other:?}"),
    }
}

fn parse_cap(name: &str) -> Cap {
    match name {
        "butt" => Cap::Butt,
        "round" => Cap::Round,
        "square" => Cap::Square,
        other => panic!("unknown cap {other:?}"),
    }
}

fn parse_path(svg: &str) -> BezPath {
    BezPath::from_svg(svg).expect("invalid path data in scene")
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("vellz-oracle: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match argv.first().map(String::as_str) {
        Some("--dump-glyphs") => return dump_glyphs(&argv[1..]),
        Some("--dump-cmap") => return dump_cmap(&argv[1..]),
        Some("--dump-decoration") => return dump_decoration(&argv[1..]),
        _ => {}
    }

    let mut scene_path: Option<PathBuf> = None;
    let mut out_path: Option<PathBuf> = None;
    let mut write_png = false;

    let mut args = argv.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--scene" => scene_path = Some(args.next().ok_or("--scene needs a value")?.into()),
            "--out" => out_path = Some(args.next().ok_or("--out needs a value")?.into()),
            "--png" => write_png = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let scene_path = scene_path.ok_or("missing --scene PATH")?;
    let out_path = out_path.ok_or("missing --out PATH")?;

    let scene_text = std::fs::read_to_string(&scene_path)
        .map_err(|e| format!("reading {}: {e}", scene_path.display()))?;
    let scene: Scene = serde_json::from_str(&scene_text)
        .map_err(|e| format!("parsing {}: {e}", scene_path.display()))?;

    if scene.version != 1 {
        return Err(format!("unsupported scene version {}", scene.version));
    }

    // `asset` paths are relative to the scene file's directory.
    let scene_dir = match scene_path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };

    let mode = match scene.settings.mode.as_deref() {
        None | Some("quality") => RenderMode::OptimizeQuality,
        Some("speed") => RenderMode::OptimizeSpeed,
        Some(other) => return Err(format!("unknown mode {other:?}")),
    };
    let level = match scene.settings.level.as_deref() {
        None | Some("fallback") => Level::fallback(),
        Some("native") => Level::new(),
        Some(other) => return Err(format!("unknown level {other:?}")),
    };
    let threads = scene.settings.threads.unwrap_or(0);

    let render_settings = RenderSettings {
        level,
        num_threads: threads,
    };
    let rasterizer_settings = RasterizerSettings {
        render_mode: mode,
        target_init: match scene.target_init {
            TargetInitSpec::Clear => TargetInit::Clear(AlphaColor::<Srgb>::TRANSPARENT),
            TargetInitSpec::SrcOver => TargetInit::SrcOver,
        },
        pixel_format: PixelFormat::Rgba8,
        offset: (0, 0),
    };

    let mut ctx = RenderContext::new_with(scene.width, scene.height, render_settings);
    let mut resources = vello_cpu::Resources::new();
    // Font blobs are cached per scene so repeated runs share one `FontData`
    // id and glyph atlas cache entries.
    let mut font_cache: HashMap<(PathBuf, u32), FontData> = HashMap::new();

    for command in &scene.commands {
        match command {
            Command::SetTransform { affine } => ctx.set_transform(parse_affine(*affine)),
            Command::ResetTransform => ctx.reset_transform(),
            Command::SetPaintTransform { affine } => ctx.set_paint_transform(parse_affine(*affine)),
            Command::ResetPaintTransform => ctx.reset_paint_transform(),
            Command::SetPaint(spec) => ctx.set_paint(build_paint(spec, scene_dir)?),
            Command::SetFillRule { rule } => match rule.as_str() {
                "nonzero" => ctx.set_fill_rule(Fill::NonZero),
                "evenodd" => ctx.set_fill_rule(Fill::EvenOdd),
                other => return Err(format!("unknown fill rule {other:?}")),
            },
            Command::SetStroke {
                width,
                join,
                start_cap,
                end_cap,
                miter_limit,
                dash,
                dash_offset,
            } => {
                let mut stroke = Stroke::new(*width);
                if let Some(join) = join {
                    stroke = stroke.with_join(parse_join(join));
                }
                if let Some(cap) = start_cap {
                    stroke = stroke.with_start_cap(parse_cap(cap));
                }
                if let Some(cap) = end_cap {
                    stroke = stroke.with_end_cap(parse_cap(cap));
                }
                if let Some(limit) = miter_limit {
                    stroke = stroke.with_miter_limit(*limit);
                }
                if let Some(dash) = dash {
                    stroke = stroke.with_dashes(dash_offset.unwrap_or(0.0), dash.clone());
                }
                ctx.set_stroke(stroke);
            }
            Command::SetAliasingThreshold { value } => ctx.set_aliasing_threshold(*value),
            Command::FillRect { rect } => {
                ctx.fill_rect(&Rect::new(rect[0], rect[1], rect[2], rect[3]));
            }
            Command::StrokeRect { rect } => {
                ctx.stroke_rect(&Rect::new(rect[0], rect[1], rect[2], rect[3]));
            }
            Command::FillBlurredRoundedRect {
                rect,
                radius,
                std_dev,
                invert,
            } => {
                ctx.fill_blurred_rounded_rect(
                    &Rect::new(rect[0], rect[1], rect[2], rect[3]),
                    *radius,
                    *std_dev,
                    *invert,
                );
            }
            Command::FillPath { path } => ctx.fill_path(&parse_path(path)),
            Command::StrokePath { path } => ctx.stroke_path(&parse_path(path)),
            Command::PushClipPath { path } => ctx.push_clip_path(&parse_path(path)),
            Command::PopClipPath => ctx.pop_clip_path(),
            Command::PushClipLayer { path } => ctx.push_clip_layer(&parse_path(path)),
            Command::PushLayer(layer) => match layer {
                LayerSpec::Clip { path } => ctx.push_clip_layer(&parse_path(path)),
                LayerSpec::Blend { blend } => ctx.push_layer(
                    None,
                    Some(BlendMode {
                        mix: blend.mix.into(),
                        compose: blend.compose.into(),
                    }),
                    None,
                    None,
                    None,
                ),
                LayerSpec::Opacity { opacity } => {
                    ctx.push_layer(None, None, Some(*opacity), None, None);
                }
                LayerSpec::Mask { mask } => {
                    // `vello_cpu` ignores masks whose size differs from the
                    // context, so resample mask assets to the target size
                    // (nearest neighbor; see tests/scenes/assets/README.md).
                    let mask = load_mask(mask, scene_dir, scene.width, scene.height)?;
                    ctx.push_layer(None, None, None, Some(mask), None);
                }
                LayerSpec::Filter {
                    filter,
                    clip,
                    blend,
                    opacity,
                    mask,
                } => {
                    let clip_path = clip.as_deref().map(parse_path);
                    let blend = blend.as_ref().map(|blend| BlendMode {
                        mix: blend.mix.into(),
                        compose: blend.compose.into(),
                    });
                    let mask = mask
                        .as_ref()
                        .map(|mask| load_mask(mask, scene_dir, scene.width, scene.height))
                        .transpose()?;
                    ctx.push_layer(
                        clip_path.as_ref(),
                        blend,
                        *opacity,
                        mask,
                        Some(build_filter(filter)),
                    );
                }
            },
            Command::PopLayer => ctx.pop_layer(),
            Command::SetFilterEffect { filter } => ctx.set_filter_effect(build_filter(filter)),
            Command::ResetFilterEffect => ctx.reset_filter_effect(),
            Command::GlyphRun(spec) => {
                draw_glyph_run(&mut ctx, &mut resources, scene_dir, spec, &mut font_cache)?
            }
            Command::Reset => ctx.reset(),
        }
    }

    ctx.flush();
    let mut pixmap = Pixmap::new(scene.width, scene.height);
    ctx.render_with(&mut pixmap, &mut resources, rasterizer_settings);

    let pixels = pixmap.data_as_u8_slice();
    let expected = usize::from(scene.width) * usize::from(scene.height) * 4;
    assert_eq!(pixels.len(), expected, "unexpected pixmap size");

    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("creating {}: {e}", parent.display()))?;
        }
    }
    std::fs::write(&out_path, pixels)
        .map_err(|e| format!("writing {}: {e}", out_path.display()))?;
    if write_png {
        let png = pixmap
            .clone()
            .into_png()
            .map_err(|e| format!("encoding png: {e}"))?;
        let png_path = out_path.with_extension("png");
        std::fs::write(&png_path, png)
            .map_err(|e| format!("writing {}: {e}", png_path.display()))?;
    }

    let scene_hash = fnv1a(scene_text.as_bytes());
    let output_hash = fnv1a(pixels);
    let meta = serde_json::json!({
        "oracle": "vellz-oracle 0.1.0",
        "vello_cpu": "0.2.0",
        "vello_rev": "1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7",
        "width": scene.width,
        "height": scene.height,
        "pixel_format": "rgba8-premultiplied-srgb",
        "render_mode": match mode { RenderMode::OptimizeQuality => "quality", RenderMode::OptimizeSpeed => "speed" },
        "level": match scene.settings.level.as_deref() { None => "fallback", Some(l) => l },
        "threads": threads,
        "scene_fnv1a": format!("{scene_hash:016x}"),
        "output_fnv1a": format!("{output_hash:016x}"),
    });
    let meta_path = out_path.with_extension("json");
    std::fs::write(&meta_path, serde_json::to_string_pretty(&meta).unwrap())
        .map_err(|e| format!("writing {}: {e}", meta_path.display()))?;

    println!(
        "ok {}x{} bytes={expected} fnv1a={output_hash:016x} scene_fnv1a={scene_hash:016x}",
        scene.width, scene.height
    );
    Ok(())
}

/// TrueType point/path dumps for the M3 `glifo` port.
///
/// The text format is versioned and canonical: one f32 per coordinate printed
/// as its raw bit pattern in lowercase hex, so the Zig side can be compared
/// byte-for-byte without any float formatting.
///
/// `--dump-glyphs --font PATH [--index N] [--hint] --size PPEM --gids 1,3,5-9`
///   emits `skrifa`'s `PathStyle::FreeType` path elements plus the adjusted
///   lsb/advance from the same draw. Without `--hint` this is exactly the call
///   `glifo`'s `OutlineCache` makes for an unhinted run; with `--hint` it uses
///   the same `HintingInstance`/`HintingOptions` glifo builds for a hinted
///   run and adds a `hint 1` marker line.
///
/// `--dump-cmap --font PATH [--index N] --codepoints 65,66,0x1F600`
///   emits the selected cmap subtable's mappings (skrifa's selection strategy,
///   preferring symbol then full-repertoire subtables).
fn dump_glyphs(args: &[String]) -> Result<(), String> {
    let parsed = parse_dump_args(args, true, "gid")?;
    let size = parsed.size.ok_or("missing --size PPEM")?;
    let data = std::fs::read(&parsed.font)
        .map_err(|e| format!("reading {}: {e}", parsed.font.display()))?;
    let font = skrifa::FontRef::from_index(&data, parsed.index)
        .map_err(|e| format!("loading {}[{}]: {e}", parsed.font.display(), parsed.index))?;
    let outlines = font.outline_glyphs();
    let mut out = String::new();
    out.push_str("vellz-glyph-dump v1\n");
    out.push_str(&format!("face {}\n", parsed.index));
    out.push_str(&format!("size {:08x}\n", size.to_bits()));
    if parsed.hint {
        out.push_str("hint 1\n");
    }
    // The same configuration glifo 0.3.0 uses for hinted runs.
    let hinting_options = HintingOptions {
        engine: SkrifaEngine::AutoFallback,
        target: SkrifaTarget::Smooth {
            mode: SkrifaSmoothMode::Lcd,
            symmetric_rendering: false,
            preserve_linear_metrics: true,
        },
    };
    let hinting_instance = if parsed.hint {
        Some(
            HintingInstance::new(
                &outlines,
                SkrifaSize::new(size),
                skrifa::instance::LocationRef::default(),
                hinting_options,
            )
            .map_err(|e| format!("configuring hinting at size {size}: {e}"))?,
        )
    } else {
        None
    };
    for gid in parsed.ids {
        let glyph = outlines
            .get(skrifa::GlyphId::new(gid))
            .ok_or_else(|| format!("glyph {gid} is not present"))?;
        let format = match glyph.format() {
            skrifa::outline::OutlineGlyphFormat::Glyf => "glyf",
            skrifa::outline::OutlineGlyphFormat::Cff => "cff",
            skrifa::outline::OutlineGlyphFormat::Cff2 => "cff2",
            skrifa::outline::OutlineGlyphFormat::Varc => "varc",
        };
        let mut elements: Vec<PathElement> = Vec::new();
        let settings = match &hinting_instance {
            Some(instance) => SkrifaDrawSettings::hinted(instance, false),
            None => SkrifaDrawSettings::unhinted(
                SkrifaSize::new(size),
                skrifa::instance::LocationRef::default(),
            ),
        };
        let metrics = glyph
            .draw(settings, &mut elements)
            .map_err(|e| format!("drawing glyph {gid}: {e}"))?;
        out.push_str(&format!(
            "gid {gid} format {format} elems {} lsb {} advance {}\n",
            elements.len(),
            format_opt_f32(metrics.lsb),
            format_opt_f32(metrics.advance_width),
        ));
        for el in &elements {
            match el {
                PathElement::MoveTo { x, y } => {
                    out.push_str(&format!("M {:08x} {:08x}\n", x.to_bits(), y.to_bits()));
                }
                PathElement::LineTo { x, y } => {
                    out.push_str(&format!("L {:08x} {:08x}\n", x.to_bits(), y.to_bits()));
                }
                PathElement::QuadTo { cx0, cy0, x, y } => {
                    out.push_str(&format!(
                        "Q {:08x} {:08x} {:08x} {:08x}\n",
                        cx0.to_bits(),
                        cy0.to_bits(),
                        x.to_bits(),
                        y.to_bits(),
                    ));
                }
                PathElement::CurveTo {
                    cx0,
                    cy0,
                    cx1,
                    cy1,
                    x,
                    y,
                } => {
                    out.push_str(&format!(
                        "C {:08x} {:08x} {:08x} {:08x} {:08x} {:08x}\n",
                        cx0.to_bits(),
                        cy0.to_bits(),
                        cx1.to_bits(),
                        cy1.to_bits(),
                        x.to_bits(),
                        y.to_bits(),
                    ));
                }
                PathElement::Close => out.push_str("Z\n"),
            }
        }
    }
    out.push_str("end\n");
    print!("{out}");
    Ok(())
}

/// cmap dump companion to [`dump_glyphs`].
fn dump_cmap(args: &[String]) -> Result<(), String> {
    let parsed = parse_dump_args(args, false, "codepoint")?;
    let data = std::fs::read(&parsed.font)
        .map_err(|e| format!("reading {}: {e}", parsed.font.display()))?;
    let font = skrifa::FontRef::from_index(&data, parsed.index)
        .map_err(|e| format!("loading {}[{}]: {e}", parsed.font.display(), parsed.index))?;
    let charmap = font.charmap();
    let mut out = String::new();
    out.push_str("vellz-cmap-dump v1\n");
    out.push_str(&format!("face {}\n", parsed.index));
    out.push_str(&format!(
        "has_map {} is_symbol {}\n",
        u8::from(charmap.has_map()),
        u8::from(charmap.is_symbol()),
    ));
    for cp in parsed.ids {
        match charmap.map(cp) {
            Some(gid) => out.push_str(&format!("cp {cp} gid {}\n", gid.to_u32())),
            None => out.push_str(&format!("cp {cp} gid none\n")),
        }
    }
    out.push_str("end\n");
    print!("{out}");
    Ok(())
}

fn format_opt_f32(value: Option<f32>) -> String {
    match value {
        Some(value) => format!("{:08x}", value.to_bits()),
        None => "none".to_string(),
    }
}

struct DumpArgs {
    font: PathBuf,
    index: u32,
    size: Option<f32>,
    ids: Vec<u32>,
    hint: bool,
}

/// Parses the shared `--dump-glyphs`/`--dump-cmap` arguments.
fn parse_dump_args(args: &[String], want_size: bool, what: &str) -> Result<DumpArgs, String> {
    let mut font: Option<PathBuf> = None;
    let mut index: u32 = 0;
    let mut size: Option<f32> = None;
    let mut ids: Vec<u32> = Vec::new();
    let mut hint = false;
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "--font" => {
                let value = args.get(i + 1).ok_or("--font needs a value")?;
                font = Some(PathBuf::from(value));
                i += 2;
            }
            "--index" => {
                let value = args.get(i + 1).ok_or("--index needs a value")?;
                index = value
                    .parse()
                    .map_err(|_| format!("--index must be an integer, got {value:?}"))?;
                i += 2;
            }
            "--size" => {
                let value = args.get(i + 1).ok_or("--size needs a value")?;
                size = Some(
                    value
                        .parse()
                        .map_err(|_| format!("--size must be a number, got {value:?}"))?,
                );
                i += 2;
            }
            "--hint" => {
                hint = true;
                i += 1;
            }
            "--gids" | "--codepoints" => {
                let value = args.get(i + 1).ok_or("list argument needs a value")?;
                ids.extend(parse_id_list(value, what)?);
                i += 2;
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let font = font.ok_or("missing --font PATH")?;
    if want_size && size.is_none() {
        return Err("missing --size PPEM".to_string());
    }
    Ok(DumpArgs {
        font,
        index,
        size,
        ids,
        hint,
    })
}

/// Parses `1,3,5-9` into `[1, 3, 5, 6, 7, 8, 9]`.
fn parse_id_list(spec: &str, what: &str) -> Result<Vec<u32>, String> {
    let mut ids = Vec::new();
    for part in spec.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((start, end)) = part.split_once('-') {
            let start: u32 = parse_u32(start.trim())
                .ok_or_else(|| format!("invalid {what} range start in {part:?}"))?;
            let end: u32 = parse_u32(end.trim())
                .ok_or_else(|| format!("invalid {what} range end in {part:?}"))?;
            if end < start {
                return Err(format!("invalid {what} range {part:?}"));
            }
            ids.extend(start..=end);
        } else {
            ids.push(parse_u32(part).ok_or_else(|| format!("invalid {what} {part:?}"))?);
        }
    }
    Ok(ids)
}

/// Parses decimal or `0x`-prefixed hex.
fn parse_u32(value: &str) -> Option<u32> {
    match value.strip_prefix("0x").or_else(|| value.strip_prefix("0X")) {
        Some(hex) => u32::from_str_radix(hex, 16).ok(),
        None => value.parse().ok(),
    }
}

/// Builds the current paint from a `set_paint` payload.
fn build_paint(spec: &PaintSpec, scene_dir: &Path) -> Result<PaintType, String> {
    let variants = usize::from(spec.rgba8.is_some())
        + usize::from(spec.gradient.is_some())
        + usize::from(spec.image.is_some());
    if variants != 1 {
        return Err("set_paint needs exactly one of rgba8, gradient, image".into());
    }
    if let Some(rgba8) = spec.rgba8 {
        let color = AlphaColor::<Srgb>::from_rgba8(rgba8[0], rgba8[1], rgba8[2], rgba8[3]);
        return Ok(color.into());
    }
    if let Some(gradient) = &spec.gradient {
        return Ok(build_gradient(gradient)?.into());
    }
    let image = spec.image.as_ref().expect("checked above");
    Ok(load_image(image, scene_dir)?.into())
}

/// Draw one positioned glyph run through the pinned upstream `glifo` stack.
///
/// Deferred features (`embolden`, `normalized_coords`) are hard errors so a
/// scene can never silently drop them. `decoration` draws after the
/// fill/stroke pass, like the upstream decoration tests.
fn draw_glyph_run(
    ctx: &mut RenderContext,
    resources: &mut vello_cpu::Resources,
    scene_dir: &Path,
    spec: &GlyphRunSpec,
    font_cache: &mut HashMap<(PathBuf, u32), FontData>,
) -> Result<(), String> {
    if let Some(embolden) = spec.embolden
        && (embolden[0] != 0.0 || embolden[1] != 0.0)
    {
        return Err("glyph_run embolden is not ported yet (error.Unsupported)".into());
    }
    if let Some(coords) = &spec.normalized_coords
        && !coords.is_empty()
    {
        return Err("glyph_run normalized_coords are not supported (gvar deferred)".into());
    }

    let font = load_font(scene_dir, &spec.font, font_cache)?;
    let mut builder = ctx
        .glyph_run(resources, &font)
        .font_size(spec.font_size)
        .hint(spec.hint)
        .atlas_cache(spec.atlas_cache);
    if let Some(transform) = spec.glyph_transform {
        builder = builder.glyph_transform(parse_affine(transform));
    }

    let glyphs: Vec<Glyph> = spec
        .glyphs
        .iter()
        .map(|glyph| Glyph {
            id: glyph.id,
            x: glyph.x,
            y: glyph.y,
        })
        .collect();

    match spec.style.as_deref() {
        None | Some("fill") => builder.fill_glyphs(glyphs.clone().into_iter()),
        Some("stroke") => builder.stroke_glyphs(glyphs.clone().into_iter()),
        Some(other) => return Err(format!("unknown glyph_run style {other:?}")),
    }

    if let Some(decoration) = &spec.decoration {
        let mut deco_builder = ctx
            .glyph_run(resources, &font)
            .font_size(spec.font_size)
            .hint(spec.hint)
            .atlas_cache(spec.atlas_cache);
        if let Some(transform) = spec.glyph_transform {
            deco_builder = deco_builder.glyph_transform(parse_affine(transform));
        }
        deco_builder.render_decoration(
            glyphs.into_iter(),
            decoration.x_range[0]..=decoration.x_range[1],
            decoration.baseline_y,
            decoration.offset,
            decoration.size,
            decoration.buffer,
        );
    }
    Ok(())
}

/// Recording `DrawSink` for `--dump-decoration`.
struct DecorationDumpSink {
    width: u16,
    height: u16,
    rects: Vec<Rect>,
}

impl glifo::DrawSink for DecorationDumpSink {
    fn set_transform(&mut self, _t: Affine) {}
    fn set_paint(&mut self, _paint: glifo::AtlasPaint) {}
    fn set_paint_transform(&mut self, _t: Affine) {}
    fn fill_path(&mut self, _path: &BezPath) {}
    fn fill_rect(&mut self, rect: &Rect) {
        self.rects.push(*rect);
    }
    fn push_clip_layer(&mut self, _clip: &BezPath) {}
    fn push_blend_layer(&mut self, _blend_mode: BlendMode) {}
    fn pop_layer(&mut self) {}
    fn width(&self) -> u16 {
        self.width
    }
    fn height(&self) -> u16 {
        self.height
    }
}

/// Backend that routes `render_decoration` into a [`DecorationDumpSink`],
/// bypassing the pixel renderer.
struct DecorationDumpBackend<'a> {
    sink: &'a mut DecorationDumpSink,
    prep: glifo::GlyphPrepCache,
}

impl<'a> glifo::GlyphRunBackend<'a> for DecorationDumpBackend<'a> {
    fn atlas_cache(self, _enabled: bool) -> Self {
        self
    }

    fn fill_glyphs<Glyphs>(self, _run: glifo::GlyphRun<'a>, _glyphs: Glyphs)
    where
        Glyphs: Iterator<Item = glifo::Glyph> + Clone,
    {
    }

    fn stroke_glyphs<Glyphs>(self, _run: glifo::GlyphRun<'a>, _glyphs: Glyphs)
    where
        Glyphs: Iterator<Item = glifo::Glyph> + Clone,
    {
    }

    fn render_decoration<Glyphs>(
        mut self,
        run: glifo::GlyphRun<'a>,
        glyphs: Glyphs,
        x_range: std::ops::RangeInclusive<f32>,
        baseline_y: f32,
        offset: f32,
        size: f32,
        buffer: f32,
    ) where
        Glyphs: Iterator<Item = glifo::Glyph> + Clone,
    {
        let sink = self.sink;
        let mut renderer = run.build(glyphs, self.prep.as_mut(), glifo::AtlasCacher::Disabled);
        renderer.render_decoration(x_range, baseline_y, offset, size, buffer, sink);
    }
}

/// `--dump-decoration --scene PATH` prints, for every decorated `glyph_run`
/// command, the skip-ink rectangles as f64 bit patterns. Shapes the Zig
/// decoration tests can compare against without rasterizing.
fn dump_decoration(args: &[String]) -> Result<(), String> {
    let mut scene_path: Option<PathBuf> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--scene" => scene_path = Some(iter.next().ok_or("--scene needs a value")?.into()),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let scene_path = scene_path.ok_or("missing --scene PATH")?;
    let scene_text = std::fs::read_to_string(&scene_path)
        .map_err(|e| format!("reading {}: {e}", scene_path.display()))?;
    let scene: Scene = serde_json::from_str(&scene_text)
        .map_err(|e| format!("parsing {}: {e}", scene_path.display()))?;
    let scene_dir = match scene_path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };

    let mut font_cache: HashMap<(PathBuf, u32), FontData> = HashMap::new();
    for (command_index, command) in scene.commands.iter().enumerate() {
        let Command::GlyphRun(spec) = command else {
            continue;
        };
        let Some(decoration) = &spec.decoration else {
            continue;
        };
        let font = load_font(scene_dir, &spec.font, &mut font_cache)?;
        let glyphs: Vec<Glyph> = spec
            .glyphs
            .iter()
            .map(|glyph| Glyph {
                id: glyph.id,
                x: glyph.x,
                y: glyph.y,
            })
            .collect();

        let mut sink = DecorationDumpSink {
            width: scene.width,
            height: scene.height,
            rects: Vec::new(),
        };
        {
            let backend = DecorationDumpBackend {
                sink: &mut sink,
                prep: glifo::GlyphPrepCache::default(),
            };
            let mut builder =
                glifo::GlyphRunBuilder::new(font, Affine::IDENTITY, Affine::IDENTITY, backend)
                    .font_size(spec.font_size)
                    .hint(spec.hint);
            if let Some(transform) = spec.glyph_transform {
                builder = builder.glyph_transform(parse_affine(transform));
            }
            builder.render_decoration(
                glyphs.into_iter(),
                decoration.x_range[0]..=decoration.x_range[1],
                decoration.baseline_y,
                decoration.offset,
                decoration.size,
                decoration.buffer,
            );
        }
        for rect in &sink.rects {
            println!(
                "command={command_index} x0={:016x} y0={:016x} x1={:016x} y1={:016x}",
                rect.x0.to_bits(),
                rect.y0.to_bits(),
                rect.x1.to_bits(),
                rect.y1.to_bits(),
            );
        }
    }
    Ok(())
}

/// Load (and cache) a font asset as `FontData`; the cache keeps one blob per
/// (path, face index) so repeated runs share the same font id.
fn load_font(
    scene_dir: &Path,
    spec: &FontSpec,
    font_cache: &mut HashMap<(PathBuf, u32), FontData>,
) -> Result<FontData, String> {
    let path = scene_dir.join(&spec.asset);
    let key = (path.clone(), spec.index);
    if let Some(font) = font_cache.get(&key) {
        return Ok(font.clone());
    }
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("reading font {}: {e}", path.display()))?;
    let font = FontData::new(Blob::new(Arc::new(bytes)), spec.index);
    font_cache.insert(key, font.clone());
    Ok(font)
}

/// Builds a single-primitive filter from a scene spec.
fn build_filter(spec: &FilterSpec) -> Filter {
    fn color(rgba8: &[u8; 4]) -> AlphaColor<Srgb> {
        AlphaColor::<Srgb>::from_rgba8(rgba8[0], rgba8[1], rgba8[2], rgba8[3])
    }

    let primitive = match spec {
        FilterSpec::Flood { rgba8 } => FilterPrimitive::Flood { color: color(rgba8) },
        FilterSpec::GaussianBlur {
            std_deviation,
            edge_mode,
        } => FilterPrimitive::GaussianBlur {
            std_deviation: *std_deviation,
            edge_mode: (*edge_mode).into(),
        },
        FilterSpec::Offset { dx, dy } => FilterPrimitive::Offset {
            dx: *dx,
            dy: *dy,
        },
        FilterSpec::DropShadow {
            dx,
            dy,
            std_deviation,
            rgba8,
            edge_mode,
        } => FilterPrimitive::DropShadow {
            dx: *dx,
            dy: *dy,
            std_deviation: *std_deviation,
            color: color(rgba8),
            edge_mode: (*edge_mode).into(),
        },
        FilterSpec::DropShadowOnly {
            dx,
            dy,
            std_deviation,
            rgba8,
            edge_mode,
        } => FilterPrimitive::DropShadowOnly {
            dx: *dx,
            dy: *dy,
            std_deviation: *std_deviation,
            color: color(rgba8),
            edge_mode: (*edge_mode).into(),
        },
    };
    Filter::from_primitive(primitive)
}

fn build_gradient(spec: &GradientSpec) -> Result<Gradient, String> {
    let kind = match &spec.kind {
        GradientKindSpec::Linear { start, end } => LinearGradientPosition {
            start: Point::new(start[0], start[1]),
            end: Point::new(end[0], end[1]),
        }
        .into(),
        GradientKindSpec::Radial {
            start_center,
            start_radius,
            end_center,
            end_radius,
        } => RadialGradientPosition {
            start_center: Point::new(start_center[0], start_center[1]),
            start_radius: *start_radius,
            end_center: Point::new(end_center[0], end_center[1]),
            end_radius: *end_radius,
        }
        .into(),
        GradientKindSpec::Sweep {
            center,
            start_angle,
            end_angle,
        } => SweepGradientPosition {
            center: Point::new(center[0], center[1]),
            start_angle: *start_angle,
            end_angle: *end_angle,
        }
        .into(),
    };
    let mut stops = ColorStops::new();
    for stop in &spec.stops {
        let color = AlphaColor::<Srgb>::from_rgba8(
            stop.rgba8[0],
            stop.rgba8[1],
            stop.rgba8[2],
            stop.rgba8[3],
        );
        stops.push(ColorStop::from((stop.offset, color)));
    }
    Ok(Gradient {
        kind,
        extend: spec.extend.into(),
        stops,
        ..Default::default()
    })
}

fn load_image(spec: &ImageSpec, scene_dir: &Path) -> Result<Image, String> {
    let pixmap = load_raw_pixmap(
        scene_dir,
        &spec.asset,
        spec.width,
        spec.height,
        spec.format,
        spec.alpha_type,
    )?;
    Ok(Image {
        image: ImageSource::Pixmap(Arc::new(pixmap)),
        sampler: ImageSampler {
            x_extend: spec.sampler.x_extend.into(),
            y_extend: spec.sampler.y_extend.into(),
            quality: spec.sampler.quality.into(),
            alpha: spec.sampler.alpha,
        },
    })
}

fn load_mask(spec: &MaskSpec, scene_dir: &Path, width: u16, height: u16) -> Result<Mask, String> {
    let pixmap = load_raw_pixmap(
        scene_dir,
        &spec.asset,
        spec.width,
        spec.height,
        spec.format,
        spec.alpha_type,
    )?;
    let pixmap = if pixmap.width() == width && pixmap.height() == height {
        pixmap
    } else {
        resize_nearest(&pixmap, width, height)
    };
    Ok(match spec.kind {
        MaskKindSpec::Alpha => Mask::new_alpha(&pixmap),
        MaskKindSpec::Luminance => Mask::new_luminance(&pixmap),
    })
}

/// Reads a raw RGBA8 asset and wraps it in a premultiplied [`Pixmap`].
///
/// `bgra8` assets have their red and blue channels swapped before wrapping.
/// `Pixmap::from_parts` performs the premultiplication when
/// `alpha_type` is `alpha`.
fn load_raw_pixmap(
    scene_dir: &Path,
    asset: &str,
    width: u16,
    height: u16,
    format: FormatSpec,
    alpha_type: AlphaTypeSpec,
) -> Result<Pixmap, String> {
    let path = scene_dir.join(asset);
    let mut data =
        std::fs::read(&path).map_err(|e| format!("reading asset {}: {e}", path.display()))?;
    let expected = usize::from(width) * usize::from(height) * 4;
    if data.len() != expected {
        return Err(format!(
            "asset {} has {} bytes, expected {expected} for {width}x{height} rgba",
            path.display(),
            data.len()
        ));
    }
    if matches!(format, FormatSpec::Bgra8) {
        for pixel in data.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
    }
    Ok(Pixmap::from_parts(
        data,
        width,
        height,
        PixelMetadata::new(alpha_type.into(), true),
    ))
}

/// Nearest-neighbor resample with integer `src = dst * src_size / dst_size`.
///
/// Deterministic and defined for every size; used to bring mask assets to the
/// render context size, which is what `vello_cpu::Mask` layers require.
fn resize_nearest(src: &Pixmap, width: u16, height: u16) -> Pixmap {
    let mut out = Pixmap::new(width, height);
    for y in 0..height {
        let sy = (u32::from(y) * u32::from(src.height()) / u32::from(height)) as u16;
        for x in 0..width {
            let sx = (u32::from(x) * u32::from(src.width()) / u32::from(width)) as u16;
            out.set_pixel(x, y, src.sample(sx, sy));
        }
    }
    out
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}
