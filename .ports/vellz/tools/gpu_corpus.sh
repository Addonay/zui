#!/usr/bin/env bash
# Offscreen GPU corpus gate (M5 T5).
#
# Renders the root-pass scene subset with the wgpu backend and compares the
# premultiplied RGBA8 output against the pinned `vello_cpu` oracle using the
# documented GPU tolerance.
#
# Usage:
#   tools/gpu_corpus.sh [--update-tolerances] RENDERER [SCENE ...]
#
# Invoked directly by `zig build -Dgpu=true gpu-corpus` (the file must stay
# executable).
#
#   RENDERER is the built `vellz-gpu-render` executable (the Zig build passes
#   it via `addArtifactArg`). When no scenes are given, the root-pass subset
#   below runs.
#
# Tolerance policy (docs/gpu-m5-plan.md §4): compare all four channels, start
# at `--max-abs-diff 1 --max-diff-pixels 0`, and relax a scene only with a
# written reason. The environment's adapter identity is printed with every
# render (`adapter: ... execution=...`), so software-adapter results are
# explicit.
#
# Exit status: 0 when every scene passes; 1 on the first failing comparison;
# 2 for usage or missing files.

set -euo pipefail

SCENES=(
    empty_64
    fill_rect_64
    fill_overlap_alpha_64
    fill_path_nonzero_64
    fill_path_evenodd_64
    transform_rotate_64
    stroke_basic_64
    clip_nested_64
    degenerate_64
    clip_layer_64
    clip_layer_64_speed
    layer_opacity_64
    layer_opacity_64_speed
    layer_blend_multiply_64
    layer_blend_multiply_64_speed
    filter_offset_64
    filter_flood_64
    filter_gaussian_blur_64
    filter_drop_shadow_64
    filter_drop_shadow_only_64
    filter_layer_clip_64
    filter_layer_opacity_64
    filter_layer_clip_opacity_64
    gradient_linear_64
    gradient_linear_64_speed
    gradient_radial_64
    gradient_radial_64_speed
    gradient_radial_undefined_64_speed
    gradient_sweep_64
    gradient_sweep_64_speed
    gradient_repeat_128
    gradient_repeat_128_speed
    image_nearest_64
    image_nearest_64_speed
    image_bilinear_64
    image_bilinear_64_speed
    image_bilinear_skew_64_speed
    fill_tile_grid_128
    fill_wave_seams_128
    blurred_rounded_rect_64
    blurred_rounded_rect_invert_64
    fill_overlap_alpha_64_speed
    fill_rect_64_speed
    stroke_basic_64_speed
    mask_alpha_64
    mask_alpha_64_speed
    mask_luminance_64
    glyph_run_filled_unhinted_300x70
    glyph_run_filled_unhinted_cache_300x70
    glyph_run_filled_hinted_300x70
    glyph_run_filled_hinted_cache_300x70
    glyph_run_stroked_unhinted_300x70
    glyph_run_small_unhinted_64x16
    glyph_run_small_unhinted_cache_64x16
    glyph_run_scaled_unhinted_150x125
    glyph_run_scaled_unhinted_cache_150x125
    glyph_run_scaled_hinted_150x125
    glyph_run_skewed_unhinted_300x70
    glyph_run_glyph_transform_unhinted_150x125
    glyph_run_glyph_transform_unhinted_cache_150x125
    glyph_run_glyph_transform_hinted_150x125
    glyph_run_colr_noto_250x70
    glyph_run_colr_noto_cache_250x70
    glyph_run_colr_noto_scaled_half_125x35
    glyph_run_colr_noto_rotated_350x350
    glyph_run_bitmap_noto_250x70
    glyph_run_bitmap_noto_cache_250x70
    glyph_run_decoration_no_descenders_180x70
    glyph_run_decoration_no_descenders_cache_180x70
    glyph_run_decoration_transformed_100x150
    glyph_run_decoration_offset_values_300x180
    glyph_run_composite_hinted_300x70
    glyph_run_gradient_unhinted_300x180
    glyph_run_transform_composition_unhinted_300x420
    glyph_run_transform_composition_unhinted_cache_300x420
)

usage() {
    echo "usage: tools/gpu_corpus.sh RENDERER [SCENE ...]" >&2
    exit 2
}

