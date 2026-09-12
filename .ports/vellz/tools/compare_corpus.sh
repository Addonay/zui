#!/usr/bin/env bash
# Render the shared corpus with vellz and compare against the pinned oracle
# fixtures. Gates G1 (foundation) and G2 (M2 CPU features, including filter
# layers and blurred rounded rectangles).
#
# Usage:
#   tools/compare_corpus.sh [--tolerance N] [--jobs N]
#
# Exit codes: 0 all scenes match, 1 mismatches, 2 setup error.
set -euo pipefail

cd "$(dirname "$0")/.."

cli="zig-out/bin/vellz-cli"
fixtures="tests/fixtures/oracle"
out="out/candidate"
diffs="out/diffs"

tolerance=0
jobs="$(nproc)"
while [ $# -gt 0 ]; do
    case "$1" in
        --tolerance) tolerance="$2"; shift 2 ;;
        --jobs) jobs="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -x "$cli" ]; then
    echo "building vellz-cli..."
    zig build vellz-cli
fi

mkdir -p "$out" "$diffs"

run_one() {
    local scene="$1" name fixture width height
    name="$(basename "$scene" .json)"
    fixture="$fixtures/$name.rgba"
    if [ ! -f "$fixture" ]; then
        echo "SKIP     $name (no oracle fixture)"
        return 0
    fi
    if ! "$cli" --scene "$scene" --out "$out/$name.rgba" >/dev/null 2>"$out/$name.stderr"; then
        echo "ERROR    $name (cli failed; see $out/$name.stderr)"
        return 1
    fi
    width="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["width"])' "$fixtures/$name.json")"
    height="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["height"])' "$fixtures/$name.json")"
    if python3 tools/compare_raw.py "$fixture" "$out/$name.rgba" \
        --size "${width}x${height}" \
        --max-abs-diff "$tolerance" --max-diff-pixels 0 \
        >"$out/$name.compare" 2>&1; then
        echo "PASS     $name"
        return 0
    fi
    echo "FAIL     $name"
    sed 's/^/         /' "$out/$name.compare"
    return 1
}
export -f run_one
export cli fixtures out tolerance

failures=0
scenes=(tests/scenes/*.json)
if command -v xargs >/dev/null; then
    printf '%s\n' "${scenes[@]}" | xargs -P "$jobs" -I{} bash -c 'run_one {}' || failures=1
else
    for scene in "${scenes[@]}"; do run_one "$scene" || failures=1; done
fi

if [ "$failures" -ne 0 ]; then
    echo "corpus: FAIL (see $out/*.compare)"
    exit 1
fi
echo "corpus: PASS (${#scenes[@]} scenes, tolerance=$tolerance)"
