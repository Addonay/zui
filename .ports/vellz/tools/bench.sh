#!/usr/bin/env bash
# Stage-level CPU benchmark for the vellz port (plan.md §12 methodology).
#
# Measures scene construction, CPU preprocessing, coarse bucketing, and fine
# rasterization separately (the latter two through
# `RasterizerSettings.timings`), for the quality (f32) and speed (u8) modes
# and for the scalar `fallback` and detected `native` SIMD levels.
#
# Usage:
#   tools/bench.sh [--optimize Debug|ReleaseSafe|ReleaseFast] [--out FILE]
#                  [-- <extra vellz-bench arguments>]
#
# Defaults to ReleaseFast (benchmarks are only meaningful optimized). Run it
# for each build mode to fill docs/benchmarks.md.
set -euo pipefail

cd "$(dirname "$0")/.."

optimize="ReleaseFast"
out=""
passthru=()
while [ $# -gt 0 ]; do
    case "$1" in
        --optimize) optimize="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --) shift; passthru=("$@"); break ;;
        *) passthru=("$@"); break ;;
    esac
done

mkdir -p out
if [ -z "$out" ]; then
    out="out/bench-${optimize}.md"
fi

# `zig build bench` compiles tools/bench.zig (vendored bench executable) and
# runs it; passthrough arguments reach vellz-bench.
zig build bench -Doptimize="$optimize" -- "${passthru[@]}" | tee "$out"
echo "benchmark written to $out"
