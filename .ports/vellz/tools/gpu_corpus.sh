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

    # Per-scene tolerance registry. `max_abs` is always 1 (upstream's
    # DEFAULT_HYBRID_TOLERANCE); a scene may raise `max_pixels` past 0 only
    # with a written reason in `tests/README.md`.
    #
    # fill_rect_64 / transform_rotate_64: the GPU evaluates fractional
    # rectangle-edge coverage per fragment while the CPU oracle uses
    # sparse-strip coverage; 41/84 pixels differ by exactly one channel step
    # on the anti-aliased edges, all within max-abs-diff 1.
    max_abs=1
    max_pixels=0
    reason=""
    case "$scene" in
        fill_rect_64)
            max_pixels=64
            reason="(fractional rect-edge AA: 41 pixels differ by 1)"
            ;;
        transform_rotate_64)
            max_pixels=128
            reason="(rotated-edge AA: 84 pixels differ by 1)"
            ;;
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
