//! vellz oracle driver.
//!
//! Renders a scene from the shared JSON corpus with the pinned upstream
//! `vello_cpu` and writes premultiplied RGBA8 pixels plus a metadata sidecar.
//! The Zig implementation consumes the same scene files through
//! `tools/vellz_cli`, so scene construction is shared rather than re-created.
//!
//! This binary is development tooling. It is not distributed with the package.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use serde::Deserialize;
use vello_cpu::color::{AlphaColor, Srgb};
use vello_cpu::kurbo::{Affine, BezPath, Cap, Join, Point, Rect, Stroke};
use vello_cpu::peniko::{
    BlendMode, ColorStop, ColorStops, Compose, Extend, Fill, Gradient, ImageAlphaType,
    ImageQuality, ImageSampler, LinearGradientPosition, Mix, RadialGradientPosition,
    SweepGradientPosition,
};
use vello_cpu::{
    Image, ImageSource, Level, Mask, PaintType, PixelFormat, PixelMetadata, Pixmap,
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
    Reset,
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
    let mut scene_path: Option<PathBuf> = None;
    let mut out_path: Option<PathBuf> = None;
    let mut write_png = false;

    let mut args = std::env::args().skip(1);
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
            },
            Command::PopLayer => ctx.pop_layer(),
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