if [[ $# -lt 1 ]]; then
    usage
fi
RENDERER=$1
shift

if [[ $# -gt 0 ]]; then
    SCENES=("$@")
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

if [[ ! -x "$RENDERER" ]]; then
    echo "gpu-corpus: renderer '$RENDERER' is not executable" >&2
    exit 2
fi

OUT_DIR=out/gpu
mkdir -p "$OUT_DIR"

pass=0
fail=0

for scene in "${SCENES[@]}"; do
    scene_file="tests/scenes/${scene}.json"
    oracle="tests/fixtures/oracle/${scene}.rgba"
    candidate="$OUT_DIR/${scene}.rgba"
    if [[ ! -f "$scene_file" ]]; then
        echo "gpu-corpus: missing scene $scene_file" >&2
        exit 2
    fi
    if [[ ! -f "$oracle" ]]; then
        echo "gpu-corpus: missing oracle $oracle" >&2
        exit 2
    fi

    # Per-scene tolerance registry. The defaults are upstream's hybrid
    # tolerance (`max_abs=1`, no differing pixels); every relaxed entry has a
    # written reason in `tests/README.md`. Counts are the measured
    # deterministic worst case on the llvmpipe adapter, not estimates.
    max_abs=1
    max_pixels=0
    reason=""
    case "$scene" in
        # Anti-aliased edges: per-fragment GPU coverage vs CPU sparse strips.
        fill_rect_64) max_pixels=41; reason="(rect-edge AA: 41 px at 1)" ;;
        transform_rotate_64) max_pixels=84; reason="(rotated-edge AA: 84 px at 1)" ;;
        fill_tile_grid_128) max_pixels=4948; reason="(tile-seam coverage: 4948 px at 1)" ;;
        fill_wave_seams_128) max_pixels=280; reason="(tile-seam coverage: 280 px at 1)" ;;
        # u8 opacity quantization in the layer fill shader (128/255 vs 0.5).
        layer_opacity_64) max_pixels=2180; reason="(u8 opacity quantization: 2180 px at 1)" ;;
        layer_opacity_64_speed) max_pixels=580; reason="(u8 opacity quantization: 580 px at 1)" ;;
        # Filter decimation/rounding differences.
        filter_gaussian_blur_64) max_pixels=664; reason="(blur decimation rounding: 664 px at 1)" ;;
        filter_drop_shadow_64) max_pixels=464; reason="(shadow blur rounding: 464 px at 1)" ;;
        filter_drop_shadow_only_64) max_pixels=800; reason="(shadow blur rounding: 800 px at 1)" ;;
        filter_layer_opacity_64) max_pixels=800; reason="(shadow blur + u8 opacity: 800 px at 1)" ;;
        # Gradient LUT index rounding at repeat boundaries.
        gradient_repeat_128) max_pixels=27; reason="(repeat LUT rounding: 27 px at 1)" ;;
        gradient_repeat_128_speed) max_pixels=122; reason="(repeat LUT rounding: 122 px at 1)" ;;
        # u8-pipeline oracle vs the GPU's f32 analytic AA.
        clip_layer_64_speed) max_pixels=360; reason="(u8 oracle quantization: 360 px at 1)" ;;
        fill_overlap_alpha_64_speed) max_pixels=64; reason="(u8 oracle quantization: 64 px at 1)" ;;
        fill_rect_64_speed) max_pixels=119; reason="(u8 oracle quantization: 119 px at 1)" ;;
        stroke_basic_64_speed) max_pixels=98; reason="(u8 oracle quantization: 98 px at 1)" ;;
        image_bilinear_64_speed) max_pixels=455; reason="(u8 oracle/bilinear rounding: 455 px at 1)" ;;
        image_bilinear_skew_64_speed) max_abs=2; max_pixels=643; reason="(u8 oracle vs f32 skew sampling: 643 px, max 2)" ;;
        # Analytic blurred rounded rect vs the CPU pixmap integration.
        blurred_rounded_rect_64) max_abs=2; max_pixels=2032; reason="(analytic blur coverage: 2032 px, max 2)" ;;
        blurred_rounded_rect_invert_64) max_abs=2; max_pixels=2380; reason="(analytic blur coverage: 2380 px, max 2)" ;;
        # Mask adapt: GPU f32 multiply vs the CPU oracle's kernel (u8 div255
        # for the speed oracle; f32 for the regular scenes). Bounds are the
        # measured worst case; only the speed scene has channel diffs at 2.
        mask_alpha_64) max_abs=1; max_pixels=1984; reason="(f32 mask multiply vs CPU f32 kernel: 1984 px at 1)" ;;
        mask_alpha_64_speed) max_abs=2; max_pixels=2304; reason="(f32 mask multiply vs u8 div255 oracle: 2304 px, max 2)" ;;
        mask_luminance_64) max_abs=1; max_pixels=1216; reason="(f32 mask multiply vs CPU f32 kernel: 1216 px at 1)" ;;
        # GPU glyph strips vs the CPU oracle's glyph rasterization: the CPU
        # fixture is a hardened pixel path, the GPU uses analytic strip AA,
        # so edge coverage can differ by one channel step.
        glyph_run_filled_unhinted_300x70) max_pixels=493; reason="(strip AA vs CPU glyph coverage: 493 px at 1)" ;;
        glyph_run_filled_unhinted_cache_300x70) max_pixels=467; reason="(atlas glyph sampling: 467 px at 1)" ;;
        glyph_run_filled_hinted_300x70) max_pixels=476; reason="(hinted outlines: 476 px at 1)" ;;
        glyph_run_filled_hinted_cache_300x70) max_pixels=530; reason="(hinted atlas glyph sampling: 530 px at 1)" ;;
        glyph_run_stroked_unhinted_300x70) max_pixels=789; reason="(stroked outlines: 789 px at 1)" ;;
        glyph_run_scaled_unhinted_150x125) max_pixels=447; reason="(scaled outlines: 447 px at 1)" ;;
        glyph_run_scaled_unhinted_cache_150x125) max_pixels=477; reason="(scaled atlas sampling: 477 px at 1)" ;;
        glyph_run_scaled_hinted_150x125) max_pixels=418; reason="(scaled hinted outlines: 418 px at 1)" ;;
        glyph_run_skewed_unhinted_300x70) max_pixels=495; reason="(skewed outlines: 495 px at 1)" ;;
        glyph_run_glyph_transform_unhinted_150x125) max_pixels=440; reason="(per-glyph transform: 440 px at 1)" ;;
        glyph_run_glyph_transform_unhinted_cache_150x125) max_pixels=464; reason="(per-glyph transform atlas sampling: 464 px at 1)" ;;
        glyph_run_glyph_transform_hinted_150x125) max_pixels=407; reason="(hinted per-glyph transform: 407 px at 1)" ;;
        glyph_run_colr_noto_250x70) max_abs=2; max_pixels=1048; reason="(COLR color/gradient rounding: 1048 px, max 2)" ;;
        glyph_run_colr_noto_cache_250x70) max_abs=2; max_pixels=1112; reason="(COLR atlas sampling rounding: 1112 px, max 2)" ;;
        glyph_run_colr_noto_scaled_half_125x35) max_abs=2; max_pixels=501; reason="(scaled COLR rounding: 501 px, max 2)" ;;
        glyph_run_colr_noto_rotated_350x350) max_abs=2; max_pixels=940; reason="(rotated COLR rounding: 940 px, max 2)" ;;
        glyph_run_bitmap_noto_250x70) max_abs=2; max_pixels=10; reason="(bitmap pixmap sampling vs uploaded atlas: 10 px, max 2)" ;;
        glyph_run_bitmap_noto_cache_250x70) max_pixels=3; reason="(bitmap atlas sampling: 3 px at 1)" ;;
        glyph_run_decoration_transformed_100x150) max_pixels=5; reason="(transformed decoration: 5 px at 1)" ;;
        glyph_run_decoration_offset_values_300x180) max_pixels=431; reason="(decoration offset spans: 431 px at 1)" ;;
        glyph_run_composite_hinted_300x70) max_pixels=223; reason="(hinted composite glyphs: 223 px at 1)" ;;
        glyph_run_gradient_unhinted_300x180) max_pixels=437; reason="(glyph gradient paint rounding: 437 px at 1)" ;;
        glyph_run_transform_composition_unhinted_cache_300x420) max_pixels=2; reason="(transform composition atlas sampling: 2 px at 1)" ;;
        *) ;;
    esac

    echo "== gpu-corpus: $scene (max-abs-diff=$max_abs max-diff-pixels=$max_pixels${reason:+ $reason})"
    if ! "$RENDERER" --scene "$scene_file" --out "$candidate"; then
        echo "gpu-corpus: FAIL $scene (renderer error)" >&2
        fail=$((fail + 1))
        continue
    fi

    size=$(python3 - "$scene_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    scene = json.load(handle)
print(f"{scene['width']}x{scene['height']}")
PY
)

    if python3 tools/compare_raw.py "$oracle" "$candidate" \
        --size "$size" --max-abs-diff "$max_abs" --max-diff-pixels "$max_pixels"; then
        pass=$((pass + 1))
    else
        echo "gpu-corpus: FAIL $scene" >&2
        fail=$((fail + 1))
    fi
done

echo "gpu-corpus: ${pass} passed, ${fail} failed (${#SCENES[@]} scenes)"
if [[ $fail -ne 0 ]]; then
    exit 1
fi
